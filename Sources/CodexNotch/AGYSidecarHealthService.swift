import Darwin
import Foundation

enum AGYSidecarHealthServiceError: Error, Equatable {
    case cancelled
    case liveCanaryNotAuthorized
}

protocol AGYSidecarHealthServicing: Sendable {
    func cachedEntry() async -> AGYSidecarHealthCacheEntry
    func checkDoctor(at date: Date) async throws -> AGYSidecarDoctorSnapshot
    func runCanary(at date: Date, liveAuthorized: Bool) async throws -> AGYSidecarE2ESnapshot
}

struct AGYSidecarHealthPaths: Sendable {
    let scriptURL: URL
    let supportDirectoryURL: URL
    let cacheURL: URL
    let fixtureURL: URL

    init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        applicationSupportDirectory: URL? = nil
    ) {
        let supportBase = applicationSupportDirectory
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? homeDirectory.appendingPathComponent("Library/Application Support", isDirectory: true)
        supportDirectoryURL = supportBase.appendingPathComponent("CodexNotch", isDirectory: true)
        cacheURL = supportDirectoryURL.appendingPathComponent("agy-sidecar-health.json")
        fixtureURL = supportDirectoryURL.appendingPathComponent("AGYSidecarCanary", isDirectory: true)
        scriptURL = homeDirectory
            .appendingPathComponent(".codex/skills/agy-model-sidecar/scripts/agy_review.py")
    }
}

struct AGYSidecarHealthCache: @unchecked Sendable {
    let fileURL: URL
    private let fileManager: FileManager

    init(fileURL: URL, fileManager: FileManager = .default) {
        self.fileURL = fileURL
        self.fileManager = fileManager
    }

    func load() throws -> AGYSidecarHealthCacheEntry? {
        guard fileManager.fileExists(atPath: fileURL.path) else { return nil }
        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder().decode(AGYSidecarHealthCacheEntry.self, from: data)
    }

    func save(_ entry: AGYSidecarHealthCacheEntry) throws {
        let directory = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(entry).write(to: fileURL, options: [.atomic])
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}

protocol AGYSidecarFixturePreparing: Sendable {
    func prepare() throws -> URL
}

enum AGYSidecarFixtureError: Error, Equatable {
    case invalid
}

struct AGYSidecarCanaryFixture: AGYSidecarFixturePreparing, @unchecked Sendable {
    static let correctSource = """
    def clamp(value, lower, upper):
        return min(max(value, lower), upper)

    """
    static let regressedSource = """
    def clamp(value, lower, upper):
        return min(max(value, upper), lower)

    """
    static let untrackedSource = "Canary fixture only. No production data.\n"

    let repositoryURL: URL
    private let fileManager: FileManager

    init(repositoryURL: URL, fileManager: FileManager = .default) {
        self.repositoryURL = repositoryURL
        self.fileManager = fileManager
    }

    func prepare() throws -> URL {
        let parent = repositoryURL.deletingLastPathComponent()
        guard !Self.isSymbolicLink(parent) else { throw AGYSidecarFixtureError.invalid }
        try fileManager.createDirectory(
            at: parent,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        guard !Self.isSymbolicLink(parent) else { throw AGYSidecarFixtureError.invalid }
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parent.path)

        if !fileManager.fileExists(atPath: repositoryURL.path) {
            try createFixture()
        }
        guard try validateFixture() else { throw AGYSidecarFixtureError.invalid }
        return repositoryURL
    }

    private func createFixture() throws {
        try fileManager.createDirectory(
            at: repositoryURL,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        guard !Self.isSymbolicLink(repositoryURL) else { throw AGYSidecarFixtureError.invalid }
        let clampURL = repositoryURL.appendingPathComponent("clamp.py")
        try Self.correctSource.data(using: .utf8)!.write(to: clampURL, options: [.atomic])
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: clampURL.path)
        _ = try runGit(["init", "--quiet"])
        _ = try runGit(["add", "--", "clamp.py"])
        _ = try runGit([
            "-c", "user.name=Codex Monitor Canary",
            "-c", "user.email=canary@localhost.invalid",
            "-c", "commit.gpgsign=false",
            "-c", "core.hooksPath=/dev/null",
            "commit", "--quiet", "-m", "Initialize bounded clamp canary"
        ])
        try Self.regressedSource.data(using: .utf8)!.write(to: clampURL, options: [.atomic])
        let untrackedURL = repositoryURL.appendingPathComponent("canary-note.txt")
        try Self.untrackedSource.data(using: .utf8)!.write(to: untrackedURL, options: [.atomic])
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: clampURL.path)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: untrackedURL.path)
    }

    private func validateFixture() throws -> Bool {
        guard !Self.isSymbolicLink(repositoryURL),
              Self.isDirectory(repositoryURL),
              Set(try fileManager.contentsOfDirectory(atPath: repositoryURL.path)) == [".git", "clamp.py", "canary-note.txt"] else {
            return false
        }
        let gitURL = repositoryURL.appendingPathComponent(".git", isDirectory: true)
        let clampURL = repositoryURL.appendingPathComponent("clamp.py")
        let untrackedURL = repositoryURL.appendingPathComponent("canary-note.txt")
        guard !Self.isSymbolicLink(gitURL), Self.isDirectory(gitURL),
              !Self.isSymbolicLink(clampURL), Self.isRegularFile(clampURL),
              !Self.isSymbolicLink(untrackedURL), Self.isRegularFile(untrackedURL),
              String(decoding: try Data(contentsOf: clampURL), as: UTF8.self) == Self.regressedSource,
              String(decoding: try Data(contentsOf: untrackedURL), as: UTF8.self) == Self.untrackedSource,
              String(decoding: try runGit(["show", "HEAD:clamp.py"]), as: UTF8.self) == Self.correctSource,
              String(decoding: try runGit(["rev-list", "--count", "HEAD"]), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == "1",
              String(decoding: try runGit(["ls-files"]), as: UTF8.self) == "clamp.py\n",
              String(decoding: try runGit(["diff", "--name-only", "HEAD", "--"]), as: UTF8.self) == "clamp.py\n",
              String(decoding: try runGit(["status", "--porcelain=v1", "--untracked-files=all"]), as: UTF8.self)
                == " M clamp.py\n?? canary-note.txt\n" else {
            return false
        }
        return true
    }

    private func runGit(_ arguments: [String]) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", repositoryURL.path] + arguments
        process.environment = [
            "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
            "PATH": "/usr/bin:/bin",
            "LANG": "C",
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_CONFIG_GLOBAL": "/dev/null",
            "GIT_OPTIONAL_LOCKS": "0",
            "GIT_PAGER": "cat",
            "PAGER": "cat"
        ]
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw AGYSidecarFixtureError.invalid
        }
        process.waitUntilExit()
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        _ = stderr.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0, output.count <= 64 * 1024 else {
            throw AGYSidecarFixtureError.invalid
        }
        return output
    }

    private static func fileMode(_ url: URL) -> mode_t? {
        var info = stat()
        return lstat(url.path, &info) == 0 ? info.st_mode : nil
    }

    private static func isSymbolicLink(_ url: URL) -> Bool {
        guard let mode = fileMode(url) else { return false }
        return mode & S_IFMT == S_IFLNK
    }

    private static func isDirectory(_ url: URL) -> Bool {
        guard let mode = fileMode(url) else { return false }
        return mode & S_IFMT == S_IFDIR
    }

    private static func isRegularFile(_ url: URL) -> Bool {
        guard let mode = fileMode(url) else { return false }
        return mode & S_IFMT == S_IFREG
    }
}

actor AGYSidecarHealthService: AGYSidecarHealthServicing {
    private let runner: any AGYSidecarProcessRunning
    private let fixture: any AGYSidecarFixturePreparing
    private let cache: AGYSidecarHealthCache
    private let diagnostics: MonitorDiagnostics
    private let scriptURL: URL
    private var entry: AGYSidecarHealthCacheEntry

    init(
        runner: any AGYSidecarProcessRunning = AGYSidecarProcessRunner(),
        paths: AGYSidecarHealthPaths = AGYSidecarHealthPaths(),
        fixture: (any AGYSidecarFixturePreparing)? = nil,
        cache: AGYSidecarHealthCache? = nil,
        diagnostics: MonitorDiagnostics = .shared
    ) {
        self.runner = runner
        self.fixture = fixture ?? AGYSidecarCanaryFixture(repositoryURL: paths.fixtureURL)
        self.cache = cache ?? AGYSidecarHealthCache(fileURL: paths.cacheURL)
        self.diagnostics = diagnostics
        scriptURL = paths.scriptURL
        entry = (try? self.cache.load()) ?? AGYSidecarHealthCacheEntry(doctor: .neverRun, e2e: .neverRun)
    }

    func cachedEntry() -> AGYSidecarHealthCacheEntry {
        entry
    }

    func checkDoctor(at date: Date) async throws -> AGYSidecarDoctorSnapshot {
        let snapshot: AGYSidecarDoctorSnapshot
        do {
            let result = try await runner.run(.doctor(scriptURL: scriptURL))
            let parsed = try AGYSidecarReceiptParser.parseDoctor(result.stdout, checkedAt: date)
            let validExit = ((parsed.status == .ready || parsed.status == .compatibilityWarning) && result.exitCode == 0)
                || (parsed.status == .unavailable && result.exitCode == 20)
            snapshot = validExit ? parsed : AGYSidecarDoctorSnapshot(
                status: .broken,
                checkedAt: date,
                models: parsed.models,
                repositoryModeReady: parsed.repositoryModeReady,
                errorCode: .processFailed
            )
        } catch let error as AGYSidecarProcessRunnerError {
            if error == .cancelled { throw AGYSidecarHealthServiceError.cancelled }
            snapshot = doctorFailure(error, at: date)
        } catch let error as AGYSidecarReceiptParserError {
            snapshot = AGYSidecarDoctorSnapshot(
                status: .broken,
                checkedAt: date,
                models: [],
                repositoryModeReady: false,
                errorCode: error == .receiptOversized ? .receiptOversized : .outputInvalid
            )
        } catch {
            snapshot = AGYSidecarDoctorSnapshot(
                status: .broken,
                checkedAt: date,
                models: [],
                repositoryModeReady: false,
                errorCode: .outputInvalid
            )
        }
        entry = AGYSidecarHealthCacheEntry(doctor: snapshot, e2e: entry.e2e)
        persistAndRecordDoctor(snapshot)
        return snapshot
    }

    func runCanary(at date: Date, liveAuthorized: Bool) async throws -> AGYSidecarE2ESnapshot {
        guard liveAuthorized else { throw AGYSidecarHealthServiceError.liveCanaryNotAuthorized }
        let repositoryURL: URL
        do {
            repositoryURL = try fixture.prepare()
        } catch {
            let unavailable = e2eFailure(status: .unavailable, at: date, code: .fixtureInvalid)
            entry = AGYSidecarHealthCacheEntry(doctor: entry.doctor, e2e: unavailable)
            persistAndRecordE2E(unavailable)
            return unavailable
        }

        let snapshot: AGYSidecarE2ESnapshot
        do {
            let result = try await runner.run(.review(scriptURL: scriptURL, repositoryURL: repositoryURL))
            let parsed = try AGYSidecarReceiptParser.parseReview(result.stdout, checkedAt: date)
            let expectedExit: Int32? = switch parsed.wrapperStatus {
            case "COMPLETE": 0
            case "PARTIAL": 21
            case "FALLBACK_SOL": 20
            case "INPUT_REJECTED": 2
            default: nil
            }
            snapshot = expectedExit == result.exitCode ? parsed : copyE2E(
                parsed,
                status: .broken,
                errorCode: .processFailed
            )
        } catch let error as AGYSidecarProcessRunnerError {
            if error == .cancelled { throw AGYSidecarHealthServiceError.cancelled }
            if error == .stdoutOversized {
                snapshot = e2eFailure(status: .broken, at: date, code: .receiptOversized)
            } else {
                snapshot = e2eFailure(status: .unavailable, at: date, code: processErrorCode(error))
            }
        } catch let error as AGYSidecarReceiptParserError {
            snapshot = e2eFailure(
                status: .broken,
                at: date,
                code: error == .receiptOversized ? .receiptOversized : .outputInvalid
            )
        } catch {
            snapshot = e2eFailure(status: .broken, at: date, code: .outputInvalid)
        }
        entry = AGYSidecarHealthCacheEntry(doctor: entry.doctor, e2e: snapshot)
        persistAndRecordE2E(snapshot)
        return snapshot
    }

    private func doctorFailure(_ error: AGYSidecarProcessRunnerError, at date: Date) -> AGYSidecarDoctorSnapshot {
        let status: AGYSidecarDoctorStatus = error == .stdoutOversized ? .broken : .unavailable
        return AGYSidecarDoctorSnapshot(
            status: status,
            checkedAt: date,
            models: [],
            repositoryModeReady: false,
            errorCode: error == .stdoutOversized ? .receiptOversized : processErrorCode(error)
        )
    }

    private func processErrorCode(_ error: AGYSidecarProcessRunnerError) -> AGYSidecarErrorCode {
        switch error {
        case .pythonUnavailable: .pythonUnavailable
        case .scriptUnavailable: .scriptUnavailable
        case .timedOut: .timedOut
        case .cancelled: .cancelled
        case .stdoutOversized: .receiptOversized
        case .launchFailed: .processFailed
        }
    }

    private func e2eFailure(status: AGYSidecarE2EStatus, at date: Date, code: AGYSidecarErrorCode) -> AGYSidecarE2ESnapshot {
        AGYSidecarE2ESnapshot(
            status: status,
            checkedAt: date,
            wrapperStatus: nil,
            attemptedModels: [],
            secondaryRequired: nil,
            source: nil,
            toolAudit: nil,
            usage: .unavailable,
            receiptBytes: nil,
            findingMatched: nil,
            codexTokenUsage: nil,
            errorCode: code
        )
    }

    private func copyE2E(
        _ snapshot: AGYSidecarE2ESnapshot,
        status: AGYSidecarE2EStatus,
        errorCode: AGYSidecarErrorCode
    ) -> AGYSidecarE2ESnapshot {
        AGYSidecarE2ESnapshot(
            status: status,
            checkedAt: snapshot.checkedAt,
            wrapperStatus: snapshot.wrapperStatus,
            attemptedModels: snapshot.attemptedModels,
            secondaryRequired: snapshot.secondaryRequired,
            source: snapshot.source,
            toolAudit: snapshot.toolAudit,
            usage: snapshot.usage,
            receiptBytes: snapshot.receiptBytes,
            findingMatched: snapshot.findingMatched,
            codexTokenUsage: snapshot.codexTokenUsage,
            errorCode: errorCode
        )
    }

    private func persistAndRecordDoctor(_ snapshot: AGYSidecarDoctorSnapshot) {
        try? cache.save(entry)
        diagnostics.record(
            event: "agy_sidecar_doctor_state",
            correlationID: "agy-sidecar-doctor",
            fields: [
                "status": snapshot.status.rawValue,
                "error_code": snapshot.errorCode?.rawValue ?? "NONE",
                "repo_snapshot_ready": snapshot.repositoryModeReady,
                "available_models": snapshot.models.filter(\.available).map(\.model).sorted()
            ]
        )
    }

    private func persistAndRecordE2E(_ snapshot: AGYSidecarE2ESnapshot) {
        try? cache.save(entry)
        var fields: [String: Any] = [
            "status": snapshot.status.rawValue,
            "wrapper_status": snapshot.wrapperStatus ?? "NONE",
            "error_code": snapshot.errorCode?.rawValue ?? "NONE",
            "attempted_models": snapshot.attemptedModels,
            "finding_matched": snapshot.findingMatched ?? false,
            "receipt_bytes": snapshot.receiptBytes ?? -1
        ]
        if let audit = snapshot.toolAudit {
            fields["snapshot_diff_reads"] = audit.snapshotDiffReads
            fields["read_only_file_calls"] = audit.readOnlyFileCalls
            fields["other_tool_calls"] = audit.otherToolCalls
        }
        if let total = snapshot.usage.total { fields["usage_total"] = total }
        diagnostics.record(
            event: "agy_sidecar_e2e_state",
            correlationID: "agy-sidecar-e2e",
            fields: fields
        )
    }
}
