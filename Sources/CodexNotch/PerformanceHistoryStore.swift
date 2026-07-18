import Foundation

final class PerformanceHistoryStore: @unchecked Sendable {
    static let shared = PerformanceHistoryStore()

    static var defaultLogURL: URL {
        let logsDirectory = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library", isDirectory: true)
        return logsDirectory
            .appendingPathComponent("Logs/CodexMonitor", isDirectory: true)
            .appendingPathComponent("performance-samples.jsonl")
    }

    let logURL: URL

    private let maxBytes: UInt64
    private let lock = NSLock()
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()
    private let decoder = JSONDecoder()

    init(
        logURL: URL = PerformanceHistoryStore.defaultLogURL,
        maxBytes: UInt64 = 4 * 1_024 * 1_024
    ) {
        self.logURL = logURL
        self.maxBytes = max(8 * 1_024, maxBytes)
    }

    func record(_ sample: PerformanceSample) {
        let record = StoredPerformanceSample(sample: sample)
        guard var data = try? encoder.encode(record) else {
            return
        }
        data.append(0x0A)

        lock.lock()
        defer { lock.unlock() }
        appendLocked(data)
    }

    func recentSamples(limit: Int = 120, now: Date = Date()) -> [PerformanceSample] {
        lock.lock()
        defer { lock.unlock() }

        let records = recentLinesLocked(limit: max(1, min(limit, 5_000))).compactMap { line in
            try? decoder.decode(StoredPerformanceSample.self, from: Data(line))
        }
        return records.compactMap { $0.validatedSample(now: now) }
    }

    func recentData(limit: Int = 200) -> Data {
        lock.lock()
        defer { lock.unlock() }

        let lines = recentLinesLocked(limit: max(1, min(limit, 5_000)))
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

    private func recentLinesLocked(limit: Int) -> [Data.SubSequence] {
        let backupURL = logURL.appendingPathExtension("1")
        let sources = [backupURL, logURL]
        let combined = sources.compactMap { try? Data(contentsOf: $0) }.reduce(into: Data()) {
            $0.append($1)
        }
        return Array(combined.split(separator: 0x0A, omittingEmptySubsequences: true).suffix(limit))
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
                try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backupURL.path)
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
            return
        }
    }
}

private struct StoredPerformanceSample: Codable {
    static let schemaVersion = 1

    let schemaVersion: Int
    let timestampMilliseconds: Int64
    let chatGPT: StoredPerformanceTarget
    let safariHost: StoredPerformanceTarget
    let webKitContent: StoredPerformanceTarget
    let windowServer: StoredPerformanceTarget
    let systemMemoryFreePercent: Int?

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case timestampMilliseconds = "timestamp_ms"
        case chatGPT = "chatgpt"
        case safariHost = "safari_host"
        case webKitContent = "webkit_hot_content"
        case windowServer = "window_server"
        case systemMemoryFreePercent = "system_memory_free_percent"
    }

    init(sample: PerformanceSample) {
        schemaVersion = Self.schemaVersion
        timestampMilliseconds = Int64(sample.capturedAt.timeIntervalSince1970 * 1_000)
        chatGPT = StoredPerformanceTarget(sample.chatGPT)
        safariHost = StoredPerformanceTarget(sample.safariHost)
        webKitContent = StoredPerformanceTarget(sample.webKitContent)
        windowServer = StoredPerformanceTarget(sample.windowServer)
        systemMemoryFreePercent = sample.systemMemoryFreePercent
    }

    func validatedSample(now: Date) -> PerformanceSample? {
        guard schemaVersion == Self.schemaVersion else {
            return nil
        }
        let capturedAt = Date(timeIntervalSince1970: Double(timestampMilliseconds) / 1_000)
        guard capturedAt.timeIntervalSince(now) <= 300,
              now.timeIntervalSince(capturedAt) <= 7 * 24 * 60 * 60,
              systemMemoryFreePercent.map({ (0...100).contains($0) }) ?? true,
              let chatGPT = chatGPT.validated(kind: .chatGPT),
              let safariHost = safariHost.validated(kind: .safariHost),
              let webKitContent = webKitContent.validated(kind: .webKitContent),
              let windowServer = windowServer.validated(kind: .windowServer) else {
            return nil
        }
        return PerformanceSample(
            capturedAt: capturedAt,
            chatGPT: chatGPT,
            safariHost: safariHost,
            webKitContent: webKitContent,
            windowServer: windowServer,
            systemMemoryFreePercent: systemMemoryFreePercent
        )
    }
}

private struct StoredPerformanceTarget: Codable {
    let cpuPercent: Double
    let residentBytes: UInt64
    let processCount: Int
    let pid: Int32?

    enum CodingKeys: String, CodingKey {
        case cpuPercent = "cpu_percent"
        case residentBytes = "resident_bytes"
        case processCount = "process_count"
        case pid
    }

    init(_ target: PerformanceTargetSample) {
        cpuPercent = target.cpuPercent
        residentBytes = target.residentBytes
        processCount = target.processCount
        pid = target.pid
    }

    func validated(kind: PerformanceTargetKind) -> PerformanceTargetSample? {
        guard cpuPercent.isFinite,
              (0...10_000).contains(cpuPercent),
              (0...10_000).contains(processCount),
              pid.map({ $0 > 0 }) ?? true else {
            return nil
        }
        return PerformanceTargetSample(
            kind: kind,
            cpuPercent: cpuPercent,
            residentBytes: residentBytes,
            processCount: processCount,
            pid: pid
        )
    }
}
