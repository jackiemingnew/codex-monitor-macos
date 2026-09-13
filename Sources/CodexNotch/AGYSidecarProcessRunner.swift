import Darwin
import Foundation

struct AGYSidecarProcessRequest: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case doctor
        case review
    }

    let kind: Kind
    let scriptURL: URL
    let arguments: [String]
    let timeout: TimeInterval

    static func doctor(scriptURL: URL) -> AGYSidecarProcessRequest {
        AGYSidecarProcessRequest(
            kind: .doctor,
            scriptURL: scriptURL,
            arguments: [scriptURL.path, "doctor"],
            timeout: AGYSidecarHealthPolicy.doctorTimeout
        )
    }

    static func review(scriptURL: URL, repositoryURL: URL) -> AGYSidecarProcessRequest {
        AGYSidecarProcessRequest(
            kind: .review,
            scriptURL: scriptURL,
            arguments: [
                scriptURL.path,
                "review",
                "--repo",
                repositoryURL.path,
                "--task",
                AGYSidecarHealthPolicy.canaryTask,
                "--risk",
                "normal"
            ],
            timeout: AGYSidecarHealthPolicy.reviewTimeout
        )
    }
}

struct AGYSidecarProcessResult: Equatable, Sendable {
    let stdout: Data
    let stderrBytes: Int
    let exitCode: Int32
    let duration: TimeInterval
}

enum AGYSidecarProcessRunnerError: Error, Equatable {
    case pythonUnavailable
    case scriptUnavailable
    case launchFailed
    case timedOut
    case cancelled
    case stdoutOversized
}

protocol AGYSidecarProcessRunning: Sendable {
    func run(_ request: AGYSidecarProcessRequest) async throws -> AGYSidecarProcessResult
}

struct AGYSidecarProcessRunner: AGYSidecarProcessRunning, @unchecked Sendable {
    static let pythonURL = URL(fileURLWithPath: "/usr/bin/python3")

    let fileManager: FileManager
    let environment: [String: String]

    init(
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.fileManager = fileManager
        self.environment = environment
    }

    func run(_ request: AGYSidecarProcessRequest) async throws -> AGYSidecarProcessResult {
        guard fileManager.isExecutableFile(atPath: Self.pythonURL.path) else {
            throw AGYSidecarProcessRunnerError.pythonUnavailable
        }
        guard request.scriptURL.isFileURL,
              fileManager.fileExists(atPath: request.scriptURL.path) else {
            throw AGYSidecarProcessRunnerError.scriptUnavailable
        }

        let startedAt = Date()
        let process = try spawn(request)
        let stdoutTask = Task.detached(priority: .utility) {
            AGYSidecarPipeReader.readBounded(
                fileDescriptor: process.stdoutFD,
                limit: AGYSidecarHealthPolicy.receiptByteLimit,
                onOversized: { process.terminate() }
            )
        }
        let stderrTask = Task.detached(priority: .utility) {
            AGYSidecarPipeReader.countAndDiscard(fileDescriptor: process.stderrFD)
        }

        do {
            let exitCode = try await withTaskCancellationHandler {
                try await waitForExit(process, timeout: request.timeout)
            } onCancel: {
                process.terminate()
            }
            let stdoutResult = await stdoutTask.value
            let stderrBytes = await stderrTask.value
            if stdoutResult.oversized {
                throw AGYSidecarProcessRunnerError.stdoutOversized
            }
            return AGYSidecarProcessResult(
                stdout: stdoutResult.data,
                stderrBytes: stderrBytes,
                exitCode: exitCode,
                duration: Date().timeIntervalSince(startedAt)
            )
        } catch {
            process.terminate()
            _ = await stdoutTask.value
            _ = await stderrTask.value
            if error is CancellationError {
                throw AGYSidecarProcessRunnerError.cancelled
            }
            throw error
        }
    }

    private func waitForExit(_ process: AGYSidecarSpawnedProcess, timeout: TimeInterval) async throws -> Int32 {
        try await withThrowingTaskGroup(of: Int32.self) { group in
            group.addTask(priority: .utility) {
                process.waitForExit()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(max(0.01, timeout) * 1_000_000_000))
                process.terminate()
                throw AGYSidecarProcessRunnerError.timedOut
            }
            guard let result = try await group.next() else {
                process.terminate()
                throw AGYSidecarProcessRunnerError.launchFailed
            }
            group.cancelAll()
            return result
        }
    }

    private func spawn(_ request: AGYSidecarProcessRequest) throws -> AGYSidecarSpawnedProcess {
        var stdoutPipe: [Int32] = [0, 0]
        var stderrPipe: [Int32] = [0, 0]
        guard pipe(&stdoutPipe) == 0 else { throw AGYSidecarProcessRunnerError.launchFailed }
        guard pipe(&stderrPipe) == 0 else {
            close(stdoutPipe[0]); close(stdoutPipe[1])
            throw AGYSidecarProcessRunnerError.launchFailed
        }

        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&actions) == 0,
              posix_spawnattr_init(&attributes) == 0 else {
            close(stdoutPipe[0]); close(stdoutPipe[1]); close(stderrPipe[0]); close(stderrPipe[1])
            throw AGYSidecarProcessRunnerError.launchFailed
        }
        defer {
            posix_spawn_file_actions_destroy(&actions)
            posix_spawnattr_destroy(&attributes)
        }

        let devNull = "/dev/null"
        let spawnFlags = POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT
        guard posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, devNull, O_RDONLY, 0) == 0,
              posix_spawn_file_actions_adddup2(&actions, stdoutPipe[1], STDOUT_FILENO) == 0,
              posix_spawn_file_actions_adddup2(&actions, stderrPipe[1], STDERR_FILENO) == 0,
              posix_spawn_file_actions_addclose(&actions, stdoutPipe[0]) == 0,
              posix_spawn_file_actions_addclose(&actions, stderrPipe[0]) == 0,
              posix_spawn_file_actions_addclose(&actions, stdoutPipe[1]) == 0,
              posix_spawn_file_actions_addclose(&actions, stderrPipe[1]) == 0,
              posix_spawnattr_setflags(&attributes, Int16(spawnFlags)) == 0,
              posix_spawnattr_setpgroup(&attributes, 0) == 0 else {
            close(stdoutPipe[0]); close(stdoutPipe[1]); close(stderrPipe[0]); close(stderrPipe[1])
            throw AGYSidecarProcessRunnerError.launchFailed
        }

        let safeEnvironmentNames: Set<String> = [
            "HOME", "PATH", "USER", "LOGNAME", "LANG", "LC_ALL", "LC_CTYPE", "TERM", "TMPDIR",
            "SSL_CERT_FILE", "SSL_CERT_DIR", "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY",
            "http_proxy", "https_proxy", "all_proxy", "no_proxy", "XDG_CONFIG_HOME"
        ]
        var environmentPointers = environment
            .filter { safeEnvironmentNames.contains($0.key) }
            .map { strdup("\($0.key)=\($0.value)") as UnsafeMutablePointer<CChar>? }
        environmentPointers.append(nil)
        defer {
            for pointer in environmentPointers {
                if let pointer { free(pointer) }
            }
        }

        let argvStrings = [Self.pythonURL.path] + request.arguments
        var argumentPointers = argvStrings.map { strdup($0) as UnsafeMutablePointer<CChar>? }
        argumentPointers.append(nil)
        defer {
            for pointer in argumentPointers {
                if let pointer { free(pointer) }
            }
        }

        var pid: pid_t = 0
        let status = Self.pythonURL.path.withCString { executable in
            posix_spawn(&pid, executable, &actions, &attributes, &argumentPointers, &environmentPointers)
        }
        close(stdoutPipe[1])
        close(stderrPipe[1])
        // POSIX_SPAWN_SETPGROUP with pgroup 0 makes the child its own group.
        // Do not query getpgid here: a valid short-lived doctor can exit before
        // the parent reaches that check, which would turn success into a race.
        guard status == 0, pid > 0 else {
            close(stdoutPipe[0]); close(stderrPipe[0])
            if pid > 0 {
                _ = kill(pid, SIGKILL)
                var waitStatus: Int32 = 0
                while waitpid(pid, &waitStatus, 0) == -1 && errno == EINTR {}
            }
            throw AGYSidecarProcessRunnerError.launchFailed
        }
        return AGYSidecarSpawnedProcess(pid: pid, stdoutFD: stdoutPipe[0], stderrFD: stderrPipe[0])
    }
}

private final class AGYSidecarSpawnedProcess: @unchecked Sendable {
    let pid: pid_t
    let stdoutFD: Int32
    let stderrFD: Int32
    private let lock = NSLock()
    private var terminationRequested = false

    init(pid: pid_t, stdoutFD: Int32, stderrFD: Int32) {
        self.pid = pid
        self.stdoutFD = stdoutFD
        self.stderrFD = stderrFD
    }

    func terminate() {
        lock.lock()
        let shouldSignal = !terminationRequested
        terminationRequested = true
        lock.unlock()
        guard shouldSignal else { return }
        _ = kill(-pid, SIGTERM)
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5) { [pid] in
            if kill(-pid, 0) == 0 || errno == EPERM {
                _ = kill(-pid, SIGKILL)
            }
        }
    }

    func waitForExit() -> Int32 {
        var status: Int32 = 0
        while waitpid(pid, &status, 0) == -1 {
            if errno != EINTR { return 255 }
        }
        if status & 0x7F == 0 {
            return (status >> 8) & 0xFF
        }
        return 128 + (status & 0x7F)
    }
}

private enum AGYSidecarPipeReader {
    struct BoundedRead: Sendable {
        let data: Data
        let oversized: Bool
    }

    static func readBounded(
        fileDescriptor: Int32,
        limit: Int,
        onOversized: @Sendable () -> Void
    ) -> BoundedRead {
        defer { close(fileDescriptor) }
        var data = Data()
        var oversized = false
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while true {
            let count = read(fileDescriptor, &buffer, buffer.count)
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                break
            }
            if !oversized, data.count <= limit - count {
                data.append(buffer, count: count)
            } else if !oversized {
                oversized = true
                onOversized()
            }
        }
        return BoundedRead(data: data, oversized: oversized)
    }

    static func countAndDiscard(fileDescriptor: Int32) -> Int {
        defer { close(fileDescriptor) }
        var total = 0
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while true {
            let count = read(fileDescriptor, &buffer, buffer.count)
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                break
            }
            total = min(Int.max - count, total) + count
        }
        return total
    }
}
