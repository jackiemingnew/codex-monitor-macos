import Foundation

enum AGYSidecarDoctorStatus: String, Codable, CaseIterable, Sendable {
    case neverRun = "NEVER_RUN"
    case ready = "READY"
    case compatibilityWarning = "COMPATIBILITY_WARNING"
    case unavailable = "UNAVAILABLE"
    case broken = "BROKEN"
}

enum AGYSidecarE2EStatus: String, Codable, CaseIterable, Sendable {
    case neverRun = "NEVER_RUN"
    case complete = "COMPLETE"
    case partial = "PARTIAL"
    case broken = "BROKEN"
    case unavailable = "UNAVAILABLE"
}

enum AGYSidecarErrorCode: String, Codable, Sendable {
    case pythonUnavailable = "PYTHON_UNAVAILABLE"
    case scriptUnavailable = "SCRIPT_UNAVAILABLE"
    case processFailed = "PROCESS_FAILED"
    case timedOut = "TIMED_OUT"
    case cancelled = "CANCELLED"
    case outputInvalid = "OUTPUT_INVALID"
    case receiptOversized = "RECEIPT_OVERSIZED"
    case fixtureInvalid = "FIXTURE_INVALID"
    case liveCanaryNotAuthorized = "LIVE_CANARY_NOT_AUTHORIZED"
    case sidecarUnavailable = "SIDECAR_UNAVAILABLE"
    case protocolViolation = "PROTOCOL_VIOLATION"
    case findingMissed = "FINDING_MISSED"
    case contractUnsupported = "CONTRACT_UNSUPPORTED"
    case modelRoleUnsupported = "MODEL_ROLE_UNSUPPORTED"
}

struct AGYSidecarModelAvailability: Codable, Equatable, Sendable, Identifiable {
    let model: String
    let available: Bool

    var id: String { model }
}

struct AGYSidecarDoctorSnapshot: Codable, Equatable, Sendable {
    let status: AGYSidecarDoctorStatus
    let checkedAt: Date?
    let models: [AGYSidecarModelAvailability]
    let repositoryModeReady: Bool
    let errorCode: AGYSidecarErrorCode?

    static let neverRun = AGYSidecarDoctorSnapshot(
        status: .neverRun,
        checkedAt: nil,
        models: [],
        repositoryModeReady: false,
        errorCode: nil
    )
}

struct AGYSidecarSourceSummary: Codable, Equatable, Sendable {
    let kind: String
    let diffDelivery: String?
    let originalRepositoryExposed: Bool?
    let gitMetadataExposed: Bool?
    let snapshotReadOnly: Bool?
    let untrackedFilesOmitted: Int?
}

struct AGYSidecarToolAuditSummary: Codable, Equatable, Sendable {
    let snapshotDiffReads: Int
    let readOnlyFileCalls: Int
    let otherToolCalls: Int
}

struct AGYSidecarTokenUsage: Codable, Equatable, Sendable {
    let input: Int?
    let output: Int?
    let thinking: Int?
    let cacheRead: Int?
    let total: Int?

    static let unavailable = AGYSidecarTokenUsage(
        input: nil,
        output: nil,
        thinking: nil,
        cacheRead: nil,
        total: nil
    )

    var isComplete: Bool {
        input != nil && output != nil && thinking != nil && cacheRead != nil && total != nil
    }
}

struct AGYSidecarE2ESnapshot: Codable, Equatable, Sendable {
    let status: AGYSidecarE2EStatus
    let checkedAt: Date?
    let wrapperStatus: String?
    let attemptedModels: [String]
    let secondaryRequired: Bool?
    let source: AGYSidecarSourceSummary?
    let toolAudit: AGYSidecarToolAuditSummary?
    let usage: AGYSidecarTokenUsage
    let receiptBytes: Int?
    let findingMatched: Bool?
    let codexTokenUsage: Int?
    let errorCode: AGYSidecarErrorCode?

    static let neverRun = AGYSidecarE2ESnapshot(
        status: .neverRun,
        checkedAt: nil,
        wrapperStatus: nil,
        attemptedModels: [],
        secondaryRequired: nil,
        source: nil,
        toolAudit: nil,
        usage: .unavailable,
        receiptBytes: nil,
        findingMatched: nil,
        codexTokenUsage: nil,
        errorCode: nil
    )

    var codexTokenUsageLabel: String {
        codexTokenUsage.map { "CODEX_TOKEN_USAGE=\($0)" }
            ?? "CODEX_TOKEN_USAGE=UNAVAILABLE"
    }
}

struct AGYSidecarHealthCacheEntry: Codable, Equatable, Sendable {
    let doctor: AGYSidecarDoctorSnapshot
    let e2e: AGYSidecarE2ESnapshot
}

enum AGYSidecarHealthPolicy {
    static let currentContractVersion = 1
    static let receiptByteLimit = 96 * 1024
    static let doctorFreshness: TimeInterval = 6 * 60 * 60
    static let minimumAutomaticCanaryInterval: TimeInterval = 24 * 60 * 60
    static let maximumAutomaticCanaryInterval: TimeInterval = 30 * 24 * 60 * 60
    static let defaultAutomaticCanaryInterval: TimeInterval = 7 * 24 * 60 * 60
    static let doctorTimeout: TimeInterval = 35
    static let reviewTimeout: TimeInterval = 420
    static let liveCanaryAuthorized = false

    static let primaryModel = "gemini-3.7-flash-high"
    static let secondaryModel = "claude-sonnet-4-6"
    static let primaryModelFamily = "gemini-flash-high"
    static let secondaryModelFamily = "claude-sonnet"
    static let canaryTask = "Review the deliberate clamp regression; no production code is in scope and no tests were run before review."

    static func automaticInterval(_ value: TimeInterval) -> TimeInterval {
        min(maximumAutomaticCanaryInterval, max(minimumAutomaticCanaryInterval, value))
    }

    static func doctorIsFresh(_ snapshot: AGYSidecarDoctorSnapshot, now: Date) -> Bool {
        guard snapshot.status != .neverRun, let checkedAt = snapshot.checkedAt else { return false }
        let age = now.timeIntervalSince(checkedAt)
        return age >= 0 && age < doctorFreshness
    }
}
