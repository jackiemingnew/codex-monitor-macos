import Foundation

/// The routing feature intentionally has no raw thread identifiers in any public model.
enum RoutingDailyState: String, Equatable, Sendable {
    case empty, loading, ready, partial, stale, unavailable

    var label: String {
        switch self {
        case .empty: "暂无快照"
        case .loading: "扫描中"
        case .ready: "READY"
        case .partial: "PARTIAL"
        case .stale: "STALE"
        case .unavailable: "UNAVAILABLE"
        }
    }
}

enum RoutingManualState: String, Equatable, Sendable {
    case idle, assessing, success, cancelled, failed
}

enum RoutingTelemetryQuality: String, Codable, Sendable {
    case complete = "COMPLETE"
    case partial = "PARTIAL"
    case unavailable = "UNAVAILABLE"
}

/// Stable, globally registered child-agent roles. Their declaration order is the
/// presentation and aggregation order; source model/effort values never infer one.
enum RoutingRegisteredRole: String, CaseIterable, Codable, Identifiable, Sendable {
    case codeExplorer = "code-explorer"
    case quickImplementer = "quick-implementer"
    case implementer
    case terraImplementer = "terra-implementer"
    case terraHighImplementer = "terra-high-implementer"
    case terraMaxImplementer = "terra-max-implementer"
    case solUltraTerra = "sol_ultra_terra"
    case terraReviewer = "terra-reviewer"
    case codeReviewer = "code-reviewer"
    case commitPusher = "commit-pusher"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .codeExplorer: "代码探索"
        case .quickImplementer: "快速实现"
        case .implementer: "兼容实现"
        case .terraImplementer: "常规实现"
        case .terraHighImplementer: "复杂实现"
        case .terraMaxImplementer: "大型实现"
        case .solUltraTerra: "调查归纳"
        case .terraReviewer: "常规审查"
        case .codeReviewer: "高风险审查"
        case .commitPusher: "Git 提交"
        }
    }

    var tierLabel: String {
        switch self {
        case .codeExplorer, .quickImplementer, .implementer: "Luna High"
        case .commitPusher: "Luna Low"
        case .terraImplementer, .solUltraTerra: "Terra Medium"
        case .terraHighImplementer: "Terra High"
        case .terraMaxImplementer: "Terra Max"
        case .terraReviewer: "Terra High"
        case .codeReviewer: "Sol Medium"
        }
    }

    var expectedModelID: String {
        switch self {
        case .codeExplorer, .quickImplementer, .implementer, .commitPusher:
            "gpt-5.6-luna"
        case .terraImplementer, .terraHighImplementer, .terraMaxImplementer, .solUltraTerra, .terraReviewer:
            "gpt-5.6-terra"
        case .codeReviewer:
            "gpt-5.6-sol"
        }
    }

    var expectedEffort: String {
        switch self {
        case .codeExplorer, .quickImplementer, .implementer, .terraHighImplementer, .terraReviewer:
            "high"
        case .terraImplementer, .solUltraTerra, .codeReviewer:
            "medium"
        case .terraMaxImplementer:
            "max"
        case .commitPusher:
            "low"
        }
    }

    func matches(model: String?, effort: String?) -> Bool {
        model?.lowercased() == expectedModelID && effort?.lowercased() == expectedEffort
    }
}

/// Aggregate-only child-role evidence. `role == nil` is the opaque unknown
/// bucket; it intentionally retains no unregistered raw role string.
struct RoutingRoleBucket: Codable, Identifiable, Equatable, Sendable {
    let role: RoutingRegisteredRole?
    let childThreads: Int
    let cumulativeTokens: Int
    let tokenDelta: Int
    /// Threads carrying role, model, and effort metadata; this makes the role
    /// breakdown's identity completeness inspectable without storing raw values.
    let identityCompleteThreads: Int
    /// nil is reserved for legacy payloads and the opaque unknown bucket.
    /// New registered-role buckets count exact role-contract model/effort matches.
    let identityMatchedThreads: Int?

    var id: String { role?.rawValue ?? "unknown" }
    var isUnknown: Bool { role == nil }
    var displayName: String { role?.displayName ?? "未知角色" }
    var tierLabel: String { role?.tierLabel ?? "未注册" }
    static func zero(_ role: RoutingRegisteredRole) -> RoutingRoleBucket {
        RoutingRoleBucket(role: role, childThreads: 0, cumulativeTokens: 0, tokenDelta: 0, identityCompleteThreads: 0, identityMatchedThreads: 0)
    }

    func withTokenDelta(_ value: Int) -> RoutingRoleBucket {
        RoutingRoleBucket(role: role, childThreads: childThreads, cumulativeTokens: cumulativeTokens, tokenDelta: value, identityCompleteThreads: identityCompleteThreads, identityMatchedThreads: identityMatchedThreads)
    }
}

/// Aggregate-only strict attribution for the Ultra routing token denominator.
/// `nil` on a daily metric means a legacy payload or a scan that could not
/// establish a safe one-to-one topology (for example duplicate thread IDs).
struct RoutingUltraTokenPartition: Codable, Equatable, Sendable {
    let ultraRootThreads: Int
    let ultraRootCumulativeTokens: Int
    let maxRootThreads: Int
    let maxRootCumulativeTokens: Int
    let attributedUltraChildThreads: Int
    let attributedUltraChildCumulativeTokens: Int
    let unattributedChildThreads: Int
    let unattributedChildCumulativeTokens: Int
    /// Strictly attributed Token growth observed and merged within this local day.
    /// These optional fields are absent in payloads published before this metric.
    let ultraRootDailyObservedTokenDelta: Int?
    let attributedUltraChildDailyObservedTokenDelta: Int?
    /// `false` means at least one strict line was unsafe to aggregate; `nil` is legacy.
    let dailyDeltaEvidenceComplete: Bool?
    /// Number of light observations merged into the local-day strict delta.
    let dailyMergeObservationCount: Int?

    init(
        ultraRootThreads: Int,
        ultraRootCumulativeTokens: Int,
        maxRootThreads: Int,
        maxRootCumulativeTokens: Int,
        attributedUltraChildThreads: Int,
        attributedUltraChildCumulativeTokens: Int,
        unattributedChildThreads: Int,
        unattributedChildCumulativeTokens: Int,
        ultraRootDailyObservedTokenDelta: Int? = nil,
        attributedUltraChildDailyObservedTokenDelta: Int? = nil,
        dailyDeltaEvidenceComplete: Bool? = nil,
        dailyMergeObservationCount: Int? = nil
    ) {
        self.ultraRootThreads = ultraRootThreads
        self.ultraRootCumulativeTokens = ultraRootCumulativeTokens
        self.maxRootThreads = maxRootThreads
        self.maxRootCumulativeTokens = maxRootCumulativeTokens
        self.attributedUltraChildThreads = attributedUltraChildThreads
        self.attributedUltraChildCumulativeTokens = attributedUltraChildCumulativeTokens
        self.unattributedChildThreads = unattributedChildThreads
        self.unattributedChildCumulativeTokens = unattributedChildCumulativeTokens
        self.ultraRootDailyObservedTokenDelta = ultraRootDailyObservedTokenDelta
        self.attributedUltraChildDailyObservedTokenDelta = attributedUltraChildDailyObservedTokenDelta
        self.dailyDeltaEvidenceComplete = dailyDeltaEvidenceComplete
        self.dailyMergeObservationCount = dailyMergeObservationCount
    }

    /// Max roots are deliberately excluded from this denominator.
    var ultraRoutingTokenShare: Double? {
        // Convert before addition so two independently saturated aggregates
        // cannot overflow Int while a report or chart reads the ratio.
        let denominator = Double(ultraRootCumulativeTokens) + Double(attributedUltraChildCumulativeTokens)
        guard denominator > 0 else { return nil }
        return Double(attributedUltraChildCumulativeTokens) / denominator
    }

    /// This is intentionally independent of the cumulative share above.
    var ultraRoutingDailyObservedTokenShare: Double? {
        guard dailyDeltaEvidenceComplete == true,
              let root = ultraRootDailyObservedTokenDelta,
              let child = attributedUltraChildDailyObservedTokenDelta else { return nil }
        let denominator = Double(root) + Double(child)
        guard denominator > 0 else { return nil }
        return Double(child) / denominator
    }

    func withDailyObservedDelta(root: Int, child: Int, evidenceComplete: Bool, mergeObservationCount: Int) -> RoutingUltraTokenPartition {
        RoutingUltraTokenPartition(
            ultraRootThreads: ultraRootThreads,
            ultraRootCumulativeTokens: ultraRootCumulativeTokens,
            maxRootThreads: maxRootThreads,
            maxRootCumulativeTokens: maxRootCumulativeTokens,
            attributedUltraChildThreads: attributedUltraChildThreads,
            attributedUltraChildCumulativeTokens: attributedUltraChildCumulativeTokens,
            unattributedChildThreads: unattributedChildThreads,
            unattributedChildCumulativeTokens: unattributedChildCumulativeTokens,
            ultraRootDailyObservedTokenDelta: root,
            attributedUltraChildDailyObservedTokenDelta: child,
            dailyDeltaEvidenceComplete: evidenceComplete,
            dailyMergeObservationCount: mergeObservationCount
        )
    }
}

/// Local operational guardrail for the strict daily-observation metric only.
/// It is not a success rate, performance claim, or external routing standard.
enum RoutingUltraDeltaGuidanceState: Equatable, Sendable {
    case unavailable, observing, low, balanced, elevated, excessive
}

struct RoutingUltraDeltaGuidance: Equatable, Sendable {
    static let lowerBound = 0.20
    static let upperBound = 0.35
    static let reviewBound = 0.50
    static let minimumValidDays = 3

    let state: RoutingUltraDeltaGuidanceState
    let validDays: Int
    let weightedShare: Double?

    static func evaluate(_ metrics: [RoutingDailyMetric]) -> RoutingUltraDeltaGuidance {
        var validDays = 0
        var rootTotal = 0.0
        var childTotal = 0.0
        for metric in metrics {
            guard let partition = metric.ultraTokenPartition,
                  partition.dailyDeltaEvidenceComplete == true,
                  let root = partition.ultraRootDailyObservedTokenDelta,
                  let child = partition.attributedUltraChildDailyObservedTokenDelta,
                  Double(root) + Double(child) > 0 else { continue }
            validDays += 1
            rootTotal += Double(root)
            childTotal += Double(child)
        }
        let denominator = rootTotal + childTotal
        guard denominator > 0 else {
            return RoutingUltraDeltaGuidance(state: .unavailable, validDays: 0, weightedShare: nil)
        }
        let share = childTotal / denominator
        guard validDays >= minimumValidDays else {
            return RoutingUltraDeltaGuidance(state: .observing, validDays: validDays, weightedShare: share)
        }
        let state: RoutingUltraDeltaGuidanceState
        if share < lowerBound { state = .low }
        else if share <= upperBound { state = .balanced }
        else if share <= reviewBound { state = .elevated }
        else { state = .excessive }
        return RoutingUltraDeltaGuidance(state: state, validDays: validDays, weightedShare: share)
    }
}

struct RoutingDailyMetric: Codable, Identifiable, Equatable, Sendable {
    let dayKey: String
    let sourceThreads: Int
    let edgeCount: Int
    let rootThreads: Int
    let childThreads: Int
    let roleMetadataCovered: Int
    let roleMetadataMissing: Int
    let depthAtLeastTwo: Int
    let orphanEdges: Int
    /// Recent child threads whose ancestry reaches at least one cycle.
    let cycleAffectedChildren: Int
    let anonymousSolChildren: Int
    let cumulativeTokens: Int
    let childCumulativeTokens: Int
    let tokenDelta: Int
    let childTokenDelta: Int
    let missingBaselines: Int
    let tokenRollbacks: Int
    /// Median per-thread max(0, updated - created); a proxy, not E2E elapsed time.
    let createdToUpdatedMedianMilliseconds: Int64
    let readRows: Int
    let derivedWrites: Int
    let scanMilliseconds: Int
    let quality: RoutingTelemetryQuality
    /// nil means an old payload had no role breakdown; [] is a valid, empty new snapshot.
    let roleBuckets: [RoutingRoleBucket]?
    /// nil is a legacy or topology-ambiguous snapshot, never a zero partition.
    let ultraTokenPartition: RoutingUltraTokenPartition?

    var id: String { dayKey }
    var childTokenShare: Double { cumulativeTokens > 0 ? Double(childCumulativeTokens) / Double(cumulativeTokens) : 0 }
    var ultraRoutingTokenShare: Double? { ultraTokenPartition?.ultraRoutingTokenShare }
    var ultraRoutingDailyObservedTokenShare: Double? { ultraTokenPartition?.ultraRoutingDailyObservedTokenShare }

    private enum CodingKeys: String, CodingKey {
        case dayKey, sourceThreads, edgeCount, rootThreads, childThreads, roleMetadataCovered, roleMetadataMissing, depthAtLeastTwo, orphanEdges, cycleAffectedChildren, anonymousSolChildren, cumulativeTokens, childCumulativeTokens, tokenDelta, childTokenDelta, missingBaselines, tokenRollbacks, createdToUpdatedMedianMilliseconds, readRows, derivedWrites, scanMilliseconds, quality, roleBuckets, ultraTokenPartition
    }

    init(dayKey: String, sourceThreads: Int, edgeCount: Int, rootThreads: Int, childThreads: Int, roleMetadataCovered: Int, roleMetadataMissing: Int, depthAtLeastTwo: Int, orphanEdges: Int, cycleAffectedChildren: Int, anonymousSolChildren: Int, cumulativeTokens: Int, childCumulativeTokens: Int, tokenDelta: Int, childTokenDelta: Int, missingBaselines: Int, tokenRollbacks: Int, createdToUpdatedMedianMilliseconds: Int64, readRows: Int, derivedWrites: Int, scanMilliseconds: Int, quality: RoutingTelemetryQuality, roleBuckets: [RoutingRoleBucket]? = nil, ultraTokenPartition: RoutingUltraTokenPartition? = nil) {
        self.dayKey = dayKey; self.sourceThreads = sourceThreads; self.edgeCount = edgeCount; self.rootThreads = rootThreads; self.childThreads = childThreads; self.roleMetadataCovered = roleMetadataCovered; self.roleMetadataMissing = roleMetadataMissing; self.depthAtLeastTwo = depthAtLeastTwo; self.orphanEdges = orphanEdges; self.cycleAffectedChildren = cycleAffectedChildren; self.anonymousSolChildren = anonymousSolChildren; self.cumulativeTokens = cumulativeTokens; self.childCumulativeTokens = childCumulativeTokens; self.tokenDelta = tokenDelta; self.childTokenDelta = childTokenDelta; self.missingBaselines = missingBaselines; self.tokenRollbacks = tokenRollbacks; self.createdToUpdatedMedianMilliseconds = createdToUpdatedMedianMilliseconds; self.readRows = readRows; self.derivedWrites = derivedWrites; self.scanMilliseconds = scanMilliseconds; self.quality = quality; self.roleBuckets = roleBuckets; self.ultraTokenPartition = ultraTokenPartition
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(dayKey: try c.decode(String.self, forKey: .dayKey), sourceThreads: try c.decode(Int.self, forKey: .sourceThreads), edgeCount: try c.decode(Int.self, forKey: .edgeCount), rootThreads: try c.decode(Int.self, forKey: .rootThreads), childThreads: try c.decode(Int.self, forKey: .childThreads), roleMetadataCovered: try c.decode(Int.self, forKey: .roleMetadataCovered), roleMetadataMissing: try c.decode(Int.self, forKey: .roleMetadataMissing), depthAtLeastTwo: try c.decode(Int.self, forKey: .depthAtLeastTwo), orphanEdges: try c.decode(Int.self, forKey: .orphanEdges), cycleAffectedChildren: try c.decode(Int.self, forKey: .cycleAffectedChildren), anonymousSolChildren: try c.decode(Int.self, forKey: .anonymousSolChildren), cumulativeTokens: try c.decode(Int.self, forKey: .cumulativeTokens), childCumulativeTokens: try c.decode(Int.self, forKey: .childCumulativeTokens), tokenDelta: try c.decode(Int.self, forKey: .tokenDelta), childTokenDelta: try c.decode(Int.self, forKey: .childTokenDelta), missingBaselines: try c.decode(Int.self, forKey: .missingBaselines), tokenRollbacks: try c.decode(Int.self, forKey: .tokenRollbacks), createdToUpdatedMedianMilliseconds: try c.decode(Int64.self, forKey: .createdToUpdatedMedianMilliseconds), readRows: try c.decode(Int.self, forKey: .readRows), derivedWrites: try c.decode(Int.self, forKey: .derivedWrites), scanMilliseconds: try c.decode(Int.self, forKey: .scanMilliseconds), quality: try c.decode(RoutingTelemetryQuality.self, forKey: .quality), roleBuckets: try c.decodeIfPresent([RoutingRoleBucket].self, forKey: .roleBuckets), ultraTokenPartition: try c.decodeIfPresent(RoutingUltraTokenPartition.self, forKey: .ultraTokenPartition))
    }
}

struct RoutingAssessment: Codable, Equatable, Sendable {
    let periodDays: Int
    let generatedAt: Date
    let metrics: RoutingDailyMetric
    /// These need run outcome and wall-clock execution evidence, neither exists in state.sqlite.
    let verifiedSuccessRate: String
    let tokenPerVerifiedSuccess: String
    let trueEndToEndSpeedup: String
}

struct RoutingTelemetrySnapshot: Equatable, Sendable {
    let days: [RoutingDailyMetric]
    let state: RoutingDailyState
    let lastUpdated: Date?
    let automaticStatus: String
    let latestAssessment: RoutingAssessment?

    static let empty = RoutingTelemetrySnapshot(days: [], state: .empty, lastUpdated: nil, automaticStatus: "每日 21:00 本地时间", latestAssessment: nil)

    var latest: RoutingDailyMetric? { days.last }
}

struct RoutingTelemetryScanPolicy: Sendable {
    static let automaticHour = 21
    static let automaticMinute = 0
    static let dayRetention = 90
    static let baselineRetentionDays = 100

    static func localDayKey(_ date: Date, calendar: Calendar = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    static func nextAutomaticRunDate(now: Date, calendar: Calendar = .current) -> Date {
        var parts = calendar.dateComponents([.year, .month, .day], from: now)
        parts.hour = automaticHour
        parts.minute = automaticMinute
        parts.second = 0
        let today = calendar.date(from: parts) ?? now.addingTimeInterval(24 * 60 * 60)
        return today > now ? today : (calendar.date(byAdding: .day, value: 1, to: today) ?? today.addingTimeInterval(24 * 60 * 60))
    }

    static func latestSchedulePoint(now: Date, calendar: Calendar = .current) -> Date {
        var parts = calendar.dateComponents([.year, .month, .day], from: now)
        parts.hour = automaticHour
        parts.minute = automaticMinute
        parts.second = 0
        let today = calendar.date(from: parts) ?? now
        return now >= today ? today : (calendar.date(byAdding: .day, value: -1, to: today) ?? today)
    }

    static func automaticDeferralReason(processInfo: ProcessInfo = .processInfo) -> String? {
        automaticDeferralReason(lowPower: processInfo.isLowPowerModeEnabled, thermalState: processInfo.thermalState)
    }

    static func automaticDeferralReason(lowPower: Bool, thermalState: ProcessInfo.ThermalState) -> String? {
        if lowPower { return "低电量模式，已延期" }
        switch thermalState {
        case .serious, .critical: return "设备温度压力，已延期"
        default: return nil
        }
    }
}
