import Foundation
import Darwin

enum CodexSkillCatalogSourceError: Error {
    case missingExecutable
    case launchFailed
    case timedOut
    case responseTooLarge
    case protocolFailure
    case parseFailed
}

final class CodexSkillsAppServerClient: @unchecked Sendable {
    private let codexDirectory: URL
    private let workingDirectory: URL
    private let executablePath: String?
    private let timeout: TimeInterval
    private let maxOutputBytes: Int

    init(
        codexDirectory: URL,
        workingDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        executablePath: String? = nil,
        timeout: TimeInterval = 5,
        maxOutputBytes: Int = 8 * 1024 * 1024
    ) {
        self.codexDirectory = codexDirectory.standardizedFileURL
        self.workingDirectory = workingDirectory.standardizedFileURL
        self.executablePath = executablePath ?? CodexRuntimeLocator.executable(named: "codex")
        self.timeout = max(0.1, timeout)
        self.maxOutputBytes = max(64 * 1024, maxOutputBytes)
    }

    func load(now: Date, forceReload: Bool) throws -> SkillCatalogSnapshot {
        guard let executablePath,
              FileManager.default.isExecutableFile(atPath: executablePath) else {
            throw CodexSkillCatalogSourceError.missingExecutable
        }

        let response = try runSkillsList(
            executablePath: executablePath,
            forceReload: forceReload
        )
        return try Self.parseSkillsListResponse(response, loadedAt: now)
    }

    static func parseSkillsListResponse(
        _ data: Data,
        loadedAt: Date
    ) throws -> SkillCatalogSnapshot {
        let envelope: SkillsListEnvelope
        do {
            envelope = try JSONDecoder().decode(SkillsListEnvelope.self, from: data)
        } catch {
            throw CodexSkillCatalogSourceError.parseFailed
        }
        guard envelope.error == nil,
              let result = envelope.result else {
            throw CodexSkillCatalogSourceError.protocolFailure
        }

        let metadata = result.data.flatMap(\.skills)
        var seenPaths = Set<String>()
        var invalidEntries = 0
        var skills: [SkillCatalogEntry] = []

        for item in metadata {
            let name = item.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let description = item.description.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, !description.isEmpty else {
                invalidEntries += 1
                continue
            }

            let canonicalPath = URL(fileURLWithPath: item.path)
                .resolvingSymlinksInPath()
                .standardizedFileURL
                .path
            guard seenPaths.insert(canonicalPath).inserted else {
                continue
            }

            let characterCount = name.count + description.count
            skills.append(
                SkillCatalogEntry(
                    id: SkillCatalogLoader.stableID(for: canonicalPath),
                    name: name,
                    description: description,
                    path: canonicalPath,
                    enabled: item.enabled,
                    catalogCharacterCount: characterCount,
                    catalogTokenEstimate: max(1, Int(ceil(Double(characterCount) / 4.0))),
                    protectsHighRiskWorkflow: SkillCatalogLoader.protectsHighRiskWorkflow(
                        name: name,
                        description: description
                    )
                )
            )
        }

        let sourceErrorCount = result.data.reduce(0) { $0 + $1.errors.count }
        var diagnostics: [String] = []
        if sourceErrorCount > 0 {
            diagnostics.append("Codex reported \(sourceErrorCount) Skill catalog loading error(s).")
        }
        if invalidEntries > 0 {
            diagnostics.append("Codex returned \(invalidEntries) Skill catalog entry or entries without usable metadata.")
        }

        let sortedSkills = skills.sorted {
            if $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedSame {
                return $0.path < $1.path
            }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        let quality: SkillInsightsQuality
        if sortedSkills.isEmpty {
            quality = .unavailable
        } else if diagnostics.isEmpty {
            quality = .complete
        } else {
            quality = .partial
        }

        return SkillCatalogSnapshot(
            skills: sortedSkills,
            quality: quality,
            diagnostics: diagnostics,
            loadedAt: loadedAt
        )
    }

    private func runSkillsList(
        executablePath: String,
        forceReload: Bool
    ) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = ["app-server", "--stdio"]
        process.currentDirectoryURL = workingDirectory
        var environment = ProcessInfo.processInfo.environment
        environment["CODEX_HOME"] = codexDirectory.path
        process.environment = environment

        let standardInput = Pipe()
        let standardOutput = Pipe()
        let standardError = Pipe()
        process.standardInput = standardInput
        process.standardOutput = standardOutput
        process.standardError = standardError

        let accumulator = SkillsListResponseAccumulator(
            responseID: 2,
            maxOutputBytes: maxOutputBytes
        )
        let responseReady = DispatchSemaphore(value: 0)
        let terminated = DispatchSemaphore(value: 0)

        standardOutput.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else {
                return
            }
            if accumulator.append(chunk) {
                responseReady.signal()
            }
        }
        standardError.fileHandleForReading.readabilityHandler = { handle in
            _ = handle.availableData
        }
        process.terminationHandler = { _ in
            terminated.signal()
        }

        do {
            try process.run()
        } catch {
            standardOutput.fileHandleForReading.readabilityHandler = nil
            standardError.fileHandleForReading.readabilityHandler = nil
            throw CodexSkillCatalogSourceError.launchFailed
        }

        defer {
            try? standardInput.fileHandleForWriting.close()
            if process.isRunning {
                Shell.terminateProcessTree(rootPID: process.processIdentifier, signal: SIGTERM)
                if terminated.wait(timeout: .now() + .milliseconds(200)) == .timedOut {
                    Shell.terminateProcessTree(rootPID: process.processIdentifier, signal: SIGKILL)
                    _ = terminated.wait(timeout: .now() + .milliseconds(300))
                }
            }
            standardOutput.fileHandleForReading.readabilityHandler = nil
            standardError.fileHandleForReading.readabilityHandler = nil
            try? standardOutput.fileHandleForReading.close()
            try? standardError.fileHandleForReading.close()
        }

        do {
            try standardInput.fileHandleForWriting.write(
                contentsOf: requestPayload(forceReload: forceReload)
            )
        } catch {
            throw CodexSkillCatalogSourceError.protocolFailure
        }

        let milliseconds = max(1, Int((timeout * 1_000).rounded()))
        guard responseReady.wait(timeout: .now() + .milliseconds(milliseconds)) == .success else {
            throw CodexSkillCatalogSourceError.timedOut
        }

        let response = try accumulator.response()
        try? standardInput.fileHandleForWriting.close()
        if process.isRunning,
           terminated.wait(timeout: .now() + .milliseconds(300)) == .timedOut {
            Shell.terminateProcessTree(rootPID: process.processIdentifier, signal: SIGTERM)
            _ = terminated.wait(timeout: .now() + .milliseconds(300))
        }
        return response
    }

    private func requestPayload(forceReload: Bool) throws -> Data {
        let messages: [[String: Any]] = [
            [
                "jsonrpc": "2.0",
                "id": 1,
                "method": "initialize",
                "params": [
                    "clientInfo": [
                        "name": "codex-monitor",
                        "version": AppInfo.version
                    ],
                    "capabilities": ["experimentalApi": true]
                ]
            ],
            [
                "jsonrpc": "2.0",
                "method": "initialized"
            ],
            [
                "jsonrpc": "2.0",
                "id": 2,
                "method": "skills/list",
                "params": [
                    "cwds": [workingDirectory.path],
                    "forceReload": forceReload
                ]
            ]
        ]

        var payload = Data()
        for message in messages {
            payload.append(try JSONSerialization.data(withJSONObject: message, options: [.sortedKeys]))
            payload.append(0x0A)
        }
        return payload
    }
}

private final class SkillsListResponseAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private let responseID: Int
    private let maxOutputBytes: Int
    private var totalOutputBytes = 0
    private var buffer = Data()
    private var responseData: Data?
    private var failure: CodexSkillCatalogSourceError?

    init(responseID: Int, maxOutputBytes: Int) {
        self.responseID = responseID
        self.maxOutputBytes = maxOutputBytes
    }

    func append(_ chunk: Data) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard responseData == nil, failure == nil else {
            return false
        }

        totalOutputBytes += chunk.count
        guard totalOutputBytes <= maxOutputBytes else {
            failure = .responseTooLarge
            return true
        }
        buffer.append(chunk)

        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = Data(buffer[..<newline])
            buffer.removeSubrange(buffer.startIndex...newline)
            guard !line.isEmpty,
                  let identifier = try? JSONDecoder().decode(ResponseIdentifier.self, from: line),
                  identifier.id == responseID else {
                continue
            }
            responseData = line
            return true
        }
        return false
    }

    func response() throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        if let failure {
            throw failure
        }
        guard let responseData else {
            throw CodexSkillCatalogSourceError.protocolFailure
        }
        return responseData
    }
}

private struct ResponseIdentifier: Decodable {
    let id: Int?
}

private struct SkillsListEnvelope: Decodable {
    let result: SkillsListResult?
    let error: SkillsListRPCError?
}

private struct SkillsListRPCError: Decodable {
    let code: Int?
    let message: String?
}

private struct SkillsListResult: Decodable {
    let data: [SkillsListEntry]
}

private struct SkillsListEntry: Decodable {
    let skills: [SkillsListMetadata]
    let errors: [SkillsListError]
}

private struct SkillsListMetadata: Decodable {
    let name: String
    let description: String
    let path: String
    let enabled: Bool
}

private struct SkillsListError: Decodable {}
