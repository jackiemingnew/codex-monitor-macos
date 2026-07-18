import Foundation

enum PerformanceSeverity: Int, Comparable, Sendable {
    case unavailable = 0
    case normal = 1
    case warning = 2
    case critical = 3

    static func < (lhs: PerformanceSeverity, rhs: PerformanceSeverity) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

enum PerformanceTargetKind: String, CaseIterable, Sendable {
    case chatGPT
    case safariHost
    case webKitContent
    case windowServer
}

struct PerformanceProcessRecord: Equatable, Sendable {
    let pid: Int32
    let parentPID: Int32
    let cpuPercent: Double
    let residentBytes: UInt64
    let executablePath: String
}

struct PerformanceTargetSample: Equatable, Sendable {
    let kind: PerformanceTargetKind
    let cpuPercent: Double
    let residentBytes: UInt64
    let processCount: Int
    let pid: Int32?

    static func unavailable(_ kind: PerformanceTargetKind) -> PerformanceTargetSample {
        PerformanceTargetSample(
            kind: kind,
            cpuPercent: 0,
            residentBytes: 0,
            processCount: 0,
            pid: nil
        )
    }
}

struct PerformanceSample: Equatable, Sendable {
    let capturedAt: Date
    let chatGPT: PerformanceTargetSample
    let safariHost: PerformanceTargetSample
    let webKitContent: PerformanceTargetSample
    let windowServer: PerformanceTargetSample
    let systemMemoryFreePercent: Int?

    func target(_ kind: PerformanceTargetKind) -> PerformanceTargetSample {
        switch kind {
        case .chatGPT:
            chatGPT
        case .safariHost:
            safariHost
        case .webKitContent:
            webKitContent
        case .windowServer:
            windowServer
        }
    }
}

struct PerformanceFinding: Identifiable, Equatable, Sendable {
    let id: String
    let severity: PerformanceSeverity
    let title: String
    let detail: String
}

enum PerformanceDiagnostics {
    private static let mebibyte: UInt64 = 1_024 * 1_024
    private static let gibibyte: UInt64 = 1_024 * 1_024 * 1_024

    static func evaluate(_ samples: [PerformanceSample]) -> [PerformanceFinding] {
        guard let latest = samples.last else {
            return []
        }

        let recent = Array(samples.suffix(10))
        var findings: [PerformanceFinding] = []

        appendWebKitFindings(latest: latest, recent: recent, into: &findings)
        appendWindowServerFinding(recent: recent, into: &findings)
        appendApplicationFindings(latest: latest, recent: recent, into: &findings)
        appendSystemMemoryFinding(latest: latest, into: &findings)

        return findings.sorted {
            if $0.severity == $1.severity {
                return $0.id < $1.id
            }
            return $0.severity > $1.severity
        }
    }

    static func overallSeverity(_ findings: [PerformanceFinding], hasSample: Bool) -> PerformanceSeverity {
        guard hasSample else {
            return .unavailable
        }
        return findings.map(\.severity).max() ?? .normal
    }

    private static func appendWebKitFindings(
        latest: PerformanceSample,
        recent: [PerformanceSample],
        into findings: inout [PerformanceFinding]
    ) {
        let current = latest.webKitContent
        guard current.processCount > 0, let pid = current.pid else {
            return
        }

        let sameProcess = recent.filter { $0.webKitContent.pid == pid }
        if sameProcess.count >= 2,
           let first = sameProcess.first {
            let memoryDelta = signedDelta(current.residentBytes, first.webKitContent.residentBytes)
            let elapsed = max(0, latest.capturedAt.timeIntervalSince(first.capturedAt))
            let criticalGrowth = Int64(512 * mebibyte)
            let warningGrowth = Int64(256 * mebibyte)
            if memoryDelta >= criticalGrowth {
                findings.append(PerformanceFinding(
                    id: "webkit-memory-growth",
                    severity: .critical,
                    title: "WebKit 内存快速增长",
                    detail: "PID \(pid) 在 \(Int(elapsed.rounded())) 秒增长 \(PerformanceFormatting.bytes(UInt64(memoryDelta)))；需通过刷新或关闭 Safari 标签验证归属。"
                ))
            } else if memoryDelta >= warningGrowth {
                findings.append(PerformanceFinding(
                    id: "webkit-memory-growth",
                    severity: .warning,
                    title: "WebKit 内存持续增长",
                    detail: "PID \(pid) 在 \(Int(elapsed.rounded())) 秒增长 \(PerformanceFormatting.bytes(UInt64(memoryDelta)))；归属尚未验证。"
                ))
            }

            let averageCPU = average(sameProcess.map { $0.webKitContent.cpuPercent })
            if averageCPU >= 80 {
                findings.append(PerformanceFinding(
                    id: "webkit-cpu",
                    severity: .critical,
                    title: "WebKit 内容进程持续高 CPU",
                    detail: "PID \(pid) 近期平均 \(PerformanceFormatting.cpu(averageCPU))，很可能直接造成页面卡顿。"
                ))
            } else if averageCPU >= 40 {
                findings.append(PerformanceFinding(
                    id: "webkit-cpu",
                    severity: .warning,
                    title: "WebKit 内容进程 CPU 偏高",
                    detail: "PID \(pid) 近期平均 \(PerformanceFormatting.cpu(averageCPU))。"
                ))
            }
        }

        if current.residentBytes >= 3 * gibibyte {
            findings.append(PerformanceFinding(
                id: "webkit-memory-current",
                severity: .critical,
                title: "WebKit 单进程内存过高",
                detail: "PID \(pid) 当前占用 \(PerformanceFormatting.bytes(current.residentBytes))；这是跨应用 WebKit 候选，不能自动断言属于当前 Safari 标签。"
            ))
        } else if current.residentBytes >= 1_536 * mebibyte {
            findings.append(PerformanceFinding(
                id: "webkit-memory-current",
                severity: .warning,
                title: "WebKit 单进程内存偏高",
                detail: "PID \(pid) 当前占用 \(PerformanceFormatting.bytes(current.residentBytes))。"
            ))
        }
    }

    private static func appendWindowServerFinding(
        recent: [PerformanceSample],
        into findings: inout [PerformanceFinding]
    ) {
        let available = recent.map(\.windowServer).filter { $0.processCount > 0 }
        guard available.count >= 2 else {
            return
        }
        let averageCPU = average(available.map(\.cpuPercent))
        if averageCPU >= 80 {
            findings.append(PerformanceFinding(
                id: "windowserver-cpu",
                severity: .critical,
                title: "窗口合成压力很高",
                detail: "WindowServer 近期平均 \(PerformanceFormatting.cpu(averageCPU))；它是掉帧风险代理，不是应用真实 FPS。"
            ))
        } else if averageCPU >= 40 {
            findings.append(PerformanceFinding(
                id: "windowserver-cpu",
                severity: .warning,
                title: "窗口合成压力偏高",
                detail: "WindowServer 近期平均 \(PerformanceFormatting.cpu(averageCPU))；可能伴随滚动或动画不流畅。"
            ))
        }
    }

    private static func appendApplicationFindings(
        latest: PerformanceSample,
        recent: [PerformanceSample],
        into findings: inout [PerformanceFinding]
    ) {
        let chatGPT = latest.chatGPT
        if chatGPT.residentBytes >= 8 * gibibyte {
            findings.append(PerformanceFinding(
                id: "chatgpt-memory",
                severity: .critical,
                title: "Codex / ChatGPT 进程组内存过高",
                detail: "当前合计 \(PerformanceFormatting.bytes(chatGPT.residentBytes))，包含应用内辅助进程和其后代。"
            ))
        } else if chatGPT.residentBytes >= 4 * gibibyte {
            findings.append(PerformanceFinding(
                id: "chatgpt-memory",
                severity: .warning,
                title: "Codex / ChatGPT 进程组内存偏高",
                detail: "当前合计 \(PerformanceFormatting.bytes(chatGPT.residentBytes))。"
            ))
        }

        appendCPUFinding(
            id: "chatgpt-cpu",
            title: "Codex / ChatGPT",
            values: recent.map(\.chatGPT).filter { $0.processCount > 0 }.map(\.cpuPercent),
            into: &findings
        )
        appendCPUFinding(
            id: "safari-host-cpu",
            title: "Safari 主进程组",
            values: recent.map(\.safariHost).filter { $0.processCount > 0 }.map(\.cpuPercent),
            into: &findings
        )
    }

    private static func appendCPUFinding(
        id: String,
        title: String,
        values: [Double],
        into findings: inout [PerformanceFinding]
    ) {
        guard values.count >= 2 else {
            return
        }
        let averageCPU = average(values)
        if averageCPU >= 80 {
            findings.append(PerformanceFinding(
                id: id,
                severity: .critical,
                title: "\(title) 持续高 CPU",
                detail: "近期平均 \(PerformanceFormatting.cpu(averageCPU))。"
            ))
        } else if averageCPU >= 40 {
            findings.append(PerformanceFinding(
                id: id,
                severity: .warning,
                title: "\(title) CPU 偏高",
                detail: "近期平均 \(PerformanceFormatting.cpu(averageCPU))。"
            ))
        }
    }

    private static func appendSystemMemoryFinding(
        latest: PerformanceSample,
        into findings: inout [PerformanceFinding]
    ) {
        guard let freePercent = latest.systemMemoryFreePercent else {
            return
        }
        if freePercent <= 10 {
            findings.append(PerformanceFinding(
                id: "system-memory",
                severity: .critical,
                title: "系统内存压力很高",
                detail: "memory_pressure 报告可用比例仅 \(freePercent)%。"
            ))
        } else if freePercent <= 20 {
            findings.append(PerformanceFinding(
                id: "system-memory",
                severity: .warning,
                title: "系统内存压力升高",
                detail: "memory_pressure 报告可用比例为 \(freePercent)%。"
            ))
        }
    }

    private static func signedDelta(_ lhs: UInt64, _ rhs: UInt64) -> Int64 {
        if lhs >= rhs {
            return Int64(min(lhs - rhs, UInt64(Int64.max)))
        }
        return -Int64(min(rhs - lhs, UInt64(Int64.max)))
    }

    private static func average(_ values: [Double]) -> Double {
        guard !values.isEmpty else {
            return 0
        }
        return values.reduce(0, +) / Double(values.count)
    }
}

enum PerformanceFormatting {
    static func cpu(_ value: Double) -> String {
        String(format: "%.1f%%", value)
    }

    static func bytes(_ value: UInt64) -> String {
        let gibibyte = 1_024.0 * 1_024.0 * 1_024.0
        let mebibyte = 1_024.0 * 1_024.0
        if Double(value) >= gibibyte {
            return String(format: "%.2f GB", Double(value) / gibibyte)
        }
        return String(format: "%.0f MB", Double(value) / mebibyte)
    }
}
