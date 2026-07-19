import Combine
import Foundation

@MainActor
final class UsageViewModel: ObservableObject {
    private enum DetailCadence {
        static let activeRefreshInterval: TimeInterval = 15
        static let idleRefreshInterval: TimeInterval = 90
        static let summaryContextTaskLimit = 4
        static let detailContextTaskLimit = 12
    }

    @Published private(set) var snapshot: UsageSnapshot = .empty
    @Published private(set) var isRefreshing = false
    @Published private(set) var isCostUsageRefreshing = false

    private let store: CodexUsageStore
    private let settings: CodexNotchSettings
    private let refreshCoordinator = RefreshCoordinator<RefreshLane>()
    private var fastTimer: Timer?
    private var usageTimer: Timer?
    private var appServerRateLimitTimer: Timer?
    private var pendingSnapshotTimer: Timer?
    private var pendingUsageTimer: Timer?
    private var costUsageContinuationTimer: Timer?
    private var watcherRefreshTimer: Timer?
    private var settingsChangeTimer: Timer?
    private var cancellables: Set<AnyCancellable> = []
    private var completionFollowUpTimers: [Timer] = []
    private var fileChangeRefreshTimers: [Timer] = []
    private var fileWatchers: [CodexFileWatcher] = []
    private var watchedPaths: [String] = []
    private var pendingSnapshotBypassFastCache = false
    private var lastFileChangeRefreshScheduledAt: Date = .distantPast
    private var observedSettings: LocalUsageSettingsSnapshot?
    private var isDetailVisible = false
    private var isSourceVisible = false
    private var lastSnapshotSuccessfulAt: Date?
    private var lastUsageSuccessfulAt: Date?
    private var publishedCostLoadGeneration = 0

    init(store: CodexUsageStore = CodexUsageStore(), settings: CodexNotchSettings = CodexNotchSettings()) {
        self.store = store
        self.settings = settings
        requestSnapshot(bypassFastCache: true, reason: .startup)
        scheduleUsageRefresh(after: 20)
        scheduleWatcherRefresh(after: 20)
        refreshAppServerRateLimits(force: true, reason: .startup)
        observeSettings()
        observeRefreshEnvironment()
    }

    func setDetailVisible(_ visible: Bool) {
        guard isDetailVisible != visible else {
            return
        }
        isDetailVisible = visible
        rescheduleFastRefreshForVisibilityChange()
    }

    func setSourceVisible(_ visible: Bool) {
        guard isSourceVisible != visible else {
            return
        }
        isSourceVisible = visible
        rescheduleFastRefreshForVisibilityChange()
    }

    func refresh(bypassFastCache: Bool = false) {
        requestSnapshot(
            bypassFastCache: bypassFastCache,
            reason: .manual,
            mode: .coalesce
        )
    }

    func refreshWhenPresented(now: Date = Date()) {
        let snapshotFreshness = AdaptiveRefreshPolicy.freshness(
            lastSuccessfulAt: lastSnapshotSuccessfulAt,
            now: now,
            maximumAge: snapshot.isRunning
                ? DetailCadence.activeRefreshInterval
                : DetailCadence.idleRefreshInterval
        )
        let usageFreshness = AdaptiveRefreshPolicy.freshness(
            lastSuccessfulAt: lastUsageSuccessfulAt,
            now: now,
            maximumAge: settings.adaptiveRefreshEnabled
                ? AdaptiveRefreshPolicy.normalBackgroundInterval
                : max(1, settings.usageRefreshInterval)
        )

        if snapshotFreshness.requiresRefresh {
            requestSnapshot(bypassFastCache: true, reason: .presentation)
            if settings.rateLimitSource == .appServerFirst {
                refreshAppServerRateLimits(reason: .presentation)
            }
        } else {
            rescheduleFastRefreshForVisibilityChange()
        }
        if usageFreshness.requiresRefresh {
            refreshUsageTotals(reason: .presentation)
        }
    }

    private func requestSnapshot(
        bypassFastCache: Bool = false,
        reason: RefreshReason,
        mode: RefreshRequestMode = .coalesce
    ) {
        if mode == .replace {
            pendingSnapshotBypassFastCache = false
        }
        let start = refreshCoordinator.begin(.localSnapshot, reason: reason, mode: mode)
        guard case let .started(token) = start else {
            pendingSnapshotBypassFastCache = pendingSnapshotBypassFastCache || bypassFastCache
            return
        }
        fastTimer?.invalidate()
        fastTimer = nil
        pendingSnapshotTimer?.invalidate()
        pendingSnapshotTimer = nil
        updateRefreshingState()
        let fallbackUsage = currentUsage
        let rateLimitSource = settings.rateLimitSource
        let taskHistoryRange = settings.taskHistoryRange
        let includeContextUsage = settings.showContextMetrics
        let contextTaskLimit = currentContextTaskLimit

        let task = Task.detached(priority: .utility) { [store, fallbackUsage, bypassFastCache, rateLimitSource, taskHistoryRange, includeContextUsage, contextTaskLimit] in
            let nextSnapshot = store.loadSnapshot(
                includePeriodUsage: false,
                fallbackUsage: fallbackUsage,
                bypassFastCache: bypassFastCache,
                rateLimitSource: rateLimitSource,
                taskHistoryRange: taskHistoryRange,
                includeContextUsage: includeContextUsage,
                contextTaskLimit: contextTaskLimit
            )
            await MainActor.run {
                let completion = self.refreshCoordinator.complete(token)
                guard completion.isCurrent else {
                    self.updateRefreshingState()
                    return
                }
                let wasRunning = self.snapshot.isRunning
                var mergedSnapshot = self.stabilizedSnapshot(nextSnapshot)
                if mergedSnapshot.usage1h == nil {
                    mergedSnapshot.usage1h = self.snapshot.usage1h
                }
                mergedSnapshot.usage24h = self.snapshot.usage24h
                mergedSnapshot.usage7d = self.snapshot.usage7d
                mergedSnapshot.usage30d = self.snapshot.usage30d
                mergedSnapshot.periodUsageQuality = self.snapshot.periodUsageQuality
                mergedSnapshot.dailyUsage = self.snapshot.dailyUsage
                mergedSnapshot.costUsage = self.snapshot.costUsage
                mergedSnapshot.tasks = mergedSnapshot.tasks.map {
                    $0.withTodaySharePercent(totalTokens: mergedSnapshot.dailyUsage.usageTodayTokens)
                }
                mergedSnapshot.monitorStats.lastUsageDurationMs = self.snapshot.monitorStats.lastUsageDurationMs
                mergedSnapshot.monitorStats.watchedPathCount = self.snapshot.monitorStats.watchedPathCount
                self.snapshot = mergedSnapshot
                if nextSnapshot.errorMessage == nil {
                    self.lastSnapshotSuccessfulAt = nextSnapshot.lastUpdated
                }
                self.updateRefreshingState()
                let shouldBypassFastCache = self.pendingSnapshotBypassFastCache
                self.pendingSnapshotBypassFastCache = false
                if wasRunning && !self.snapshot.isRunning {
                    self.scheduleCompletionFollowUp()
                }
                if completion.shouldRunPending {
                    self.schedulePendingSnapshotRefresh(bypassFastCache: shouldBypassFastCache)
                } else {
                    self.scheduleFastRefresh()
                }
            }
        }
        refreshCoordinator.attach(task, to: token)
    }

    func refreshAll(forceRateLimitRefresh: Bool = true) {
        refreshUsageTotals(reason: .manual, mode: .replace)
        if settings.rateLimitSource == .appServerFirst {
            if forceRateLimitRefresh {
                refreshAppServerRateLimits(force: true, reason: .manual, mode: .replace)
            } else {
                requestSnapshot(bypassFastCache: true, reason: .manual, mode: .replace)
                refreshAppServerRateLimits(reason: .manual, mode: .replace)
            }
        } else {
            requestSnapshot(bypassFastCache: true, reason: .manual, mode: .replace)
        }
    }

    func loadPublishedCostUsageWhenPresented() {
        publishedCostLoadGeneration += 1
        let generation = publishedCostLoadGeneration
        guard settings.showPeriodUsage else {
            snapshot.costUsage = .unavailable
            return
        }
        let store = store
        Task { [weak self] in
            let summary = await Task.detached(priority: .utility) {
                store.loadCostUsageSummary()
            }.value
            guard let self,
                  self.settings.showPeriodUsage,
                  generation == self.publishedCostLoadGeneration else {
                return
            }
            self.snapshot.costUsage = summary
        }
    }

    func refreshLocalTokenAnalytics() {
        publishedCostLoadGeneration += 1
        guard settings.showPeriodUsage else {
            snapshot.costUsage = .unavailable
            return
        }
        refreshCostUsage(reason: .manual, mode: .replace, invalidatePublishedCostLoad: false)
    }

    private func refreshUsageTotals(
        reason: RefreshReason,
        mode: RefreshRequestMode = .coalesce
    ) {
        // Both this lane and the cost lane can publish a newer cost snapshot.
        // Invalidate any presentation load before either async operation starts.
        publishedCostLoadGeneration += 1
        refreshCostUsage(reason: reason, mode: mode, invalidatePublishedCostLoad: false)
        let start = refreshCoordinator.begin(.usageTotals, reason: reason, mode: mode)
        guard case let .started(token) = start else {
            return
        }
        usageTimer?.invalidate()
        usageTimer = nil
        pendingUsageTimer?.invalidate()
        pendingUsageTimer = nil
        updateRefreshingState()

        let showsPeriodUsage = settings.showPeriodUsage
        let task = Task.detached(priority: .utility) { [store, showsPeriodUsage] in
            let startedAt = Date()
            let usageHistory = store.loadUsageTotalsAndDailyWithQuality()
            let costUsage = showsPeriodUsage
                ? store.loadCostUsageSummary()
                : CostUsageSummary.unavailable
            let durationMs = max(0, Int((Date().timeIntervalSince(startedAt) * 1_000).rounded()))
            await MainActor.run {
                let completion = self.refreshCoordinator.complete(token)
                guard completion.isCurrent else {
                    self.updateRefreshingState()
                    return
                }
                self.snapshot.usage24h = usageHistory.usage.day
                self.snapshot.usage7d = usageHistory.usage.week
                self.snapshot.usage30d = usageHistory.usage.month
                self.snapshot.periodUsageQuality = usageHistory.quality
                self.snapshot.dailyUsage = usageHistory.daily
                self.snapshot.tasks = self.snapshot.tasks.map {
                    $0.withTodaySharePercent(totalTokens: usageHistory.daily.usageTodayTokens)
                }
                self.lastUsageSuccessfulAt = Date()
                self.snapshot.costUsage = costUsage
                self.snapshot.monitorStats.lastUsageDurationMs = durationMs
                self.updateRefreshingState()
                if completion.shouldRunPending {
                    self.schedulePendingUsageRefresh()
                } else {
                    self.scheduleUsageRefresh()
                }
            }
        }
        refreshCoordinator.attach(task, to: token)
    }

    private func refreshCostUsage(
        reason: RefreshReason,
        mode: RefreshRequestMode = .coalesce,
        isContinuation: Bool = false,
        invalidatePublishedCostLoad: Bool = true
    ) {
        if invalidatePublishedCostLoad {
            publishedCostLoadGeneration += 1
        }
        costUsageContinuationTimer?.invalidate()
        costUsageContinuationTimer = nil
        let environment = RefreshEnvironment.current
        guard CostUsageRefreshPolicy.shouldRequestRefresh(
            showsPeriodUsage: settings.showPeriodUsage,
            reason: reason,
            environment: environment
        ) else {
            if !settings.showPeriodUsage || environment.isConstrained {
                refreshCoordinator.invalidate(.costUsage)
                isCostUsageRefreshing = false
            }
            if !settings.showPeriodUsage {
                snapshot.costUsage = .unavailable
            }
            return
        }

        let start = refreshCoordinator.begin(.costUsage, reason: reason, mode: mode)
        guard case let .started(token) = start else {
            return
        }
        isCostUsageRefreshing = true
        let bypassCadence = reason == .manual || isContinuation
        let task = Task { [store] in
            let result = await CostUsageScanExecutor.run { shouldCancel in
                let metrics = store.refreshCostUsageSlice(
                    bypassCadence: bypassCadence,
                    reuseExistingCandidates: isContinuation,
                    shouldCancel: shouldCancel
                )
                return (metrics: metrics, summary: store.loadCostUsageSummary())
            }
            let completion = refreshCoordinator.complete(token)
            guard completion.isCurrent else {
                return
            }
            isCostUsageRefreshing = false
            snapshot.costUsage = result.summary
            if completion.shouldRunPending {
                refreshCostUsage(reason: reason)
            } else if let delay = CostUsageRefreshPolicy.continuationDelay(after: result.metrics) {
                scheduleCostUsageContinuation(after: delay)
            }
        }
        refreshCoordinator.attach(task, to: token)
    }

    private func scheduleCostUsageContinuation(after delay: TimeInterval) {
        costUsageContinuationTimer?.invalidate()
        guard settings.showPeriodUsage,
              !RefreshEnvironment.current.isConstrained else {
            costUsageContinuationTimer = nil
            return
        }
        let timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.costUsageContinuationTimer = nil
                self?.refreshCostUsage(reason: .timer, isContinuation: true)
            }
        }
        timer.tolerance = min(0.5, delay * 0.1)
        costUsageContinuationTimer = timer
    }

    private func scheduleFastRefresh() {
        let fixedInterval = currentFixedFastRefreshInterval
        let decision = AdaptiveRefreshPolicy.localSnapshot(
            adaptiveEnabled: settings.adaptiveRefreshEnabled,
            isVisible: isSourceCurrentlyVisible,
            isRunning: snapshot.isRunning,
            environment: .current,
            fixedInterval: fixedInterval
        )
        RefreshShadowMetrics.shared.recordSchedule(
            lane: .localSnapshot,
            fixedInterval: fixedInterval,
            candidateInterval: decision.candidateInterval
        )
        let interval = decision.interval
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.requestSnapshot(reason: .timer)
            }
        }
        timer.tolerance = interval * 0.35
        fastTimer = timer
    }

    private func schedulePendingSnapshotRefresh(bypassFastCache: Bool) {
        fastTimer?.invalidate()
        fastTimer = nil
        pendingSnapshotTimer?.invalidate()

        let interval = currentRefreshDecision.interval
        let delay = RefreshCadence.pendingSnapshotDelay(for: interval)
        let timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.pendingSnapshotTimer = nil
                self?.requestSnapshot(bypassFastCache: bypassFastCache, reason: .timer)
            }
        }
        timer.tolerance = min(1, delay * 0.35)
        pendingSnapshotTimer = timer
    }

    private func scheduleUsageRefresh(after delay: TimeInterval? = nil) {
        usageTimer?.invalidate()
        let fixedInterval = delay ?? settings.usageRefreshInterval
        let decision = delay == nil
            ? AdaptiveRefreshPolicy.localBackground(
                adaptiveEnabled: settings.adaptiveRefreshEnabled,
                environment: .current,
                fixedInterval: fixedInterval
            )
            : RefreshCadenceDecision(
                interval: fixedInterval,
                candidateInterval: fixedInterval,
                reasonCode: "startup_delay"
            )
        if delay == nil {
            RefreshShadowMetrics.shared.recordSchedule(
                lane: .usageTotals,
                fixedInterval: fixedInterval,
                candidateInterval: decision.candidateInterval
            )
        }
        let interval = decision.interval
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.refreshUsageTotals(reason: .timer)
            }
        }
        timer.tolerance = min(30, max(5, interval * 0.35))
        usageTimer = timer
    }

    private func schedulePendingUsageRefresh() {
        usageTimer?.invalidate()
        usageTimer = nil
        pendingUsageTimer?.invalidate()

        let delay = RefreshCadence.pendingUsageDelay(for: settings.usageRefreshInterval)
        let timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.pendingUsageTimer = nil
                self?.refreshUsageTotals(reason: .timer)
            }
        }
        timer.tolerance = min(5, delay * 0.35)
        pendingUsageTimer = timer
    }

    private func scheduleWatcherRefresh(after delay: TimeInterval? = nil) {
        watcherRefreshTimer?.invalidate()
        let fixedInterval = delay ?? settings.watcherRefreshInterval
        let decision = delay == nil
            ? AdaptiveRefreshPolicy.localBackground(
                adaptiveEnabled: settings.adaptiveRefreshEnabled,
                environment: .current,
                fixedInterval: fixedInterval
            )
            : RefreshCadenceDecision(
                interval: fixedInterval,
                candidateInterval: fixedInterval,
                reasonCode: "startup_delay"
            )
        if delay == nil {
            RefreshShadowMetrics.shared.recordSchedule(
                lane: .watchPaths,
                fixedInterval: fixedInterval,
                candidateInterval: decision.candidateInterval
            )
        }
        let interval = decision.interval
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.refreshWatchPaths(reason: .timer)
            }
        }
        timer.tolerance = min(30, max(3, interval * 0.35))
        watcherRefreshTimer = timer
    }

    private func scheduleCompletionFollowUp() {
        completionFollowUpTimers.forEach { $0.invalidate() }
        completionFollowUpTimers = [8, 30].map { delay in
            let timer = Timer.scheduledTimer(withTimeInterval: TimeInterval(delay), repeats: false) { [weak self] _ in
                Task { @MainActor in
                    self?.requestSnapshot(bypassFastCache: true, reason: .fileEvent, mode: .enqueue)
                }
            }
            timer.tolerance = min(5, TimeInterval(delay) * 0.35)
            return timer
        }
    }

    private func scheduleAppServerRateLimitRefresh(after delay: TimeInterval? = nil) {
        appServerRateLimitTimer?.invalidate()
        appServerRateLimitTimer = nil
        guard settings.rateLimitSource == .appServerFirst else {
            return
        }

        let interval = max(1, delay ?? store.appServerRefreshDelay())
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.refreshAppServerRateLimits(reason: .timer)
            }
        }
        timer.tolerance = min(10, max(1, interval * 0.1))
        appServerRateLimitTimer = timer
    }

    private func refreshAppServerRateLimits(
        force: Bool = false,
        reason: RefreshReason,
        mode: RefreshRequestMode = .coalesce
    ) {
        appServerRateLimitTimer?.invalidate()
        appServerRateLimitTimer = nil
        guard settings.rateLimitSource == .appServerFirst else {
            refreshCoordinator.invalidate(.appServerQuota)
            return
        }
        let start = refreshCoordinator.begin(.appServerQuota, reason: reason, mode: mode)
        guard case let .started(token) = start else {
            return
        }

        let task = Task.detached(priority: .utility) { [store] in
            let refreshed = store.refreshAppServerRateLimits(force: force)
            let nextDelay = store.appServerRefreshDelay()
            await MainActor.run {
                let completion = self.refreshCoordinator.complete(token)
                guard completion.isCurrent else {
                    return
                }
                if refreshed || force {
                    self.requestSnapshot(
                        bypassFastCache: true,
                        reason: reason,
                        mode: .enqueue
                    )
                }
                if completion.shouldRunPending {
                    self.refreshAppServerRateLimits(
                        force: false,
                        reason: reason
                    )
                } else {
                    self.scheduleAppServerRateLimitRefresh(after: nextDelay)
                }
            }
        }
        refreshCoordinator.attach(task, to: token)
    }

    private func refreshWatchPaths(
        reason: RefreshReason,
        mode: RefreshRequestMode = .coalesce
    ) {
        let start = refreshCoordinator.begin(.watchPaths, reason: reason, mode: mode)
        guard case let .started(token) = start else {
            return
        }
        let task = Task.detached(priority: .utility) { [store] in
            let paths = store.rateLimitWatchPaths()
            await MainActor.run {
                let completion = self.refreshCoordinator.complete(token)
                guard completion.isCurrent else {
                    return
                }
                self.installFileWatchers(for: paths)
                self.snapshot.monitorStats.watchedPathCount = self.watchedPaths.count
                if completion.shouldRunPending {
                    self.refreshWatchPaths(reason: reason)
                } else {
                    self.scheduleWatcherRefresh()
                }
            }
        }
        refreshCoordinator.attach(task, to: token)
    }

    private func installFileWatchers(for paths: [String]) {
        let normalizedPaths = Array(Set(paths.filter { !$0.isEmpty })).sorted()
        guard normalizedPaths != watchedPaths else {
            return
        }

        fileWatchers.forEach { $0.cancel() }
        fileWatchers.removeAll()

        var installedPaths: [String] = []
        var installedWatchers: [CodexFileWatcher] = []

        for path in normalizedPaths {
            guard let watcher = CodexFileWatcher(path: path, onChange: { [weak self] in
                Task { @MainActor in
                    self?.scheduleFileChangeRefresh()
                }
            }) else {
                continue
            }
            installedPaths.append(path)
            installedWatchers.append(watcher)
        }

        watchedPaths = installedPaths
        fileWatchers = installedWatchers
    }

    private func scheduleFileChangeRefresh() {
        let now = Date()
        guard now.timeIntervalSince(lastFileChangeRefreshScheduledAt) >= settings.fileChangeRefreshMinimumGap else {
            return
        }
        lastFileChangeRefreshScheduledAt = now

        fileChangeRefreshTimers.forEach { $0.invalidate() }
        let delay = max(1, settings.fileChangeRefreshMinimumGap)
        let timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.requestSnapshot(bypassFastCache: true, reason: .fileEvent, mode: .enqueue)
                self?.refreshWatchPaths(reason: .fileEvent, mode: .enqueue)
                self?.refreshCostUsage(reason: .fileEvent, mode: .coalesce)
            }
        }
        timer.tolerance = min(5, delay * 0.35)
        fileChangeRefreshTimers = [timer]
    }

    private func observeSettings() {
        observedSettings = LocalUsageSettingsSnapshot(settings: settings)
        settings.objectWillChange
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    Task { @MainActor in
                        self?.settingsMayHaveChanged()
                    }
                }
            }
            .store(in: &cancellables)
    }

    private func observeRefreshEnvironment() {
        Publishers.Merge(
            NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange),
            NotificationCenter.default.publisher(for: ProcessInfo.thermalStateDidChangeNotification)
        )
        .sink { [weak self] _ in
            Task { @MainActor in
                self?.refreshEnvironmentDidChange()
            }
        }
        .store(in: &cancellables)
    }

    private func settingsMayHaveChanged() {
        let next = LocalUsageSettingsSnapshot(settings: settings)
        guard next != observedSettings else {
            return
        }
        observedSettings = next
        scheduleSettingsRefresh()
    }

    private func scheduleSettingsRefresh() {
        settingsChangeTimer?.invalidate()

        let timer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.settingsDidChange()
            }
        }
        timer.tolerance = 0.15
        settingsChangeTimer = timer
    }

    private func settingsDidChange() {
        settingsChangeTimer?.invalidate()
        settingsChangeTimer = nil
        fastTimer?.invalidate()
        fastTimer = nil
        usageTimer?.invalidate()
        usageTimer = nil
        appServerRateLimitTimer?.invalidate()
        appServerRateLimitTimer = nil
        pendingSnapshotTimer?.invalidate()
        pendingSnapshotTimer = nil
        pendingUsageTimer?.invalidate()
        pendingUsageTimer = nil
        costUsageContinuationTimer?.invalidate()
        costUsageContinuationTimer = nil
        watcherRefreshTimer?.invalidate()
        watcherRefreshTimer = nil
        refreshCoordinator.invalidateAll([
            .localSnapshot,
            .usageTotals,
            .costUsage,
            .watchPaths,
            .appServerQuota
        ])
        isCostUsageRefreshing = false
        updateRefreshingState()

        refreshUsageTotals(reason: .settings, mode: .replace)
        refreshWatchPaths(reason: .settings, mode: .replace)
        if settings.rateLimitSource == .appServerFirst {
            refreshAppServerRateLimits(force: true, reason: .settings, mode: .replace)
        } else {
            requestSnapshot(bypassFastCache: true, reason: .settings, mode: .replace)
        }
    }

    private func refreshEnvironmentDidChange() {
        if RefreshEnvironment.current.isConstrained {
            costUsageContinuationTimer?.invalidate()
            costUsageContinuationTimer = nil
            refreshCoordinator.invalidate(.costUsage)
            isCostUsageRefreshing = false
        }
        guard settings.adaptiveRefreshEnabled else {
            return
        }
        fastTimer?.invalidate()
        fastTimer = nil
        usageTimer?.invalidate()
        usageTimer = nil
        watcherRefreshTimer?.invalidate()
        watcherRefreshTimer = nil
        if !refreshCoordinator.isInFlight(.localSnapshot) {
            scheduleFastRefresh()
        }
        if !refreshCoordinator.isInFlight(.usageTotals) {
            scheduleUsageRefresh()
        }
        if !refreshCoordinator.isInFlight(.watchPaths) {
            scheduleWatcherRefresh()
        }
    }

    private func rescheduleFastRefreshForVisibilityChange() {
        fastTimer?.invalidate()
        fastTimer = nil
        pendingSnapshotTimer?.invalidate()
        pendingSnapshotTimer = nil
        if !refreshCoordinator.isInFlight(.localSnapshot) {
            scheduleFastRefresh()
        }
    }

    private var currentUsage: PeriodUsage {
        PeriodUsage(
            day: snapshot.usage24h,
            week: snapshot.usage7d,
            month: snapshot.usage30d
        )
    }

    private var currentFixedFastRefreshInterval: TimeInterval {
        let foldedInterval = snapshot.isRunning ? settings.activeRefreshInterval : settings.idleRefreshInterval
        guard isDetailVisible else {
            return foldedInterval
        }

        let detailInterval = snapshot.isRunning
            ? DetailCadence.activeRefreshInterval
            : DetailCadence.idleRefreshInterval
        return min(foldedInterval, detailInterval)
    }

    private var currentRefreshDecision: RefreshCadenceDecision {
        AdaptiveRefreshPolicy.localSnapshot(
            adaptiveEnabled: settings.adaptiveRefreshEnabled,
            isVisible: isSourceCurrentlyVisible,
            isRunning: snapshot.isRunning,
            environment: .current,
            fixedInterval: currentFixedFastRefreshInterval
        )
    }

    private var isSourceCurrentlyVisible: Bool {
        isSourceVisible || isDetailVisible
    }

    private var currentContextTaskLimit: Int {
        isDetailVisible ? DetailCadence.detailContextTaskLimit : DetailCadence.summaryContextTaskLimit
    }

    private func updateRefreshingState() {
        isRefreshing = refreshCoordinator.hasAnyInFlight(in: [.localSnapshot, .usageTotals])
    }

    private func stabilizedSnapshot(_ next: UsageSnapshot) -> UsageSnapshot {
        var snapshot = next
        let previous = self.snapshot

        snapshot.stabilizeQuota(from: previous)

        if snapshot.monitorStats.lastRateLimitSource == "none"
            || snapshot.monitorStats.lastRateLimitSource == "error" {
            snapshot.monitorStats.lastRateLimitSource = previous.monitorStats.lastRateLimitSource
            snapshot.rateLimitCapturedAt = previous.rateLimitCapturedAt
        }

        if snapshot.errorMessage != nil,
           snapshot.usage1h == nil,
           snapshot.usage24h == 0,
           snapshot.usage7d == 0,
           snapshot.usage30d == 0,
           previous.usage30d > 0 {
            snapshot.usage1h = previous.usage1h
            snapshot.usage24h = previous.usage24h
            snapshot.usage7d = previous.usage7d
            snapshot.usage30d = previous.usage30d
        }

        if snapshot.errorMessage != nil {
            if snapshot.sparkQuotaWindows.isEmpty {
                snapshot.sparkQuotaWindows = previous.sparkQuotaWindows
            }
            if snapshot.tasks.isEmpty {
                snapshot.tasks = previous.tasks.map { task in
                    CodexTask(
                        id: task.id,
                        title: task.title,
                        status: task.status == .running ? .recent : task.status,
                        detail: task.detail,
                        tokenCount: task.tokenCount,
                        updatedAt: task.updatedAt,
                        activeSubagentCount: task.activeSubagentCount,
                        delta10mTokens: task.delta10mTokens,
                        delta1hTokens: task.delta1hTokens,
                        todayTokens: task.todayTokens,
                        todaySharePercent: task.todaySharePercent,
                        contextInputTokens: task.contextInputTokens,
                        contextWindowTokens: task.contextWindowTokens,
                        contextPercent: task.contextPercent,
                        contextUpdatedAt: task.contextUpdatedAt
                    )
                }
            }
            snapshot.isRunning = false
            snapshot.errorMessage = nil
        }

        return snapshot
    }
}

private struct LocalUsageSettingsSnapshot: Equatable {
    let activeRefreshInterval: TimeInterval
    let idleRefreshInterval: TimeInterval
    let usageRefreshInterval: TimeInterval
    let watcherRefreshInterval: TimeInterval
    let fileChangeRefreshMinimumGap: TimeInterval
    let adaptiveRefreshEnabled: Bool
    let rateLimitSource: RateLimitSourcePreference
    let showContextMetrics: Bool
    let showPeriodUsage: Bool
    let taskHistoryRange: TaskHistoryRange

    @MainActor
    init(settings: CodexNotchSettings) {
        activeRefreshInterval = settings.activeRefreshInterval
        idleRefreshInterval = settings.idleRefreshInterval
        usageRefreshInterval = settings.usageRefreshInterval
        watcherRefreshInterval = settings.watcherRefreshInterval
        fileChangeRefreshMinimumGap = settings.fileChangeRefreshMinimumGap
        adaptiveRefreshEnabled = settings.adaptiveRefreshEnabled
        rateLimitSource = settings.rateLimitSource
        showContextMetrics = settings.showContextMetrics
        showPeriodUsage = settings.showPeriodUsage
        taskHistoryRange = settings.taskHistoryRange
    }
}

@MainActor
final class OverlayState: ObservableObject {
    @Published var isExpanded = false
}
