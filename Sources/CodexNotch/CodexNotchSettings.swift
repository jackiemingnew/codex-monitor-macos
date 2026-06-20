import Foundation
import ServiceManagement

protocol LaunchAtLoginManaging {
    var isEnabled: Bool { get }
    func setEnabled(_ enabled: Bool) throws
}

private struct SMAppServiceLaunchAtLoginManager: LaunchAtLoginManaging {
    var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    func setEnabled(_ enabled: Bool) throws {
        if enabled {
            if SMAppService.mainApp.status != .enabled {
                try SMAppService.mainApp.register()
            }
        } else if SMAppService.mainApp.status == .enabled {
            try SMAppService.mainApp.unregister()
        }
    }
}

@MainActor
final class CodexNotchSettings: ObservableObject {
    static let cliproxyKeychainService = "com.alight.codexnotch.cliproxy.management-key"
    static let cliproxyKeychainAccount = "default"

    private enum Keys {
        static let activeRefreshInterval = "activeRefreshInterval"
        static let idleRefreshInterval = "idleRefreshInterval"
        static let usageRefreshInterval = "usageRefreshInterval"
        static let watcherRefreshInterval = "watcherRefreshInterval"
        static let fileChangeRefreshMinimumGap = "fileChangeRefreshMinimumGap"
        static let rateLimitSource = "rateLimitSource"
        static let showPeriodUsage = "showPeriodUsage"
        static let enablePulse = "enablePulse"
        static let taskHistoryRange = "taskHistoryRange"
        static let remoteMonitorEnabled = "remoteMonitorEnabled"
        static let cliproxyPanelURL = "cliproxyPanelURL"
        static let cliproxyRefreshInterval = "cliproxyRefreshInterval"
        static let cliproxyRequestTimeout = "cliproxyRequestTimeout"
        static let cliproxyAllowInsecureTLS = "cliproxyAllowInsecureTLS"
    }

    private let defaults: UserDefaults
    private let launchAtLoginManager: LaunchAtLoginManaging

    @Published var activeRefreshInterval: TimeInterval {
        didSet {
            normalizeActiveRefreshInterval()
        }
    }

    @Published var idleRefreshInterval: TimeInterval {
        didSet {
            normalizeIdleRefreshInterval()
        }
    }

    @Published var usageRefreshInterval: TimeInterval {
        didSet {
            normalizeUsageRefreshInterval()
        }
    }

    @Published var watcherRefreshInterval: TimeInterval {
        didSet {
            normalizeWatcherRefreshInterval()
        }
    }

    @Published var fileChangeRefreshMinimumGap: TimeInterval {
        didSet {
            normalizeFileChangeRefreshMinimumGap()
        }
    }

    @Published var rateLimitSource: RateLimitSourcePreference {
        didSet {
            defaults.set(rateLimitSource.rawValue, forKey: Keys.rateLimitSource)
        }
    }

    @Published var showPeriodUsage: Bool {
        didSet {
            defaults.set(showPeriodUsage, forKey: Keys.showPeriodUsage)
        }
    }

    @Published var enablePulse: Bool {
        didSet {
            defaults.set(enablePulse, forKey: Keys.enablePulse)
        }
    }

    @Published var taskHistoryRange: TaskHistoryRange {
        didSet {
            defaults.set(taskHistoryRange.rawValue, forKey: Keys.taskHistoryRange)
        }
    }

    @Published var remoteMonitorEnabled: Bool {
        didSet {
            defaults.set(remoteMonitorEnabled, forKey: Keys.remoteMonitorEnabled)
        }
    }

    @Published var cliproxyPanelURL: String {
        didSet {
            let trimmed = cliproxyPanelURL.trimmingCharacters(in: .whitespacesAndNewlines)
            if cliproxyPanelURL != trimmed {
                cliproxyPanelURL = trimmed
                return
            }
            if Self.managementOrigin(from: oldValue) != Self.managementOrigin(from: trimmed),
               !oldValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               !cliproxyManagementKey.isEmpty {
                cliproxyManagementKey = ""
            }
            defaults.set(trimmed, forKey: Keys.cliproxyPanelURL)
        }
    }

    @Published var cliproxyManagementKey: String {
        didSet {
            persistCliproxyManagementKey()
        }
    }

    @Published var cliproxyRefreshInterval: TimeInterval {
        didSet {
            normalizeCliproxyRefreshInterval()
        }
    }

    @Published var cliproxyRequestTimeout: TimeInterval {
        didSet {
            normalizeCliproxyRequestTimeout()
        }
    }

    @Published var cliproxyAllowInsecureTLS: Bool {
        didSet {
            if oldValue != cliproxyAllowInsecureTLS, !cliproxyManagementKey.isEmpty {
                cliproxyManagementKey = ""
            }
            defaults.set(cliproxyAllowInsecureTLS, forKey: Keys.cliproxyAllowInsecureTLS)
        }
    }

    @Published private(set) var launchAtLoginEnabled: Bool
    @Published private(set) var launchAtLoginError: String?
    @Published private(set) var cliproxyKeychainError: String?

    init(
        defaults: UserDefaults = .standard,
        initialManagementKey: String? = nil,
        launchAtLoginManager: LaunchAtLoginManaging = SMAppServiceLaunchAtLoginManager()
    ) {
        self.defaults = defaults
        self.launchAtLoginManager = launchAtLoginManager
        self.activeRefreshInterval = Self.clamped(defaults.object(forKey: Keys.activeRefreshInterval) as? TimeInterval ?? 3, min: 2, max: 30)
        self.idleRefreshInterval = Self.clamped(defaults.object(forKey: Keys.idleRefreshInterval) as? TimeInterval ?? 6, min: 4, max: 120)
        self.usageRefreshInterval = Self.clamped(defaults.object(forKey: Keys.usageRefreshInterval) as? TimeInterval ?? 30, min: 15, max: 300)
        self.watcherRefreshInterval = Self.clamped(defaults.object(forKey: Keys.watcherRefreshInterval) as? TimeInterval ?? 12, min: 8, max: 120)
        self.fileChangeRefreshMinimumGap = Self.clamped(defaults.object(forKey: Keys.fileChangeRefreshMinimumGap) as? TimeInterval ?? 3, min: 1, max: 30)
        self.rateLimitSource = RateLimitSourcePreference(rawValue: defaults.string(forKey: Keys.rateLimitSource) ?? "") ?? .appServerFirst
        self.showPeriodUsage = defaults.object(forKey: Keys.showPeriodUsage) as? Bool ?? true
        self.enablePulse = defaults.object(forKey: Keys.enablePulse) as? Bool ?? true
        self.taskHistoryRange = TaskHistoryRange(rawValue: defaults.string(forKey: Keys.taskHistoryRange) ?? "") ?? .threeDays
        self.remoteMonitorEnabled = defaults.object(forKey: Keys.remoteMonitorEnabled) as? Bool ?? false
        self.cliproxyPanelURL = defaults.string(forKey: Keys.cliproxyPanelURL) ?? ""
        self.cliproxyManagementKey = initialManagementKey ?? ((try? KeychainStore.read(
            service: Self.cliproxyKeychainService,
            account: Self.cliproxyKeychainAccount
        )) ?? "")
        self.cliproxyRefreshInterval = Self.clamped(defaults.object(forKey: Keys.cliproxyRefreshInterval) as? TimeInterval ?? 60, min: 60, max: 3_600)
        self.cliproxyRequestTimeout = Self.clamped(defaults.object(forKey: Keys.cliproxyRequestTimeout) as? TimeInterval ?? 6, min: 3, max: 30)
        self.cliproxyAllowInsecureTLS = defaults.object(forKey: Keys.cliproxyAllowInsecureTLS) as? Bool ?? false
        self.launchAtLoginEnabled = launchAtLoginManager.isEnabled
    }

    func setLaunchAtLoginEnabled(_ enabled: Bool) {
        do {
            try launchAtLoginManager.setEnabled(enabled)
            launchAtLoginError = nil
        } catch {
            launchAtLoginError = error.localizedDescription
        }

        launchAtLoginEnabled = launchAtLoginManager.isEnabled
    }

    func resetRefreshDefaults() {
        activeRefreshInterval = 3
        idleRefreshInterval = 6
        usageRefreshInterval = 30
        watcherRefreshInterval = 12
        fileChangeRefreshMinimumGap = 3
    }

    static func managementKeyForSave(
        draftKey: String,
        oldPanelURL: String,
        newPanelURL: String,
        oldAllowsInsecureTLS: Bool,
        newAllowsInsecureTLS: Bool,
        remoteEnabled: Bool
    ) -> String {
        guard remoteEnabled else {
            return ""
        }

        let oldOrigin = managementOrigin(from: oldPanelURL)
        let newOrigin = managementOrigin(from: newPanelURL)
        let originChanged = oldOrigin != nil && newOrigin != nil && oldOrigin != newOrigin
        let tlsModeChanged = oldAllowsInsecureTLS != newAllowsInsecureTLS
        guard !originChanged, !tlsModeChanged else {
            return ""
        }

        return draftKey
    }

    private func persistCliproxyManagementKey() {
        do {
            try KeychainStore.write(
                cliproxyManagementKey,
                service: Self.cliproxyKeychainService,
                account: Self.cliproxyKeychainAccount
            )
            cliproxyKeychainError = nil
        } catch {
            cliproxyKeychainError = error.localizedDescription
        }
    }

    private func normalizeActiveRefreshInterval() {
        let value = normalized(
            activeRefreshInterval,
            min: 2,
            max: 30,
            key: Keys.activeRefreshInterval
        )
        if activeRefreshInterval != value {
            activeRefreshInterval = value
        }
    }

    private func normalizeIdleRefreshInterval() {
        let value = normalized(
            idleRefreshInterval,
            min: 4,
            max: 120,
            key: Keys.idleRefreshInterval
        )
        if idleRefreshInterval != value {
            idleRefreshInterval = value
        }
    }

    private func normalizeUsageRefreshInterval() {
        let value = normalized(
            usageRefreshInterval,
            min: 15,
            max: 300,
            key: Keys.usageRefreshInterval
        )
        if usageRefreshInterval != value {
            usageRefreshInterval = value
        }
    }

    private func normalizeWatcherRefreshInterval() {
        let value = normalized(
            watcherRefreshInterval,
            min: 8,
            max: 120,
            key: Keys.watcherRefreshInterval
        )
        if watcherRefreshInterval != value {
            watcherRefreshInterval = value
        }
    }

    private func normalizeFileChangeRefreshMinimumGap() {
        let value = normalized(
            fileChangeRefreshMinimumGap,
            min: 1,
            max: 30,
            key: Keys.fileChangeRefreshMinimumGap
        )
        if fileChangeRefreshMinimumGap != value {
            fileChangeRefreshMinimumGap = value
        }
    }

    private func normalizeCliproxyRefreshInterval() {
        let value = normalized(
            cliproxyRefreshInterval,
            min: 60,
            max: 3_600,
            key: Keys.cliproxyRefreshInterval
        )
        if cliproxyRefreshInterval != value {
            cliproxyRefreshInterval = value
        }
    }

    private func normalizeCliproxyRequestTimeout() {
        let value = normalized(
            cliproxyRequestTimeout,
            min: 3,
            max: 30,
            key: Keys.cliproxyRequestTimeout
        )
        if cliproxyRequestTimeout != value {
            cliproxyRequestTimeout = value
        }
    }

    private func normalized(
        _ value: TimeInterval,
        min: TimeInterval,
        max: TimeInterval,
        key: String
    ) -> TimeInterval {
        let normalized = Self.clamped(value, min: min, max: max)
        defaults.set(normalized, forKey: key)
        return normalized
    }

    private static func clamped(_ value: TimeInterval, min: TimeInterval, max: TimeInterval) -> TimeInterval {
        Swift.min(max, Swift.max(min, value.rounded()))
    }

    private static func managementOrigin(from input: String) -> String? {
        guard let url = CLIProxyAPIClient.managementBaseURL(from: input),
              let scheme = url.scheme,
              let host = url.host else {
            return nil
        }
        let port = url.port.map { ":\($0)" } ?? ""
        return "\(scheme)://\(host.lowercased())\(port)"
    }
}
