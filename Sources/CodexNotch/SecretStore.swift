import Foundation
import Darwin
import SQLite3

enum SecretStorageMode: String, CaseIterable, Identifiable, Codable {
    case keychain
    case database

    var id: String { rawValue }

    var label: String {
        switch self {
        case .keychain:
            "钥匙串"
        case .database:
            "本机数据库"
        }
    }
}

struct SecretKey: Hashable, Codable {
    let rawValue: String

    static let cliproxyManagement = SecretKey(rawValue: "cliproxy.management")
    static let newAPIManagement = SecretKey(rawValue: "newapi.management")
    static let subAPIManagement = SecretKey(rawValue: "subapi.management")

    static func balanceAccount(source: BalanceMonitorSource, id: String) -> SecretKey {
        SecretKey(rawValue: "\(source.rawValue).account.\(id)")
    }
}

struct SecretVault: Codable, Equatable {
    private var values: [String: String] = [:]

    var isEmpty: Bool {
        values.isEmpty
    }

    func value(for key: SecretKey) -> String {
        values[key.rawValue] ?? ""
    }

    mutating func set(_ value: String, for key: SecretKey) {
        if value.isEmpty {
            values.removeValue(forKey: key.rawValue)
        } else {
            values[key.rawValue] = value
        }
    }

    mutating func removeValue(for key: SecretKey) {
        values.removeValue(forKey: key.rawValue)
    }
}

protocol SecretStore {
    func loadVault() throws -> SecretVault
    func saveVault(_ vault: SecretVault) throws
    func deleteVault() throws
}

struct SecretStoreFactory {
    let keychain: any SecretStore
    let database: any SecretStore

    static func live() -> SecretStoreFactory {
        SecretStoreFactory(
            keychain: KeychainSecretStore(),
            database: DatabaseSecretStore(databaseURL: DatabaseSecretStore.defaultDatabaseURL)
        )
    }

    func store(for mode: SecretStorageMode) -> any SecretStore {
        switch mode {
        case .keychain:
            keychain
        case .database:
            database
        }
    }
}

struct KeychainSecretStore: SecretStore {
    static let service = "com.alight.codexnotch.secret-vault"
    static let account = "default"

    func loadVault() throws -> SecretVault {
        let encoded = try KeychainStore.read(service: Self.service, account: Self.account)
        guard !encoded.isEmpty else {
            return SecretVault()
        }
        let data = Data(encoded.utf8)
        return try JSONDecoder().decode(SecretVault.self, from: data)
    }

    func saveVault(_ vault: SecretVault) throws {
        let data = try JSONEncoder().encode(vault)
        let encoded = String(decoding: data, as: UTF8.self)
        try KeychainStore.write(encoded, service: Self.service, account: Self.account)
    }

    func deleteVault() throws {
        try KeychainStore.delete(service: Self.service, account: Self.account)
    }
}

final class MemorySecretStore: SecretStore {
    private var vault: SecretVault

    init(vault: SecretVault = SecretVault()) {
        self.vault = vault
    }

    func loadVault() throws -> SecretVault {
        vault
    }

    func saveVault(_ vault: SecretVault) throws {
        self.vault = vault
    }

    func deleteVault() throws {
        vault = SecretVault()
    }
}

enum DatabaseSecretStoreError: LocalizedError {
    case sqlite(String)
    case corruptPayload

    var errorDescription: String? {
        switch self {
        case .sqlite(let message):
            "凭证数据库操作失败：\(message)"
        case .corruptPayload:
            "凭证数据库内容已损坏，未使用空数据覆盖。"
        }
    }
}

struct DatabaseSecretStore: SecretStore {
    let databaseURL: URL

    static var defaultDatabaseURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base
            .appendingPathComponent("codex监测", isDirectory: true)
            .appendingPathComponent("secrets.sqlite3")
    }

    func loadVault() throws -> SecretVault {
        try withConnection { connection in
            let statement = try prepare(
                "SELECT payload FROM secret_vault WHERE id = ? LIMIT 1;",
                connection: connection
            )
            defer { sqlite3_finalize(statement) }
            try bindDefaultID(to: statement, connection: connection)

            switch sqlite3_step(statement) {
            case SQLITE_DONE:
                return SecretVault()
            case SQLITE_ROW:
                let count = Int(sqlite3_column_bytes(statement, 0))
                guard count > 0, let bytes = sqlite3_column_blob(statement, 0) else {
                    throw DatabaseSecretStoreError.corruptPayload
                }
                return try decodeVaultPayload(Data(bytes: bytes, count: count))
            default:
                throw sqliteError(connection)
            }
        }
    }

    func saveVault(_ vault: SecretVault) throws {
        let data = try JSONEncoder().encode(vault)
        try withConnection { connection in
            let statement = try prepare(
                """
                INSERT INTO secret_vault(id, payload, updated_at)
                VALUES(?, ?, strftime('%s','now'))
                ON CONFLICT(id) DO UPDATE SET payload = excluded.payload, updated_at = excluded.updated_at;
                """,
                connection: connection
            )
            defer { sqlite3_finalize(statement) }
            try bindDefaultID(to: statement, connection: connection)
            let bindStatus = data.withUnsafeBytes { buffer in
                sqlite3_bind_blob(
                    statement,
                    2,
                    buffer.baseAddress,
                    Int32(buffer.count),
                    Self.sqliteTransient
                )
            }
            guard bindStatus == SQLITE_OK else {
                throw sqliteError(connection)
            }
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw sqliteError(connection)
            }
        }
    }

    func deleteVault() throws {
        try withConnection { connection in
            let statement = try prepare(
                "DELETE FROM secret_vault WHERE id = ?;",
                connection: connection
            )
            defer { sqlite3_finalize(statement) }
            try bindDefaultID(to: statement, connection: connection)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw sqliteError(connection)
            }
        }
    }

    private static let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private func withConnection<T>(_ operation: (OpaquePointer) throws -> T) throws -> T {
        let directory = databaseURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        chmod(directory.path, S_IRWXU)

        var connection: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(databaseURL.path, &connection, flags, nil) == SQLITE_OK,
              let connection else {
            let message = connection.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            if let connection {
                sqlite3_close(connection)
            }
            throw DatabaseSecretStoreError.sqlite(message)
        }
        defer { sqlite3_close(connection) }
        sqlite3_busy_timeout(connection, 1_000)

        let schema = """
        CREATE TABLE IF NOT EXISTS secret_vault(
            id TEXT PRIMARY KEY,
            payload BLOB NOT NULL,
            updated_at REAL NOT NULL
        );
        """
        var errorMessage: UnsafeMutablePointer<Int8>?
        let schemaStatus = sqlite3_exec(connection, schema, nil, nil, &errorMessage)
        guard schemaStatus == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(connection))
            if let errorMessage {
                sqlite3_free(errorMessage)
            }
            throw DatabaseSecretStoreError.sqlite(message)
        }
        chmod(databaseURL.path, S_IRUSR | S_IWUSR)
        return try operation(connection)
    }

    private func prepare(_ sql: String, connection: OpaquePointer) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(connection, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw sqliteError(connection)
        }
        return statement
    }

    private func bindDefaultID(to statement: OpaquePointer, connection: OpaquePointer) throws {
        guard sqlite3_bind_text(statement, 1, "default", -1, Self.sqliteTransient) == SQLITE_OK else {
            throw sqliteError(connection)
        }
    }

    private func decodeVaultPayload(_ payload: Data) throws -> SecretVault {
        if let vault = try? JSONDecoder().decode(SecretVault.self, from: payload) {
            return vault
        }
        if let encoded = String(data: payload, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
           let legacyData = Data(base64Encoded: encoded),
           let vault = try? JSONDecoder().decode(SecretVault.self, from: legacyData) {
            return vault
        }
        throw DatabaseSecretStoreError.corruptPayload
    }

    private func sqliteError(_ connection: OpaquePointer) -> DatabaseSecretStoreError {
        .sqlite(String(cString: sqlite3_errmsg(connection)))
    }
}
