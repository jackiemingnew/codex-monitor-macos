import Foundation

enum TaskBadgeFormatter {
    static func subagentBadgeText(for count: Int) -> String? {
        count > 0 ? "子代理 \(count)" : nil
    }
}

enum SnapshotOutputFormatter {
    static func humanLines(for snapshot: UsageSnapshot, taskLimit: Int = 4) -> [String] {
        var lines = [
            "primary=\(Formatters.percent(snapshot.primaryPercent)) secondary=\(Formatters.percent(snapshot.secondaryPercent)) running=\(snapshot.isRunning)",
            "cumulative active=\(snapshot.cumulativeUsage.activeTokens) archived=\(snapshot.cumulativeUsage.archivedTokens) all=\(snapshot.cumulativeUsage.allTokens)",
            "recent20d active=\(snapshot.recentUsage.usage20dActiveTokens) archived=\(snapshot.recentUsage.usage20dArchivedTokens) all=\(snapshot.recentUsage.usage20dAllTokens)",
            "daily today=\(snapshot.dailyUsage.usageTodayTokens) partial=\(snapshot.dailyUsage.isPartial) missing=\(snapshot.dailyUsage.missingBaselineSessions)",
            "usage1h=\(optionalInt(snapshot.usage1h)) usage24h=\(snapshot.usage24h) usage7d=\(snapshot.usage7d) usage30d=\(snapshot.usage30d) source=swift-delta-cache",
            "spark=\(snapshot.sparkQuotaWindows.map { "\($0.label)=\($0.remainingText)" }.joined(separator: ","))",
            "monitor snapshot_ms=\(optionalInt(snapshot.monitorStats.lastSnapshotDurationMs)) usage_ms=\(optionalInt(snapshot.monitorStats.lastUsageDurationMs)) delta_ms=\(optionalInt(snapshot.monitorStats.lastDeltaDurationMs)) rate=\(snapshot.monitorStats.lastRateLimitSource) watched=\(snapshot.monitorStats.watchedPathCount) context_scans=\(snapshot.monitorStats.jsonlContextScans) model_tokens=\(snapshot.monitorStats.monitorModelTokens)"
        ]

        for task in snapshot.tasks.prefix(taskLimit) {
            lines.append(
                "task=\(task.status.label) \(task.title) \(task.tokenCount) "
                    + "delta1h=\(Formatters.signedCompactTokens(task.delta1hTokens)) "
                    + "today=\(Formatters.compactTokensWithShare(tokens: task.todayTokens, sharePercent: task.todaySharePercent)) "
                    + "ctx=\(Formatters.compactTokenRatio(task.contextInputTokens, task.contextWindowTokens))"
            )
        }

        if let error = snapshot.errorMessage {
            lines.append("error=\(error)")
        }

        return lines
    }

    static func jsonData(for snapshot: UsageSnapshot, taskLimit: Int = 4) -> Data {
        let payload = SnapshotJSON(
            primaryPercent: snapshot.primaryPercent,
            secondaryPercent: snapshot.secondaryPercent,
            primaryResetsAt: snapshot.primaryResetsAt,
            secondaryResetsAt: snapshot.secondaryResetsAt,
            running: snapshot.isRunning,
            cumulativeUsage: SnapshotCumulativeUsageJSON(usage: snapshot.cumulativeUsage),
            recentUsage: SnapshotRecentUsageJSON(usage: snapshot.recentUsage),
            dailyUsage: SnapshotDailyUsageJSON(usage: snapshot.dailyUsage),
            usage1h: snapshot.usage1h,
            usage24h: snapshot.usage24h,
            usage7d: snapshot.usage7d,
            usage30d: snapshot.usage30d,
            periodUsageQuality: SnapshotPeriodUsageQualityJSON(quality: snapshot.periodUsageQuality),
            sparkQuotaWindows: snapshot.sparkQuotaWindows.map(SnapshotSparkQuotaWindowJSON.init(window:)),
            lastUpdated: ISO8601DateFormatter().string(from: snapshot.lastUpdated),
            error: snapshot.errorMessage,
            monitor: SnapshotMonitorJSON(stats: snapshot.monitorStats),
            tasks: snapshot.tasks.prefix(taskLimit).map(SnapshotTaskJSON.init(task:))
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(payload)) ?? Data(#"{"error":"Unable to encode snapshot"}"#.utf8)
    }

    static func nodeCompatibleHumanLines(for snapshot: UsageSnapshot, taskLimit: Int = 12) -> [String] {
        var lines = [
            "quota: 5h=\(Formatters.percent(snapshot.primaryPercent)) 7d=\(Formatters.percent(snapshot.secondaryPercent)) source=\(snapshot.monitorStats.lastRateLimitSource)",
            "cumulative: active=\(Formatters.compactTokensEnglish(snapshot.cumulativeUsage.activeTokens)) archived=\(Formatters.compactTokensEnglish(snapshot.cumulativeUsage.archivedTokens)) all=\(Formatters.compactTokensEnglish(snapshot.cumulativeUsage.allTokens)) source=native-state",
            "recent20d: active=\(Formatters.compactTokensEnglish(snapshot.recentUsage.usage20dActiveTokens)) archived=\(Formatters.compactTokensEnglish(snapshot.recentUsage.usage20dArchivedTokens)) all=\(Formatters.compactTokensEnglish(snapshot.recentUsage.usage20dAllTokens)) source=native-state",
            "daily: today=\(Formatters.compactTokensEnglish(snapshot.dailyUsage.usageTodayTokens)) source=swift-delta-cache",
            "usage: 24h=\(Formatters.compactTokensEnglish(snapshot.usage24h)) 7d=\(Formatters.compactTokensEnglish(snapshot.usage7d)) 30d=\(Formatters.compactTokensEnglish(snapshot.usage30d)) source=swift-delta-cache",
            "active: running=\(snapshot.tasks.filter { $0.status == .running }.count) threads=\(snapshot.tasks.count) subagents=\(snapshot.tasks.map(\.activeSubagentCount).reduce(0, +))"
        ]
        lines.append(contentsOf: snapshot.tasks.prefix(taskLimit).map { task in
            "\(String(task.id.prefix(8))) \(task.status.rawValue) \(Formatters.compactTokensEnglish(task.tokenCount)) \(task.title)"
        })
        if let error = snapshot.errorMessage {
            lines.append("error: \(error)")
        }
        return lines
    }

    static func nodeCompatibleJSONData(
        for snapshot: UsageSnapshot,
        options: NodeCompatibleSnapshotOptions
    ) -> Data {
        let payload = NodeCompatibleSnapshotJSON(snapshot: snapshot, options: options)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(payload)) ?? Data(#"{"error":"Unable to encode node-compatible snapshot"}"#.utf8)
    }

    private static func optionalInt(_ value: Int?) -> String {
        value.map(String.init) ?? "--"
    }
}

struct NodeCompatibleSnapshotOptions {
    let includeArchived: Bool
    let taskLimit: Int
    let tailBytes: Int
    let logScanLimit: Int
    let remoteEnabled: Bool
    let codexDirectory: URL
    let stateDatabase: String
    let logsDatabase: String
    let deltaDatabase: String
}

private struct NodeCompatibleSnapshotJSON: Encodable {
    let generatedAt: String
    let mode: NodeCompatibleModeJSON
    let sources: [NodeCompatibleSourceJSON]
    let rateLimits: NodeCompatibleRateLimitsJSON
    let sparkQuotaWindows: [NodeCompatibleSparkQuotaWindowJSON]
    let cumulativeUsage: NodeCompatibleCumulativeUsageJSON
    let recentUsage: NodeCompatibleRecentUsageJSON
    let dailyUsage: NodeCompatibleDailyUsageJSON
    let periodUsage: NodeCompatiblePeriodUsageJSON
    let active: NodeCompatibleActiveJSON
    let deltaUsage: NodeCompatibleDeltaUsageJSON
    let tasks: [NodeCompatibleTaskJSON]
    let remoteMonitors: NodeCompatibleRemoteMonitorsJSON

    init(snapshot: UsageSnapshot, options: NodeCompatibleSnapshotOptions) {
        self.generatedAt = ISO8601DateFormatter().string(from: snapshot.lastUpdated)
        self.mode = NodeCompatibleModeJSON(options: options)
        self.sources = NodeCompatibleSourceJSON.sources(options: options)
        self.rateLimits = NodeCompatibleRateLimitsJSON(snapshot: snapshot)
        self.sparkQuotaWindows = snapshot.sparkQuotaWindows.map(NodeCompatibleSparkQuotaWindowJSON.init(window:))
        self.cumulativeUsage = NodeCompatibleCumulativeUsageJSON(usage: snapshot.cumulativeUsage)
        self.recentUsage = NodeCompatibleRecentUsageJSON(usage: snapshot.recentUsage)
        self.dailyUsage = NodeCompatibleDailyUsageJSON(usage: snapshot.dailyUsage)
        self.periodUsage = NodeCompatiblePeriodUsageJSON(snapshot: snapshot, options: options)
        self.active = NodeCompatibleActiveJSON(snapshot: snapshot)
        self.deltaUsage = NodeCompatibleDeltaUsageJSON(snapshot: snapshot)
        self.tasks = snapshot.tasks.prefix(options.taskLimit).map(NodeCompatibleTaskJSON.init(task:))
        self.remoteMonitors = NodeCompatibleRemoteMonitorsJSON.disabled
    }

    enum CodingKeys: String, CodingKey {
        case generatedAt
        case mode
        case sources
        case rateLimits
        case sparkQuotaWindows
        case cumulativeUsage
        case recentUsage
        case dailyUsage
        case periodUsage
        case active
        case deltaUsage
        case tasks
        case remoteMonitors
    }
}

private struct NodeCompatibleModeJSON: Encodable {
    let includeArchived: Bool
    let taskLimit: Int
    let tailBytes: Int
    let logScanLimit: Int
    let remoteEnabled: Bool

    init(options: NodeCompatibleSnapshotOptions) {
        self.includeArchived = options.includeArchived
        self.taskLimit = options.taskLimit
        self.tailBytes = options.tailBytes
        self.logScanLimit = options.logScanLimit
        self.remoteEnabled = options.remoteEnabled
    }
}

private struct NodeCompatibleSourceJSON: Encodable {
    let source: String
    let path: String
    let readable: Bool
    let sizeBytes: UInt64
    let itemCount: Int
    let latestMtimeMs: Int64

    static func sources(options: NodeCompatibleSnapshotOptions) -> [NodeCompatibleSourceJSON] {
        [
            file(source: "state", path: options.stateDatabase),
            file(source: "logs", path: options.logsDatabase),
            directory(source: "sessions", path: options.codexDirectory.appendingPathComponent("sessions").path),
            directory(source: "archived_sessions", path: options.codexDirectory.appendingPathComponent("archived_sessions").path),
            file(source: "swift_delta_cache", path: options.deltaDatabase)
        ]
    }

    private static func file(source: String, path: String) -> NodeCompatibleSourceJSON {
        let attributes = (try? FileManager.default.attributesOfItem(atPath: path)) ?? [:]
        let modifiedAt = attributes[.modificationDate] as? Date
        return NodeCompatibleSourceJSON(
            source: source,
            path: path,
            readable: FileManager.default.isReadableFile(atPath: path),
            sizeBytes: (attributes[.size] as? NSNumber)?.uint64Value ?? 0,
            itemCount: 1,
            latestMtimeMs: modifiedAt.map { Int64(($0.timeIntervalSince1970 * 1_000).rounded()) } ?? 0
        )
    }

    private static func directory(source: String, path: String) -> NodeCompatibleSourceJSON {
        let attributes = (try? FileManager.default.attributesOfItem(atPath: path)) ?? [:]
        let modifiedAt = attributes[.modificationDate] as? Date
        return NodeCompatibleSourceJSON(
            source: source,
            path: path,
            readable: FileManager.default.isReadableFile(atPath: path),
            sizeBytes: 0,
            itemCount: 0,
            latestMtimeMs: modifiedAt.map { Int64(($0.timeIntervalSince1970 * 1_000).rounded()) } ?? 0
        )
    }
}

private struct NodeCompatibleRateLimitsJSON: Encodable {
    let source: String
    let limitId: String
    let primary: NodeCompatibleRateLimitWindowJSON?
    let secondary: NodeCompatibleRateLimitWindowJSON?
    let capturedAt: String
    let capturedAtMs: Int64
    let ok: Bool

    init(snapshot: UsageSnapshot) {
        self.source = snapshot.monitorStats.lastRateLimitSource
        self.limitId = "codex"
        self.primary = NodeCompatibleRateLimitWindowJSON(remainingPercent: snapshot.primaryPercent, resetsAt: snapshot.primaryResetsAt)
        self.secondary = NodeCompatibleRateLimitWindowJSON(remainingPercent: snapshot.secondaryPercent, resetsAt: snapshot.secondaryResetsAt)
        self.capturedAt = ISO8601DateFormatter().string(from: snapshot.lastUpdated)
        self.capturedAtMs = Int64((snapshot.lastUpdated.timeIntervalSince1970 * 1_000).rounded())
        self.ok = snapshot.primaryPercent != nil || snapshot.secondaryPercent != nil
    }
}

private struct NodeCompatibleSparkQuotaWindowJSON: Encodable {
    let id: String
    let label: String
    let remainingPercent: Int?
    let usedPercent: Double?
    let resetAt: Int?
    let resetText: String?

    init(window: SparkQuotaWindow) {
        self.id = window.id
        self.label = window.label
        self.remainingPercent = window.remainingPercent
        self.usedPercent = window.usedPercent
        self.resetAt = window.resetAt
        self.resetText = window.resetText
    }

    enum CodingKeys: String, CodingKey {
        case id
        case label
        case remainingPercent = "remaining_percent"
        case usedPercent = "used_percent"
        case resetAt = "reset_at"
        case resetText = "reset_text"
    }
}

private struct NodeCompatibleRateLimitWindowJSON: Encodable {
    let usedPercent: Int?
    let remainingPercent: Int?
    let resetsAt: Int?

    init(remainingPercent: Int?, resetsAt: Int?) {
        self.remainingPercent = remainingPercent
        self.usedPercent = remainingPercent.map { min(100, max(0, 100 - $0)) }
        self.resetsAt = resetsAt
    }
}

private struct NodeCompatibleCumulativeUsageJSON: Encodable {
    let activeTokens: Int
    let archivedTokens: Int
    let allTokens: Int
    let activeSessions: Int
    let archivedSessions: Int
    let allSessions: Int
    let defaultScope: String
    let source: String
    let metricId: String

    init(usage: CumulativeUsage) {
        self.activeTokens = usage.activeTokens
        self.archivedTokens = usage.archivedTokens
        self.allTokens = usage.allTokens
        self.activeSessions = usage.activeSessions
        self.archivedSessions = usage.archivedSessions
        self.allSessions = usage.allSessions
        self.defaultScope = "active"
        self.source = "native-state"
        self.metricId = "cumulative.active_tokens"
    }
}

private struct NodeCompatibleRecentUsageJSON: Encodable {
    let usage20dActiveTokens: Int
    let usage20dArchivedTokens: Int
    let usage20dAllTokens: Int
    let usage20dActiveSessions: Int
    let usage20dArchivedSessions: Int
    let usage20dAllSessions: Int
    let windowDays: Int
    let source: String
    let metricId: String

    init(usage: RecentUsage) {
        self.usage20dActiveTokens = usage.usage20dActiveTokens
        self.usage20dArchivedTokens = usage.usage20dArchivedTokens
        self.usage20dAllTokens = usage.usage20dAllTokens
        self.usage20dActiveSessions = usage.usage20dActiveSessions
        self.usage20dArchivedSessions = usage.usage20dArchivedSessions
        self.usage20dAllSessions = usage.usage20dAllSessions
        self.windowDays = usage.windowDays
        self.source = "native-state"
        self.metricId = "recent.usage_20d_all_tokens"
    }
}

private struct NodeCompatibleDailyUsageJSON: Encodable {
    let usageTodayTokens: Int
    let dayStartedAt: String
    let dayStartedAtMs: Int64
    let timeZoneIdentifier: String
    let isPartial: Bool
    let missingBaselineSessions: Int
    let source: String
    let metricId: String

    init(usage: DailyUsage) {
        self.usageTodayTokens = usage.usageTodayTokens
        self.dayStartedAt = ISO8601DateFormatter().string(from: usage.dayStartedAt)
        self.dayStartedAtMs = Int64((usage.dayStartedAt.timeIntervalSince1970 * 1_000).rounded())
        self.timeZoneIdentifier = usage.timeZoneIdentifier
        self.isPartial = usage.isPartial
        self.missingBaselineSessions = usage.missingBaselineSessions
        self.source = "swift-delta-cache"
        self.metricId = "daily.usage_today_tokens"
    }
}

private struct NodeCompatiblePeriodUsageJSON: Encodable {
    let usage24h: Int
    let usage7d: Int
    let usage30d: Int
    let isPartial: Bool
    let missing24hBaselines: Int
    let missing7dBaselines: Int
    let missing30dBaselines: Int
    let logs: NodeCompatiblePeriodUsageDetailJSON
    let rollouts: NodeCompatiblePeriodUsageDetailJSON
    let source: String
    let logScanLimit: Int
    let tailBytes: Int

    init(snapshot: UsageSnapshot, options: NodeCompatibleSnapshotOptions) {
        self.usage24h = snapshot.usage24h
        self.usage7d = snapshot.usage7d
        self.usage30d = snapshot.usage30d
        self.isPartial = snapshot.periodUsageQuality.usage24hPartial
            || snapshot.periodUsageQuality.usage7dPartial
            || snapshot.periodUsageQuality.usage30dPartial
        self.missing24hBaselines = snapshot.periodUsageQuality.missing24hBaselines
        self.missing7dBaselines = snapshot.periodUsageQuality.missing7dBaselines
        self.missing30dBaselines = snapshot.periodUsageQuality.missing30dBaselines
        self.logs = NodeCompatiblePeriodUsageDetailJSON.zero
        self.rollouts = NodeCompatiblePeriodUsageDetailJSON(
            usage24h: snapshot.usage24h,
            usage7d: snapshot.usage7d,
            usage30d: snapshot.usage30d
        )
        self.source = "swift-delta-cache"
        self.logScanLimit = options.logScanLimit
        self.tailBytes = options.tailBytes
    }
}

private struct NodeCompatiblePeriodUsageDetailJSON: Encodable {
    let usage24h: Int
    let usage7d: Int
    let usage30d: Int

    static let zero = NodeCompatiblePeriodUsageDetailJSON(usage24h: 0, usage7d: 0, usage30d: 0)
}

private struct NodeCompatibleActiveJSON: Encodable {
    let runningTasks: Int
    let activeThreads: Int
    let activeSubagents: Int
    let activeSubagentTokens: Int?
    let maxSubagentsOnThread: Int

    init(snapshot: UsageSnapshot) {
        self.runningTasks = snapshot.tasks.filter { $0.status == .running }.count
        self.activeThreads = self.runningTasks
        self.activeSubagents = snapshot.tasks.map(\.activeSubagentCount).reduce(0, +)
        self.activeSubagentTokens = nil
        self.maxSubagentsOnThread = snapshot.tasks.map(\.activeSubagentCount).max() ?? 0
    }
}

private struct NodeCompatibleDeltaUsageJSON: Encodable {
    let delta10mTokens: Int?
    let delta1hTokens: Int?
    let known10m: Int
    let known1h: Int
    let total: Int

    init(snapshot: UsageSnapshot) {
        let delta10mValues = snapshot.tasks.compactMap(\.delta10mTokens)
        let delta1hValues = snapshot.tasks.compactMap(\.delta1hTokens)
        self.delta10mTokens = delta10mValues.isEmpty ? nil : delta10mValues.reduce(0, +)
        self.delta1hTokens = snapshot.usage1h ?? (delta1hValues.isEmpty ? nil : delta1hValues.reduce(0, +))
        self.known10m = delta10mValues.count
        self.known1h = delta1hValues.count
        self.total = snapshot.tasks.count
    }
}

private struct NodeCompatibleTaskJSON: Encodable {
    let id: String
    let shortId: String
    let title: String
    let cwd: String
    let model: String
    let archived: Bool
    let rolloutPath: String
    let updated: String
    let updatedAtMs: Int64
    let tokensUsed: Int
    let latestTokenTotal: Int
    let isSubagent: Bool
    let parentThreadId: String
    let isRunning: Bool
    let subagentCount: Int
    let activeSubagentCount: Int
    let subagentTokens: Int
    let totalWithSubagents: Int
    let status: String
    let statusLabel: String
    let delta10mTokens: Int?
    let delta1hTokens: Int?
    let todayTokens: Int?
    let todaySharePercent: Double?
    let contextInputTokens: Int?
    let contextWindowTokens: Int?
    let contextPercent: Double?
    let contextUpdatedAt: String?

    init(task: CodexTask) {
        self.id = task.id
        self.shortId = String(task.id.prefix(8))
        self.title = task.title
        self.cwd = ""
        self.model = ""
        self.archived = false
        self.rolloutPath = ""
        self.updated = ISO8601DateFormatter().string(from: task.updatedAt)
        self.updatedAtMs = Int64((task.updatedAt.timeIntervalSince1970 * 1_000).rounded())
        self.tokensUsed = task.tokenCount
        self.latestTokenTotal = task.tokenCount
        self.isSubagent = false
        self.parentThreadId = ""
        self.isRunning = task.status == .running
        self.subagentCount = task.activeSubagentCount
        self.activeSubagentCount = task.activeSubagentCount
        self.subagentTokens = 0
        self.totalWithSubagents = task.tokenCount
        self.status = task.status.rawValue
        self.statusLabel = task.status.label
        self.delta10mTokens = task.delta10mTokens
        self.delta1hTokens = task.delta1hTokens
        self.todayTokens = task.todayTokens
        self.todaySharePercent = task.todaySharePercent
        self.contextInputTokens = task.contextInputTokens
        self.contextWindowTokens = task.contextWindowTokens
        self.contextPercent = task.contextPercent
        self.contextUpdatedAt = task.contextUpdatedAt.map { ISO8601DateFormatter().string(from: $0) }
    }
}

private struct NodeCompatibleRemoteMonitorsJSON: Encodable {
    let cliProxy: NodeCompatibleRemoteMonitorJSON
    let newAPI: NodeCompatibleRemoteMonitorJSON
    let sub2API: NodeCompatibleRemoteMonitorJSON

    static let disabled = NodeCompatibleRemoteMonitorsJSON(
        cliProxy: NodeCompatibleRemoteMonitorJSON(source: "CLIProxyAPI", state: "disabled", message: "remote checks disabled"),
        newAPI: NodeCompatibleRemoteMonitorJSON(source: "NewAPI", state: "disabled", message: "remote checks disabled"),
        sub2API: NodeCompatibleRemoteMonitorJSON(source: "Sub2API", state: "disabled", message: "remote checks disabled")
    )
}

private struct NodeCompatibleRemoteMonitorJSON: Encodable {
    let source: String
    let state: String
    let message: String
}

private struct SnapshotJSON: Encodable {
    let primaryPercent: Int?
    let secondaryPercent: Int?
    let primaryResetsAt: Int?
    let secondaryResetsAt: Int?
    let running: Bool
    let cumulativeUsage: SnapshotCumulativeUsageJSON
    let recentUsage: SnapshotRecentUsageJSON
    let dailyUsage: SnapshotDailyUsageJSON
    let usage1h: Int?
    let usage24h: Int
    let usage7d: Int
    let usage30d: Int
    let periodUsageQuality: SnapshotPeriodUsageQualityJSON
    let sparkQuotaWindows: [SnapshotSparkQuotaWindowJSON]
    let lastUpdated: String
    let error: String?
    let monitor: SnapshotMonitorJSON
    let tasks: [SnapshotTaskJSON]

    enum CodingKeys: String, CodingKey {
        case primaryPercent = "primary_percent"
        case secondaryPercent = "secondary_percent"
        case primaryResetsAt = "primary_reset_at"
        case secondaryResetsAt = "secondary_reset_at"
        case running
        case cumulativeUsage = "cumulative_usage"
        case recentUsage = "recent_usage"
        case dailyUsage = "daily_usage"
        case usage1h = "usage_1h"
        case usage24h = "usage_24h"
        case usage7d = "usage_7d"
        case usage30d = "usage_30d"
        case periodUsageQuality = "period_usage_quality"
        case sparkQuotaWindows = "spark_quota_windows"
        case lastUpdated = "last_updated"
        case error
        case monitor
        case tasks
    }
}

private struct SnapshotCumulativeUsageJSON: Encodable {
    let activeTokens: Int
    let archivedTokens: Int
    let allTokens: Int
    let activeSessions: Int
    let archivedSessions: Int
    let allSessions: Int
    let defaultScope: String
    let source: String
    let metricId: String

    init(usage: CumulativeUsage) {
        self.activeTokens = usage.activeTokens
        self.archivedTokens = usage.archivedTokens
        self.allTokens = usage.allTokens
        self.activeSessions = usage.activeSessions
        self.archivedSessions = usage.archivedSessions
        self.allSessions = usage.allSessions
        self.defaultScope = "active"
        self.source = "native-state"
        self.metricId = "cumulative.active_tokens"
    }

    enum CodingKeys: String, CodingKey {
        case activeTokens = "active_tokens"
        case archivedTokens = "archived_tokens"
        case allTokens = "all_tokens"
        case activeSessions = "active_sessions"
        case archivedSessions = "archived_sessions"
        case allSessions = "all_sessions"
        case defaultScope = "default_scope"
        case source
        case metricId = "metric_id"
    }
}

private struct SnapshotRecentUsageJSON: Encodable {
    let usage20dActiveTokens: Int
    let usage20dArchivedTokens: Int
    let usage20dAllTokens: Int
    let usage20dActiveSessions: Int
    let usage20dArchivedSessions: Int
    let usage20dAllSessions: Int
    let windowDays: Int
    let source: String
    let metricId: String

    init(usage: RecentUsage) {
        self.usage20dActiveTokens = usage.usage20dActiveTokens
        self.usage20dArchivedTokens = usage.usage20dArchivedTokens
        self.usage20dAllTokens = usage.usage20dAllTokens
        self.usage20dActiveSessions = usage.usage20dActiveSessions
        self.usage20dArchivedSessions = usage.usage20dArchivedSessions
        self.usage20dAllSessions = usage.usage20dAllSessions
        self.windowDays = usage.windowDays
        self.source = "native-state"
        self.metricId = "recent.usage_20d_all_tokens"
    }

    enum CodingKeys: String, CodingKey {
        case usage20dActiveTokens = "usage_20d_active_tokens"
        case usage20dArchivedTokens = "usage_20d_archived_tokens"
        case usage20dAllTokens = "usage_20d_all_tokens"
        case usage20dActiveSessions = "usage_20d_active_sessions"
        case usage20dArchivedSessions = "usage_20d_archived_sessions"
        case usage20dAllSessions = "usage_20d_all_sessions"
        case windowDays = "window_days"
        case source
        case metricId = "metric_id"
    }
}

private struct SnapshotDailyUsageJSON: Encodable {
    let usageTodayTokens: Int
    let dayStartedAt: String
    let dayStartedAtMs: Int64
    let timeZoneIdentifier: String
    let isPartial: Bool
    let missingBaselineSessions: Int
    let source: String
    let metricId: String

    init(usage: DailyUsage) {
        self.usageTodayTokens = usage.usageTodayTokens
        self.dayStartedAt = ISO8601DateFormatter().string(from: usage.dayStartedAt)
        self.dayStartedAtMs = Int64((usage.dayStartedAt.timeIntervalSince1970 * 1_000).rounded())
        self.timeZoneIdentifier = usage.timeZoneIdentifier
        self.isPartial = usage.isPartial
        self.missingBaselineSessions = usage.missingBaselineSessions
        self.source = "swift-delta-cache"
        self.metricId = "daily.usage_today_tokens"
    }

    enum CodingKeys: String, CodingKey {
        case usageTodayTokens = "usage_today_tokens"
        case dayStartedAt = "day_started_at"
        case dayStartedAtMs = "day_started_at_ms"
        case timeZoneIdentifier = "time_zone"
        case isPartial = "is_partial"
        case missingBaselineSessions = "missing_baseline_sessions"
        case source
        case metricId = "metric_id"
    }
}

private struct SnapshotPeriodUsageQualityJSON: Encodable {
    let usage24hPartial: Bool
    let usage7dPartial: Bool
    let usage30dPartial: Bool
    let missing24hBaselines: Int
    let missing7dBaselines: Int
    let missing30dBaselines: Int
    let source: String

    init(quality: PeriodUsageQuality) {
        self.usage24hPartial = quality.usage24hPartial
        self.usage7dPartial = quality.usage7dPartial
        self.usage30dPartial = quality.usage30dPartial
        self.missing24hBaselines = quality.missing24hBaselines
        self.missing7dBaselines = quality.missing7dBaselines
        self.missing30dBaselines = quality.missing30dBaselines
        self.source = "swift-delta-cache"
    }

    enum CodingKeys: String, CodingKey {
        case usage24hPartial = "usage_24h_partial"
        case usage7dPartial = "usage_7d_partial"
        case usage30dPartial = "usage_30d_partial"
        case missing24hBaselines = "missing_24h_baselines"
        case missing7dBaselines = "missing_7d_baselines"
        case missing30dBaselines = "missing_30d_baselines"
        case source
    }
}

private struct SnapshotMonitorJSON: Encodable {
    let lastSnapshotDurationMs: Int?
    let lastUsageDurationMs: Int?
    let lastDeltaDurationMs: Int?
    let lastRateLimitSource: String
    let watchedPathCount: Int
    let jsonlContextScans: Int
    let monitorModelTokens: Int

    init(stats: MonitorPerformanceStats) {
        self.lastSnapshotDurationMs = stats.lastSnapshotDurationMs
        self.lastUsageDurationMs = stats.lastUsageDurationMs
        self.lastDeltaDurationMs = stats.lastDeltaDurationMs
        self.lastRateLimitSource = stats.lastRateLimitSource
        self.watchedPathCount = stats.watchedPathCount
        self.jsonlContextScans = stats.jsonlContextScans
        self.monitorModelTokens = stats.monitorModelTokens
    }

    enum CodingKeys: String, CodingKey {
        case lastSnapshotDurationMs = "last_snapshot_duration_ms"
        case lastUsageDurationMs = "last_usage_duration_ms"
        case lastDeltaDurationMs = "last_delta_duration_ms"
        case lastRateLimitSource = "last_rate_limit_source"
        case watchedPathCount = "watched_path_count"
        case jsonlContextScans = "jsonl_context_scans"
        case monitorModelTokens = "monitor_model_tokens"
    }
}

private struct SnapshotSparkQuotaWindowJSON: Encodable {
    let id: String
    let label: String
    let remainingPercent: Int?
    let usedPercent: Double?
    let resetAt: Int?
    let resetText: String?

    init(window: SparkQuotaWindow) {
        self.id = window.id
        self.label = window.label
        self.remainingPercent = window.remainingPercent
        self.usedPercent = window.usedPercent
        self.resetAt = window.resetAt
        self.resetText = window.resetText
    }

    enum CodingKeys: String, CodingKey {
        case id
        case label
        case remainingPercent = "remaining_percent"
        case usedPercent = "used_percent"
        case resetAt = "reset_at"
        case resetText = "reset_text"
    }
}

private struct SnapshotTaskJSON: Encodable {
    let id: String
    let title: String
    let status: String
    let statusLabel: String
    let detail: String
    let tokens: Int
    let subagents: Int
    let delta10mTokens: Int?
    let delta1hTokens: Int?
    let todayTokens: Int?
    let todaySharePercent: Double?
    let contextInputTokens: Int?
    let contextWindowTokens: Int?
    let contextPercent: Double?
    let contextUpdatedAt: String?
    let updatedAt: String

    init(task: CodexTask) {
        self.id = task.id
        self.title = task.title
        self.status = task.status.rawValue
        self.statusLabel = task.status.label
        self.detail = task.detail
        self.tokens = task.tokenCount
        self.subagents = task.activeSubagentCount
        self.delta10mTokens = task.delta10mTokens
        self.delta1hTokens = task.delta1hTokens
        self.todayTokens = task.todayTokens
        self.todaySharePercent = task.todaySharePercent
        self.contextInputTokens = task.contextInputTokens
        self.contextWindowTokens = task.contextWindowTokens
        self.contextPercent = task.contextPercent
        self.contextUpdatedAt = task.contextUpdatedAt.map { ISO8601DateFormatter().string(from: $0) }
        self.updatedAt = ISO8601DateFormatter().string(from: task.updatedAt)
    }

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case status
        case statusLabel = "status_label"
        case detail
        case tokens
        case subagents
        case delta10mTokens = "delta_10m_tokens"
        case delta1hTokens = "delta_1h_tokens"
        case todayTokens = "today_tokens"
        case todaySharePercent = "today_share_percent"
        case contextInputTokens = "context_input_tokens"
        case contextWindowTokens = "context_window_tokens"
        case contextPercent = "context_percent"
        case contextUpdatedAt = "context_updated_at"
        case updatedAt = "updated_at"
    }
}
