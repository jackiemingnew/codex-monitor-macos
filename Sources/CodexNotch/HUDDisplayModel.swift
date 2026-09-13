import Foundation

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
