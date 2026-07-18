import Combine
import Foundation

@MainActor
final class PerformanceMonitorViewModel: ObservableObject {
    static let refreshInterval: TimeInterval = 5
    static let retainedSampleCount = 120

    @Published private(set) var samples: [PerformanceSample] = []
    @Published private(set) var isRefreshing = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var backgroundMonitoringEnabled: Bool

    private let historyStore: PerformanceHistoryStore
    private var refreshTimer: Timer?
    private var refreshTask: Task<Void, Never>?
    private var generation = 0
    private var lastMemoryPressureAttemptAt: Date?
    private var settingsCancellable: AnyCancellable?

    init(
        settings: CodexNotchSettings,
        historyStore: PerformanceHistoryStore = .shared
    ) {
        self.historyStore = historyStore
        backgroundMonitoringEnabled = settings.performanceMonitoringEnabled
        settingsCancellable = settings.$performanceMonitoringEnabled
            .removeDuplicates()
            .sink { [weak self] enabled in
                Task { @MainActor [weak self] in
                    self?.applyBackgroundMonitoring(enabled)
                }
            }
        loadRecentHistory()
        if backgroundMonitoringEnabled {
            refreshNow()
        }
    }

    var currentSample: PerformanceSample? {
        samples.last
    }

    var findings: [PerformanceFinding] {
        PerformanceDiagnostics.evaluate(samples)
    }

    var severity: PerformanceSeverity {
        PerformanceDiagnostics.overallSeverity(findings, hasSample: currentSample != nil)
    }

    func setDetailVisible(_ visible: Bool) {
        guard visible else {
            return
        }
        refreshWhenPresented()
    }

    func refreshWhenPresented() {
        if let currentSample,
           Date().timeIntervalSince(currentSample.capturedAt) < 1 {
            return
        }
        refreshNow()
    }

    func refreshNow() {
        guard refreshTask == nil else {
            return
        }
        refreshTimer?.invalidate()
        refreshTimer = nil
        generation += 1
        let currentGeneration = generation
        let capturedAt = Date()
        let cachedMemoryFreePercent = currentSample?.systemMemoryFreePercent
        let refreshMemoryPressure = lastMemoryPressureAttemptAt.map {
            capturedAt.timeIntervalSince($0) >= 60
        } ?? true
        if refreshMemoryPressure {
            lastMemoryPressureAttemptAt = capturedAt
        }
        isRefreshing = true

        refreshTask = Task { [weak self] in
            let result = await Task.detached(priority: .utility) { () -> CaptureResult in
                do {
                    return .success(try PerformanceSampler.capture(
                        now: capturedAt,
                        cachedMemoryFreePercent: cachedMemoryFreePercent,
                        refreshMemoryPressure: refreshMemoryPressure
                    ))
                } catch {
                    return .failure(error.localizedDescription)
                }
            }.value

            guard let self, currentGeneration == self.generation else {
                return
            }
            self.refreshTask = nil
            self.isRefreshing = false
            switch result {
            case .success(let sample):
                self.errorMessage = nil
                self.samples.append(sample)
                if self.samples.count > Self.retainedSampleCount {
                    self.samples.removeFirst(self.samples.count - Self.retainedSampleCount)
                }
                if self.backgroundMonitoringEnabled {
                    let historyStore = self.historyStore
                    Task.detached(priority: .background) {
                        historyStore.record(sample)
                    }
                }
            case .failure(let message):
                self.errorMessage = message
            }
            if self.backgroundMonitoringEnabled {
                self.scheduleNextRefresh(after: Self.refreshInterval)
            }
        }
    }

    func peakCPU(for kind: PerformanceTargetKind) -> Double? {
        let cutoff = Date().addingTimeInterval(-30)
        let values = samples
            .filter { $0.capturedAt >= cutoff }
            .map { $0.target(kind) }
            .filter { $0.processCount > 0 }
            .map(\.cpuPercent)
        return values.max()
    }

    private func applyBackgroundMonitoring(_ enabled: Bool) {
        guard backgroundMonitoringEnabled != enabled else {
            return
        }
        backgroundMonitoringEnabled = enabled
        if enabled {
            refreshNow()
        } else {
            stopScheduling()
        }
    }

    private func loadRecentHistory() {
        let historyStore = historyStore
        let retainedSampleCount = Self.retainedSampleCount
        Task { [weak self] in
            let history = await Task.detached(priority: .utility) {
                historyStore.recentSamples(limit: retainedSampleCount)
            }.value
            guard let self else {
                return
            }
            var merged: [PerformanceSample] = []
            for sample in (history + self.samples).sorted(by: { $0.capturedAt < $1.capturedAt }) {
                if merged.last?.capturedAt == sample.capturedAt {
                    merged[merged.count - 1] = sample
                } else {
                    merged.append(sample)
                }
            }
            self.samples = Array(merged.suffix(retainedSampleCount))
            if self.lastMemoryPressureAttemptAt == nil {
                self.lastMemoryPressureAttemptAt = self.samples.last?.capturedAt
            }
        }
    }

    private func scheduleNextRefresh(after interval: TimeInterval) {
        guard backgroundMonitoringEnabled else {
            return
        }
        refreshTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshNow()
            }
        }
        refreshTimer = timer
    }

    private func stopScheduling() {
        generation += 1
        refreshTimer?.invalidate()
        refreshTimer = nil
        refreshTask?.cancel()
        refreshTask = nil
        isRefreshing = false
    }
}

private enum CaptureResult: Sendable {
    case success(PerformanceSample)
    case failure(String)
}
