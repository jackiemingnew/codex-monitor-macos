import Combine
import Foundation

protocol RoutingTelemetryStoring: Sendable {
    func loadPublished(days: Int, now: Date) -> RoutingTelemetrySnapshot
    func hasSuccessfulSnapshot(after date: Date) -> Bool
    func lightScan(days: Int, now: Date, shouldCancel: @escaping @Sendable () -> Bool) throws -> RoutingTelemetrySnapshot
    func assess(days: Int, now: Date, shouldCancel: @escaping @Sendable () -> Bool) throws -> RoutingAssessment
}

extension RoutingTelemetryStore: RoutingTelemetryStoring {}

@MainActor
final class RoutingTelemetryViewModel: ObservableObject {
    private enum AssessmentResult { case success(RoutingAssessment), cancelled, failure }
    private enum LightResult { case success(RoutingTelemetrySnapshot), cancelled, schemaUnavailable, failure }
    @Published private(set) var snapshot: RoutingTelemetrySnapshot
    @Published private(set) var dailyState: RoutingDailyState
    @Published private(set) var manualState: RoutingManualState = .idle
    @Published private(set) var assessment: RoutingAssessment?
    private let store: any RoutingTelemetryStoring
    private let automaticDeferralReason: @Sendable () -> String?
    private var timer: Timer?
    private var lightWorker: Task<LightResult, Never>?
    private var assessmentWorker: Task<AssessmentResult, Never>?
    private var automaticCatchUpPending = false
    private var generation = 0

    init(store: any RoutingTelemetryStoring = RoutingTelemetryStore(), automaticDeferralReason: @escaping @Sendable () -> String? = { RoutingTelemetryScanPolicy.automaticDeferralReason() }) {
        self.store = store; self.automaticDeferralReason = automaticDeferralReason
        let initial = store.loadPublished(days: 30, now: Date()); snapshot = initial; dailyState = initial.state; assessment = initial.latestAssessment
        scheduleAutomaticRun(); catchUpIfNeeded()
    }

    func loadPublishedSnapshot() { guard !isBusy else { return }; let next = store.loadPublished(days: 30, now: Date()); snapshot = next; dailyState = next.state; assessment = next.latestAssessment }
    func refreshLight() { startLight(automatic: false) }
    func automaticRunDue() { startLight(automatic: true) }

    func assess(days: Int) {
        guard !isBusy else { return }; generation += 1; let token = generation; manualState = .assessing
        let worker: Task<AssessmentResult, Never> = Task.detached(priority: .utility) { [store] in
            do { return .success(try store.assess(days: days, now: Date(), shouldCancel: { Task.isCancelled })) }
            catch RoutingTelemetryStoreError.cancelled { return .cancelled }
            catch { return .failure }
        }
        assessmentWorker = worker
        Task { [weak self] in
            let result = await worker.value
            guard let self else { return }
            self.assessmentWorker = nil
            if self.generation == token {
                switch result { case .success(let value): assessment = value; manualState = .success; case .cancelled: manualState = .cancelled; case .failure: manualState = .failed }
            }
            resumeAutomaticSchedule()
        }
    }

    func cancelAssessment() { guard assessmentWorker != nil else { return }; generation += 1; assessmentWorker?.cancel(); manualState = .cancelled }

    private var isBusy: Bool { lightWorker != nil || assessmentWorker != nil }
    private func catchUpIfNeeded(now: Date = Date()) {
        if store.hasSuccessfulSnapshot(after: RoutingTelemetryScanPolicy.latestSchedulePoint(now: now)) {
            scheduleAutomaticRun()
        } else {
            startLight(automatic: true)
        }
    }
    private func startLight(automatic: Bool) {
        guard !isBusy else {
            if automatic { automaticCatchUpPending = true }
            return
        }
        if automatic, let reason = automaticDeferralReason() { snapshot = RoutingTelemetrySnapshot(days: snapshot.days, state: snapshot.days.isEmpty ? .empty : .stale, lastUpdated: snapshot.lastUpdated, automaticStatus: reason, latestAssessment: assessment); dailyState = snapshot.state; scheduleAutomaticRun(after: 60 * 60); return }
        generation += 1; let token = generation; dailyState = .loading
        let worker: Task<LightResult, Never> = Task.detached(priority: automatic ? .background : .utility) { [store] in
            do { return .success(try store.lightScan(days: 7, now: Date(), shouldCancel: { Task.isCancelled })) }
            catch RoutingTelemetryStoreError.cancelled { return .cancelled }
            catch RoutingTelemetryStoreError.schemaUnavailable { return .schemaUnavailable }
            catch { return .failure }
        }
        lightWorker = worker
        Task { [weak self] in
            let result = await worker.value
            guard let self else { return }
            self.lightWorker = nil
            if self.generation == token {
                switch result { case .success(let value): snapshot = value; assessment = value.latestAssessment; dailyState = value.state; case .cancelled: break; case .schemaUnavailable: dailyState = .unavailable; case .failure: dailyState = snapshot.days.isEmpty ? .unavailable : .stale }
            }
            if automatic, case .success = result {
                resumeAutomaticSchedule()
            } else if automatic {
                scheduleAutomaticRun(after: 60 * 60)
            } else {
                resumeAutomaticSchedule()
            }
        }
    }
    private func resumeAutomaticSchedule() {
        if automaticCatchUpPending {
            automaticCatchUpPending = false
            catchUpIfNeeded()
        } else {
            scheduleAutomaticRun()
        }
    }
    private func scheduleAutomaticRun(after delay: TimeInterval? = nil) { timer?.invalidate(); let interval = delay ?? max(1, RoutingTelemetryScanPolicy.nextAutomaticRunDate(now: Date()).timeIntervalSinceNow); let next = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in Task { @MainActor in self?.automaticRunDue() } }; next.tolerance = min(15 * 60, max(60, interval * 0.1)); timer = next }
}
