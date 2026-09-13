import Foundation

enum AntigravityQuotaCacheError: Error, Equatable, LocalizedError {
    case invalidEntry

    var errorDescription: String? {
        switch self {
        case .invalidEntry:
            "AGY 缓存内容无效"
        }
    }
}

struct AntigravityQuotaCache {
    static let defaultRelativePath = "Library/Application Support/CodexNotch/antigravity-quota.json"

    let fileURL: URL
    private let fileManager: FileManager

    init(
        fileURL: URL = AntigravityQuotaCache.defaultFileURL,
        fileManager: FileManager = .default
    ) {
        self.fileURL = fileURL
        self.fileManager = fileManager
    }

    static var defaultFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(defaultRelativePath)
    }

    func load() throws -> AntigravityQuotaCacheEntry? {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return nil
        }
        let data = try Data(contentsOf: fileURL)
        let decoder = JSONDecoder()
        let entry = try decoder.decode(AntigravityQuotaCacheEntry.self, from: data)
        guard AntigravityQuotaParser.accepts(resultSource: entry.source),
              entry.primaryFiveHour.pool == .primary,
              entry.primaryFiveHour.period == .fiveHour,
              entry.secondaryFiveHour.pool == .secondary,
              entry.secondaryFiveHour.period == .fiveHour,
              entry.primarySevenDay.map({ $0.pool == .primary && $0.period == .sevenDay }) ?? true,
              entry.secondarySevenDay.map({ $0.pool == .secondary && $0.period == .sevenDay }) ?? true else {
            throw AntigravityQuotaCacheError.invalidEntry
        }
        return entry
    }

    func save(_ entry: AntigravityQuotaCacheEntry) throws {
        guard AntigravityQuotaParser.accepts(resultSource: entry.source),
              entry.primaryFiveHour.pool == .primary,
              entry.primaryFiveHour.period == .fiveHour,
              entry.secondaryFiveHour.pool == .secondary,
              entry.secondaryFiveHour.period == .fiveHour,
              entry.primarySevenDay.map({ $0.pool == .primary && $0.period == .sevenDay }) ?? true,
              entry.secondarySevenDay.map({ $0.pool == .secondary && $0.period == .sevenDay }) ?? true else {
            throw AntigravityQuotaCacheError.invalidEntry
        }

        let directory = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(entry)
        try data.write(to: fileURL, options: [.atomic])
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}
