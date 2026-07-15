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

    static func resolve(snapshot: UsageSnapshot) -> HUDTodayUsageDisplay {
        if let publishedTokenCount = snapshot.costUsage.today.tokenCount {
            return HUDTodayUsageDisplay(
                tokenCount: publishedTokenCount,
                isPartial: false,
                missingBaselineSessions: 0
            )
        }

        let dailyUsage = snapshot.dailyUsage
        return HUDTodayUsageDisplay(
            tokenCount: dailyUsage.usageTodayTokens > 0 || dailyUsage.isPartial
                ? dailyUsage.usageTodayTokens
                : nil,
            isPartial: dailyUsage.isPartial,
            missingBaselineSessions: dailyUsage.missingBaselineSessions
        )
    }
}
