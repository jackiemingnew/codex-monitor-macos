import Foundation

enum RefreshLane: String, CaseIterable, Hashable, Sendable {
    case localSnapshot
    case usageTotals
    case costUsage
    case watchPaths
    case appServerQuota
    case remoteCodex
    case newAPI
    case subAPI
    case codexRadar
}

enum RefreshReason: String, Sendable {
    case startup
    case timer
    case fileEvent
    case presentation
    case manual
    case settings
    case resetBoundary
    case environmentChange
}

enum RefreshFreshness: String, Equatable, Sendable {
    case fresh
    case stale
    case expired
    case unavailable

    var requiresRefresh: Bool {
        self != .fresh
    }
}

enum RefreshRequestMode: Sendable {
    case coalesce
    case enqueue
    case replace
}

struct RefreshToken<Key: Hashable & Sendable>: Equatable, Sendable {
    let key: Key
    let generation: Int
}

enum RefreshStart<Key: Hashable & Sendable>: Equatable, Sendable {
    case started(RefreshToken<Key>)
    case coalesced
}

struct RefreshCompletion: Equatable, Sendable {
    let isCurrent: Bool
    let shouldRunPending: Bool

    static let stale = RefreshCompletion(isCurrent: false, shouldRunPending: false)
}

struct RefreshCoordinatorState<Key: Hashable & Sendable>: Sendable {
    private struct LaneState: Sendable {
        var generation = 0
        var isInFlight = false
        var hasPendingRequest = false
    }

    private var lanes: [Key: LaneState] = [:]

    mutating func begin(_ key: Key, mode: RefreshRequestMode) -> RefreshStart<Key> {
        var lane = lanes[key] ?? LaneState()
        if lane.isInFlight {
            switch mode {
            case .coalesce:
                return .coalesced
            case .enqueue:
                lane.hasPendingRequest = true
                lanes[key] = lane
                return .coalesced
            case .replace:
                break
            }
        }

        lane.generation += 1
        lane.isInFlight = true
        lane.hasPendingRequest = false
        lanes[key] = lane
        return .started(RefreshToken(key: key, generation: lane.generation))
    }

    mutating func complete(_ token: RefreshToken<Key>) -> RefreshCompletion {
        guard var lane = lanes[token.key],
              lane.generation == token.generation,
              lane.isInFlight else {
            return .stale
        }

        let shouldRunPending = lane.hasPendingRequest
        lane.isInFlight = false
        lane.hasPendingRequest = false
        lanes[token.key] = lane
        return RefreshCompletion(isCurrent: true, shouldRunPending: shouldRunPending)
    }

    mutating func invalidate(_ key: Key) {
        var lane = lanes[key] ?? LaneState()
        lane.generation += 1
        lane.isInFlight = false
        lane.hasPendingRequest = false
        lanes[key] = lane
    }

    func isCurrent(_ token: RefreshToken<Key>) -> Bool {
        guard let lane = lanes[token.key] else {
            return false
        }
        return lane.generation == token.generation && lane.isInFlight
    }

    func isInFlight(_ key: Key) -> Bool {
        lanes[key]?.isInFlight == true
    }

    func hasAnyInFlight(in keys: Set<Key>) -> Bool {
        keys.contains { lanes[$0]?.isInFlight == true }
    }
}

@MainActor
final class RefreshCoordinator<Key: Hashable & Sendable> {
    private var state = RefreshCoordinatorState<Key>()
    private var tasks: [Key: Task<Void, Never>] = [:]
    private let metrics: RefreshShadowMetrics

    init(metrics: RefreshShadowMetrics = .shared) {
        self.metrics = metrics
    }

    func begin(
        _ key: Key,
        reason: RefreshReason,
        mode: RefreshRequestMode = .coalesce
    ) -> RefreshStart<Key> {
        if mode == .replace {
            tasks.removeValue(forKey: key)?.cancel()
        }
        let result = state.begin(key, mode: mode)
        metrics.recordRequest(reason: reason, coalesced: result == .coalesced, replaced: mode == .replace)
        return result
    }

    func attach(_ task: Task<Void, Never>, to token: RefreshToken<Key>) {
        guard state.isCurrent(token) else {
            task.cancel()
            return
        }
        tasks[token.key] = task
    }

    func complete(_ token: RefreshToken<Key>) -> RefreshCompletion {
        let completion = state.complete(token)
        if completion.isCurrent {
            tasks.removeValue(forKey: token.key)
        } else {
            metrics.recordStaleCompletion()
        }
        return completion
    }

    func invalidate(_ key: Key) {
        tasks.removeValue(forKey: key)?.cancel()
        state.invalidate(key)
    }

    func invalidateAll(_ keys: Set<Key>) {
        for key in keys {
            invalidate(key)
        }
    }

    func isInFlight(_ key: Key) -> Bool {
        state.isInFlight(key)
    }

    func hasAnyInFlight(in keys: Set<Key>) -> Bool {
        state.hasAnyInFlight(in: keys)
    }
}

struct RefreshEnvironment: Equatable, Sendable {
    let isLowPowerModeEnabled: Bool
    let isThermallyConstrained: Bool

    var isConstrained: Bool {
        isLowPowerModeEnabled || isThermallyConstrained
    }

    static var current: RefreshEnvironment {
        let processInfo = ProcessInfo.processInfo
        let thermalState = processInfo.thermalState
        return RefreshEnvironment(
            isLowPowerModeEnabled: processInfo.isLowPowerModeEnabled,
            isThermallyConstrained: thermalState == .serious || thermalState == .critical
        )
    }
}

struct RefreshCadenceDecision: Equatable, Sendable {
    let interval: TimeInterval
    let candidateInterval: TimeInterval
    let reasonCode: String
}

enum AdaptiveRefreshPolicy {
    static let localVisibleRunning: TimeInterval = 15
    static let localHiddenRunning: TimeInterval = 30
    static let localVisibleIdle: TimeInterval = 90
    static let localHiddenIdle: TimeInterval = 300
    static let constrainedLocalSafetyPoll: TimeInterval = 600
    static let normalBackgroundInterval: TimeInterval = 300
    static let constrainedBackgroundInterval: TimeInterval = 900
    static let hiddenRemoteMinimum: TimeInterval = 900
    static let constrainedRemoteMinimum: TimeInterval = 1_800

    static func localSnapshot(
        adaptiveEnabled: Bool,
        isVisible: Bool,
        isRunning: Bool,
        environment: RefreshEnvironment,
        fixedInterval: TimeInterval
    ) -> RefreshCadenceDecision {
        let candidate: TimeInterval
        let reason: String
        if environment.isConstrained {
            candidate = constrainedLocalSafetyPoll
            reason = "power_or_thermal_constraint"
        } else if isRunning {
            candidate = isVisible ? localVisibleRunning : localHiddenRunning
            reason = isVisible ? "visible_running" : "hidden_running"
        } else {
            candidate = isVisible ? localVisibleIdle : localHiddenIdle
            reason = isVisible ? "visible_idle" : "hidden_idle"
        }
        return RefreshCadenceDecision(
            interval: adaptiveEnabled ? candidate : fixedInterval,
            candidateInterval: candidate,
            reasonCode: adaptiveEnabled ? reason : "fixed_shadow_\(reason)"
        )
    }

    static func localBackground(
        adaptiveEnabled: Bool,
        environment: RefreshEnvironment,
        fixedInterval: TimeInterval
    ) -> RefreshCadenceDecision {
        let candidate = environment.isConstrained
            ? constrainedBackgroundInterval
            : normalBackgroundInterval
        return RefreshCadenceDecision(
            interval: adaptiveEnabled ? candidate : fixedInterval,
            candidateInterval: candidate,
            reasonCode: adaptiveEnabled ? "adaptive_background" : "fixed_shadow_background"
        )
    }

    static func remote(
        adaptiveEnabled: Bool,
        isVisible: Bool,
        environment: RefreshEnvironment,
        baseInterval: TimeInterval,
        consecutiveFailures: Int
    ) -> RefreshCadenceDecision {
        if consecutiveFailures > 0 {
            let backoff = failureBackoff(consecutiveFailures: consecutiveFailures)
            let candidate = environment.isConstrained
                ? max(backoff, constrainedRemoteMinimum)
                : backoff
            return RefreshCadenceDecision(
                interval: adaptiveEnabled ? candidate : backoff,
                candidateInterval: candidate,
                reasonCode: environment.isConstrained
                    ? "constrained_failure_backoff_\(consecutiveFailures)"
                    : "failure_backoff_\(consecutiveFailures)"
            )
        }

        let candidate: TimeInterval
        let reason: String
        if environment.isConstrained {
            candidate = max(baseInterval, constrainedRemoteMinimum)
            reason = isVisible ? "constrained_visible_remote" : "constrained_hidden_remote"
        } else if isVisible {
            candidate = baseInterval
            reason = "visible_remote"
        } else {
            candidate = max(baseInterval, hiddenRemoteMinimum)
            reason = "hidden_remote"
        }
        return RefreshCadenceDecision(
            interval: adaptiveEnabled ? candidate : baseInterval,
            candidateInterval: candidate,
            reasonCode: adaptiveEnabled ? reason : "fixed_shadow_\(reason)"
        )
    }

    static func failureBackoff(consecutiveFailures: Int) -> TimeInterval {
        let schedule: [TimeInterval] = [30, 60, 120, 300, 600, 1_800]
        let index = min(schedule.count - 1, max(0, consecutiveFailures - 1))
        return schedule[index]
    }

    static func freshness(
        lastSuccessfulAt: Date?,
        now: Date = Date(),
        maximumAge: TimeInterval,
        expirationMultiplier: Double = 3
    ) -> RefreshFreshness {
        guard let lastSuccessfulAt else {
            return .unavailable
        }
        let age = max(0, now.timeIntervalSince(lastSuccessfulAt))
        if age <= maximumAge {
            return .fresh
        }
        if age <= maximumAge * max(1, expirationMultiplier) {
            return .stale
        }
        return .expired
    }
}

struct RefreshShadowSnapshot: Equatable, Sendable {
    var decisionCount = 0
    var projectedFixedRefreshesPerDay = 0.0
    var projectedAdaptiveRefreshesPerDay = 0.0
    var requestCount = 0
    var coalescedRequestCount = 0
    var replacedRequestCount = 0
    var staleCompletionCount = 0
}

final class RefreshShadowMetrics: @unchecked Sendable {
    static let shared = RefreshShadowMetrics()

    private let lock = NSLock()
    private var value = RefreshShadowSnapshot()
    private var fixedRatesByLane: [RefreshLane: Double] = [:]
    private var adaptiveRatesByLane: [RefreshLane: Double] = [:]

    func recordSchedule(
        lane: RefreshLane,
        fixedInterval: TimeInterval,
        candidateInterval: TimeInterval
    ) {
        lock.lock()
        value.decisionCount += 1
        fixedRatesByLane[lane] = 86_400 / max(1, fixedInterval)
        adaptiveRatesByLane[lane] = 86_400 / max(1, candidateInterval)
        lock.unlock()
    }

    func recordRequest(reason _: RefreshReason, coalesced: Bool, replaced: Bool) {
        lock.lock()
        value.requestCount += 1
        if coalesced {
            value.coalescedRequestCount += 1
        }
        if replaced {
            value.replacedRequestCount += 1
        }
        lock.unlock()
    }

    func recordStaleCompletion() {
        lock.lock()
        value.staleCompletionCount += 1
        lock.unlock()
    }

    func snapshot() -> RefreshShadowSnapshot {
        lock.lock()
        defer { lock.unlock() }
        var snapshot = value
        snapshot.projectedFixedRefreshesPerDay = fixedRatesByLane.values.reduce(0, +)
        snapshot.projectedAdaptiveRefreshesPerDay = adaptiveRatesByLane.values.reduce(0, +)
        return snapshot
    }

    func resetForTesting() {
        lock.lock()
        value = RefreshShadowSnapshot()
        fixedRatesByLane.removeAll()
        adaptiveRatesByLane.removeAll()
        lock.unlock()
    }
}

enum QuotaPaceOutcome: Equatable, Sendable {
    case sustainable
    case exhaustsBeforeReset(Date)
}

struct QuotaPace: Equatable, Sendable {
    let outcome: QuotaPaceOutcome
    let expectedUsedPercent: Double
    let actualUsedPercent: Double

    static func calculate(
        remainingPercent: Int?,
        resetsAt: Int?,
        windowMinutes: Int?,
        now: Date = Date()
    ) -> QuotaPace? {
        guard let remainingPercent,
              (0...100).contains(remainingPercent),
              let resetsAt,
              let windowMinutes,
              windowMinutes > 0,
              windowMinutes <= Int.max / 60 else {
            return nil
        }

        let resetDate = Date(timeIntervalSince1970: TimeInterval(resetsAt))
        let windowDuration = TimeInterval(windowMinutes) * 60
        guard windowDuration.isFinite else {
            return nil
        }
        let windowStart = resetDate.addingTimeInterval(-windowDuration)
        let elapsed = now.timeIntervalSince(windowStart)
        let remainingWindow = resetDate.timeIntervalSince(now)
        guard elapsed > 0, elapsed < windowDuration, remainingWindow > 0 else {
            return nil
        }

        let minimumElapsed: TimeInterval = windowMinutes >= 24 * 60 ? 30 * 60 : 5 * 60
        guard elapsed >= minimumElapsed else {
            return nil
        }

        let actualUsed = Double(100 - remainingPercent)
        let expectedUsed = min(100, max(0, elapsed / windowDuration * 100))
        if remainingPercent == 0 {
            return QuotaPace(
                outcome: .exhaustsBeforeReset(now),
                expectedUsedPercent: expectedUsed,
                actualUsedPercent: actualUsed
            )
        }
        guard actualUsed >= 1 else {
            return nil
        }

        let burnRatePerSecond = actualUsed / elapsed
        guard burnRatePerSecond.isFinite, burnRatePerSecond > 0 else {
            return nil
        }
        let exhaustionDate = now.addingTimeInterval(Double(remainingPercent) / burnRatePerSecond)
        let outcome: QuotaPaceOutcome = exhaustionDate < resetDate
            ? .exhaustsBeforeReset(exhaustionDate)
            : .sustainable
        return QuotaPace(
            outcome: outcome,
            expectedUsedPercent: expectedUsed,
            actualUsedPercent: actualUsed
        )
    }
}
