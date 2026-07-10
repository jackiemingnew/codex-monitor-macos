import Foundation
import Darwin
import SQLite3

enum ShellError: Error, LocalizedError {
    case launchFailed(String)
    case timedOut(String, TimeInterval, String)
    case nonZeroExit(String, Int32, String)
    case decodeFailed(String)

    var errorDescription: String? {
        switch self {
        case .launchFailed(let executable):
            "无法启动 \(executable)。"
        case .timedOut(let executable, let timeout, let output):
            output.isEmpty
                ? "\(executable) timed out after \(Int(timeout.rounded()))s"
                : "\(executable) timed out after \(Int(timeout.rounded()))s: \(output)"
        case .nonZeroExit(let executable, let status, let output):
            "\(executable) exited with status \(status): \(output)"
        case .decodeFailed(let detail):
            "无法解析命令输出：\(detail)"
        }
    }
}

enum Shell {
    private static let outputLimit = 1024 * 1024

    static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval? = nil) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let standardOutput = Pipe()
        let standardError = Pipe()
        let outputCollector = ShellOutputCollector(limit: outputLimit)
        let errorCollector = ShellOutputCollector(limit: outputLimit)
        let readers = DispatchGroup()
        process.standardOutput = standardOutput
        process.standardError = standardError

        do {
            try process.run()
        } catch {
            throw ShellError.launchFailed(executable)
        }

        drain(standardOutput.fileHandleForReading, into: outputCollector, group: readers)
        drain(standardError.fileHandleForReading, into: errorCollector, group: readers)

        if let timeout {
            let completed = DispatchSemaphore(value: 0)
            DispatchQueue.global(qos: .utility).async {
                process.waitUntilExit()
                completed.signal()
            }

            let milliseconds = max(1, Int((timeout * 1_000).rounded()))
            if completed.wait(timeout: .now() + .milliseconds(milliseconds)) == .timedOut {
                terminateProcessTree(rootPID: process.processIdentifier, signal: SIGTERM)
                if completed.wait(timeout: .now() + .milliseconds(200)) == .timedOut {
                    terminateProcessTree(rootPID: process.processIdentifier, signal: SIGKILL)
                    _ = completed.wait(timeout: .now() + .milliseconds(300))
                }

                try? standardOutput.fileHandleForReading.close()
                try? standardError.fileHandleForReading.close()
                _ = readers.wait(timeout: .now() + .seconds(1))
                throw ShellError.timedOut(executable, timeout, combinedOutput(outputCollector, errorCollector))
            }

            readers.wait()
            let output = combinedOutput(outputCollector, errorCollector)

            guard process.terminationStatus == 0 else {
                throw ShellError.nonZeroExit(executable, process.terminationStatus, output)
            }

            return output
        }

        process.waitUntilExit()
        readers.wait()
        let output = combinedOutput(outputCollector, errorCollector)

        guard process.terminationStatus == 0 else {
            throw ShellError.nonZeroExit(executable, process.terminationStatus, output)
        }

        return output
    }

    private static func drain(
        _ handle: FileHandle,
        into collector: ShellOutputCollector,
        group: DispatchGroup
    ) {
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            defer {
                try? handle.close()
                group.leave()
            }
            while let chunk = try? handle.read(upToCount: 16 * 1024), !chunk.isEmpty {
                collector.append(chunk)
            }
        }
    }

    private static func combinedOutput(
        _ standardOutput: ShellOutputCollector,
        _ standardError: ShellOutputCollector
    ) -> String {
        [standardOutput.rendered, standardError.rendered]
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    static func sqliteJSON<T: Decodable>(
        database: String,
        query: String,
        as type: T.Type,
        readOnly: Bool = false
    ) throws -> T {
        var arguments = ["-json"]
        if readOnly {
            arguments.append("-readonly")
        }
        arguments.append(contentsOf: [database, query])

        let output = try run("/usr/bin/sqlite3", arguments)
        let trimmedOutput = output.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate = sqliteJSONPayload(from: trimmedOutput)
        let data = Data(candidate.utf8)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            if trimmedOutput.isEmpty,
               let decoded = try? JSONDecoder().decode(T.self, from: Data("[]".utf8)) {
                return decoded
            }
            throw ShellError.decodeFailed(error.localizedDescription)
        }
    }

    private static func sqliteJSONPayload(from output: String) -> String {
        guard let start = output.firstIndex(where: { $0 == "[" || $0 == "{" }) else {
            return output
        }

        let close: Character = output[start] == "[" ? "]" : "}"
        guard let end = output.lastIndex(of: close), end >= start else {
            return String(output[start...])
        }

        return String(output[start...end])
    }

    static func sqliteExec(database: String, query: String) throws {
        try SQLiteJSONReader.exec(database: database, query: query)
    }

    static func terminateProcessTree(rootPID: pid_t, signal: Int32) {
        for pid in descendantProcessIDs(of: rootPID).reversed() {
            kill(pid, signal)
        }
        kill(rootPID, signal)
    }

    private static func descendantProcessIDs(of rootPID: pid_t) -> [pid_t] {
        let relationships = processRelationships()
        var descendants: [pid_t] = []
        var stack = relationships[rootPID] ?? []

        while let pid = stack.popLast() {
            descendants.append(pid)
            stack.append(contentsOf: relationships[pid] ?? [])
        }

        return descendants
    }

    private static func processRelationships() -> [pid_t: [pid_t]] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "pid=,ppid="]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return [:]
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let output = String(decoding: data, as: UTF8.self)
        var relationships: [pid_t: [pid_t]] = [:]

        for line in output.split(separator: "\n") {
            let parts = line.split(whereSeparator: \.isWhitespace)
            guard parts.count >= 2,
                  let pid = pid_t(parts[0]),
                  let ppid = pid_t(parts[1]) else {
                continue
            }
            relationships[ppid, default: []].append(pid)
        }

        return relationships
    }
}

private final class ShellOutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var data = Data()
    private var truncated = false

    init(limit: Int) {
        self.limit = max(1, limit)
    }

    func append(_ chunk: Data) {
        lock.lock()
        defer { lock.unlock() }
        let remaining = max(0, limit - data.count)
        if remaining > 0 {
            data.append(chunk.prefix(remaining))
        }
        if chunk.count > remaining {
            truncated = true
        }
    }

    var rendered: String {
        lock.lock()
        defer { lock.unlock() }
        let output = String(decoding: data, as: UTF8.self)
        return truncated ? "\(output)\n[output truncated]" : output
    }
}

private enum SQLiteJSONReader {
    static func exec(database: String, query: String) throws {
        var connection: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(database, &connection, flags, nil) == SQLITE_OK,
              let connection else {
            let message = connection.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            if let connection {
                sqlite3_close(connection)
            }
            throw ShellError.nonZeroExit("sqlite3", 1, message)
        }
        defer {
            sqlite3_close(connection)
        }

        sqlite3_busy_timeout(connection, 1_000)
        var errorMessage: UnsafeMutablePointer<Int8>?
        let status = sqlite3_exec(connection, query, nil, nil, &errorMessage)
        guard status == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(connection))
            if let errorMessage {
                sqlite3_free(errorMessage)
            }
            throw ShellError.nonZeroExit("sqlite3", status, message)
        }
    }
}
