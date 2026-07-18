import Foundation

enum PerformanceSampler {
    static func capture(
        now: Date = Date(),
        cachedMemoryFreePercent: Int? = nil,
        refreshMemoryPressure: Bool = true
    ) throws -> PerformanceSample {
        let processOutput = try Shell.run(
            "/bin/ps",
            ["-axo", "pid=,ppid=,%cpu=,rss=,comm="],
            timeout: 2
        )
        let memoryFreePercent: Int?
        if refreshMemoryPressure {
            let memoryOutput = try? Shell.run(
                "/usr/bin/memory_pressure",
                ["-Q"],
                timeout: 2
            )
            memoryFreePercent = memoryOutput.flatMap(parseMemoryFreePercent)
        } else {
            memoryFreePercent = cachedMemoryFreePercent
        }
        return makeSample(
            records: parseProcessList(processOutput),
            memoryFreePercent: memoryFreePercent,
            capturedAt: now
        )
    }

    static func parseProcessList(_ output: String) -> [PerformanceProcessRecord] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            let parts = line.split(
                maxSplits: 4,
                omittingEmptySubsequences: true,
                whereSeparator: \.isWhitespace
            )
            guard parts.count == 5,
                  let pid = Int32(parts[0]),
                  let parentPID = Int32(parts[1]),
                  let cpuPercent = Double(parts[2]),
                  cpuPercent.isFinite,
                  cpuPercent >= 0,
                  let residentKilobytes = UInt64(parts[3]) else {
                return nil
            }
            let (residentBytes, overflow) = residentKilobytes.multipliedReportingOverflow(by: 1_024)
            guard !overflow else {
                return nil
            }
            return PerformanceProcessRecord(
                pid: pid,
                parentPID: parentPID,
                cpuPercent: cpuPercent,
                residentBytes: residentBytes,
                executablePath: String(parts[4])
            )
        }
    }

    static func parseMemoryFreePercent(_ output: String) -> Int? {
        for line in output.split(whereSeparator: \.isNewline) {
            guard line.contains("System-wide memory free percentage:") else {
                continue
            }
            guard let token = line.split(whereSeparator: \.isWhitespace).last,
                  token.last == "%",
                  let value = Int(token.dropLast()),
                  (0...100).contains(value) else {
                return nil
            }
            return value
        }
        return nil
    }

    static func makeSample(
        records: [PerformanceProcessRecord],
        memoryFreePercent: Int?,
        capturedAt: Date
    ) -> PerformanceSample {
        let chatGPTRoots = records.filter {
            $0.executablePath.contains("/ChatGPT.app/")
                || $0.executablePath.contains("/Codex.app/")
        }
        let safariRoots = records.filter {
            $0.executablePath.contains("/Safari.app/")
                || $0.executablePath.contains("/Safari Technology Preview.app/")
        }
        let webKitCandidates = records.filter {
            $0.executablePath.contains("/WebKit.framework/")
                && $0.executablePath.localizedCaseInsensitiveContains("WebContent")
        }
        let windowServerCandidates = records.filter {
            $0.executablePath.hasSuffix("/WindowServer")
        }

        return PerformanceSample(
            capturedAt: capturedAt,
            chatGPT: aggregateProcessTree(
                kind: .chatGPT,
                roots: chatGPTRoots,
                allRecords: records,
                preferredMainSuffix: "/MacOS/ChatGPT"
            ),
            safariHost: aggregateProcessTree(
                kind: .safariHost,
                roots: safariRoots,
                allRecords: records,
                preferredMainSuffix: "/MacOS/Safari"
            ),
            webKitContent: hottestProcess(kind: .webKitContent, candidates: webKitCandidates),
            windowServer: hottestProcess(kind: .windowServer, candidates: windowServerCandidates),
            systemMemoryFreePercent: memoryFreePercent
        )
    }

    private static func aggregateProcessTree(
        kind: PerformanceTargetKind,
        roots: [PerformanceProcessRecord],
        allRecords: [PerformanceProcessRecord],
        preferredMainSuffix: String
    ) -> PerformanceTargetSample {
        guard !roots.isEmpty else {
            return .unavailable(kind)
        }

        var includedPIDs = Set(roots.map(\.pid))
        var changed = true
        while changed {
            changed = false
            for record in allRecords where !includedPIDs.contains(record.pid) {
                if includedPIDs.contains(record.parentPID) {
                    includedPIDs.insert(record.pid)
                    changed = true
                }
            }
        }

        let included = allRecords.filter { includedPIDs.contains($0.pid) }
        let mainPID = included.first { $0.executablePath.hasSuffix(preferredMainSuffix) }?.pid
        return aggregate(kind: kind, records: included, pid: mainPID)
    }

    private static func hottestProcess(
        kind: PerformanceTargetKind,
        candidates: [PerformanceProcessRecord]
    ) -> PerformanceTargetSample {
        guard let hottest = candidates.max(by: { lhs, rhs in
            if lhs.cpuPercent == rhs.cpuPercent {
                return lhs.residentBytes < rhs.residentBytes
            }
            return lhs.cpuPercent < rhs.cpuPercent
        }) else {
            return .unavailable(kind)
        }
        return aggregate(kind: kind, records: [hottest], pid: hottest.pid)
    }

    private static func aggregate(
        kind: PerformanceTargetKind,
        records: [PerformanceProcessRecord],
        pid: Int32?
    ) -> PerformanceTargetSample {
        let cpuPercent = records.reduce(0) { $0 + $1.cpuPercent }
        let residentBytes = records.reduce(UInt64(0)) { partial, record in
            let (sum, overflow) = partial.addingReportingOverflow(record.residentBytes)
            return overflow ? UInt64.max : sum
        }
        return PerformanceTargetSample(
            kind: kind,
            cpuPercent: cpuPercent,
            residentBytes: residentBytes,
            processCount: records.count,
            pid: pid
        )
    }
}

enum PerformanceSnapshotFormatter {
    static func humanLines(for sample: PerformanceSample) -> [String] {
        var lines = [
            line("Codex / ChatGPT", sample.chatGPT),
            line("Safari host", sample.safariHost),
            line("hottest WebKit content (UNVERIFIED owner)", sample.webKitContent),
            line("WindowServer (frame-pressure proxy)", sample.windowServer)
        ]
        if let freePercent = sample.systemMemoryFreePercent {
            lines.append("system memory free=\(freePercent)%")
        } else {
            lines.append("system memory free=UNAVAILABLE")
        }
        lines.append("note: macOS does not expose lightweight cross-application FPS; WindowServer CPU is a proxy, not measured FPS")
        return lines
    }

    private static func line(_ label: String, _ target: PerformanceTargetSample) -> String {
        guard target.processCount > 0 else {
            return "\(label): UNAVAILABLE"
        }
        let pidText = target.pid.map { " pid=\($0)" } ?? ""
        return "\(label): cpu=\(PerformanceFormatting.cpu(target.cpuPercent)) memory=\(PerformanceFormatting.bytes(target.residentBytes)) processes=\(target.processCount)\(pidText)"
    }
}
