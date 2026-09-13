import Foundation

/// Presentation-only token formatting for the light detail panel.  The
/// public CLI/JSON formatters intentionally keep their historical contracts;
/// this formatter is local to the HUD and uses integer arithmetic so values
/// around the 万/亿 boundary never drift through binary floating point.
enum HUDTokenFormatter {
    static func compact(_ value: Int?) -> String {
        guard let value else { return "--" }
        return compact(value)
    }

    static func compact(_ value: Int) -> String {
        let value = max(0, value)
        guard value >= 10_000 else {
            return "\(value)"
        }

        let tenThousandTenths = roundedTenths(value, unit: 10_000)
        if value < 100_000_000, tenThousandTenths < 100_000 {
            return decimal(tenThousandTenths, suffix: "万", alwaysShowDecimal: false)
        }
        return decimal(roundedTenths(value, unit: 100_000_000), suffix: "亿", alwaysShowDecimal: true)
    }

    static func sharePercent(tokens: Int?, total: Int?) -> String {
        guard let tokens, let total, tokens >= 0, total > 0, tokens <= total else {
            return "--"
        }
        if tokens == total {
            return "100.0%"
        }
        let tenths = roundedFractionTenths(numerator: tokens, denominator: total, scale: 1_000)
        return decimal(tenths, suffix: "%", alwaysShowDecimal: true)
    }

    static func shareAccessibility(tokens: Int?, total: Int?) -> String {
        guard let tokens, let total, tokens >= 0, total > 0, tokens <= total else {
            return "暂无占比"
        }
        return "占本机今日 \(sharePercent(tokens: tokens, total: total))"
    }

    static func roundedTenths(_ value: Int, unit: Int) -> Int {
        let value = max(0, value)
        let whole = value / unit
        let remainder = value % unit
        // whole*10 is safe for the units used here even at Int.max.  The
        // remainder is bounded by unit, so this multiplication is also safe.
        let roundedRemainder = (remainder * 10 + unit / 2) / unit
        return whole * 10 + roundedRemainder
    }

    private static func roundedFractionTenths(numerator: Int, denominator: Int, scale: Int) -> Int {
        let whole = numerator / denominator
        let remainder = numerator % denominator
        let product = remainder.multipliedFullWidth(by: scale)
        let division = denominator.dividingFullWidth(product)
        let half = denominator / 2 + denominator % 2
        let roundedRemainder = Int(division.quotient) + (division.remainder >= UInt(half) ? 1 : 0)
        return whole * scale + roundedRemainder
    }

    private static func decimal(_ tenths: Int, suffix: String, alwaysShowDecimal: Bool) -> String {
        let whole = tenths / 10
        let fraction = tenths % 10
        if !alwaysShowDecimal, fraction == 0 {
            return "\(whole)\(suffix)"
        }
        return "\(whole).\(fraction)\(suffix)"
    }
}

struct HUDTaskPresentation {
    static let defaultVisibleRootLimit = 5

    static func canExpand(rootCount: Int, residualTokens: Int?) -> Bool {
        rootCount > defaultVisibleRootLimit || (residualTokens ?? 0) > 0
    }

    static func todayDenominator(snapshot: UsageSnapshot) -> Int? {
        if snapshot.costUsage.hasReconciledTodayLedger {
            return snapshot.costUsage.today.tokenCount
        }
        let today = HUDTodayUsageDisplay.resolve(snapshot: snapshot)
        // A complete global bucket is not a denominator for unmatched local
        // root estimates. Only use the fallback's own current-day denominator.
        return today.isPartial ? today.tokenCount : nil
    }

    static func visibleRoots(
        from tasks: [CodexTask],
        isExpanded: Bool,
        limit: Int = defaultVisibleRootLimit
    ) -> [CodexTask] {
        guard !isExpanded else { return tasks }
        return Array(tasks.prefix(max(1, limit)))
    }

    static func runningRootCount(in tasks: [CodexTask]) -> Int {
        tasks.reduce(into: 0) { count, task in
            if task.status == .running { count += 1 }
        }
    }

    static func countSummary(
        runningCount: Int,
        visibleRootCount: Int,
        totalRootCount: Int
    ) -> String {
        "\(runningCount) 运行 · 显示 \(visibleRootCount) / \(totalRootCount)"
    }

    static func todayCaption(isReconciled: Bool) -> String {
        isReconciled
            ? "占比：本机今日总量 · 含已归因子代理"
            : "占比：本机今日总量 · 本地根任务暂估"
    }

    static func residualLocalTokens(
        summary: CostUsageSummary,
        tasks: [CodexTask],
        todayKey: String
    ) -> Int? {
        guard summary.hasReconciledTodayLedger else { return nil }
        let taskIDs = Set(tasks.map { $0.id.lowercased() })
        let residual = summary.threadDayBuckets
            .filter { $0.dayKey == todayKey && !taskIDs.contains($0.threadID.lowercased()) }
            .reduce(into: 0) { total, bucket in
                let (sum, overflow) = total.addingReportingOverflow(max(0, bucket.tokenCount))
                total = overflow ? Int.max : sum
            }
        return residual
    }
}

enum HUDDisplaySourceResolver {
    static func resolve(
        selected: NotchDisplaySource,
        remoteEnabled: Bool,
        remoteSeverity: RemoteAlertSeverity,
        newAPIEnabled: Bool,
        newAPISeverity: RemoteAlertSeverity,
        subAPIEnabled: Bool,
        subAPISeverity: RemoteAlertSeverity
    ) -> NotchDisplaySource {
        guard selected == .automatic else {
            return isEnabled(
                selected,
                remoteEnabled: remoteEnabled,
                newAPIEnabled: newAPIEnabled,
                subAPIEnabled: subAPIEnabled
            ) ? selected : .codex
        }

        let externalSources: [(NotchDisplaySource, RemoteAlertSeverity)] = [
            remoteEnabled ? (.remoteCodex, remoteSeverity) : nil,
            newAPIEnabled ? (.newAPI, newAPISeverity) : nil,
            subAPIEnabled ? (.subAPI, subAPISeverity) : nil
        ].compactMap { $0 }
        return externalSources
            .filter { $0.1 != .none }
            .sorted { $0.1 > $1.1 }
            .first?.0 ?? .codex
    }

    private static func isEnabled(
        _ source: NotchDisplaySource,
        remoteEnabled: Bool,
        newAPIEnabled: Bool,
        subAPIEnabled: Bool
    ) -> Bool {
        switch source {
        case .automatic, .codex:
            true
        case .remoteCodex:
            remoteEnabled
        case .newAPI:
            newAPIEnabled
        case .subAPI:
            subAPIEnabled
        }
    }
}

struct HUDPresentationVisibility: Equatable {
    let showsFloatingHUD: Bool
    let showsMenuBarItem: Bool

    init(showsFloatingHUD: Bool, showsMenuBarItem: Bool) {
        self.showsFloatingHUD = showsFloatingHUD
        self.showsMenuBarItem = showsMenuBarItem
    }

    init(mode: HUDDisplayMode) {
        switch mode {
        case .floatingHUD:
            self.init(showsFloatingHUD: true, showsMenuBarItem: false)
        case .menuBar:
            self.init(showsFloatingHUD: false, showsMenuBarItem: true)
        }
    }
}

struct HUDTodayUsageDisplay: Equatable {
    let tokenCount: Int?
    let isPartial: Bool
    let missingBaselineSessions: Int
    let isBackfilling: Bool

    static func resolve(snapshot: UsageSnapshot) -> HUDTodayUsageDisplay {
        if snapshot.costUsage.tokenQuality == .complete,
           let publishedTokenCount = snapshot.costUsage.today.tokenCount {
            return HUDTodayUsageDisplay(
                tokenCount: publishedTokenCount,
                isPartial: false,
                missingBaselineSessions: 0,
                isBackfilling: false
            )
        }

        let dailyUsage = snapshot.dailyUsage
        let usesCurrentLocalDay = dailyUsage.timeZoneIdentifier == TimeZone.current.identifier
            && Calendar.current.isDateInToday(dailyUsage.dayStartedAt)
        let hasFallback = usesCurrentLocalDay
            && (dailyUsage.usageTodayTokens > 0
                || dailyUsage.isPartial
                || dailyUsage.missingBaselineSessions > 0)
        return HUDTodayUsageDisplay(
            tokenCount: hasFallback ? dailyUsage.usageTodayTokens : nil,
            isPartial: hasFallback,
            missingBaselineSessions: hasFallback ? dailyUsage.missingBaselineSessions : 0,
            isBackfilling: !hasFallback && snapshot.costUsage.today.isPartial
        )
    }

    func helpText(label: String) -> String? {
        if isBackfilling {
            return "\(label)正在核验本地完整历史，完成前不显示零值。"
        }
        guard isPartial else {
            return nil
        }
        if missingBaselineSessions > 0 {
            return "\(label)有 \(missingBaselineSessions) 个会话缺少历史基线；当前为本地日快照暂估值，尚未与完整发布账本对齐。"
        }
        return "\(label)为现有本地日快照的暂估值，尚未与完整发布账本对齐。"
    }
}
