import Foundation

// The focused presentation test compiles the real HUD model helpers without
// pulling in SwiftUI or the application target. These small stand-ins keep
// the test independent of the app's settings and monitor view models.
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

private func task(_ index: Int, status: TaskStatus = .idle) -> CodexTask {
    CodexTask(
        id: "root-\(index)",
        title: "Root \(index)",
        status: status,
        detail: "本地快照",
        tokenCount: index * 10,
        updatedAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(index))
    )
}

private func threadBucket(dayKey: String, threadID: String, tokenCount: Int) -> CostUsageThreadDayBucket {
    CostUsageThreadDayBucket(
        dayKey: dayKey,
        threadID: threadID,
        tokenCount: tokenCount,
        ownTokenCount: tokenCount,
        subagentTokenCount: 0,
        sessionCount: 1
    )
}

let runner = TestRunner()

runner.check(HUDTokenFormatter.compact(9_999) == "9999", "values below one万 stay exact")
runner.check(HUDTokenFormatter.compact(10_000) == "1万", "one万 omits a redundant decimal")
runner.check(HUDTokenFormatter.compact(12_345) == "1.2万", "万 values use one decimal")
runner.check(HUDTokenFormatter.compact(99_999_499) == "9999.9万", "万 boundary rounds below carry")
runner.check(HUDTokenFormatter.compact(99_999_500) == "1.0亿", "万 boundary carries into 亿")
runner.check(HUDTokenFormatter.compact(100_000_000) == "1.0亿", "亿 values retain one decimal")
runner.check(HUDTokenFormatter.compact(Int.max) == "92233720368.5亿", "Int.max formats without overflow")
runner.check(HUDTokenFormatter.compact(nil) == "--", "missing tokens stay unknown")
runner.check(HUDTokenFormatter.compact(0) == "0", "a real zero stays distinct from missing")

runner.check(HUDTokenFormatter.sharePercent(tokens: nil, total: 100) == "--", "missing numerator has no share")
runner.check(HUDTokenFormatter.sharePercent(tokens: 0, total: 0) == "--", "zero denominator has no share")
runner.check(HUDTokenFormatter.sharePercent(tokens: 101, total: 100) == "--", "tokens above total are invalid")
runner.check(HUDTokenFormatter.sharePercent(tokens: -1, total: 100) == "--", "negative tokens are invalid")
runner.check(HUDTokenFormatter.sharePercent(tokens: 0, total: 100) == "0.0%", "zero share is explicit when denominator exists")
runner.check(HUDTokenFormatter.sharePercent(tokens: 1, total: 40) == "2.5%", "share uses half-up tenths")
runner.check(HUDTokenFormatter.sharePercent(tokens: Int.max / 2, total: Int.max) == "50.0%", "large share avoids multiplication overflow")
runner.check(HUDTokenFormatter.shareAccessibility(tokens: nil, total: 100) == "暂无占比", "unknown share help is honest")

var zeroTodaySnapshot = UsageSnapshot.empty
zeroTodaySnapshot.costUsage = CostUsageSummary(
    today: CostEstimateWindow(usd: nil, isPartial: false, tokenCount: 0),
    sevenDays: CostEstimateWindow(usd: nil, isPartial: false, tokenCount: 0),
    thirtyDays: CostEstimateWindow(usd: nil, isPartial: false, tokenCount: 0),
    quality: .complete,
    lastUpdated: nil,
    usesSparkProxy: false,
    tokenQuality: .complete
)
let zeroTodayDisplay = HUDTodayUsageDisplay.resolve(snapshot: zeroTodaySnapshot)
runner.check(zeroTodayDisplay.tokenCount == 0 && !zeroTodayDisplay.isBackfilling, "verified zero Today remains visible")

var missingTodaySnapshot = UsageSnapshot.empty
missingTodaySnapshot.costUsage = .backfilling(lastUpdated: nil)
let missingTodayDisplay = HUDTodayUsageDisplay.resolve(snapshot: missingTodaySnapshot)
runner.check(missingTodayDisplay.tokenCount == nil && missingTodayDisplay.isBackfilling, "missing Today stays backfilling instead of becoming zero")

runner.check(
    HUDTaskPresentation.todayCaption(isReconciled: true) == "占比：本机今日总量 · 含已归因子代理",
    "reconciled caption distinguishes child attribution"
)
runner.check(
    HUDTaskPresentation.todayCaption(isReconciled: false) == "占比：本机今日总量 · 本地根任务暂估",
    "fallback caption distinguishes root-only estimate"
)

let roots = (0..<7).map { task($0, status: $0 < 2 ? .running : .idle) }
let collapsedRoots = HUDTaskPresentation.visibleRoots(from: roots, isExpanded: false)
runner.check(collapsedRoots.count == 5, "collapsed task table shows five roots")
runner.check(collapsedRoots.map(\.id) == Array(roots.prefix(5)).map(\.id), "collapsed roots preserve snapshot order")
runner.check(
    HUDTaskPresentation.visibleRoots(from: roots, isExpanded: true).count == 7,
    "expanded task table reveals the existing snapshot roots"
)
runner.check(
    HUDTaskPresentation.countSummary(runningCount: 2, visibleRootCount: 5, totalRootCount: 7) == "2 运行 · 显示 5 / 7",
    "task count summary reports running and visible root counts"
)

let todayKey = "2026-09-13"
let completeSummary = CostUsageSummary(
    today: CostEstimateWindow(usd: nil, isPartial: false, tokenCount: 100),
    sevenDays: CostEstimateWindow(usd: nil, isPartial: false, tokenCount: 100),
    thirtyDays: CostEstimateWindow(usd: nil, isPartial: false, tokenCount: 100),
    quality: .complete,
    lastUpdated: nil,
    usesSparkProxy: false,
    tokenQuality: .complete,
    threadDayBuckets: [
        threadBucket(dayKey: todayKey, threadID: "ROOT-0", tokenCount: 60),
        threadBucket(dayKey: todayKey, threadID: "root-1", tokenCount: 30),
        threadBucket(dayKey: todayKey, threadID: "unlisted-local-record", tokenCount: 10)
    ]
)
runner.check(completeSummary.hasReconciledTodayLedger, "matching published bucket sum is reconciled")
runner.check(
    HUDTaskPresentation.residualLocalTokens(summary: completeSummary, tasks: Array(roots.prefix(2)), todayKey: todayKey) == 10,
    "residual row sums only today's snapshot-missing threads"
)
runner.check(
    HUDTaskPresentation.residualLocalTokens(summary: completeSummary, tasks: roots, todayKey: "2026-09-12") == 0,
    "residual row stays zero for a different day"
)
let partialSummary = CostUsageSummary(
    today: CostEstimateWindow(usd: nil, isPartial: true, tokenCount: 100),
    sevenDays: .backfilling,
    thirtyDays: .backfilling,
    quality: .partial,
    lastUpdated: nil,
    usesSparkProxy: false,
    tokenQuality: .partial,
    threadDayBuckets: completeSummary.threadDayBuckets
)
runner.check(
    HUDTaskPresentation.residualLocalTokens(summary: partialSummary, tasks: roots, todayKey: todayKey) == nil,
    "residual row is withheld before reconciliation"
)

runner.check(HUDTaskPresentation.canExpand(rootCount: 2, residualTokens: 10), "residual evidence is reachable even with fewer than five roots")
runner.check(!HUDTaskPresentation.canExpand(rootCount: 2, residualTokens: nil), "small root list does not need expansion")
var denominatorSnapshot = UsageSnapshot.empty
denominatorSnapshot.costUsage = completeSummary
runner.check(HUDTaskPresentation.todayDenominator(snapshot: denominatorSnapshot) == 100, "reconciled shares use the global ledger total")
denominatorSnapshot.costUsage = CostUsageSummary(
    today: CostEstimateWindow(usd: nil, isPartial: false, tokenCount: 100),
    sevenDays: .unavailable, thirtyDays: .unavailable, quality: .complete,
    lastUpdated: nil, usesSparkProxy: false, tokenQuality: .complete
)
runner.check(HUDTaskPresentation.todayDenominator(snapshot: denominatorSnapshot) == nil, "unmatched root estimates cannot use a complete global bucket as denominator")
denominatorSnapshot.costUsage = .unavailable
denominatorSnapshot.dailyUsage = DailyUsage(
    usageTodayTokens: 50, dayStartedAt: Calendar.current.startOfDay(for: Date()),
    timeZoneIdentifier: TimeZone.current.identifier, isPartial: true, missingBaselineSessions: 0
)
runner.check(HUDTaskPresentation.todayDenominator(snapshot: denominatorSnapshot) == 50, "current-day fallback uses its own denominator")
denominatorSnapshot.dailyUsage.dayStartedAt = Date(timeIntervalSince1970: 0)
runner.check(HUDTaskPresentation.todayDenominator(snapshot: denominatorSnapshot) == nil, "stale fallback has no current-day denominator")

if runner.failures > 0 {
    exit(1)
}
print("LightDetailPresentationTests passed")
