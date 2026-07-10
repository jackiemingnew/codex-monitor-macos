import Foundation
import OSLog

final class MonitorDiagnostics: @unchecked Sendable {
    static let shared = MonitorDiagnostics()

    static var defaultLogURL: URL {
        let logsDirectory = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library", isDirectory: true)
        return logsDirectory
            .appendingPathComponent("Logs/CodexMonitor", isDirectory: true)
            .appendingPathComponent("quota-diagnostics.jsonl")
    }

    let logURL: URL

    private let maxBytes: UInt64
    private let lock = NSLock()
    private var lastPayloadByEvent: [String: Data] = [:]
    private let systemLogger = Logger(subsystem: "com.alight.codexnotch", category: "quota")
    private let dateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    init(logURL: URL = MonitorDiagnostics.defaultLogURL, maxBytes: UInt64 = 2 * 1024 * 1024) {
        self.logURL = logURL
        self.maxBytes = max(4 * 1024, maxBytes)
    }

    func record(
        event: String,
        correlationID: String,
        fields: [String: Any],
        deduplicate: Bool = true
    ) {
        guard JSONSerialization.isValidJSONObject(fields),
              let canonical = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]) else {
            return
        }

        lock.lock()
        defer { lock.unlock() }

        if deduplicate, lastPayloadByEvent[event] == canonical {
            return
        }
        lastPayloadByEvent[event] = canonical

        var payload = fields
        payload["timestamp"] = dateFormatter.string(from: Date())
        payload["event"] = event
        payload["correlation_id"] = correlationID
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else {
            return
        }

        var line = data
        line.append(0x0A)
        appendLocked(line)
        if let text = String(data: data, encoding: .utf8) {
            systemLogger.debug("\(text, privacy: .public)")
        }
    }

    func recentData(limit: Int = 200) -> Data {
        lock.lock()
        defer { lock.unlock() }

        let boundedLimit = max(1, min(limit, 2_000))
        let backupURL = logURL.appendingPathExtension("1")
        let sources = [backupURL, logURL]
        let combined = sources.compactMap { try? Data(contentsOf: $0) }.reduce(into: Data()) {
            $0.append($1)
        }
        let lines = combined.split(separator: 0x0A, omittingEmptySubsequences: true).suffix(boundedLimit)
        guard !lines.isEmpty else {
            return Data()
        }

        var output = Data()
        for line in lines {
            output.append(contentsOf: line)
            output.append(0x0A)
        }
        return output
    }

    private func appendLocked(_ data: Data) {
        let fileManager = FileManager.default
        let directory = logURL.deletingLastPathComponent()
        do {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)

            let currentSize = (try? logURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(UInt64.init) ?? 0
            if currentSize > 0, currentSize + UInt64(data.count) > maxBytes {
                let backupURL = logURL.appendingPathExtension("1")
                try? fileManager.removeItem(at: backupURL)
                try fileManager.moveItem(at: logURL, to: backupURL)
            }

            if !fileManager.fileExists(atPath: logURL.path) {
                guard fileManager.createFile(
                    atPath: logURL.path,
                    contents: nil,
                    attributes: [.posixPermissions: 0o600]
                ) else {
                    return
                }
            }
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: logURL.path)

            let handle = try FileHandle(forWritingTo: logURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            systemLogger.error("diagnostic file write failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
