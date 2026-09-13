import Darwin
import Foundation

/// Owns exactly one `agy` process group for one refresh. It never attaches to,
/// records, or terminates a process it did not create.
actor AntigravityLocalSession {
    private var pid: pid_t?
    private var processGroupID: pid_t?
    private var masterFD: Int32 = -1
    private var loginEvidence = Data()

    deinit { Self.cleanup(pid: pid, processGroupID: processGroupID, masterFD: masterFD) }

    func start(executable: URL, timeout: TimeInterval) async throws -> [Int] {
        guard pid == nil else { throw AntigravityQuotaClientError.localSessionUnavailable }
        let launched = try launchPTY(executable.path)
        pid = launched.pid
        processGroupID = launched.processGroupID
        masterFD = launched.masterFD
        do {
            let deadline = Date().addingTimeInterval(timeout * 0.45)
            while Date() < deadline {
                try Task.checkCancellation()
                if drainLoginPromptEvidence() { throw AntigravityQuotaClientError.localSessionUnavailable }
                let ports = AntigravityLocalPortDiscovery.ports(ownedBy: launched.pid)
                if !ports.isEmpty { return ports }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            throw AntigravityQuotaClientError.localSessionUnavailable
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        Self.cleanup(pid: pid, processGroupID: processGroupID, masterFD: masterFD)
        self.pid = nil
        processGroupID = nil
        masterFD = -1
        loginEvidence.removeAll(keepingCapacity: false)
    }

    private func launchPTY(_ executable: String) throws -> (pid: pid_t, processGroupID: pid_t, masterFD: Int32) {
        let master = posix_openpt(O_RDWR | O_NOCTTY)
        guard master >= 0, grantpt(master) == 0, unlockpt(master) == 0,
              let slaveName = ptsname(master) else {
            if master >= 0 { close(master) }
            throw AntigravityQuotaClientError.localSessionUnavailable
        }
        let flags = fcntl(master, F_GETFL)
        _ = fcntl(master, F_SETFL, flags | O_NONBLOCK)
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&actions) == 0,
              posix_spawnattr_init(&attributes) == 0 else {
            close(master); throw AntigravityQuotaClientError.localSessionUnavailable
        }
        defer { posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attributes) }
        var defaultSignals = sigset_t()
        sigemptyset(&defaultSignals)
        sigaddset(&defaultSignals, SIGINT)
        sigaddset(&defaultSignals, SIGTERM)
        sigaddset(&defaultSignals, SIGHUP)
        let spawnFlags = POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_CLOEXEC_DEFAULT
        guard posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, slaveName, O_RDWR, 0) == 0,
              posix_spawn_file_actions_adddup2(&actions, STDIN_FILENO, STDOUT_FILENO) == 0,
              posix_spawn_file_actions_adddup2(&actions, STDIN_FILENO, STDERR_FILENO) == 0,
              posix_spawn_file_actions_addclose(&actions, master) == 0,
              posix_spawnattr_setsigdefault(&attributes, &defaultSignals) == 0,
              posix_spawnattr_setflags(&attributes, Int16(spawnFlags)) == 0,
              posix_spawnattr_setpgroup(&attributes, 0) == 0 else {
            close(master); throw AntigravityQuotaClientError.localSessionUnavailable
        }
        var environment = ProcessInfo.processInfo.environment
        environment["PWD"] = FileManager.default.homeDirectoryForCurrentUser.path
        environment["TERM"] = "xterm-256color"
        var environmentPointers = environment.map { key, value in
            strdup("\(key)=\(value)") as UnsafeMutablePointer<CChar>?
        }
        environmentPointers.append(nil)
        defer {
            for pointer in environmentPointers {
                if let pointer { free(pointer) }
            }
        }
        var child: pid_t = 0
        let status: Int32 = executable.withCString { path in
            var argv: [UnsafeMutablePointer<CChar>?] = [strdup(path), nil]
            defer { free(argv[0]) }
            return posix_spawn(&child, path, &actions, &attributes, &argv, &environmentPointers)
        }
        guard status == 0, child > 0 else { close(master); throw AntigravityQuotaClientError.localSessionUnavailable }
        guard AntigravityLocalSessionPolicy.ownsPrivateProcessGroup(rootPID: child, groupPID: getpgid(child)) else {
            close(master)
            Self.terminateRootAndReap(child)
            throw AntigravityQuotaClientError.localSessionUnavailable
        }
        return (child, child, master)
    }

    /// Output is always drained; only a bounded, non-persisted login marker is
    /// inspected so a blocking sign-in can fail as unavailable rather than hang.
    private func drainLoginPromptEvidence() -> Bool {
        guard masterFD >= 0 else { return false }
        var buffer = [UInt8](repeating: 0, count: 512)
        var evidence = Data()
        while true {
            let count = read(masterFD, &buffer, buffer.count)
            if count <= 0 { break }
            evidence.append(buffer, count: count)
            if evidence.count > 1024 { evidence = evidence.suffix(1024) }
        }
        loginEvidence.append(evidence)
        if loginEvidence.count > 1024 { loginEvidence = loginEvidence.suffix(1024) }
        return String(decoding: loginEvidence, as: UTF8.self).localizedCaseInsensitiveContains("select login method")
    }

    private static func cleanup(pid: pid_t?, processGroupID: pid_t?, masterFD: Int32) {
        if masterFD >= 0 { close(masterFD) }
        guard let pid else { return }

        let ownsPrivateGroup = processGroupID == pid && pid > 0
        if ownsPrivateGroup { _ = kill(-pid, SIGTERM) } else { _ = kill(pid, SIGTERM) }

        var status: Int32 = 0
        let initial = waitpid(pid, &status, WNOHANG)
        var rootReaped = initial == pid || (initial == -1 && errno == ECHILD)
        for _ in 0..<12 {
            if !rootReaped {
                let result = waitpid(pid, &status, WNOHANG)
                rootReaped = result == pid || (result == -1 && errno == ECHILD)
            }
            let groupAlive = ownsPrivateGroup && (kill(-pid, 0) == 0 || errno == EPERM)
            if rootReaped && !groupAlive { return }
            usleep(25_000)
        }

        if ownsPrivateGroup { _ = kill(-pid, SIGKILL) } else if !rootReaped { _ = kill(pid, SIGKILL) }
        if !rootReaped {
            while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
        }
    }

    private static func terminateRootAndReap(_ pid: pid_t) {
        _ = kill(pid, SIGKILL)
        var status: Int32 = 0
        while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
    }
}

enum AntigravityLocalPortDiscovery {
    static func valid(port: Int) -> Bool { (1...65_535).contains(port) }

    static func ports(ownedBy rootPID: pid_t) -> [Int] {
        let pids = descendants(of: rootPID) + [rootPID]
        return Array(Set(pids.flatMap { ports(for: $0) })).sorted()
    }

    private static func descendants(of pid: pid_t) -> [pid_t] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else { return [] }
        var processes = [kinfo_proc](repeating: kinfo_proc(), count: size / MemoryLayout<kinfo_proc>.stride)
        guard sysctl(&mib, 4, &processes, &size, nil, 0) == 0 else { return [] }
        var result: [pid_t] = []
        var frontier: Set<pid_t> = [pid]
        while !frontier.isEmpty {
            let children = processes.compactMap { process -> pid_t? in
                process.kp_eproc.e_ppid != 0 && frontier.contains(process.kp_eproc.e_ppid) ? process.kp_proc.p_pid : nil
            }
            frontier = Set(children).subtracting(result)
            result.append(contentsOf: frontier)
        }
        return result
    }

    private static func ports(for pid: pid_t) -> [Int] {
        var byteCount = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard byteCount > 0 else { return [] }
        var descriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(byteCount) / MemoryLayout<proc_fdinfo>.stride)
        byteCount = descriptors.withUnsafeMutableBytes { bytes in
            proc_pidinfo(pid, PROC_PIDLISTFDS, 0, bytes.baseAddress, Int32(bytes.count))
        }
        guard byteCount > 0 else { return [] }
        return descriptors.compactMap { descriptor -> Int? in
            var info = socket_fdinfo()
            let result = withUnsafeMutableBytes(of: &info) { bytes in
                proc_pidfdinfo(pid, descriptor.proc_fd, PROC_PIDFDSOCKETINFO, bytes.baseAddress, Int32(bytes.count))
            }
            guard result == MemoryLayout<socket_fdinfo>.stride,
                  info.psi.soi_kind == SOCKINFO_TCP,
                  info.psi.soi_proto.pri_tcp.tcpsi_state == TCPS_LISTEN else { return nil }
            let port = Int(UInt16(truncatingIfNeeded: info.psi.soi_proto.pri_tcp.tcpsi_ini.insi_lport).bigEndian)
            return valid(port: port) ? port : nil
        }
    }
}

enum AntigravityLocalSessionPolicy {
    static func ownsPrivateProcessGroup(rootPID: pid_t, groupPID: pid_t) -> Bool {
        rootPID > 0 && groupPID == rootPID
    }
}
