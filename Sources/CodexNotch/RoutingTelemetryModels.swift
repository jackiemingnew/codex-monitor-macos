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

enum RoutingRoleLifecycle: String, Codable, Sendable {
    case active, retired
}

enum RoutingRoleAccent: String, Codable, Sendable {
    case luna, terra, sol
}

/// One additive table is the role contract. Aggregation and presentation consume
/// this metadata instead of duplicating role switches. Retired entries are kept
/// so old persisted snapshots continue to decode without treating history as an
/// unknown current role.
private struct RoutingRoleDefinition: Sendable {
    let rawValue: String
    let displayName: String
    let tierLabel: String
    let expectedModelID: String
    let expectedEffort: String
    let lifecycle: RoutingRoleLifecycle
    let accent: RoutingRoleAccent
    let historicalIdentities: [RoutingRoleHistoricalIdentity]

    init(
        rawValue: String,
        displayName: String,
        tierLabel: String,
        expectedModelID: String,
        expectedEffort: String,
        lifecycle: RoutingRoleLifecycle,
        accent: RoutingRoleAccent,
        historicalIdentities: [RoutingRoleHistoricalIdentity] = []
    ) {
        self.rawValue = rawValue
        self.displayName = displayName
        self.tierLabel = tierLabel
        self.expectedModelID = expectedModelID
        self.expectedEffort = expectedEffort
        self.lifecycle = lifecycle
        self.accent = accent
        self.historicalIdentities = historicalIdentities
    }
}

private struct RoutingRoleHistoricalIdentity: Sendable {
    let modelID: String
    let effort: String
    let validBeforeMs: Int64
}

private enum RoutingRoleCatalog {
    static let active: [RoutingRoleDefinition] = [
        .init(rawValue: "code-explorer", displayName: "代码探索", tierLabel: "Luna High", expectedModelID: "gpt-5.6-luna", expectedEffort: "high", lifecycle: .active, accent: .luna),
        .init(rawValue: "terra-explorer", displayName: "广域探索", tierLabel: "Terra Medium", expectedModelID: "gpt-5.6-terra", expectedEffort: "medium", lifecycle: .active, accent: .terra),
        .init(rawValue: "luna-max-implementer", displayName: "常规实现", tierLabel: "Luna Max", expectedModelID: "gpt-5.6-luna", expectedEffort: "max", lifecycle: .active, accent: .luna),
        .init(rawValue: "terra-high-implementer", displayName: "复杂实现", tierLabel: "Terra High", expectedModelID: "gpt-5.6-terra", expectedEffort: "high", lifecycle: .active, accent: .terra),
        .init(rawValue: "terra-max-implementer", displayName: "大型实现", tierLabel: "Terra Max", expectedModelID: "gpt-5.6-terra", expectedEffort: "max", lifecycle: .active, accent: .terra),
        .init(
            rawValue: "commit-pusher",
            displayName: "Git 提交",
            tierLabel: "Luna High",
            expectedModelID: "gpt-5.6-luna",
            expectedEffort: "high",
            lifecycle: .active,
            accent: .luna,
            historicalIdentities: [
                // Global contract changed to Luna High on 2026-08-01 local time.
                .init(modelID: "gpt-5.6-luna", effort: "low", validBeforeMs: 1_785_513_600_000),
            ]
        ),
    ]

    static let retired: [RoutingRoleDefinition] = [
        .init(rawValue: "quick-implementer", displayName: "快速实现", tierLabel: "Luna High", expectedModelID: "gpt-5.6-luna", expectedEffort: "high", lifecycle: .retired, accent: .luna),
        .init(rawValue: "implementer", displayName: "兼容实现", tierLabel: "Luna High", expectedModelID: "gpt-5.6-luna", expectedEffort: "high", lifecycle: .retired, accent: .luna),
        .init(rawValue: "terra-implementer", displayName: "旧常规实现", tierLabel: "Terra Medium", expectedModelID: "gpt-5.6-terra", expectedEffort: "medium", lifecycle: .retired, accent: .terra),
        .init(rawValue: "sol_ultra_terra", displayName: "旧调查归纳", tierLabel: "Terra Medium", expectedModelID: "gpt-5.6-terra", expectedEffort: "medium", lifecycle: .retired, accent: .terra),
        .init(rawValue: "terra-reviewer", displayName: "旧常规审查", tierLabel: "Terra High", expectedModelID: "gpt-5.6-terra", expectedEffort: "high", lifecycle: .retired, accent: .terra),
        .init(rawValue: "code-reviewer", displayName: "旧高风险审查", tierLabel: "Sol Medium", expectedModelID: "gpt-5.6-sol", expectedEffort: "medium", lifecycle: .retired, accent: .sol),
    ]

    static let all = active + retired
    static let byRawValue = Dictionary(uniqueKeysWithValues: all.map { ($0.rawValue, $0) })
}

/// Stable, privacy-bounded registered role identifier. Unknown source strings
/// fail construction and therefore continue to collapse into the opaque unknown
/// bucket rather than being persisted verbatim.
struct RoutingRegisteredRole: RawRepresentable, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    let rawValue: String

    init?(rawValue: String) {
        guard RoutingRoleCatalog.byRawValue[rawValue] != nil else { return nil }
        self.rawValue = rawValue
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        guard let value = Self(rawValue: rawValue) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unregistered routing role")
        }
        self = value
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    var id: String { rawValue }
    static var allCases: [RoutingRegisteredRole] { RoutingRoleCatalog.all.compactMap { Self(rawValue: $0.rawValue) } }
    static var activeCases: [RoutingRegisteredRole] { RoutingRoleCatalog.active.compactMap { Self(rawValue: $0.rawValue) } }
    static var retiredCases: [RoutingRegisteredRole] { RoutingRoleCatalog.retired.compactMap { Self(rawValue: $0.rawValue) } }

    static let codeExplorer = Self(rawValue: "code-explorer")!
    static let terraExplorer = Self(rawValue: "terra-explorer")!
    static let lunaMaxImplementer = Self(rawValue: "luna-max-implementer")!
    static let terraHighImplementer = Self(rawValue: "terra-high-implementer")!
    static let terraMaxImplementer = Self(rawValue: "terra-max-implementer")!
    static let commitPusher = Self(rawValue: "commit-pusher")!
    static let quickImplementer = Self(rawValue: "quick-implementer")!
    static let implementer = Self(rawValue: "implementer")!
    static let terraImplementer = Self(rawValue: "terra-implementer")!
    static let solUltraTerra = Self(rawValue: "sol_ultra_terra")!
    static let terraReviewer = Self(rawValue: "terra-reviewer")!
    static let codeReviewer = Self(rawValue: "code-reviewer")!

    private var definition: RoutingRoleDefinition { RoutingRoleCatalog.byRawValue[rawValue]! }
    var displayName: String { definition.displayName }
    var tierLabel: String { definition.tierLabel }
    var expectedModelID: String { definition.expectedModelID }
    var expectedEffort: String { definition.expectedEffort }
    var lifecycle: RoutingRoleLifecycle { definition.lifecycle }
    var accent: RoutingRoleAccent { definition.accent }
    var isActive: Bool { lifecycle == .active }
    var isRetired: Bool { lifecycle == .retired }

    func matches(model: String?, effort: String?) -> Bool {
        let normalizedModel = model?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedEffort = effort?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalizedModel == expectedModelID && normalizedEffort == expectedEffort
    }

    func matches(model: String?, effort: String?, createdAtMs: Int64) -> Bool {
        if matches(model: model, effort: effort) { return true }
        guard createdAtMs > 0 else { return false }
        let normalizedModel = model?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedEffort = effort?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return definition.historicalIdentities.contains {
            createdAtMs < $0.validBeforeMs
                && normalizedModel == $0.modelID
                && normalizedEffort == $0.effort
        }
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
    var displayName: String { role?.displayName ?? "未识别角色" }
    var tierLabel: String { role?.tierLabel ?? "未注册" }
    var isActive: Bool { role?.isActive == true }
    var isRetired: Bool { role?.isRetired == true }
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

/// Stable, privacy-safe model family used by the generalized routing metric.
/// Unknown model strings are deliberately collapsed into `other`; the raw
/// value observed in state.sqlite is never persisted in a derived payload.
enum RoutingModelFamily: String, CaseIterable, Codable, Identifiable, Sendable {
    case gpt56Sol = "gpt-5.6-sol"
    case gpt56Luna = "gpt-5.6-luna"
    case gpt56Terra = "gpt-5.6-terra"
    case gpt55 = "gpt-5.5"
    case gpt54 = "gpt-5.4"
    case gpt54Mini = "gpt-5.4-mini"
    case gpt53CodexSpark = "gpt-5.3-codex-spark"
    case codexAutoReview = "codex-auto-review"
    case other = "other"

    var id: String { rawValue }

    static func classify(_ raw: String?) -> RoutingModelFamily {
        let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        if value == "gpt-5.6-sol" || value.hasPrefix("gpt-5.6-sol-") { return .gpt56Sol }
        if value == "gpt-5.6-luna" || value.hasPrefix("gpt-5.6-luna-") { return .gpt56Luna }
        if value == "gpt-5.6-terra" || value.hasPrefix("gpt-5.6-terra-") { return .gpt56Terra }
        if value == "gpt-5.5" || value.hasPrefix("gpt-5.5-") { return .gpt55 }
        // Check mini before the broader 5.4 family so the stable mini bucket
        // cannot be swallowed by the general 5.4 prefix.
        if value == "gpt-5.4-mini" || value.hasPrefix("gpt-5.4-mini-") { return .gpt54Mini }
        if value == "gpt-5.4" || value.hasPrefix("gpt-5.4-") { return .gpt54 }
        if value == "gpt-5.3-codex-spark" || value.hasPrefix("gpt-5.3-codex-spark-") { return .gpt53CodexSpark }
        if value == "codex-auto-review" || value.hasPrefix("codex-auto-review-") { return .codexAutoReview }
        return .other
    }
}

/// Only this finite effort vocabulary is retained in aggregate payloads.
enum RoutingEffortBucket: String, CaseIterable, Codable, Identifiable, Sendable {
    case none, low, medium, high, xhigh, max, ultra, unknown

    var id: String { rawValue }

    static func classify(_ raw: String?) -> RoutingEffortBucket {
        let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        return RoutingEffortBucket(rawValue: value) ?? (value.isEmpty ? .unknown : .unknown)
    }
}

/// A composite parent-root source bucket. Keeping model family and effort
/// together avoids presenting a same-effort model mix as a single fact.
struct RoutingParentSourceBucket: Codable, Equatable, Identifiable, Sendable {
    let modelFamily: RoutingModelFamily
    let effort: RoutingEffortBucket
    let rootThreads: Int
    let rootCumulativeTokens: Int
    let attributedChildThreads: Int
    let attributedChildCumulativeTokens: Int

    var id: String { "\(modelFamily.rawValue)|\(effort.rawValue)" }
    var tokenTotal: Int { saturatedAggregate(rootCumulativeTokens, attributedChildCumulativeTokens) }
    var parentModelFamily: RoutingModelFamily { modelFamily }
    var parentEffort: RoutingEffortBucket { effort }
    var attributedChildTokenShare: Double? {
        let denominator = Double(rootCumulativeTokens) + Double(attributedChildCumulativeTokens)
        guard denominator > 0 else { return nil }
        return Double(attributedChildCumulativeTokens) / denominator
    }
}

/// Aggregate-only generalized routing partition. No raw thread identity,
/// title, path, or unknown model/effort value is retained here.
struct RoutingTokenPartition: Codable, Equatable, Sendable {
    let windowRootThreads: Int
    let windowRootCumulativeTokens: Int
    let routedRootThreads: Int
    let routedRootCumulativeTokens: Int
    let attributedChildThreads: Int
    let attributedChildCumulativeTokens: Int
    let unattributedChildThreads: Int
    let unattributedChildCumulativeTokens: Int
    let parentSourceBuckets: [RoutingParentSourceBucket]
    let rootDailyObservedTokenDelta: Int?
    let attributedChildDailyObservedTokenDelta: Int?
    let dailyDeltaEvidenceComplete: Bool?
    let dailyMergeObservationCount: Int?

    init(
        windowRootThreads: Int,
        windowRootCumulativeTokens: Int,
        routedRootThreads: Int,
        routedRootCumulativeTokens: Int,
        attributedChildThreads: Int,
        attributedChildCumulativeTokens: Int,
        unattributedChildThreads: Int,
        unattributedChildCumulativeTokens: Int,
        parentSourceBuckets: [RoutingParentSourceBucket] = [],
        rootDailyObservedTokenDelta: Int? = nil,
        attributedChildDailyObservedTokenDelta: Int? = nil,
        dailyDeltaEvidenceComplete: Bool? = nil,
        dailyMergeObservationCount: Int? = nil
    ) {
        self.windowRootThreads = windowRootThreads
        self.windowRootCumulativeTokens = windowRootCumulativeTokens
        self.routedRootThreads = routedRootThreads
        self.routedRootCumulativeTokens = routedRootCumulativeTokens
        self.attributedChildThreads = attributedChildThreads
        self.attributedChildCumulativeTokens = attributedChildCumulativeTokens
        self.unattributedChildThreads = unattributedChildThreads
        self.unattributedChildCumulativeTokens = unattributedChildCumulativeTokens
        self.parentSourceBuckets = parentSourceBuckets
        self.rootDailyObservedTokenDelta = rootDailyObservedTokenDelta
        self.attributedChildDailyObservedTokenDelta = attributedChildDailyObservedTokenDelta
        self.dailyDeltaEvidenceComplete = dailyDeltaEvidenceComplete
        self.dailyMergeObservationCount = dailyMergeObservationCount
    }

    /// Main metric: strict attributed child Token over routed-root plus child
    /// Token. Roots without a strictly attributable child are not in the
    /// denominator by design.
    var routingTokenShare: Double? {
        let denominator = Double(routedRootCumulativeTokens) + Double(attributedChildCumulativeTokens)
        guard denominator > 0, routedRootThreads > 0 else { return nil }
        return Double(attributedChildCumulativeTokens) / denominator
    }

    var dailyObservedTokenShare: Double? {
        guard dailyDeltaEvidenceComplete == true,
              let root = rootDailyObservedTokenDelta,
              let child = attributedChildDailyObservedTokenDelta else { return nil }
        let denominator = Double(root) + Double(child)
        guard denominator > 0 else { return nil }
        return Double(child) / denominator
    }

    var routedRootCoverage: Double? {
        guard windowRootThreads > 0 else { return nil }
        return Double(routedRootThreads) / Double(windowRootThreads)
    }

    /// Compatibility aliases make the aggregate's purpose explicit at call
    /// sites while keeping the persisted names concise.
    var rootThreads: Int { windowRootThreads }
    var rootCumulativeTokens: Int { windowRootCumulativeTokens }
    var routedRootTokenShare: Double? { routingTokenShare }
    var strictAttributedChildThreads: Int { attributedChildThreads }
    var strictAttributedChildCumulativeTokens: Int { attributedChildCumulativeTokens }
    var strictUnattributedChildThreads: Int { unattributedChildThreads }
    var strictUnattributedChildCumulativeTokens: Int { unattributedChildCumulativeTokens }
    var parentRootBuckets: [RoutingParentSourceBucket] { parentSourceBuckets }
    var dailyObservedRootTokenDelta: Int? { rootDailyObservedTokenDelta }
    var dailyObservedAttributedChildTokenDelta: Int? { attributedChildDailyObservedTokenDelta }

    func withDailyObservedDelta(root: Int, child: Int, evidenceComplete: Bool, mergeObservationCount: Int) -> RoutingTokenPartition {
        RoutingTokenPartition(
            windowRootThreads: windowRootThreads,
            windowRootCumulativeTokens: windowRootCumulativeTokens,
            routedRootThreads: routedRootThreads,
            routedRootCumulativeTokens: routedRootCumulativeTokens,
            attributedChildThreads: attributedChildThreads,
            attributedChildCumulativeTokens: attributedChildCumulativeTokens,
            unattributedChildThreads: unattributedChildThreads,
            unattributedChildCumulativeTokens: unattributedChildCumulativeTokens,
            parentSourceBuckets: parentSourceBuckets,
            rootDailyObservedTokenDelta: root,
            attributedChildDailyObservedTokenDelta: child,
            dailyDeltaEvidenceComplete: evidenceComplete,
            dailyMergeObservationCount: mergeObservationCount
        )
    }
}

private func saturatedAggregate(_ a: Int, _ b: Int) -> Int {
    let (value, overflow) = a.addingReportingOverflow(b)
    return overflow ? Int.max : value
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

/// Generalized local operational guidance for multi-agent routing intensity.
/// This is a Token-weighted observation band, not an official or community
/// health standard and not a success/performance claim.
enum RoutingDeltaGuidanceState: Equatable, Sendable {
    case unavailable, observing, low, balanced, elevated, excessive
}

struct RoutingDeltaGuidance: Equatable, Sendable {
    static let lowerBound = 0.20
    static let upperBound = 0.35
    static let reviewBound = 0.50
    static let minimumValidDays = 3

    let state: RoutingDeltaGuidanceState
    let validDays: Int
    let weightedShare: Double?

    static func evaluate(_ metrics: [RoutingDailyMetric]) -> RoutingDeltaGuidance {
        var validDays = 0
        var rootTotal = 0.0
        var childTotal = 0.0
        for metric in metrics {
            guard let partition = metric.routingTokenPartition,
                  partition.dailyDeltaEvidenceComplete == true,
                  let root = partition.rootDailyObservedTokenDelta,
                  let child = partition.attributedChildDailyObservedTokenDelta,
                  Double(root) + Double(child) > 0 else { continue }
            validDays += 1
            rootTotal += Double(root)
            childTotal += Double(child)
        }
        let denominator = rootTotal + childTotal
        guard denominator > 0 else {
            return RoutingDeltaGuidance(state: .unavailable, validDays: 0, weightedShare: nil)
        }
        let share = childTotal / denominator
        guard validDays >= minimumValidDays else {
            return RoutingDeltaGuidance(state: .observing, validDays: validDays, weightedShare: share)
        }
        let state: RoutingDeltaGuidanceState
        if share < lowerBound { state = .low }
        else if share <= upperBound { state = .balanced }
        else if share <= reviewBound { state = .elevated }
        else { state = .excessive }
        return RoutingDeltaGuidance(state: state, validDays: validDays, weightedShare: share)
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
    /// nil means a legacy payload or topology-ambiguous snapshot.
    let routingTokenPartition: RoutingTokenPartition?

    var id: String { dayKey }
    var childTokenShare: Double { cumulativeTokens > 0 ? Double(childCumulativeTokens) / Double(cumulativeTokens) : 0 }
    var ultraRoutingTokenShare: Double? { ultraTokenPartition?.ultraRoutingTokenShare }
    var ultraRoutingDailyObservedTokenShare: Double? { ultraTokenPartition?.ultraRoutingDailyObservedTokenShare }
    var routingIntensityTokenShare: Double? { routingTokenPartition?.routingTokenShare }
    var routingDailyObservedTokenShare: Double? { routingTokenPartition?.dailyObservedTokenShare }
    var rootDispatchCoverage: Double? { routingTokenPartition?.routedRootCoverage }

    private enum CodingKeys: String, CodingKey {
        case dayKey, sourceThreads, edgeCount, rootThreads, childThreads, roleMetadataCovered, roleMetadataMissing, depthAtLeastTwo, orphanEdges, cycleAffectedChildren, anonymousSolChildren, cumulativeTokens, childCumulativeTokens, tokenDelta, childTokenDelta, missingBaselines, tokenRollbacks, createdToUpdatedMedianMilliseconds, readRows, derivedWrites, scanMilliseconds, quality, roleBuckets, ultraTokenPartition, routingTokenPartition
    }

    init(dayKey: String, sourceThreads: Int, edgeCount: Int, rootThreads: Int, childThreads: Int, roleMetadataCovered: Int, roleMetadataMissing: Int, depthAtLeastTwo: Int, orphanEdges: Int, cycleAffectedChildren: Int, anonymousSolChildren: Int, cumulativeTokens: Int, childCumulativeTokens: Int, tokenDelta: Int, childTokenDelta: Int, missingBaselines: Int, tokenRollbacks: Int, createdToUpdatedMedianMilliseconds: Int64, readRows: Int, derivedWrites: Int, scanMilliseconds: Int, quality: RoutingTelemetryQuality, roleBuckets: [RoutingRoleBucket]? = nil, ultraTokenPartition: RoutingUltraTokenPartition? = nil, routingTokenPartition: RoutingTokenPartition? = nil) {
        self.dayKey = dayKey; self.sourceThreads = sourceThreads; self.edgeCount = edgeCount; self.rootThreads = rootThreads; self.childThreads = childThreads; self.roleMetadataCovered = roleMetadataCovered; self.roleMetadataMissing = roleMetadataMissing; self.depthAtLeastTwo = depthAtLeastTwo; self.orphanEdges = orphanEdges; self.cycleAffectedChildren = cycleAffectedChildren; self.anonymousSolChildren = anonymousSolChildren; self.cumulativeTokens = cumulativeTokens; self.childCumulativeTokens = childCumulativeTokens; self.tokenDelta = tokenDelta; self.childTokenDelta = childTokenDelta; self.missingBaselines = missingBaselines; self.tokenRollbacks = tokenRollbacks; self.createdToUpdatedMedianMilliseconds = createdToUpdatedMedianMilliseconds; self.readRows = readRows; self.derivedWrites = derivedWrites; self.scanMilliseconds = scanMilliseconds; self.quality = quality; self.roleBuckets = roleBuckets; self.ultraTokenPartition = ultraTokenPartition; self.routingTokenPartition = routingTokenPartition
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(dayKey: try c.decode(String.self, forKey: .dayKey), sourceThreads: try c.decode(Int.self, forKey: .sourceThreads), edgeCount: try c.decode(Int.self, forKey: .edgeCount), rootThreads: try c.decode(Int.self, forKey: .rootThreads), childThreads: try c.decode(Int.self, forKey: .childThreads), roleMetadataCovered: try c.decode(Int.self, forKey: .roleMetadataCovered), roleMetadataMissing: try c.decode(Int.self, forKey: .roleMetadataMissing), depthAtLeastTwo: try c.decode(Int.self, forKey: .depthAtLeastTwo), orphanEdges: try c.decode(Int.self, forKey: .orphanEdges), cycleAffectedChildren: try c.decode(Int.self, forKey: .cycleAffectedChildren), anonymousSolChildren: try c.decode(Int.self, forKey: .anonymousSolChildren), cumulativeTokens: try c.decode(Int.self, forKey: .cumulativeTokens), childCumulativeTokens: try c.decode(Int.self, forKey: .childCumulativeTokens), tokenDelta: try c.decode(Int.self, forKey: .tokenDelta), childTokenDelta: try c.decode(Int.self, forKey: .childTokenDelta), missingBaselines: try c.decode(Int.self, forKey: .missingBaselines), tokenRollbacks: try c.decode(Int.self, forKey: .tokenRollbacks), createdToUpdatedMedianMilliseconds: try c.decode(Int64.self, forKey: .createdToUpdatedMedianMilliseconds), readRows: try c.decode(Int.self, forKey: .readRows), derivedWrites: try c.decode(Int.self, forKey: .derivedWrites), scanMilliseconds: try c.decode(Int.self, forKey: .scanMilliseconds), quality: try c.decode(RoutingTelemetryQuality.self, forKey: .quality), roleBuckets: try c.decodeIfPresent([RoutingRoleBucket].self, forKey: .roleBuckets), ultraTokenPartition: try c.decodeIfPresent(RoutingUltraTokenPartition.self, forKey: .ultraTokenPartition), routingTokenPartition: try c.decodeIfPresent(RoutingTokenPartition.self, forKey: .routingTokenPartition))
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
