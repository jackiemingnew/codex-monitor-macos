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
