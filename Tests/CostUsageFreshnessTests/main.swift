import Foundation
import SQLite3

// HUDDisplayModel keeps these presentation-only types in other application
// sources; the fast test supplies their minimal public shape while exercising
// the real Today resolver below.
enum RemoteAlertSeverity: Int, Comparable, Equatable {
    case none
    case warning
    case error

    static func < (lhs: RemoteAlertSeverity, rhs: RemoteAlertSeverity) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

enum HUDDisplayMode {
    case floatingHUD
    case menuBar
}

final class TestRunner {
    private(set) var failures = 0

    func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            failures += 1
            FileHandle.standardError.write(Data("FAILED: \(message)\n".utf8))
            return
        }
    }
}

func localDate(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
    var components = DateComponents()
    components.calendar = Calendar.current
    components.timeZone = .current
    components.year = year
    components.month = month
    components.day = day
    components.hour = hour
    components.minute = minute
    return Calendar.current.date(from: components)!
}

func costFixture(timestamp: Int) -> String {
    """
    {"timestamp":\(timestamp),"type":"turn_context","payload":{"model":"gpt-5.6-sol"}}
    {"timestamp":\(timestamp + 1),"type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":120,"cached_input_tokens":20,"output_tokens":40},"total_token_usage":{"input_tokens":120,"cached_input_tokens":20,"output_tokens":40}}}}
    """
}

let runner = TestRunner()
let temporaryRoot = ProcessInfo.processInfo.environment["COST_USAGE_FRESHNESS_TMP"]
    ?? NSTemporaryDirectory()
let root = URL(fileURLWithPath: temporaryRoot)
    .appendingPathComponent("CodexNotchCostUsageFreshness-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: root) }

let publishedAt = localDate(2024, 12, 31, 23, 55)
let requestedAt = localDate(2025, 1, 1, 0, 5)
let sessionID = "11111111-1111-4111-8111-111111111111"
let rollout = root.appendingPathComponent("rollout-\(sessionID).jsonl")
try Data((costFixture(timestamp: Int(publishedAt.timeIntervalSince1970)) + "\n").utf8).write(to: rollout)
try FileManager.default.setAttributes([.modificationDate: publishedAt], ofItemAtPath: rollout.path)

let estimator = CostUsageEstimator(databasePath: root.appendingPathComponent("usage-deltas.sqlite").path)
estimator.updateCandidates([CostUsageSessionCandidate(sessionID: sessionID, path: rollout.path)], inventoryTruncated: false)
let initialScan = estimator.scanSlice(now: publishedAt, bypassCadence: true)
runner.check(initialScan.isComplete, "fixture must publish a complete source day")

let staleSummary = estimator.loadSummary(now: requestedAt)
runner.check(staleSummary.quality == .partial, "a prior local-day publication must backfill instead of claiming an empty Today complete")
runner.check(staleSummary.tokenQuality == .partial, "a prior local-day publication must not authorize the root Today ledger")
runner.check(staleSummary.today.tokenCount == nil, "a prior local-day publication must not publish zero Today Token")
runner.check(staleSummary.lastUpdated == publishedAt, "backfill must retain the last publication time")

let warmScan = estimator.scanSlice(now: requestedAt, bypassCadence: true)
runner.check(warmScan.stopReason == .caughtUp, "unchanged complete inventory should remain caught up")
runner.check(warmScan.jsonlBytesRead == 0, "cross-day coverage advance must not reread JSONL")
runner.check(warmScan.databaseWrites == 1, "cross-day coverage advance must only write metadata")
let zeroToday = estimator.loadSummary(now: requestedAt)
runner.check(zeroToday.tokenQuality == .complete, "a complete same-day coverage advance may verify a genuine zero Today")
runner.check(zeroToday.today.tokenCount == 0, "a complete same-day coverage advance must expose genuine zero Today")
let sameDayWarmScan = estimator.scanSlice(now: requestedAt.addingTimeInterval(60), bypassCadence: true)
runner.check(sameDayWarmScan.jsonlBytesRead == 0 && sameDayWarmScan.databaseWrites == 0, "same-day warm coverage must not reread or rewrite")

var legacyDatabase: OpaquePointer?
guard sqlite3_open(root.appendingPathComponent("usage-deltas.sqlite").path, &legacyDatabase) == SQLITE_OK else {
    fatalError("cannot open isolated legacy fixture")
}
let removedCoverage = sqlite3_exec(legacyDatabase, "DELETE FROM delta_cache_metadata WHERE key='cost_published_coverage_at_ms';", nil, nil, nil)
sqlite3_close(legacyDatabase)
runner.check(removedCoverage == SQLITE_OK, "legacy fixture must remove only coverage metadata")
runner.check(estimator.loadSummary(now: requestedAt).today.tokenCount == nil, "legacy publication without coverage metadata must not display zero")
let submillisecondRequest = requestedAt.addingTimeInterval(0.0008)
let migratedCoverage = estimator.scanSlice(now: submillisecondRequest, bypassCadence: true)
runner.check(migratedCoverage.jsonlBytesRead == 0 && migratedCoverage.databaseWrites == 1, "legacy coverage migration must validate checkpoints without JSONL replay")
runner.check(estimator.loadSummary(now: submillisecondRequest).today.tokenCount == 0, "metadata precision must not round verified coverage into the future")

let crossMidnightRoot = root.appendingPathComponent("cross-midnight")
try FileManager.default.createDirectory(at: crossMidnightRoot, withIntermediateDirectories: true)
let generationStartedAt = localDate(2024, 12, 31, 23, 59)
let generationPublishedAt = localDate(2025, 1, 1, 0, 7)
let crossMidnightSession = "22222222-2222-4222-8222-222222222222"
let crossMidnightRollout = crossMidnightRoot.appendingPathComponent("rollout-\(crossMidnightSession).jsonl")
try Data((costFixture(timestamp: Int(generationStartedAt.timeIntervalSince1970)) + "\n").utf8).write(to: crossMidnightRollout)
try FileManager.default.setAttributes([.modificationDate: generationStartedAt], ofItemAtPath: crossMidnightRollout.path)
let crossMidnightEstimator = CostUsageEstimator(databasePath: crossMidnightRoot.appendingPathComponent("usage-deltas.sqlite").path)
crossMidnightEstimator.updateCandidates(
    [CostUsageSessionCandidate(sessionID: crossMidnightSession, path: crossMidnightRollout.path)],
    inventoryTruncated: false
)
let yieldedGeneration = crossMidnightEstimator.scanSlice(
    now: generationStartedAt,
    budget: CostUsageScanBudget(maxBytes: 0, maxCPUNanoseconds: 50_000_000, maxWallTime: 0.250, maxRowBytes: 256 * 1024),
    bypassCadence: true
)
runner.check(!yieldedGeneration.isComplete, "zero-byte first slice must retain its frozen generation")
let finishedGeneration = crossMidnightEstimator.scanSlice(now: generationPublishedAt, bypassCadence: true)
runner.check(finishedGeneration.isComplete, "the frozen cross-midnight generation must eventually publish")
let crossMidnightSummary = crossMidnightEstimator.loadSummary(now: generationPublishedAt)
runner.check(crossMidnightSummary.quality == .partial, "a generation started before midnight must not turn its old coverage into new-day zero")
runner.check(crossMidnightSummary.today.tokenCount == nil, "cross-midnight publication must retain a missing Today instead of zero")

let dstCalendar = Calendar(identifier: .gregorian)
let newYork = TimeZone(identifier: "America/New_York")!
runner.check(
    CostUsagePublicationFreshness.isCurrent(
        coverageAt: Date(timeIntervalSince1970: 1_710_054_000),
        requestedAt: Date(timeIntervalSince1970: 1_710_068_400),
        calendar: dstCalendar,
        timeZone: newYork
    ),
    "same local DST day must remain current"
)
runner.check(
    !CostUsagePublicationFreshness.isCurrent(
        coverageAt: Date(timeIntervalSince1970: 1_710_054_000),
        requestedAt: Date(timeIntervalSince1970: 1_710_140_400),
        calendar: dstCalendar,
        timeZone: newYork
    ),
    "next local DST day must become stale"
)
runner.check(
    !CostUsagePublicationFreshness.isCurrent(
        coverageAt: Date(timeIntervalSince1970: 1_735_689_540),
        requestedAt: Date(timeIntervalSince1970: 1_735_689_480),
        calendar: Calendar.current,
        timeZone: .current
    ),
    "future coverage metadata must fail closed even on the same local day"
)

let budgetLimited = CostUsageScanMetrics(
    jsonlBytesRead: 1,
    filesAdvanced: 1,
    databaseWrites: 1,
    skippedOversizedRows: 0,
    stopReason: .byteBudget,
    isComplete: false
)
runner.check(
    CostUsageContinuationSchedulingPolicy.timerDisposition(
        reason: .presentation,
        mode: .coalesce,
        requestAllowed: false
    ) == .preserve,
    "presentation rejection must preserve an existing continuation"
)
runner.check(
    CostUsageContinuationSchedulingPolicy.timerDisposition(
        reason: .fileEvent,
        mode: .coalesce,
        requestAllowed: true
    ) == .preserve,
    "coalesced file events must preserve an existing continuation deadline"
)
runner.check(
    CostUsageContinuationSchedulingPolicy.timerDisposition(
        reason: .timer,
        mode: .coalesce,
        requestAllowed: true
    ) == .preserve,
    "coalesced timer requests must preserve an existing continuation deadline"
)
runner.check(
    CostUsageContinuationSchedulingPolicy.timerDisposition(
        reason: .manual,
        mode: .replace,
        requestAllowed: true
    ) == .cancel,
    "explicit manual replacement may cancel an existing continuation"
)
runner.check(
    CostUsageContinuationSchedulingPolicy.timerDisposition(
        reason: .settings,
        mode: .replace,
        requestAllowed: false
    ) == .cancel,
    "disabled period usage may cancel an existing continuation"
)
runner.check(
    CostUsageContinuationSchedulingPolicy.timerDisposition(
        reason: .timer,
        mode: .coalesce,
        requestAllowed: false
    ) == .cancel,
    "a power- or thermal-constrained request may cancel an existing continuation"
)
runner.check(
    CostUsageContinuationSchedulingPolicy.completionDisposition(
        metrics: budgetLimited,
        hasPendingRequest: true
    ) == .scheduleContinuation,
    "a budget-limited result must keep its continuation ahead of pending cadence work"
)

var unavailableTodaySnapshot = UsageSnapshot.empty
unavailableTodaySnapshot.costUsage = .backfilling(lastUpdated: publishedAt)
let unavailableTodayDisplay = HUDTodayUsageDisplay.resolve(snapshot: unavailableTodaySnapshot)
runner.check(unavailableTodayDisplay.tokenCount == nil && unavailableTodayDisplay.isBackfilling, "backfilling Today without a current local fallback must stay unavailable")
runner.check(unavailableTodayDisplay.helpText(label: "今日")?.contains("不显示零值") == true, "backfilling Today help must disclose that zero is withheld")

var provisionalTodaySnapshot = UsageSnapshot.empty
provisionalTodaySnapshot.costUsage = .backfilling(lastUpdated: publishedAt)
provisionalTodaySnapshot.dailyUsage = DailyUsage(
    usageTodayTokens: 77,
    dayStartedAt: Calendar.current.startOfDay(for: Date()),
    timeZoneIdentifier: TimeZone.current.identifier,
    isPartial: false,
    missingBaselineSessions: 0
)
let provisionalTodayDisplay = HUDTodayUsageDisplay.resolve(snapshot: provisionalTodaySnapshot)
runner.check(provisionalTodayDisplay.tokenCount == 77 && provisionalTodayDisplay.isPartial, "current root-only Today fallback must be marked provisional")
runner.check(Formatters.apiEquivalentCost(.backfilling) == "回填中", "missing complete Token coverage remains backfilling")
runner.check(
    Formatters.apiEquivalentCost(CostEstimateWindow(usd: nil, isPartial: true, tokenCount: 77)) == "未定价",
    "complete Token with no model price must be labeled unpriced instead of backfilling"
)

if runner.failures > 0 {
    exit(1)
}
print("CostUsageFreshnessTests passed (warm jsonlBytesRead=\(warmScan.jsonlBytesRead) databaseWrites=\(warmScan.databaseWrites))")
