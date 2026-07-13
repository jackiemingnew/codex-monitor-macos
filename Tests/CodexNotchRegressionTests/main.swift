import Foundation

final class TestRunner {
    private(set) var failures = 0

    func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard !condition() else {
            return
        }
        failures += 1
        FileHandle.standardError.write(Data("FAILED: \(message)\n".utf8))
    }

    func checkEqual<T: Equatable>(_ actual: @autoclosure () -> T, _ expected: T, _ message: String) {
        let actualValue = actual()
        guard actualValue == expected else {
            failures += 1
            FileHandle.standardError.write(
                Data("FAILED: \(message) (actual: \(actualValue), expected: \(expected))\n".utf8)
            )
            return
        }
    }

    func require<T>(_ value: T?, _ message: String) -> T {
        guard let value else {
            failures += 1
            FileHandle.standardError.write(Data("FAILED: \(message)\n".utf8))
            fatalError(message)
        }
        return value
    }
}

private struct CountRecord: Decodable {
    let count: Int
}

private struct StringValueRecord: Decodable {
    let value: String
}

private final class AsyncResultBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Result<Value, Error>?

    func store(_ value: Result<Value, Error>) {
        lock.lock()
        self.value = value
        lock.unlock()
    }

    func load() -> Result<Value, Error>? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

private func waitForAsync<Value: Sendable>(
    _ operation: @escaping @Sendable () async throws -> Value
) throws -> Value {
    let semaphore = DispatchSemaphore(value: 0)
    let box = AsyncResultBox<Value>()
    Task.detached {
        do {
            box.store(.success(try await operation()))
        } catch {
            box.store(.failure(error))
        }
        semaphore.signal()
    }
    semaphore.wait()
    return try box.load()!.get()
}

final class RequestPathRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    func append(_ path: String) {
        lock.lock()
        storage.append(path)
        lock.unlock()
    }

    var paths: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

enum AppServerLoaderTestError: Error {
    case unavailable
}

final class AppServerLoaderSequence: @unchecked Sendable {
    enum Step {
        case success(RateLimitSnapshot)
        case failure
    }

    private let lock = NSLock()
    private var steps: [Step]
    private var attemptsStorage: [Date] = []

    init(_ steps: [Step]) {
        self.steps = steps
    }

    func load(now: Date) throws -> RateLimitSnapshot {
        lock.lock()
        attemptsStorage.append(now)
        let step = steps.isEmpty ? .failure : steps.removeFirst()
        lock.unlock()

        switch step {
        case .success(let snapshot):
            return snapshot
        case .failure:
            throw AppServerLoaderTestError.unavailable
        }
    }

    var attempts: [Date] {
        lock.lock()
        defer { lock.unlock() }
        return attemptsStorage
    }
}

final class SkillCancellationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let cancelOnCall: Int
    private var calls = 0

    init(cancelOnCall: Int) {
        self.cancelOnCall = cancelOnCall
    }

    func shouldCancel() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        calls += 1
        return calls >= cancelOnCall
    }

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }
}

let runner = TestRunner()
let repositoryRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
let metricDefinitionsPath = repositoryRoot.appendingPathComponent("docs/METRIC_DEFINITIONS.md").path
let metricDefinitions = (try? String(contentsOfFile: metricDefinitionsPath, encoding: .utf8)) ?? ""
for metricID in [
    "cumulative.active_tokens",
    "cumulative.archived_tokens",
    "cumulative.all_tokens",
    "recent.usage_20d_active_tokens",
    "recent.usage_20d_archived_tokens",
    "recent.usage_20d_all_tokens",
    "daily.usage_today_tokens",
    "period.usage_24h",
    "period.usage_7d",
    "period.usage_30d",
    "delta.10m",
    "delta.1h",
    "delta.24h",
    "task.total_tokens",
    "quota.5h",
    "quota.7d",
    "skill.catalog.enabled_count",
    "skill.catalog.disabled_count",
    "skill.catalog.context_token_estimate",
    "skill.evidence.direct_7d",
    "skill.evidence.strong_7d",
    "skill.evidence.inferred_7d",
    "skill.evidence.shadow_7d",
    "skill.suspected_miss_7d",
    "skill.suspected_misfire_7d",
    "skill.related_session_tokens_7d",
    "skill.per_skill_tokens",
    "skill.report.quality"
] {
    runner.check(metricDefinitions.contains(metricID), "metric definitions should document \(metricID)")
}

runner.check(AppInfo.version == "0.1.2", "app info should expose version 0.1.2")
runner.check(AppInfo.displayVersion == "0.1.2", "app info should fall back to source version when bundle version is unavailable")
let fullCodexDetailHeight = IslandMetrics.detailHeight(
    taskRows: IslandMetrics.visibleTaskRows,
    showsPeriodUsage: true,
    showsSparkQuota: true
)
let codexDetailWithoutSpark = IslandMetrics.detailHeight(
    taskRows: IslandMetrics.visibleTaskRows,
    showsPeriodUsage: true,
    showsSparkQuota: false
)
let codexDetailWithoutPeriod = IslandMetrics.detailHeight(
    taskRows: IslandMetrics.visibleTaskRows,
    showsPeriodUsage: false,
    showsSparkQuota: true
)
runner.check(IslandMetrics.width == 520, "detail panel should preserve the fixed 520 point width")
runner.check(IslandMetrics.collapsedWidth == 264, "collapsed window should match the visible 264 point pill")
let overlayScreenFrame = CGRect(x: 0, y: 0, width: 1_440, height: 900)
runner.check(
    IslandMetrics.clampedOverlayCenterX(720, in: overlayScreenFrame) == 720,
    "centered overlay position should remain unchanged"
)
runner.check(
    IslandMetrics.clampedOverlayCenterX(50, in: overlayScreenFrame) == 260,
    "overlay drag should keep the detail panel inside the left screen edge"
)
runner.check(
    IslandMetrics.clampedOverlayCenterX(1_400, in: overlayScreenFrame) == 1_180,
    "overlay drag should keep the detail panel inside the right screen edge"
)
runner.check(
    IslandMetrics.clampedOverlayCenterX(920, in: overlayScreenFrame) == 920,
    "overlay drag should preserve an in-bounds horizontal offset"
)
var overlayDragSession = OverlayDragSession(
    pointer: CGPoint(x: 720, y: 800),
    centerX: 720,
    topEdge: 850
)
runner.check(
    overlayDragSession.update(
        pointer: CGPoint(x: 820, y: 800),
        screenFrame: overlayScreenFrame,
        topEdgeRange: 430...900
    ).centerX == 820,
    "overlay drag should follow global pointer movement one-to-one"
)
runner.check(
    overlayDragSession.update(
        pointer: CGPoint(x: 1_500, y: 800),
        screenFrame: overlayScreenFrame,
        topEdgeRange: 430...900
    ).centerX == 1_180,
    "overlay drag should clamp at the right edge"
)
runner.check(
    overlayDragSession.update(
        pointer: CGPoint(x: 1_499, y: 800),
        screenFrame: overlayScreenFrame,
        topEdgeRange: 430...900
    ).centerX == 1_179,
    "overlay drag should leave a clamped edge after one point of reverse movement"
)
let normalizedOverlayPosition = IslandMetrics.normalizedOverlayPosition(
    centerX: 920,
    in: overlayScreenFrame
)
runner.check(
    abs(IslandMetrics.overlayCenterX(normalizedPosition: normalizedOverlayPosition, in: overlayScreenFrame) - 920) < 0.001,
    "normalized overlay position should round-trip on the same screen"
)
let widerOverlayScreenFrame = CGRect(x: 0, y: 0, width: 1_728, height: 1_117)
let restoredWiderCenter = IslandMetrics.overlayCenterX(
    normalizedPosition: normalizedOverlayPosition,
    in: widerOverlayScreenFrame
)
runner.check(
    abs(IslandMetrics.normalizedOverlayPosition(centerX: restoredWiderCenter, in: widerOverlayScreenFrame) - normalizedOverlayPosition) < 0.001,
    "normalized overlay position should survive a screen width change"
)
let narrowOverlayScreenFrame = CGRect(x: 0, y: 0, width: 400, height: 800)
runner.check(
    IslandMetrics.overlayCenterX(normalizedPosition: 1, in: narrowOverlayScreenFrame) == narrowOverlayScreenFrame.midX,
    "screens narrower than the detail panel should force the overlay to center"
)
runner.check(fullCodexDetailHeight == 528, "five-row Codex detail with Spark and period usage should be 528 points tall")
runner.check(fullCodexDetailHeight - codexDetailWithoutSpark == 40, "Spark strip should add 40 points including its section gap")
runner.check(fullCodexDetailHeight - codexDetailWithoutPeriod == 56, "period footer should add 56 points including its section gap")
runner.check(IslandMetrics.visibleTaskRowsHeight == 170, "task viewport should expose exactly five 34 point rows")
runner.check(IslandMetrics.taskTableHeight(taskRows: IslandMetrics.visibleTaskRows) == 248, "task table should reserve 50 points below the five-row viewport")

let diagnosticsTestRoot = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("CodexNotchDiagnostics-\(UUID().uuidString)")
let diagnosticsTestURL = diagnosticsTestRoot.appendingPathComponent("quota-diagnostics.jsonl")
let diagnostics = MonitorDiagnostics(logURL: diagnosticsTestURL)
defer {
    try? FileManager.default.removeItem(at: diagnosticsTestRoot)
}
diagnostics.record(
    event: "quota_resolution",
    correlationID: "first",
    fields: ["result_primary_percent": 83, "primary_decision": "local_jsonl_lower_same_generation"]
)
diagnostics.record(
    event: "quota_resolution",
    correlationID: "duplicate",
    fields: ["result_primary_percent": 83, "primary_decision": "local_jsonl_lower_same_generation"]
)
diagnostics.record(
    event: "quota_resolution",
    correlationID: "second",
    fields: ["result_primary_percent": 100, "primary_decision": "app_server_newer_generation"]
)
let diagnosticsLines = diagnostics.recentData(limit: 20)
    .split(separator: 0x0A, omittingEmptySubsequences: true)
let diagnosticsObjects = diagnosticsLines.compactMap { line in
    try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any]
}
runner.check(diagnosticsObjects.count == 2, "diagnostic logger should deduplicate unchanged quota decisions")
runner.check(diagnosticsObjects.last?["event"] as? String == "quota_resolution", "diagnostic logger should use a stable event name")
runner.check(diagnosticsObjects.last?["result_primary_percent"] as? Int == 100, "diagnostic logger should preserve structured quota fields")
runner.check(diagnosticsObjects.last?["correlation_id"] as? String == "second", "diagnostic logger should preserve the decision correlation id")
let diagnosticsPermissions = (try? FileManager.default.attributesOfItem(atPath: diagnosticsTestURL.path)[.posixPermissions] as? NSNumber)?.intValue
runner.check(diagnosticsPermissions == 0o600, "diagnostic log should be readable only by the current user")
let diagnosticsDirectoryPermissions = (try? FileManager.default.attributesOfItem(atPath: diagnosticsTestRoot.path)[.posixPermissions] as? NSNumber)?.intValue
runner.check(diagnosticsDirectoryPermissions == 0o700, "diagnostic directory should be accessible only by the current user")
runner.check(TaskStatus.running.hudLabel == "RUNNING", "HUD running status should display RUNNING")
runner.check(TaskStatus.recent.hudLabel == "IDLE", "HUD recent status should display as IDLE")
runner.check(TaskStatus.idle.hudLabel == "IDLE", "HUD idle status should display as IDLE")
runner.check(QuotaDisplayLevel.level(for: nil) == .unavailable, "missing quota should use unavailable display level")
runner.check(QuotaDisplayLevel.level(for: 0) == .critical, "zero quota should use critical display level")
runner.check(QuotaDisplayLevel.level(for: 20) == .critical, "20 percent quota should use critical display level")
runner.check(QuotaDisplayLevel.level(for: 21) == .warning, "21 percent quota should use warning display level")
runner.check(QuotaDisplayLevel.level(for: 40) == .warning, "40 percent quota should use warning display level")
runner.check(QuotaDisplayLevel.level(for: 41) == .healthy, "41 percent quota should use healthy display level")
runner.check(QuotaDisplayLevel.level(for: 100) == .healthy, "full quota should use healthy display level")

let quotaBoundaryNow = Date(timeIntervalSince1970: 1_783_000_000)
let preciseQuotaSnapshot = RateLimitSnapshot(
    primaryPercent: 99,
    secondaryPercent: 100,
    primaryResetsAt: 1_783_003_600,
    secondaryResetsAt: 1_783_003_600,
    capturedAt: quotaBoundaryNow,
    isPrimaryCodexLimit: true
)
runner.check(
    preciseQuotaSnapshot.primaryDisplayPercent(now: quotaBoundaryNow) == 99,
    "future quota windows should preserve an exact 99 percent remaining value"
)
runner.check(
    preciseQuotaSnapshot.secondaryDisplayPercent(now: quotaBoundaryNow) == 100,
    "future quota windows should preserve an exact 100 percent remaining value"
)
runner.check(
    preciseQuotaSnapshot.primaryDisplayPercent(now: Date(timeIntervalSince1970: 1_783_003_600)) == 99,
    "a reset timestamp alone should not synthesize a 100 percent quota"
)

var legacyQuotaSnapshot = UsageSnapshot.empty
legacyQuotaSnapshot.primaryPercent = 78
legacyQuotaSnapshot.secondaryPercent = 36
legacyQuotaSnapshot.primaryResetsAt = 1_783_003_600
legacyQuotaSnapshot.secondaryResetsAt = 1_783_400_000
legacyQuotaSnapshot.primaryWindowMinutes = 300
legacyQuotaSnapshot.secondaryWindowMinutes = 10_080
runner.check(
    legacyQuotaSnapshot.mainQuotaWindows.map(\.title) == ["5h Quota", "Weekly Quota"],
    "legacy dual-window quota should keep both 5h and weekly display windows"
)
runner.check(
    legacyQuotaSnapshot.mainQuotaWindows.map(\.compactLabel) == ["5h", "7d"],
    "legacy dual-window quota should keep compact 5h and 7d labels"
)

var weeklyOnlyQuotaSnapshot = UsageSnapshot.empty
weeklyOnlyQuotaSnapshot.primaryPercent = 100
weeklyOnlyQuotaSnapshot.primaryResetsAt = 1_783_604_800
weeklyOnlyQuotaSnapshot.primaryWindowMinutes = 10_080
weeklyOnlyQuotaSnapshot.stabilizeQuota(from: legacyQuotaSnapshot)
runner.check(
    weeklyOnlyQuotaSnapshot.secondaryPercent == nil,
    "an authoritative weekly-only snapshot should clear the previous secondary quota"
)
runner.check(
    weeklyOnlyQuotaSnapshot.mainQuotaWindows.map(\.title) == ["Weekly Quota"],
    "a weekly quota delivered in the primary slot should render as one weekly window"
)
runner.check(
    weeklyOnlyQuotaSnapshot.mainQuotaWindows.first?.usesDateResetStyle == true,
    "weekly quota reset metadata should use a date instead of a time-only label"
)

var unavailableQuotaSnapshot = UsageSnapshot.empty
unavailableQuotaSnapshot.stabilizeQuota(from: legacyQuotaSnapshot)
runner.check(
    unavailableQuotaSnapshot.primaryPercent == 78 && unavailableQuotaSnapshot.secondaryPercent == 36,
    "a fully unavailable quota refresh should preserve the last known windows"
)

var partiallyAvailableLegacyQuotaSnapshot = UsageSnapshot.empty
partiallyAvailableLegacyQuotaSnapshot.primaryPercent = 77
partiallyAvailableLegacyQuotaSnapshot.primaryResetsAt = 1_783_003_900
partiallyAvailableLegacyQuotaSnapshot.primaryWindowMinutes = 300
partiallyAvailableLegacyQuotaSnapshot.stabilizeQuota(from: legacyQuotaSnapshot)
runner.check(
    partiallyAvailableLegacyQuotaSnapshot.secondaryPercent == 36,
    "a partial legacy quota refresh should preserve the temporarily missing weekly window"
)

let runtimeLocatorRoot = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("CodexNotchRuntimeLocator-\(UUID().uuidString)")
let discoveredRuntimeApp = runtimeLocatorRoot.appendingPathComponent("ChatGPT.app", isDirectory: true)
let legacyRuntimeApp = runtimeLocatorRoot.appendingPathComponent("Codex.app", isDirectory: true)
let discoveredResources = discoveredRuntimeApp.appendingPathComponent("Contents/Resources", isDirectory: true)
let legacyResources = legacyRuntimeApp.appendingPathComponent("Contents/Resources", isDirectory: true)
try FileManager.default.createDirectory(at: discoveredResources, withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: legacyResources, withIntermediateDirectories: true)
defer {
    try? FileManager.default.removeItem(at: runtimeLocatorRoot)
}
let discoveredCodexExecutable = discoveredResources.appendingPathComponent("codex")
let discoveredRipgrepExecutable = discoveredResources.appendingPathComponent("rg")
let legacyCodexExecutable = legacyResources.appendingPathComponent("codex")
for executable in [discoveredCodexExecutable, discoveredRipgrepExecutable, legacyCodexExecutable] {
    try Data().write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
}
runner.check(
    CodexRuntimeLocator.firstExecutable(
        named: "codex",
        in: [discoveredRuntimeApp, legacyRuntimeApp]
    ) == discoveredCodexExecutable.path,
    "runtime locator should prefer the bundle-discovered ChatGPT executable"
)
runner.check(
    CodexRuntimeLocator.firstExecutable(
        named: "rg",
        in: [discoveredRuntimeApp, legacyRuntimeApp]
    ) == discoveredRipgrepExecutable.path,
    "runtime locator should resolve companion tools from the same app resources"
)
try FileManager.default.removeItem(at: discoveredCodexExecutable)
runner.check(
    CodexRuntimeLocator.firstExecutable(
        named: "codex",
        in: [discoveredRuntimeApp, legacyRuntimeApp]
    ) == legacyCodexExecutable.path,
    "runtime locator should fall back to the legacy Codex app when needed"
)
runner.check(
    CodexRuntimeLocator.firstExecutable(
        named: "missing-tool",
        in: [discoveredRuntimeApp, legacyRuntimeApp]
    ) == nil,
    "runtime locator should return nil when no executable exists"
)
runner.check(
    Formatters.compactTokens(15_000, isPartial: false) == "2万",
    "complete usage values should keep their existing compact token format"
)
runner.check(
    Formatters.compactTokens(15_000, isPartial: true) == "≥2万",
    "partial usage values should display as a confirmed lower bound"
)
runner.check(
    Formatters.compactTokensEnglish(1_500_000, isPartial: true) == "≥1.5M",
    "collapsed partial usage should display an English lower-bound marker"
)
runner.check(
    Formatters.partialUsageHelp(label: "7天", isPartial: true, missingBaselineSessions: 7)
        == "7天有 7 个会话缺少历史基线，当前数值为已确认最低值。",
    "partial usage help should explain the missing baseline count"
)
runner.check(
    Formatters.partialUsageHelp(label: "30天", isPartial: false, missingBaselineSessions: 0) == nil,
    "complete usage should not expose a partial-data help message"
)
runner.check(
    Formatters.reasoningEffortLabel("ultra") == "极致推理",
    "GPT-5.6 ultra reasoning effort should use the localized detail label"
)
runner.check(
    Formatters.reasoningEffortLabel("xhigh") == "超高推理",
    "existing xhigh reasoning effort localization should stay unchanged"
)
runner.check(
    Formatters.reasoningEffortLabel("future-effort") == "future-effort",
    "unknown reasoning effort values should remain visible for forward compatibility"
)

let snapshotFormatterTask = CodexTask(
    id: "snapshot-task",
    title: "父任务",
    status: .running,
    detail: "gpt-5.5 · 高推理",
    tokenCount: 12345,
    updatedAt: Date(timeIntervalSince1970: 0),
    activeSubagentCount: 3,
    delta10mTokens: 1200,
    delta1hTokens: 3456,
    todayTokens: 12,
    todaySharePercent: 10.81081081081081,
    contextInputTokens: 58609,
    contextWindowTokens: 258400,
    contextPercent: 22.681501547987615,
    contextUpdatedAt: Date(timeIntervalSince1970: 10)
)
let snapshotFormatterSnapshot = UsageSnapshot(
    primaryPercent: 88,
    secondaryPercent: 66,
    primaryResetsAt: 1_783_000_000,
    secondaryResetsAt: 1_783_400_000,
    cumulativeUsage: CumulativeUsage(
        activeTokens: 123_456,
        archivedTokens: 7_890,
        allTokens: 131_346,
        activeSessions: 3,
        archivedSessions: 1,
        allSessions: 4
    ),
    recentUsage: RecentUsage(
        usage20dActiveTokens: 123_456,
        usage20dArchivedTokens: 7_890,
        usage20dAllTokens: 131_346,
        usage20dActiveSessions: 3,
        usage20dArchivedSessions: 1,
        usage20dAllSessions: 4,
        windowDays: 20
    ),
    dailyUsage: DailyUsage(
        usageTodayTokens: 111,
        dayStartedAt: Date(timeIntervalSince1970: 0),
        timeZoneIdentifier: "UTC",
        isPartial: false,
        missingBaselineSessions: 0
    ),
    usage1h: 444,
    usage24h: 111,
    usage7d: 222,
    usage30d: 333,
    periodUsageQuality: .empty,
    sparkQuotaWindows: [
        SparkQuotaWindow(
            id: "spark-5h",
            label: "5h",
            remainingPercent: 12,
            usedPercent: 88,
            resetAt: 1_783_000_000,
            resetText: "2h"
        )
    ],
    tasks: [snapshotFormatterTask],
    isRunning: true,
    lastUpdated: Date(timeIntervalSince1970: 0),
    errorMessage: nil,
    monitorStats: MonitorPerformanceStats(
        lastSnapshotDurationMs: 42,
        lastUsageDurationMs: 84,
        lastDeltaDurationMs: 5,
        lastRateLimitSource: "local-jsonl",
        watchedPathCount: 7,
        jsonlContextScans: 2,
        monitorModelTokens: 0
    )
)
let humanSnapshotLines = SnapshotOutputFormatter.humanLines(for: snapshotFormatterSnapshot)
runner.check(
    humanSnapshotLines.contains("usage1h=444 usage24h=111 usage7d=222 usage30d=333 source=swift-delta-cache"),
    "human snapshot output should expose aggregate 1 hour usage and rolling period source"
)
runner.check(
    humanSnapshotLines.contains("daily today=111 partial=false missing=0"),
    "human snapshot output should expose natural-day token usage"
)
runner.check(
    humanSnapshotLines.contains("cumulative active=123456 archived=7890 all=131346"),
    "human snapshot output should expose cumulative token totals"
)
runner.check(
    humanSnapshotLines.contains("recent20d active=123456 archived=7890 all=131346"),
    "human snapshot output should expose recent 20 day token totals"
)
runner.check(
    humanSnapshotLines.contains("spark=5h=12%"),
    "human snapshot output should expose Spark quota windows"
)
runner.check(
    humanSnapshotLines.contains("monitor snapshot_ms=42 usage_ms=84 delta_ms=5 rate=local-jsonl watched=7 context_scans=2 model_tokens=0"),
    "human snapshot output should expose monitor self cost"
)
runner.check(
    humanSnapshotLines.contains("task=运行中 父任务 12345 delta1h=+3.5千 today=12 11% ctx=6万/26万"),
    "human snapshot task line should expose 1 hour delta, Today usage share, and context ratio"
)
runner.check(
    !humanSnapshotLines.contains { $0.contains("subagents=") },
    "human snapshot output should not append subagent fields to task lines"
)
let jsonSnapshot = try JSONSerialization.jsonObject(
    with: SnapshotOutputFormatter.jsonData(for: snapshotFormatterSnapshot)
) as? [String: Any]
let jsonMonitor = jsonSnapshot?["monitor"] as? [String: Any]
let jsonCumulativeUsage = jsonSnapshot?["cumulative_usage"] as? [String: Any]
runner.check(
    jsonSnapshot?["usage_1h"] as? Int == 444,
    "JSON snapshot output should expose aggregate 1 hour usage"
)
runner.check(
    jsonCumulativeUsage?["active_tokens"] as? Int == 123_456,
    "JSON snapshot output should expose active cumulative tokens"
)
runner.check(
    jsonCumulativeUsage?["metric_id"] as? String == "cumulative.active_tokens",
    "JSON snapshot output should identify the default cumulative metric"
)
runner.check(
    jsonSnapshot?["primary_reset_at"] as? Int == 1_783_000_000,
    "JSON snapshot output should expose primary quota reset time"
)
runner.check(
    jsonSnapshot?["secondary_reset_at"] as? Int == 1_783_400_000,
    "JSON snapshot output should expose secondary quota reset time"
)
let jsonSparkWindows = jsonSnapshot?["spark_quota_windows"] as? [[String: Any]]
runner.check(
    jsonSparkWindows?.first?["label"] as? String == "5h",
    "JSON snapshot output should expose Spark quota labels"
)
runner.check(
    jsonSparkWindows?.first?["remaining_percent"] as? Int == 12,
    "JSON snapshot output should expose Spark quota remaining percent"
)
runner.check(
    Formatters.quotaResetText(
        1_783_000_000,
        now: Date(timeIntervalSince1970: 1_782_999_000),
        timeZone: TimeZone(secondsFromGMT: 0)!
    ) == "13:46 恢复",
    "quota reset formatter should display future reset time"
)
runner.check(
    Formatters.quotaResetText(
        1_783_518_400,
        style: .date,
        now: Date(timeIntervalSince1970: 1_783_000_000),
        timeZone: TimeZone(secondsFromGMT: 0)!
    ) == "7/8 恢复",
    "quota reset formatter should display same-year reset date"
)
runner.check(
    Formatters.quotaResetText(
        1_798_859_045,
        style: .date,
        now: Date(timeIntervalSince1970: 1_798_675_200),
        timeZone: TimeZone(secondsFromGMT: 0)!
    ) == "2027/1/2 恢复",
    "quota reset formatter should include year for cross-year reset date"
)
runner.check(
    Formatters.quotaResetText(
        1_783_000_000,
        now: Date(timeIntervalSince1970: 1_783_000_000),
        timeZone: TimeZone(secondsFromGMT: 0)!
    ) == nil,
    "quota reset formatter should hide expired reset time"
)
runner.check(
    jsonMonitor?["last_snapshot_duration_ms"] as? Int == 42,
    "JSON snapshot output should expose snapshot duration"
)
runner.check(
    jsonMonitor?["last_usage_duration_ms"] as? Int == 84,
    "JSON snapshot output should expose usage duration"
)
runner.check(
    jsonMonitor?["last_delta_duration_ms"] as? Int == 5,
    "JSON snapshot output should expose delta duration"
)
runner.check(
    jsonMonitor?["last_rate_limit_source"] as? String == "local-jsonl",
    "JSON snapshot output should expose rate limit source"
)
runner.check(
    jsonMonitor?["watched_path_count"] as? Int == 7,
    "JSON snapshot output should expose watched path count"
)
runner.check(
    jsonMonitor?["jsonl_context_scans"] as? Int == 2,
    "JSON snapshot output should expose context scan count"
)
runner.check(
    jsonMonitor?["monitor_model_tokens"] as? Int == 0,
    "JSON snapshot output should report zero monitor model tokens"
)
let jsonSnapshotTasks = jsonSnapshot?["tasks"] as? [[String: Any]]
runner.check(
    jsonSnapshotTasks?.first?["subagents"] as? Int == 3,
    "JSON snapshot output should expose active subagent counts"
)
runner.check(
    jsonSnapshotTasks?.first?["delta_10m_tokens"] as? Int == 1200,
    "JSON snapshot output should keep legacy 10 minute token deltas for compatibility"
)
runner.check(
    jsonSnapshotTasks?.first?["delta_1h_tokens"] as? Int == 3456,
    "JSON snapshot output should expose 1 hour token deltas"
)
runner.check(
    jsonSnapshotTasks?.first?["today_tokens"] as? Int == 12,
    "JSON snapshot output should expose Today token usage"
)
runner.check(
    (jsonSnapshotTasks?.first?["today_share_percent"] as? Double).map { abs($0 - 10.81081081081081) < 0.000001 } == true,
    "JSON snapshot output should expose Today usage share percent"
)
runner.check(
    jsonSnapshotTasks?.first?["context_input_tokens"] as? Int == 58609,
    "JSON snapshot output should expose context input tokens"
)
runner.check(
    jsonSnapshotTasks?.first?["context_window_tokens"] as? Int == 258400,
    "JSON snapshot output should expose model context window tokens"
)
runner.check(
    (jsonSnapshotTasks?.first?["context_percent"] as? Double).map { abs($0 - 22.681501547987615) < 0.000001 } == true,
    "JSON snapshot output should expose context percentage"
)
let tokenContextLine = #"{"timestamp":"2026-06-29T15:01:43.961Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":39217907,"cached_input_tokens":35158912,"output_tokens":176936,"reasoning_output_tokens":60714,"total_tokens":39394843},"last_token_usage":{"input_tokens":57907,"cached_input_tokens":55168,"output_tokens":644,"reasoning_output_tokens":230,"total_tokens":58551},"model_context_window":258400},"rate_limits":{"limit_id":"codex"}}}"#
let parsedContext = runner.require(
    TokenContextUsageParser.parse(line: tokenContextLine),
    "token context parser should read token_count context payloads"
)
runner.check(parsedContext.inputTokens == 57907, "token context parser should use last_token_usage input tokens")
runner.check(parsedContext.windowTokens == 258400, "token context parser should read model_context_window")
runner.check(abs(parsedContext.percent - 22.40982972136223) < 0.000001, "token context parser should calculate context percentage")
runner.check(
    TaskBadgeFormatter.subagentBadgeText(for: 3) == "子代理 3",
    "task row subagent badge should use compact text"
)
runner.check(
    TaskBadgeFormatter.subagentBadgeText(for: 0) == nil,
    "task row subagent badge should stay hidden for zero active subagents"
)

let appServerFixtureNow = Date()
let appServerPrimaryReset = Int(appServerFixtureNow.timeIntervalSince1970) + 5 * 60 * 60
let appServerSecondaryReset = Int(appServerFixtureNow.timeIntervalSince1970) + 7 * 24 * 60 * 60
let appServerSparkPrimaryReset = appServerPrimaryReset + 600
let appServerSparkSecondaryReset = appServerSecondaryReset + 600
let appServerRateLimitOutput = """
{"jsonrpc":"2.0","id":2,"result":{"rateLimits":{"limitId":"codex","limitName":null,"primary":{"usedPercent":17,"windowDurationMins":300,"resetsAt":\(appServerPrimaryReset)},"secondary":{"usedPercent":22,"windowDurationMins":10080,"resetsAt":\(appServerSecondaryReset)}},"rateLimitsByLimitId":{"codex_bengalfox":{"limitId":"codex_bengalfox","limitName":"GPT-5.3-Codex-Spark","primary":{"usedPercent":78,"windowDurationMins":300,"resetsAt":\(appServerSparkPrimaryReset)},"secondary":{"usedPercent":42,"windowDurationMins":10080,"resetsAt":\(appServerSparkSecondaryReset)}},"codex_luna":{"limitId":"codex_luna","limitName":"GPT-5.6-Codex-Luna","primary":{"usedPercent":12,"windowDurationMins":300,"resetsAt":\(appServerSparkPrimaryReset)},"secondary":{"usedPercent":34,"windowDurationMins":10080,"resetsAt":\(appServerSparkSecondaryReset)}},"codex":{"limitId":"codex","limitName":null,"primary":{"usedPercent":17,"windowDurationMins":300,"resetsAt":\(appServerPrimaryReset)},"secondary":{"usedPercent":22,"windowDurationMins":10080,"resetsAt":\(appServerSecondaryReset)}}}}}
"""
let appServerSnapshot = runner.require(
    CodexUsageStore().parseAppServerRateLimits(
        output: appServerRateLimitOutput,
        now: appServerFixtureNow
    ),
    "app-server rate limit fixture should parse"
)
runner.check(appServerSnapshot.isPrimaryCodexLimit, "app-server quota should identify codex as the main limit")
runner.check(appServerSnapshot.primaryPercent == 83, "app-server codex primary quota should remain the main 5h quota")
runner.check(appServerSnapshot.secondaryPercent == 78, "app-server codex secondary quota should remain the main 7d quota")
runner.check(appServerSnapshot.primaryResetsAt == appServerPrimaryReset, "app-server codex primary reset time should decode")
runner.check(appServerSnapshot.secondaryResetsAt == appServerSecondaryReset, "app-server codex secondary reset time should decode")
runner.check(appServerSnapshot.primaryWindowMinutes == 300, "app-server primary window duration should decode")
runner.check(appServerSnapshot.secondaryWindowMinutes == 10_080, "app-server secondary window duration should decode")
runner.check(appServerSnapshot.sparkQuotaWindows.map(\.label) == ["5h", "7d"], "app-server Spark quota windows should decode")
runner.check(appServerSnapshot.sparkQuotaWindows.allSatisfy { !$0.id.contains("luna") }, "app-server unknown model quota windows should not appear in Spark quota windows")
runner.check(appServerSnapshot.sparkQuotaWindows.first?.remainingPercent == 22, "app-server Spark 5h remaining percent should decode")
runner.check(appServerSnapshot.sparkQuotaWindows.last?.remainingPercent == 58, "app-server Spark 7d remaining percent should decode")

let weeklyOnlyReset = Int(appServerFixtureNow.timeIntervalSince1970) + 7 * 24 * 60 * 60
let weeklyOnlyAppServerOutput = """
{"jsonrpc":"2.0","id":2,"result":{"rateLimits":{"limitId":"codex","limitName":null,"primary":{"usedPercent":0,"windowDurationMins":10080,"resetsAt":\(weeklyOnlyReset)},"secondary":null},"rateLimitsByLimitId":{"codex":{"limitId":"codex","limitName":null,"primary":{"usedPercent":0,"windowDurationMins":10080,"resetsAt":\(weeklyOnlyReset)},"secondary":null}}}}
"""
let weeklyOnlyAppServerSnapshot = runner.require(
    CodexUsageStore().parseAppServerRateLimits(
        output: weeklyOnlyAppServerOutput,
        now: appServerFixtureNow
    ),
    "weekly-only app-server rate limit fixture should parse"
)
runner.check(weeklyOnlyAppServerSnapshot.primaryPercent == 100, "weekly-only app-server quota should expose full remaining usage")
runner.check(weeklyOnlyAppServerSnapshot.primaryWindowMinutes == 10_080, "weekly-only app-server quota should retain its seven-day duration")
runner.check(weeklyOnlyAppServerSnapshot.secondaryPercent == nil, "weekly-only app-server quota should not synthesize a secondary window")

@MainActor
func dateFromISO8601(_ value: String, message: String) -> Date {
    runner.require(CodexRadarDateParser.parse(value), message)
}

let codexRadarFixture = """
{
  "monitored_at": "2026-07-01T06:27:00+08:00",
  "status": "community_confirmed",
  "recommended_action": "reset_completed",
  "window": {
    "message": "社区反馈已完成重置"
  },
  "prediction": {
    "summary": "官方重置已经完成。"
  },
  "api_access": {
    "requirements": {
      "attribution_required": true,
      "attribution_text": "数据来自 Codex 雷达 codexradar.com",
      "site": "https://codexradar.com"
    }
  },
  "model_iq": {
    "latest": {
      "date": "2026-07-07-pm",
      "score": 62.5,
      "status": "red",
      "passed": 5,
      "tasks": 12,
      "wall_time_human": "37分钟",
      "model": "gpt-5.5",
      "reasoning_effort": "xhigh",
      "cost_usd": 46.348455
    },
    "comparisons": {
      "gpt_55_high": {
        "label": "GPT-5.5 high",
        "latest": {
          "score": 75.0,
          "status": "red",
          "passed": 6,
          "tasks": 12,
          "wall_time_human": "36分钟",
          "cost_usd": 24.929204
        }
      },
      "gpt_55_medium": {
        "label": "GPT-5.5 medium",
        "latest": {
          "score": 87.5,
          "status": "yellow",
          "passed": 7,
          "tasks": 12,
          "wall_time_human": "32分钟",
          "cost_usd": 20.98977
        }
      },
      "gpt_54_xhigh": {
        "label": "GPT-5.4 xhigh",
        "latest": {
          "score": 50.0,
          "status": "red",
          "passed": 4,
          "tasks": 12,
          "wall_time_human": "35分钟",
          "cost_usd": 22.651593
        }
      },
      "gpt_54_high": {
        "label": "GPT-5.4 high",
        "latest": {
          "score": 87.5,
          "status": "yellow",
          "passed": 7,
          "tasks": 12,
          "wall_time_human": "36分钟",
          "cost_usd": 17.771049
        }
      }
    },
    "quota_radar": {
      "updated_at": "2026-06-30T22:27:57Z",
      "cost_usd": 132.690071,
      "rows": [
        {"tier": "20x Pro", "basis": "measured 7d", "five_h": 276.44, "seven_d": 1658.63},
        {"tier": "5x Pro", "basis": "model /4", "five_h": 69.11, "seven_d": 414.66},
        {"tier": "Plus", "basis": "model /20", "five_h": 13.82, "seven_d": 82.93}
      ]
    }
  }
}
""".data(using: .utf8)!
let radarFetchedAt = dateFromISO8601("2026-07-01T06:28:00+08:00", message: "Codex Radar fetched timestamp should parse")
let radarSnapshot = try CodexRadarSnapshot.decodePublicSummary(
    from: codexRadarFixture,
    fetchedAt: radarFetchedAt,
    dataSource: .authorizedAPI
)
runner.check(radarSnapshot.models.count == 5, "Codex Radar summary should expose five model cards")
runner.check(radarSnapshot.models.map(\.label) == [
    "GPT-5.5 xhigh",
    "GPT-5.5 high",
    "GPT-5.5 medium",
    "GPT-5.4 xhigh",
    "GPT-5.4 high"
], "Codex Radar model cards should preserve the expected display order")
runner.check(radarSnapshot.models.first?.score == 62.5, "Codex Radar latest model should decode score")
runner.check(radarSnapshot.models.first?.passed == 5, "Codex Radar latest model should decode passed tasks")
runner.check(radarSnapshot.models.first?.tasks == 12, "Codex Radar latest model should decode task count")
runner.check(radarSnapshot.quotaRows.count == 3, "Codex Radar quota radar should expose three plan rows")
runner.check(radarSnapshot.quotaRows.first?.tier == "20x Pro", "Codex Radar quota row should preserve tier")
runner.check(radarSnapshot.quotaRows.first?.fiveH == 276.44, "Codex Radar quota row should decode 5h estimate")
runner.check(radarSnapshot.quotaRows.first?.sevenD == 1658.63, "Codex Radar quota row should decode 7d estimate")
runner.check(radarSnapshot.costUSD == 132.690071, "Codex Radar cost should prefer quota_radar cost")
runner.check(radarSnapshot.dataSource == .authorizedAPI, "Codex Radar snapshot should preserve the authorized API source")
runner.check(radarSnapshot.modelIQDate == "2026-07-07-pm", "Codex Radar authorized API should expose model_iq latest date for the summary Updated field")
runner.check(
    radarSnapshot.displayUpdatedAt == dateFromISO8601("2026-06-30T22:27:57Z", message: "Codex Radar display timestamp should parse"),
    "Codex Radar display timestamp should prefer the freshest source data timestamp"
)
runner.check(radarSnapshot.attributionRequired, "Codex Radar should preserve required attribution flag")
runner.check(radarSnapshot.attributionText == "数据来自 Codex 雷达 codexradar.com", "Codex Radar should preserve attribution text")
runner.check(radarSnapshot.siteURL.absoluteString == "https://codexradar.com", "Codex Radar should preserve source site")

let codexRadar56Fixture = """
{
  "monitored_at": "2026-07-10T11:22:58+08:00",
  "status": "community_confirmed",
  "recommended_action": "wait",
  "window": {
    "message": "当前没有开启的速蹬窗口；本次 full reset 已到账。"
  },
  "prediction": {
    "summary": "当前窗口关闭。",
    "expected_window": "本次 full reset 已到账，当前窗口关闭"
  },
  "model_iq": {
    "latest": {
      "date": "2026-07-10-am",
      "score": 116.7,
      "status": "invalid",
      "passed": 7,
      "tasks": 10,
      "invalid": 1,
      "valid_tasks": 9,
      "model": "gpt-5.6-sol",
      "reasoning_effort": "ultra",
      "cost_usd": 33.103802
    },
    "comparisons": {
      "gpt_56_sol_xhigh": {
        "label": "GPT-5.6 Sol xhigh",
        "latest": {"score": 105.0, "status": "green", "passed": 7, "tasks": 10, "invalid": 0, "valid_tasks": 10, "model": "gpt-5.6-sol", "reasoning_effort": "xhigh", "cost_usd": 37.127702}
      },
      "gpt_56_sol_high": {
        "label": "GPT-5.6 Sol high",
        "latest": {"score": 105.0, "status": "green", "passed": 7, "tasks": 10, "invalid": 0, "valid_tasks": 10, "model": "gpt-5.6-sol", "reasoning_effort": "high", "cost_usd": 23.423657}
      },
      "gpt_56_luna_medium": {
        "label": "GPT-5.6 Luna medium",
        "latest": {"score": 30.0, "status": "red", "passed": 2, "tasks": 10, "invalid": 0, "valid_tasks": 10, "model": "gpt-5.6-luna", "reasoning_effort": "medium", "cost_usd": 2.837291}
      },
      "gpt_56_sol_low": {
        "label": "GPT-5.6 Sol low",
        "latest": {"score": 105.0, "status": "green", "passed": 7, "tasks": 10, "invalid": 0, "valid_tasks": 10, "model": "gpt-5.6-sol", "reasoning_effort": "low", "cost_usd": 9.497932}
      },
      "gpt_56_sol_medium": {
        "label": "GPT-5.6 Sol medium",
        "latest": {"score": 120.0, "status": "green", "passed": 8, "tasks": 10, "invalid": 0, "valid_tasks": 10, "model": "gpt-5.6-sol", "reasoning_effort": "medium", "cost_usd": 15.285266}
      },
      "gpt_56_terra_medium": {
        "label": "GPT-5.6 Terra medium",
        "latest": {"score": 75.0, "status": "red", "passed": 5, "tasks": 10, "invalid": 0, "valid_tasks": 10, "model": "gpt-5.6-terra", "reasoning_effort": "medium", "cost_usd": 6.083723}
      }
    },
    "quota_radar": {
      "date": "2026-07-09-pm",
      "updated_at": "2026-07-09T05:21:42Z",
      "cost_usd": 116.938665,
      "rows": [
        {"tier": "20x Pro", "basis": "measured", "five_h": 259.86, "seven_d": 1559.16},
        {"tier": "5x Pro", "basis": "model /4", "five_h": 64.97, "seven_d": 389.79},
        {"tier": "Plus", "basis": "model /20", "five_h": 12.99, "seven_d": 77.96}
      ],
      "trend": [
        {"date": "2026-07-08-am", "five_h_20x": 320.45, "seven_d_20x": 1922.70},
        {"date": "2026-07-09-pm", "five_h_20x": 259.86, "seven_d_20x": 1559.16}
      ]
    }
  }
}
""".data(using: .utf8)!
let radar56Snapshot = try CodexRadarSnapshot.decodePublicSummary(
    from: codexRadar56Fixture,
    fetchedAt: radarFetchedAt,
    dataSource: .authorizedAPI
)
runner.check(radar56Snapshot.models.count == 5, "Codex Radar 5.6 summary should expose every current model card")
runner.check(radar56Snapshot.models.map(\.label) == [
    "GPT-5.6 Sol ultra",
    "GPT-5.6 Sol medium",
    "GPT-5.6 Sol low",
    "GPT-5.6 Terra medium",
    "GPT-5.6 Luna medium"
], "Codex Radar 5.6 cards should use dynamic labels and stable ordering")
runner.check(radar56Snapshot.models.first?.id == "latest:gpt-5.6-sol:ultra", "Codex Radar latest card should use a stable model identity")
runner.check(radar56Snapshot.models.first?.validTasks == 9, "Codex Radar should decode valid task counts")
runner.check(radar56Snapshot.models.first?.invalidTasks == 1, "Codex Radar should decode invalid task counts")
runner.check(radar56Snapshot.models.first?.taskSummary == "7/9 · 1 无效", "Codex Radar cards should use valid tasks as the benchmark denominator")
runner.check(radar56Snapshot.models.first?.scoreBand == .healthy, "Codex Radar should color an invalid 116.7 result by score while preserving invalid metadata")
runner.check(radar56Snapshot.signalText == "本次 full reset 已到账，当前窗口关闭", "Codex Radar signal should prefer the expected window")
runner.check(abs((radar56Snapshot.modelRunCostUSD ?? 0) - 66.808014) < 0.000001, "Codex Radar should sum only the five displayed model costs")
runner.check(radar56Snapshot.quotaCalibrationCostUSD == 116.938665, "Codex Radar should expose quota calibration cost separately")
runner.check(radar56Snapshot.costUSD == 116.938665, "Codex Radar should preserve the existing compatible cost value")
runner.check(radar56Snapshot.quotaDate == "2026-07-09-pm", "Codex Radar should expose the quota batch date")
runner.check(radar56Snapshot.quotaTrend.count == 2, "Codex Radar should decode quota trend points")
runner.check(radar56Snapshot.quotaTrendSummary?.startValue == 1922.70, "Codex Radar quota trend should retain its starting value")
runner.check(radar56Snapshot.quotaTrendSummary?.endValue == 1559.16, "Codex Radar quota trend should retain its ending value")
runner.check(abs((radar56Snapshot.quotaTrendSummary?.delta ?? 0) + 363.54) < 0.000001, "Codex Radar quota trend should calculate the signed delta")
runner.check(abs((radar56Snapshot.quotaTrendSummary?.percentChange ?? 0) + 18.907785) < 0.0001, "Codex Radar quota trend should calculate percent change")
runner.check(radar56Snapshot.quotaTrendSummary?.direction == .negative, "a lower 7d quota estimate should use negative trend semantics")
runner.check(radar56Snapshot.quotaRows.map(\.displayBasis) == ["实测", "推测", "推测"], "Codex Radar quota basis should use concise Chinese labels")
runner.check(CodexRadarCurrencyFormatter.displayText(1559.16) == "$1,559.16", "Codex Radar currency should include a symbol, grouping, and two decimals")
runner.check(CodexRadarBatchDateFormatter.displayText("2026-07-10-am") == "7/10 AM", "Codex Radar should format morning benchmark batches compactly")
runner.check(CodexRadarBatchDateFormatter.displayText("2026-07-10-pm") == "7/10 PM", "Codex Radar should format afternoon benchmark batches compactly")
runner.check(CodexRadarScoreBand.classify(nil) == .unknown, "missing Radar scores should use a neutral band")
runner.check(CodexRadarScoreBand.classify(30) == .critical, "Radar scores below 60 should be critical")
runner.check(CodexRadarScoreBand.classify(59.9) == .critical, "Radar critical band should end below 60")
runner.check(CodexRadarScoreBand.classify(60) == .warning, "Radar scores at 60 should enter the warning band")
runner.check(CodexRadarScoreBand.classify(89.9) == .warning, "Radar warning band should end below 90")
runner.check(CodexRadarScoreBand.classify(90) == .baseline, "Radar scores at 90 should enter the baseline band")
runner.check(CodexRadarScoreBand.classify(109.9) == .baseline, "Radar baseline band should end below 110")
runner.check(CodexRadarScoreBand.classify(110) == .healthy, "Radar scores at 110 should enter the healthy band")
runner.check(CodexRadarScoreBand.classify(116.7) == .healthy, "Radar score 116.7 should be healthy regardless of API status")
runner.check(CodexRadarScoreBand.classify(120) == .healthy, "Radar scores above 110 should remain healthy")

let positiveTrendFixture = String(data: codexRadar56Fixture, encoding: .utf8)!
    .replacingOccurrences(of: "\"seven_d_20x\": 1922.70", with: "\"seven_d_20x\": 1200.00")
    .replacingOccurrences(of: "\"seven_d_20x\": 1559.16", with: "\"seven_d_20x\": 1800.00")
    .data(using: .utf8)!
let positiveTrendSnapshot = try CodexRadarSnapshot.decodePublicSummary(from: positiveTrendFixture, fetchedAt: radarFetchedAt)
runner.check(positiveTrendSnapshot.quotaTrendSummary?.direction == .positive, "a higher 7d quota estimate should use positive trend semantics")
runner.check(positiveTrendSnapshot.quotaTrendSummary?.percentChange == 50, "a positive quota trend should preserve its signed percent change")

let codexRadarFutureFixture = """
{
  "model_iq": {
    "latest": {"date": "2026-08-01-am", "score": 111, "model": "gpt-5.7-nova", "reasoning_effort": "ultra"},
    "comparisons": {
      "gpt_57_orbit_medium": {"latest": {"score": 82, "model": "gpt-5.7-orbit", "reasoning_effort": "medium"}},
      "gpt_57_nova_low": {"latest": {"score": 103, "model": "gpt-5.7-nova", "reasoning_effort": "low"}}
    }
  }
}
""".data(using: .utf8)!
let radarFutureSnapshot = try CodexRadarSnapshot.decodePublicSummary(from: codexRadarFutureFixture, fetchedAt: radarFetchedAt)
runner.check(radarFutureSnapshot.models.map(\.label) == [
    "GPT-5.7 Nova ultra",
    "GPT-5.7 Nova low",
    "GPT-5.7 Orbit medium"
], "Codex Radar should display unknown future model families without hard-coded keys")
runner.check(radarFutureSnapshot.modelRunCostUSD == nil, "Codex Radar should not invent a model run cost when all model costs are missing")
runner.check(radarFutureSnapshot.quotaTrend.isEmpty, "Codex Radar should allow missing quota trend data")
runner.check(radarFutureSnapshot.quotaTrendSummary == nil, "Codex Radar should hide trend summaries with fewer than two points")

let radarMissingModelIQ = """
{
  "monitored_at": "2026-07-01T06:27:00+08:00",
  "api_access": {
    "requirements": {
      "attribution_required": true,
      "attribution_text": "数据来自 Codex 雷达 codexradar.com",
      "site": "https://codexradar.com"
    }
  }
}
""".data(using: .utf8)!
let missingModelSnapshot = try CodexRadarSnapshot.decodePublicSummary(from: radarMissingModelIQ, fetchedAt: radarFetchedAt)
runner.check(missingModelSnapshot.models.isEmpty, "Codex Radar should degrade when model_iq is missing")
runner.check(missingModelSnapshot.quotaRows.isEmpty, "Codex Radar should degrade when quota radar is missing")
runner.check(missingModelSnapshot.attributionText == CodexRadarSnapshot.defaultAttributionText, "Codex Radar should keep attribution on partial data")

let radarMissingComparisons = """
{
  "monitored_at": "2026-07-01T06:27:00+08:00",
  "model_iq": {
    "latest": {
      "score": 62.5,
      "status": "red",
      "passed": 5,
      "tasks": 12
    },
    "quota_radar": {
      "rows": []
    }
  }
}
""".data(using: .utf8)!
let missingComparisonsSnapshot = try CodexRadarSnapshot.decodePublicSummary(from: radarMissingComparisons, fetchedAt: radarFetchedAt)
runner.check(missingComparisonsSnapshot.models.count == 1, "Codex Radar should still show latest model when comparisons are missing")
runner.check(missingComparisonsSnapshot.quotaRows.isEmpty, "Codex Radar should allow an empty quota radar row list")

runner.check(
    CodexRadarClient.isAllowedPublicSummaryURL(URL(string: "https://codexradar.com/current.json")!),
    "Codex Radar client should allow the public summary URL"
)
runner.check(
    CodexRadarClient.isAllowedAuthorizedAPIURL(URL(string: "https://codexradar.com/api/v1/current")!),
    "Codex Radar client should allow the authorized current API URL"
)
runner.check(
    !CodexRadarClient.isAllowedPublicSummaryURL(URL(string: "https://codexradar.com/api/v1/current")!),
    "Codex Radar public summary allowlist should not allow the API URL"
)
runner.check(
    !CodexRadarClient.isAllowedPublicSummaryURL(URL(string: "https://codexradar.com@evil.example.com/current.json")!),
    "Codex Radar client should reject userinfo spoofing"
)
runner.check(
    !CodexRadarClient.isAllowedPublicSummaryURL(URL(string: "http://codexradar.com/current.json")!),
    "Codex Radar client should require HTTPS"
)
runner.check(
    !CodexRadarClient.isAllowedAuthorizedAPIURL(URL(string: "http://codexradar.com/api/v1/current")!),
    "Codex Radar authorized API should require HTTPS"
)
runner.check(
    !CodexRadarClient.isAllowedAuthorizedAPIURL(URL(string: "https://codexradar.com@evil.example.com/api/v1/current")!),
    "Codex Radar authorized API should reject userinfo spoofing"
)

func radarResponse(for request: URLRequest, status: Int, data: Data) -> (Data, URLResponse) {
    let response = HTTPURLResponse(
        url: request.url!,
        statusCode: status,
        httpVersion: "HTTP/2",
        headerFields: ["Content-Type": "application/json"]
    )!
    return (data, response)
}

let authorizedRecorder = RequestPathRecorder()
let authorizedRadarClient = CodexRadarClient(
    requestExecutor: { request in
        authorizedRecorder.append(request.url?.path ?? "")
        return radarResponse(for: request, status: 200, data: codexRadar56Fixture)
    }
)
let authorizedFetch = try waitForAsync { try await authorizedRadarClient.fetchSummary(bearerToken: "test-token") }
runner.check(authorizedFetch.source == .authorizedAPI, "Codex Radar should use the authorized API when a token is available")
runner.check(authorizedFetch.fallbackReason == nil, "a successful authorized API request should not report fallback")
runner.check(authorizedRecorder.paths == ["/api/v1/current"], "a successful API request should not call the public summary")

let publicRecorder = RequestPathRecorder()
let publicRadarClient = CodexRadarClient(
    requestExecutor: { request in
        publicRecorder.append(request.url?.path ?? "")
        return radarResponse(for: request, status: 200, data: codexRadar56Fixture)
    }
)
let publicFetch = try waitForAsync { try await publicRadarClient.fetchSummary(bearerToken: nil) }
runner.check(publicFetch.source == .publicSummary, "Codex Radar should use the public summary when no token is configured")
runner.check(publicFetch.fallbackReason == nil, "normal public mode should not be labeled as API fallback")
runner.check(publicRecorder.paths == ["/current.json"], "no-token mode should not call the authorized API")

let fallbackRecorder = RequestPathRecorder()
let fallbackRadarClient = CodexRadarClient(
    requestExecutor: { request in
        fallbackRecorder.append(request.url?.path ?? "")
        if request.url?.path == "/api/v1/current" {
            return radarResponse(for: request, status: 401, data: Data())
        }
        return radarResponse(for: request, status: 200, data: codexRadar56Fixture)
    }
)
let fallbackFetch = try waitForAsync { try await fallbackRadarClient.fetchSummary(bearerToken: "expired-token") }
runner.check(fallbackFetch.source == .publicSummary, "an unauthorized API request should fall back to the public summary")
runner.check(fallbackFetch.fallbackReason == .invalidToken, "401 fallback should identify an invalid token")
runner.check(fallbackRecorder.paths == ["/api/v1/current", "/current.json"], "API fallback should make exactly one public request")
runner.check(CodexRadarClient.fallbackReason(for: CodexRadarClientError.httpStatus(403)) == .invalidToken, "403 should identify an invalid Radar token")
runner.check(CodexRadarClient.fallbackReason(for: CodexRadarClientError.httpStatus(429)) == .apiUnavailable, "429 should use the temporary API fallback")
runner.check(CodexRadarClient.fallbackReason(for: CodexRadarClientError.httpStatus(500)) == .apiUnavailable, "5xx should use the temporary API fallback")
runner.check(CodexRadarClient.fallbackReason(for: URLError(.timedOut)) == .apiUnavailable, "timeouts should use the temporary API fallback")
runner.check(CodexRadarClient.fallbackReason(for: CodexRadarClientError.disallowedURL) == nil, "URL allowlist failures must not silently fall back")
runner.check(
    CodexRadarCredentialRefreshPolicy.fallbackReason(for: .interactionRequired) == .credentialAuthorizationRequired,
    "a blocked startup credential should report deferred authorization instead of an invalid token"
)
runner.check(
    CodexRadarCredentialRefreshPolicy.shouldForceAuthorizedRefresh(
        currentSource: .publicSummary,
        currentFallbackReason: .credentialAuthorizationRequired,
        credential: CodexRadarCredential(token: "available-token", source: .secretStore)
    ),
    "presenting Radar should immediately upgrade a Public snapshot when the user authorizes a token"
)
runner.check(
    !CodexRadarCredentialRefreshPolicy.shouldForceAuthorizedRefresh(
        currentSource: .authorizedAPI,
        currentFallbackReason: nil,
        credential: CodexRadarCredential(token: "available-token", source: .secretStore)
    ),
    "presenting Radar should not force another fetch when the current snapshot already uses the authorized API"
)
runner.check(
    !CodexRadarCredentialRefreshPolicy.shouldForceAuthorizedRefresh(
        currentSource: .publicSummary,
        currentFallbackReason: .invalidToken,
        credential: CodexRadarCredential(token: "invalid-token", source: .secretStore)
    ),
    "presenting Radar should not repeatedly retry a token that already fell back as invalid"
)

let fallbackSnapshot = try CodexRadarSnapshot.decodePublicSummary(
    from: codexRadar56Fixture,
    fetchedAt: radarFetchedAt,
    dataSource: .publicSummary,
    fallbackReason: .invalidToken
)
runner.check(fallbackSnapshot.fallbackReason == .invalidToken, "Codex Radar snapshots should retain their API fallback reason")
runner.check(fallbackSnapshot.message == "API Token 无效，已使用公开摘要", "Codex Radar fallback should expose a user-facing source notice")

let legacyRadarMetadata = """
{"lastFetchAt":"2026-07-10T00:20:07Z","source":"authorizedAPI"}
""".data(using: .utf8)!
let metadataDecoder = JSONDecoder()
metadataDecoder.dateDecodingStrategy = .iso8601
let decodedLegacyRadarMetadata = try metadataDecoder.decode(CodexRadarCacheMetadata.self, from: legacyRadarMetadata)
runner.check(decodedLegacyRadarMetadata.fallbackReason == nil, "legacy Radar cache metadata should decode without a fallback field")
let fallbackRadarMetadata = CodexRadarCacheMetadata(
    lastFetchAt: radarFetchedAt,
    source: .publicSummary,
    fallbackReason: .apiUnavailable
)
let metadataEncoder = JSONEncoder()
metadataEncoder.dateEncodingStrategy = .iso8601
let encodedFallbackRadarMetadata = try metadataEncoder.encode(fallbackRadarMetadata)
let decodedFallbackRadarMetadata = try metadataDecoder.decode(CodexRadarCacheMetadata.self, from: encodedFallbackRadarMetadata)
runner.check(decodedFallbackRadarMetadata == fallbackRadarMetadata, "Radar cache metadata should preserve fallback source state")

let radarCalendar = CodexRadarRefreshPolicy.beijingCalendar
let beforeMorningSlot = dateFromISO8601("2026-07-01T07:00:00+08:00", message: "before morning slot date should parse")
let morningSlot = dateFromISO8601("2026-07-01T08:20:00+08:00", message: "morning slot date should parse")
let afternoonSlot = dateFromISO8601("2026-07-01T14:20:00+08:00", message: "afternoon slot date should parse")
let afterAfternoonSlot = dateFromISO8601("2026-07-01T14:30:00+08:00", message: "after afternoon slot date should parse")
runner.check(
    CodexRadarRefreshPolicy.nextScheduledRefresh(after: beforeMorningSlot, calendar: radarCalendar) == morningSlot,
    "Codex Radar scheduler should use the Beijing 08:20 refresh point"
)
runner.check(
    CodexRadarRefreshPolicy.nextScheduledRefresh(after: morningSlot, calendar: radarCalendar) == afternoonSlot,
    "Codex Radar scheduler should use the Beijing 14:20 refresh point"
)
runner.check(
    CodexRadarRefreshPolicy.shouldRefresh(lastFetchAt: nil, now: beforeMorningSlot, calendar: radarCalendar),
    "Codex Radar should refresh on first launch with no cache"
)
runner.check(
    !CodexRadarRefreshPolicy.shouldRefresh(
        lastFetchAt: dateFromISO8601("2026-07-01T08:21:00+08:00", message: "fresh cache date should parse"),
        now: dateFromISO8601("2026-07-01T09:00:00+08:00", message: "after morning date should parse"),
        calendar: radarCalendar
    ),
    "Codex Radar should not refresh when cache is fresh for the latest schedule point"
)
runner.check(
    CodexRadarRefreshPolicy.shouldRefresh(
        lastFetchAt: dateFromISO8601("2026-07-01T08:10:00+08:00", message: "stale morning cache date should parse"),
        now: dateFromISO8601("2026-07-01T09:00:00+08:00", message: "after morning stale date should parse"),
        calendar: radarCalendar
    ),
    "Codex Radar should refresh after crossing the 08:20 schedule point"
)
runner.check(
    CodexRadarRefreshPolicy.shouldRefresh(
        lastFetchAt: dateFromISO8601("2026-07-01T08:21:00+08:00", message: "morning cache date should parse"),
        now: afterAfternoonSlot,
        calendar: radarCalendar
    ),
    "Codex Radar should refresh after crossing the 14:20 schedule point"
)
runner.check(
    !CodexRadarRefreshPolicy.shouldRefresh(
        lastFetchAt: dateFromISO8601("2026-07-01T14:21:00+08:00", message: "fresh afternoon cache date should parse"),
        now: afterAfternoonSlot,
        calendar: radarCalendar
    ),
    "Codex Radar should only refresh once per schedule point"
)
runner.check(
    !CodexRadarRefreshPolicy.shouldRefreshOnPresentation(
        lastFetchAt: beforeMorningSlot,
        now: beforeMorningSlot.addingTimeInterval(29 * 60)
    ),
    "Codex Radar presentation refresh should keep a cache younger than 30 minutes"
)
runner.check(
    CodexRadarRefreshPolicy.shouldRefreshOnPresentation(
        lastFetchAt: beforeMorningSlot,
        now: beforeMorningSlot.addingTimeInterval(30 * 60)
    ),
    "Codex Radar presentation refresh should refresh a 30 minute old cache"
)
runner.check(
    !CodexRadarRefreshPolicy.canManualRefresh(
        lastManualRefreshAt: beforeMorningSlot,
        now: beforeMorningSlot.addingTimeInterval(299)
    ),
    "Codex Radar manual refresh should enforce a 5 minute gap"
)
runner.check(
    CodexRadarRefreshPolicy.canManualRefresh(
        lastManualRefreshAt: beforeMorningSlot,
        now: beforeMorningSlot.addingTimeInterval(300)
    ),
    "Codex Radar manual refresh should be allowed after 5 minutes"
)

final class FakeLaunchAtLoginManager: LaunchAtLoginManaging {
    var isEnabled: Bool

    init(isEnabled: Bool = false) {
        self.isEnabled = isEnabled
    }

    func setEnabled(_ enabled: Bool) throws {
        isEnabled = enabled
    }
}

enum CountingSecretStoreError: Error {
    case load
    case save
    case delete
}

final class CountingSecretStore: SecretStore {
    private var vault: SecretVault
    private let failOnLoad: Bool
    private let failOnNonInteractiveLoad: Bool
    var failOnSave: Bool
    var failOnDelete: Bool
    private(set) var loadCount = 0
    private(set) var loadAccessModes: [SecretStoreAccessMode] = []
    private(set) var saveCount = 0
    private(set) var deleteCount = 0

    init(
        vault: SecretVault = SecretVault(),
        failOnLoad: Bool = false,
        failOnNonInteractiveLoad: Bool = false,
        failOnSave: Bool = false,
        failOnDelete: Bool = false
    ) {
        self.vault = vault
        self.failOnLoad = failOnLoad
        self.failOnNonInteractiveLoad = failOnNonInteractiveLoad
        self.failOnSave = failOnSave
        self.failOnDelete = failOnDelete
    }

    func loadVault(accessMode: SecretStoreAccessMode) throws -> SecretVault {
        loadCount += 1
        loadAccessModes.append(accessMode)
        if failOnNonInteractiveLoad, accessMode == .nonInteractive {
            throw SecretStoreAccessError.interactionRequired
        }
        if failOnLoad {
            throw CountingSecretStoreError.load
        }
        return vault
    }

    func saveVault(_ vault: SecretVault) throws {
        saveCount += 1
        if failOnSave {
            throw CountingSecretStoreError.save
        }
        self.vault = vault
    }

    func deleteVault() throws {
        deleteCount += 1
        if failOnDelete {
            throw CountingSecretStoreError.delete
        }
        vault = SecretVault()
    }
}

func remoteAccount(
    id: String,
    state: RemoteAccountState,
    quotaWindows: [RemoteQuotaWindow] = [],
    quotaError: String? = nil,
    unavailable: Bool = false
) -> RemoteCodexAccount {
    RemoteCodexAccount(
        id: id,
        name: id,
        email: nil,
        label: nil,
        provider: "codex",
        accountType: nil,
        authIndex: id,
        chatgptAccountID: nil,
        status: state == .abnormal ? "error" : "active",
        statusMessage: state == .abnormal ? "auth failed" : nil,
        successCount: 1,
        failureCount: state == .abnormal ? 1 : 0,
        recentFailures: state == .abnormal ? 1 : 0,
        state: state,
        lastRefresh: nil,
        planType: "plus",
        quotaWindows: quotaWindows,
        quotaError: quotaError,
        unavailable: unavailable
    )
}

let exhaustedFiveHourWindow = RemoteQuotaWindow(
    id: "code-primary",
    shortLabel: "5h",
    remainingPercent: 0,
    usedPercent: 100,
    resetText: nil
)
let exhaustedWeeklyWindow = RemoteQuotaWindow(
    id: "code-secondary",
    shortLabel: "7d",
    remainingPercent: 0,
    usedPercent: 100,
    resetText: nil
)
let proQuotaAccount = remoteAccount(
    id: "pro-four-windows",
    state: .healthy,
    quotaWindows: [
        RemoteQuotaWindow(id: "primary", shortLabel: "5h", remainingPercent: 98, usedPercent: 2, resetText: nil),
        RemoteQuotaWindow(id: "secondary", shortLabel: "7d", remainingPercent: 60, usedPercent: 40, resetText: nil),
        RemoteQuotaWindow(id: "pro-20x", shortLabel: "Pro 20x", remainingPercent: 100, usedPercent: 0, resetText: nil),
        RemoteQuotaWindow(id: "pro-5x", shortLabel: "Pro 5x", remainingPercent: 80, usedPercent: 20, resetText: nil),
        RemoteQuotaWindow(id: "spark-5h", shortLabel: "GPT-5.3-Codex-Spark 5h", remainingPercent: 100, usedPercent: 0, resetText: nil),
        RemoteQuotaWindow(id: "spark-7d", shortLabel: "GPT-5.3-Codex-Spark 7d", remainingPercent: 100, usedPercent: 0, resetText: nil)
    ]
)
runner.check(proQuotaAccount.displayQuotaWindows.map(\.shortLabel) == ["5h", "7d"], "CLIProxyAPI Pro account detail should only display bare 5h and 7d quota windows")
runner.check(proQuotaAccount.quotaSummaryText == "5h 98%  7d 60%", "CLIProxyAPI Pro account quota summary should hide extra Pro quota windows")
let modelOnlyQuotaAccount = remoteAccount(
    id: "model-only-windows",
    state: .healthy,
    quotaWindows: [
        RemoteQuotaWindow(id: "spark-5h", shortLabel: "GPT-5.3-Codex-Spark 5h", remainingPercent: 100, usedPercent: 0, resetText: nil),
        RemoteQuotaWindow(id: "spark-7d", shortLabel: "GPT-5.3-Codex-Spark 7d", remainingPercent: 100, usedPercent: 0, resetText: nil)
    ]
)
runner.check(modelOnlyQuotaAccount.displayQuotaWindows.isEmpty, "CLIProxyAPI detail should not fall back to displaying model quota windows when bare 5h/7d are missing")
runner.check(modelOnlyQuotaAccount.quotaSummaryText == "额度 --", "CLIProxyAPI quota summary should stay empty when only hidden model windows are available")

runner.check(RefreshCadence.pendingSnapshotDelay(for: 2) == 1, "coalesced snapshot refresh should wait at least one second")
runner.check(RefreshCadence.pendingSnapshotDelay(for: 6) == 3, "coalesced snapshot refresh should cap short follow-up waits")
runner.check(RefreshCadence.pendingUsageDelay(for: 30) == 8, "coalesced usage refresh should wait instead of immediately restarting")
runner.check(RefreshCadence.pendingUsageDelay(for: 300) == 15, "coalesced usage refresh should cap long follow-up waits")
runner.check(BalanceRefreshCadence.refreshInterval(base: 300, consecutiveFailures: 0) == 300, "healthy balance refresh should use the configured interval")
runner.check(BalanceRefreshCadence.refreshInterval(base: 300, consecutiveFailures: 1) == 30, "failed balance refresh should retry quickly instead of leaving stale timeout state")
runner.check(BalanceRefreshCadence.refreshInterval(base: 60, consecutiveFailures: 3) == 30, "repeated balance failures should cap retry interval")

let settingsSuiteName = "CodexNotchRegressionTests-\(UUID().uuidString)"
let settingsDefaults = runner.require(
    UserDefaults(suiteName: settingsSuiteName),
    "settings regression defaults should be available"
)
settingsDefaults.removePersistentDomain(forName: settingsSuiteName)
var secretVault = SecretVault()
secretVault.set("clip-secret", for: .cliproxyManagement)
secretVault.set("newapi-legacy", for: .newAPIManagement)
secretVault.set("subapi-legacy", for: .subAPIManagement)
secretVault.set("radar-secret", for: .codexRadarAPI)
secretVault.set("account-secret", for: .balanceAccount(source: .newAPI, id: "account-1"))
runner.check(secretVault.value(for: .cliproxyManagement) == "clip-secret", "secret vault should store CLIProxyAPI key")
runner.check(secretVault.value(for: .codexRadarAPI) == "radar-secret", "secret vault should store the Codex Radar token")
runner.check(secretVault.value(for: .balanceAccount(source: .newAPI, id: "account-1")) == "account-secret", "secret vault should store account secret")
secretVault.set("", for: .balanceAccount(source: .newAPI, id: "account-1"))
runner.check(secretVault.value(for: .balanceAccount(source: .newAPI, id: "account-1")).isEmpty, "empty secret should remove vault entry")
let memorySecretStore = MemorySecretStore()
try memorySecretStore.saveVault(secretVault)
let loadedMemoryVault = try memorySecretStore.loadVault()
runner.check(loadedMemoryVault == secretVault, "memory secret store should persist one vault")
let secretDatabaseURL = FileManager.default.temporaryDirectory
    .appendingPathComponent("CodexNotchSecretStore-\(UUID().uuidString)")
    .appendingPathComponent("secrets.sqlite3")
let databaseSecretStore = DatabaseSecretStore(databaseURL: secretDatabaseURL)
try databaseSecretStore.saveVault(secretVault)
let loadedDatabaseVault = try databaseSecretStore.loadVault()
runner.check(loadedDatabaseVault == secretVault, "database secret store should persist one vault")
let databasePayloadType = try Shell.sqliteJSON(
    database: secretDatabaseURL.path,
    query: "select typeof(payload) as value from secret_vault where id = 'default';",
    as: [[String: String]].self,
    readOnly: true
).first?["value"]
runner.check(databasePayloadType == "blob", "database secret store should bind the vault as a blob")
try databaseSecretStore.deleteVault()
let deletedDatabaseVault = try databaseSecretStore.loadVault()
runner.check(deletedDatabaseVault.isEmpty, "database secret store should delete the vault row")

let legacyVaultData = try JSONEncoder().encode(secretVault)
let legacyEncodedVault = legacyVaultData.base64EncodedString()
try Shell.sqliteExec(
    database: secretDatabaseURL.path,
    query: "insert or replace into secret_vault(id, payload, updated_at) values('default', '\(legacyEncodedVault)', 0);"
)
let loadedLegacyDatabaseVault = try databaseSecretStore.loadVault()
runner.check(loadedLegacyDatabaseVault == secretVault, "database secret store should read legacy Base64 vault rows")
try Shell.sqliteExec(
    database: secretDatabaseURL.path,
    query: "update secret_vault set payload = X'00FF' where id = 'default';"
)
do {
    _ = try databaseSecretStore.loadVault()
    runner.check(false, "corrupt database vault should throw")
} catch DatabaseSecretStoreError.corruptPayload {
    runner.check(true, "corrupt database vault should be reported explicitly")
} catch {
    runner.check(false, "corrupt database vault should use the dedicated error")
}
try? FileManager.default.removeItem(at: secretDatabaseURL.deletingLastPathComponent())

var lazyStartupVault = SecretVault()
lazyStartupVault.set("lazy-clip-secret", for: .cliproxyManagement)
let lazyStartupKeychainStore = CountingSecretStore(vault: lazyStartupVault)
let lazyStartupSuiteName = "CodexNotchLazySecrets-\(UUID().uuidString)"
let lazyStartupDefaults = runner.require(
    UserDefaults(suiteName: lazyStartupSuiteName),
    "lazy secret defaults should be available"
)
lazyStartupDefaults.removePersistentDomain(forName: lazyStartupSuiteName)
let lazyStartupSettings = CodexNotchSettings(
    defaults: lazyStartupDefaults,
    secretStores: SecretStoreFactory(keychain: lazyStartupKeychainStore, database: MemorySecretStore()),
    launchAtLoginManager: FakeLaunchAtLoginManager()
)
runner.check(lazyStartupKeychainStore.loadCount == 0, "settings startup should not read Keychain when remote monitors are disabled")
runner.check(lazyStartupSettings.cliproxyManagementKey.isEmpty, "lazy settings should leave CLIProxyAPI key unloaded at startup")
runner.check(!lazyStartupSettings.secretsAreLoaded, "settings should expose unloaded secret state before remote features need credentials")
lazyStartupSettings.codexRadarEnabled = false
lazyStartupSettings.showSparkQuota = true
lazyStartupSettings.resetRefreshDefaults()
runner.check(lazyStartupKeychainStore.loadCount == 0, "local settings changes should not read Keychain")
runner.check(lazyStartupKeychainStore.saveCount == 0, "local settings changes should not write secret storage")
lazyStartupSettings.skillInsightsEnabled = false
var disabledSkillFeatureFactoryCalls = 0
let disabledSkillFeature = SkillInsightsFeatureCoordinator(settings: lazyStartupSettings) {
    disabledSkillFeatureFactoryCalls += 1
    return SkillInsightsViewModel(
        service: SkillInsightsService(
            codexDirectory: FileManager.default.temporaryDirectory
                .appendingPathComponent("DisabledSkillFeature-\(UUID().uuidString)"),
            skillRoots: [],
            databaseURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("disabled-skill-feature-\(UUID().uuidString).sqlite"),
            automaticDeferralReason: { "test policy" }
        )
    )
}
runner.check(!disabledSkillFeature.isEnabled, "disabled Skill Insights should remain uninitialized")
runner.checkEqual(
    disabledSkillFeatureFactoryCalls,
    0,
    "disabled Skill Insights must not construct the catalog, scanner, database, or timer service"
)
runner.check(lazyStartupSettings.loadSecretsIfNeeded(), "explicit secret load should succeed")
runner.check(lazyStartupKeychainStore.loadCount == 1, "explicit secret load should read Keychain once")
runner.check(lazyStartupSettings.cliproxyManagementKey == "lazy-clip-secret", "explicit secret load should populate CLIProxyAPI key")
runner.check(lazyStartupSettings.secretsAreLoaded, "explicit secret load should mark settings secrets as loaded")
lazyStartupDefaults.removePersistentDomain(forName: lazyStartupSuiteName)

let radarCredentialDirectory = FileManager.default.temporaryDirectory
    .appendingPathComponent("CodexRadarCredential-\(UUID().uuidString)", isDirectory: true)
let radarCredentialLegacyFile = radarCredentialDirectory.appendingPathComponent("token")
var protectedRadarVault = SecretVault()
protectedRadarVault.set("vault-radar-token", for: .codexRadarAPI)
let protectedRadarStore = CountingSecretStore(
    vault: protectedRadarVault,
    failOnNonInteractiveLoad: true
)
let protectedRadarSuiteName = "CodexRadarProtectedCredential-\(UUID().uuidString)"
let protectedRadarDefaults = runner.require(
    UserDefaults(suiteName: protectedRadarSuiteName),
    "protected Radar credential defaults should be available"
)
protectedRadarDefaults.removePersistentDomain(forName: protectedRadarSuiteName)
let protectedRadarSettings = CodexNotchSettings(
    defaults: protectedRadarDefaults,
    secretStores: SecretStoreFactory(keychain: protectedRadarStore, database: MemorySecretStore()),
    launchAtLoginManager: FakeLaunchAtLoginManager(),
    environment: [:],
    codexRadarLegacyTokenFileURL: radarCredentialLegacyFile
)
let defaultPublicRadarCredential = protectedRadarSettings.codexRadarCredential(accessMode: .nonInteractive)
runner.check(defaultPublicRadarCredential.token == nil, "Radar should default to the public source without a bearer token")
runner.check(defaultPublicRadarCredential.source == .none, "default Radar access should report the public credential source")
runner.check(protectedRadarStore.loadCount == 0, "default Radar access should not read Keychain")
protectedRadarSettings.codexRadarUsesAuthorizedAPI = true
let backgroundRadarCredential = protectedRadarSettings.codexRadarCredential(accessMode: .nonInteractive)
runner.check(backgroundRadarCredential.token == nil, "background Radar credential reads must not force Keychain authorization")
runner.check(backgroundRadarCredential.source == .interactionRequired, "blocked background Keychain reads should request deferred authorization")
runner.check(!protectedRadarSettings.secretsAreLoaded, "non-interactive Radar reads must not mark the full vault as loaded")
runner.check(protectedRadarStore.loadAccessModes == [.nonInteractive], "startup Radar reads should explicitly disable authentication UI")
let interactiveRadarCredential = protectedRadarSettings.codexRadarCredential(accessMode: .interactive)
runner.check(interactiveRadarCredential.token == "vault-radar-token", "user-initiated Radar reads should load the stored token")
runner.check(interactiveRadarCredential.source == .secretStore, "user-initiated Radar reads should report the unified secret store")
runner.check(protectedRadarSettings.secretsAreLoaded, "interactive Radar reads should load the shared vault")

let environmentRadarStore = CountingSecretStore(vault: protectedRadarVault, failOnNonInteractiveLoad: true)
let environmentRadarSettings = CodexNotchSettings(
    defaults: protectedRadarDefaults,
    secretStores: SecretStoreFactory(keychain: environmentRadarStore, database: MemorySecretStore()),
    launchAtLoginManager: FakeLaunchAtLoginManager(),
    environment: [CodexNotchSettings.codexRadarEnvironmentKey: "  env-radar-token  "],
    codexRadarLegacyTokenFileURL: radarCredentialLegacyFile
)
let environmentRadarCredential = environmentRadarSettings.codexRadarCredential(accessMode: .nonInteractive)
runner.check(environmentRadarCredential.token == "env-radar-token", "Radar environment token should remain the highest-priority temporary override")
runner.check(environmentRadarCredential.source == .environment, "Radar environment overrides should expose their source")
runner.check(environmentRadarStore.loadCount == 0, "Radar environment overrides should not touch Keychain")

try FileManager.default.createDirectory(at: radarCredentialDirectory, withIntermediateDirectories: true)
try Data("  migrated-radar-token  \n".utf8).write(to: radarCredentialLegacyFile, options: .atomic)
let migratedRadarStore = CountingSecretStore()
let migratedRadarSuiteName = "CodexRadarLegacyMigration-\(UUID().uuidString)"
let migratedRadarDefaults = runner.require(
    UserDefaults(suiteName: migratedRadarSuiteName),
    "legacy Radar migration defaults should be available"
)
migratedRadarDefaults.removePersistentDomain(forName: migratedRadarSuiteName)
let migratedRadarSettings = CodexNotchSettings(
    defaults: migratedRadarDefaults,
    secretStores: SecretStoreFactory(keychain: migratedRadarStore, database: MemorySecretStore()),
    launchAtLoginManager: FakeLaunchAtLoginManager(),
    environment: [:],
    codexRadarLegacyTokenFileURL: radarCredentialLegacyFile
)
migratedRadarSettings.codexRadarUsesAuthorizedAPI = true
let migratedRadarCredential = migratedRadarSettings.codexRadarCredential(accessMode: .interactive)
runner.check(migratedRadarCredential.token == "migrated-radar-token", "interactive Radar access should migrate the legacy token file")
runner.check(!FileManager.default.fileExists(atPath: radarCredentialLegacyFile.path), "verified Radar migration should delete the legacy token file")
let migratedRadarVault = try migratedRadarStore.loadVault()
runner.check(migratedRadarVault.value(for: .codexRadarAPI) == "migrated-radar-token", "Radar migration should persist the token in SecretVault")

let retryRadarDirectory = FileManager.default.temporaryDirectory
    .appendingPathComponent("CodexRadarMigrationRetry-\(UUID().uuidString)", isDirectory: true)
let retryRadarLegacyFile = retryRadarDirectory.appendingPathComponent("token")
try FileManager.default.createDirectory(at: retryRadarDirectory, withIntermediateDirectories: true)
try Data("retry-radar-token\n".utf8).write(to: retryRadarLegacyFile, options: .atomic)
let retryRadarStore = CountingSecretStore(failOnSave: true)
let retryRadarSuiteName = "CodexRadarMigrationRetry-\(UUID().uuidString)"
let retryRadarDefaults = runner.require(
    UserDefaults(suiteName: retryRadarSuiteName),
    "Radar migration retry defaults should be available"
)
retryRadarDefaults.removePersistentDomain(forName: retryRadarSuiteName)
let failedRadarMigrationSettings = CodexNotchSettings(
    defaults: retryRadarDefaults,
    secretStores: SecretStoreFactory(keychain: retryRadarStore, database: MemorySecretStore()),
    launchAtLoginManager: FakeLaunchAtLoginManager(),
    environment: [:],
    codexRadarLegacyTokenFileURL: retryRadarLegacyFile
)
failedRadarMigrationSettings.codexRadarUsesAuthorizedAPI = true
let failedRadarMigrationCredential = failedRadarMigrationSettings.codexRadarCredential(accessMode: .interactive)
runner.check(failedRadarMigrationCredential.token == nil, "a failed Radar vault write must not publish an unverified migrated token")
runner.check(FileManager.default.fileExists(atPath: retryRadarLegacyFile.path), "a failed Radar vault write must preserve the legacy token file")
retryRadarStore.failOnSave = false
let recoveredRadarMigrationSettings = CodexNotchSettings(
    defaults: retryRadarDefaults,
    secretStores: SecretStoreFactory(keychain: retryRadarStore, database: MemorySecretStore()),
    launchAtLoginManager: FakeLaunchAtLoginManager(),
    environment: [:],
    codexRadarLegacyTokenFileURL: retryRadarLegacyFile
)
recoveredRadarMigrationSettings.codexRadarUsesAuthorizedAPI = true
let recoveredRadarMigrationCredential = recoveredRadarMigrationSettings.codexRadarCredential(accessMode: .interactive)
runner.check(recoveredRadarMigrationCredential.token == "retry-radar-token", "Radar migration should recover after a failed target write")
runner.check(!FileManager.default.fileExists(atPath: retryRadarLegacyFile.path), "recovered Radar migration should clean the verified legacy file")

let cleanupRetryDirectory = FileManager.default.temporaryDirectory
    .appendingPathComponent("CodexRadarCleanupRetry-\(UUID().uuidString)", isDirectory: true)
let cleanupRetryLegacyFile = cleanupRetryDirectory.appendingPathComponent("token")
try FileManager.default.createDirectory(at: cleanupRetryDirectory, withIntermediateDirectories: true)
try Data("cleanup-retry-token\n".utf8).write(to: cleanupRetryLegacyFile, options: .atomic)
let cleanupRetryStore = CountingSecretStore()
let cleanupRetrySuiteName = "CodexRadarCleanupRetry-\(UUID().uuidString)"
let cleanupRetryDefaults = runner.require(
    UserDefaults(suiteName: cleanupRetrySuiteName),
    "Radar cleanup retry defaults should be available"
)
cleanupRetryDefaults.removePersistentDomain(forName: cleanupRetrySuiteName)
try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: cleanupRetryDirectory.path)
let failedRadarCleanupSettings = CodexNotchSettings(
    defaults: cleanupRetryDefaults,
    secretStores: SecretStoreFactory(keychain: cleanupRetryStore, database: MemorySecretStore()),
    launchAtLoginManager: FakeLaunchAtLoginManager(),
    environment: [:],
    codexRadarLegacyTokenFileURL: cleanupRetryLegacyFile
)
failedRadarCleanupSettings.codexRadarUsesAuthorizedAPI = true
let failedRadarCleanupCredential = failedRadarCleanupSettings.codexRadarCredential(accessMode: .interactive)
runner.check(failedRadarCleanupCredential.token == "cleanup-retry-token", "a verified Radar vault write should remain usable when legacy cleanup fails")
runner.check(FileManager.default.fileExists(atPath: cleanupRetryLegacyFile.path), "failed Radar cleanup should preserve the legacy file for retry")
runner.check(failedRadarCleanupSettings.codexRadarCredentialError?.contains("重试") == true, "failed Radar cleanup should remain visible and retryable")
try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cleanupRetryDirectory.path)
let recoveredRadarCleanupSettings = CodexNotchSettings(
    defaults: cleanupRetryDefaults,
    secretStores: SecretStoreFactory(keychain: cleanupRetryStore, database: MemorySecretStore()),
    launchAtLoginManager: FakeLaunchAtLoginManager(),
    environment: [:],
    codexRadarLegacyTokenFileURL: cleanupRetryLegacyFile
)
recoveredRadarCleanupSettings.codexRadarUsesAuthorizedAPI = true
let recoveredRadarCleanupCredential = recoveredRadarCleanupSettings.codexRadarCredential(accessMode: .interactive)
runner.check(recoveredRadarCleanupCredential.token == "cleanup-retry-token", "Radar cleanup retry should preserve the migrated token")
runner.check(!FileManager.default.fileExists(atPath: cleanupRetryLegacyFile.path), "Radar cleanup retry should remove the verified legacy file")

try Data("conflicting-file-token\n".utf8).write(to: radarCredentialLegacyFile, options: .atomic)
var conflictRadarVault = SecretVault()
conflictRadarVault.set("existing-vault-token", for: .codexRadarAPI)
let conflictRadarStore = CountingSecretStore(vault: conflictRadarVault)
let conflictRadarSettings = CodexNotchSettings(
    defaults: migratedRadarDefaults,
    secretStores: SecretStoreFactory(keychain: conflictRadarStore, database: MemorySecretStore()),
    launchAtLoginManager: FakeLaunchAtLoginManager(),
    environment: [:],
    codexRadarLegacyTokenFileURL: radarCredentialLegacyFile
)
conflictRadarSettings.codexRadarUsesAuthorizedAPI = true
let conflictRadarCredential = conflictRadarSettings.codexRadarCredential(accessMode: .interactive)
runner.check(conflictRadarCredential.token == "existing-vault-token", "an existing vault token should win over a conflicting legacy file")
runner.check(FileManager.default.fileExists(atPath: radarCredentialLegacyFile.path), "a conflicting legacy Radar token must be preserved for explicit resolution")
runner.check(conflictRadarSettings.codexRadarCredentialError != nil, "a conflicting legacy Radar token should produce an actionable settings error")
try conflictRadarSettings.setCodexRadarAPIToken("replacement-token")
runner.check(!FileManager.default.fileExists(atPath: radarCredentialLegacyFile.path), "explicit Radar token save should clean a conflicting legacy file after verification")
let replacedRadarVault = try conflictRadarStore.loadVault()
runner.check(replacedRadarVault.value(for: .codexRadarAPI) == "replacement-token", "explicit Radar token save should update the unified vault")
conflictRadarStore.failOnSave = true
do {
    try conflictRadarSettings.setCodexRadarAPIToken("unverified-token")
    runner.check(false, "an explicit Radar token write failure should throw")
} catch {
    runner.check(true, "an explicit Radar token write failure should remain visible")
}
runner.check(
    conflictRadarSettings.codexRadarCredential(accessMode: .interactive).token == "replacement-token",
    "a failed explicit Radar token write must not publish the unverified in-memory value"
)
conflictRadarStore.failOnSave = false

protectedRadarDefaults.removePersistentDomain(forName: protectedRadarSuiteName)
migratedRadarDefaults.removePersistentDomain(forName: migratedRadarSuiteName)
retryRadarDefaults.removePersistentDomain(forName: retryRadarSuiteName)
cleanupRetryDefaults.removePersistentDomain(forName: cleanupRetrySuiteName)
try? FileManager.default.removeItem(at: radarCredentialDirectory)
try? FileManager.default.removeItem(at: retryRadarDirectory)
try? FileManager.default.removeItem(at: cleanupRetryDirectory)

let settings = CodexNotchSettings(
    defaults: settingsDefaults,
    initialManagementKey: "",
    initialNewAPIKey: "",
    initialSubAPIKey: "",
    secretStores: SecretStoreFactory(keychain: MemorySecretStore(), database: MemorySecretStore()),
    launchAtLoginManager: FakeLaunchAtLoginManager()
)
settings.activeRefreshInterval = settings.activeRefreshInterval
settings.idleRefreshInterval = settings.idleRefreshInterval
settings.usageRefreshInterval = settings.usageRefreshInterval
settings.watcherRefreshInterval = settings.watcherRefreshInterval
settings.fileChangeRefreshMinimumGap = settings.fileChangeRefreshMinimumGap
settings.cliproxyRefreshInterval = settings.cliproxyRefreshInterval
settings.cliproxyRequestTimeout = settings.cliproxyRequestTimeout
runner.check(settings.activeRefreshInterval == 30, "saving unchanged refresh intervals should keep the folded low-power active default")
runner.check(settings.idleRefreshInterval == 180, "saving unchanged refresh intervals should keep the folded low-power idle default")
runner.check(settings.usageRefreshInterval == 300, "saving unchanged refresh intervals should keep the low-power usage default")
runner.check(settings.watcherRefreshInterval == 180, "saving unchanged refresh intervals should keep the folded low-power watcher default")
runner.check(settings.fileChangeRefreshMinimumGap == 15, "saving unchanged refresh intervals should keep the folded low-power debounce default")
runner.check(settings.codexRadarEnabled, "Codex Radar should default to enabled")
runner.check(!settings.codexRadarUsesAuthorizedAPI, "Codex Radar should default to Public without reading Keychain")
runner.check(settings.hudDisplayMode == .floatingHUD, "HUD should default to the existing floating presentation")
runner.check(HUDDisplayMode.allCases == [.floatingHUD, .menuBar], "HUD should expose floating and menu-bar display modes")
runner.check(
    HUDPresentationVisibility(mode: .floatingHUD) == HUDPresentationVisibility(showsFloatingHUD: true, showsMenuBarItem: false),
    "floating mode should expose only the floating HUD entry point"
)
runner.check(
    HUDPresentationVisibility(mode: .menuBar) == HUDPresentationVisibility(showsFloatingHUD: false, showsMenuBarItem: true),
    "menu-bar mode should expose only the status item entry point"
)
runner.check(
    HUDDisplaySourceResolver.resolve(
        selected: .automatic,
        remoteEnabled: true,
        remoteSeverity: .warning,
        newAPIEnabled: true,
        newAPISeverity: .error,
        subAPIEnabled: false,
        subAPISeverity: .none
    ) == .newAPI,
    "automatic HUD source selection should stay consistent across floating and menu-bar modes"
)
runner.check(
    HUDDisplaySourceResolver.resolve(
        selected: .newAPI,
        remoteEnabled: false,
        remoteSeverity: .none,
        newAPIEnabled: false,
        newAPISeverity: .none,
        subAPIEnabled: false,
        subAPISeverity: .none
    ) == .codex,
    "a disabled explicit HUD source should fall back to Codex in both display modes"
)
settings.hudDisplayMode = .menuBar
let menuBarModeReloadedSettings = CodexNotchSettings(
    defaults: settingsDefaults,
    secretStores: SecretStoreFactory(keychain: MemorySecretStore(), database: MemorySecretStore()),
    launchAtLoginManager: FakeLaunchAtLoginManager()
)
runner.check(menuBarModeReloadedSettings.hudDisplayMode == .menuBar, "menu-bar HUD mode should persist across launches")
settings.hudDisplayMode = .floatingHUD
runner.check(settings.overlayHorizontalPosition == 0, "overlay position should default to the primary screen center")
runner.check(settings.overlayVerticalPosition == 0, "overlay position should default to the top edge")
settings.setOverlayPosition(horizontal: 0.42, vertical: 0.36)
let overlayPositionReloadedSettings = CodexNotchSettings(
    defaults: settingsDefaults,
    secretStores: SecretStoreFactory(keychain: MemorySecretStore(), database: MemorySecretStore()),
    launchAtLoginManager: FakeLaunchAtLoginManager()
)
runner.check(
    abs(overlayPositionReloadedSettings.overlayHorizontalPosition - 0.42) < 0.001,
    "horizontal overlay position should persist across app restarts"
)
runner.check(
    abs(overlayPositionReloadedSettings.overlayVerticalPosition - 0.36) < 0.001,
    "vertical overlay position should persist across app restarts"
)
overlayPositionReloadedSettings.setOverlayHorizontalPosition(4)
runner.check(overlayPositionReloadedSettings.overlayHorizontalPosition == 1, "persisted overlay position should clamp to the right edge")
overlayPositionReloadedSettings.setOverlayVerticalPosition(4)
runner.check(overlayPositionReloadedSettings.overlayVerticalPosition == 1, "persisted overlay position should clamp to the bottom edge")
overlayPositionReloadedSettings.resetOverlayPosition()
runner.check(overlayPositionReloadedSettings.overlayHorizontalPosition == 0, "reset should return the overlay to the default center")
runner.check(overlayPositionReloadedSettings.overlayVerticalPosition == 0, "reset should return the overlay to the default top edge")
runner.check(settingsDefaults.object(forKey: "overlayHorizontalPosition") == nil, "reset should clear the persisted overlay position")
runner.check(settingsDefaults.object(forKey: "overlayVerticalPosition") == nil, "reset should clear the persisted vertical overlay position")
runner.check(!settings.showSparkQuota, "Spark quota display should default to disabled")
runner.check(!settings.showContextMetrics, "context metrics display should default to disabled")
settings.activeRefreshInterval = 2
settings.idleRefreshInterval = 4
settings.usageRefreshInterval = 15
settings.watcherRefreshInterval = 8
settings.fileChangeRefreshMinimumGap = 1
settings.resetRefreshDefaults()
runner.check(settings.activeRefreshInterval == 30, "reset refresh defaults should restore folded low-power active refresh")
runner.check(settings.idleRefreshInterval == 180, "reset refresh defaults should restore folded low-power idle refresh")
runner.check(settings.usageRefreshInterval == 300, "reset refresh defaults should restore low-power usage refresh")
runner.check(settings.watcherRefreshInterval == 180, "reset refresh defaults should restore folded low-power watcher refresh")
runner.check(settings.fileChangeRefreshMinimumGap == 15, "reset refresh defaults should restore folded low-power debounce")

let legacyRefreshSuiteName = "CodexNotchLegacyRefresh-\(UUID().uuidString)"
let legacyRefreshDefaults = runner.require(
    UserDefaults(suiteName: legacyRefreshSuiteName),
    "legacy refresh defaults should be available"
)
legacyRefreshDefaults.removePersistentDomain(forName: legacyRefreshSuiteName)
legacyRefreshDefaults.set(3, forKey: "activeRefreshInterval")
legacyRefreshDefaults.set(6, forKey: "idleRefreshInterval")
legacyRefreshDefaults.set(30, forKey: "usageRefreshInterval")
legacyRefreshDefaults.set(12, forKey: "watcherRefreshInterval")
legacyRefreshDefaults.set(3, forKey: "fileChangeRefreshMinimumGap")
let migratedLegacyRefreshSettings = CodexNotchSettings(
    defaults: legacyRefreshDefaults,
    initialManagementKey: "",
    initialNewAPIKey: "",
    initialSubAPIKey: "",
    secretStores: SecretStoreFactory(keychain: MemorySecretStore(), database: MemorySecretStore()),
    launchAtLoginManager: FakeLaunchAtLoginManager()
)
runner.check(migratedLegacyRefreshSettings.activeRefreshInterval == 30, "legacy refresh defaults should migrate to folded low-power active refresh")
runner.check(migratedLegacyRefreshSettings.idleRefreshInterval == 180, "legacy refresh defaults should migrate to folded low-power idle refresh")
runner.check(migratedLegacyRefreshSettings.usageRefreshInterval == 300, "legacy refresh defaults should migrate to low-power usage refresh")
runner.check(migratedLegacyRefreshSettings.watcherRefreshInterval == 180, "legacy refresh defaults should migrate to folded low-power watcher refresh")
runner.check(migratedLegacyRefreshSettings.fileChangeRefreshMinimumGap == 15, "legacy refresh defaults should migrate to folded low-power debounce")
legacyRefreshDefaults.removePersistentDomain(forName: legacyRefreshSuiteName)

let previousLowPowerSuiteName = "CodexNotchPreviousLowPower-\(UUID().uuidString)"
let previousLowPowerDefaults = runner.require(
    UserDefaults(suiteName: previousLowPowerSuiteName),
    "previous low-power defaults should be available"
)
previousLowPowerDefaults.removePersistentDomain(forName: previousLowPowerSuiteName)
previousLowPowerDefaults.set(15, forKey: "activeRefreshInterval")
previousLowPowerDefaults.set(90, forKey: "idleRefreshInterval")
previousLowPowerDefaults.set(300, forKey: "usageRefreshInterval")
previousLowPowerDefaults.set(120, forKey: "watcherRefreshInterval")
previousLowPowerDefaults.set(10, forKey: "fileChangeRefreshMinimumGap")
let migratedPreviousLowPowerSettings = CodexNotchSettings(
    defaults: previousLowPowerDefaults,
    initialManagementKey: "",
    initialNewAPIKey: "",
    initialSubAPIKey: "",
    secretStores: SecretStoreFactory(keychain: MemorySecretStore(), database: MemorySecretStore()),
    launchAtLoginManager: FakeLaunchAtLoginManager()
)
runner.check(migratedPreviousLowPowerSettings.activeRefreshInterval == 30, "previous low-power defaults should migrate to folded low-power active refresh")
runner.check(migratedPreviousLowPowerSettings.idleRefreshInterval == 180, "previous low-power defaults should migrate to folded low-power idle refresh")
runner.check(migratedPreviousLowPowerSettings.usageRefreshInterval == 300, "previous low-power defaults should migrate to low-power usage refresh")
runner.check(migratedPreviousLowPowerSettings.watcherRefreshInterval == 180, "previous low-power defaults should migrate to folded low-power watcher refresh")
runner.check(migratedPreviousLowPowerSettings.fileChangeRefreshMinimumGap == 15, "previous low-power defaults should migrate to folded low-power debounce")
previousLowPowerDefaults.removePersistentDomain(forName: previousLowPowerSuiteName)

runner.check(settings.remoteCodexDataSource == .cpaManagerPlus, "remote Codex monitor should default to CPA Manager Plus data")
runner.check(settings.notchDisplaySource == .codex, "collapsed notch display should default to local Codex")
settings.codexRadarEnabled = false
settings.showSparkQuota = true
settings.showContextMetrics = true
settings.remoteCodexDataSource = .cliProxyAPI
settings.notchDisplaySource = .remoteCodex
settings.newAPIMonitorEnabled = true
settings.newAPIPanelURL = "https://newapi.example.com"
settings.newAPIUsername = "owner"
settings.newAPIRefreshInterval = 180
settings.subAPIMonitorEnabled = true
settings.subAPIPanelURL = "https://subapi.example.com"
settings.subAPIUsername = "user@example.com"
settings.subAPIRefreshInterval = 240
let reloadedSettings = CodexNotchSettings(
    defaults: settingsDefaults,
    initialManagementKey: "",
    initialNewAPIKey: "",
    initialSubAPIKey: "",
    secretStores: SecretStoreFactory(keychain: MemorySecretStore(), database: MemorySecretStore()),
    launchAtLoginManager: FakeLaunchAtLoginManager()
)
runner.check(reloadedSettings.remoteCodexDataSource == .cliProxyAPI, "remote Codex data source should persist")
runner.check(reloadedSettings.notchDisplaySource == .remoteCodex, "collapsed notch display source should persist")
runner.check(!reloadedSettings.codexRadarEnabled, "Codex Radar enablement should persist")
runner.check(reloadedSettings.showSparkQuota, "Spark quota display preference should persist")
runner.check(reloadedSettings.showContextMetrics, "context metrics display preference should persist")
runner.check(reloadedSettings.newAPIMonitorEnabled, "NewAPI monitor enablement should persist")
runner.check(reloadedSettings.newAPIPanelURL == "https://newapi.example.com", "NewAPI panel URL should persist")
runner.check(reloadedSettings.newAPIUsername == "owner", "NewAPI username should persist")
let migratedNewAPIAccounts = reloadedSettings.balanceAccounts(for: .newAPI)
runner.check(migratedNewAPIAccounts.count == 1, "legacy NewAPI settings should migrate to one balance account")
runner.check(migratedNewAPIAccounts.first?.panelURL == "https://newapi.example.com", "migrated NewAPI account should preserve panel URL")
runner.check(migratedNewAPIAccounts.first?.username == "owner", "migrated NewAPI account should preserve username")
runner.check(migratedNewAPIAccounts.first?.usesDefaultThresholds == true, "migrated NewAPI account should use default thresholds")
runner.check(reloadedSettings.subAPIMonitorEnabled, "SubAPI monitor enablement should persist")
runner.check(reloadedSettings.subAPIPanelURL == "https://subapi.example.com", "SubAPI panel URL should persist")
runner.check(reloadedSettings.subAPIUsername == "user@example.com", "SubAPI login name should persist")
let migratedSubAPIAccounts = reloadedSettings.balanceAccounts(for: .subAPI)
runner.check(migratedSubAPIAccounts.count == 1, "legacy Sub2API settings should migrate to one balance account")
runner.check(migratedSubAPIAccounts.first?.panelURL == "https://subapi.example.com", "migrated Sub2API account should preserve panel URL")
runner.check(migratedSubAPIAccounts.first?.username == "user@example.com", "migrated Sub2API account should preserve login name")
reloadedSettings.setBalanceAccounts([], for: .newAPI)
let emptiedSettings = CodexNotchSettings(
    defaults: settingsDefaults,
    initialManagementKey: "",
    initialNewAPIKey: "",
    initialSubAPIKey: "",
    secretStores: SecretStoreFactory(keychain: MemorySecretStore(), database: MemorySecretStore()),
    launchAtLoginManager: FakeLaunchAtLoginManager()
)
runner.check(emptiedSettings.balanceAccounts(for: .newAPI).isEmpty, "explicitly saved empty NewAPI account list should not revive legacy settings")
settingsDefaults.removePersistentDomain(forName: settingsSuiteName)

let databaseModeSuiteName = "CodexNotchDatabaseSecretMode-\(UUID().uuidString)"
let databaseModeDefaults = runner.require(
    UserDefaults(suiteName: databaseModeSuiteName),
    "database secret mode defaults should be available"
)
databaseModeDefaults.removePersistentDomain(forName: databaseModeSuiteName)
let keychainStoreForDatabaseMode = CountingSecretStore()
let databaseStoreForDatabaseMode = CountingSecretStore()
let databaseModeSettings = CodexNotchSettings(
    defaults: databaseModeDefaults,
    initialManagementKey: "clip-secret",
    initialNewAPIKey: "newapi-secret",
    initialSubAPIKey: "subapi-secret",
    secretStores: SecretStoreFactory(keychain: keychainStoreForDatabaseMode, database: databaseStoreForDatabaseMode),
    launchAtLoginManager: FakeLaunchAtLoginManager()
)
runner.check(databaseModeSettings.loadSecretsIfNeeded(), "database migration setup should load the source vault")
try databaseModeSettings.setCodexRadarAPIToken("database-radar-token")
databaseModeSettings.setSecretStorageMode(.database)
runner.check(databaseModeSettings.secretStorageMode == .database, "verified secret migration should switch storage mode")
runner.check(keychainStoreForDatabaseMode.deleteCount == 1, "secret migration should delete the source vault")
let migratedSourceVault = try keychainStoreForDatabaseMode.loadVault()
runner.check(migratedSourceVault.isEmpty, "secret migration should leave the source vault empty")
databaseModeSettings.setBalanceAccounts([
    BalanceAccountConfiguration(
        id: "db-account",
        source: .newAPI,
        enabled: true,
        label: "DB Account",
        panelURL: "https://newapi.example.com",
        username: "owner",
        secret: "db-account-secret",
        requestTimeout: 6
    )
], for: .newAPI)
let reloadedDatabaseModeSettings = CodexNotchSettings(
    defaults: databaseModeDefaults,
    secretStores: SecretStoreFactory(keychain: keychainStoreForDatabaseMode, database: databaseStoreForDatabaseMode),
    launchAtLoginManager: FakeLaunchAtLoginManager()
)
runner.check(reloadedDatabaseModeSettings.secretStorageMode == .database, "secret storage mode should persist")
runner.check(reloadedDatabaseModeSettings.loadSecretsIfNeeded(), "database mode should load secrets on demand")
runner.check(reloadedDatabaseModeSettings.cliproxyManagementKey == "clip-secret", "database mode should reload CLIProxyAPI key")
runner.check(reloadedDatabaseModeSettings.newAPIManagementKey == "newapi-secret", "database mode should reload NewAPI key")
runner.check(reloadedDatabaseModeSettings.subAPIManagementKey == "subapi-secret", "database mode should reload Sub2API key")
runner.check(
    reloadedDatabaseModeSettings.codexRadarCredential(accessMode: .nonInteractive).token == "database-radar-token",
    "database mode should reload the unified Radar token without authentication UI"
)
runner.check(
    reloadedDatabaseModeSettings.balanceAccounts(for: .newAPI).first?.secret == "db-account-secret",
    "database mode should reload account secret"
)
databaseModeDefaults.removePersistentDomain(forName: databaseModeSuiteName)

let retryCleanupSuiteName = "CodexNotchSecretCleanupRetry-\(UUID().uuidString)"
let retryCleanupDefaults = runner.require(
    UserDefaults(suiteName: retryCleanupSuiteName),
    "secret cleanup retry defaults should be available"
)
retryCleanupDefaults.removePersistentDomain(forName: retryCleanupSuiteName)

let retryWriteSuiteName = "CodexNotchSecretWriteRetry-\(UUID().uuidString)"
let retryWriteDefaults = runner.require(
    UserDefaults(suiteName: retryWriteSuiteName),
    "secret write retry defaults should be available"
)
retryWriteDefaults.removePersistentDomain(forName: retryWriteSuiteName)

let invalidMigrationSuiteName = "CodexNotchInvalidSecretMigration-\(UUID().uuidString)"
let invalidMigrationDefaults = runner.require(
    UserDefaults(suiteName: invalidMigrationSuiteName),
    "invalid migration defaults should be available"
)
invalidMigrationDefaults.removePersistentDomain(forName: invalidMigrationSuiteName)
invalidMigrationDefaults.set("keychain", forKey: "secretStorageMode")
invalidMigrationDefaults.set(
    Data(#"{"sourceMode":"keychain","targetMode":"keychain","expectedDigest":"invalid"}"#.utf8),
    forKey: "secretStorageMigrationState"
)
var invalidMigrationVault = SecretVault()
invalidMigrationVault.set("must-survive", for: .cliproxyManagement)
let invalidMigrationStore = CountingSecretStore(vault: invalidMigrationVault)
let invalidMigrationSettings = CodexNotchSettings(
    defaults: invalidMigrationDefaults,
    secretStores: SecretStoreFactory(keychain: invalidMigrationStore, database: CountingSecretStore()),
    launchAtLoginManager: FakeLaunchAtLoginManager()
)
runner.check(invalidMigrationSettings.loadSecretsIfNeeded(), "invalid same-store migration state should not block secret loading")
runner.check(invalidMigrationStore.deleteCount == 0, "invalid same-store migration state must not delete the active vault")
runner.check(invalidMigrationSettings.cliproxyManagementKey == "must-survive", "invalid migration state must preserve the active secret")
invalidMigrationDefaults.removePersistentDomain(forName: invalidMigrationSuiteName)
let retryWriteSource = CountingSecretStore()
let retryWriteTarget = CountingSecretStore(failOnSave: true)
let retryWriteSettings = CodexNotchSettings(
    defaults: retryWriteDefaults,
    initialManagementKey: "write-retry-secret",
    secretStores: SecretStoreFactory(keychain: retryWriteSource, database: retryWriteTarget),
    launchAtLoginManager: FakeLaunchAtLoginManager()
)
retryWriteSettings.setSecretStorageMode(.database)
runner.check(retryWriteSettings.secretStorageMode == .keychain, "failed target write should keep the source mode")
runner.check(retryWriteSource.deleteCount == 0, "failed target write must not delete the source vault")
retryWriteTarget.failOnSave = false
let recoveredWriteSettings = CodexNotchSettings(
    defaults: retryWriteDefaults,
    secretStores: SecretStoreFactory(keychain: retryWriteSource, database: retryWriteTarget),
    launchAtLoginManager: FakeLaunchAtLoginManager()
)
runner.check(recoveredWriteSettings.loadSecretsIfNeeded(), "pending target write should recover on the next launch")
runner.check(recoveredWriteSettings.secretStorageMode == .database, "write recovery should complete the target switch")
runner.check(retryWriteSource.deleteCount == 1, "write recovery should delete the verified source vault")
runner.check(recoveredWriteSettings.cliproxyManagementKey == "write-retry-secret", "write recovery should preserve migrated secrets")
retryWriteDefaults.removePersistentDomain(forName: retryWriteSuiteName)
let retryCleanupSource = CountingSecretStore(failOnDelete: true)
let retryCleanupTarget = CountingSecretStore()
let retryCleanupSettings = CodexNotchSettings(
    defaults: retryCleanupDefaults,
    initialManagementKey: "retry-secret",
    secretStores: SecretStoreFactory(keychain: retryCleanupSource, database: retryCleanupTarget),
    launchAtLoginManager: FakeLaunchAtLoginManager()
)
retryCleanupSettings.setSecretStorageMode(.database)
runner.check(retryCleanupSettings.secretStorageMode == .database, "verified migration should stay on target when source cleanup fails")
runner.check(retryCleanupSettings.secretStorageError?.contains("下次启动重试") == true, "failed source cleanup should remain visible and retryable")
retryCleanupSource.failOnDelete = false
let recoveredCleanupSettings = CodexNotchSettings(
    defaults: retryCleanupDefaults,
    secretStores: SecretStoreFactory(keychain: retryCleanupSource, database: retryCleanupTarget),
    launchAtLoginManager: FakeLaunchAtLoginManager()
)
runner.check(recoveredCleanupSettings.loadSecretsIfNeeded(), "pending secret cleanup should recover on the next launch")
runner.check(recoveredCleanupSettings.secretStorageMode == .database, "cleanup recovery should keep the verified target mode")
let recoveredSourceVault = try retryCleanupSource.loadVault()
runner.check(recoveredSourceVault.isEmpty, "cleanup recovery should remove the old source vault")
runner.check(recoveredCleanupSettings.secretStorageError == nil, "successful cleanup recovery should clear the migration error")
retryCleanupDefaults.removePersistentDomain(forName: retryCleanupSuiteName)

let oldBalanceAccount = BalanceAccountConfiguration(
    id: "account-1",
    source: .newAPI,
    panelURL: "https://old.example.com",
    username: "owner",
    secret: "same-password",
    allowInsecureTLS: false
)
var changedOriginAccount = oldBalanceAccount
changedOriginAccount.panelURL = "https://new.example.com"
let sanitizedChangedOrigin = CodexNotchSettings.sanitizedBalanceAccountForSave(
    changedOriginAccount,
    oldAccount: oldBalanceAccount
)
runner.check(sanitizedChangedOrigin.secret.isEmpty, "changing a balance account origin should clear an unchanged password")
var changedTLSAccount = oldBalanceAccount
changedTLSAccount.allowInsecureTLS = true
let sanitizedChangedTLS = CodexNotchSettings.sanitizedBalanceAccountForSave(
    changedTLSAccount,
    oldAccount: oldBalanceAccount
)
runner.check(sanitizedChangedTLS.secret.isEmpty, "changing a balance account TLS mode should clear an unchanged password")
var retypedChangedOrigin = changedOriginAccount
retypedChangedOrigin.secret = "retyped-password"
let sanitizedRetypedOrigin = CodexNotchSettings.sanitizedBalanceAccountForSave(
    retypedChangedOrigin,
    oldAccount: oldBalanceAccount
)
runner.check(sanitizedRetypedOrigin.secret == "retyped-password", "retyped password should be kept after origin change")

let shellTimeoutStart = Date()
do {
    _ = try Shell.run("/bin/sh", ["-c", "sleep 2"], timeout: 0.2)
    runner.check(false, "shell timeout should stop a stuck command")
} catch {
    runner.check(Date().timeIntervalSince(shellTimeoutStart) < 3.0, "shell timeout should return promptly")
}

let resistantShellTimeoutStart = Date()
do {
    _ = try Shell.run("/bin/sh", ["-c", "trap '' TERM; while :; do :; done"], timeout: 0.2)
    runner.check(false, "shell timeout should stop a SIGTERM-resistant command")
} catch {
    runner.check(Date().timeIntervalSince(resistantShellTimeoutStart) < 3.0, "shell timeout should not wait indefinitely after SIGTERM fails")
}

let largeShellOutput = try Shell.run(
    "/bin/sh",
    ["-c", "/usr/bin/yes x | /usr/bin/head -c 2000000"],
    timeout: 5
)
runner.check(largeShellOutput.contains("[output truncated]"), "shell output should be drained and capped without deadlocking")
runner.check(largeShellOutput.utf8.count < 1_100_000, "shell output cap should bound retained memory")

runner.check(CLIProxyAPIClient.managementBaseURL(from: "http://example.com:8317/management.html") == nil, "external plain HTTP panel URL must be rejected")
runner.check(CLIProxyAPIClient.managementBaseURL(from: "https://panel.example.com@evil.example.com/management.html") == nil, "CLIProxyAPI panel URL must reject userinfo")

let newAPIBaseURL = runner.require(
    BalanceAPIClient.apiBaseURL(from: "https://newapi.example.com/admin"),
    "NewAPI-compatible panel URL should normalize"
)
runner.check(newAPIBaseURL.absoluteString == "https://newapi.example.com", "NewAPI-compatible base URL should use the origin")
runner.check(BalanceAPIClient.apiBaseURL(from: "https://newapi.example.com@evil.example.com/admin") == nil, "NewAPI-compatible panel URL must reject userinfo")

let configuredSecureOrigin = URL(string: "https://panel.example.com/v0/management")!
runner.check(
    NetworkSecurityPolicy.allowsRedirect(
        from: URL(string: "https://panel.example.com/v0/management/auth-files"),
        to: URL(string: "https://panel.example.com/v0/management/login")!,
        configuredURL: configuredSecureOrigin
    ),
    "same-origin HTTPS redirects should be allowed"
)
runner.check(
    !NetworkSecurityPolicy.allowsRedirect(
        from: URL(string: "https://panel.example.com/v0/management/auth-files"),
        to: URL(string: "https://evil.example.com/steal")!,
        configuredURL: configuredSecureOrigin
    ),
    "cross-origin redirects must be rejected"
)
runner.check(
    !NetworkSecurityPolicy.allowsRedirect(
        from: URL(string: "https://panel.example.com/v0/management/auth-files"),
        to: URL(string: "http://panel.example.com/steal")!,
        configuredURL: configuredSecureOrigin
    ),
    "HTTPS to HTTP redirects must be rejected"
)
runner.check(
    NetworkSecurityPolicy.matchesProtectionSpace(
        host: "PANEL.EXAMPLE.COM",
        port: 443,
        protocolName: "https",
        configuredURL: configuredSecureOrigin
    ),
    "TLS exceptions should match the configured origin"
)
runner.check(
    !NetworkSecurityPolicy.matchesProtectionSpace(
        host: "evil.example.com",
        port: 443,
        protocolName: "https",
        configuredURL: configuredSecureOrigin
    ),
    "TLS exceptions must not follow a challenge to another host"
)
let testCertificateFingerprint = String(repeating: "ab", count: 32)
let colonCertificateFingerprint = stride(from: 0, to: testCertificateFingerprint.count, by: 2)
    .map { index in
        let start = testCertificateFingerprint.index(testCertificateFingerprint.startIndex, offsetBy: index)
        let end = testCertificateFingerprint.index(start, offsetBy: 2)
        return String(testCertificateFingerprint[start..<end])
    }
    .joined(separator: ":")
runner.check(
    NetworkSecurityPolicy.normalizedCertificateSHA256("SHA256:\(colonCertificateFingerprint.uppercased())") == testCertificateFingerprint,
    "certificate fingerprints should normalize common colon-delimited SHA-256 text"
)
runner.check(
    NetworkSecurityPolicy.normalizedCertificateSHA256("not-a-fingerprint") == nil,
    "invalid certificate fingerprints must be rejected"
)
let successResponse = HTTPURLResponse(
    url: configuredSecureOrigin,
    statusCode: 200,
    httpVersion: nil,
    headerFields: nil
)!
let errorResponse = HTTPURLResponse(
    url: configuredSecureOrigin,
    statusCode: 500,
    httpVersion: nil,
    headerFields: nil
)!
runner.check(NetworkResponsePolicy.limit(for: successResponse) == 5 * 1_024 * 1_024, "successful JSON responses should use the 5 MiB cap")
runner.check(NetworkResponsePolicy.limit(for: errorResponse) == 16 * 1_024, "error responses should use the 16 KiB cap")
do {
    try NetworkResponsePolicy.validate(Data(count: 16 * 1_024 + 1), response: errorResponse)
    runner.check(false, "oversized error responses should be rejected")
} catch NetworkResponseError.tooLarge {
    runner.check(true, "oversized error responses should use the dedicated error")
} catch {
    runner.check(false, "oversized error responses should not surface an unrelated error")
}
let pinnedBalanceAccount = BalanceAccountConfiguration(
    source: .newAPI,
    allowInsecureTLS: true,
    tlsCertificateSHA256: testCertificateFingerprint
)
runner.check(pinnedBalanceAccount.tlsCertificateValidationMessage == nil, "valid pinned account certificates should pass validation")
let unpinnedBalanceAccount = BalanceAccountConfiguration(source: .newAPI, allowInsecureTLS: true)
runner.check(unpinnedBalanceAccount.tlsCertificateValidationMessage != nil, "self-signed TLS mode should require a certificate fingerprint")

let newAPILoginBody = try BalanceAPIClient.newAPILoginBody(
    for: BalanceAPIConfiguration(
        panelURL: "https://newapi.example.com",
        username: "owner",
        secret: "newapi-password",
        timeout: 6,
        allowInsecureTLS: false
    )
)
let newAPILoginJSON = runner.require(
    try? JSONSerialization.jsonObject(with: newAPILoginBody) as? [String: String],
    "NewAPI login body should be JSON"
)
runner.check(newAPILoginJSON["username"] == "owner", "NewAPI login should send username")
runner.check(newAPILoginJSON["password"] == "newapi-password", "NewAPI login should send password")
for password in [
    " leading-space",
    "trailing-space ",
    "\tpassword\n",
    "🔐e\u{301}",
    String(repeating: "x", count: 4_096),
    "   "
] {
    let body = try BalanceAPIClient.newAPILoginBody(
        for: BalanceAPIConfiguration(
            panelURL: "https://newapi.example.com",
            username: " owner ",
            secret: password,
            timeout: 6,
            allowInsecureTLS: false
        )
    )
    let json = runner.require(
        try? JSONSerialization.jsonObject(with: body) as? [String: String],
        "NewAPI whitespace password body should be JSON"
    )
    runner.check(json["username"] == "owner", "NewAPI login may normalize the username")
    runner.check(json["password"] == password, "NewAPI login must preserve every password character")
}

let newAPILoginResponse = """
{
  "success": true,
  "message": "",
  "data": {
    "id": 42,
    "username": "owner",
    "require_2fa": false
  }
}
""".data(using: .utf8)!
let newAPIUserID = try BalanceAPIClient.validateNewAPILoginResponse(newAPILoginResponse)
runner.check(newAPIUserID == "42", "NewAPI login should return the user id required by management endpoints")
let newAPIManagementHeaders = BalanceAPIClient.newAPIManagementHeaders(userID: newAPIUserID)
runner.check(newAPIManagementHeaders["New-Api-User"] == "42", "NewAPI management requests should include the logged-in user id")
runner.check(newAPIManagementHeaders["Accept"] == "application/json", "NewAPI management requests should accept JSON")

let defaultThresholds = BalanceThresholdConfiguration(warningThreshold: 100, alertThreshold: 30)
runner.check(defaultThresholds.state(for: 150) == .healthy, "balance above warning threshold should be healthy")
runner.check(defaultThresholds.state(for: 99.99) == .warning, "balance below warning threshold should warn")
runner.check(defaultThresholds.state(for: 29.99) == .error, "balance below alert threshold should be an error")
runner.check(defaultThresholds.normalized.alertThreshold == 30, "already ordered thresholds should stay unchanged")
let swappedThresholds = BalanceThresholdConfiguration(warningThreshold: 25, alertThreshold: 50).normalized
runner.check(swappedThresholds.warningThreshold == 50, "normalized thresholds should keep warning at the larger value")
runner.check(swappedThresholds.alertThreshold == 25, "normalized thresholds should keep alert at the smaller value")
runner.check(defaultThresholds.hasValidOrder, "warning threshold above alert threshold should be valid")
runner.check(
    !BalanceThresholdConfiguration(warningThreshold: 25, alertThreshold: 50).hasValidOrder,
    "warning threshold below alert threshold should be invalid for editing"
)
runner.check(
    !BalanceThresholdConfiguration(warningThreshold: 50, alertThreshold: 50).hasValidOrder,
    "warning threshold equal to alert threshold should be invalid for editing"
)
runner.check(BalanceThresholdConfiguration().summaryText == "不提醒", "empty threshold summary should be explicit")
runner.check(defaultThresholds.summaryText == "提醒 100.00 · 告警 30.00", "threshold summary should show warning and alert values")
let defaultThresholdAccount = BalanceAccountConfiguration(
    source: .newAPI,
    username: "owner",
    usesDefaultThresholds: true
)
runner.check(
    defaultThresholdAccount.thresholdSummary(defaults: defaultThresholds) == "默认：提醒 100.00 · 告警 30.00",
    "default threshold account summary should reference default thresholds"
)
let customThresholdAccount = BalanceAccountConfiguration(
    source: .newAPI,
    username: "owner",
    usesDefaultThresholds: false,
    warningThreshold: 20,
    alertThreshold: 5
)
runner.check(
    customThresholdAccount.thresholdSummary(defaults: defaultThresholds) == "自定义：提醒 20.00 · 告警 5.00",
    "custom threshold account summary should show account thresholds"
)
let invalidCustomThresholdAccount = BalanceAccountConfiguration(
    source: .newAPI,
    username: "owner",
    usesDefaultThresholds: false,
    warningThreshold: 5,
    alertThreshold: 20
)
runner.check(
    !invalidCustomThresholdAccount.hasValidThresholdOrder,
    "custom account thresholds should require warning threshold above alert threshold"
)
let defaultThresholdAccountWithStaleInvalidCustomValues = BalanceAccountConfiguration(
    source: .newAPI,
    username: "owner",
    usesDefaultThresholds: true,
    warningThreshold: 5,
    alertThreshold: 20
)
runner.check(
    defaultThresholdAccountWithStaleInvalidCustomValues.hasValidThresholdOrder,
    "default-threshold accounts should ignore stale custom threshold ordering"
)

let newAPI2FAResponse = """
{
  "success": true,
  "message": "需要二次验证",
  "data": {
    "require_2fa": true
  }
}
""".data(using: .utf8)!
do {
    try BalanceAPIClient.validateNewAPILoginResponse(newAPI2FAResponse)
    runner.check(false, "NewAPI login should report unsupported two-factor login")
} catch {
    runner.check(error.localizedDescription.contains("二次验证"), "NewAPI 2FA login should show a clear message")
}

let subAPILoginBody = try BalanceAPIClient.subAPILoginBody(
    for: BalanceAPIConfiguration(
        panelURL: "https://subapi.example.com",
        username: "user@example.com",
        secret: "subapi-password",
        timeout: 6,
        allowInsecureTLS: false
    )
)
let subAPILoginJSON = runner.require(
    try? JSONSerialization.jsonObject(with: subAPILoginBody) as? [String: String],
    "Sub2API login body should be JSON"
)
runner.check(subAPILoginJSON["email"] == "user@example.com", "Sub2API login should send the login name as email")
runner.check(subAPILoginJSON["password"] == "subapi-password", "Sub2API login should send password")
let subAPIWhitespacePassword = "\t subapi password \n"
let subAPIWhitespaceBody = try BalanceAPIClient.subAPILoginBody(
    for: BalanceAPIConfiguration(
        panelURL: "https://subapi.example.com",
        username: " user@example.com ",
        secret: subAPIWhitespacePassword,
        timeout: 6,
        allowInsecureTLS: false
    )
)
let subAPIWhitespaceJSON = runner.require(
    try? JSONSerialization.jsonObject(with: subAPIWhitespaceBody) as? [String: String],
    "Sub2API whitespace password body should be JSON"
)
runner.check(subAPIWhitespaceJSON["password"] == subAPIWhitespacePassword, "Sub2API login must preserve every password character")
do {
    _ = try BalanceAPIClient.subAPILoginBody(
        for: BalanceAPIConfiguration(
            panelURL: "https://subapi.example.com",
            username: "test",
            secret: "subapi-password",
            timeout: 6,
            allowInsecureTLS: false
        )
    )
    runner.check(false, "Sub2API login should reject non-email login names before sending a request")
} catch {
    runner.check(error.localizedDescription.contains("邮箱"), "Sub2API non-email login names should show a clear email error")
}

let subAPILoginResponse = """
{
  "code": 0,
  "message": "success",
  "data": {
    "access_token": "subapi-access-token",
    "token_type": "Bearer",
    "user": {
      "id": 101,
      "email": "user@example.com",
      "username": "user",
      "role": "user",
      "balance": 12.5,
      "concurrency": 3,
      "status": "active"
    }
  }
}
""".data(using: .utf8)!
let subAPIToken = try BalanceAPIClient.validateSubAPILoginResponse(subAPILoginResponse)
runner.check(subAPIToken == "subapi-access-token", "Sub2API login should return an access token")
let subAPIUserHeaders = BalanceAPIClient.bearerHeaders(token: subAPIToken)
runner.check(subAPIUserHeaders["Authorization"] == "Bearer subapi-access-token", "Sub2API user requests should use bearer token auth")
let subAPIHTTP400 = """
{
  "code": 400,
  "message": "Invalid request: Key: 'LoginRequest.Email' Error:Field validation for 'Email' failed on the 'email' tag"
}
""".data(using: .utf8)!
runner.check(
    BalanceAPIClient.httpFailureMessage(statusCode: 400, data: subAPIHTTP400).contains("邮箱格式不正确"),
    "Sub2API HTTP 400 validation payload should become an actionable email-format message"
)
let echoedPassword = "unusual password value"
let echoedPasswordError = Data(#"{"unexpected":"unusual password value"}"#.utf8)
runner.check(
    !BalanceAPIClient.httpFailureMessage(
        statusCode: 500,
        data: echoedPasswordError,
        sensitiveValues: [echoedPassword]
    ).contains(echoedPassword),
    "remote error bodies should redact the exact configured password even under unknown field names"
)
runner.check(SettingsShortcutFilter.shouldSuppressTextInputKey(
    characters: "⌃⌥⌘V",
    hasCommand: true,
    hasControl: true,
    hasOption: true,
    hasShift: false
), "non-standard command shortcuts should not be inserted into settings text fields")
runner.check(!SettingsShortcutFilter.shouldSuppressTextInputKey(
    characters: "v",
    hasCommand: true,
    hasControl: false,
    hasOption: false,
    hasShift: false
), "standard paste shortcut should still reach the text field")
runner.check(!SettingsShortcutFilter.shouldSuppressTextInputKey(
    characters: "a",
    hasCommand: false,
    hasControl: false,
    hasOption: false,
    hasShift: false
), "plain text input should not be suppressed")

let newAPIUserPayload = """
{
  "success": true,
  "message": "",
  "data": {
    "username": "owner",
    "display_name": "Owner",
    "quota": 73454877,
    "used_quota": 0,
    "request_count": 42,
    "status": 1
  }
}
""".data(using: .utf8)!
let newAPIStatusPayload = """
{
  "success": true,
  "message": "",
  "data": {
    "quota_per_unit": 500000,
    "quota_display_type": "CNY",
    "usd_exchange_rate": 6.8069
  }
}
""".data(using: .utf8)!
let newAPIQuotaDisplay = try BalanceAPIClient.decodeNewAPIQuotaDisplay(newAPIStatusPayload)
let userBalanceAccount = try BalanceAPIClient.decodeUserAccount(
    newAPIUserPayload,
    source: .newAPI,
    quotaDisplay: newAPIQuotaDisplay
)
runner.check(userBalanceAccount.displayName == "Owner", "NewAPI self account should prefer display_name")
runner.check(userBalanceAccount.amountText == "¥1000.00", "NewAPI self account quota should display the same CNY balance as the console")
runner.check(userBalanceAccount.detailText.contains("已用 ¥0.00"), "NewAPI used quota should display as currency usage")
runner.check(userBalanceAccount.detailText.contains("请求 42"), "NewAPI self account should include request count")
let warningThresholdBalanceAccount = try BalanceAPIClient.decodeUserAccount(
    newAPIUserPayload,
    source: .newAPI,
    quotaDisplay: newAPIQuotaDisplay,
    thresholds: BalanceThresholdConfiguration(warningThreshold: 1200, alertThreshold: 500)
)
runner.check(warningThresholdBalanceAccount.state == .warning, "NewAPI balance below reminder threshold should become warning")
runner.check(warningThresholdBalanceAccount.stateText == "余额低于提醒阈值", "NewAPI warning status should explain the balance threshold reason")

let newAPIChannelPayload = """
{
  "success": true,
  "message": "",
  "data": {
    "items": [
      {
        "id": 11,
        "name": "OpenAI Primary",
        "status": 1,
        "balance": 12.3456,
        "used_quota": 987654
      },
      {
        "id": 12,
        "name": "Disabled Channel",
        "status": 2,
        "balance": "0.5",
        "used_quota": "123"
      }
    ],
    "total": 2
  }
}
""".data(using: .utf8)!
let channelBalanceAccounts = try BalanceAPIClient.decodeChannelAccounts(
    newAPIChannelPayload,
    source: .newAPI
)
runner.check(channelBalanceAccounts.count == 2, "NewAPI channel list should decode channel balances")
runner.check(channelBalanceAccounts[0].amountText == "$12.35", "NewAPI channel balance should format to dollars")
runner.check(channelBalanceAccounts[1].state == .warning, "disabled NewAPI channel should become a warning balance account")

let sameCurrencySnapshot = BalanceMonitorSnapshot(
    source: .newAPI,
    panelState: .healthy,
    accounts: [
        BalanceAccount(
            id: "cny-1",
            source: .newAPI,
            name: "CNY 1",
            kind: "用户额度",
            statusCode: nil,
            amountText: "¥100.00",
            usedText: nil,
            requestCount: nil,
            updatedAt: nil,
            state: .healthy,
            balanceAmount: 100,
            balanceUnitKey: "CNY",
            balanceUnitSymbol: "¥"
        ),
        BalanceAccount(
            id: "cny-2",
            source: .newAPI,
            name: "CNY 2",
            kind: "用户额度",
            statusCode: nil,
            amountText: "¥30.50",
            usedText: nil,
            requestCount: nil,
            updatedAt: nil,
            state: .healthy,
            balanceAmount: 30.5,
            balanceUnitKey: "CNY",
            balanceUnitSymbol: "¥"
        )
    ],
    message: nil,
    lastUpdated: nil
)
runner.check(sameCurrencySnapshot.totalAmountText == "¥130.50", "same-currency balances should be summed")
let mixedCurrencySnapshot = BalanceMonitorSnapshot(
    source: .newAPI,
    panelState: .healthy,
    accounts: [
        BalanceAccount(
            id: "cny",
            source: .newAPI,
            name: "CNY",
            kind: "用户额度",
            statusCode: nil,
            amountText: "¥100.00",
            usedText: nil,
            requestCount: nil,
            updatedAt: nil,
            state: .healthy,
            balanceAmount: 100,
            balanceUnitKey: "CNY",
            balanceUnitSymbol: "¥"
        ),
        BalanceAccount(
            id: "usd",
            source: .newAPI,
            name: "USD",
            kind: "用户额度",
            statusCode: nil,
            amountText: "$10.00",
            usedText: nil,
            requestCount: nil,
            updatedAt: nil,
            state: .healthy,
            balanceAmount: 10,
            balanceUnitKey: "USD",
            balanceUnitSymbol: "$"
        )
    ],
    message: nil,
    lastUpdated: nil
)
runner.check(mixedCurrencySnapshot.totalAmountText == "¥100.00 + $10.00", "two-currency totals should be grouped instead of converted")

let subAPIProfilePayload = """
{
  "code": 0,
  "message": "success",
  "data": {
    "id": 101,
    "email": "active@example.com",
    "username": "active",
    "role": "user",
    "balance": 12.5,
    "concurrency": 3,
    "status": "active"
  }
}
""".data(using: .utf8)!
let subAPIProfileAccount = try BalanceAPIClient.decodeSubAPIProfileAccount(subAPIProfilePayload)
runner.check(subAPIProfileAccount.displayName == "active@example.com", "Sub2API profile balance should prefer email")
runner.check(subAPIProfileAccount.amountText == "$12.50", "Sub2API profile balance should format as currency")
runner.check(subAPIProfileAccount.detailText.contains("并发 3"), "Sub2API profile should include concurrency")
let subAPISensitiveStatusPayload = """
{
  "code": 0,
  "message": "success",
  "data": {
    "id": 102,
    "email": "sensitive@example.com",
    "role": "user",
    "balance": 8,
    "status": "Bearer sk-sensitive-token"
  }
}
""".data(using: .utf8)!
let subAPISensitiveStatusAccount = try BalanceAPIClient.decodeSubAPIProfileAccount(subAPISensitiveStatusPayload)
runner.check(subAPISensitiveStatusAccount.state == .warning, "Sub2API unknown status should still mark the account as warning")
runner.check(subAPISensitiveStatusAccount.stateText == "状态异常", "Sub2API status reason should not display remote status values verbatim")
runner.check(!subAPISensitiveStatusAccount.detailText.lowercased().contains("sk-"), "Sub2API detail text should redact token-like status values")
let alertThresholdSubAPIProfileAccount = try BalanceAPIClient.decodeSubAPIProfileAccount(
    subAPIProfilePayload,
    thresholds: BalanceThresholdConfiguration(warningThreshold: 20, alertThreshold: 15)
)
runner.check(alertThresholdSubAPIProfileAccount.state == .error, "Sub2API balance below alert threshold should become error")
runner.check(alertThresholdSubAPIProfileAccount.stateText == "余额低于告警阈值", "Sub2API error status should explain the balance threshold reason")

let subAPIPlatformQuotaPayload = """
{
  "code": 0,
  "message": "success",
  "data": {
    "platform_quotas": [
      {
        "platform": "openai",
        "daily_usage_usd": 1.5,
        "daily_limit_usd": 5,
        "weekly_usage_usd": 4,
        "weekly_limit_usd": 20,
        "monthly_usage_usd": 8,
        "monthly_limit_usd": 30
      }
    ]
  }
}
""".data(using: .utf8)!
let subAPIQuotaAccounts = try BalanceAPIClient.decodeSubAPIPlatformQuotaAccounts(subAPIPlatformQuotaPayload)
runner.check(subAPIQuotaAccounts.count == 1, "Sub2API platform quota list should decode")
runner.check(subAPIQuotaAccounts[0].displayName == "openai", "Sub2API platform quota should use platform name")
runner.check(subAPIQuotaAccounts[0].amountText == "$3.50", "Sub2API platform quota should display the most constrained remaining quota")
let subAPIQuotaAccountsForA = try BalanceAPIClient.decodeSubAPIPlatformQuotaAccounts(
    subAPIPlatformQuotaPayload,
    accountID: "account-a",
    accountLabel: "A"
)
let subAPIQuotaAccountsForB = try BalanceAPIClient.decodeSubAPIPlatformQuotaAccounts(
    subAPIPlatformQuotaPayload,
    accountID: "account-b",
    accountLabel: "B"
)
runner.check(subAPIQuotaAccountsForA[0].id != subAPIQuotaAccountsForB[0].id, "Sub2API platform quota row ids should include the parent account id")
runner.check(subAPIQuotaAccountsForA[0].displayName == "A · openai", "Sub2API platform quota display name should include account label when available")

let failedBalanceEnvelope = """
{
  "success": false,
  "message": "authorization Bearer sk-sensitive-token should not be displayed"
}
""".data(using: .utf8)!
do {
    _ = try BalanceAPIClient.decodeUserAccount(failedBalanceEnvelope, source: .newAPI)
    runner.check(false, "failed NewAPI envelope should throw")
} catch {
    runner.check(!error.localizedDescription.lowercased().contains("sk-sensitive"), "NewAPI-compatible error messages should redact token-like secrets")
}
let redactedJSONError = DisplayRedactor.redact(#"{"password":"secret-password","access_token":"sensitive-access-token","message":"bad"}"#)
runner.check(!redactedJSONError.contains("secret-password"), "redaction should hide JSON password values")
runner.check(!redactedJSONError.contains("sensitive-access-token"), "redaction should hide JSON access tokens")

let localURL = runner.require(
    CLIProxyAPIClient.managementBaseURL(from: "http://127.0.0.1:8317/management.html"),
    "localhost plain HTTP panel URL should be accepted"
)
runner.check(localURL.absoluteString == "http://127.0.0.1:8317/v0/management", "localhost HTTP URL should normalize to management API base")

let previous = RemoteCodexAccount(
    id: "1",
    name: "previous",
    email: nil,
    label: nil,
    provider: "codex",
    accountType: nil,
    authIndex: "1",
    chatgptAccountID: nil,
    status: "active",
    statusMessage: nil,
    successCount: 1,
    failureCount: 0,
    recentFailures: 0,
    state: .healthy,
    lastRefresh: nil,
    planType: "team",
    quotaWindows: [
        RemoteQuotaWindow(
            id: "code-primary",
            shortLabel: "5h",
            remainingPercent: 88,
            usedPercent: 12,
            resetText: nil
        )
    ],
    quotaError: nil
)

let current = RemoteCodexAccount(
    id: "1",
    name: "current",
    email: nil,
    label: nil,
    provider: "codex",
    accountType: nil,
    authIndex: "1",
    chatgptAccountID: nil,
    status: "active",
    statusMessage: nil,
    successCount: 1,
    failureCount: 0,
    recentFailures: 0,
    state: .healthy,
    lastRefresh: nil,
    planType: "team",
    quotaWindows: [],
    quotaError: "HTTP 401"
)

let preserved = current.preservingFailedQuota(from: previous)
runner.check(preserved.state == .abnormal, "authentication quota failure should mark the account abnormal")
runner.check(preserved.quotaError == "HTTP 401", "preserved quota should keep the current error")
runner.check(preserved.stateReasonText == "登录已过期", "authentication quota failure should explain login expiry")

let timeoutQuotaFailure = RemoteCodexAccount(
    id: "1",
    name: "current timeout",
    email: nil,
    label: nil,
    provider: "codex",
    accountType: nil,
    authIndex: "1",
    chatgptAccountID: nil,
    status: "active",
    statusMessage: nil,
    successCount: 1,
    failureCount: 0,
    recentFailures: 0,
    state: .healthy,
    lastRefresh: nil,
    planType: "team",
    quotaWindows: [],
    quotaError: "额度查询超时"
)
let timeoutPreserved = timeoutQuotaFailure.preservingFailedQuota(from: previous)
runner.check(timeoutPreserved.state == .healthy, "non-auth quota refresh failure should preserve the account state when old quota is available")
runner.check(timeoutPreserved.quotaSummaryText == "5h 88%", "preserved quota should keep displaying the old quota numbers")

let previousQuotaFailure = RemoteCodexAccount(
    id: "1",
    name: "previous failure",
    email: nil,
    label: nil,
    provider: "codex",
    accountType: nil,
    authIndex: "1",
    chatgptAccountID: nil,
    status: "active",
    statusMessage: nil,
    successCount: 1,
    failureCount: 0,
    recentFailures: 0,
    state: .healthy,
    lastRefresh: nil,
    planType: "team",
    quotaWindows: [],
    quotaError: "额度查询超时"
)
let statusOnlyAccount = RemoteCodexAccount(
    id: "1",
    name: "status only",
    email: nil,
    label: nil,
    provider: "codex",
    accountType: nil,
    authIndex: "1",
    chatgptAccountID: nil,
    status: "active",
    statusMessage: nil,
    successCount: 1,
    failureCount: 0,
    recentFailures: 0,
    state: .healthy,
    lastRefresh: nil,
    planType: "team",
    quotaWindows: [],
    quotaError: nil
)
let statusOnlyPreserved = statusOnlyAccount.preservingQuota(from: previousQuotaFailure)
runner.check(statusOnlyPreserved.quotaError == nil, "status-only refresh should not preserve stale quota errors without quota windows")

let unavailableDueToQuota = RemoteCodexAccount(
    id: "quota-unavailable",
    name: "quota unavailable",
    email: nil,
    label: nil,
    provider: "codex",
    accountType: nil,
    authIndex: "1",
    chatgptAccountID: nil,
    status: "error",
    statusMessage: #"{"error":{"type":"usage_limit_reached","message":"The usage limit has been reached"}}"#,
    successCount: 419,
    failureCount: 7,
    recentFailures: 0,
    state: .abnormal,
    lastRefresh: nil,
    planType: "plus",
    quotaWindows: [
        RemoteQuotaWindow(
            id: "code-primary",
            shortLabel: "5h",
            remainingPercent: 0,
            usedPercent: 100,
            resetText: "6-14 19:43"
        ),
        RemoteQuotaWindow(
            id: "code-secondary",
            shortLabel: "7d",
            remainingPercent: 56,
            usedPercent: 44,
            resetText: nil
        )
    ],
    quotaError: nil,
    unavailable: true
).withQuotaExhaustion
runner.check(unavailableDueToQuota.state == .quotaExhausted, "unavailable account with exhausted quota should be classified as quota exhausted")
runner.check(unavailableDueToQuota.stateReasonText == "5小时额度已满", "exhausted 5h quota should explain that the 5h quota is full")

let staleQuotaMarkerAccount = RemoteCodexAccount(
    id: "stale-quota-marker",
    name: "stale quota marker",
    email: nil,
    label: nil,
    provider: "codex",
    accountType: nil,
    authIndex: "1",
    chatgptAccountID: nil,
    status: "error",
    statusMessage: #"{"error":{"type":"usage_limit_reached","message":"The usage limit has been reached"}}"#,
    successCount: 633,
    failureCount: 12,
    recentFailures: 0,
    state: .quotaExhausted,
    lastRefresh: nil,
    planType: "plus",
    quotaWindows: [],
    quotaError: nil,
    unavailable: true
)
let freshAvailableQuotaWindows = [
    RemoteQuotaWindow(
        id: "code-primary",
        shortLabel: "5h",
        remainingPercent: 99,
        usedPercent: 1,
        resetText: nil
    ),
    RemoteQuotaWindow(
        id: "code-secondary",
        shortLabel: "7d",
        remainingPercent: 40,
        usedPercent: 60,
        resetText: nil
    )
]
runner.check(
    staleQuotaMarkerAccount.stateAfterMergingFreshQuota(
        windows: freshAvailableQuotaWindows,
        error: nil
    ) == .healthy,
    "fresh available quota should clear stale quota-exhausted status markers"
)
let previousAvailableQuotaAccount = remoteAccount(
    id: "stale-quota-marker",
    state: .healthy,
    quotaWindows: freshAvailableQuotaWindows
)
let preservedAvailableQuotaAccount = staleQuotaMarkerAccount.preservingQuota(
    from: previousAvailableQuotaAccount
)
runner.check(
    preservedAvailableQuotaAccount.state == .healthy,
    "status-only refresh should clear stale quota-exhausted status when preserving available quota"
)
runner.check(
    preservedAvailableQuotaAccount.stateReasonText == "正常",
    "status-only refresh with preserved available quota should display a healthy reason"
)

let poolWithOneShortQuota = [
    remoteAccount(id: "quota-1", state: .quotaExhausted, quotaWindows: [exhaustedFiveHourWindow]),
    remoteAccount(id: "healthy-1", state: .healthy),
    remoteAccount(id: "healthy-2", state: .healthy)
]
runner.check(RemoteMonitorSnapshot.poolAlertSeverity(for: poolWithOneShortQuota) == .none, "single 5h exhausted account should not alert when the remote pool has healthy accounts")

let poolWithThinCapacity = [
    remoteAccount(id: "quota-1", state: .quotaExhausted, quotaWindows: [exhaustedFiveHourWindow]),
    remoteAccount(id: "quota-2", state: .quotaExhausted, quotaWindows: [exhaustedFiveHourWindow]),
    remoteAccount(id: "healthy-1", state: .healthy)
]
runner.check(RemoteMonitorSnapshot.poolAlertSeverity(for: poolWithThinCapacity) == .warning, "remote pool should warn when only one account remains available")

let poolWithAbnormalAccount = [
    remoteAccount(id: "abnormal-1", state: .abnormal),
    remoteAccount(id: "healthy-1", state: .healthy)
]
runner.check(RemoteMonitorSnapshot.poolAlertSeverity(for: poolWithAbnormalAccount) == .error, "non-quota account abnormality should still alert as error")

let poolWithOneWeeklyQuota = [
    remoteAccount(id: "quota-1", state: .quotaExhausted, quotaWindows: [exhaustedWeeklyWindow]),
    remoteAccount(id: "healthy-1", state: .healthy)
]
runner.check(RemoteMonitorSnapshot.poolAlertSeverity(for: poolWithOneWeeklyQuota) == .warning, "long-term quota exhaustion should warn when the remote pool has limited reserve")

let poolWithMissingInspectionQuota = [
    remoteAccount(id: "quota-error-1", state: .healthy, quotaError: "巡检额度缺失"),
    remoteAccount(id: "quota-error-2", state: .healthy, quotaError: "巡检额度缺失")
]
runner.check(RemoteMonitorSnapshot.poolAlertSeverity(for: poolWithMissingInspectionQuota) == .warning, "missing quota data for the whole remote pool should warn")

let bothQuotasExhausted = RemoteCodexAccount(
    id: "both-quotas",
    name: "both quotas",
    email: nil,
    label: nil,
    provider: "codex",
    accountType: nil,
    authIndex: "1",
    chatgptAccountID: nil,
    status: "error",
    statusMessage: #"{"error":{"type":"usage_limit_reached"}}"#,
    successCount: 10,
    failureCount: 1,
    recentFailures: 0,
    state: .abnormal,
    lastRefresh: nil,
    planType: "plus",
    quotaWindows: [
        RemoteQuotaWindow(
            id: "code-primary",
            shortLabel: "5h",
            remainingPercent: 0,
            usedPercent: 100,
            resetText: nil
        ),
        RemoteQuotaWindow(
            id: "code-secondary",
            shortLabel: "7d",
            remainingPercent: 0,
            usedPercent: 100,
            resetText: nil
        )
    ],
    quotaError: nil,
    unavailable: true
).withQuotaExhaustion
runner.check(bothQuotasExhausted.stateReasonText == "5小时额度已满", "5h quota should be preferred when both 5h and weekly quota are exhausted")

let whamPayload = """
{
  "plan_type": "team",
  "rate_limits": {
    "primary": {
      "used_percent": 65,
      "window_minutes": 300
    },
    "secondary": {
      "used_percent": "12",
      "window_minutes": 10080
    }
  }
}
""".data(using: .utf8)!
let whamQuota = try CLIProxyAPIClient.decodeQuotaBody(whamPayload, fallbackPlanType: nil)
runner.check(whamQuota.planType == "team", "quota payload should preserve plan type")
runner.check(whamQuota.windows.count == 2, "rate_limits primary and secondary windows should decode")
runner.check(whamQuota.windows.first?.shortLabel == "5h", "window_minutes 300 should label as 5h")
runner.check(whamQuota.windows.first?.remainingPercent == 35, "remaining percent should be derived from used_percent")
runner.check(whamQuota.windows.last?.shortLabel == "7d", "window_minutes 10080 should label as 7d")
runner.check(whamQuota.windows.last?.remainingPercent == 88, "string used_percent should decode")

let reachedPayload = """
{
  "rate_limit": {
    "allowed": false,
    "limit_reached": true,
    "primary_window": {
      "limit_window_seconds": 18000
    }
  }
}
""".data(using: .utf8)!
let reachedQuota = try CLIProxyAPIClient.decodeQuotaBody(reachedPayload, fallbackPlanType: nil)
runner.check(reachedQuota.windows.first?.reachesThreshold == true, "limit_reached or allowed=false should mark quota threshold reached when the window lacks percent data")

let weeklyReachedPayload = """
{
  "rate_limit": {
    "allowed": false,
    "limit_reached": true,
    "primary_window": {
      "used_percent": 31,
      "limit_window_seconds": 18000
    },
    "secondary_window": {
      "used_percent": 100,
      "limit_window_seconds": 604800
    }
  }
}
""".data(using: .utf8)!
let weeklyReachedQuota = try CLIProxyAPIClient.decodeQuotaBody(weeklyReachedPayload, fallbackPlanType: nil)
runner.check(weeklyReachedQuota.windows.count == 2, "weekly reached payload should decode both quota windows")
runner.check(weeklyReachedQuota.windows[0].reachesThreshold == false, "global limit marker should not mark 5h reached when 5h still has quota")
runner.check(weeklyReachedQuota.windows[1].reachesThreshold == true, "weekly window with 0 remaining quota should be reached")
let weeklyReachedAccount = remoteAccount(
    id: "weekly-reached",
    state: .healthy,
    quotaWindows: weeklyReachedQuota.windows
).withQuotaExhaustion
runner.check(weeklyReachedAccount.stateReasonText == "周额度已满", "weekly quota exhaustion should not be reported as 5h exhaustion")

let codexInspectionAuthFilesPayload = """
{
  "files": [
    {
      "provider": "codex",
      "type": "codex",
      "name": "codex-healthy-pro.json",
      "email": "healthy@example.com",
      "auth_index": "auth-healthy",
      "success": 6,
      "failed": 1,
      "id_token": {
        "plan_type": "pro"
      }
    },
    {
      "provider": "codex",
      "type": "codex",
      "name": "codex-limited-plus.json",
      "email": "limited@example.com",
      "auth_index": "auth-limited",
      "success": 2,
      "failed": 0,
      "id_token": {
        "plan_type": "plus"
      }
    },
    {
      "provider": "codex",
      "type": "codex",
      "name": "codex-disabled-plus.json",
      "email": "disabled@example.com",
      "auth_index": "auth-disabled",
      "disabled": true,
      "id_token": {
        "plan_type": "plus"
      }
    }
  ]
}
""".data(using: .utf8)!
let codexInspectionRunPayload = """
{
  "run": {
    "id": 263,
    "status": "completed",
    "finishedAtMs": 1781693102243
  },
  "results": [
    {
      "fileName": "codex-healthy-pro.json",
      "displayAccount": "healthy@example.com",
      "authIndex": "auth-healthy",
      "provider": "codex",
      "disabled": false,
      "status": "error",
      "action": "keep",
      "actionReason": "周额度仍可用，无需处理",
      "statusCode": 200,
      "usedPercent": 67,
      "quotaWindows": [
        {
          "id": "five-hour",
          "labelKey": "codex_quota.primary_window",
          "usedPercent": 1,
          "resetLabel": "06/20 11:30",
          "limitWindowSeconds": 18000
        },
        {
          "id": "weekly",
          "labelKey": "codex_quota.secondary_window",
          "usedPercent": 67,
          "resetLabel": "06/24 21:36",
          "limitWindowSeconds": 604800
        }
      ],
      "isQuota": false,
      "createdAtMs": 1781693102234
    },
    {
      "fileName": "codex-limited-plus.json",
      "displayAccount": "limited@example.com",
      "authIndex": "auth-limited",
      "provider": "codex",
      "disabled": false,
      "status": "error",
      "action": "keep",
      "actionReason": "周额度达到阈值，保留待恢复",
      "statusCode": 200,
      "usedPercent": 100,
      "quotaWindows": [
        {
          "id": "five-hour",
          "labelKey": "codex_quota.primary_window",
          "usedPercent": 69,
          "resetLabel": "06/20 11:30",
          "limitWindowSeconds": 18000
        },
        {
          "id": "weekly",
          "labelKey": "codex_quota.secondary_window",
          "usedPercent": 100,
          "resetLabel": "06/24 21:36",
          "limitWindowSeconds": 604800
        }
      ],
      "isQuota": true,
      "createdAtMs": 1781693102235
    },
    {
      "fileName": "codex-disabled-plus.json",
      "displayAccount": "disabled@example.com",
      "authIndex": "auth-disabled",
      "provider": "codex",
      "disabled": true,
      "status": "disabled",
      "action": "keep",
      "actionReason": "账号已禁用",
      "statusCode": 200,
      "usedPercent": 100,
      "isQuota": true,
      "createdAtMs": 1781693102236
    }
  ],
  "logs": []
}
""".data(using: .utf8)!
let inspectionAccounts = try CLIProxyAPIClient.decodeCodexInspectionAccounts(
    authFilesData: codexInspectionAuthFilesPayload,
    inspectionRunData: codexInspectionRunPayload
)
runner.check(inspectionAccounts.count == 2, "server inspection accounts should ignore disabled Codex auth files")
let healthyInspection = runner.require(
    inspectionAccounts.first { $0.authIndex == "auth-healthy" },
    "server inspection should include the healthy account"
)
runner.check(healthyInspection.state == .healthy, "action keep with status 200 and non-quota inspection should be healthy even if raw status is error")
runner.check(healthyInspection.planLabel == "Pro 20x", "server inspection merge should preserve auth-file plan type")
runner.check(healthyInspection.quotaSummaryText == "5h 99%  7d 33%", "server inspection quota windows should display 5h and weekly remaining quota")
let limitedInspection = runner.require(
    inspectionAccounts.first { $0.authIndex == "auth-limited" },
    "server inspection should include the limited account"
)
runner.check(limitedInspection.state == .quotaExhausted, "server inspection quota flag should mark quota exhausted")
runner.check(limitedInspection.stateReasonText == "周额度已满", "server inspection weekly quota should explain the exhausted window")
runner.check(limitedInspection.quotaSummaryText == "5h 31%  7d 0%", "server inspection quota windows should display 5h and weekly remaining percent")

let hiddenModelInspectionRunPayload = """
{
  "run": {
    "id": 264,
    "status": "completed",
    "finishedAtMs": 1781693102244
  },
  "results": [
    {
      "fileName": "codex-hidden-model-pro.json",
      "displayAccount": "hidden-model@example.com",
      "authIndex": "auth-hidden-model",
      "provider": "codex",
      "disabled": false,
      "status": "error",
      "action": "keep",
      "actionReason": "账号级额度仍可用",
      "statusCode": 200,
      "quotaWindows": [
        {
          "id": "spark-five-hour",
          "labelParams": { "name": "GPT-5.3-Codex-Spark" },
          "usedPercent": 100,
          "limitWindowSeconds": 18000
        },
        {
          "id": "spark-weekly",
          "labelParams": { "name": "GPT-5.3-Codex-Spark" },
          "usedPercent": 100,
          "limitWindowSeconds": 604800
        }
      ],
      "isQuota": false,
      "createdAtMs": 1781693102237
    }
  ],
  "logs": []
}
""".data(using: .utf8)!
let hiddenModelInspectionAccounts = try CLIProxyAPIClient.decodeCodexInspectionAccounts(
    authFilesData: Data(#"{"files":[]}"#.utf8),
    inspectionRunData: hiddenModelInspectionRunPayload
)
let hiddenModelInspection = runner.require(
    hiddenModelInspectionAccounts.first,
    "server inspection should decode the hidden model account"
)
runner.check(hiddenModelInspection.state == .healthy, "hidden model quota windows should not mark a CLIProxyAPI account as quota exhausted")
runner.check(hiddenModelInspection.quotaSummaryText == "额度 --", "hidden model quota windows should not be displayed in CLIProxyAPI detail")

let currentWhamPayload = """
{
  "user_id": "user-1",
  "account_id": "user-1",
  "email": "codex@example.com",
  "plan_type": "pro",
  "rate_limit": {
    "allowed": true,
    "limit_reached": false,
    "primary_window": {
      "used_percent": 21,
      "limit_window_seconds": 18000,
      "reset_after_seconds": 13996,
      "reset_at": 1781390042
    },
    "secondary_window": {
      "used_percent": 38,
      "limit_window_seconds": 604800,
      "reset_after_seconds": 431880,
      "reset_at": 1781807925
    }
  },
  "code_review_rate_limit": null,
  "additional_rate_limits": [
    {
      "limit_name": "GPT-5.3-Codex-Spark",
      "metered_feature": "codex_bengalfox",
      "rate_limit": {
        "allowed": true,
        "limit_reached": false,
        "primary_window": {
          "used_percent": 100,
          "limit_window_seconds": 18000
        },
        "secondary_window": {
          "used_percent": 0,
          "limit_window_seconds": 604800
        }
      }
    }
  ]
}
""".data(using: .utf8)!
let currentWhamQuota = try CLIProxyAPIClient.decodeQuotaBody(currentWhamPayload, fallbackPlanType: nil)
runner.check(currentWhamQuota.planType == "pro", "current wham payload should preserve plan type")
runner.check(currentWhamQuota.windows.count == 4, "current wham payload should decode primary, secondary, and additional windows")
runner.check(currentWhamQuota.windows[0].remainingPercent == 79, "current wham primary remaining percent should decode")
runner.check(currentWhamQuota.windows[1].remainingPercent == 62, "current wham weekly remaining percent should decode")
let currentWhamAccount = remoteAccount(
    id: "current-wham",
    state: .healthy,
    quotaWindows: currentWhamQuota.windows
).withQuotaExhaustion
runner.check(currentWhamAccount.displayQuotaWindows.map(\.shortLabel) == ["5h", "7d"], "decoded additional model quotas should be hidden from CLIProxyAPI detail")
runner.check(currentWhamAccount.quotaSummaryText == "5h 79%  7d 62%", "decoded quota summary should only include bare 5h and 7d windows")
runner.check(currentWhamAccount.state == .healthy, "hidden decoded model quota should not mark the account as quota exhausted")

let proxyStringBodyPayload = """
{
  "status_code": 200,
  "body": "{\\"plan_type\\":\\"plus\\",\\"rate_limit\\":{\\"allowed\\":true,\\"limit_reached\\":false,\\"primary_window\\":{\\"used_percent\\":12,\\"limit_window_seconds\\":18000},\\"secondary_window\\":{\\"used_percent\\":34,\\"limit_window_seconds\\":604800}}}"
}
""".data(using: .utf8)!
let proxyStringBodyQuota = try CLIProxyAPIClient.decodeQuotaProxyResponse(proxyStringBodyPayload, fallbackPlanType: nil)
runner.check(proxyStringBodyQuota.planType == "plus", "proxy string body should preserve quota plan type")
runner.check(proxyStringBodyQuota.windows.count == 2, "proxy string body should decode quota windows")
runner.check(proxyStringBodyQuota.windows[0].remainingPercent == 88, "proxy string body should decode primary remaining percent")
runner.check(proxyStringBodyQuota.windows[1].remainingPercent == 66, "proxy string body should decode secondary remaining percent")

let stringBoolLimitPayload = """
{
  "rate_limit": {
    "allowed": "false",
    "limit_reached": "true",
    "primary_window": {
      "limit_window_seconds": 18000
    }
  }
}
""".data(using: .utf8)!
let stringBoolLimitQuota = try CLIProxyAPIClient.decodeQuotaBody(stringBoolLimitPayload, fallbackPlanType: nil)
runner.check(stringBoolLimitQuota.windows.first?.reachesThreshold == true, "string boolean quota flags should mark threshold reached")

let proxyStringBodyErrorPayload = """
{
  "status_code": 200,
  "body": "{\\"error\\":{\\"type\\":\\"usage_limit_reached\\",\\"message\\":\\"The usage limit has been reached\\"}}"
}
""".data(using: .utf8)!
do {
    _ = try CLIProxyAPIClient.decodeQuotaProxyResponse(proxyStringBodyErrorPayload, fallbackPlanType: nil)
    runner.check(false, "proxy error body should not decode as an empty successful quota")
} catch {
    runner.check(error.localizedDescription.contains("usage limit") || error.localizedDescription.contains("额度"), "proxy error body should surface the upstream quota error")
}

let authFilesPayload = """
{
  "files": [
    {
      "authIndex": "7",
      "name": "codex-team",
      "provider": "Codex",
      "statusMessage": "ok",
      "recentRequests": [
        { "success": "2", "failed": "0" }
      ],
      "idToken": {
        "chatgptAccountId": "acct-1",
        "planType": "team"
      }
    }
  ]
}
""".data(using: .utf8)!
let authFiles = try JSONDecoder().decode(CLIProxyAuthFilesResponse.self, from: authFilesPayload)
let authFile = authFiles.files[0]
runner.check(authFile.authIndex == "7", "auth files should decode camelCase authIndex")
runner.check(authFile.statusMessage == "ok", "auth files should decode camelCase statusMessage")
runner.check(authFile.recentRequests?.first?.success == 2, "recent request success should decode string integers")
runner.check(authFile.idToken?.chatgptAccountID == "acct-1", "idToken should decode camelCase chatgpt account id")

let quotaAvailableInspectionPayload = """
{
  "results": [
    {
      "fileName": "codex-quota-available.json",
      "displayAccount": "available@example.com",
      "authIndex": "auth-available",
      "provider": "codex",
      "disabled": false,
      "status": "error",
      "action": "keep",
      "actionReason": "weekly quota still available",
      "statusCode": 200,
      "isQuota": false,
      "createdAtMs": 1781693102238
    }
  ],
  "logs": []
}
""".data(using: .utf8)!
let quotaAvailableAccounts = try CLIProxyAPIClient.decodeCodexInspectionAccounts(
    authFilesData: codexInspectionAuthFilesPayload,
    inspectionRunData: quotaAvailableInspectionPayload
)
runner.check(quotaAvailableAccounts.first?.state == .healthy, "available quota reason should not be treated as quota exhausted")

let previousQuotaAccounts = [
    remoteAccount(
        id: "preserve-1",
        state: .healthy,
        quotaWindows: [
            RemoteQuotaWindow(
                id: "code-primary",
                shortLabel: "5h",
                remainingPercent: 77,
                usedPercent: 23,
                resetText: nil
            )
        ]
    )
]
let currentQuotaMissingAccounts = [
    remoteAccount(id: "preserve-1", state: .healthy, quotaWindows: [])
]
let mergedQuotaAccounts = RemoteCodexAccount.preservingQuota(
    in: currentQuotaMissingAccounts,
    from: previousQuotaAccounts
)
runner.check(mergedQuotaAccounts.first?.quotaSummaryText == "5h 77%", "remote account list merge should preserve previous quota windows when current refresh has none")

let sensitiveStatusAccount = RemoteCodexAccount(
    id: "secret-status-field",
    name: "secret-status-field",
    email: nil,
    label: nil,
    provider: "codex",
    accountType: nil,
    authIndex: "secret-status-field",
    chatgptAccountID: nil,
    status: "Bearer sk-sensitive-token",
    statusMessage: nil,
    successCount: 0,
    failureCount: 1,
    recentFailures: 0,
    state: .abnormal,
    lastRefresh: nil,
    planType: "plus",
    quotaWindows: [],
    quotaError: nil
)
runner.check(sensitiveStatusAccount.stateReasonText == "状态异常", "remote status values should be mapped before display")
runner.check(!sensitiveStatusAccount.stateReasonText.lowercased().contains("sk-"), "remote status values should not leak token-like secrets")

let sensitiveReasonAccount = RemoteCodexAccount(
    id: "secret-status",
    name: "secret-status",
    email: nil,
    label: nil,
    provider: "codex",
    accountType: nil,
    authIndex: "secret-status",
    chatgptAccountID: nil,
    status: "active",
    statusMessage: "token sk-1234567890abcdef should not appear",
    successCount: 0,
    failureCount: 1,
    recentFailures: 1,
    state: .abnormal,
    lastRefresh: nil,
    planType: "plus",
    quotaWindows: [],
    quotaError: nil
)
runner.check(!sensitiveReasonAccount.stateReasonText.lowercased().contains("sk-"), "remote status reasons should redact token-like secrets before display")

runner.check(
    CodexNotchSettings.managementKeyForSave(
        draftKey: "old-secret",
        oldPanelURL: "https://old.example.com/management.html",
        newPanelURL: "https://new.example.com/management.html",
        oldAllowsInsecureTLS: false,
        newAllowsInsecureTLS: false,
        remoteEnabled: true
    ).isEmpty,
    "changing remote panel origin should clear the old management key instead of saving it to the new origin"
)
runner.check(
    CodexNotchSettings.managementKeyForSave(
        draftKey: "old-secret",
        oldPanelURL: "https://old.example.com/management.html",
        newPanelURL: "https://old.example.com/management.html",
        oldAllowsInsecureTLS: false,
        newAllowsInsecureTLS: true,
        remoteEnabled: true
    ).isEmpty,
    "changing insecure TLS mode should clear the old management key"
)
runner.check(
    CodexNotchSettings.managementKeyForSave(
        draftKey: "old-secret",
        oldPanelURL: "https://old.example.com/management.html",
        newPanelURL: "https://old.example.com/management.html",
        oldAllowsInsecureTLS: true,
        newAllowsInsecureTLS: true,
        oldTLSCertificateSHA256: String(repeating: "a", count: 64),
        newTLSCertificateSHA256: String(repeating: "b", count: 64),
        remoteEnabled: true,
        oldSavedKey: "old-secret"
    ).isEmpty,
    "changing the pinned certificate should clear the old management key"
)
runner.check(
    CodexNotchSettings.managementKeyForSave(
        draftKey: "new-secret",
        oldPanelURL: "https://old.example.com/management.html",
        newPanelURL: "https://new.example.com/management.html",
        oldAllowsInsecureTLS: false,
        newAllowsInsecureTLS: false,
        remoteEnabled: true,
        oldSavedKey: "old-secret"
    ) == "new-secret",
    "changing remote panel origin should save a newly entered management key"
)
runner.check(
    CodexNotchSettings.managementKeyForSave(
        draftKey: "old-secret",
        oldPanelURL: "not a url",
        newPanelURL: "https://new.example.com/management.html",
        oldAllowsInsecureTLS: false,
        newAllowsInsecureTLS: false,
        remoteEnabled: true,
        oldSavedKey: "old-secret"
    ).isEmpty,
    "changing from an invalid remote panel URL to a valid origin should clear a reused management key"
)
runner.check(
    CodexNotchSettings.apiKeyForSave(
        draftKey: "old-api-token",
        oldPanelURL: "not a url",
        newPanelURL: "https://newapi.example.com",
        oldAllowsInsecureTLS: false,
        newAllowsInsecureTLS: false,
        enabled: true,
        oldSavedKey: "old-api-token"
    ).isEmpty,
    "changing from an invalid API panel URL to a valid origin should clear a reused API key"
)
runner.check(
    CodexNotchSettings.apiKeyForSave(
        draftKey: "new-api-token",
        oldPanelURL: "not a url",
        newPanelURL: "https://newapi.example.com",
        oldAllowsInsecureTLS: false,
        newAllowsInsecureTLS: false,
        enabled: true,
        oldSavedKey: "old-api-token"
    ) == "new-api-token",
    "changing API panel origin should save a newly entered API key"
)

let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("CodexNotchRegression-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
defer {
    try? FileManager.default.removeItem(at: tempRoot)
}

let stateDatabase = tempRoot.appendingPathComponent("state_5.sqlite").path
let logsDatabase = tempRoot.appendingPathComponent("logs_2.sqlite").path
_ = try Shell.run("/usr/bin/sqlite3", [
    stateDatabase,
    """
    create table threads(
      id text,
      title text,
      tokens_used integer,
      model text,
      reasoning_effort text,
      rollout_path text,
      created_at integer,
      updated_at integer,
      archived integer default 0
    );
    """
])
_ = try Shell.run("/usr/bin/sqlite3", [
    logsDatabase,
    """
    create table logs(
      thread_id text,
      ts integer,
      target text,
      feedback_log_body text
    );
    """
])

let sessionID = "019e7169-d297-74c1-a61a-8e5a82acab34"
let subagentSessionID = "019ec23f-2f8e-7d50-a71d-b8a2ba679fd4"
let historicalSubagentSessionID = "019ec23f-7777-7d50-a71d-b8a2ba679fd4"
let parentOnlySessionID = "019e073a-c032-74e2-966e-b85ede0c9ccb"
let parentOnlySubagentID = "019ec23f-344a-7171-99d0-f1c2fe671252"
let pollutedDeltaParentSessionID = "019e073a-c032-74e2-966e-b85ede0c9caa"
let pollutedDeltaSubagentID = "019ec23f-6666-7171-99d0-f1c2fe671252"
let staleParentSessionID = "019e073a-c032-74e2-966e-b85ede0c9cd1"
let staleParentSubagentID = "019ec23f-5555-7171-99d0-f1c2fe671252"
let longMetaParentSessionID = "019e073a-c032-74e2-966e-b85ede0c9cd0"
let longMetaSubagentID = "019ec23f-4444-7171-99d0-f1c2fe671252"
let completedSessionID = "019e073a-c032-74e2-966e-b85ede0c9ccd"
let completedFinalAnswerSessionID = "019e073a-c032-74e2-966e-b85ede0c9ccf"
let dbBackedSessionID = "019e073a-c032-74e2-966e-b85ede0c9cce"
let staleDBTokenSessionID = "019e073a-c032-74e2-966e-b85ede0c9cd2"
let activeToolCallSessionID = "019e073a-c032-74e2-966e-b85ede0c9cd3"
let codexQuotaSessionID = "019e073a-c032-74e2-966e-b85ede0c9cdb"
let sparkQuotaSessionID = "019e073a-c032-74e2-966e-b85ede0c9cda"
let lunaQuotaSessionID = "019e073a-c032-74e2-966e-b85ede0c9cab"
let archivedUsageSessionID = "019e073a-c032-74e2-966e-b85ede0c9cdc"
let archivedOnlyUsageSessionID = "019e073a-c032-74e2-966e-b85ede0c9cdd"
let sessionDirectory = tempRoot
    .appendingPathComponent("sessions/2026/06/14", isDirectory: true)
try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
let rolloutPath = sessionDirectory
    .appendingPathComponent("rollout-2026-06-14T02-20-00-\(sessionID).jsonl")
let now = Date()
let timestamp = ISO8601DateFormatter().string(from: now)
let subagentQuotaTimestamp = ISO8601DateFormatter().string(from: now.addingTimeInterval(30))
let codexPrimaryReset = Int(now.timeIntervalSince1970) + 5 * 60 * 60
let codexSecondaryReset = Int(now.timeIntervalSince1970) + 7 * 24 * 60 * 60
let subagentPrimaryReset = codexPrimaryReset + 600
let subagentSecondaryReset = codexSecondaryReset + 600
let rolloutBody = """
{"timestamp":"\(timestamp)","type":"turn_context","payload":{"model":"gpt-5.6-sol","effort":"ultra","collaboration_mode":{"settings":{"reasoning_effort":"ultra"}}}}
{"timestamp":"\(timestamp)","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"正在运行的 Codex 任务"}]}}
{"timestamp":"\(timestamp)","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":90000}}}}
{"timestamp":"\(timestamp)","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":60000,"total_tokens":12345},"model_context_window":240000}}}
"""
try rolloutBody.write(to: rolloutPath, atomically: true, encoding: .utf8)
try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: rolloutPath.path)

let subagentRolloutPath = sessionDirectory
    .appendingPathComponent("rollout-2026-06-14T02-20-01-\(subagentSessionID).jsonl")
let subagentRolloutBody = """
{"timestamp":"\(timestamp)","type":"session_meta","payload":{"id":"\(subagentSessionID)","parent_thread_id":"\(sessionID)","source":{"subagent":{"thread_spawn":{"parent_thread_id":"\(sessionID)","depth":1,"agent_nickname":"Test","agent_role":"explorer"}}},"thread_source":"subagent","agent_nickname":"Test","agent_role":"explorer"}}
{"timestamp":"\(timestamp)","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"子代理任务不应该显示"}]}}
{"timestamp":"\(timestamp)","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":10000}}}}
{"timestamp":"\(subagentQuotaTimestamp)","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":0}},"rate_limits":{"limit_id":"codex","primary":{"used_percent":8,"resets_at":\(subagentPrimaryReset)},"secondary":{"used_percent":2,"resets_at":\(subagentSecondaryReset)}}}}
{"timestamp":"\(timestamp)","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":23456}}}}
"""
try subagentRolloutBody.write(to: subagentRolloutPath, atomically: true, encoding: .utf8)
try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(30)], ofItemAtPath: subagentRolloutPath.path)

let historicalSubagentRolloutPath = sessionDirectory
    .appendingPathComponent("rollout-2026-06-14T02-20-04-\(historicalSubagentSessionID).jsonl")
let historicalSubagentRolloutBody = """
{"timestamp":"\(timestamp)","type":"session_meta","payload":{"id":"\(historicalSubagentSessionID)","parent_thread_id":"\(sessionID)","source":{"subagent":{"thread_spawn":{"parent_thread_id":"\(sessionID)","depth":1,"agent_nickname":"Old","agent_role":"reviewer"}}},"thread_source":"subagent","agent_nickname":"Old","agent_role":"reviewer"}}
{"timestamp":"\(timestamp)","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"历史子代理不应该计入当前子代理数量"}]}}
{"timestamp":"\(timestamp)","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":50000}}}}
"""
try historicalSubagentRolloutBody.write(to: historicalSubagentRolloutPath, atomically: true, encoding: .utf8)
try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-600)], ofItemAtPath: historicalSubagentRolloutPath.path)

let parentOnlyRolloutPath = sessionDirectory
    .appendingPathComponent("rollout-2026-06-14T02-20-02-\(parentOnlySessionID).jsonl")
let parentOnlyBody = """
{"timestamp":"\(timestamp)","type":"turn_context","payload":{"model":"gpt-5.5","effort":"high","collaboration_mode":{"settings":{"reasoning_effort":"high"}}}}
{"timestamp":"\(timestamp)","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"只有子代理活跃的父任务"}]}}
{"timestamp":"\(timestamp)","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":34567}}}}
"""
try parentOnlyBody.write(to: parentOnlyRolloutPath, atomically: true, encoding: .utf8)
try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-600)], ofItemAtPath: parentOnlyRolloutPath.path)

let parentOnlySubagentPath = sessionDirectory
    .appendingPathComponent("rollout-2026-06-14T02-20-03-\(parentOnlySubagentID).jsonl")
let parentOnlySubagentBody = """
{"timestamp":"\(timestamp)","type":"session_meta","payload":{"id":"\(parentOnlySubagentID)","parent_thread_id":"\(parentOnlySessionID)","source":{"subagent":{"thread_spawn":{"parent_thread_id":"\(parentOnlySessionID)","depth":1,"agent_nickname":"Worker","agent_role":"reviewer"}}},"thread_source":"subagent","agent_nickname":"Worker","agent_role":"reviewer"}}
{"timestamp":"\(timestamp)","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"另一个子代理任务不应该显示"}]}}
{"timestamp":"\(timestamp)","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":45678}}}}
"""
try parentOnlySubagentBody.write(to: parentOnlySubagentPath, atomically: true, encoding: .utf8)
try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: parentOnlySubagentPath.path)

let pollutedDeltaParentPath = sessionDirectory
    .appendingPathComponent("rollout-2026-06-14T02-20-14-\(pollutedDeltaParentSessionID).jsonl")
let pollutedDeltaParentBody = """
{"timestamp":"\(timestamp)","type":"turn_context","payload":{"model":"gpt-5.5","effort":"high","collaboration_mode":{"settings":{"reasoning_effort":"high"}}}}
{"timestamp":"\(timestamp)","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"parent token should not absorb subagent deltas"}]}}
{"timestamp":"\(timestamp)","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":162000000}}}}
"""
try pollutedDeltaParentBody.write(to: pollutedDeltaParentPath, atomically: true, encoding: .utf8)
try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-600)], ofItemAtPath: pollutedDeltaParentPath.path)
_ = try Shell.run("/usr/bin/sqlite3", [
    stateDatabase,
    """
    insert into threads(id, title, tokens_used, model, reasoning_effort, rollout_path, updated_at, archived)
    values('\(pollutedDeltaParentSessionID)', 'parent token should not absorb subagent deltas', 162000000, 'gpt-5.5', 'high', '\(pollutedDeltaParentPath.path)', \(Int(now.timeIntervalSince1970) - 600), 0);
    """
])

let pollutedDeltaSubagentPath = sessionDirectory
    .appendingPathComponent("rollout-2026-06-14T02-20-15-\(pollutedDeltaSubagentID).jsonl")
let pollutedDeltaSubagentBody = """
{"timestamp":"\(timestamp)","type":"session_meta","payload":{"id":"\(pollutedDeltaSubagentID)","parent_thread_id":"\(pollutedDeltaParentSessionID)","source":{"subagent":{"thread_spawn":{"parent_thread_id":"\(pollutedDeltaParentSessionID)","depth":1,"agent_nickname":"Delta","agent_role":"explorer"}}},"thread_source":"subagent","agent_nickname":"Delta","agent_role":"explorer"}}
{"timestamp":"\(timestamp)","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"subagent token should stay separate from parent delta"}]}}
{"timestamp":"\(timestamp)","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":23000000}}}}
"""
try pollutedDeltaSubagentBody.write(to: pollutedDeltaSubagentPath, atomically: true, encoding: .utf8)
try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-600)], ofItemAtPath: pollutedDeltaSubagentPath.path)

let staleParentPath = sessionDirectory
    .appendingPathComponent("rollout-2026-06-14T02-20-10-\(staleParentSessionID).jsonl")
let staleParentBody = """
{"timestamp":"\(timestamp)","type":"turn_context","payload":{"model":"gpt-5.5","effort":"high","collaboration_mode":{"settings":{"reasoning_effort":"high"}}}}
{"timestamp":"\(timestamp)","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"父会话超出当前任务范围但子代理正在运行"}]}}
{"timestamp":"\(timestamp)","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":123000}}}}
"""
try staleParentBody.write(to: staleParentPath, atomically: true, encoding: .utf8)
try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-2 * 24 * 60 * 60)], ofItemAtPath: staleParentPath.path)

let staleParentSubagentPath = sessionDirectory
    .appendingPathComponent("rollout-2026-06-14T02-20-11-\(staleParentSubagentID).jsonl")
let staleParentSubagentBody = """
{"timestamp":"\(timestamp)","type":"session_meta","payload":{"id":"\(staleParentSubagentID)","parent_thread_id":"\(staleParentSessionID)","source":{"subagent":{"thread_spawn":{"parent_thread_id":"\(staleParentSessionID)","depth":1,"agent_nickname":"Worker","agent_role":"explorer"}}},"thread_source":"subagent","agent_nickname":"Worker","agent_role":"explorer"}}
{"timestamp":"\(timestamp)","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"子代理仍在输出"}]}}
{"timestamp":"\(timestamp)","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":321000}}}}
"""
try staleParentSubagentBody.write(to: staleParentSubagentPath, atomically: true, encoding: .utf8)
try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: staleParentSubagentPath.path)

let longMetaParentPath = sessionDirectory
    .appendingPathComponent("rollout-2026-06-14T02-20-08-\(longMetaParentSessionID).jsonl")
let longMetaParentBody = """
{"timestamp":"\(timestamp)","type":"turn_context","payload":{"model":"gpt-5.5","effort":"high","collaboration_mode":{"settings":{"reasoning_effort":"high"}}}}
{"timestamp":"\(timestamp)","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"超长 session_meta 的父任务"}]}}
{"timestamp":"\(timestamp)","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":22222}}}}
"""
try longMetaParentBody.write(to: longMetaParentPath, atomically: true, encoding: .utf8)
try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-600)], ofItemAtPath: longMetaParentPath.path)

let longSessionMetaPadding = String(repeating: "x", count: 80_000)
let longMetaSubagentPath = sessionDirectory
    .appendingPathComponent("rollout-2026-06-14T02-20-09-\(longMetaSubagentID).jsonl")
let longMetaSubagentBody = """
{"timestamp":"\(timestamp)","type":"session_meta","payload":{"id":"\(longMetaSubagentID)","parent_thread_id":"\(longMetaParentSessionID)","source":{"subagent":{"thread_spawn":{"parent_thread_id":"\(longMetaParentSessionID)","depth":1,"agent_nickname":"Long","agent_role":"explorer"}}},"thread_source":"subagent","agent_nickname":"Long","agent_role":"explorer","base_instructions":{"text":"\(longSessionMetaPadding)"}}}
{"timestamp":"\(timestamp)","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"超长子代理任务不应该显示"}]}}
{"timestamp":"\(timestamp)","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":11111}}}}
"""
try longMetaSubagentBody.write(to: longMetaSubagentPath, atomically: true, encoding: .utf8)
try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: longMetaSubagentPath.path)
_ = try Shell.run("/usr/bin/sqlite3", [
    stateDatabase,
    """
    insert into threads(id, title, tokens_used, model, reasoning_effort, rollout_path, updated_at, archived)
    values('\(longMetaSubagentID)', '数据库里的子代理不应该显示', 11111, 'gpt-5.5', 'xhigh', '\(longMetaSubagentPath.path)', \(Int(now.timeIntervalSince1970)), 0);
    """
])

let completedRolloutPath = sessionDirectory
    .appendingPathComponent("rollout-2026-06-14T02-20-05-\(completedSessionID).jsonl")
let completedBody = """
{"timestamp":"\(timestamp)","type":"turn_context","payload":{"model":"gpt-5.5","effort":"high","collaboration_mode":{"settings":{"reasoning_effort":"high"}}}}
{"timestamp":"\(timestamp)","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"已经完成的任务"}]}}
{"timestamp":"\(timestamp)","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"完成"}],"phase":"final"}}
"""
try completedBody.write(to: completedRolloutPath, atomically: true, encoding: .utf8)
try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: completedRolloutPath.path)

let completedFinalAnswerRolloutPath = sessionDirectory
    .appendingPathComponent("rollout-2026-06-14T02-20-07-\(completedFinalAnswerSessionID).jsonl")
let completedFinalAnswerBody = """
{"timestamp":"\(timestamp)","type":"turn_context","payload":{"model":"gpt-5.5","effort":"high","collaboration_mode":{"settings":{"reasoning_effort":"high"}}}}
{"timestamp":"\(timestamp)","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"刚刚完成但还很新的任务"}]}}
{"timestamp":"\(timestamp)","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"完成"}],"phase":"final_answer"}}
{"timestamp":"\(timestamp)","type":"event_msg","payload":{"type":"task_complete","turn_id":"019ed38c-b572-7140-a10f-e4c982c36066","completed_at":\(Int(now.timeIntervalSince1970)),"duration_ms":1200}}
"""
try completedFinalAnswerBody.write(to: completedFinalAnswerRolloutPath, atomically: true, encoding: .utf8)
try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: completedFinalAnswerRolloutPath.path)

let dbBackedRolloutPath = sessionDirectory
    .appendingPathComponent("rollout-2026-06-14T02-20-06-\(dbBackedSessionID).jsonl")
let dbBackedBody = """
{"timestamp":"\(timestamp)","type":"turn_context","payload":{"model":"gpt-5.5","effort":"high","collaboration_mode":{"settings":{"reasoning_effort":"high"}}}}
{"timestamp":"\(timestamp)","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"数据库已有 token 的旧任务"}]}}
{"timestamp":"\(timestamp)","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"完成"}],"phase":"final"}}
"""
try dbBackedBody.write(to: dbBackedRolloutPath, atomically: true, encoding: .utf8)
try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: dbBackedRolloutPath.path)
_ = try Shell.run("/usr/bin/sqlite3", [
    stateDatabase,
    """
    insert into threads(id, title, tokens_used, model, reasoning_effort, rollout_path, updated_at, archived)
    values('\(dbBackedSessionID)', '数据库已有 token 的旧任务', 777, 'gpt-5.5', 'high', '\(dbBackedRolloutPath.path)', \(Int(now.timeIntervalSince1970) - 7 * 24 * 60 * 60), 0);
    """
])

let staleDBTokenRolloutPath = sessionDirectory
    .appendingPathComponent("rollout-2026-06-14T02-20-12-\(staleDBTokenSessionID).jsonl")
let staleDBTokenBody = """
{"timestamp":"\(timestamp)","type":"turn_context","payload":{"model":"gpt-5.5","effort":"high","collaboration_mode":{"settings":{"reasoning_effort":"high"}}}}
{"timestamp":"\(timestamp)","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"数据库 token 滞后的运行中任务"}]}}
{"timestamp":"\(timestamp)","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":120000000}}}}
"""
try staleDBTokenBody.write(to: staleDBTokenRolloutPath, atomically: true, encoding: .utf8)
try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: staleDBTokenRolloutPath.path)
_ = try Shell.run("/usr/bin/sqlite3", [
    stateDatabase,
    """
    insert into threads(id, title, tokens_used, model, reasoning_effort, rollout_path, updated_at, archived)
    values('\(staleDBTokenSessionID)', '数据库 token 滞后的运行中任务', 13, 'gpt-5.5', 'high', '\(staleDBTokenRolloutPath.path)', \(Int(now.timeIntervalSince1970)), 0);
    """
])

let activeToolCallPath = sessionDirectory
    .appendingPathComponent("rollout-2026-06-14T02-20-13-\(activeToolCallSessionID).jsonl")
let activeToolCallActivity = ISO8601DateFormatter().string(from: now.addingTimeInterval(-240))
let activeToolCallItemDone = ISO8601DateFormatter().string(from: now.addingTimeInterval(-230))
let activeToolCallBody = """
{"timestamp":"\(timestamp)","type":"turn_context","payload":{"model":"gpt-5.5","effort":"xhigh","collaboration_mode":{"settings":{"reasoning_effort":"xhigh"}}}}
{"timestamp":"\(activeToolCallActivity)","type":"response_item","payload":{"type":"function_call","name":"exec_command","arguments":"{}"}}
{"timestamp":"\(activeToolCallItemDone)","type":"event_msg","payload":{"type":"response.function_call_arguments.done"}}
{"timestamp":"\(activeToolCallItemDone)","type":"event_msg","payload":{"type":"response.output_item.done"}}
{"timestamp":"\(activeToolCallItemDone)","type":"event_msg","payload":{"type":"response.completed"}}
"""
try activeToolCallBody.write(to: activeToolCallPath, atomically: true, encoding: .utf8)
try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: activeToolCallPath.path)
_ = try Shell.run("/usr/bin/sqlite3", [
    stateDatabase,
    """
    insert into threads(id, title, tokens_used, model, reasoning_effort, rollout_path, updated_at, archived)
    values('\(activeToolCallSessionID)', '工具调用仍在运行', 21, 'gpt-5.5', 'xhigh', '\(activeToolCallPath.path)', \(Int(now.timeIntervalSince1970)), 0);
    """
])

let codexQuotaPath = sessionDirectory
    .appendingPathComponent("rollout-2026-06-14T02-20-18-\(codexQuotaSessionID).jsonl")
let codexQuotaBody = """
{"timestamp":"\(timestamp)","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Codex 额度恢复时间测试"}]}}
{"timestamp":"\(timestamp)","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":0}},"rate_limits":{"limit_id":"codex","primary":{"used_percent":33,"window_minutes":300,"resets_at":\(codexPrimaryReset)},"secondary":{"used_percent":55,"window_minutes":10080,"resets_at":\(codexSecondaryReset)}}}}
"""
try codexQuotaBody.write(to: codexQuotaPath, atomically: true, encoding: .utf8)
try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: codexQuotaPath.path)
_ = try Shell.run("/usr/bin/sqlite3", [
    stateDatabase,
    """
    insert into threads(id, title, tokens_used, model, reasoning_effort, rollout_path, updated_at, archived)
    values('\(codexQuotaSessionID)', 'Codex 额度恢复时间测试', 0, 'gpt-5.6-sol', 'ultra', '\(codexQuotaPath.path)', \(Int(now.timeIntervalSince1970)), 0);
    """
])

let sparkQuotaPath = sessionDirectory
    .appendingPathComponent("rollout-2026-06-14T02-20-17-\(sparkQuotaSessionID).jsonl")
let sparkQuotaBody = """
{"timestamp":"\(timestamp)","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Spark 额度测试"}]}}
{"timestamp":"\(timestamp)","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":0}},"rate_limits":{"limit_id":"codex_bengalfox","limit_name":"GPT-5.3-Codex-Spark","primary":{"used_percent":40,"resets_at":\(codexPrimaryReset)},"secondary":{"used_percent":"10","resets_at":\(codexSecondaryReset)}}}}
"""
try sparkQuotaBody.write(to: sparkQuotaPath, atomically: true, encoding: .utf8)
try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: sparkQuotaPath.path)
_ = try Shell.run("/usr/bin/sqlite3", [
    stateDatabase,
    """
    insert into threads(id, title, tokens_used, model, reasoning_effort, rollout_path, updated_at, archived)
    values('\(sparkQuotaSessionID)', 'Spark 额度测试', 0, 'gpt-5.5', 'high', '\(sparkQuotaPath.path)', \(Int(now.timeIntervalSince1970)), 0);
    """
])

let lunaQuotaPath = sessionDirectory
    .appendingPathComponent("rollout-2026-06-14T02-20-16-\(lunaQuotaSessionID).jsonl")
let lunaQuotaBody = """
{"timestamp":"\(timestamp)","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Luna 额度测试"}]}}
{"timestamp":"\(timestamp)","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":0}},"rate_limits":{"limit_id":"codex_luna","limit_name":"GPT-5.6-Codex-Luna","primary":{"used_percent":12,"resets_at":\(codexPrimaryReset)},"secondary":{"used_percent":"34","resets_at":\(codexSecondaryReset)}}}}
"""
try lunaQuotaBody.write(to: lunaQuotaPath, atomically: true, encoding: .utf8)
try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: lunaQuotaPath.path)
_ = try Shell.run("/usr/bin/sqlite3", [
    stateDatabase,
    """
    insert into threads(id, title, tokens_used, model, reasoning_effort, rollout_path, updated_at, archived)
    values('\(lunaQuotaSessionID)', 'Luna 额度测试', 0, 'gpt-5.6-luna', 'high', '\(lunaQuotaPath.path)', \(Int(now.timeIntervalSince1970)), 0);
    """
])

let archivedUsagePath = sessionDirectory
    .appendingPathComponent("rollout-2026-06-14T02-20-19-\(archivedUsageSessionID).jsonl")
let archivedUsageBody = """
{"timestamp":"\(timestamp)","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":999999}}}}
"""
try archivedUsageBody.write(to: archivedUsagePath, atomically: true, encoding: .utf8)
try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: archivedUsagePath.path)
_ = try Shell.run("/usr/bin/sqlite3", [
    stateDatabase,
    """
    insert into threads(id, title, tokens_used, model, reasoning_effort, rollout_path, updated_at, archived)
    values('\(archivedUsageSessionID)', 'Archived usage should be included', 999999, 'gpt-5.5', 'high', '\(archivedUsagePath.path)', \(Int(now.timeIntervalSince1970)), 1);
    """
])

let archivedOnlySessionDirectory = tempRoot
    .appendingPathComponent("archived_sessions/2026/06/14", isDirectory: true)
try FileManager.default.createDirectory(at: archivedOnlySessionDirectory, withIntermediateDirectories: true)
let archivedOnlyUsagePath = archivedOnlySessionDirectory
    .appendingPathComponent("rollout-2026-06-14T02-20-20-\(archivedOnlyUsageSessionID).jsonl")
let archivedOnlyUsageBody = """
{"timestamp":"\(timestamp)","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":888888}}}}
"""
try archivedOnlyUsageBody.write(to: archivedOnlyUsagePath, atomically: true, encoding: .utf8)
try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: archivedOnlyUsagePath.path)

let deltaDirectory = tempRoot.appendingPathComponent("context-guard", isDirectory: true)
try FileManager.default.createDirectory(at: deltaDirectory, withIntermediateDirectories: true)
let deltaDatabase = deltaDirectory.appendingPathComponent("usage-deltas.sqlite").path
let observedNowMs = Int64((now.timeIntervalSince1970 * 1_000).rounded())
let oneHourBaselineMs = observedNowMs - Int64(61 * 60 * 1_000)
let twentyFourHourBaselineMs = observedNowMs - Int64(25 * 60 * 60 * 1_000)
let staleCurrentMs = observedNowMs - Int64(2 * 60 * 60 * 1_000)
let staleBaselineMs = observedNowMs - Int64(3 * 60 * 60 * 1_000)
let staleDeltaSessionID = "019e073a-c032-74e2-966e-b85ede0c9cd8"
let missingBaselineDeltaSessionID = "019e073a-c032-74e2-966e-b85ede0c9cd9"
let todayCreatedDeltaSessionID = "019e073a-c032-74e2-966e-b85ede0c9cda"
_ = try Shell.run("/usr/bin/sqlite3", [
    deltaDatabase,
    """
    create table token_snapshots (
      thread_id text primary key,
      tokens_used integer not null,
      updated_at_ms integer not null,
      observed_at_ms integer not null
    );
    create table token_snapshot_history (
      thread_id text not null,
      tokens_used integer not null,
      updated_at_ms integer not null,
      observed_at_ms integer not null,
      primary key(thread_id, observed_at_ms)
    );
    create index idx_token_snapshot_history_lookup
      on token_snapshot_history(thread_id, observed_at_ms desc);
    insert into token_snapshots(thread_id, tokens_used, updated_at_ms, observed_at_ms)
    values
      ('\(sessionID)', 102345, \(observedNowMs), \(observedNowMs)),
      ('\(parentOnlySessionID)', 34567, \(observedNowMs), \(observedNowMs)),
      ('\(pollutedDeltaParentSessionID)', 185000000, \(observedNowMs), \(observedNowMs)),
      ('\(staleDeltaSessionID)', 10000, \(staleCurrentMs), \(staleCurrentMs)),
      ('\(missingBaselineDeltaSessionID)', 500, \(observedNowMs), \(observedNowMs));
    insert into token_snapshot_history(thread_id, tokens_used, updated_at_ms, observed_at_ms)
    values
      ('\(sessionID)', 100000, \(oneHourBaselineMs), \(oneHourBaselineMs)),
      ('\(sessionID)', 90000, \(twentyFourHourBaselineMs), \(twentyFourHourBaselineMs)),
      ('\(parentOnlySessionID)', 34000, \(oneHourBaselineMs), \(oneHourBaselineMs)),
      ('\(parentOnlySessionID)', 14000, \(twentyFourHourBaselineMs), \(twentyFourHourBaselineMs)),
      ('\(pollutedDeltaParentSessionID)', 162000000, \(oneHourBaselineMs), \(oneHourBaselineMs)),
      ('\(pollutedDeltaParentSessionID)', 162000000, \(twentyFourHourBaselineMs), \(twentyFourHourBaselineMs)),
      ('\(pollutedDeltaParentSessionID)', 185000000, \(observedNowMs - 60 * 1000), \(observedNowMs - 60 * 1000)),
      ('\(staleDeltaSessionID)', 1000, \(staleBaselineMs), \(staleBaselineMs));
    """
])
_ = try Shell.run("/usr/bin/sqlite3", [
    stateDatabase,
    """
    insert into threads(id, title, tokens_used, model, reasoning_effort, rollout_path, updated_at, archived)
    values('\(missingBaselineDeltaSessionID)', 'Today baseline missing', 500, 'gpt-5.5', 'high', '', \(Int(now.timeIntervalSince1970)), 0);
    insert into threads(id, title, tokens_used, model, reasoning_effort, rollout_path, created_at, updated_at, archived)
    values('\(todayCreatedDeltaSessionID)', 'Today created baseline missing', 600, 'gpt-5.5', 'high', '', \(Int(now.timeIntervalSince1970)), \(Int(now.timeIntervalSince1970)), 0);
    """
])

let localStore = CodexUsageStore(
    codexDirectory: tempRoot,
    deltaDatabase: deltaDatabase,
    ripgrepCandidates: []
)
let localSnapshot = localStore.loadSnapshot(
    includePeriodUsage: false,
    bypassFastCache: true,
    rateLimitSource: .localFilesOnly,
    taskHistoryRange: .day,
    now: now
)
runner.check(localSnapshot.isRunning, "recent session rollout should mark local Codex as running")
runner.check(localSnapshot.monitorStats.jsonlContextScans == 0, "context metrics disabled should skip rollout context scans")
runner.check(
    localSnapshot.tasks.allSatisfy { $0.contextPercent == nil && $0.contextInputTokens == nil && $0.contextWindowTokens == nil },
    "context metrics disabled should leave task context fields empty"
)
runner.check(localSnapshot.usage1h == 2912, "aggregate 1 hour usage should sum parent-only recent delta snapshots")
runner.check(localSnapshot.tasks.first?.delta1hTokens != localSnapshot.usage1h, "aggregate 1 hour usage should not reuse the first visible task delta")
runner.check(localSnapshot.tasks.first { $0.id == sessionID }?.todayTokens == 12345, "session Today usage should use the parent-only 24 hour delta baseline")
runner.check(localSnapshot.tasks.first { $0.id == parentOnlySessionID }?.todayTokens == 20567, "parent-only session Today usage should use the parent-only 24 hour delta baseline")
runner.check(localSnapshot.tasks.first { $0.id == todayCreatedDeltaSessionID }?.todayTokens == 600, "today-created session without baseline should count from zero for Today usage")
runner.check(localSnapshot.tasks.first { $0.id == missingBaselineDeltaSessionID }?.todayTokens == nil, "missing natural-day baseline without created_at should hide session Today usage")
let pollutedDeltaTask = runner.require(
    localSnapshot.tasks.first { $0.id == pollutedDeltaParentSessionID },
    "polluted delta parent task should be visible"
)
runner.check(pollutedDeltaTask.tokenCount == 162000000, "parent task total should stay parent-only even when a subagent has tokens")
runner.check(pollutedDeltaTask.delta1hTokens == 0, "parent 1 hour delta should not include subagent token totals")
runner.check(pollutedDeltaTask.todayTokens == 0, "parent Today delta should not include subagent token totals")
runner.check(pollutedDeltaTask.todaySharePercent == 0, "zero Today delta should not clamp to a false 100 percent share")
runner.check(localSnapshot.primaryPercent == 67, "GPT-5.6 Sol local JSONL should expose the main Codex 5h quota")
runner.check(localSnapshot.secondaryPercent == 45, "GPT-5.6 Sol local JSONL should expose the main Codex 7d quota")
runner.check(localSnapshot.primaryResetsAt == codexPrimaryReset, "local JSONL Codex quota should expose primary reset time")
runner.check(localSnapshot.secondaryResetsAt == codexSecondaryReset, "local JSONL Codex quota should expose secondary reset time")
runner.check(localSnapshot.primaryWindowMinutes == 300, "local JSONL Codex quota should expose the primary window duration")
runner.check(localSnapshot.secondaryWindowMinutes == 10_080, "local JSONL Codex quota should expose the secondary window duration")
runner.check(localSnapshot.primaryPercent != 92, "subagent Codex quota should not override the main 5h quota")
runner.check(localSnapshot.sparkQuotaWindows.map(\.remainingPercent) == [60, 90], "local JSONL Spark quota windows should decode")
runner.check(localSnapshot.sparkQuotaWindows.allSatisfy { !$0.id.contains("luna") }, "unknown local model quota windows should not appear in Spark quota windows")
let localContextSnapshot = localStore.loadSnapshot(
    includePeriodUsage: false,
    bypassFastCache: true,
    rateLimitSource: .localFilesOnly,
    taskHistoryRange: .day,
    includeContextUsage: true,
    now: now
)
runner.check(localContextSnapshot.monitorStats.jsonlContextScans > 0, "context metrics enabled should scan visible rollout context")
let contextEnabledTask = runner.require(
    localContextSnapshot.tasks.first { $0.id == sessionID },
    "context-enabled session task should be visible"
)
runner.check(contextEnabledTask.contextInputTokens == 60000, "context metrics enabled should load input token context")
runner.check(contextEnabledTask.contextWindowTokens == 240000, "context metrics enabled should load context window")
runner.check(contextEnabledTask.contextPercent == 25, "context metrics enabled should compute context percent")
let localSnapshotJSON = try JSONSerialization.jsonObject(
    with: SnapshotOutputFormatter.jsonData(for: localSnapshot)
) as? [String: Any]
let localSnapshotSparkWindows = localSnapshotJSON?["spark_quota_windows"] as? [[String: Any]]
let localSnapshotCumulative = localSnapshotJSON?["cumulative_usage"] as? [String: Any]
let localSnapshotRecent = localSnapshotJSON?["recent_usage"] as? [String: Any]
runner.check(localSnapshotJSON?["primary_percent"] as? Int == 67, "compact JSON should expose main Codex 5h quota")
runner.check(localSnapshotJSON?["secondary_percent"] as? Int == 45, "compact JSON should expose main Codex 7d quota")
runner.check(localSnapshotSparkWindows?.compactMap { $0["remaining_percent"] as? Int } == [60, 90], "compact JSON should keep Spark quota separate")
runner.check(localSnapshotSparkWindows?.allSatisfy { !(($0["id"] as? String) ?? "").contains("luna") } == true, "compact JSON should not expose unknown model quota as Spark")
let staleSparkNow = Date(timeIntervalSince1970: 1_790_000_000)
let staleSparkRoot = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("CodexNotchStaleSpark-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: staleSparkRoot, withIntermediateDirectories: true)
defer {
    try? FileManager.default.removeItem(at: staleSparkRoot)
}
let staleSparkStateDatabase = staleSparkRoot.appendingPathComponent("state_5.sqlite").path
let staleSparkLogsDatabase = staleSparkRoot.appendingPathComponent("logs_2.sqlite").path
_ = try Shell.run("/usr/bin/sqlite3", [
    staleSparkStateDatabase,
    """
    create table threads(
      id text,
      title text,
      tokens_used integer,
      model text,
      reasoning_effort text,
      rollout_path text,
      created_at integer,
      updated_at integer,
      archived integer default 0
    );
    """
])
_ = try Shell.run("/usr/bin/sqlite3", [
    staleSparkLogsDatabase,
    """
    create table logs(
      thread_id text,
      ts integer,
      target text,
      feedback_log_body text
    );
    """
])
let staleSparkSessionDirectory = staleSparkRoot.appendingPathComponent("sessions/2026/06/14", isDirectory: true)
try FileManager.default.createDirectory(at: staleSparkSessionDirectory, withIntermediateDirectories: true)
let staleSparkSessionID = "019e073a-c032-74e2-966e-b85ede0c9cae"
let staleSparkPath = staleSparkSessionDirectory
    .appendingPathComponent("rollout-2026-06-14T02-20-17-\(staleSparkSessionID).jsonl")
let staleSparkTimestamp = ISO8601DateFormatter().string(from: staleSparkNow)
let staleSparkBody = """
{"timestamp":"\(staleSparkTimestamp)","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":0}},"rate_limits":{"limit_id":"codex_bengalfox","limit_name":"GPT-5.3-Codex-Spark","primary":{"resets_at":\(Int(staleSparkNow.timeIntervalSince1970) - 300)},"secondary":{"resets_at":\(Int(staleSparkNow.timeIntervalSince1970) - 300)}}}}
"""
try staleSparkBody.write(to: staleSparkPath, atomically: true, encoding: .utf8)
_ = try Shell.run("/usr/bin/sqlite3", [
    staleSparkStateDatabase,
    """
    insert into threads(id, title, tokens_used, model, reasoning_effort, rollout_path, updated_at, archived)
    values('\(staleSparkSessionID)', '过期 Spark 额度', 0, 'gpt-5.5', 'high', '\(staleSparkPath.path)', \(Int(staleSparkNow.timeIntervalSince1970)), 0);
    """
])
let staleSparkStore = CodexUsageStore(codexDirectory: staleSparkRoot)
let staleSparkSnapshot = staleSparkStore.loadSnapshot(
    includePeriodUsage: false,
    bypassFastCache: true,
    rateLimitSource: .localFilesOnly,
    taskHistoryRange: .day,
    now: staleSparkNow
)
runner.check(
    staleSparkSnapshot.sparkQuotaWindows.isEmpty,
    "expired Spark windows should not display fake 100%"
)
let expectedActiveCumulativeTokens = try Shell.sqliteJSON(
    database: stateDatabase,
    query: "select coalesce(sum(tokens_used), 0) as count from threads where archived = 0;",
    as: [CountRecord].self,
    readOnly: true
).first?.count ?? 0
let expectedArchivedCumulativeTokens = try Shell.sqliteJSON(
    database: stateDatabase,
    query: "select coalesce(sum(tokens_used), 0) as count from threads where archived = 1;",
    as: [CountRecord].self,
    readOnly: true
).first?.count ?? 0
let recentWindowStart = Int(now.timeIntervalSince1970) - (20 * 24 * 60 * 60)
let expectedRecentActiveTokens = try Shell.sqliteJSON(
    database: stateDatabase,
    query: "select coalesce(sum(tokens_used), 0) as count from threads where archived = 0 and updated_at >= \(recentWindowStart);",
    as: [CountRecord].self,
    readOnly: true
).first?.count ?? 0
let expectedRecentArchivedTokens = try Shell.sqliteJSON(
    database: stateDatabase,
    query: "select coalesce(sum(tokens_used), 0) as count from threads where archived = 1 and updated_at >= \(recentWindowStart);",
    as: [CountRecord].self,
    readOnly: true
).first?.count ?? 0
let expectedPeriodUsage24h = 55_734
let expectedPeriodUsage7d = 282_734
let expectedPeriodUsage30d = 282_734
runner.check(localSnapshot.cumulativeUsage.activeTokens == expectedActiveCumulativeTokens, "snapshot cumulative active tokens should match readonly state DB")
runner.check(localSnapshot.cumulativeUsage.archivedTokens == expectedArchivedCumulativeTokens, "snapshot cumulative archived tokens should match readonly state DB")
runner.check(localSnapshot.cumulativeUsage.allTokens == expectedActiveCumulativeTokens + expectedArchivedCumulativeTokens, "snapshot cumulative all tokens should equal active plus archived")
runner.check(localSnapshot.recentUsage.usage20dActiveTokens == expectedRecentActiveTokens, "snapshot recent 20d active tokens should match readonly state DB")
runner.check(localSnapshot.recentUsage.usage20dArchivedTokens == expectedRecentArchivedTokens, "snapshot recent 20d archived tokens should include archived sessions")
runner.check(localSnapshot.recentUsage.usage20dAllTokens == expectedRecentActiveTokens + expectedRecentArchivedTokens, "snapshot recent 20d all tokens should equal active plus archived")
runner.check(localSnapshot.recentUsage.usage20dAllTokens != localSnapshot.usage30d, "recent 20d all tokens should not reuse period usage30d")
runner.check(localSnapshotCumulative?["active_tokens"] as? Int == expectedActiveCumulativeTokens, "compact JSON should expose active cumulative tokens from state DB")
runner.check(localSnapshotCumulative?["archived_tokens"] as? Int == expectedArchivedCumulativeTokens, "compact JSON should expose archived cumulative tokens from state DB")
runner.check(localSnapshotRecent?["usage_20d_active_tokens"] as? Int == expectedRecentActiveTokens, "compact JSON should expose recent 20d active tokens")
runner.check(localSnapshotRecent?["usage_20d_archived_tokens"] as? Int == expectedRecentArchivedTokens, "compact JSON should expose recent 20d archived tokens")
runner.check(localSnapshotRecent?["usage_20d_all_tokens"] as? Int == expectedRecentActiveTokens + expectedRecentArchivedTokens, "compact JSON should expose recent 20d all tokens")

let periodArchivedRoot = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("CodexNotchPeriodArchived-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: periodArchivedRoot, withIntermediateDirectories: true)
defer {
    try? FileManager.default.removeItem(at: periodArchivedRoot)
}

let periodArchivedStateDatabase = periodArchivedRoot.appendingPathComponent("state_5.sqlite").path
let periodArchivedLogsDatabase = periodArchivedRoot.appendingPathComponent("logs_2.sqlite").path
let periodArchivedSessionsRoot = periodArchivedRoot.appendingPathComponent("sessions/2026/06/14", isDirectory: true)
try FileManager.default.createDirectory(at: periodArchivedSessionsRoot, withIntermediateDirectories: true)
_ = try Shell.run("/usr/bin/sqlite3", [
    periodArchivedStateDatabase,
    """
    create table threads(
      id text,
      title text,
      tokens_used integer,
      model text,
      reasoning_effort text,
      rollout_path text,
      created_at integer,
      updated_at integer,
      archived integer default 0
    );
    """
])
_ = try Shell.run("/usr/bin/sqlite3", [
    periodArchivedLogsDatabase,
    """
    create table logs(
      thread_id text,
      ts integer,
      target text,
      feedback_log_body text
    );
    """
])

let periodActiveSessionID = "019e073a-c032-74e2-966e-b85ede0c9ca1"
let periodArchivedSessionID = "019e073a-c032-74e2-966e-b85ede0c9ca2"
let periodWindowNow = now.timeIntervalSince1970
let periodActiveRollout = periodArchivedSessionsRoot
    .appendingPathComponent("rollout-2026-06-14T20-00-00-\(periodActiveSessionID).jsonl")
let periodArchivedRollout = periodArchivedSessionsRoot
    .appendingPathComponent("rollout-2026-06-14T20-00-01-\(periodArchivedSessionID).jsonl")
let periodActiveRolloutBody = """
{\"timestamp\":\"\(ISO8601DateFormatter().string(from: now))\",\"payload\":{\"type\":\"token_count\",\"info\":{\"last_token_usage\":{\"total_tokens\":111}}}}
"""
let periodArchivedRolloutBody = """
{\"timestamp\":\"\(ISO8601DateFormatter().string(from: now))\",\"payload\":{\"type\":\"token_count\",\"info\":{\"last_token_usage\":{\"total_tokens\":222}}}}
"""
try periodActiveRolloutBody.write(to: periodActiveRollout, atomically: true, encoding: .utf8)
try periodArchivedRolloutBody.write(to: periodArchivedRollout, atomically: true, encoding: .utf8)
try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: periodActiveRollout.path)
try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: periodArchivedRollout.path)

_ = try Shell.run("/usr/bin/sqlite3", [
    periodArchivedStateDatabase,
    """
    insert into threads(
      id, title, tokens_used, model, reasoning_effort, rollout_path, created_at, updated_at, archived
    )
    values
      ('\(periodActiveSessionID)', 'active session', 111, 'gpt-5.5', 'high', '\(periodActiveRollout.path)', 0, \(Int(periodWindowNow)), 0),
      ('\(periodArchivedSessionID)', 'archived session', 222, 'gpt-5.5', 'high', '\(periodArchivedRollout.path)', 0, \(Int(periodWindowNow)), 1);
    """
])
let periodArchivedDeltaDirectory = periodArchivedRoot.appendingPathComponent("context-guard", isDirectory: true)
try FileManager.default.createDirectory(at: periodArchivedDeltaDirectory, withIntermediateDirectories: true)
let periodArchivedDeltaDatabase = periodArchivedDeltaDirectory.appendingPathComponent("usage-deltas.sqlite").path
let periodObservedAtMs = Int64((now.timeIntervalSince1970 * 1_000).rounded())
let period25hBaselineMs = periodObservedAtMs - Int64(25 * 60 * 60 * 1_000)
let period8dBaselineMs = periodObservedAtMs - Int64(8 * 24 * 60 * 60 * 1_000)
let period31dBaselineMs = periodObservedAtMs - Int64(31 * 24 * 60 * 60 * 1_000)
_ = try Shell.run("/usr/bin/sqlite3", [
    periodArchivedDeltaDatabase,
    """
    create table token_snapshots (
      thread_id text primary key,
      tokens_used integer not null,
      updated_at_ms integer not null,
      observed_at_ms integer not null
    );
    create table token_snapshot_history (
      thread_id text not null,
      tokens_used integer not null,
      updated_at_ms integer not null,
      observed_at_ms integer not null,
      primary key(thread_id, observed_at_ms)
    );
    create index idx_token_snapshot_history_lookup
      on token_snapshot_history(thread_id, observed_at_ms desc);
    insert into token_snapshot_history(thread_id, tokens_used, updated_at_ms, observed_at_ms)
    values
      ('\(periodActiveSessionID)', 10, \(period25hBaselineMs), \(period25hBaselineMs)),
      ('\(periodArchivedSessionID)', 20, \(period25hBaselineMs), \(period25hBaselineMs)),
      ('\(periodActiveSessionID)', 5, \(period8dBaselineMs), \(period8dBaselineMs)),
      ('\(periodArchivedSessionID)', 15, \(period8dBaselineMs), \(period8dBaselineMs)),
      ('\(periodActiveSessionID)', 1, \(period31dBaselineMs), \(period31dBaselineMs)),
      ('\(periodArchivedSessionID)', 2, \(period31dBaselineMs), \(period31dBaselineMs));
    """
])

let periodArchivedStore = CodexUsageStore(codexDirectory: periodArchivedRoot)
let periodUsage = periodArchivedStore.loadUsageTotals(now: now)
let periodSnapshot = periodArchivedStore.loadSnapshot(
    includePeriodUsage: true,
    bypassFastCache: true,
    rateLimitSource: .localFilesOnly,
    taskHistoryRange: .day,
    now: now
)

let periodExpectedDay = (111 - 10) + (222 - 20)
let periodExpectedWeek = (111 - 5) + (222 - 15)
let periodExpectedMonth = (111 - 1) + (222 - 2)

let periodExpectedDayWithoutArchived = try Shell.sqliteJSON(
    database: periodArchivedStateDatabase,
    query: "select coalesce(sum(tokens_used), 0) as count from threads where archived = 0 and updated_at >= \(Int(periodWindowNow) - 24 * 60 * 60);",
    as: [CountRecord].self,
    readOnly: true
).first?.count ?? 0

runner.check(periodUsage?.day == periodExpectedDay, "period usage should include archived sessions in 24h rolling deltas")
runner.check(periodUsage?.week == periodExpectedWeek, "period usage should include archived sessions in 7d rolling deltas")
runner.check(periodUsage?.month == periodExpectedMonth, "period usage should include archived sessions in 30d rolling deltas")
runner.check(periodSnapshot.usage24h == periodExpectedDay, "snapshot period 24h usage should include archived rolling deltas")
runner.check(periodSnapshot.usage7d == periodExpectedWeek, "snapshot period 7d usage should include archived rolling deltas")
runner.check(periodSnapshot.usage30d == periodExpectedMonth, "snapshot period 30d usage should include archived rolling deltas")
runner.check(periodUsage?.day != periodExpectedDayWithoutArchived, "period usage 24h should not use active sessions only")

let appServerFirstStore = CodexUsageStore(
    codexDirectory: tempRoot,
    initialAppServerRateLimits: appServerSnapshot
)
let appServerFirstSnapshot = appServerFirstStore.loadSnapshot(
    includePeriodUsage: false,
    bypassFastCache: true,
    rateLimitSource: .appServerFirst,
    taskHistoryRange: .day,
    now: now
)
runner.check(appServerFirstSnapshot.primaryPercent == 83, "fresh app-server 5h quota should remain authoritative")
runner.check(appServerFirstSnapshot.secondaryPercent == 78, "fresh app-server 7d quota should remain authoritative")
runner.check(appServerFirstSnapshot.sparkQuotaWindows.map(\.remainingPercent) == [22, 58], "app-server-first should keep Spark quota in Spark windows")

let weeklyOnlyAppServerStore = CodexUsageStore(
    codexDirectory: tempRoot,
    initialAppServerRateLimits: weeklyOnlyAppServerSnapshot
)
let weeklyOnlyAppServerResult = weeklyOnlyAppServerStore.loadSnapshot(
    includePeriodUsage: false,
    bypassFastCache: true,
    rateLimitSource: .appServerFirst,
    taskHistoryRange: .day,
    now: now
)
runner.check(weeklyOnlyAppServerResult.primaryPercent == 100, "weekly-only app-server quota should remain authoritative")
runner.check(weeklyOnlyAppServerResult.primaryWindowMinutes == 10_080, "weekly-only app-server quota should retain weekly semantics")
runner.check(weeklyOnlyAppServerResult.secondaryPercent == nil, "weekly-only app-server quota should clear a stale local secondary window")

let weeklyTransitionRoot = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("CodexNotchWeeklyTransition-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: weeklyTransitionRoot, withIntermediateDirectories: true)
defer {
    try? FileManager.default.removeItem(at: weeklyTransitionRoot)
}
let weeklyTransitionStateDatabase = weeklyTransitionRoot.appendingPathComponent("state_5.sqlite").path
let weeklyTransitionLogsDatabase = weeklyTransitionRoot.appendingPathComponent("logs_2.sqlite").path
_ = try Shell.run("/usr/bin/sqlite3", [
    weeklyTransitionStateDatabase,
    """
    create table threads(
      id text,
      title text,
      tokens_used integer,
      model text,
      reasoning_effort text,
      rollout_path text,
      created_at integer,
      updated_at integer,
      archived integer default 0
    );
    """
])
_ = try Shell.run("/usr/bin/sqlite3", [
    weeklyTransitionLogsDatabase,
    """
    create table logs(
      thread_id text,
      ts integer,
      target text,
      feedback_log_body text
    );
    """
])
let weeklyTransitionSessionDirectory = weeklyTransitionRoot
    .appendingPathComponent("sessions/2026/07/13", isDirectory: true)
try FileManager.default.createDirectory(at: weeklyTransitionSessionDirectory, withIntermediateDirectories: true)
let legacyTransitionSessionID = "019f56de-19ba-7220-9ac7-b1fc2b6800f1"
let weeklyTransitionSessionID = "019f56de-19ba-7220-9ac7-b1fc2b6800f2"
let legacyTransitionPath = weeklyTransitionSessionDirectory
    .appendingPathComponent("rollout-legacy-\(legacyTransitionSessionID).jsonl")
let weeklyTransitionPath = weeklyTransitionSessionDirectory
    .appendingPathComponent("rollout-weekly-\(weeklyTransitionSessionID).jsonl")
let legacyTransitionTimestamp = ISO8601DateFormatter().string(from: now.addingTimeInterval(-5))
let weeklyTransitionTimestamp = ISO8601DateFormatter().string(from: now)
let legacyTransitionPrimaryReset = Int(now.timeIntervalSince1970) + 4 * 60 * 60
let legacyTransitionSecondaryReset = Int(now.timeIntervalSince1970) + 5 * 24 * 60 * 60
let weeklyTransitionReset = Int(now.timeIntervalSince1970) + 7 * 24 * 60 * 60
try """
{"timestamp":"\(legacyTransitionTimestamp)","type":"turn_context","payload":{"model":"gpt-5.6-sol","effort":"max"}}
{"timestamp":"\(legacyTransitionTimestamp)","type":"event_msg","payload":{"type":"token_count","rate_limits":{"limit_id":"codex","primary":{"used_percent":22,"window_minutes":300,"resets_at":\(legacyTransitionPrimaryReset)},"secondary":{"used_percent":64,"window_minutes":10080,"resets_at":\(legacyTransitionSecondaryReset)}}}}
"""
    .write(to: legacyTransitionPath, atomically: true, encoding: .utf8)
try """
{"timestamp":"\(weeklyTransitionTimestamp)","type":"turn_context","payload":{"model":"gpt-5.6-sol","effort":"max"}}
{"timestamp":"\(weeklyTransitionTimestamp)","type":"event_msg","payload":{"type":"token_count","rate_limits":{"limit_id":"codex","primary":{"used_percent":0,"window_minutes":10080,"resets_at":\(weeklyTransitionReset)},"secondary":null}}}
"""
    .write(to: weeklyTransitionPath, atomically: true, encoding: .utf8)
_ = try Shell.run("/usr/bin/sqlite3", [
    weeklyTransitionStateDatabase,
    """
    insert into threads(id, title, tokens_used, model, reasoning_effort, rollout_path, created_at, updated_at, archived)
    values
      ('\(legacyTransitionSessionID)', 'Legacy quota topology', 0, 'gpt-5.6-sol', 'max', '\(legacyTransitionPath.path)', \(Int(now.timeIntervalSince1970)), \(Int(now.timeIntervalSince1970)), 0),
      ('\(weeklyTransitionSessionID)', 'Weekly-only quota topology', 0, 'gpt-5.6-sol', 'max', '\(weeklyTransitionPath.path)', \(Int(now.timeIntervalSince1970)), \(Int(now.timeIntervalSince1970)), 0);
    """
])
let weeklyTransitionStore = CodexUsageStore(
    codexDirectory: weeklyTransitionRoot,
    stateDatabase: weeklyTransitionStateDatabase,
    logsDatabase: weeklyTransitionLogsDatabase,
    ripgrepCandidates: []
)
let weeklyTransitionSnapshot = weeklyTransitionStore.loadSnapshot(
    includePeriodUsage: false,
    bypassFastCache: true,
    rateLimitSource: .localFilesOnly,
    taskHistoryRange: .day,
    now: now
)
runner.check(weeklyTransitionSnapshot.primaryPercent == 100, "the newest weekly-only local topology should replace the legacy 5h window")
runner.check(weeklyTransitionSnapshot.primaryWindowMinutes == 10_080, "the local topology transition should retain weekly semantics")
runner.check(weeklyTransitionSnapshot.secondaryPercent == nil, "the local topology transition should drop the legacy 36 percent weekly value")

let appServerMoreConstrainedStore = CodexUsageStore(
    codexDirectory: tempRoot,
    initialAppServerRateLimits: RateLimitSnapshot(
        primaryPercent: 60,
        secondaryPercent: 44,
        primaryResetsAt: appServerPrimaryReset,
        secondaryResetsAt: appServerSecondaryReset,
        capturedAt: appServerFixtureNow,
        isPrimaryCodexLimit: true,
        sparkQuotaWindows: appServerSnapshot.sparkQuotaWindows
    )
)
let appServerMoreConstrainedSnapshot = appServerMoreConstrainedStore.loadSnapshot(
    includePeriodUsage: false,
    bypassFastCache: true,
    rateLimitSource: .appServerFirst,
    taskHistoryRange: .day,
    now: now
)
runner.check(appServerMoreConstrainedSnapshot.primaryPercent == 60, "app-server-first should keep app-server 5h quota when it is lower than local JSONL")
runner.check(appServerMoreConstrainedSnapshot.secondaryPercent == 44, "app-server-first should keep app-server 7d quota when it is lower than local JSONL")

let mixedQuotaGenerationRoot = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("CodexNotchMixedQuotaGeneration-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: mixedQuotaGenerationRoot, withIntermediateDirectories: true)
defer {
    try? FileManager.default.removeItem(at: mixedQuotaGenerationRoot)
}
let mixedQuotaStateDatabase = mixedQuotaGenerationRoot.appendingPathComponent("state_5.sqlite").path
let mixedQuotaLogsDatabase = mixedQuotaGenerationRoot.appendingPathComponent("logs_2.sqlite").path
_ = try Shell.run("/usr/bin/sqlite3", [
    mixedQuotaStateDatabase,
    """
    create table threads(
      id text,
      title text,
      tokens_used integer,
      model text,
      reasoning_effort text,
      rollout_path text,
      created_at integer,
      updated_at integer,
      archived integer default 0
    );
    """
])
_ = try Shell.run("/usr/bin/sqlite3", [
    mixedQuotaLogsDatabase,
    """
    create table logs(
      thread_id text,
      ts integer,
      target text,
      feedback_log_body text
    );
    """
])
let mixedQuotaSessionDirectory = mixedQuotaGenerationRoot
    .appendingPathComponent("sessions/2026/07/10", isDirectory: true)
try FileManager.default.createDirectory(at: mixedQuotaSessionDirectory, withIntermediateDirectories: true)

let staleGenerationSessionID = "019f48cd-4e2c-7ce2-a31e-d7da44b4fbce"
let currentGenerationSessionID = "019f48df-1f66-7011-8d08-2bc819d84ec7"
let staleGenerationPath = mixedQuotaSessionDirectory
    .appendingPathComponent("rollout-stale-\(staleGenerationSessionID).jsonl")
let currentGenerationPath = mixedQuotaSessionDirectory
    .appendingPathComponent("rollout-current-\(currentGenerationSessionID).jsonl")
let staleGenerationTimestamp = ISO8601DateFormatter().string(from: now)
let currentGenerationTimestamp = ISO8601DateFormatter().string(from: now.addingTimeInterval(-2))
let staleGenerationPrimaryReset = Int(now.timeIntervalSince1970) + 3 * 60 * 60
let staleGenerationSecondaryReset = Int(now.timeIntervalSince1970) + 5 * 24 * 60 * 60
let currentGenerationPrimaryReset = Int(now.timeIntervalSince1970) + 5 * 60 * 60
let currentGenerationSecondaryReset = Int(now.timeIntervalSince1970) + 7 * 24 * 60 * 60

try """
{"timestamp":"\(staleGenerationTimestamp)","type":"turn_context","payload":{"model":"gpt-5.6-sol","effort":"ultra"}}
{"timestamp":"\(staleGenerationTimestamp)","type":"event_msg","payload":{"type":"token_count","rate_limits":{"limit_id":"codex","primary":{"used_percent":21,"resets_at":\(staleGenerationPrimaryReset)},"secondary":{"used_percent":15,"resets_at":\(staleGenerationSecondaryReset)}}}}
"""
    .write(to: staleGenerationPath, atomically: true, encoding: .utf8)
try """
{"timestamp":"\(currentGenerationTimestamp)","type":"turn_context","payload":{"model":"gpt-5.6-sol","effort":"ultra"}}
{"timestamp":"\(currentGenerationTimestamp)","type":"event_msg","payload":{"type":"token_count","rate_limits":{"limit_id":"codex","primary":{"used_percent":6,"resets_at":\(currentGenerationPrimaryReset)},"secondary":{"used_percent":1,"resets_at":\(currentGenerationSecondaryReset)}}}}
"""
    .write(to: currentGenerationPath, atomically: true, encoding: .utf8)
_ = try Shell.run("/usr/bin/sqlite3", [
    mixedQuotaStateDatabase,
    """
    insert into threads(id, title, tokens_used, model, reasoning_effort, rollout_path, created_at, updated_at, archived)
    values
      ('\(staleGenerationSessionID)', 'Stale quota generation', 0, 'gpt-5.6-sol', 'ultra', '\(staleGenerationPath.path)', \(Int(now.timeIntervalSince1970)), \(Int(now.timeIntervalSince1970)), 0),
      ('\(currentGenerationSessionID)', 'Current quota generation', 0, 'gpt-5.6-sol', 'ultra', '\(currentGenerationPath.path)', \(Int(now.timeIntervalSince1970)), \(Int(now.timeIntervalSince1970)), 0);
    """
])

let mixedQuotaLocalStore = CodexUsageStore(
    codexDirectory: mixedQuotaGenerationRoot,
    stateDatabase: mixedQuotaStateDatabase,
    logsDatabase: mixedQuotaLogsDatabase,
    ripgrepCandidates: []
)
let mixedQuotaLocalSnapshot = mixedQuotaLocalStore.loadSnapshot(
    includePeriodUsage: false,
    bypassFastCache: true,
    rateLimitSource: .localFilesOnly,
    taskHistoryRange: .day,
    now: now
)
runner.check(mixedQuotaLocalSnapshot.primaryPercent == 79, "tied local 5h cohorts should keep the earlier stable generation")
runner.check(mixedQuotaLocalSnapshot.secondaryPercent == 85, "tied local 7d cohorts should keep the earlier stable generation")
runner.check(mixedQuotaLocalSnapshot.primaryResetsAt == staleGenerationPrimaryReset, "tied local 5h cohorts should not jump to a later reset")
runner.check(mixedQuotaLocalSnapshot.secondaryResetsAt == staleGenerationSecondaryReset, "tied local 7d cohorts should not jump to a later reset")

let futureCohortSessionID = "019f48d7-c4fe-7da0-8e71-762f34b2a133"
let futureCohortPath = mixedQuotaSessionDirectory
    .appendingPathComponent("rollout-future-cohort-\(futureCohortSessionID).jsonl")
let futureCohortPrimaryReset = currentGenerationPrimaryReset + 8 * 60
let futureCohortSecondaryReset = currentGenerationSecondaryReset + 8 * 60
try """
{"timestamp":"\(staleGenerationTimestamp)","type":"turn_context","payload":{"model":"gpt-5.6-sol","effort":"ultra"}}
{"timestamp":"\(staleGenerationTimestamp)","type":"event_msg","payload":{"type":"token_count","rate_limits":{"limit_id":"codex","primary":{"used_percent":1,"resets_at":\(futureCohortPrimaryReset)},"secondary":{"used_percent":0,"resets_at":\(futureCohortSecondaryReset)}}}}
"""
    .write(to: futureCohortPath, atomically: true, encoding: .utf8)
_ = try Shell.run("/usr/bin/sqlite3", [
    mixedQuotaStateDatabase,
    """
    insert into threads(id, title, tokens_used, model, reasoning_effort, rollout_path, created_at, updated_at, archived)
    values ('\(futureCohortSessionID)', 'Alternative quota cohort', 0, 'gpt-5.6-sol', 'ultra', '\(futureCohortPath.path)', \(Int(now.timeIntervalSince1970)), \(Int(now.timeIntervalSince1970)), 0);
    """
])

let futureConflictDiagnostics = MonitorDiagnostics(
    logURL: mixedQuotaGenerationRoot.appendingPathComponent("future-conflict-diagnostics.jsonl")
)
let futureConflictAppServerStore = CodexUsageStore(
    codexDirectory: mixedQuotaGenerationRoot,
    stateDatabase: mixedQuotaStateDatabase,
    logsDatabase: mixedQuotaLogsDatabase,
    ripgrepCandidates: [],
    initialAppServerRateLimits: RateLimitSnapshot(
        primaryPercent: 54,
        secondaryPercent: 93,
        primaryResetsAt: currentGenerationPrimaryReset,
        secondaryResetsAt: currentGenerationSecondaryReset,
        capturedAt: now,
        isPrimaryCodexLimit: true
    ),
    diagnostics: futureConflictDiagnostics
)
let futureConflictAppServerSnapshot = futureConflictAppServerStore.loadSnapshot(
    includePeriodUsage: false,
    bypassFastCache: true,
    rateLimitSource: .appServerFirst,
    taskHistoryRange: .day,
    now: now
)
runner.check(futureConflictAppServerSnapshot.primaryPercent == 54, "a future local cohort must not replace the official active 5h window")
runner.check(futureConflictAppServerSnapshot.secondaryPercent == 93, "a future local cohort must not replace the official active 7d window")
runner.check(futureConflictAppServerSnapshot.primaryResetsAt == currentGenerationPrimaryReset, "future 5h conflicts should retain the official reset")
runner.check(futureConflictAppServerSnapshot.secondaryResetsAt == currentGenerationSecondaryReset, "future 7d conflicts should retain the official reset")
let futureConflictDiagnostic = futureConflictDiagnostics.recentData(limit: 20)
    .split(separator: 0x0A, omittingEmptySubsequences: true)
    .compactMap { line in
        try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any]
    }
    .last
runner.check(futureConflictDiagnostic?["primary_decision"] as? String == "app_server_fresh", "diagnostics should explain authoritative future 5h data")
runner.check(futureConflictDiagnostic?["secondary_decision"] as? String == "app_server_fresh", "diagnostics should explain authoritative future 7d data")

let supportingCurrentSessionIDs = [
    "019f48f4-5db6-7a31-b8ce-d05673d1af15",
    "019f48f9-8381-7d12-81dc-0a83a19935f7"
]
for (index, sessionID) in supportingCurrentSessionIDs.enumerated() {
    let path = mixedQuotaSessionDirectory
        .appendingPathComponent("rollout-current-support-\(sessionID).jsonl")
    let timestamp = ISO8601DateFormatter().string(from: now.addingTimeInterval(TimeInterval(-3 - index)))
    try """
    {"timestamp":"\(timestamp)","type":"turn_context","payload":{"model":"gpt-5.6-sol","effort":"ultra"}}
    {"timestamp":"\(timestamp)","type":"event_msg","payload":{"type":"token_count","rate_limits":{"limit_id":"codex","primary":{"used_percent":6,"resets_at":\(currentGenerationPrimaryReset)},"secondary":{"used_percent":1,"resets_at":\(currentGenerationSecondaryReset)}}}}
    """
        .write(to: path, atomically: true, encoding: .utf8)
    _ = try Shell.run("/usr/bin/sqlite3", [
        mixedQuotaStateDatabase,
        """
        insert into threads(id, title, tokens_used, model, reasoning_effort, rollout_path, created_at, updated_at, archived)
        values ('\(sessionID)', 'Current cohort support', 0, 'gpt-5.6-sol', 'ultra', '\(path.path)', \(Int(now.timeIntervalSince1970)), \(Int(now.timeIntervalSince1970)), 0);
        """
    ])
}

let majorityLocalDiagnostics = MonitorDiagnostics(
    logURL: mixedQuotaGenerationRoot.appendingPathComponent("majority-local-diagnostics.jsonl")
)
let majorityLocalStore = CodexUsageStore(
    codexDirectory: mixedQuotaGenerationRoot,
    stateDatabase: mixedQuotaStateDatabase,
    logsDatabase: mixedQuotaLogsDatabase,
    ripgrepCandidates: [],
    diagnostics: majorityLocalDiagnostics
)
let majorityLocalSnapshot = majorityLocalStore.loadSnapshot(
    includePeriodUsage: false,
    bypassFastCache: true,
    rateLimitSource: .localFilesOnly,
    taskHistoryRange: .day,
    now: now
)
runner.check(majorityLocalSnapshot.primaryPercent == 94, "the majority local cohort should retain the official 5h generation")
runner.check(majorityLocalSnapshot.secondaryPercent == 99, "the majority local cohort should retain the official 7d generation")
let majorityLocalDiagnostic = majorityLocalDiagnostics.recentData(limit: 20)
    .split(separator: 0x0A, omittingEmptySubsequences: true)
    .compactMap { line in
        try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any]
    }
    .last
runner.check(majorityLocalDiagnostic?["local_selection_reason"] as? String == "majority_future_generation", "diagnostics should explain majority local cohort selection")
runner.check(majorityLocalDiagnostic?["local_selected_generation_support"] as? Int == 3, "diagnostics should report selected local cohort support")

let sameGenerationAppServerStore = CodexUsageStore(
    codexDirectory: mixedQuotaGenerationRoot,
    stateDatabase: mixedQuotaStateDatabase,
    logsDatabase: mixedQuotaLogsDatabase,
    ripgrepCandidates: [],
    initialAppServerRateLimits: RateLimitSnapshot(
        primaryPercent: 100,
        secondaryPercent: 100,
        primaryResetsAt: currentGenerationPrimaryReset,
        secondaryResetsAt: currentGenerationSecondaryReset,
        capturedAt: now,
        isPrimaryCodexLimit: true
    )
)
let sameGenerationAppServerSnapshot = sameGenerationAppServerStore.loadSnapshot(
    includePeriodUsage: false,
    bypassFastCache: true,
    rateLimitSource: .appServerFirst,
    taskHistoryRange: .day,
    now: now
)
runner.check(sameGenerationAppServerSnapshot.primaryPercent == 100, "fresh app-server 5h quota should not be lowered by local JSONL")
runner.check(sameGenerationAppServerSnapshot.secondaryPercent == 100, "fresh app-server 7d quota should not be lowered by local JSONL")

let expiredAppServerPrimaryReset = Int(now.timeIntervalSince1970) - 60
let expiredAppServerSecondaryReset = Int(now.timeIntervalSince1970) - 60
let expiredGenerationAppServerStore = CodexUsageStore(
    codexDirectory: mixedQuotaGenerationRoot,
    stateDatabase: mixedQuotaStateDatabase,
    logsDatabase: mixedQuotaLogsDatabase,
    ripgrepCandidates: [],
    initialAppServerRateLimits: RateLimitSnapshot(
        primaryPercent: 0,
        secondaryPercent: 66,
        primaryResetsAt: expiredAppServerPrimaryReset,
        secondaryResetsAt: expiredAppServerSecondaryReset,
        capturedAt: now,
        isPrimaryCodexLimit: true
    )
)
let expiredGenerationAppServerSnapshot = expiredGenerationAppServerStore.loadSnapshot(
    includePeriodUsage: false,
    bypassFastCache: true,
    rateLimitSource: .appServerFirst,
    taskHistoryRange: .day,
    now: now
)
runner.check(expiredGenerationAppServerSnapshot.primaryPercent == 0, "a protected official 5h value should survive its reset boundary")
runner.check(expiredGenerationAppServerSnapshot.secondaryPercent == 66, "a protected official 7d value should remain authoritative")
runner.check(expiredGenerationAppServerSnapshot.primaryResetsAt == expiredAppServerPrimaryReset, "protected official 5h data should retain its confirmed reset")
runner.check(expiredGenerationAppServerSnapshot.secondaryResetsAt == expiredAppServerSecondaryReset, "protected official 7d data should retain its confirmed reset")

let partiallyExpiredAppServerStore = CodexUsageStore(
    codexDirectory: mixedQuotaGenerationRoot,
    stateDatabase: mixedQuotaStateDatabase,
    logsDatabase: mixedQuotaLogsDatabase,
    ripgrepCandidates: [],
    initialAppServerRateLimits: RateLimitSnapshot(
        primaryPercent: 0,
        secondaryPercent: 75,
        primaryResetsAt: expiredAppServerPrimaryReset,
        secondaryResetsAt: currentGenerationSecondaryReset,
        capturedAt: now,
        isPrimaryCodexLimit: true
    )
)
let partiallyExpiredAppServerSnapshot = partiallyExpiredAppServerStore.loadSnapshot(
    includePeriodUsage: false,
    bypassFastCache: true,
    rateLimitSource: .appServerFirst,
    taskHistoryRange: .day,
    now: now
)
runner.check(partiallyExpiredAppServerSnapshot.primaryPercent == 0, "an expired official 5h value should remain protected until a new official response")
runner.check(partiallyExpiredAppServerSnapshot.secondaryPercent == 75, "active official 7d data should remain authoritative")
runner.check(partiallyExpiredAppServerSnapshot.primaryResetsAt == expiredAppServerPrimaryReset, "protected 5h should retain the official reset")
runner.check(partiallyExpiredAppServerSnapshot.secondaryResetsAt == currentGenerationSecondaryReset, "official 7d should retain its reset")

let newerAppServerPrimaryReset = currentGenerationPrimaryReset + 10 * 60
let newerAppServerSecondaryReset = currentGenerationSecondaryReset + 10 * 60
let mixedQuotaDiagnostics = MonitorDiagnostics(
    logURL: mixedQuotaGenerationRoot.appendingPathComponent("quota-diagnostics.jsonl")
)
let newerGenerationAppServerStore = CodexUsageStore(
    codexDirectory: mixedQuotaGenerationRoot,
    stateDatabase: mixedQuotaStateDatabase,
    logsDatabase: mixedQuotaLogsDatabase,
    ripgrepCandidates: [],
    initialAppServerRateLimits: RateLimitSnapshot(
        primaryPercent: 100,
        secondaryPercent: 100,
        primaryResetsAt: newerAppServerPrimaryReset,
        secondaryResetsAt: newerAppServerSecondaryReset,
        capturedAt: now,
        isPrimaryCodexLimit: true
    ),
    diagnostics: mixedQuotaDiagnostics
)
let newerGenerationAppServerSnapshot = newerGenerationAppServerStore.loadSnapshot(
    includePeriodUsage: false,
    bypassFastCache: true,
    rateLimitSource: .appServerFirst,
    taskHistoryRange: .day,
    now: now
)
runner.check(newerGenerationAppServerSnapshot.primaryPercent == 100, "fresh app-server 5h quota should override conflicting local consensus")
runner.check(newerGenerationAppServerSnapshot.secondaryPercent == 100, "fresh app-server 7d quota should override conflicting local consensus")
runner.check(newerGenerationAppServerSnapshot.primaryResetsAt == newerAppServerPrimaryReset, "fresh app-server 5h reset should remain authoritative")
runner.check(newerGenerationAppServerSnapshot.secondaryResetsAt == newerAppServerSecondaryReset, "fresh app-server 7d reset should remain authoritative")
let mixedQuotaDiagnosticObjects = mixedQuotaDiagnostics.recentData(limit: 20)
    .split(separator: 0x0A, omittingEmptySubsequences: true)
    .compactMap { line in
        try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any]
    }
let mixedQuotaDiagnostic = mixedQuotaDiagnosticObjects.last
runner.check(mixedQuotaDiagnostic?["primary_decision"] as? String == "app_server_fresh", "quota diagnostics should explain the authoritative 5h decision")
runner.check(mixedQuotaDiagnostic?["secondary_decision"] as? String == "app_server_fresh", "quota diagnostics should explain the authoritative 7d decision")
runner.check(mixedQuotaDiagnostic?["local_generation_count"] as? Int == 3, "quota diagnostics should report conflicting local generations")
runner.check(mixedQuotaDiagnostic?["local_recent_generation_count"] as? Int == 3, "quota diagnostics should report recent conflicting local generations")
runner.check(mixedQuotaDiagnostic?["local_selected_generation_support"] as? Int == 3, "quota diagnostics should report selected local generation support")
runner.check(mixedQuotaDiagnostic?["local_consensus_minimum_support"] as? Int == 2, "quota diagnostics should report the local consensus threshold")
runner.check(mixedQuotaDiagnostic?["result_primary_percent"] as? Int == 100, "quota diagnostics should report the published 5h value")
let mixedQuotaDiagnosticText = String(data: mixedQuotaDiagnostics.recentData(limit: 20), encoding: .utf8) ?? ""
runner.check(!mixedQuotaDiagnosticText.contains(staleGenerationPath.path), "quota diagnostics must not include rollout paths")
runner.check(!mixedQuotaDiagnosticText.contains("Stale quota generation"), "quota diagnostics must not include task titles")

let appServerCacheRoot = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("CodexNotchAppServerCache-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: appServerCacheRoot, withIntermediateDirectories: true)
defer {
    try? FileManager.default.removeItem(at: appServerCacheRoot)
}
let persistedAppServerCacheURL = appServerCacheRoot.appendingPathComponent("app-server-rate-limits.json")
let authoritativeSnapshot = RateLimitSnapshot(
    primaryPercent: 47,
    secondaryPercent: 75,
    primaryResetsAt: Int(now.timeIntervalSince1970) + 4 * 60 * 60,
    secondaryResetsAt: Int(now.timeIntervalSince1970) + 6 * 24 * 60 * 60,
    capturedAt: now,
    isPrimaryCodexLimit: true
)
let recoveredSnapshot = RateLimitSnapshot(
    primaryPercent: 39,
    secondaryPercent: 73,
    primaryResetsAt: authoritativeSnapshot.primaryResetsAt,
    secondaryResetsAt: authoritativeSnapshot.secondaryResetsAt,
    capturedAt: now.addingTimeInterval(815),
    isPrimaryCodexLimit: true
)
let exhaustedSnapshot = RateLimitSnapshot(
    primaryPercent: 0,
    secondaryPercent: 66,
    primaryResetsAt: Int(now.timeIntervalSince1970) + 4 * 60 * 60,
    secondaryResetsAt: Int(now.timeIntervalSince1970) + 6 * 24 * 60 * 60,
    capturedAt: now,
    isPrimaryCodexLimit: true
)
let anomalousReboundSnapshot = RateLimitSnapshot(
    primaryPercent: 99,
    secondaryPercent: 100,
    primaryResetsAt: exhaustedSnapshot.primaryResetsAt.map { $0 + 217 },
    secondaryResetsAt: exhaustedSnapshot.secondaryResetsAt.map { $0 + 480 },
    capturedAt: now.addingTimeInterval(301),
    isPrimaryCodexLimit: true
)
let reboundLoader = AppServerLoaderSequence([
    .success(anomalousReboundSnapshot),
    .success(exhaustedSnapshot)
])
let reboundDiagnostics = MonitorDiagnostics(
    logURL: appServerCacheRoot.appendingPathComponent("rebound-diagnostics.jsonl")
)
let reboundStore = CodexUsageStore(
    codexDirectory: tempRoot,
    appServerRateLimitLoader: reboundLoader.load,
    appServerCacheURL: nil,
    initialAppServerRateLimits: exhaustedSnapshot,
    diagnostics: reboundDiagnostics
)
let reboundAt = now.addingTimeInterval(301)
runner.check(
    !reboundStore.refreshAppServerRateLimits(now: reboundAt),
    "a single large app-server rebound should be staged instead of published"
)
let stagedReboundSnapshot = reboundStore.loadSnapshot(
    includePeriodUsage: false,
    bypassFastCache: true,
    rateLimitSource: .appServerFirst,
    taskHistoryRange: .day,
    now: reboundAt
)
runner.check(stagedReboundSnapshot.primaryPercent == 0, "a staged app-server rebound must not replace the confirmed 5h value")
runner.check(stagedReboundSnapshot.secondaryPercent == 66, "a staged app-server rebound must not replace the confirmed 7d value")
runner.check(reboundStore.appServerRefreshDelay(now: reboundAt) == 30, "a staged rebound should be rechecked after 30 seconds")
let reboundRecoveryAt = reboundAt.addingTimeInterval(31)
runner.check(
    reboundStore.refreshAppServerRateLimits(now: reboundRecoveryAt),
    "a normal app-server response should clear a staged rebound"
)
let recoveredFromReboundSnapshot = reboundStore.loadSnapshot(
    includePeriodUsage: false,
    bypassFastCache: true,
    rateLimitSource: .appServerFirst,
    taskHistoryRange: .day,
    now: reboundRecoveryAt
)
runner.check(recoveredFromReboundSnapshot.primaryPercent == 0, "rebound recovery should preserve the real 5h value")
runner.check(recoveredFromReboundSnapshot.secondaryPercent == 66, "rebound recovery should preserve the real 7d value")
let reboundDiagnosticText = String(data: reboundDiagnostics.recentData(limit: 20), encoding: .utf8) ?? ""
runner.check(reboundDiagnosticText.contains(#""outcome":"staged_rebound""#), "diagnostics should identify a staged app-server rebound")

let confirmedResetSnapshot = RateLimitSnapshot(
    primaryPercent: 98,
    secondaryPercent: 66,
    primaryResetsAt: exhaustedSnapshot.primaryResetsAt.map { $0 + 5 * 60 * 60 },
    secondaryResetsAt: exhaustedSnapshot.secondaryResetsAt,
    capturedAt: reboundAt,
    isPrimaryCodexLimit: true
)
let confirmedResetFollowUp = RateLimitSnapshot(
    primaryPercent: 97,
    secondaryPercent: 66,
    primaryResetsAt: confirmedResetSnapshot.primaryResetsAt.map { $0 + 1 },
    secondaryResetsAt: confirmedResetSnapshot.secondaryResetsAt.map { $0 - 1 },
    capturedAt: reboundRecoveryAt,
    isPrimaryCodexLimit: true
)
let confirmedResetLoader = AppServerLoaderSequence([
    .success(confirmedResetSnapshot),
    .success(confirmedResetFollowUp)
])
let confirmedResetStore = CodexUsageStore(
    codexDirectory: tempRoot,
    appServerRateLimitLoader: confirmedResetLoader.load,
    appServerCacheURL: nil,
    initialAppServerRateLimits: exhaustedSnapshot
)
runner.check(
    !confirmedResetStore.refreshAppServerRateLimits(now: reboundAt),
    "the first response for a real reset should wait for confirmation"
)
runner.check(
    confirmedResetStore.refreshAppServerRateLimits(now: reboundRecoveryAt),
    "a second response from the same reset generation should confirm the rebound"
)
let acceptedResetSnapshot = confirmedResetStore.loadSnapshot(
    includePeriodUsage: false,
    bypassFastCache: true,
    rateLimitSource: .appServerFirst,
    taskHistoryRange: .day,
    now: reboundRecoveryAt
)
runner.check(acceptedResetSnapshot.primaryPercent == 97, "a confirmed reset should publish the latest official 5h value")
runner.check(acceptedResetSnapshot.secondaryPercent == 66, "a confirmed reset should preserve the unaffected 7d value")
runner.check(acceptedResetSnapshot.primaryResetsAt == confirmedResetFollowUp.primaryResetsAt, "a confirmed reset should publish the latest reset timestamp")

let persistenceLoader = AppServerLoaderSequence([.success(authoritativeSnapshot)])
let persistenceDiagnostics = MonitorDiagnostics(
    logURL: appServerCacheRoot.appendingPathComponent("persistence-diagnostics.jsonl")
)
let persistenceStore = CodexUsageStore(
    codexDirectory: tempRoot,
    appServerRateLimitLoader: persistenceLoader.load,
    appServerCacheURL: persistedAppServerCacheURL,
    diagnostics: persistenceDiagnostics
)
runner.check(
    persistenceStore.refreshAppServerRateLimits(now: now, force: true),
    "successful app-server refresh should report success"
)
runner.check(FileManager.default.fileExists(atPath: persistedAppServerCacheURL.path), "successful app-server refresh should persist last-known-good quota")
runner.check(
    !persistenceStore.refreshAppServerRateLimits(now: now.addingTimeInterval(10)),
    "presentation refresh should reuse a fresh app-server cache"
)
runner.check(persistenceLoader.attempts.count == 1, "presentation refresh should not start a second app-server process")
let appServerCachePermissions = (try? FileManager.default.attributesOfItem(atPath: persistedAppServerCacheURL.path)[.posixPermissions] as? NSNumber)?.intValue
let appServerCacheDirectoryPermissions = (try? FileManager.default.attributesOfItem(atPath: appServerCacheRoot.path)[.posixPermissions] as? NSNumber)?.intValue
runner.check(appServerCachePermissions == 0o600, "persisted app-server quota should be current-user-only")
runner.check(appServerCacheDirectoryPermissions == 0o700, "app-server quota cache directory should be current-user-only")

let retryLoader = AppServerLoaderSequence([
    .failure,
    .failure,
    .failure,
    .failure,
    .success(recoveredSnapshot)
])
let retryDiagnostics = MonitorDiagnostics(
    logURL: appServerCacheRoot.appendingPathComponent("retry-diagnostics.jsonl")
)
let restoredStore = CodexUsageStore(
    codexDirectory: tempRoot,
    appServerRateLimitLoader: retryLoader.load,
    appServerCacheURL: persistedAppServerCacheURL,
    diagnostics: retryDiagnostics
)
let firstFailureAt = now.addingTimeInterval(301)
runner.check(
    !restoredStore.refreshAppServerRateLimits(now: firstFailureAt),
    "failed app-server refresh should report failure"
)
runner.check(restoredStore.appServerRefreshDelay(now: firstFailureAt) == 30, "first app-server failure should retry after 30 seconds")
let staleOfficialSnapshot = restoredStore.loadSnapshot(
    includePeriodUsage: false,
    bypassFastCache: true,
    rateLimitSource: .appServerFirst,
    taskHistoryRange: .day,
    now: firstFailureAt
)
runner.check(staleOfficialSnapshot.primaryPercent == 47, "last-known-good 5h quota should survive a transient refresh failure")
runner.check(staleOfficialSnapshot.secondaryPercent == 75, "last-known-good 7d quota should survive a transient refresh failure")
runner.check(staleOfficialSnapshot.monitorStats.lastRateLimitSource == "app-server-stale", "stale official quota should expose a distinct source")

let deferredRetryAt = firstFailureAt.addingTimeInterval(10)
runner.check(
    !restoredStore.refreshAppServerRateLimits(now: deferredRetryAt),
    "refresh inside the retry backoff should be deferred"
)
runner.check(retryLoader.attempts.count == 1, "retry backoff should not start another app-server process")

let secondFailureAt = firstFailureAt.addingTimeInterval(31)
runner.check(!restoredStore.refreshAppServerRateLimits(now: secondFailureAt), "second app-server refresh should fail deterministically")
runner.check(restoredStore.appServerRefreshDelay(now: secondFailureAt) == 60, "second app-server failure should retry after 60 seconds")
let thirdFailureAt = secondFailureAt.addingTimeInterval(61)
runner.check(!restoredStore.refreshAppServerRateLimits(now: thirdFailureAt), "third app-server refresh should fail deterministically")
runner.check(restoredStore.appServerRefreshDelay(now: thirdFailureAt) == 120, "third app-server failure should retry after 120 seconds")
let fourthFailureAt = thirdFailureAt.addingTimeInterval(121)
runner.check(!restoredStore.refreshAppServerRateLimits(now: fourthFailureAt), "fourth app-server refresh should fail deterministically")
runner.check(restoredStore.appServerRefreshDelay(now: fourthFailureAt) == 300, "fourth app-server failure should cap retry delay at 300 seconds")
let recoveryAt = fourthFailureAt.addingTimeInterval(301)
runner.check(restoredStore.refreshAppServerRateLimits(now: recoveryAt), "app-server refresh should recover after backoff")
let recoveredOfficialSnapshot = restoredStore.loadSnapshot(
    includePeriodUsage: false,
    bypassFastCache: true,
    rateLimitSource: .appServerFirst,
    taskHistoryRange: .day,
    now: recoveryAt
)
runner.check(recoveredOfficialSnapshot.primaryPercent == 39, "recovered app-server 5h quota should replace last-known-good")
runner.check(recoveredOfficialSnapshot.secondaryPercent == 73, "recovered app-server 7d quota should replace last-known-good")
runner.check(recoveredOfficialSnapshot.monitorStats.lastRateLimitSource == "app-server-fresh", "recovered official quota should expose a fresh source")

let expiredGraceStore = CodexUsageStore(
    codexDirectory: tempRoot,
    appServerRateLimitLoader: AppServerLoaderSequence([.failure]).load,
    appServerCacheURL: persistedAppServerCacheURL
)
let afterGraceSnapshot = expiredGraceStore.loadSnapshot(
    includePeriodUsage: false,
    bypassFastCache: true,
    rateLimitSource: .appServerFirst,
    taskHistoryRange: .day,
    now: recoveryAt.addingTimeInterval(16 * 60)
)
runner.check(afterGraceSnapshot.primaryPercent == 67, "local 5h quota should take over after the official grace window")
runner.check(afterGraceSnapshot.secondaryPercent == 45, "local 7d quota should take over after the official grace window")
runner.check(afterGraceSnapshot.monitorStats.lastRateLimitSource == "local-jsonl", "expired official grace should expose local fallback source")

let retryDiagnosticText = String(data: retryDiagnostics.recentData(limit: 50), encoding: .utf8) ?? ""
runner.check(retryDiagnosticText.contains(#""event":"app_server_refresh""#), "diagnostics should record app-server refresh attempts")
runner.check(retryDiagnosticText.contains(#""outcome":"failure""#), "diagnostics should record app-server refresh failures")
runner.check(!retryDiagnosticText.contains(tempRoot.path), "app-server diagnostics must not include local paths")

let expiredLocalQuotaRoot = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("CodexNotchExpiredLocalQuota-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: expiredLocalQuotaRoot, withIntermediateDirectories: true)
defer {
    try? FileManager.default.removeItem(at: expiredLocalQuotaRoot)
}
let expiredLocalQuotaStateDatabase = expiredLocalQuotaRoot.appendingPathComponent("state_5.sqlite").path
let expiredLocalQuotaLogsDatabase = expiredLocalQuotaRoot.appendingPathComponent("logs_2.sqlite").path
_ = try Shell.run("/usr/bin/sqlite3", [
    expiredLocalQuotaStateDatabase,
    """
    create table threads(
      id text,
      title text,
      tokens_used integer,
      model text,
      reasoning_effort text,
      rollout_path text,
      created_at integer,
      updated_at integer,
      archived integer default 0
    );
    """
])
_ = try Shell.run("/usr/bin/sqlite3", [
    expiredLocalQuotaLogsDatabase,
    """
    create table logs(
      thread_id text,
      ts integer,
      target text,
      feedback_log_body text
    );
    """
])
let expiredLocalQuotaDirectory = expiredLocalQuotaRoot.appendingPathComponent("sessions/2026/06/14", isDirectory: true)
try FileManager.default.createDirectory(at: expiredLocalQuotaDirectory, withIntermediateDirectories: true)
let expiredLocalQuotaSessionID = "019e073a-c032-74e2-966e-b85ede0c9cd9"
let expiredLocalQuotaPath = expiredLocalQuotaDirectory.appendingPathComponent("rollout-2026-06-14T02-20-20-\(expiredLocalQuotaSessionID).jsonl")
let expiredPrimaryReset = Int(now.timeIntervalSince1970) + 4 * 60 * 60
let expiredSecondaryReset = Int(now.timeIntervalSince1970) + 6 * 24 * 60 * 60
try """
{"timestamp":"\(timestamp)","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Expired local quota"}]}}
{"timestamp":"\(timestamp)","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":0}},"rate_limits":{"limit_id":"codex","primary":{"used_percent":0,"resets_at":\(expiredPrimaryReset)},"secondary":{"used_percent":34,"resets_at":\(expiredSecondaryReset)}}}}
"""
    .write(to: expiredLocalQuotaPath, atomically: true, encoding: .utf8)
try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: expiredLocalQuotaPath.path)
_ = try Shell.run("/usr/bin/sqlite3", [
    expiredLocalQuotaStateDatabase,
    """
    insert into threads(id, title, tokens_used, model, reasoning_effort, rollout_path, created_at, updated_at, archived)
    values('\(expiredLocalQuotaSessionID)', 'Expired local quota', 0, 'gpt-5.5', 'high', '\(expiredLocalQuotaPath.path)', \(Int(now.timeIntervalSince1970)), \(Int(now.timeIntervalSince1970)), 0);
    """
])
let resetAppServerSnapshot = RateLimitSnapshot(
    primaryPercent: 0,
    secondaryPercent: 66,
    primaryResetsAt: Int(now.timeIntervalSince1970) - 60,
    secondaryResetsAt: expiredSecondaryReset,
    capturedAt: now,
    isPrimaryCodexLimit: true
)
let expiredLocalQuotaStore = CodexUsageStore(
    codexDirectory: expiredLocalQuotaRoot,
    ripgrepCandidates: [],
    initialAppServerRateLimits: resetAppServerSnapshot
)
let expiredLocalQuotaSnapshot = expiredLocalQuotaStore.loadSnapshot(
    includePeriodUsage: false,
    bypassFastCache: true,
    rateLimitSource: .appServerFirst,
    taskHistoryRange: .day,
    now: now
)
runner.check(expiredLocalQuotaSnapshot.primaryPercent == 0, "a local 100 percent sample must not replace a protected official 0 percent value")
runner.check(expiredLocalQuotaSnapshot.primaryResetsAt == resetAppServerSnapshot.primaryResetsAt, "a local future reset must not replace the protected official 5h reset")
runner.check(expiredLocalQuotaSnapshot.secondaryPercent == 66, "the protected official 7d value should remain unchanged")
runner.check(expiredLocalQuotaSnapshot.secondaryResetsAt == resetAppServerSnapshot.secondaryResetsAt, "the official 7d reset should remain unchanged")
runner.check(localSnapshot.tasks.contains { $0.id == sessionID && $0.status == .running }, "recent session rollout should appear in running task list")
runner.check(localSnapshot.tasks.first { $0.id == sessionID }?.title == "正在运行的 Codex 任务", "session rollout should use the user message as task title")
runner.check(localSnapshot.tasks.first { $0.id == sessionID }?.detail.contains("gpt-5.6-sol · 极致推理") == true, "GPT-5.6 Sol session rollout should localize the ultra effort")
runner.check(!localSnapshot.tasks.contains { $0.id == subagentSessionID }, "subagent rollout should not appear as a separate local task")
runner.check(!localSnapshot.tasks.contains { $0.id == parentOnlySubagentID }, "subagent-only activity should still hide the child task")
runner.check(!localSnapshot.tasks.contains { $0.id == longMetaSubagentID }, "subagent rollout with long session metadata should still hide the child task")
runner.check(localSnapshot.tasks.contains { $0.id == parentOnlySessionID && $0.status == .running }, "recent subagent activity should mark the parent task running")
runner.check(localSnapshot.tasks.contains { $0.id == longMetaParentSessionID && $0.status == .running }, "long session metadata subagent activity should mark the parent task running")
runner.check(localSnapshot.tasks.first { $0.id == parentOnlySessionID }?.detail.contains("gpt-5.5 · 高推理") == true, "parent running through subagent activity should use turn context model and effort")
runner.check(localSnapshot.tasks.first { $0.id == sessionID }?.activeSubagentCount == 1, "parent task should only show currently active subagents")
runner.check(localSnapshot.tasks.first { $0.id == parentOnlySessionID }?.activeSubagentCount == 1, "parent running through subagent activity should show one subagent")
runner.check(localSnapshot.tasks.first { $0.id == longMetaParentSessionID }?.activeSubagentCount == 1, "parent running through long metadata subagent activity should show one subagent")
runner.check(localSnapshot.tasks.contains { $0.id == staleParentSessionID && $0.status == .running }, "active subagent should synthesize a running parent task even when the parent is outside the task range")
runner.check(localSnapshot.tasks.first { $0.id == sessionID }?.tokenCount == 102345, "parent task token count should stay parent-only")
runner.check(localSnapshot.tasks.first { $0.id == parentOnlySessionID }?.tokenCount == 34567, "parent running through subagent activity should keep parent-only token usage")
runner.check(localSnapshot.tasks.first { $0.id == longMetaParentSessionID }?.tokenCount == 22222, "parent running through long metadata subagent activity should keep parent-only token usage")
runner.check(localSnapshot.tasks.first { $0.id == staleDBTokenSessionID }?.tokenCount == 120000000, "recent task token count should prefer fresher rollout totals over stale database tokens")
runner.check(localSnapshot.tasks.contains { $0.id == activeToolCallSessionID && $0.status == .running }, "quiet tool calls should keep the running indicator on until a task-level completion event arrives")
runner.check(localSnapshot.tasks.first { $0.id == completedSessionID }?.status == .recent, "fresh completed session rollout should not be treated as running")
runner.check(localSnapshot.tasks.first { $0.id == completedFinalAnswerSessionID }?.status == .recent, "fresh final_answer/task_complete rollout should not be treated as running")
runner.check(localSnapshot.tasks.first { $0.id == dbBackedSessionID }?.tokenCount == 777, "recent rollout fallback should reuse database tokens even when the database updated_at is outside the task range")
let localWatchPaths = Set(localStore.rateLimitWatchPaths())
let normalizedSessionDirectory = sessionDirectory.resolvingSymlinksInPath().path
let normalizedRolloutPath = rolloutPath.resolvingSymlinksInPath().path
runner.check(localWatchPaths.contains(normalizedSessionDirectory), "local file watchers should include recent session directories so new subagents trigger refreshes")
runner.check(localWatchPaths.contains(normalizedRolloutPath), "local file watchers should keep watching recent session files for active task updates")

let mixedUsageRoot = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("CodexNotchMixedUsage-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: mixedUsageRoot, withIntermediateDirectories: true)
defer {
    try? FileManager.default.removeItem(at: mixedUsageRoot)
}
let mixedUsageStateDatabase = mixedUsageRoot.appendingPathComponent("state_5.sqlite").path
let mixedUsageLogsDatabase = mixedUsageRoot.appendingPathComponent("logs_2.sqlite").path
_ = try Shell.run("/usr/bin/sqlite3", [
    mixedUsageStateDatabase,
    """
    create table threads(
      id text,
      title text,
      tokens_used integer,
      model text,
      reasoning_effort text,
      rollout_path text,
      created_at integer,
      updated_at integer,
      archived integer default 0
    );
    """
])
_ = try Shell.run("/usr/bin/sqlite3", [
    mixedUsageLogsDatabase,
    """
    create table logs(
      thread_id text,
      ts integer,
      target text,
      feedback_log_body text
    );
    """
])
let mixedUsageDirectory = mixedUsageRoot.appendingPathComponent("sessions/2026/06/14", isDirectory: true)
try FileManager.default.createDirectory(at: mixedUsageDirectory, withIntermediateDirectories: true)
let mixedUsageSessionID = "019e073a-c032-74e2-966e-b85ede0c9cd5"
let mixedUsagePath = mixedUsageDirectory.appendingPathComponent("rollout-2026-06-14T02-20-15-\(mixedUsageSessionID).jsonl")
try #"{"timestamp":"\#(timestamp)","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":100}}}}"#
    .write(to: mixedUsagePath, atomically: true, encoding: .utf8)
try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: mixedUsagePath.path)
_ = try Shell.run("/usr/bin/sqlite3", [
    mixedUsageStateDatabase,
    """
    insert into threads(id, title, tokens_used, model, reasoning_effort, rollout_path, created_at, updated_at, archived)
    values('\(mixedUsageSessionID)', '状态数据库仅记录', 999, 'gpt-5.5', 'high', '\(mixedUsagePath.path)', \(Int(now.timeIntervalSince1970)), \(Int(now.timeIntervalSince1970)), 0);
    """
])
_ = try Shell.run("/usr/bin/sqlite3", [
    mixedUsageLogsDatabase,
    """
    insert into logs(thread_id, ts, target, feedback_log_body)
    values('\(mixedUsageSessionID)', \(Int(now.timeIntervalSince1970)), 'codex_otel.trace_safe', 'event.kind=response.completed tool_token_count=10000');
    """
])
let mixedUsageStore = CodexUsageStore(codexDirectory: mixedUsageRoot, ripgrepCandidates: [])
runner.check(mixedUsageStore.loadUsageTotals(now: now)?.day == 999, "new-thread period usage should use state current totals even when rollout/log tokens differ")

let logCacheRoot = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("CodexNotchLogCache-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: logCacheRoot, withIntermediateDirectories: true)
defer {
    try? FileManager.default.removeItem(at: logCacheRoot)
}
let logCacheStateDatabase = logCacheRoot.appendingPathComponent("state_5.sqlite").path
let logCacheLogsDatabase = logCacheRoot.appendingPathComponent("logs_2.sqlite").path
_ = try Shell.run("/usr/bin/sqlite3", [
    logCacheStateDatabase,
    """
    create table threads(
      id text,
      title text,
      tokens_used integer,
      model text,
      reasoning_effort text,
      rollout_path text,
      created_at integer,
      updated_at integer,
      archived integer default 0
    );
    """
])
_ = try Shell.run("/usr/bin/sqlite3", [
    logCacheLogsDatabase,
    """
    create table logs(
      thread_id text,
      ts integer,
      target text,
      feedback_log_body text
    );
    """
])
let logCacheDirectory = logCacheRoot.appendingPathComponent("sessions/2026/06/14", isDirectory: true)
try FileManager.default.createDirectory(at: logCacheDirectory, withIntermediateDirectories: true)
let logCacheSessionID = "019e073a-c032-74e2-966e-b85ede0c9cd6"
let logCachePath = logCacheDirectory.appendingPathComponent("rollout-2026-06-14T02-20-16-\(logCacheSessionID).jsonl")
try #"{"timestamp":"\#(timestamp)","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"仅日志统计"}]}}"#
    .write(to: logCachePath, atomically: true, encoding: .utf8)
try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: logCachePath.path)
_ = try Shell.run("/usr/bin/sqlite3", [
    logCacheStateDatabase,
    """
    insert into threads(id, title, tokens_used, model, reasoning_effort, rollout_path, created_at, updated_at, archived)
    values('\(logCacheSessionID)', '日志与 state 对照', 1000, 'gpt-5.5', 'high', '\(logCachePath.path)', \(Int(now.timeIntervalSince1970)), \(Int(now.timeIntervalSince1970)), 0);
    """
])
_ = try Shell.run("/usr/bin/sqlite3", [
    logCacheLogsDatabase,
    """
    insert into logs(thread_id, ts, target, feedback_log_body)
    values('\(logCacheSessionID)', \(Int(now.timeIntervalSince1970)), 'codex_otel.trace_safe', 'event.kind=response.completed tool_token_count=1000');
    """
])
let logCacheStore = CodexUsageStore(codexDirectory: logCacheRoot, ripgrepCandidates: [])
runner.check(logCacheStore.loadUsageTotals(now: now)?.day == 1000, "new-thread state totals should remain dominant when rollout/log data differs")
_ = try Shell.run("/usr/bin/sqlite3", [
    logCacheLogsDatabase,
    """
    insert into logs(thread_id, ts, target, feedback_log_body)
    values('\(logCacheSessionID)', \(Int(now.timeIntervalSince1970) + 1), 'codex_otel.trace_safe', 'event.kind=response.completed tool_token_count=2000');
    """
])
runner.check(logCacheStore.loadUsageTotals(now: now.addingTimeInterval(1))?.day == 1000, "new-thread state totals should be stable even when logs database changes")

let dbBackedActivityRoot = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("CodexNotchDBBackedActivity-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: dbBackedActivityRoot, withIntermediateDirectories: true)
defer {
    try? FileManager.default.removeItem(at: dbBackedActivityRoot)
}
let dbBackedActivityStateDatabase = dbBackedActivityRoot.appendingPathComponent("state_5.sqlite").path
let dbBackedActivityLogsDatabase = dbBackedActivityRoot.appendingPathComponent("logs_2.sqlite").path
_ = try Shell.run("/usr/bin/sqlite3", [
    dbBackedActivityStateDatabase,
    """
    create table threads(
      id text,
      title text,
      tokens_used integer,
      model text,
      reasoning_effort text,
      rollout_path text,
      created_at integer,
      updated_at integer,
      archived integer default 0
    );
    """
])
_ = try Shell.run("/usr/bin/sqlite3", [
    dbBackedActivityLogsDatabase,
    """
    create table logs(
      thread_id text,
      ts integer,
      target text,
      feedback_log_body text
    );
    """
])
let dbBackedActivityDirectory = dbBackedActivityRoot.appendingPathComponent("external-rollouts", isDirectory: true)
try FileManager.default.createDirectory(at: dbBackedActivityDirectory, withIntermediateDirectories: true)
let dbBackedActiveSessionID = "019e073a-c032-74e2-966e-b85ede0c9cd7"
let dbBackedCompletedSessionID = "019e073a-c032-74e2-966e-b85ede0c9cd8"
let dbBackedActivePath = dbBackedActivityDirectory.appendingPathComponent("active-\(dbBackedActiveSessionID).jsonl")
let dbBackedCompletedPath = dbBackedActivityDirectory.appendingPathComponent("completed-\(dbBackedCompletedSessionID).jsonl")
try #"{"timestamp":"\#(timestamp)","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"DB backed active"}]}}"#
    .write(to: dbBackedActivePath, atomically: true, encoding: .utf8)
try """
{"timestamp":"\(timestamp)","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"DB backed completed"}]}}
{"timestamp":"\(timestamp)","payload":{"phase":"final_answer","type":"task_complete"}}
"""
    .write(to: dbBackedCompletedPath, atomically: true, encoding: .utf8)
try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: dbBackedActivePath.path)
try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: dbBackedCompletedPath.path)
_ = try Shell.run("/usr/bin/sqlite3", [
    dbBackedActivityStateDatabase,
    """
    insert into threads(id, title, tokens_used, model, reasoning_effort, rollout_path, created_at, updated_at, archived)
    values
      ('\(dbBackedActiveSessionID)', 'DB backed active fallback', 1200, 'gpt-5.5', 'high', '\(dbBackedActivePath.path)', \(Int(now.timeIntervalSince1970)), \(Int(now.timeIntervalSince1970)), 0),
      ('\(dbBackedCompletedSessionID)', 'DB backed completed fallback', 2200, 'gpt-5.5', 'high', '\(dbBackedCompletedPath.path)', \(Int(now.timeIntervalSince1970)), \(Int(now.timeIntervalSince1970)), 0);
    """
])
let dbBackedActivityStore = CodexUsageStore(codexDirectory: dbBackedActivityRoot, ripgrepCandidates: [])
let dbBackedActivitySnapshot = dbBackedActivityStore.loadSnapshot(
    includePeriodUsage: false,
    bypassFastCache: true,
    rateLimitSource: .localFilesOnly,
    taskHistoryRange: .day,
    now: now
)
runner.check(dbBackedActivitySnapshot.isRunning, "db-backed rollout activity should keep local Codex running when logs active rows are missing")
runner.check(
    dbBackedActivitySnapshot.tasks.first { $0.id == dbBackedActiveSessionID }?.status == .running,
    "db-backed active rollout should appear as a running task without logs activity"
)
runner.check(
    dbBackedActivitySnapshot.tasks.first { $0.id == dbBackedCompletedSessionID }?.status == .recent,
    "db-backed completed rollout should not be treated as running without logs activity"
)

let cachedLocalSnapshot = localStore.loadSnapshot(
    includePeriodUsage: false,
    bypassFastCache: false,
    rateLimitSource: .localFilesOnly,
    taskHistoryRange: .day,
    now: now
)
runner.check(cachedLocalSnapshot.tasks.contains { $0.id == parentOnlySessionID && $0.status == .running }, "fast snapshot cache should preserve active parent task ids")
runner.check(cachedLocalSnapshot.tasks.first { $0.id == parentOnlySessionID }?.activeSubagentCount == 1, "fast snapshot cache should preserve active subagent counts")
runner.checkEqual(localStore.loadUsageTotals(now: now)?.day, expectedPeriodUsage24h, "24h local usage should use parent rolling delta baselines")
runner.checkEqual(localStore.loadUsageTotals(now: now)?.week, expectedPeriodUsage7d, "7d local usage should include new parent sessions without inflating unknown baselines")
runner.checkEqual(localStore.loadUsageTotals(now: now)?.month, expectedPeriodUsage30d, "30d local usage should include new parent sessions without inflating unknown baselines")
runner.checkEqual(localStore.loadUsageTotals(now: now.addingTimeInterval(1))?.day, expectedPeriodUsage24h, "unchanged local rolling usage totals should remain stable across refreshes")
let localExportSnapshot = localStore.loadSnapshot(
    includePeriodUsage: true,
    bypassFastCache: true,
    rateLimitSource: .localFilesOnly,
    taskHistoryRange: .day,
    now: now
)
runner.checkEqual(localExportSnapshot.usage24h, expectedPeriodUsage24h, "export snapshots should expose 24h rolling delta usage")
runner.checkEqual(localExportSnapshot.usage7d, expectedPeriodUsage7d, "export snapshots should expose 7d rolling delta usage")
runner.checkEqual(localExportSnapshot.usage30d, expectedPeriodUsage30d, "export snapshots should expose 30d rolling delta usage")
let localExportSnapshotJSON = try JSONSerialization.jsonObject(
    with: SnapshotOutputFormatter.jsonData(for: localExportSnapshot)
) as? [String: Any]
runner.checkEqual(localExportSnapshotJSON?["usage_24h"] as? Int, expectedPeriodUsage24h, "compact JSON should expose rolling delta usage_24h")
runner.checkEqual(localExportSnapshotJSON?["usage_7d"] as? Int, expectedPeriodUsage7d, "compact JSON should expose rolling delta usage_7d")
runner.checkEqual(localExportSnapshotJSON?["usage_30d"] as? Int, expectedPeriodUsage30d, "compact JSON should expose rolling delta usage_30d")

let defaultDeltaPath = CodexUsageStore.defaultDeltaDatabasePath(
    for: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
)
runner.check(
    defaultDeltaPath.contains("Application Support/CodexNotch/usage-deltas.sqlite"),
    "default user delta cache should live in CodexNotch Application Support"
)

let stateMtimeBeforeDeltaRecord = try FileManager.default.attributesOfItem(atPath: stateDatabase)[.modificationDate] as? Date
let logsMtimeBeforeDeltaRecord = try FileManager.default.attributesOfItem(atPath: logsDatabase)[.modificationDate] as? Date
runner.check(localStore.recordDeltaSnapshot(now: now.addingTimeInterval(2), range: .day), "Swift should record delta snapshots into its own cache")
let stateMtimeAfterDeltaRecord = try FileManager.default.attributesOfItem(atPath: stateDatabase)[.modificationDate] as? Date
let logsMtimeAfterDeltaRecord = try FileManager.default.attributesOfItem(atPath: logsDatabase)[.modificationDate] as? Date
runner.check(stateMtimeBeforeDeltaRecord == stateMtimeAfterDeltaRecord, "recording Swift deltas should not modify the Codex state database")
runner.check(logsMtimeBeforeDeltaRecord == logsMtimeAfterDeltaRecord, "recording Swift deltas should not modify the Codex logs database")

let localDeltaRows = try Shell.sqliteJSON(
    database: deltaDatabase,
    query: "select count(*) as count from token_snapshot_history;",
    as: [CountRecord].self,
    readOnly: true
).first?.count ?? 0
runner.check(localDeltaRows > 0, "Swift delta cache should keep token snapshot history")
let pollutedDeltaRows = try Shell.sqliteJSON(
    database: deltaDatabase,
    query: "select count(*) as count from token_snapshot_history where thread_id = '\(pollutedDeltaParentSessionID)' and tokens_used > 162000000;",
    as: [CountRecord].self,
    readOnly: true
).first?.count ?? -1
runner.check(pollutedDeltaRows == 0, "Swift delta cache should prune parent rows polluted by merged subagent token totals")
let compactedDuplicateRows = try Shell.sqliteJSON(
    database: deltaDatabase,
    query: "select count(*) as count from token_snapshot_history where thread_id = '\(pollutedDeltaParentSessionID)' and tokens_used = 162000000;",
    as: [CountRecord].self,
    readOnly: true
).first?.count ?? -1
runner.check(compactedDuplicateRows == 1, "delta cache upgrade should compact consecutive equal token history without changing rolling metrics")
let historyRowsBeforeUnchangedRecord = try Shell.sqliteJSON(
    database: deltaDatabase,
    query: "select count(*) as count from token_snapshot_history;",
    as: [CountRecord].self,
    readOnly: true
).first?.count ?? -1
runner.check(localStore.recordDeltaSnapshot(now: now.addingTimeInterval(3), range: .day), "unchanged Swift delta recording should succeed")
let historyRowsAfterUnchangedRecord = try Shell.sqliteJSON(
    database: deltaDatabase,
    query: "select count(*) as count from token_snapshot_history;",
    as: [CountRecord].self,
    readOnly: true
).first?.count ?? -1
runner.check(
    historyRowsAfterUnchangedRecord == historyRowsBeforeUnchangedRecord,
    "unchanged Swift delta recording should not append duplicate history rows"
)
let observedAtIndexCount = try Shell.sqliteJSON(
    database: deltaDatabase,
    query: "select count(*) as count from sqlite_master where type = 'index' and name = 'idx_token_snapshot_history_observed_at';",
    as: [CountRecord].self,
    readOnly: true
).first?.count ?? 0
runner.check(observedAtIndexCount == 1, "delta history retention should have a standalone observed_at_ms index")
let deltaMetadataTableCount = try Shell.sqliteJSON(
    database: deltaDatabase,
    query: "select count(*) as count from sqlite_master where type = 'table' and name = 'delta_cache_metadata';",
    as: [CountRecord].self,
    readOnly: true
).first?.count ?? 0
runner.check(deltaMetadataTableCount == 1, "delta cache should persist upgrade and maintenance metadata")
let expiredMaintenanceThreadID = "delta-maintenance-expired"
let expiredMaintenanceObservedMs = observedNowMs - Int64(32 * 24 * 60 * 60 * 1_000)
_ = try Shell.run("/usr/bin/sqlite3", [
    deltaDatabase,
    "insert into token_snapshot_history(thread_id, tokens_used, updated_at_ms, observed_at_ms) values('\(expiredMaintenanceThreadID)', 1, \(expiredMaintenanceObservedMs), \(expiredMaintenanceObservedMs));"
])
runner.check(
    localStore.recordDeltaSnapshot(now: now.addingTimeInterval(60 * 60), range: .month),
    "delta recording inside the maintenance interval should succeed"
)
let expiredRowsBeforeDailyPrune = try Shell.sqliteJSON(
    database: deltaDatabase,
    query: "select count(*) as count from token_snapshot_history where thread_id = '\(expiredMaintenanceThreadID)';",
    as: [CountRecord].self,
    readOnly: true
).first?.count ?? -1
runner.check(expiredRowsBeforeDailyPrune == 1, "retention cleanup should not rescan history more than once per day")
runner.check(
    localStore.recordDeltaSnapshot(now: now.addingTimeInterval(25 * 60 * 60), range: .month),
    "delta recording after the maintenance interval should succeed"
)
let expiredRowsAfterDailyPrune = try Shell.sqliteJSON(
    database: deltaDatabase,
    query: "select count(*) as count from token_snapshot_history where thread_id = '\(expiredMaintenanceThreadID)';",
    as: [CountRecord].self,
    readOnly: true
).first?.count ?? -1
runner.check(expiredRowsAfterDailyPrune == 0, "retention cleanup should prune expired history after one day")

let nodeCompatibleData = SnapshotOutputFormatter.nodeCompatibleJSONData(
    for: localExportSnapshot,
    options: NodeCompatibleSnapshotOptions(
        includeArchived: false,
        taskLimit: 8,
        tailBytes: 5 * 1024 * 1024,
        logScanLimit: 200_000,
        remoteEnabled: false,
        codexDirectory: tempRoot,
        stateDatabase: stateDatabase,
        logsDatabase: logsDatabase,
        deltaDatabase: deltaDatabase
    )
)
let nodeCompatibleObject = try JSONSerialization.jsonObject(with: nodeCompatibleData) as? [String: Any]
let nodeCompatibleCumulative = nodeCompatibleObject?["cumulativeUsage"] as? [String: Any]
let nodeCompatibleRecent = nodeCompatibleObject?["recentUsage"] as? [String: Any]
let nodeCompatibleDaily = nodeCompatibleObject?["dailyUsage"] as? [String: Any]
let nodeCompatiblePeriod = nodeCompatibleObject?["periodUsage"] as? [String: Any]
let nodeCompatibleRateLimits = nodeCompatibleObject?["rateLimits"] as? [String: Any]
let nodeCompatibleSparkWindows = nodeCompatibleObject?["sparkQuotaWindows"] as? [[String: Any]]
let nodeCompatiblePrimary = nodeCompatibleRateLimits?["primary"] as? [String: Any]
let nodeCompatibleSecondary = nodeCompatibleRateLimits?["secondary"] as? [String: Any]
let nodeCompatibleActive = nodeCompatibleObject?["active"] as? [String: Any]
let nodeCompatibleTasks = nodeCompatibleObject?["tasks"] as? [[String: Any]]
runner.check(nodeCompatibleObject?["generatedAt"] as? String != nil, "node-compatible JSON should include generatedAt")
runner.check(nodeCompatibleCumulative?["activeTokens"] as? Int == expectedActiveCumulativeTokens, "node-compatible JSON should expose active cumulative tokens")
runner.check(nodeCompatibleCumulative?["metricId"] as? String == "cumulative.active_tokens", "node-compatible JSON should identify the default cumulative metric")
runner.check(nodeCompatibleRecent?["usage20dActiveTokens"] as? Int == expectedRecentActiveTokens, "node-compatible JSON should expose recent 20d active tokens")
runner.check(nodeCompatibleRecent?["usage20dArchivedTokens"] as? Int == expectedRecentArchivedTokens, "node-compatible JSON should expose recent 20d archived tokens")
runner.check(nodeCompatibleRecent?["usage20dAllTokens"] as? Int == expectedRecentActiveTokens + expectedRecentArchivedTokens, "node-compatible JSON should expose recent 20d all tokens")
runner.check(nodeCompatibleRecent?["metricId"] as? String == "recent.usage_20d_all_tokens", "node-compatible JSON should identify recent 20d all metric")
runner.check(nodeCompatibleDaily?["usageTodayTokens"] as? Int == localExportSnapshot.dailyUsage.usageTodayTokens, "node-compatible JSON should expose natural-day usage")
runner.check(nodeCompatibleDaily?["metricId"] as? String == "daily.usage_today_tokens", "node-compatible JSON should identify natural-day usage metric")
runner.checkEqual(nodeCompatiblePeriod?["usage24h"] as? Int, expectedPeriodUsage24h, "node-compatible JSON should expose rolling delta periodUsage usage24h")
runner.checkEqual(nodeCompatiblePeriod?["usage7d"] as? Int, expectedPeriodUsage7d, "node-compatible JSON should expose rolling delta periodUsage usage7d")
runner.checkEqual(nodeCompatiblePeriod?["usage30d"] as? Int, expectedPeriodUsage30d, "node-compatible JSON should expose rolling delta periodUsage usage30d")
runner.check(nodeCompatiblePeriod?["usage30d"] as? Int != nil && nodeCompatibleRecent?["usage20dAllTokens"] as? Int != nil, "periodUsage should remain available alongside recent 20d usage")
runner.check(nodeCompatibleRateLimits?["limitId"] as? String == "codex", "node-compatible JSON should identify the main quota as codex")
runner.check(nodeCompatibleRateLimits?["ok"] as? Bool == true, "node-compatible JSON should mark main quota as available")
runner.check(nodeCompatibleSparkWindows?.compactMap { $0["label"] as? String } == ["5h", "7d"], "node-compatible JSON should expose Spark labels")
runner.check(nodeCompatibleSparkWindows?.compactMap { $0["remaining_percent"] as? Int } == [60, 90], "node-compatible JSON should expose Spark remaining percent values")
runner.check(nodeCompatiblePrimary?["remainingPercent"] as? Int == 67, "node-compatible JSON should expose main Codex 5h quota")
runner.check(nodeCompatiblePrimary?["usedPercent"] as? Int == 33, "node-compatible JSON should not expose Spark 5h as primary")
runner.check(nodeCompatiblePrimary?["resetsAt"] as? Int == codexPrimaryReset, "node-compatible JSON should expose main Codex 5h reset")
runner.check(nodeCompatibleSecondary?["remainingPercent"] as? Int == 45, "node-compatible JSON should expose main Codex 7d quota")
runner.check(nodeCompatibleSecondary?["usedPercent"] as? Int == 55, "node-compatible JSON should not expose Spark 7d as secondary")
runner.check(nodeCompatibleSecondary?["resetsAt"] as? Int == codexSecondaryReset, "node-compatible JSON should expose main Codex 7d reset")
runner.check(nodeCompatibleActive?["runningTasks"] as? Int != nil, "node-compatible JSON should expose active runningTasks")
runner.check(nodeCompatibleTasks?.first?["tokensUsed"] as? Int != nil, "node-compatible JSON tasks should expose tokensUsed")

let recentPriorityRoot = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("CodexNotchRecentPriority-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: recentPriorityRoot, withIntermediateDirectories: true)
defer {
    try? FileManager.default.removeItem(at: recentPriorityRoot)
}
let recentPriorityStateDatabase = recentPriorityRoot.appendingPathComponent("state_5.sqlite").path
let recentPriorityLogsDatabase = recentPriorityRoot.appendingPathComponent("logs_2.sqlite").path
let recentStart = Int(now.timeIntervalSince1970) - (20 * 24 * 60 * 60)
let oldTimestamp = recentStart - 10
let nowTimestamp = Int(now.timeIntervalSince1970)
_ = try Shell.run("/usr/bin/sqlite3", [
    recentPriorityStateDatabase,
    """
    create table threads(
      id text,
      title text,
      tokens_used integer,
      model text,
      reasoning_effort text,
      rollout_path text,
      created_at integer,
      updated_at integer,
      recency_at integer,
      archived integer default 0
    );
    insert into threads(id, title, tokens_used, model, reasoning_effort, rollout_path, created_at, updated_at, recency_at, archived)
    values
      ('recent-active-recency', 'Recent active by recency', 100, 'gpt-5.5', 'high', '', \(oldTimestamp), \(oldTimestamp), \(nowTimestamp), 0),
      ('recent-archived-recency', 'Recent archived by recency', 200, 'gpt-5.5', 'high', '', \(oldTimestamp), \(oldTimestamp), \(nowTimestamp), 1),
      ('recent-created-fallback', 'Recent created fallback', 400, 'gpt-5.5', 'high', '', \(nowTimestamp), 0, 0, 0),
      ('old-recency-wins', 'Old recency wins over updated', 800, 'gpt-5.5', 'high', '', \(nowTimestamp), \(nowTimestamp), \(oldTimestamp), 0);
    """
])
_ = try Shell.run("/usr/bin/sqlite3", [
    recentPriorityLogsDatabase,
    """
    create table logs(
      thread_id text,
      ts integer,
      target text,
      feedback_log_body text
    );
    """
])
let recentPriorityStore = CodexUsageStore(codexDirectory: recentPriorityRoot)
let recentPrioritySnapshot = recentPriorityStore.loadSnapshot(
    includePeriodUsage: true,
    bypassFastCache: true,
    rateLimitSource: .localFilesOnly,
    taskHistoryRange: .day,
    now: now
)
runner.check(recentPrioritySnapshot.recentUsage.usage20dActiveTokens == 500, "recent 20d active usage should use recency_at first and created_at as fallback")
runner.check(recentPrioritySnapshot.recentUsage.usage20dArchivedTokens == 200, "recent 20d archived usage should include archived sessions")
runner.check(recentPrioritySnapshot.recentUsage.usage20dAllTokens == 700, "recent 20d all usage should include active plus archived only inside the window")
runner.check(recentPrioritySnapshot.usage30d == 1500, "period 30 day usage should use state recency windows and include older in-window sessions")

let legacyMigrationRoot = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("CodexNotchLegacyMigration-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: legacyMigrationRoot, withIntermediateDirectories: true)
defer {
    try? FileManager.default.removeItem(at: legacyMigrationRoot)
}
let legacyStateDatabase = legacyMigrationRoot.appendingPathComponent("state_5.sqlite").path
let legacyLogsDatabase = legacyMigrationRoot.appendingPathComponent("logs_2.sqlite").path
let legacySessionDirectory = legacyMigrationRoot.appendingPathComponent("sessions/2026/06/14", isDirectory: true)
try FileManager.default.createDirectory(at: legacySessionDirectory, withIntermediateDirectories: true)
let legacySessionID = "019e073a-c032-74e2-966e-b85ede0c9cff"
let legacySessionPath = legacySessionDirectory.appendingPathComponent("rollout-2026-06-14T02-20-20-\(legacySessionID).jsonl")
try #"{"timestamp":"\#(timestamp)","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":2000}}}}"#
    .write(to: legacySessionPath, atomically: true, encoding: .utf8)
try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: legacySessionPath.path)
_ = try Shell.run("/usr/bin/sqlite3", [
    legacyStateDatabase,
    """
    create table threads(
      id text,
      title text,
      tokens_used integer,
      model text,
      reasoning_effort text,
      rollout_path text,
      created_at integer,
      updated_at integer,
      archived integer default 0
    );
    insert into threads(id, title, tokens_used, model, reasoning_effort, rollout_path, updated_at, archived)
    values('\(legacySessionID)', 'Legacy migration', 2000, 'gpt-5.5', 'high', '\(legacySessionPath.path)', \(Int(now.timeIntervalSince1970)), 0);
    """
])
_ = try Shell.run("/usr/bin/sqlite3", [
    legacyLogsDatabase,
    """
    create table logs(
      thread_id text,
      ts integer,
      target text,
      feedback_log_body text
    );
    """
])
let legacyDeltaDirectory = legacyMigrationRoot.appendingPathComponent("context-guard", isDirectory: true)
try FileManager.default.createDirectory(at: legacyDeltaDirectory, withIntermediateDirectories: true)
let legacyDeltaDatabase = legacyDeltaDirectory.appendingPathComponent("usage-deltas.sqlite").path
let legacyBaselineMs = Int64(((now.timeIntervalSince1970 - 3_700) * 1_000).rounded())
_ = try Shell.run("/usr/bin/sqlite3", [
    legacyDeltaDatabase,
    """
    create table token_snapshot_history (
      thread_id text not null,
      tokens_used integer not null,
      updated_at_ms integer not null,
      observed_at_ms integer not null,
      primary key(thread_id, observed_at_ms)
    );
    insert into token_snapshot_history(thread_id, tokens_used, updated_at_ms, observed_at_ms)
    values('\(legacySessionID)', 1500, \(legacyBaselineMs), \(legacyBaselineMs));
    create table monitor_file_cache(path text primary key);
    """
])
let migratedDeltaDatabase = legacyMigrationRoot.appendingPathComponent("SwiftCache/usage-deltas.sqlite").path
let legacyStore = CodexUsageStore(
    codexDirectory: legacyMigrationRoot,
    deltaDatabase: migratedDeltaDatabase,
    ripgrepCandidates: []
)
runner.check(legacyStore.recordDeltaSnapshot(now: now, range: .day), "Swift delta recording should migrate legacy token history")
let lateLegacyObservedMs = legacyBaselineMs + 1
_ = try Shell.run("/usr/bin/sqlite3", [
    legacyDeltaDatabase,
    "insert into token_snapshot_history(thread_id, tokens_used, updated_at_ms, observed_at_ms) values('\(legacySessionID)', 1600, \(lateLegacyObservedMs), \(lateLegacyObservedMs));"
])
runner.check(legacyStore.recordDeltaSnapshot(now: now.addingTimeInterval(1), range: .day), "legacy migration should be idempotent on repeated records")
let migratedHistoryRows = try Shell.sqliteJSON(
    database: migratedDeltaDatabase,
    query: "select count(*) as count from token_snapshot_history where thread_id = '\(legacySessionID)';",
    as: [CountRecord].self,
    readOnly: true
).first?.count ?? 0
runner.check(migratedHistoryRows >= 2, "migrated Swift cache should contain legacy and current token history rows")
let lateLegacyImportRows = try Shell.sqliteJSON(
    database: migratedDeltaDatabase,
    query: "select count(*) as count from token_snapshot_history where thread_id = '\(legacySessionID)' and observed_at_ms = \(lateLegacyObservedMs);",
    as: [CountRecord].self,
    readOnly: true
).first?.count ?? -1
runner.check(lateLegacyImportRows == 0, "legacy delta history should be imported only once after the completion marker is stored")
let migratedRowsBeforeTokenChange = migratedHistoryRows
_ = try Shell.run("/usr/bin/sqlite3", [
    legacyStateDatabase,
    "update threads set tokens_used = 2100, updated_at = \(Int(now.timeIntervalSince1970) + 2) where id = '\(legacySessionID)';"
])
runner.check(
    legacyStore.recordDeltaSnapshot(now: now.addingTimeInterval(2), range: .day),
    "a real token change should record a new delta history point"
)
let migratedRowsAfterTokenChange = try Shell.sqliteJSON(
    database: migratedDeltaDatabase,
    query: "select count(*) as count from token_snapshot_history where thread_id = '\(legacySessionID)';",
    as: [CountRecord].self,
    readOnly: true
).first?.count ?? 0
runner.check(
    migratedRowsAfterTokenChange == migratedRowsBeforeTokenChange + 1,
    "one real token change should append exactly one delta history row"
)

let missingLegacyTablesRoot = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("CodexNotchMissingLegacyTables-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: missingLegacyTablesRoot, withIntermediateDirectories: true)
defer {
    try? FileManager.default.removeItem(at: missingLegacyTablesRoot)
}
let missingLegacyState = missingLegacyTablesRoot.appendingPathComponent("state_5.sqlite").path
let missingLegacyLogs = missingLegacyTablesRoot.appendingPathComponent("logs_2.sqlite").path
_ = try Shell.run("/usr/bin/sqlite3", [
    missingLegacyState,
    """
    create table threads(
      id text,
      title text,
      tokens_used integer,
      model text,
      reasoning_effort text,
      rollout_path text,
      created_at integer,
      updated_at integer,
      archived integer default 0
    );
    insert into threads(id, title, tokens_used, model, reasoning_effort, rollout_path, updated_at, archived)
    values('\(legacySessionID)', 'Legacy missing token tables', 42, 'gpt-5.5', 'high', '', \(Int(now.timeIntervalSince1970)), 0);
    """
])
_ = try Shell.run("/usr/bin/sqlite3", [
    missingLegacyLogs,
    """
    create table logs(
      thread_id text,
      ts integer,
      target text,
      feedback_log_body text
    );
    """
])
let missingLegacyDeltaDir = missingLegacyTablesRoot.appendingPathComponent("context-guard", isDirectory: true)
try FileManager.default.createDirectory(at: missingLegacyDeltaDir, withIntermediateDirectories: true)
_ = try Shell.run("/usr/bin/sqlite3", [
    missingLegacyDeltaDir.appendingPathComponent("usage-deltas.sqlite").path,
    "create table monitor_file_cache(path text primary key);"
])
let missingLegacyStore = CodexUsageStore(
    codexDirectory: missingLegacyTablesRoot,
    deltaDatabase: missingLegacyTablesRoot.appendingPathComponent("SwiftCache/usage-deltas.sqlite").path,
    ripgrepCandidates: []
)
runner.check(missingLegacyStore.recordDeltaSnapshot(now: now, range: .day), "legacy cache without token tables should not block Swift delta recording")

let retryLegacyRoot = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("CodexNotchRetryLegacyMigration-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: retryLegacyRoot, withIntermediateDirectories: true)
defer {
    try? FileManager.default.removeItem(at: retryLegacyRoot)
}
let retryLegacySessionID = "019e073a-c032-74e2-966e-b85ede0c9cf1"
let retryLegacyState = retryLegacyRoot.appendingPathComponent("state_5.sqlite").path
let retryLegacyLogs = retryLegacyRoot.appendingPathComponent("logs_2.sqlite").path
_ = try Shell.run("/usr/bin/sqlite3", [
    retryLegacyState,
    """
    create table threads(
      id text,
      title text,
      tokens_used integer,
      model text,
      reasoning_effort text,
      rollout_path text,
      created_at integer,
      updated_at integer,
      archived integer default 0
    );
    insert into threads(id, title, tokens_used, model, reasoning_effort, rollout_path, created_at, updated_at, archived)
    values('\(retryLegacySessionID)', 'Retry legacy migration', 100, 'gpt-5.5', 'high', '', \(Int(now.timeIntervalSince1970)), \(Int(now.timeIntervalSince1970)), 0);
    """
])
_ = try Shell.run("/usr/bin/sqlite3", [
    retryLegacyLogs,
    "create table logs(thread_id text, ts integer, target text, feedback_log_body text);"
])
let retryLegacyDirectory = retryLegacyRoot.appendingPathComponent("context-guard", isDirectory: true)
try FileManager.default.createDirectory(at: retryLegacyDirectory, withIntermediateDirectories: true)
let retryLegacyDatabase = retryLegacyDirectory.appendingPathComponent("usage-deltas.sqlite").path
_ = try Shell.run("/usr/bin/sqlite3", [
    retryLegacyDatabase,
    "create table token_snapshot_history(thread_id text primary key);"
])
let retryMigratedDatabase = retryLegacyRoot.appendingPathComponent("SwiftCache/usage-deltas.sqlite").path
let retryLegacyStore = CodexUsageStore(
    codexDirectory: retryLegacyRoot,
    deltaDatabase: retryMigratedDatabase,
    ripgrepCandidates: []
)
runner.check(
    !retryLegacyStore.recordDeltaSnapshot(now: now, range: .day),
    "a malformed legacy token table should fail without marking migration complete"
)
let failedLegacyMarkerRows = (try? Shell.sqliteJSON(
    database: retryMigratedDatabase,
    query: "select count(*) as count from delta_cache_metadata where key = 'legacy_import_completed';",
    as: [CountRecord].self,
    readOnly: true
).first?.count) ?? -1
runner.check(failedLegacyMarkerRows == 0, "failed legacy migration should leave its completion marker unset")
_ = try Shell.run("/usr/bin/sqlite3", [
    retryLegacyDatabase,
    """
    drop table token_snapshot_history;
    create table token_snapshot_history (
      thread_id text not null,
      tokens_used integer not null,
      updated_at_ms integer not null,
      observed_at_ms integer not null,
      primary key(thread_id, observed_at_ms)
    );
    insert into token_snapshot_history(thread_id, tokens_used, updated_at_ms, observed_at_ms)
    values('\(retryLegacySessionID)', 50, \(legacyBaselineMs), \(legacyBaselineMs));
    """
])
runner.check(
    retryLegacyStore.recordDeltaSnapshot(now: now.addingTimeInterval(1), range: .day),
    "legacy migration should retry after the source table is repaired"
)
let retriedLegacyRows = try Shell.sqliteJSON(
    database: retryMigratedDatabase,
    query: "select count(*) as count from token_snapshot_history where thread_id = '\(retryLegacySessionID)' and tokens_used = 50;",
    as: [CountRecord].self,
    readOnly: true
).first?.count ?? 0
runner.check(retriedLegacyRows == 1, "retried legacy migration should import the repaired history exactly once")

let largeUsageRoot = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("CodexNotchLargeUsage-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: largeUsageRoot, withIntermediateDirectories: true)
defer {
    try? FileManager.default.removeItem(at: largeUsageRoot)
}
let largeUsageStateDatabase = largeUsageRoot.appendingPathComponent("state_5.sqlite").path
let largeUsageLogsDatabase = largeUsageRoot.appendingPathComponent("logs_2.sqlite").path
_ = try Shell.run("/usr/bin/sqlite3", [
    largeUsageStateDatabase,
    """
    create table threads(
      id text,
      title text,
      tokens_used integer,
      model text,
      reasoning_effort text,
      rollout_path text,
      created_at integer,
      updated_at integer,
      archived integer default 0
    );
    """
])
_ = try Shell.run("/usr/bin/sqlite3", [
    largeUsageLogsDatabase,
    """
    create table logs(
      thread_id text,
      ts integer,
      target text,
      feedback_log_body text
    );
    """
])
let largeUsageDirectory = largeUsageRoot.appendingPathComponent("sessions/2026/06/14", isDirectory: true)
try FileManager.default.createDirectory(at: largeUsageDirectory, withIntermediateDirectories: true)
let largeUsageSessionID = "019e073a-c032-74e2-966e-b85ede0c9cd4"
let largeUsagePath = largeUsageDirectory.appendingPathComponent("rollout-2026-06-14T02-20-14-\(largeUsageSessionID).jsonl")
try Data(repeating: UInt8(ascii: " "), count: 21 * 1024 * 1024).write(to: largeUsagePath)
if let handle = try? FileHandle(forWritingTo: largeUsagePath) {
    try handle.seekToEnd()
    try handle.write(contentsOf: Data(("\n" + #"{"timestamp":"\#(timestamp)","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":1}}}}"# + "\n").utf8))
    try handle.close()
}
try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: largeUsagePath.path)
let fakeRipgrepPath = largeUsageRoot.appendingPathComponent("fake-rg").path
try """
#!/bin/sh
/usr/bin/grep '"token_count"'
""".write(toFile: fakeRipgrepPath, atomically: true, encoding: .utf8)
try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeRipgrepPath)
_ = try Shell.run("/usr/bin/sqlite3", [
    largeUsageStateDatabase,
    """
    insert into threads(id, title, tokens_used, model, reasoning_effort, rollout_path, created_at, updated_at, archived)
    values('\(largeUsageSessionID)', '大文件统计任务', 777777, 'gpt-5.5', 'high', '\(largeUsagePath.path)', \(Int(now.timeIntervalSince1970)), \(Int(now.timeIntervalSince1970)), 1);
    """
])
let largeUsageStore = CodexUsageStore(codexDirectory: largeUsageRoot, ripgrepCandidates: [fakeRipgrepPath])
runner.check(largeUsageStore.loadUsageTotals(now: now)?.day == 777777, "large archived new-thread usage should use state current totals regardless of rollout search path")
let largeUsageFallbackStore = CodexUsageStore(codexDirectory: largeUsageRoot, ripgrepCandidates: [])
runner.check(largeUsageFallbackStore.loadUsageTotals(now: now)?.day == 777777, "large archived new-thread usage should be state-driven when fast search is unavailable")

let tokenCacheRoot = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("CodexNotchTokenCache-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: tokenCacheRoot, withIntermediateDirectories: true)
defer {
    try? FileManager.default.removeItem(at: tokenCacheRoot)
}
let tokenCacheStateDatabase = tokenCacheRoot.appendingPathComponent("state_5.sqlite").path
let tokenCacheLogsDatabase = tokenCacheRoot.appendingPathComponent("logs_2.sqlite").path
_ = try Shell.run("/usr/bin/sqlite3", [
    tokenCacheStateDatabase,
    """
    create table threads(
      id text,
      title text,
      tokens_used integer,
      model text,
      reasoning_effort text,
      rollout_path text,
      updated_at integer,
      archived integer default 0
    );
    """
])
_ = try Shell.run("/usr/bin/sqlite3", [
    tokenCacheLogsDatabase,
    """
    create table logs(
      thread_id text,
      ts integer,
      target text,
      feedback_log_body text
    );
    """
])
let tokenCacheSessionDirectory = tokenCacheRoot.appendingPathComponent("sessions/2026/06/14", isDirectory: true)
try FileManager.default.createDirectory(at: tokenCacheSessionDirectory, withIntermediateDirectories: true)
let tokenCacheSessionID = "019e073a-c032-74e2-966e-b85ede0c9cd3"
let tokenCachePath = tokenCacheSessionDirectory.appendingPathComponent("rollout-2026-06-14T02-20-13-\(tokenCacheSessionID).jsonl")
let firstTokenLine = #"{"timestamp":"\#(timestamp)","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"无尾换行 token"}]}}"# + "\n" +
    #"{"timestamp":"\#(timestamp)","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":100}}}}"#
try firstTokenLine.write(to: tokenCachePath, atomically: true, encoding: .utf8)
try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: tokenCachePath.path)
let tokenCacheStore = CodexUsageStore(codexDirectory: tokenCacheRoot)
let firstTokenSnapshot = tokenCacheStore.loadSnapshot(
    includePeriodUsage: false,
    bypassFastCache: true,
    rateLimitSource: .localFilesOnly,
    taskHistoryRange: .day,
    now: now
)
runner.check(firstTokenSnapshot.tasks.first { $0.id == tokenCacheSessionID }?.tokenCount == 100, "initial no-newline token event should be counted once")
let secondTokenLine = "\n" + #"{"timestamp":"\#(timestamp)","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":50}}}}"# + "\n"
if let handle = try? FileHandle(forWritingTo: tokenCachePath) {
    try handle.seekToEnd()
    try handle.write(contentsOf: Data(secondTokenLine.utf8))
    try handle.close()
}
try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(1)], ofItemAtPath: tokenCachePath.path)
let secondTokenSnapshot = tokenCacheStore.loadSnapshot(
    includePeriodUsage: false,
    bypassFastCache: true,
    rateLimitSource: .localFilesOnly,
    taskHistoryRange: .day,
    now: now.addingTimeInterval(1)
)
runner.check(secondTokenSnapshot.tasks.first { $0.id == tokenCacheSessionID }?.tokenCount == 150, "appending after an initially unterminated token line should not double count the pending line")
runner.check(CodexUsageStore.fastSnapshotCacheMaxAge == 30, "fast snapshot cache should use the agreed 30 second upper bound")
let cacheStatsAfterChangedFile = tokenCacheStore.sessionFileCacheStats()
let unchangedTokenSnapshot = tokenCacheStore.loadSnapshot(
    includePeriodUsage: false,
    bypassFastCache: true,
    rateLimitSource: .localFilesOnly,
    taskHistoryRange: .day,
    now: now.addingTimeInterval(2)
)
runner.check(unchangedTokenSnapshot.tasks.first { $0.id == tokenCacheSessionID }?.tokenCount == 150, "unchanged rollout refresh should preserve token totals")
let cacheStatsAfterUnchangedFile = tokenCacheStore.sessionFileCacheStats()
runner.check(
    cacheStatsAfterUnchangedFile.prefixScans == cacheStatsAfterChangedFile.prefixScans,
    "unchanged rollout refresh should not rescan session metadata prefixes"
)
runner.check(
    cacheStatsAfterUnchangedFile.rateLimitScans == cacheStatsAfterChangedFile.rateLimitScans,
    "unchanged rollout refresh should not rescan rate-limit tails"
)
runner.check(
    cacheStatsAfterUnchangedFile.activityScans == cacheStatsAfterChangedFile.activityScans,
    "unchanged rollout refresh should not rescan activity tails"
)
let rateLimitAppendLine = #"{"timestamp":"\#(timestamp)","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":0}},"rate_limits":{"limit_id":"codex","primary":{"used_percent":25},"secondary":{"used_percent":40}}}}"# + "\n"
if let handle = try? FileHandle(forWritingTo: tokenCachePath) {
    try handle.seekToEnd()
    try handle.write(contentsOf: Data(rateLimitAppendLine.utf8))
    try handle.close()
}
try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(3)], ofItemAtPath: tokenCachePath.path)
let appendedRateLimitSnapshot = tokenCacheStore.loadSnapshot(
    includePeriodUsage: false,
    bypassFastCache: true,
    rateLimitSource: .localFilesOnly,
    taskHistoryRange: .day,
    now: now.addingTimeInterval(3)
)
runner.check(appendedRateLimitSnapshot.primaryPercent == 75, "appending rate-limit data should invalidate the changed rollout cache")
let cacheStatsAfterAppendedFile = tokenCacheStore.sessionFileCacheStats()
runner.check(
    cacheStatsAfterAppendedFile.prefixScans == cacheStatsAfterUnchangedFile.prefixScans + 1,
    "one appended rollout should trigger one metadata prefix rescan"
)
runner.check(
    cacheStatsAfterAppendedFile.rateLimitScans == cacheStatsAfterUnchangedFile.rateLimitScans + 1,
    "one appended rollout should trigger one rate-limit tail rescan"
)
runner.check(
    cacheStatsAfterAppendedFile.activityScans == cacheStatsAfterUnchangedFile.activityScans + 1,
    "one appended rollout should trigger one activity tail rescan"
)

let tokenCacheAttributes = try FileManager.default.attributesOfItem(atPath: tokenCachePath.path)
let tokenCacheSize = (tokenCacheAttributes[.size] as? NSNumber)?.intValue ?? 0
let tokenCacheModifiedAt = tokenCacheAttributes[.modificationDate] as? Date ?? now
let tokenCacheInode = (tokenCacheAttributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
let replacementTokenPath = tokenCacheSessionDirectory.appendingPathComponent("replacement-\(UUID().uuidString).jsonl")
let replacementTokenLine = #"{"timestamp":"\#(timestamp)","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":300}}}}"# + "\n"
var replacementTokenData = Data(replacementTokenLine.utf8)
runner.check(replacementTokenData.count <= tokenCacheSize, "replacement token fixture should fit the original byte size")
if replacementTokenData.count < tokenCacheSize {
    replacementTokenData.append(Data(repeating: UInt8(ascii: " "), count: tokenCacheSize - replacementTokenData.count))
}
try replacementTokenData.write(to: replacementTokenPath)
try FileManager.default.setAttributes([.modificationDate: tokenCacheModifiedAt], ofItemAtPath: replacementTokenPath.path)
let replacementTokenAttributes = try FileManager.default.attributesOfItem(atPath: replacementTokenPath.path)
let replacementTokenInode = (replacementTokenAttributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
runner.check(replacementTokenInode != tokenCacheInode, "replacement token fixture should use a different inode")
try FileManager.default.removeItem(at: tokenCachePath)
try FileManager.default.moveItem(at: replacementTokenPath, to: tokenCachePath)
let replacedTokenSnapshot = tokenCacheStore.loadSnapshot(
    includePeriodUsage: false,
    bypassFastCache: true,
    rateLimitSource: .localFilesOnly,
    taskHistoryRange: .day,
    now: now.addingTimeInterval(4)
)
runner.check(
    replacedTokenSnapshot.tasks.first { $0.id == tokenCacheSessionID }?.tokenCount == 300,
    "same-size same-mtime rollout replacement should invalidate token caches by inode"
)
let cacheStatsBeforeFastHit = tokenCacheStore.sessionFileCacheStats()
let withinFastCacheWindow = tokenCacheStore.loadSnapshot(
    includePeriodUsage: false,
    bypassFastCache: false,
    rateLimitSource: .localFilesOnly,
    taskHistoryRange: .day,
    now: now.addingTimeInterval(33)
)
runner.check(withinFastCacheWindow.tasks.first { $0.id == tokenCacheSessionID }?.tokenCount == 300, "29 second fast-cache hit should preserve snapshot output")
let cacheStatsAfterFastHit = tokenCacheStore.sessionFileCacheStats()
runner.check(
    cacheStatsAfterFastHit.fastSnapshotHits == cacheStatsBeforeFastHit.fastSnapshotHits + 1,
    "unchanged snapshots should reuse the full cache inside 30 seconds"
)
_ = tokenCacheStore.loadSnapshot(
    includePeriodUsage: false,
    bypassFastCache: false,
    rateLimitSource: .localFilesOnly,
    taskHistoryRange: .day,
    now: now.addingTimeInterval(35)
)
let cacheStatsAfterFastExpiry = tokenCacheStore.sessionFileCacheStats()
runner.check(
    cacheStatsAfterFastExpiry.fastSnapshotHits == cacheStatsAfterFastHit.fastSnapshotHits,
    "fast snapshot cache should expire after 30 seconds"
)
_ = tokenCacheStore.loadSnapshot(
    includePeriodUsage: false,
    bypassFastCache: true,
    rateLimitSource: .localFilesOnly,
    taskHistoryRange: .day,
    now: now.addingTimeInterval(36)
)
let cacheStatsAfterForcedRefresh = tokenCacheStore.sessionFileCacheStats()
runner.check(
    cacheStatsAfterForcedRefresh.fastSnapshotHits == cacheStatsAfterFastExpiry.fastSnapshotHits,
    "forced refresh should bypass the 30 second fast snapshot cache"
)
try FileManager.default.removeItem(at: tokenCachePath)
_ = tokenCacheStore.loadSnapshot(
    includePeriodUsage: false,
    bypassFastCache: true,
    rateLimitSource: .localFilesOnly,
    taskHistoryRange: .day,
    now: now.addingTimeInterval(37)
)
runner.check(tokenCacheStore.sessionFileCacheStats().entryCount == 0, "session caches should evict files outside the current scan set")

let fastCacheActivityRoot = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("CodexNotchFastCacheActivity-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: fastCacheActivityRoot, withIntermediateDirectories: true)
defer {
    try? FileManager.default.removeItem(at: fastCacheActivityRoot)
}
let fastCacheActivityState = fastCacheActivityRoot.appendingPathComponent("state_5.sqlite").path
let fastCacheActivityLogs = fastCacheActivityRoot.appendingPathComponent("logs_2.sqlite").path
_ = try Shell.run("/usr/bin/sqlite3", [
    fastCacheActivityState,
    """
    create table threads(
      id text,
      title text,
      tokens_used integer,
      model text,
      reasoning_effort text,
      rollout_path text,
      created_at integer,
      updated_at integer,
      archived integer default 0
    );
    """
])
_ = try Shell.run("/usr/bin/sqlite3", [
    fastCacheActivityLogs,
    "create table logs(thread_id text, ts integer, target text, feedback_log_body text);"
])
let fastCacheActivityDirectory = fastCacheActivityRoot.appendingPathComponent("sessions/2026/07/12", isDirectory: true)
try FileManager.default.createDirectory(at: fastCacheActivityDirectory, withIntermediateDirectories: true)
let expiringActivitySessionID = "019e073a-c032-74e2-966e-b85ede0c9cf2"
let expiringActivityPath = fastCacheActivityDirectory.appendingPathComponent("rollout-2026-07-12T00-00-00-\(expiringActivitySessionID).jsonl")
let expiringActivityTimestamp = ISO8601DateFormatter().string(from: now.addingTimeInterval(-590))
try """
{"timestamp":"\(expiringActivityTimestamp)","type":"response_item","payload":{"type":"message","role":"assistant","content":[]}}
{"timestamp":"\(expiringActivityTimestamp)","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":1}}}}
""".write(to: expiringActivityPath, atomically: true, encoding: .utf8)
try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: expiringActivityPath.path)
let fastCacheActivityStore = CodexUsageStore(codexDirectory: fastCacheActivityRoot, ripgrepCandidates: [])
let initialActivitySnapshot = fastCacheActivityStore.loadSnapshot(
    includePeriodUsage: false,
    bypassFastCache: true,
    rateLimitSource: .localFilesOnly,
    taskHistoryRange: .day,
    now: now
)
runner.check(
    initialActivitySnapshot.tasks.first { $0.id == expiringActivitySessionID }?.status == .running,
    "recent rollout activity should initially mark the task running"
)
let newFastCacheSessionID = "019e073a-c032-74e2-966e-b85ede0c9cf3"
let newFastCachePath = fastCacheActivityDirectory.appendingPathComponent("rollout-2026-07-12T00-00-01-\(newFastCacheSessionID).jsonl")
try #"{"timestamp":"\#(timestamp)","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":2}}}}"#
    .write(to: newFastCachePath, atomically: true, encoding: .utf8)
try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(1)], ofItemAtPath: newFastCachePath.path)
let cacheStatsBeforeDirectoryChange = fastCacheActivityStore.sessionFileCacheStats()
let directoryChangedSnapshot = fastCacheActivityStore.loadSnapshot(
    includePeriodUsage: false,
    bypassFastCache: false,
    rateLimitSource: .localFilesOnly,
    taskHistoryRange: .day,
    now: now.addingTimeInterval(5)
)
runner.check(directoryChangedSnapshot.tasks.contains { $0.id == newFastCacheSessionID }, "new rollout files should invalidate cached path lists inside the 30 second window")
runner.check(
    fastCacheActivityStore.sessionFileCacheStats().fastSnapshotHits == cacheStatsBeforeDirectoryChange.fastSnapshotHits,
    "directory changes should bypass the full fast snapshot cache"
)
let activityExpiredSnapshot = fastCacheActivityStore.loadSnapshot(
    includePeriodUsage: false,
    bypassFastCache: false,
    rateLimitSource: .localFilesOnly,
    taskHistoryRange: .day,
    now: now.addingTimeInterval(25)
)
runner.check(
    activityExpiredSnapshot.tasks.first { $0.id == expiringActivitySessionID }?.status == .recent,
    "fast snapshot hits should recompute activity expiration from the requested time"
)
runner.check(
    fastCacheActivityStore.sessionFileCacheStats().fastSnapshotHits == cacheStatsBeforeDirectoryChange.fastSnapshotHits + 1,
    "unchanged directory state should reuse the refreshed snapshot inside 30 seconds"
)

let archivedSubagentCacheRoot = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("CodexNotchArchivedSubagentCache-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: archivedSubagentCacheRoot, withIntermediateDirectories: true)
defer {
    try? FileManager.default.removeItem(at: archivedSubagentCacheRoot)
}
let archivedSubagentState = archivedSubagentCacheRoot.appendingPathComponent("state_5.sqlite").path
let archivedSubagentLogs = archivedSubagentCacheRoot.appendingPathComponent("logs_2.sqlite").path
let archivedSubagentSessionID = "019e073a-c032-74e2-966e-b85ede0c9cf4"
let archivedSubagentParentID = "019e073a-c032-74e2-966e-b85ede0c9cf5"
let archivedSubagentDirectory = archivedSubagentCacheRoot.appendingPathComponent("archived_sessions/2026/07/12", isDirectory: true)
try FileManager.default.createDirectory(at: archivedSubagentDirectory, withIntermediateDirectories: true)
let archivedSubagentPath = archivedSubagentDirectory.appendingPathComponent("rollout-2026-07-12T00-00-02-\(archivedSubagentSessionID).jsonl")
try """
{"timestamp":"\(timestamp)","type":"session_meta","payload":{"thread_source":"subagent","parent_thread_id":"\(archivedSubagentParentID)"}}
""".write(to: archivedSubagentPath, atomically: true, encoding: .utf8)
try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: archivedSubagentPath.path)
_ = try Shell.run("/usr/bin/sqlite3", [
    archivedSubagentState,
    """
    create table threads(
      id text,
      title text,
      tokens_used integer,
      model text,
      reasoning_effort text,
      rollout_path text,
      created_at integer,
      updated_at integer,
      recency_at integer,
      archived integer default 0
    );
    insert into threads(id, title, tokens_used, model, reasoning_effort, rollout_path, created_at, updated_at, recency_at, archived)
    values('\(archivedSubagentSessionID)', 'Archived child', 1, 'gpt-5.5', 'high', '\(archivedSubagentPath.path)', \(Int(now.timeIntervalSince1970)), \(Int(now.timeIntervalSince1970)), \(Int(now.timeIntervalSince1970)), 1);
    """
])
_ = try Shell.run("/usr/bin/sqlite3", [
    archivedSubagentLogs,
    "create table logs(thread_id text, ts integer, target text, feedback_log_body text);"
])
let archivedSubagentCacheStore = CodexUsageStore(codexDirectory: archivedSubagentCacheRoot, ripgrepCandidates: [])
_ = archivedSubagentCacheStore.loadSnapshot(
    includePeriodUsage: false,
    bypassFastCache: true,
    rateLimitSource: .localFilesOnly,
    taskHistoryRange: .day,
    now: now
)
let archivedCacheStatsAfterFirstRefresh = archivedSubagentCacheStore.sessionFileCacheStats()
_ = archivedSubagentCacheStore.loadSnapshot(
    includePeriodUsage: false,
    bypassFastCache: true,
    rateLimitSource: .localFilesOnly,
    taskHistoryRange: .day,
    now: now.addingTimeInterval(1)
)
let archivedCacheStatsAfterSecondRefresh = archivedSubagentCacheStore.sessionFileCacheStats()
runner.check(
    archivedCacheStatsAfterSecondRefresh.prefixScans == archivedCacheStatsAfterFirstRefresh.prefixScans,
    "filtered archived subagent files should remain cached across unchanged full refreshes"
)

let skillInsightsRoot = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("CodexNotchSkillInsights-\(UUID().uuidString)")
let skillCodexHome = skillInsightsRoot.appendingPathComponent("codex-home", isDirectory: true)
let skillRoot = skillInsightsRoot.appendingPathComponent("skills", isDirectory: true)
let skillDatabaseURL = skillInsightsRoot.appendingPathComponent("skill-observations.sqlite")
let skillConfigURL = skillCodexHome.appendingPathComponent("config.toml")
let skillSessionsDirectory = skillCodexHome.appendingPathComponent("sessions/2026/07/13", isDirectory: true)
try FileManager.default.createDirectory(at: skillSessionsDirectory, withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: skillRoot, withIntermediateDirectories: true)
defer {
    try? FileManager.default.removeItem(at: skillInsightsRoot)
}

let writeSyntheticSkill: (String, String, String) throws -> URL = { directoryName, name, description in
    let directory = skillRoot.appendingPathComponent(directoryName, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("SKILL.md")
    try """
    ---
    name: \(name)
    description: \(description)
    ---

    THIS BODY MUST NOT BE NEEDED BY THE CATALOG LOADER.
    """.write(to: url, atomically: true, encoding: .utf8)
    return url
}

let testSkillURL = try writeSyntheticSkill(
    "test-skill",
    "test-skill",
    "Analyze release workflows and deployment risks."
)
_ = try writeSyntheticSkill(
    "shadow-skill",
    "shadow-skill",
    "Review database migration rollback safety."
)
_ = try writeSyntheticSkill(
    "legacy-dashboard",
    "legacy-dashboard",
    "Build operational dashboard reports."
)
let duplicateOneURL = try writeSyntheticSkill(
    "duplicate-one",
    "duplicate-skill",
    "Inspect unique duplicate alpha evidence."
)
let duplicateTwoURL = try writeSyntheticSkill(
    "duplicate-two",
    "duplicate-skill",
    "Inspect unique duplicate beta evidence."
)
_ = try writeSyntheticSkill(
    "boundary-skill",
    "boundary-skill",
    "Check weekly boundary evidence timing."
)
try """
[[skills.config]]
name = "shadow-skill"
enabled = false

[[skills.config]]
name = "legacy-dashboard"
enabled = false
""".write(to: skillConfigURL, atomically: true, encoding: .utf8)

let skillStatePath = skillCodexHome.appendingPathComponent("state_5.sqlite").path
let skillLogsPath = skillCodexHome.appendingPathComponent("logs_2.sqlite").path
let skillSessionID = "019f5d70-0000-7000-8000-000000000001"
let skillBoundarySessionID = "019f5d70-0000-7000-8000-000000000002"
let skillRolloutURL = skillSessionsDirectory
    .appendingPathComponent("rollout-2026-07-13T12-00-00-\(skillSessionID).jsonl")
let skillBoundaryURL = skillSessionsDirectory
    .appendingPathComponent("rollout-2026-07-13T12-00-01-\(skillBoundarySessionID).jsonl")
let skillNow = Calendar.current.startOfDay(for: now).addingTimeInterval(12 * 60 * 60)
let skillFixtureStart = skillNow.addingTimeInterval(-10)
let skillWindowStart = skillNow.addingTimeInterval(-7 * 24 * 60 * 60)

_ = try Shell.run("/usr/bin/sqlite3", [
    skillStatePath,
    """
    create table threads(
      id text,
      title text,
      tokens_used integer,
      model text,
      reasoning_effort text,
      rollout_path text,
      created_at integer,
      updated_at integer,
      archived integer default 0
    );
    insert into threads(id, title, tokens_used, rollout_path, created_at, updated_at, archived)
    values(
      '\(skillSessionID)',
      'Skill fixture',
      82000,
      '\(skillRolloutURL.path)',
      \(Int(skillNow.timeIntervalSince1970)),
      \(Int(skillNow.timeIntervalSince1970)),
      0
    );
    """
])
_ = try Shell.run("/usr/bin/sqlite3", [
    skillLogsPath,
    "create table logs(thread_id text, ts integer, target text, feedback_log_body text);"
])

let skillTimestamp: (Date) -> String = { date in
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
}
let skillJSONLine: ([String: Any]) -> String = { object in
    let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    return String(decoding: data, as: UTF8.self) + "\n"
}
let skillSessionMetaLine: (Date, String) -> String = { date, sessionID in
    skillJSONLine([
        "timestamp": skillTimestamp(date),
        "type": "session_meta",
        "payload": [
            "id": sessionID,
            "cwd": "/private/project-sensitive-path"
        ]
    ])
}
let skillMessageLine: (Date, String, String, String?) -> String = { date, role, text, phase in
    var payload: [String: Any] = [
        "type": "message",
        "role": role,
        "content": [["type": role == "user" ? "input_text" : "output_text", "text": text]]
    ]
    if let phase {
        payload["phase"] = phase
    }
    return skillJSONLine([
        "timestamp": skillTimestamp(date),
        "type": "response_item",
        "payload": payload
    ])
}
let skillReadLine: (Date, URL, String) -> String = { date, skillURL, extra in
    skillJSONLine([
        "timestamp": skillTimestamp(date),
        "type": "response_item",
        "payload": [
            "type": "custom_tool_call",
            "name": "exec",
            "input": "sed -n '1,120p' '\(skillURL.path)' \(extra)"
        ]
    ])
}
let skillTokenLine: (Date, Int) -> String = { date, tokens in
    skillJSONLine([
        "timestamp": skillTimestamp(date),
        "type": "event_msg",
        "payload": [
            "type": "token_count",
            "info": ["last_token_usage": ["total_tokens": tokens]]
        ]
    ])
}

var skillRollout = skillSessionMetaLine(skillFixtureStart, skillSessionID)
skillRollout += skillMessageLine(skillFixtureStart, "user", "$test-skill review release workflow", nil)
skillRollout += skillMessageLine(skillFixtureStart, "assistant", "Using test-skill skill.", "commentary")
skillRollout += skillReadLine(skillFixtureStart, testSkillURL, "")
skillRollout += skillTokenLine(skillFixtureStart, 82000)
skillRollout += skillMessageLine(skillFixtureStart, "assistant", "Completed.", "final")

skillRollout += skillMessageLine(skillFixtureStart.addingTimeInterval(1), "user", "Analyze release workflows and deployment risks.", nil)
skillRollout += skillMessageLine(skillFixtureStart.addingTimeInterval(1), "assistant", "Using test-skill skill.", "commentary")
skillRollout += skillReadLine(skillFixtureStart.addingTimeInterval(1), testSkillURL, "")
skillRollout += skillMessageLine(skillFixtureStart.addingTimeInterval(1), "assistant", "Completed.", "final")

skillRollout += skillMessageLine(skillFixtureStart.addingTimeInterval(2), "user", "What is test-skill?", nil)
skillRollout += skillMessageLine(skillFixtureStart.addingTimeInterval(2), "assistant", "Information provided.", "final")

skillRollout += skillMessageLine(
    skillFixtureStart.addingTimeInterval(3),
    "user",
    "SECRET-PROMPT-DO-NOT-STORE review database migration rollback safety",
    nil
)
skillRollout += skillMessageLine(skillFixtureStart.addingTimeInterval(3), "assistant", "Completed.", "final")

skillRollout += skillMessageLine(skillFixtureStart.addingTimeInterval(4), "user", "Build operational dashboard reports.", nil)
skillRollout += skillMessageLine(
    skillFixtureStart.addingTimeInterval(4),
    "assistant",
    "Handled by existing capability instead of legacy-dashboard skill.",
    "final"
)

skillRollout += skillMessageLine(skillFixtureStart.addingTimeInterval(5), "user", "Analyze release workflows and deployment risks.", nil)
skillRollout += skillMessageLine(skillFixtureStart.addingTimeInterval(5), "assistant", "Using test-skill skill.", "final")

skillRollout += skillMessageLine(skillFixtureStart.addingTimeInterval(6), "user", "Summarize gardening notes.", nil)
skillRollout += skillMessageLine(skillFixtureStart.addingTimeInterval(6), "assistant", "Using test-skill skill.", "commentary")
skillRollout += skillReadLine(skillFixtureStart.addingTimeInterval(6), testSkillURL, "SECRET-TOOL-INPUT")
skillRollout += skillMessageLine(skillFixtureStart.addingTimeInterval(6), "assistant", "Completed.", "final")

skillRollout += skillMessageLine(skillFixtureStart.addingTimeInterval(7), "user", "$duplicate-skill inspect duplicate evidence", nil)
skillRollout += skillMessageLine(skillFixtureStart.addingTimeInterval(7), "assistant", "Completed.", "final")
skillRollout += "{malformed-jsonl-row\n"
skillRollout += "{\"oversized\":\"\(String(repeating: "x", count: 9_000))\"}\n"
try skillRollout.write(to: skillRolloutURL, atomically: true, encoding: .utf8)
try FileManager.default.setAttributes([.modificationDate: skillNow], ofItemAtPath: skillRolloutURL.path)

var boundaryRollout = skillSessionMetaLine(skillNow, skillBoundarySessionID)
boundaryRollout += skillMessageLine(
    skillWindowStart.addingTimeInterval(-1),
    "user",
    "$boundary-skill check weekly boundary evidence timing",
    nil
)
boundaryRollout += skillMessageLine(skillWindowStart.addingTimeInterval(-1), "assistant", "Completed.", "final")
boundaryRollout += skillMessageLine(
    skillWindowStart,
    "user",
    "$boundary-skill check weekly boundary evidence timing",
    nil
)
boundaryRollout += skillMessageLine(skillWindowStart, "assistant", "Completed.", "final")
try boundaryRollout.write(to: skillBoundaryURL, atomically: true, encoding: .utf8)
try FileManager.default.setAttributes([.modificationDate: skillNow], ofItemAtPath: skillBoundaryURL.path)

let authoritativeCatalogFixture = SkillCatalogSnapshot(
    skills: [
        SkillCatalogEntry(
            id: SkillCatalogLoader.stableID(for: testSkillURL.path),
            name: "test-skill",
            description: "Analyze release workflows and deployment risks.",
            path: testSkillURL.path,
            enabled: true,
            catalogCharacterCount: 55,
            catalogTokenEstimate: 14,
            protectsHighRiskWorkflow: true
        ),
        SkillCatalogEntry(
            id: SkillCatalogLoader.stableID(for: skillRoot.appendingPathComponent("shadow-skill/SKILL.md").path),
            name: "shadow-skill",
            description: "Review database migration rollback safety.",
            path: skillRoot.appendingPathComponent("shadow-skill/SKILL.md").path,
            enabled: false,
            catalogCharacterCount: 53,
            catalogTokenEstimate: 14,
            protectsHighRiskWorkflow: true
        )
    ],
    quality: .complete,
    diagnostics: [],
    loadedAt: skillNow
)
let authoritativeCatalogResult = SkillCatalogLoader(
    codexDirectory: skillCodexHome,
    configURL: skillConfigURL,
    skillRoots: [skillRoot],
    authoritativeCatalogLoader: { _, _ in authoritativeCatalogFixture }
).load(now: skillNow)
runner.checkEqual(
    authoritativeCatalogResult.skills.count,
    2,
    "the authoritative Codex catalog should exclude cached Skills that are not active"
)
runner.checkEqual(
    authoritativeCatalogResult.enabledCount,
    1,
    "enabled Skill count should come from the authoritative Codex catalog"
)
runner.checkEqual(
    authoritativeCatalogResult.disabledCount,
    1,
    "disabled Skill count should come from the authoritative Codex catalog"
)

let appServerCatalogPayload = try JSONSerialization.data(withJSONObject: [
    "jsonrpc": "2.0",
    "id": 2,
    "result": [
        "data": [[
            "cwd": skillCodexHome.path,
            "errors": [],
            "skills": [
                [
                    "name": "test-skill",
                    "description": "Analyze release workflows and deployment risks.",
                    "path": testSkillURL.path,
                    "enabled": true,
                    "scope": "user"
                ],
                [
                    "name": "shadow-skill",
                    "description": "Review database migration rollback safety.",
                    "path": skillRoot.appendingPathComponent("shadow-skill/SKILL.md").path,
                    "enabled": false,
                    "scope": "user"
                ]
            ]
        ]]
    ]
], options: [.sortedKeys])
let parsedAppServerCatalog = try CodexSkillsAppServerClient.parseSkillsListResponse(
    appServerCatalogPayload,
    loadedAt: skillNow
)
runner.checkEqual(parsedAppServerCatalog.enabledCount, 1, "skills/list enabled state should be parsed without rescanning cache roots")
runner.checkEqual(parsedAppServerCatalog.disabledCount, 1, "skills/list disabled state should be parsed without rescanning config.toml")
runner.checkEqual(parsedAppServerCatalog.quality, .complete, "a clean skills/list response should produce COMPLETE catalog quality")

let fakeCodexExecutable = skillInsightsRoot.appendingPathComponent("fake-codex")
let fakeCatalogResponse = String(decoding: appServerCatalogPayload, as: UTF8.self)
try """
#!/bin/sh
IFS= read -r initialize
IFS= read -r initialized
IFS= read -r list_skills
printf '%s\\n' '\(fakeCatalogResponse)'
while IFS= read -r remainder; do :; done
""".write(to: fakeCodexExecutable, atomically: true, encoding: .utf8)
try FileManager.default.setAttributes(
    [.posixPermissions: 0o700],
    ofItemAtPath: fakeCodexExecutable.path
)
let catalogClientStartedAt = Date()
let processBackedCatalog = try CodexSkillsAppServerClient(
    codexDirectory: skillCodexHome,
    workingDirectory: skillInsightsRoot,
    executablePath: fakeCodexExecutable.path,
    timeout: 2
).load(now: skillNow, forceReload: true)
let catalogClientDurationMilliseconds = Int(Date().timeIntervalSince(catalogClientStartedAt) * 1_000)
runner.checkEqual(processBackedCatalog.enabledCount, 1, "the bounded local app-server process client should return enabled Skills")
runner.checkEqual(processBackedCatalog.disabledCount, 1, "the bounded local app-server process client should return disabled Skills")
runner.check(
    catalogClientDurationMilliseconds < 2_000,
    "the local skills/list process client should finish inside its two-second test budget"
)

let fallbackCatalogResult = SkillCatalogLoader(
    codexDirectory: skillCodexHome,
    configURL: skillConfigURL,
    skillRoots: [skillRoot],
    authoritativeCatalogLoader: { _, _ in throw AppServerLoaderTestError.unavailable }
).load(now: skillNow)
runner.checkEqual(fallbackCatalogResult.quality, .partial, "filesystem fallback after skills/list failure must be visibly PARTIAL")
runner.check(
    fallbackCatalogResult.diagnostics.contains { $0.contains("inactive plugin cache") },
    "filesystem fallback should diagnose possible inactive plugin cache overcounting"
)

let unavailableCheckpointAnalyzer = SkillSessionAnalyzer(
    codexDirectory: skillCodexHome,
    observationStore: SkillObservationStore(databaseURL: skillInsightsRoot),
    maxRowBytes: 8 * 1024,
    maxBytesPerFilePerRun: 4 * 1024 * 1024
)
let unavailableCheckpointOutcome = unavailableCheckpointAnalyzer.analyze(
    catalog: authoritativeCatalogResult,
    now: skillNow
)
runner.checkEqual(
    unavailableCheckpointOutcome.performance.analyzedBytes,
    0,
    "an unavailable checkpoint store must not trigger an uncheckpointed full JSONL rescan"
)
runner.checkEqual(
    unavailableCheckpointOutcome.quality,
    .partial,
    "checkpoint-store failure should propagate PARTIAL instead of silently appearing complete"
)

let skillService = SkillInsightsService(
    codexDirectory: skillCodexHome,
    configURL: skillConfigURL,
    skillRoots: [skillRoot],
    databaseURL: skillDatabaseURL,
    maxRowBytes: 8 * 1024,
    maxBytesPerFilePerRun: 4 * 1024 * 1024
)
let firstSkillSnapshot = skillService.analyzeRecentWeek(force: false, automatic: false, now: skillNow)
let firstDisabledSkillIndex = firstSkillSnapshot.rows.firstIndex { !$0.skill.enabled }
    ?? firstSkillSnapshot.rows.endIndex
runner.check(
    firstSkillSnapshot.rows[..<firstDisabledSkillIndex].allSatisfy { $0.skill.enabled }
        && firstSkillSnapshot.rows[firstDisabledSkillIndex...].allSatisfy { !$0.skill.enabled },
    "Skill Insights should group every enabled Skill ahead of disabled Skills"
)
let testSkillRow = runner.require(
    firstSkillSnapshot.rows.first { $0.skill.name == "test-skill" },
    "Skill Insights should include the enabled test Skill"
)
runner.checkEqual(testSkillRow.directCount, 1, "explicit $skill-name should produce one DIRECT observation")
runner.checkEqual(testSkillRow.strongCount, 1, "declaration + SKILL.md read + relevant task should produce STRONG")
runner.check(testSkillRow.inferredCount >= 2, "declaration without all STRONG evidence should remain INFERRED")
runner.check(testSkillRow.suspectedMissCount >= 1, "mentioning an enabled Skill without use should not count as confirmed use")
runner.check(testSkillRow.suspectedMisfireCount >= 1, "irrelevant Skill declaration/read should be a suspected misfire")
runner.checkEqual(testSkillRow.relatedSessionTokens, 82_000, "related Session Token should remain a non-attributed reference total")

let shadowSkillRow = runner.require(
    firstSkillSnapshot.rows.first { $0.skill.name == "shadow-skill" },
    "Skill Insights should include disabled Skills"
)
runner.checkEqual(shadowSkillRow.shadowCount, 1, "disabled relevant Skill should produce SHADOW evidence")
runner.checkEqual(shadowSkillRow.recommendation, .retest, "one high-risk SHADOW should recommend sampling and retest")
runner.checkEqual(shadowSkillRow.relatedSessionCount, 1, "SHADOW evidence should retain a whole-Session reference without Token attribution")

let replacementRow = runner.require(
    firstSkillSnapshot.rows.first { $0.skill.name == "legacy-dashboard" },
    "Skill Insights should include replacement candidates"
)
runner.checkEqual(replacementRow.shadowCount, 1, "disabled replacement candidate should retain its SHADOW observation")
runner.checkEqual(replacementRow.replacedByExistingCount, 1, "explicit replacement wording should remain a separate heuristic")

let duplicateRows = firstSkillSnapshot.rows.filter { $0.skill.name == "duplicate-skill" }
runner.checkEqual(duplicateRows.count, 2, "same-name Skills should stay distinct by canonical path")
runner.check(duplicateRows.allSatisfy { $0.directCount == 1 }, "ambiguous explicit duplicate name should preserve evidence for both paths")
runner.check(duplicateRows.allSatisfy { $0.evidenceQuality == .partial }, "ambiguous same-name evidence should be visibly PARTIAL")

let boundaryRow = runner.require(
    firstSkillSnapshot.rows.first { $0.skill.name == "boundary-skill" },
    "Skill Insights should include the one-week boundary fixture"
)
runner.checkEqual(boundaryRow.directCount, 1, "exact seven-day boundary should be included and older evidence excluded")
runner.checkEqual(firstSkillSnapshot.quality, .partial, "corrupt or oversized JSONL rows should propagate PARTIAL")
runner.check(firstSkillSnapshot.performance.malformedLines >= 1, "malformed JSONL row should be counted and skipped")
runner.check(firstSkillSnapshot.performance.skippedOversizedRows >= 1, "oversized JSONL row should be counted and skipped")
runner.checkEqual(firstSkillSnapshot.performance.modelTokens, 0, "Skill analyzer must not consume model Tokens")

let observationDump = try Shell.run("/usr/bin/sqlite3", [skillDatabaseURL.path, ".dump"])
runner.check(!observationDump.contains("SECRET-PROMPT-DO-NOT-STORE"), "derived SQLite must not store complete Prompt text")
runner.check(!observationDump.contains("SECRET-TOOL-INPUT"), "derived SQLite must not store complete tool input")
runner.check(!observationDump.contains("Using test-skill skill"), "derived SQLite must not store assistant message text")

let firstMarkdown = String(decoding: try skillService.export(firstSkillSnapshot, format: .markdown), as: UTF8.self)
runner.check(firstMarkdown.contains("## 9. UNVERIFIED"), "Markdown report should include all UNVERIFIED items")
runner.check(firstMarkdown.contains("Per-Skill Token: UNAVAILABLE"), "Markdown report should forbid precise per-Skill Token attribution")
let firstJSON = try skillService.export(firstSkillSnapshot, format: .json)
runner.check((try? JSONSerialization.jsonObject(with: firstJSON)) != nil, "JSON Skill report should be machine readable")
let observationsAfterColdScan = try Shell.sqliteJSON(
    database: skillDatabaseURL.path,
    query: "select count(*) as count from skill_observations;",
    as: [CountRecord].self,
    readOnly: true
).first?.count

let aliasedRolloutURL = skillSessionsDirectory
    .appendingPathComponent("rollout-alias-\(skillSessionID).jsonl")
try FileManager.default.createSymbolicLink(
    at: aliasedRolloutURL,
    withDestinationURL: skillRolloutURL
)
let unchangedSkillSnapshot = skillService.analyzeRecentWeek(
    force: false,
    automatic: false,
    now: skillNow.addingTimeInterval(1)
)
runner.checkEqual(
    unchangedSkillSnapshot.performance.candidateFiles,
    2,
    "canonical rollout paths should deduplicate real paths and symbolic-link aliases"
)
runner.checkEqual(unchangedSkillSnapshot.performance.analyzedFiles, 0, "unchanged rollout files should not be reparsed")
runner.checkEqual(unchangedSkillSnapshot.performance.unchangedFiles, 2, "unchanged rollout checkpoints should be reported")
runner.checkEqual(unchangedSkillSnapshot.performance.analyzedBytes, 0, "a warm unchanged scan should read zero logical JSONL bytes")
runner.check(
    unchangedSkillSnapshot.performance.durationMilliseconds <= 500,
    "a warm unchanged Skill snapshot should complete within 500 ms"
)
let observationsAfterWarmScan = try Shell.sqliteJSON(
    database: skillDatabaseURL.path,
    query: "select count(*) as count from skill_observations;",
    as: [CountRecord].self,
    readOnly: true
).first?.count
runner.checkEqual(
    observationsAfterWarmScan,
    observationsAfterColdScan,
    "a warm unchanged scan should write zero new observations"
)
runner.checkEqual(
    unchangedSkillSnapshot.rows.first { $0.skill.name == "test-skill" }?.directCount,
    testSkillRow.directCount,
    "repeat analysis should be idempotent"
)

try """
[[skills.config]]
name = "shadow-skill"
enabled = true

[[skills.config]]
name = "legacy-dashboard"
enabled = false
""".write(to: skillConfigURL, atomically: true, encoding: .utf8)
let enabledStateOnlySnapshot = skillService.analyzeRecentWeek(
    force: false,
    automatic: false,
    now: skillNow.addingTimeInterval(2)
)
runner.checkEqual(
    enabledStateOnlySnapshot.performance.analyzedFiles,
    0,
    "enabled-state changes should reclassify neutral evidence without rereading JSONL"
)
let enabledShadowRow = runner.require(
    enabledStateOnlySnapshot.rows.first { $0.skill.name == "shadow-skill" },
    "enabled-state reclassification should preserve the Skill row"
)
runner.checkEqual(enabledShadowRow.shadowCount, 0, "an enabled Skill should not retain SHADOW classification")
runner.check(
    enabledShadowRow.suspectedMissCount >= 1,
    "neutral relevance evidence should become a suspected miss when the Skill is enabled"
)
try """
[[skills.config]]
name = "shadow-skill"
enabled = false

[[skills.config]]
name = "legacy-dashboard"
enabled = false
""".write(to: skillConfigURL, atomically: true, encoding: .utf8)
let restoredEnabledStateSnapshot = skillService.analyzeRecentWeek(
    force: false,
    automatic: false,
    now: skillNow.addingTimeInterval(3)
)
runner.checkEqual(
    restoredEnabledStateSnapshot.performance.analyzedFiles,
    0,
    "restoring enabled state should also avoid JSONL rereads"
)

let appendedStrongTurn = skillMessageLine(
    skillNow.addingTimeInterval(8),
    "user",
    "Analyze release workflows and deployment risks.",
    nil
) + skillMessageLine(
    skillNow.addingTimeInterval(8),
    "assistant",
    "Using test-skill skill.",
    "commentary"
) + skillReadLine(
    skillNow.addingTimeInterval(8),
    testSkillURL,
    ""
) + skillMessageLine(skillNow.addingTimeInterval(8), "assistant", "Completed.", "final")
let appendHandle = try FileHandle(forWritingTo: skillRolloutURL)
try appendHandle.seekToEnd()
try appendHandle.write(contentsOf: Data(appendedStrongTurn.utf8))
try appendHandle.close()
let appendedSkillSnapshot = skillService.analyzeRecentWeek(
    force: false,
    automatic: false,
    now: skillNow.addingTimeInterval(8)
)
runner.checkEqual(appendedSkillSnapshot.performance.analyzedFiles, 1, "append should rescan only the changed rollout")
runner.checkEqual(appendedSkillSnapshot.performance.unchangedFiles, 1, "append should skip the unchanged rollout")
runner.checkEqual(
    appendedSkillSnapshot.rows.first { $0.skill.name == "test-skill" }?.strongCount,
    testSkillRow.strongCount + 1,
    "append scan should add exactly one STRONG observation"
)

_ = skillService.analyzeRecentWeek(force: false, automatic: true, now: skillNow.addingTimeInterval(9))
let directBeforeThrottledAutomatic = skillService.currentSnapshot(now: skillNow.addingTimeInterval(9))
    .rows.first { $0.skill.name == "test-skill" }?.directCount
let appendedDirectTurn = skillMessageLine(
    skillNow.addingTimeInterval(10),
    "user",
    "$test-skill review release workflow",
    nil
) + skillMessageLine(skillNow.addingTimeInterval(10), "assistant", "Completed.", "final")
let throttleAppendHandle = try FileHandle(forWritingTo: skillRolloutURL)
try throttleAppendHandle.seekToEnd()
try throttleAppendHandle.write(contentsOf: Data(appendedDirectTurn.utf8))
try throttleAppendHandle.close()
let throttledAutomaticSnapshot = skillService.analyzeRecentWeek(
    force: false,
    automatic: true,
    now: skillNow.addingTimeInterval(10)
)
runner.checkEqual(
    throttledAutomaticSnapshot.rows.first { $0.skill.name == "test-skill" }?.directCount,
    directBeforeThrottledAutomatic,
    "automatic Skill analysis should not repeat inside the rolling seven-day interval"
)
let manualAfterThrottle = skillService.analyzeRecentWeek(
    force: false,
    automatic: false,
    now: skillNow.addingTimeInterval(10)
)
runner.checkEqual(
    manualAfterThrottle.rows.first { $0.skill.name == "test-skill" }?.directCount,
    (directBeforeThrottledAutomatic ?? 0) + 1,
    "manual analysis should bypass the rolling weekly automatic throttle"
)

let scanRunCountBeforeFastSnapshot = try Shell.sqliteJSON(
    database: skillDatabaseURL.path,
    query: "select count(*) as count from skill_scan_runs;",
    as: [CountRecord].self,
    readOnly: true
).first?.count
let fastPathStore = CodexUsageStore(codexDirectory: skillCodexHome, ripgrepCandidates: [])
_ = fastPathStore.loadSnapshot(
    includePeriodUsage: false,
    bypassFastCache: true,
    rateLimitSource: .localFilesOnly,
    taskHistoryRange: .day,
    now: skillNow.addingTimeInterval(10)
)
let scanRunCountAfterFastSnapshot = try Shell.sqliteJSON(
    database: skillDatabaseURL.path,
    query: "select count(*) as count from skill_scan_runs;",
    as: [CountRecord].self,
    readOnly: true
).first?.count
runner.checkEqual(
    scanRunCountAfterFastSnapshot,
    scanRunCountBeforeFastSnapshot,
    "ordinary fast Token snapshots must not invoke Skill analysis"
)

var truncatedRollout = skillSessionMetaLine(skillNow.addingTimeInterval(11), skillSessionID)
truncatedRollout += skillMessageLine(
    skillNow.addingTimeInterval(11),
    "user",
    "Review database migration rollback safety.",
    nil
)
truncatedRollout += skillMessageLine(skillNow.addingTimeInterval(11), "assistant", "Completed.", "final")
let truncateHandle = try FileHandle(forWritingTo: skillRolloutURL)
try truncateHandle.truncate(atOffset: 0)
try truncateHandle.seek(toOffset: 0)
try truncateHandle.write(contentsOf: Data(truncatedRollout.utf8))
try truncateHandle.close()
try FileManager.default.setAttributes(
    [.modificationDate: skillNow.addingTimeInterval(11)],
    ofItemAtPath: skillRolloutURL.path
)
let truncatedSkillSnapshot = skillService.analyzeRecentWeek(
    force: false,
    automatic: false,
    now: skillNow.addingTimeInterval(11)
)
runner.checkEqual(
    truncatedSkillSnapshot.rows.first { $0.skill.name == "test-skill" }?.confirmedUseCount,
    0,
    "file truncation should invalidate observations derived from the old file contents"
)

try FileManager.default.removeItem(at: skillRolloutURL)
let rotatedRollout = skillSessionMetaLine(skillNow.addingTimeInterval(12), skillSessionID)
    + skillMessageLine(skillNow.addingTimeInterval(12), "user", "$test-skill review release workflow", nil)
    + skillMessageLine(skillNow.addingTimeInterval(12), "assistant", "Completed.", "final")
try rotatedRollout.write(to: skillRolloutURL, atomically: true, encoding: .utf8)
try FileManager.default.setAttributes(
    [.modificationDate: skillNow.addingTimeInterval(12)],
    ofItemAtPath: skillRolloutURL.path
)
let rotatedSkillSnapshot = skillService.analyzeRecentWeek(
    force: false,
    automatic: false,
    now: skillNow.addingTimeInterval(12)
)
runner.checkEqual(
    rotatedSkillSnapshot.quality,
    .complete,
    "report completeness should recover after a partial rollout is replaced by a clean file"
)
runner.checkEqual(
    rotatedSkillSnapshot.rows.first { $0.skill.name == "test-skill" }?.directCount,
    1,
    "inode replacement should fully invalidate and rescan the rollout"
)

let forcedSkillSnapshot = skillService.analyzeRecentWeek(
    force: true,
    automatic: false,
    now: skillNow.addingTimeInterval(13)
)
runner.checkEqual(
    forcedSkillSnapshot.rows.first { $0.skill.name == "test-skill" }?.directCount,
    1,
    "manual reanalysis of seven days should remain idempotent"
)

let trailingSessionID = "019f5d70-0000-7000-8000-000000000003"
let trailingRolloutURL = skillSessionsDirectory
    .appendingPathComponent("rollout-2026-07-13T12-00-02-\(trailingSessionID).jsonl")
_ = try Shell.run("/usr/bin/sqlite3", [
    skillStatePath,
    """
    insert into threads(id, title, tokens_used, rollout_path, created_at, updated_at, archived)
    values(
      '\(trailingSessionID)',
      'Trailing Skill fixture',
      12000,
      '\(trailingRolloutURL.path)',
      \(Int(skillNow.addingTimeInterval(14).timeIntervalSince1970)),
      \(Int(skillNow.addingTimeInterval(14).timeIntervalSince1970)),
      0
    );
    """
])
let trailingFinalLine = skillMessageLine(
    skillNow.addingTimeInterval(14),
    "assistant",
    "Completed.",
    "final"
)
let trailingSplit = trailingFinalLine.index(
    trailingFinalLine.startIndex,
    offsetBy: trailingFinalLine.count / 2
)
let trailingPrefix = String(trailingFinalLine[..<trailingSplit])
let trailingSuffix = String(trailingFinalLine[trailingSplit...])
let trailingInitial = skillSessionMetaLine(skillNow.addingTimeInterval(14), trailingSessionID)
    + skillMessageLine(skillNow.addingTimeInterval(14), "user", "$test-skill review release workflow", nil)
    + trailingPrefix
try trailingInitial.write(to: trailingRolloutURL, atomically: true, encoding: .utf8)
let partialTailSnapshot = skillService.analyzeRecentWeek(
    force: false,
    automatic: false,
    now: skillNow.addingTimeInterval(14)
)
runner.checkEqual(partialTailSnapshot.quality, .partial, "an incomplete trailing JSONL row should be reported as PARTIAL")

let trailingAppendHandle = try FileHandle(forWritingTo: trailingRolloutURL)
try trailingAppendHandle.seekToEnd()
try trailingAppendHandle.write(contentsOf: Data(trailingSuffix.utf8))
try trailingAppendHandle.close()
let completedTailSnapshot = skillService.analyzeRecentWeek(
    force: false,
    automatic: false,
    now: skillNow.addingTimeInterval(15)
)
runner.checkEqual(completedTailSnapshot.quality, .complete, "a completed trailing JSONL row should recover to COMPLETE")
runner.checkEqual(
    completedTailSnapshot.rows.first { $0.skill.name == "test-skill" }?.directCount,
    2,
    "a retried trailing row should flush its pending turn exactly once"
)

_ = try writeSyntheticSkill(
    "test-skill",
    "test-skill",
    "Analyze release workflows and deployment risks with audit evidence."
)
let pendingCatalogSnapshot = skillService.currentSnapshot(now: skillNow.addingTimeInterval(16))
runner.checkEqual(
    pendingCatalogSnapshot.quality,
    .complete,
    "the process-lifetime catalog cache should avoid an app-server reload when merely reopening the tab"
)
let changedCatalogSnapshot = skillService.analyzeRecentWeek(
    force: false,
    automatic: false,
    now: skillNow.addingTimeInterval(16)
)
runner.checkEqual(changedCatalogSnapshot.performance.analyzedFiles, 3, "a changed Skill catalog should invalidate all current seven-day file checkpoints")
runner.checkEqual(
    changedCatalogSnapshot.rows.first { $0.skill.name == "test-skill" }?.directCount,
    2,
    "catalog invalidation should rebuild derived evidence without duplicating observations"
)
let stableCatalogSnapshot = skillService.analyzeRecentWeek(
    force: false,
    automatic: false,
    now: skillNow.addingTimeInterval(17)
)
runner.checkEqual(stableCatalogSnapshot.performance.analyzedFiles, 0, "an unchanged catalog fingerprint should preserve warm file checkpoints")

let missingConfigCatalog = SkillCatalogLoader(
    codexDirectory: skillCodexHome,
    configURL: skillInsightsRoot.appendingPathComponent("missing-config.toml"),
    skillRoots: [skillRoot]
).load(now: skillNow)
runner.checkEqual(missingConfigCatalog.quality, .partial, "missing config.toml should produce PARTIAL catalog quality")
runner.check(missingConfigCatalog.skills.allSatisfy(\.enabled), "missing config should not silently disable discovered Skills")

let invalidPathConfigURL = skillInsightsRoot.appendingPathComponent("invalid-path-config.toml")
try """
[[skills.config]]
path = "\(skillInsightsRoot.appendingPathComponent("missing-skill/SKILL.md").path)"
enabled = false
""".write(to: invalidPathConfigURL, atomically: true, encoding: .utf8)
let invalidPathCatalog = SkillCatalogLoader(
    codexDirectory: skillCodexHome,
    configURL: invalidPathConfigURL,
    skillRoots: [skillRoot]
).load(now: skillNow)
runner.checkEqual(invalidPathCatalog.quality, .partial, "invalid configured Skill path should produce PARTIAL catalog quality")

let ambiguousNameConfigURL = skillInsightsRoot.appendingPathComponent("ambiguous-name-config.toml")
try """
[[skills.config]]
name = "duplicate-skill"
enabled = false

[[skills.config]]
name = "duplicate-skill"
path = "\(duplicateOneURL.path)"
enabled = true

[features]
enabled = false
""".write(to: ambiguousNameConfigURL, atomically: true, encoding: .utf8)
let ambiguousNameCatalog = SkillCatalogLoader(
    codexDirectory: skillCodexHome,
    configURL: ambiguousNameConfigURL,
    skillRoots: [skillRoot]
).load(now: skillNow)
runner.checkEqual(ambiguousNameCatalog.quality, .partial, "a name-only config matching multiple paths should be visibly PARTIAL")
runner.checkEqual(
    ambiguousNameCatalog.skills.first { $0.path == duplicateOneURL.path }?.enabled,
    true,
    "an exact configured Skill path should override a name-only duplicate setting"
)
runner.checkEqual(
    ambiguousNameCatalog.skills.first { $0.path == duplicateTwoURL.path }?.enabled,
    false,
    "the name-only duplicate setting should still apply to the other canonical path"
)

let emptySkillHome = skillInsightsRoot.appendingPathComponent("empty-codex-home", isDirectory: true)
try FileManager.default.createDirectory(at: emptySkillHome, withIntermediateDirectories: true)
let emptySkillService = SkillInsightsService(
    codexDirectory: emptySkillHome,
    configURL: skillConfigURL,
    skillRoots: [skillRoot],
    databaseURL: skillInsightsRoot.appendingPathComponent("empty-skill-observations.sqlite")
)
let emptySkillSnapshot = emptySkillService.analyzeRecentWeek(force: true, automatic: false, now: skillNow)
runner.check(emptySkillSnapshot.lastAnalyzedAt != nil, "empty Codex Home Skill analysis should complete without crashing")
runner.checkEqual(emptySkillSnapshot.quality, .partial, "an empty Codex Home without state SQLite should report PARTIAL source completeness")
runner.checkEqual(emptySkillSnapshot.performance.modelTokens, 0, "empty Codex Home analysis should still use zero model Tokens")

let irrelevantOversizedURL = skillInsightsRoot.appendingPathComponent("irrelevant-oversized.jsonl")
let irrelevantOversizedLine = """
{"timestamp":"\(skillTimestamp(skillNow))","type":"response_item","payload":{"type":"reasoning","text":"\(String(repeating: "x", count: 32 * 1024))"}}

"""
try irrelevantOversizedLine.write(to: irrelevantOversizedURL, atomically: true, encoding: .utf8)
let irrelevantOversizedHandle = try FileHandle(forReadingFrom: irrelevantOversizedURL)
let irrelevantOversizedResult = try SkillJSONLReader.read(
    handle: irrelevantOversizedHandle,
    startOffset: 0,
    fileSize: UInt64(Data(irrelevantOversizedLine.utf8).count),
    byteBudget: UInt64(Data(irrelevantOversizedLine.utf8).count),
    maxRowBytes: 8 * 1024,
    initialDiscardingOversizedRow: false,
    wallDeadlineUptime: ProcessInfo.processInfo.systemUptime + 5,
    cpuDeadlineNanoseconds: SkillProcessResourceSnapshot.processCPUNanoseconds() + 5_000_000_000,
    shouldCancel: { false },
    process: { _, _ in }
)
try irrelevantOversizedHandle.close()
runner.checkEqual(
    irrelevantOversizedResult.skippedIrrelevantOversizedRows,
    1,
    "an oversized reasoning row should be filtered without degrading Skill evidence completeness"
)
runner.checkEqual(
    irrelevantOversizedResult.skippedOversizedRows,
    0,
    "a deterministically irrelevant oversized row should not count as an unknown relevant loss"
)

let splitIrrelevantOversizedURL = skillInsightsRoot.appendingPathComponent("split-irrelevant-oversized.jsonl")
let splitIrrelevantOversizedLine = """
{"timestamp":"\(skillTimestamp(skillNow))","type":"response_item","payload":{"type":"reasoning","text":"\(String(repeating: "y", count: 24 * 1024))"}}

"""
let splitIrrelevantOversizedBytes = UInt64(Data(splitIrrelevantOversizedLine.utf8).count)
try splitIrrelevantOversizedLine.write(
    to: splitIrrelevantOversizedURL,
    atomically: true,
    encoding: .utf8
)
let splitIrrelevantFirstHandle = try FileHandle(forReadingFrom: splitIrrelevantOversizedURL)
let splitIrrelevantFirstResult = try SkillJSONLReader.read(
    handle: splitIrrelevantFirstHandle,
    startOffset: 0,
    fileSize: splitIrrelevantOversizedBytes,
    byteBudget: 12 * 1024,
    maxRowBytes: 8 * 1024,
    initialDiscardingOversizedRow: false,
    wallDeadlineUptime: ProcessInfo.processInfo.systemUptime + 5,
    cpuDeadlineNanoseconds: SkillProcessResourceSnapshot.processCPUNanoseconds() + 5_000_000_000,
    shouldCancel: { false },
    process: { _, _ in }
)
try splitIrrelevantFirstHandle.close()
runner.check(
    splitIrrelevantFirstResult.discardingOversizedRow,
    "a split oversized row should checkpoint that the row is still being discarded"
)
runner.checkEqual(
    splitIrrelevantFirstResult.oversizedRowClassification,
    .irrelevant,
    "a split oversized row should checkpoint its deterministic classification"
)
let splitIrrelevantSecondHandle = try FileHandle(forReadingFrom: splitIrrelevantOversizedURL)
let splitIrrelevantSecondResult = try SkillJSONLReader.read(
    handle: splitIrrelevantSecondHandle,
    startOffset: splitIrrelevantFirstResult.processedOffset,
    fileSize: splitIrrelevantOversizedBytes,
    byteBudget: splitIrrelevantOversizedBytes - splitIrrelevantFirstResult.processedOffset,
    maxRowBytes: 8 * 1024,
    initialDiscardingOversizedRow: splitIrrelevantFirstResult.discardingOversizedRow,
    initialOversizedRowClassification: splitIrrelevantFirstResult.oversizedRowClassification,
    wallDeadlineUptime: ProcessInfo.processInfo.systemUptime + 5,
    cpuDeadlineNanoseconds: SkillProcessResourceSnapshot.processCPUNanoseconds() + 5_000_000_000,
    shouldCancel: { false },
    process: { _, _ in }
)
try splitIrrelevantSecondHandle.close()
runner.checkEqual(
    splitIrrelevantSecondResult.skippedIrrelevantOversizedRows,
    1,
    "an irrelevant oversized row should retain its classification across checkpoint resume"
)
runner.checkEqual(
    splitIrrelevantSecondResult.skippedOversizedRows,
    0,
    "resuming an irrelevant oversized row must not degrade it into unknown relevant loss"
)

let classificationStoreURL = skillInsightsRoot.appendingPathComponent("classification-checkpoint.sqlite")
let classificationStore = SkillObservationStore(databaseURL: classificationStoreURL)
let classificationCheckpointPath = "/synthetic/split-oversized.jsonl"
let classificationCheckpoint = SkillFileCheckpoint(
    path: classificationCheckpointPath,
    inode: 1,
    size: splitIrrelevantOversizedBytes,
    modifiedAtNanoseconds: 1,
    processedOffset: splitIrrelevantFirstResult.processedOffset,
    lastAnalyzedAt: skillNow,
    status: .partial,
    discardingOversizedRow: true,
    oversizedRowClassification: splitIrrelevantFirstResult.oversizedRowClassification,
    cursorState: .empty(sessionID: "classification-session")
)
try classificationStore.persist([], checkpoint: classificationCheckpoint)
let persistedClassificationCheckpoint = try classificationStore.checkpoints(
    for: [classificationCheckpointPath]
)[classificationCheckpointPath]
runner.checkEqual(
    persistedClassificationCheckpoint?.oversizedRowClassification,
    .irrelevant,
    "the derived SQLite checkpoint should round-trip the oversized row classification"
)

let cancelledTransactionStoreURL = skillInsightsRoot.appendingPathComponent("cancelled-transaction.sqlite")
let cancelledTransactionStore = SkillObservationStore(databaseURL: cancelledTransactionStoreURL)
let cancelledTransactionProbe = SkillCancellationProbe(cancelOnCall: 3)
var cancelledTransactionObserved = false
do {
    try cancelledTransactionStore.persist(
        [],
        checkpoint: classificationCheckpoint,
        shouldCancel: cancelledTransactionProbe.shouldCancel
    )
} catch SkillObservationStoreError.cancelled {
    cancelledTransactionObserved = true
}
runner.check(
    cancelledTransactionObserved,
    "cancellation during a derived SQLite transaction should surface as cancellation"
)
let cancelledTransactionCheckpointCount = try Shell.sqliteJSON(
    database: cancelledTransactionStoreURL.path,
    query: "select count(*) as count from skill_scan_files;",
    as: [CountRecord].self,
    readOnly: true
).first?.count
runner.checkEqual(
    cancelledTransactionCheckpointCount,
    0,
    "cancellation during persistence should roll back the checkpoint transaction"
)

let legacyCheckpointStoreURL = skillInsightsRoot.appendingPathComponent("legacy-checkpoint.sqlite")
let legacyCheckpointPath = "/synthetic/legacy-oversized.jsonl"
let legacyCursorJSON = String(
    decoding: try JSONEncoder().encode(SkillAnalysisCursorState.empty(sessionID: "legacy-checkpoint-session")),
    as: UTF8.self
)
_ = try Shell.run("/usr/bin/sqlite3", [
    legacyCheckpointStoreURL.path,
    """
    create table skill_scan_files(
      path text primary key,
      inode integer not null,
      size integer not null,
      modified_at_nanoseconds integer not null,
      processed_offset integer not null,
      last_analyzed_ms integer not null,
      status text not null,
      discarding_oversized_row integer not null default 0,
      cursor_state_json text not null
    );
    insert into skill_scan_files(
      path, inode, size, modified_at_nanoseconds, processed_offset,
      last_analyzed_ms, status, discarding_oversized_row, cursor_state_json
    ) values(
      '\(legacyCheckpointPath)', 1, \(splitIrrelevantOversizedBytes), 1,
      \(splitIrrelevantFirstResult.processedOffset), \(Int64(skillNow.timeIntervalSince1970 * 1_000)),
      'PARTIAL', 1, '\(legacyCursorJSON)'
    );
    """
])
let legacyCheckpointStore = SkillObservationStore(databaseURL: legacyCheckpointStoreURL)
let migratedLegacyCheckpoint = try legacyCheckpointStore.checkpoints(
    for: [legacyCheckpointPath]
)[legacyCheckpointPath]
runner.checkEqual(
    migratedLegacyCheckpoint?.oversizedRowClassification,
    .parse,
    "a legacy in-progress oversized row should migrate with conservative unknown classification"
)

let preCancelledDatabaseURL = skillInsightsRoot.appendingPathComponent("pre-cancelled-observations.sqlite")
let preCancelledService = SkillInsightsService(
    codexDirectory: skillCodexHome,
    configURL: skillConfigURL,
    skillRoots: [skillRoot],
    databaseURL: preCancelledDatabaseURL
)
_ = preCancelledService.analyzeRecentWeek(
    force: false,
    automatic: false,
    now: skillNow,
    shouldCancel: { true }
)
runner.check(
    !FileManager.default.fileExists(atPath: preCancelledDatabaseURL.path),
    "a pre-cancelled analysis should not open or create its derived SQLite store"
)

let cancelledHome = skillInsightsRoot.appendingPathComponent("cancelled-home", isDirectory: true)
let cancelledSessions = cancelledHome.appendingPathComponent("sessions", isDirectory: true)
try FileManager.default.createDirectory(at: cancelledSessions, withIntermediateDirectories: true)
let cancelledSessionID = "019f5d70-0000-7000-8000-000000000003"
let cancelledRolloutURL = cancelledSessions.appendingPathComponent("rollout-cancelled-\(cancelledSessionID).jsonl")
let cancelledRollout = skillJSONLine([
    "timestamp": skillTimestamp(skillNow),
    "type": "response_item",
    "payload": ["type": "reasoning", "text": String(repeating: "c", count: 2 * 1024 * 1024)]
])
try cancelledRollout.write(to: cancelledRolloutURL, atomically: true, encoding: .utf8)
let cancelledStatePath = cancelledHome.appendingPathComponent("state_5.sqlite").path
_ = try Shell.run("/usr/bin/sqlite3", [
    cancelledStatePath,
    """
    create table threads(
      id text, title text, tokens_used integer, rollout_path text,
      created_at integer, updated_at integer, archived integer default 0
    );
    insert into threads(id, title, tokens_used, rollout_path, created_at, updated_at, archived)
    values(
      '\(cancelledSessionID)', 'Cancelled fixture', 0, '\(cancelledRolloutURL.path)',
      \(Int(skillNow.timeIntervalSince1970)), \(Int(skillNow.timeIntervalSince1970)), 0
    );
    """
])
let cancelledDatabaseURL = skillInsightsRoot.appendingPathComponent("cancelled-observations.sqlite")
let cancelledService = SkillInsightsService(
    codexDirectory: cancelledHome,
    configURL: skillConfigURL,
    skillRoots: [skillRoot],
    databaseURL: cancelledDatabaseURL,
    maxRowBytes: 8 * 1024,
    maxBytesPerFilePerRun: 4 * 1024 * 1024,
    maxBytesPerRun: 4 * 1024 * 1024
)
let cancellationProbe = SkillCancellationProbe(cancelOnCall: 8)
_ = cancelledService.analyzeRecentWeek(
    force: false,
    automatic: false,
    now: skillNow,
    shouldCancel: cancellationProbe.shouldCancel
)
runner.check(
    cancellationProbe.callCount >= 8,
    "the cancellation fixture should interrupt an analysis that has already started"
)
let cancelledRunCount = try Shell.sqliteJSON(
    database: cancelledDatabaseURL.path,
    query: "select count(*) as count from skill_scan_runs;",
    as: [CountRecord].self,
    readOnly: true
).first?.count
let cancelledCheckpointCount = try Shell.sqliteJSON(
    database: cancelledDatabaseURL.path,
    query: "select count(*) as count from skill_scan_files;",
    as: [CountRecord].self,
    readOnly: true
).first?.count
let cancelledFingerprintCount = try Shell.sqliteJSON(
    database: cancelledDatabaseURL.path,
    query: "select count(*) as count from skill_metadata where key='analysis_fingerprint';",
    as: [CountRecord].self,
    readOnly: true
).first?.count
runner.checkEqual(cancelledRunCount, 0, "a cancelled analysis must not persist a completed scan run")
runner.checkEqual(cancelledCheckpointCount, 0, "a cancelled analysis must not advance file checkpoints")
runner.checkEqual(cancelledFingerprintCount, 0, "a cancelled analysis must not persist its analysis fingerprint")

let pendingHome = skillInsightsRoot.appendingPathComponent("pending-home", isDirectory: true)
let pendingSessions = pendingHome.appendingPathComponent("sessions", isDirectory: true)
try FileManager.default.createDirectory(at: pendingSessions, withIntermediateDirectories: true)
let pendingSessionID = "019f5d70-0000-7000-8000-000000000004"
let pendingRolloutURL = pendingSessions.appendingPathComponent("rollout-pending-\(pendingSessionID).jsonl")
var pendingRollout = skillSessionMetaLine(skillNow, pendingSessionID)
for index in 0..<160 {
    pendingRollout += skillJSONLine([
        "timestamp": skillTimestamp(skillNow.addingTimeInterval(Double(index) / 100)),
        "type": "response_item",
        "payload": ["type": "reasoning", "text": String(repeating: "r", count: 256)]
    ])
}
try pendingRollout.write(to: pendingRolloutURL, atomically: true, encoding: .utf8)
let pendingStatePath = pendingHome.appendingPathComponent("state_5.sqlite").path
_ = try Shell.run("/usr/bin/sqlite3", [
    pendingStatePath,
    """
    create table threads(
      id text, title text, tokens_used integer, rollout_path text,
      created_at integer, updated_at integer, archived integer default 0
    );
    insert into threads(id, title, tokens_used, rollout_path, created_at, updated_at, archived)
    values(
      '\(pendingSessionID)', 'Pending fixture', 0, '\(pendingRolloutURL.path)',
      \(Int(skillNow.timeIntervalSince1970)), \(Int(skillNow.timeIntervalSince1970)), 0
    );
    """
])
let pendingService = SkillInsightsService(
    codexDirectory: pendingHome,
    configURL: skillConfigURL,
    skillRoots: [skillRoot],
    databaseURL: skillInsightsRoot.appendingPathComponent("pending-observations.sqlite"),
    maxRowBytes: 8 * 1024,
    maxBytesPerFilePerRun: 8 * 1024,
    maxBytesPerRun: 8 * 1024
)
let pendingSnapshot = pendingService.analyzeRecentWeek(force: false, automatic: false, now: skillNow)
runner.checkEqual(pendingSnapshot.performance.pendingFiles, 1, "a clean file stopped by budget should be counted as pending")
runner.checkEqual(pendingSnapshot.performance.partialFiles, 0, "pending budget work must not be mislabeled as a damaged file")

let boundaryHome = skillInsightsRoot.appendingPathComponent("window-boundary-home", isDirectory: true)
let boundarySessions = boundaryHome.appendingPathComponent("sessions", isDirectory: true)
try FileManager.default.createDirectory(at: boundarySessions, withIntermediateDirectories: true)
let largeBoundarySessionID = "019f5d70-0000-7000-8000-000000000005"
let largeBoundaryRolloutURL = boundarySessions
    .appendingPathComponent("rollout-window-\(largeBoundarySessionID).jsonl")
let oldBoundaryDate = skillNow.addingTimeInterval(-8 * 24 * 60 * 60)
let oldReasoningLine = skillJSONLine([
    "timestamp": skillTimestamp(oldBoundaryDate),
    "type": "response_item",
    "payload": ["type": "reasoning", "text": String(repeating: "o", count: 64 * 1024)]
])
var largeBoundaryRollout = skillSessionMetaLine(oldBoundaryDate, largeBoundarySessionID)
largeBoundaryRollout += String(repeating: oldReasoningLine, count: 132)
largeBoundaryRollout += skillMessageLine(
    skillNow.addingTimeInterval(-60),
    "user",
    "$test-skill review release workflow",
    nil
)
largeBoundaryRollout += skillMessageLine(skillNow.addingTimeInterval(-60), "assistant", "Completed.", "final")
try largeBoundaryRollout.write(to: largeBoundaryRolloutURL, atomically: true, encoding: .utf8)
let boundaryStatePath = boundaryHome.appendingPathComponent("state_5.sqlite").path
_ = try Shell.run("/usr/bin/sqlite3", [
    boundaryStatePath,
    """
    create table threads(
      id text, title text, tokens_used integer, rollout_path text,
      created_at integer, updated_at integer, archived integer default 0
    );
    insert into threads(id, title, tokens_used, rollout_path, created_at, updated_at, archived)
    values(
      '\(largeBoundarySessionID)', 'Boundary locator', 0, '\(largeBoundaryRolloutURL.path)',
      \(Int(oldBoundaryDate.timeIntervalSince1970)), \(Int(skillNow.timeIntervalSince1970)), 0
    );
    """
])
let boundaryService = SkillInsightsService(
    codexDirectory: boundaryHome,
    configURL: skillConfigURL,
    skillRoots: [skillRoot],
    databaseURL: skillInsightsRoot.appendingPathComponent("window-boundary-observations.sqlite"),
    maxBytesPerFilePerRun: 16 * 1024 * 1024,
    maxBytesPerRun: 16 * 1024 * 1024
)
let locatedBoundarySnapshot = boundaryService.analyzeRecentWeek(force: false, automatic: false, now: skillNow)
runner.check(locatedBoundarySnapshot.performance.boundaryProbeBytes > 0, "an old large rollout should probe for the seven-day boundary")
runner.check(
    locatedBoundarySnapshot.performance.analyzedBytes < UInt64(Data(largeBoundaryRollout.utf8).count / 2),
    "a proven timestamp boundary should avoid rereading the old JSONL prefix"
)
runner.checkEqual(
    locatedBoundarySnapshot.rows.first { $0.skill.name == "test-skill" }?.directCount,
    1,
    "window seeking should retain the first safe recent user turn"
)

let weeklyScheduleDatabaseURL = skillInsightsRoot.appendingPathComponent("weekly-schedule.sqlite")
let weeklyScheduleStore = SkillObservationStore(databaseURL: weeklyScheduleDatabaseURL)
runner.check(weeklyScheduleStore.shouldRunAutomatically(now: skillNow), "a new Skill store should allow its first automatic analysis")
try weeklyScheduleStore.markAutomaticRun(at: skillNow)
runner.check(
    !weeklyScheduleStore.shouldRunAutomatically(now: skillNow.addingTimeInterval(7 * 24 * 60 * 60 - 1)),
    "automatic Skill analysis should remain throttled until the full rolling week elapses"
)
runner.check(
    weeklyScheduleStore.shouldRunAutomatically(now: skillNow.addingTimeInterval(7 * 24 * 60 * 60)),
    "automatic Skill analysis should become due exactly seven days after its prior attempt"
)
try weeklyScheduleStore.enforceRetention(now: skillNow)
let firstRetentionStamp = try Shell.run(
    "/usr/bin/sqlite3",
    [weeklyScheduleDatabaseURL.path, "select value from skill_metadata where key='last_retention_ms';"]
).trimmingCharacters(in: .whitespacesAndNewlines)
try weeklyScheduleStore.enforceRetention(now: skillNow.addingTimeInterval(24 * 60 * 60))
let dailyRetentionStamp = try Shell.run(
    "/usr/bin/sqlite3",
    [weeklyScheduleDatabaseURL.path, "select value from skill_metadata where key='last_retention_ms';"]
).trimmingCharacters(in: .whitespacesAndNewlines)
runner.checkEqual(dailyRetentionStamp, firstRetentionStamp, "Skill retention cleanup should run at most once per week")
try weeklyScheduleStore.enforceRetention(now: skillNow.addingTimeInterval(7 * 24 * 60 * 60))
let weeklyRetentionStamp = try Shell.run(
    "/usr/bin/sqlite3",
    [weeklyScheduleDatabaseURL.path, "select value from skill_metadata where key='last_retention_ms';"]
).trimmingCharacters(in: .whitespacesAndNewlines)
runner.check(weeklyRetentionStamp != firstRetentionStamp, "Skill retention cleanup should resume after a week")

let legacySkillDatabaseURL = skillInsightsRoot.appendingPathComponent("legacy-skill-store.sqlite")
_ = try Shell.run("/usr/bin/sqlite3", [
    legacySkillDatabaseURL.path,
    """
    create table skill_metadata(key text primary key, value text not null);
    create table skill_observations(
      id integer primary key autoincrement,
      session_id text not null,
      skill_id text not null,
      skill_name text not null,
      skill_path text not null,
      enabled integer not null,
      evidence_level text not null,
      observation_type text not null,
      observed_at_ms integer not null,
      project_id text,
      session_tokens integer,
      analyzer_version integer not null,
      quality text not null,
      source_file_path text not null,
      source_offset integer not null,
      unique(source_file_path, source_offset, skill_id, evidence_level, observation_type)
    );
    insert into skill_observations(
      session_id, skill_id, skill_name, skill_path, enabled, evidence_level,
      observation_type, observed_at_ms, analyzer_version, quality,
      source_file_path, source_offset
    ) values('legacy-session', 'legacy-skill', 'legacy', '/legacy/SKILL.md', 1,
      'INFERRED', 'suspected_miss', \(Int64(skillNow.timeIntervalSince1970 * 1_000)),
      1, 'PARTIAL', '/legacy/rollout.jsonl', 42);
    insert into skill_observations(
      session_id, skill_id, skill_name, skill_path, enabled, evidence_level,
      observation_type, observed_at_ms, analyzer_version, quality,
      source_file_path, source_offset
    ) values('legacy-session', 'legacy-skill', 'legacy', '/legacy/SKILL.md', 1,
      'INFERRED', 'relevance_match', \(Int64(skillNow.timeIntervalSince1970 * 1_000)),
      2, 'PARTIAL', '/legacy/rollout.jsonl', 42);
    create table skill_scan_runs(
      id integer primary key autoincrement,
      completed_at_ms integer not null,
      quality text not null,
      analyzed_files integer not null,
      unchanged_files integer not null,
      analyzed_lines integer not null,
      malformed_lines integer not null,
      skipped_oversized_rows integer not null,
      partial_files integer not null,
      analyzed_bytes integer not null,
      duration_ms integer not null,
      analyzer_version integer not null,
      model_tokens integer not null default 0
    );
    """
])
let migratedLegacyStore = SkillObservationStore(databaseURL: legacySkillDatabaseURL)
_ = migratedLegacyStore.storedAnalysisFingerprint()
let migratedLegacyType = try Shell.sqliteJSON(
    database: legacySkillDatabaseURL.path,
    query: "select observation_type as value from skill_observations limit 1;",
    as: [StringValueRecord].self,
    readOnly: true
).first?.value
runner.checkEqual(migratedLegacyType, "relevance_match", "legacy enabled-state evidence should migrate to neutral relevance")
let reopenedLegacyStore = SkillObservationStore(databaseURL: legacySkillDatabaseURL)
_ = reopenedLegacyStore.storedAnalysisFingerprint()
let migratedLegacyCount = try Shell.sqliteJSON(
    database: legacySkillDatabaseURL.path,
    query: "select count(*) as count from skill_observations where observation_type='relevance_match';",
    as: [CountRecord].self,
    readOnly: true
).first?.count
runner.checkEqual(migratedLegacyCount, 1, "Skill store migration should be idempotent across reopen")

let deferredHome = skillInsightsRoot.appendingPathComponent("deferred-home", isDirectory: true)
try FileManager.default.createDirectory(at: deferredHome, withIntermediateDirectories: true)
let deferredDatabaseURL = skillInsightsRoot.appendingPathComponent("deferred-observations.sqlite")
let deferredService = SkillInsightsService(
    codexDirectory: deferredHome,
    configURL: skillConfigURL,
    skillRoots: [skillRoot],
    databaseURL: deferredDatabaseURL,
    automaticDeferralReason: { "Low Power Mode is enabled" }
)
let deferredSnapshot = deferredService.analyzeRecentWeek(force: false, automatic: true, now: skillNow)
runner.check(deferredSnapshot.performance.wasDeferred, "a power-policy deferral should be visible in the machine-readable performance snapshot")
let deferredRunCount = try Shell.sqliteJSON(
    database: deferredDatabaseURL.path,
    query: "select count(*) as count from skill_scan_runs;",
    as: [CountRecord].self,
    readOnly: true
).first?.count
runner.checkEqual(deferredRunCount, 0, "a deferred automatic attempt must not create a scanner run")
let deferredSecondSnapshot = deferredService.analyzeRecentWeek(
    force: false,
    automatic: true,
    now: skillNow.addingTimeInterval(60)
)
runner.check(deferredSecondSnapshot.performance.wasDeferred, "a deferred weekly attempt should remain visible without adding retry activity")

if runner.failures > 0 {
    FileHandle.standardError.write(Data("\(runner.failures) regression test(s) failed\n".utf8))
    exit(1)
}

print(
    "Skill Insights performance: "
        + "cold=\(firstSkillSnapshot.performance.durationMilliseconds)ms/\(firstSkillSnapshot.performance.analyzedFiles)files, "
        + "warm=\(unchangedSkillSnapshot.performance.durationMilliseconds)ms/\(unchangedSkillSnapshot.performance.analyzedFiles)files/\(unchangedSkillSnapshot.performance.analyzedLines)lines, "
        + "append=\(appendedSkillSnapshot.performance.durationMilliseconds)ms/\(appendedSkillSnapshot.performance.analyzedFiles)files, "
        + "catalog=\(catalogClientDurationMilliseconds)ms, "
        + "fastSnapshotRuns=\(scanRunCountBeforeFastSnapshot ?? -1)->\(scanRunCountAfterFastSnapshot ?? -1), "
        + "modelTokens=\(firstSkillSnapshot.performance.modelTokens)"
)
print("All regression tests passed")
