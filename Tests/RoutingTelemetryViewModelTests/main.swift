import Foundation

@main
struct RoutingTelemetryViewModelTests {
    @MainActor
    static func main() async {
        var failures: [String] = []
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            if !condition() {
                failures.append(message)
            }
        }

        let catchUpStore = FakeRoutingTelemetryStore()
        catchUpStore.successfulSnapshotAvailable = true
        let catchUpViewModel = RoutingTelemetryViewModel(
            store: catchUpStore,
            automaticDeferralReason: { nil }
        )
        catchUpViewModel.assess(days: 7)
        let catchUpAssessmentStarted = await waitUntil { catchUpStore.assessmentStarted }
        check(catchUpAssessmentStarted, "assessment should start")
        catchUpStore.successfulSnapshotAvailable = false
        catchUpViewModel.automaticRunDue()
        catchUpStore.releaseAssessment()
        let catchUpScanCompleted = await waitUntil { catchUpStore.lightScanCount == 1 }
        check(catchUpScanCompleted, "21:00 scan should catch up after a busy assessment")
        check(catchUpStore.maximumConcurrentOperations == 1, "deep and light work must remain serialized")

        let cancellationStore = FakeRoutingTelemetryStore()
        cancellationStore.successfulSnapshotAvailable = true
        let cancellationViewModel = RoutingTelemetryViewModel(
            store: cancellationStore,
            automaticDeferralReason: { nil }
        )
        cancellationViewModel.assess(days: 30)
        let cancellationAssessmentStarted = await waitUntil { cancellationStore.assessmentStarted }
        check(cancellationAssessmentStarted, "cancellable assessment should start")
        cancellationViewModel.cancelAssessment()
        cancellationViewModel.refreshLight()
        check(cancellationStore.lightScanCount == 0, "manual refresh must not overlap a cancelling assessment")
        let cancellationAssessmentFinished = await waitUntil { cancellationStore.assessmentFinished }
        check(cancellationAssessmentFinished, "cancelled worker should unwind")
        try? await Task.sleep(for: .milliseconds(30))
        check(cancellationStore.lightScanCount == 0, "cancel must not trigger an unrelated light scan")
        check(cancellationViewModel.manualState == .cancelled, "cancelled state should remain visible")

        if failures.isEmpty {
            print("RoutingTelemetryViewModelTests: PASS")
        } else {
            failures.forEach {
                FileHandle.standardError.write(Data("FAIL: \($0)\n".utf8))
            }
            exit(1)
        }
    }

    @MainActor
    private static func waitUntil(
        attempts: Int = 400,
        condition: @escaping @MainActor () -> Bool
    ) async -> Bool {
        for _ in 0..<attempts {
            if condition() {
                return true
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }
}

private final class FakeRoutingTelemetryStore: RoutingTelemetryStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var snapshotAvailable = true
    private var releaseRequested = false
    private var started = false
    private var finished = false
    private var lightScans = 0
    private var activeOperations = 0
    private var maximumOperations = 0

    var successfulSnapshotAvailable: Bool {
        get { locked { snapshotAvailable } }
        set { locked { snapshotAvailable = newValue } }
    }

    var assessmentStarted: Bool {
        locked { started }
    }

    var assessmentFinished: Bool {
        locked { finished }
    }

    var lightScanCount: Int {
        locked { lightScans }
    }

    var maximumConcurrentOperations: Int {
        locked { maximumOperations }
    }

    func releaseAssessment() {
        locked { releaseRequested = true }
    }

    func loadPublished(days _: Int, now _: Date) -> RoutingTelemetrySnapshot {
        .empty
    }

    func hasSuccessfulSnapshot(after _: Date) -> Bool {
        successfulSnapshotAvailable
    }

    func lightScan(
        days _: Int,
        now: Date,
        shouldCancel _: @escaping @Sendable () -> Bool
    ) throws -> RoutingTelemetrySnapshot {
        beginOperation()
        defer { endOperation() }
        locked { lightScans += 1 }
        let metric = Self.metric(now: now)
        return RoutingTelemetrySnapshot(
            days: [metric],
            state: .ready,
            lastUpdated: now,
            automaticStatus: "测试",
            latestAssessment: nil
        )
    }

    func assess(
        days: Int,
        now: Date,
        shouldCancel: @escaping @Sendable () -> Bool
    ) throws -> RoutingAssessment {
        beginOperation()
        locked { started = true }
        defer {
            locked { finished = true }
            endOperation()
        }
        while !locked({ releaseRequested }) {
            if shouldCancel() {
                throw RoutingTelemetryStoreError.cancelled
            }
            Thread.sleep(forTimeInterval: 0.002)
        }
        if shouldCancel() {
            throw RoutingTelemetryStoreError.cancelled
        }
        return RoutingAssessment(
            periodDays: days,
            generatedAt: now,
            metrics: Self.metric(now: now),
            verifiedSuccessRate: "UNVERIFIED",
            tokenPerVerifiedSuccess: "UNVERIFIED",
            trueEndToEndSpeedup: "UNVERIFIED"
        )
    }

    private func beginOperation() {
        locked {
            activeOperations += 1
            maximumOperations = max(maximumOperations, activeOperations)
        }
    }

    private func endOperation() {
        locked { activeOperations -= 1 }
    }

    @discardableResult
    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    private static func metric(now: Date) -> RoutingDailyMetric {
        RoutingDailyMetric(
            dayKey: RoutingTelemetryScanPolicy.localDayKey(now),
            sourceThreads: 2,
            edgeCount: 1,
            rootThreads: 1,
            childThreads: 1,
            roleMetadataCovered: 1,
            roleMetadataMissing: 0,
            depthAtLeastTwo: 0,
            orphanEdges: 0,
            cycleAffectedChildren: 0,
            anonymousSolChildren: 0,
            cumulativeTokens: 100,
            childCumulativeTokens: 25,
            tokenDelta: 10,
            childTokenDelta: 5,
            missingBaselines: 0,
            tokenRollbacks: 0,
            createdToUpdatedMedianMilliseconds: 500,
            readRows: 4,
            derivedWrites: 3,
            scanMilliseconds: 1,
            quality: .complete
        )
    }
}
