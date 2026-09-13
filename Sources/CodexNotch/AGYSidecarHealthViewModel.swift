import Combine
import Foundation

@MainActor
final class AGYSidecarHealthViewModel: ObservableObject {
    @Published private(set) var doctorSnapshot: AGYSidecarDoctorSnapshot = .neverRun
    @Published private(set) var e2eSnapshot: AGYSidecarE2ESnapshot = .neverRun
    @Published private(set) var isDoctorChecking = false
    @Published private(set) var isCanaryRunning = false

    let liveCanaryAuthorized: Bool

    private let service: any AGYSidecarHealthServicing
    private var doctorTask: Task<AGYSidecarDoctorSnapshot, Error>?
    private var doctorRefreshTask: Task<Void, Never>?
    private var canaryTask: Task<AGYSidecarE2ESnapshot, Error>?
    private var automaticTask: Task<Void, Never>?
    private var automaticEnabled = false
    private var automaticInterval = AGYSidecarHealthPolicy.defaultAutomaticCanaryInterval
    private var didStart = false

    init(
        service: any AGYSidecarHealthServicing = AGYSidecarHealthService(),
        liveCanaryAuthorized: Bool = AGYSidecarHealthPolicy.liveCanaryAuthorized,
        startAutomatically: Bool = true
    ) {
        self.service = service
        self.liveCanaryAuthorized = liveCanaryAuthorized
        if startAutomatically {
            Task { @MainActor [weak self] in
                await self?.start()
            }
        }
    }

    deinit {
        doctorTask?.cancel()
        doctorRefreshTask?.cancel()
        canaryTask?.cancel()
        automaticTask?.cancel()
    }

    func start(now: Date = Date()) async {
        guard !didStart else { return }
        didStart = true
        let cached = await service.cachedEntry()
        doctorSnapshot = cached.doctor
        e2eSnapshot = cached.e2e
        if !AGYSidecarHealthPolicy.doctorIsFresh(cached.doctor, now: now) {
            await checkDoctorNow(now: now)
        } else {
            scheduleDoctorRefresh(now: now)
        }
        scheduleAutomaticCanary(now: now)
    }

    func checkDoctorNow(now: Date = Date()) async {
        if let doctorTask {
            _ = await doctorTask.result
            return
        }
        doctorRefreshTask?.cancel()
        doctorRefreshTask = nil
        isDoctorChecking = true
        let service = self.service
        let task = Task { try await service.checkDoctor(at: now) }
        doctorTask = task
        defer {
            doctorTask = nil
            isDoctorChecking = false
        }
        switch await task.result {
        case let .success(snapshot):
            doctorSnapshot = snapshot
        case let .failure(error):
            if Self.isCancellation(error) {
                if didStart {
                    scheduleDoctorRefresh(
                        now: now,
                        notBefore: now.addingTimeInterval(AGYSidecarHealthPolicy.doctorFreshness)
                    )
                }
                return
            }
            doctorSnapshot = AGYSidecarDoctorSnapshot(
                status: .broken,
                checkedAt: now,
                models: [],
                repositoryModeReady: false,
                errorCode: .processFailed
            )
        }
        if didStart {
            scheduleDoctorRefresh(now: now)
        }
    }

    func cancelDoctorCheck() {
        doctorTask?.cancel()
    }

    func runCanaryNow(now: Date = Date()) async {
        guard liveCanaryAuthorized else { return }
        if let canaryTask {
            _ = await canaryTask.result
            return
        }
        isCanaryRunning = true
        let service = self.service
        let task = Task { try await service.runCanary(at: now, liveAuthorized: true) }
        canaryTask = task
        defer {
            canaryTask = nil
            isCanaryRunning = false
        }
        switch await task.result {
        case let .success(snapshot):
            e2eSnapshot = snapshot
        case let .failure(error):
            if Self.isCancellation(error) {
                scheduleAutomaticCanary(
                    now: now,
                    notBefore: now.addingTimeInterval(automaticInterval)
                )
                return
            }
            e2eSnapshot = AGYSidecarE2ESnapshot(
                status: .broken,
                checkedAt: now,
                wrapperStatus: nil,
                attemptedModels: [],
                secondaryRequired: nil,
                source: nil,
                toolAudit: nil,
                usage: .unavailable,
                receiptBytes: nil,
                findingMatched: nil,
                codexTokenUsage: nil,
                errorCode: .processFailed
            )
        }
        scheduleAutomaticCanary(now: now)
    }

    func cancelCanary() {
        canaryTask?.cancel()
    }

    func configureAutomaticCanary(
        enabled: Bool,
        interval: TimeInterval,
        now: Date = Date()
    ) {
        automaticEnabled = enabled
        automaticInterval = AGYSidecarHealthPolicy.automaticInterval(interval)
        scheduleAutomaticCanary(now: now)
    }

    var shouldDisplay: Bool {
        isDoctorChecking || doctorSnapshot.status != .neverRun || e2eSnapshot.status != .neverRun
    }

    var indicatorLabel: String {
        if isCanaryRunning { return "验收中" }
        if isDoctorChecking { return "自检中" }
        if e2eSnapshot.status == .broken || doctorSnapshot.status == .broken { return "BROKEN" }
        if doctorSnapshot.status == .unavailable { return "自检不可用" }
        if doctorSnapshot.status == .compatibilityWarning { return "兼容待确认" }
        switch e2eSnapshot.status {
        case .complete: return "COMPLETE"
        case .partial: return "PARTIAL"
        case .unavailable: return "验收不可用"
        case .broken: return "BROKEN"
        case .neverRun:
            switch doctorSnapshot.status {
            case .ready: return "自检通过"
            case .compatibilityWarning: return "兼容待确认"
            case .unavailable: return "自检不可用"
            case .broken: return "BROKEN"
            case .neverRun: return "未检查"
            }
        }
    }

    var accessibilitySummary: String {
        let doctor = "旁路 Doctor：\(doctorSnapshot.status.rawValue)"
        let e2e = "E2E：\(e2eSnapshot.status.rawValue)"
        let doctorModels = doctorSnapshot.models.isEmpty
            ? "Doctor models：无"
            : "Doctor models：\(doctorSnapshot.models.map(\.model).joined(separator: "、"))"
        let models = e2eSnapshot.attemptedModels.isEmpty
            ? "attempted models：无"
            : "attempted models：\(e2eSnapshot.attemptedModels.joined(separator: "、"))"
        let tokens = e2eSnapshot.usage.total.map { "模型 Token total：\($0)" }
            ?? "模型 Token：UNAVAILABLE"
        return "\(doctor)；\(e2e)；\(doctorModels)；\(models)；\(tokens)；\(e2eSnapshot.codexTokenUsageLabel)。具体模型版本只记录，模型角色族与只读协议决定健康；旁路状态与 AGY 配额状态相互独立。"
    }

    private func scheduleAutomaticCanary(now: Date) {
        scheduleAutomaticCanary(now: now, notBefore: nil)
    }

    private func scheduleDoctorRefresh(now: Date, notBefore: Date? = nil) {
        doctorRefreshTask?.cancel()
        var dueAt = doctorSnapshot.checkedAt.map { checkedAt in
            checkedAt <= now
                ? checkedAt.addingTimeInterval(AGYSidecarHealthPolicy.doctorFreshness)
                : now.addingTimeInterval(AGYSidecarHealthPolicy.doctorFreshness)
        }
            ?? now.addingTimeInterval(AGYSidecarHealthPolicy.doctorFreshness)
        if let notBefore, dueAt < notBefore {
            dueAt = notBefore
        }
        let delay = max(0, dueAt.timeIntervalSince(now))
        doctorRefreshTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            } catch {
                return
            }
            guard let self else { return }
            self.doctorRefreshTask = nil
            await self.checkDoctorNow(now: Date())
        }
    }

    private func scheduleAutomaticCanary(now: Date, notBefore: Date?) {
        automaticTask?.cancel()
        automaticTask = nil
        guard automaticEnabled, liveCanaryAuthorized else { return }
        var dueAt = e2eSnapshot.checkedAt.map { checkedAt in
            checkedAt <= now
                ? checkedAt.addingTimeInterval(automaticInterval)
                : now.addingTimeInterval(automaticInterval)
        }
            ?? now.addingTimeInterval(automaticInterval)
        if let notBefore, dueAt < notBefore {
            dueAt = notBefore
        }
        let delay = max(0, dueAt.timeIntervalSince(now))
        automaticTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            } catch {
                return
            }
            guard let self, self.automaticEnabled, self.liveCanaryAuthorized else { return }
            self.automaticTask = nil
            await self.runCanaryNow(now: Date())
        }
    }

    private static func isCancellation(_ error: Error) -> Bool {
        error is CancellationError
            || (error as? AGYSidecarHealthServiceError) == .cancelled
    }
}
