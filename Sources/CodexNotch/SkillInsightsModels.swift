import Foundation

enum SkillInsightsQuality: String, Codable, CaseIterable, Sendable {
    case complete = "COMPLETE"
    case partial = "PARTIAL"
    case unavailable = "UNAVAILABLE"

    static func combined(_ values: [SkillInsightsQuality]) -> SkillInsightsQuality {
        if values.contains(.unavailable) {
            return .unavailable
        }
        if values.contains(.partial) {
            return .partial
        }
        return .complete
    }
}

enum SkillEvidenceLevel: String, Codable, CaseIterable, Sendable {
    case direct = "DIRECT"
    case strong = "STRONG"
    case inferred = "INFERRED"
    case shadow = "SHADOW"
}

enum SkillObservationType: String, Codable, CaseIterable, Sendable {
    case confirmedUse = "confirmed_use"
    case inferredUse = "inferred_use"
    case relevanceMatch = "relevance_match"
    case replacementSignal = "replacement_signal"
    case suspectedMiss = "suspected_miss"
    case suspectedMisfire = "suspected_misfire"
    case shadowMatch = "shadow_match"
    case replacedByExisting = "replaced_by_existing"
}

enum SkillRecommendation: String, Codable, CaseIterable, Sendable {
    case keep = "保留"
    case continueObserving = "继续观察"
    case continueDisabled = "继续关闭"
    case retest = "建议复测"
    case restoreCandidate = "恢复候选"
    case noEvidence = "暂无证据"
}

struct SkillCatalogEntry: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let name: String
    let description: String
    let path: String
    let enabled: Bool
    let catalogCharacterCount: Int
    let catalogTokenEstimate: Int
    let protectsHighRiskWorkflow: Bool
}

struct SkillCatalogSnapshot: Codable, Equatable, Sendable {
    let skills: [SkillCatalogEntry]
    let quality: SkillInsightsQuality
    let diagnostics: [String]
    let loadedAt: Date

    var enabledCount: Int {
        skills.lazy.filter(\.enabled).count
    }

    var disabledCount: Int {
        skills.count - enabledCount
    }

    var enabledCatalogTokenEstimate: Int {
        skills.lazy.filter(\.enabled).reduce(0) { $0 + $1.catalogTokenEstimate }
    }

    static let unavailable = SkillCatalogSnapshot(
        skills: [],
        quality: .unavailable,
        diagnostics: ["Skill catalog has not been loaded."],
        loadedAt: .distantPast
    )
}

struct SkillObservationRecord: Codable, Equatable, Sendable {
    let sessionID: String
    let skillID: String
    let skillName: String
    let skillPath: String
    let enabled: Bool
    let evidenceLevel: SkillEvidenceLevel
    let observationType: SkillObservationType
    let observedAt: Date
    let projectID: String?
    let sessionTokens: Int?
    let analyzerVersion: Int
    let quality: SkillInsightsQuality
    let sourceFilePath: String
    let sourceOffset: UInt64
}

struct SkillAnalysisCursorState: Codable, Equatable, Sendable {
    var sessionID: String
    var projectID: String?
    var sessionTokens: Int?
    var turnTimestampMilliseconds: Int64?
    var turnSourceOffset: UInt64
    var relevantSkillIDs: Set<String>
    var directSkillIDs: Set<String>
    var directAmbiguousSkillIDs: Set<String>
    var declaredSkillIDs: Set<String>
    var readSkillIDs: Set<String>
    var structuredSkillIDs: Set<String>
    var replacementSkillIDs: Set<String>

    static func empty(sessionID: String) -> SkillAnalysisCursorState {
        SkillAnalysisCursorState(
            sessionID: sessionID,
            projectID: nil,
            sessionTokens: nil,
            turnTimestampMilliseconds: nil,
            turnSourceOffset: 0,
            relevantSkillIDs: [],
            directSkillIDs: [],
            directAmbiguousSkillIDs: [],
            declaredSkillIDs: [],
            readSkillIDs: [],
            structuredSkillIDs: [],
            replacementSkillIDs: []
        )
    }

    var hasTurnEvidence: Bool {
        turnTimestampMilliseconds != nil
            || !relevantSkillIDs.isEmpty
            || !directSkillIDs.isEmpty
            || !declaredSkillIDs.isEmpty
            || !readSkillIDs.isEmpty
            || !structuredSkillIDs.isEmpty
    }

    mutating func resetTurn(timestampMilliseconds: Int64?, sourceOffset: UInt64) {
        turnTimestampMilliseconds = timestampMilliseconds
        turnSourceOffset = sourceOffset
        relevantSkillIDs.removeAll(keepingCapacity: true)
        directSkillIDs.removeAll(keepingCapacity: true)
        directAmbiguousSkillIDs.removeAll(keepingCapacity: true)
        declaredSkillIDs.removeAll(keepingCapacity: true)
        readSkillIDs.removeAll(keepingCapacity: true)
        structuredSkillIDs.removeAll(keepingCapacity: true)
        replacementSkillIDs.removeAll(keepingCapacity: true)
    }
}

struct SkillFileCheckpoint: Codable, Equatable, Sendable {
    let path: String
    let inode: UInt64
    let size: UInt64
    let modifiedAtNanoseconds: Int64
    let processedOffset: UInt64
    let lastAnalyzedAt: Date
    let status: SkillInsightsQuality
    let discardingOversizedRow: Bool
    let cursorState: SkillAnalysisCursorState
}

struct SkillAnalysisPerformance: Codable, Equatable, Sendable {
    var candidateFiles: Int
    var analyzedFiles: Int
    var unchangedFiles: Int
    var pendingFiles: Int
    var analyzedLines: Int
    var parsedRows: Int
    var filteredRows: Int
    var malformedLines: Int
    var skippedOversizedRows: Int
    var skippedIrrelevantOversizedRows: Int
    var partialFiles: Int
    var analyzedBytes: UInt64
    var boundaryProbeBytes: UInt64
    var cpuMilliseconds: Int
    var diskReadBytes: UInt64
    var diskWriteBytes: UInt64
    var peakPhysicalFootprintBytes: UInt64
    var databaseDurationMilliseconds: Int
    var resourceMetricsAvailable: Bool
    var wasDeferred: Bool
    var durationMilliseconds: Int
    var lastCompletedAt: Date?
    var analyzerVersion: Int
    var modelTokens: Int

    static let empty = SkillAnalysisPerformance(
        candidateFiles: 0,
        analyzedFiles: 0,
        unchangedFiles: 0,
        pendingFiles: 0,
        analyzedLines: 0,
        parsedRows: 0,
        filteredRows: 0,
        malformedLines: 0,
        skippedOversizedRows: 0,
        skippedIrrelevantOversizedRows: 0,
        partialFiles: 0,
        analyzedBytes: 0,
        boundaryProbeBytes: 0,
        cpuMilliseconds: 0,
        diskReadBytes: 0,
        diskWriteBytes: 0,
        peakPhysicalFootprintBytes: 0,
        databaseDurationMilliseconds: 0,
        resourceMetricsAvailable: false,
        wasDeferred: false,
        durationMilliseconds: 0,
        lastCompletedAt: nil,
        analyzerVersion: 2,
        modelTokens: 0
    )
}

struct SkillInsightRow: Codable, Equatable, Identifiable, Sendable {
    let skill: SkillCatalogEntry
    let directCount: Int
    let strongCount: Int
    let inferredCount: Int
    let shadowCount: Int
    let suspectedMissCount: Int
    let suspectedMisfireCount: Int
    let replacedByExistingCount: Int
    let relatedSessionCount: Int
    let relatedSessionTokens: Int
    let recommendation: SkillRecommendation
    let evidenceQuality: SkillInsightsQuality

    var id: String { skill.id }
    var confirmedUseCount: Int { directCount + strongCount }
}

struct SkillInsightsSnapshot: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let windowStartedAt: Date
    let windowEndedAt: Date
    let enabledSkillCount: Int
    let disabledSkillCount: Int
    let enabledCatalogTokenEstimate: Int
    let confirmedUseCount: Int
    let suspectedMissCount: Int
    let suspectedMisfireCount: Int
    let shadowHitCount: Int
    let retestCount: Int
    let quality: SkillInsightsQuality
    let lastAnalyzedAt: Date?
    let rows: [SkillInsightRow]
    let performance: SkillAnalysisPerformance
    let diagnostics: [String]
    let unverified: [String]

    static let empty = SkillInsightsSnapshot(
        schemaVersion: 2,
        windowStartedAt: .distantPast,
        windowEndedAt: .distantPast,
        enabledSkillCount: 0,
        disabledSkillCount: 0,
        enabledCatalogTokenEstimate: 0,
        confirmedUseCount: 0,
        suspectedMissCount: 0,
        suspectedMisfireCount: 0,
        shadowHitCount: 0,
        retestCount: 0,
        quality: .unavailable,
        lastAnalyzedAt: nil,
        rows: [],
        performance: .empty,
        diagnostics: [],
        unverified: ["Skill analysis has not completed." ]
    )
}

enum SkillInsightExportFormat: Sendable {
    case markdown
    case json
}
