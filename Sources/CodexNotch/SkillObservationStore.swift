import Darwin
import Foundation
import SQLite3

final class SkillObservationStore: @unchecked Sendable {
    private struct AggregateRow {
        let skillID: String
        let directCount: Int
        let strongCount: Int
        let inferredCount: Int
        let relevanceCount: Int
        let unusedRelevanceCount: Int
        let suspectedMisfireCount: Int
        let replacementSignalCount: Int
        let partialEvidenceCount: Int
    }

    private struct RelatedTokenRow {
        let skillID: String
        let relatedSessionCount: Int
        let relatedSessionTokens: Int
    }

    static func defaultDatabaseURL() -> URL {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        return applicationSupport
            .appendingPathComponent("CodexNotch", isDirectory: true)
            .appendingPathComponent("skill-observations.sqlite")
    }

    private static let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    private static let automaticInterval: TimeInterval = 7 * 24 * 60 * 60
    private let databaseURL: URL
    private let lock = NSRecursiveLock()
    private var connection: OpaquePointer?

    init(databaseURL: URL = SkillObservationStore.defaultDatabaseURL()) {
        self.databaseURL = databaseURL
    }

    deinit {
        lock.lock()
        if let connection {
            sqlite3_close(connection)
        }
        connection = nil
        lock.unlock()
    }

    var databasePath: String { databaseURL.path }

    func storedAnalysisFingerprint() -> String? {
        metadataValue(for: "analysis_fingerprint")
    }

    func saveAnalysisFingerprint(
        _ fingerprint: String,
        shouldCancel: @escaping @Sendable () -> Bool = { false }
    ) throws {
        try throwIfCancelled(shouldCancel)
        try withConnection { database in
            try transaction(database) {
                try throwIfCancelled(shouldCancel)
                try setMetadataLocked(key: "analysis_fingerprint", value: fingerprint, database: database)
                try throwIfCancelled(shouldCancel)
            }
        }
    }

    func checkpoints(for paths: [String]) throws -> [String: SkillFileCheckpoint] {
        try withConnection { database in
            let statement = try prepare(
                """
                select path, inode, size, modified_at_nanoseconds, processed_offset,
                       last_analyzed_ms, status, discarding_oversized_row, cursor_state_json,
                       oversized_row_classification
                from skill_scan_files where path = ?;
                """,
                database: database
            )
            defer { sqlite3_finalize(statement) }
            var result: [String: SkillFileCheckpoint] = [:]
            for path in Set(paths) {
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
                try bind(path, to: statement, at: 1, database: database)
                guard sqlite3_step(statement) == SQLITE_ROW,
                      let checkpoint = checkpoint(from: statement) else {
                    continue
                }
                result[path] = checkpoint
            }
            return result
        }
    }

    func removeDerivedData(
        for paths: [String],
        shouldCancel: @escaping @Sendable () -> Bool = { false }
    ) throws {
        guard !paths.isEmpty else { return }
        try throwIfCancelled(shouldCancel)
        try withConnection { database in
            try transaction(database) {
                try throwIfCancelled(shouldCancel)
                let observationDelete = try prepare(
                    "delete from skill_observations where source_file_path = ?;",
                    database: database
                )
                defer { sqlite3_finalize(observationDelete) }
                let checkpointDelete = try prepare(
                    "delete from skill_scan_files where path = ?;",
                    database: database
                )
                defer { sqlite3_finalize(checkpointDelete) }
                for path in Set(paths) {
                    try throwIfCancelled(shouldCancel)
                    try executeBoundText(observationDelete, value: path, database: database)
                    try executeBoundText(checkpointDelete, value: path, database: database)
                }
                try throwIfCancelled(shouldCancel)
            }
        }
    }

    func persist(
        _ observations: [SkillObservationRecord],
        checkpoint: SkillFileCheckpoint,
        shouldCancel: @escaping @Sendable () -> Bool = { false }
    ) throws {
        try throwIfCancelled(shouldCancel)
        let cursorData = try JSONEncoder().encode(checkpoint.cursorState)
        let cursorJSON = String(decoding: cursorData, as: UTF8.self)
        try withConnection { database in
            try transaction(database) {
                try throwIfCancelled(shouldCancel)
                let observationStatement = try prepare(
                    """
                    insert or ignore into skill_observations(
                      session_id, skill_id, skill_name, skill_path, enabled,
                      evidence_level, observation_type, observed_at_ms, project_id,
                      session_tokens, analyzer_version, quality, source_file_path, source_offset
                    ) values(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
                    """,
                    database: database
                )
                defer { sqlite3_finalize(observationStatement) }
                for (index, observation) in observations.enumerated() {
                    if index.isMultiple(of: 128) {
                        try throwIfCancelled(shouldCancel)
                    }
                    sqlite3_reset(observationStatement)
                    sqlite3_clear_bindings(observationStatement)
                    try bind(observation.sessionID, to: observationStatement, at: 1, database: database)
                    try bind(observation.skillID, to: observationStatement, at: 2, database: database)
                    try bind(observation.skillName, to: observationStatement, at: 3, database: database)
                    try bind(observation.skillPath, to: observationStatement, at: 4, database: database)
                    sqlite3_bind_int(observationStatement, 5, observation.enabled ? 1 : 0)
                    try bind(observation.evidenceLevel.rawValue, to: observationStatement, at: 6, database: database)
                    try bind(observation.observationType.rawValue, to: observationStatement, at: 7, database: database)
                    sqlite3_bind_int64(observationStatement, 8, milliseconds(observation.observedAt))
                    try bind(observation.projectID, to: observationStatement, at: 9, database: database)
                    if let sessionTokens = observation.sessionTokens {
                        sqlite3_bind_int64(observationStatement, 10, Int64(sessionTokens))
                    } else {
                        sqlite3_bind_null(observationStatement, 10)
                    }
                    sqlite3_bind_int(observationStatement, 11, Int32(observation.analyzerVersion))
                    try bind(observation.quality.rawValue, to: observationStatement, at: 12, database: database)
                    try bind(observation.sourceFilePath, to: observationStatement, at: 13, database: database)
                    sqlite3_bind_int64(observationStatement, 14, Int64(clamping: observation.sourceOffset))
                    guard sqlite3_step(observationStatement) == SQLITE_DONE else {
                        throw sqliteError(database)
                    }
                }

                try throwIfCancelled(shouldCancel)
                let checkpointStatement = try prepare(
                    """
                    insert into skill_scan_files(
                      path, inode, size, modified_at_nanoseconds, processed_offset,
                      last_analyzed_ms, status, discarding_oversized_row, cursor_state_json,
                      oversized_row_classification
                    ) values(?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    on conflict(path) do update set
                      inode = excluded.inode,
                      size = excluded.size,
                      modified_at_nanoseconds = excluded.modified_at_nanoseconds,
                      processed_offset = excluded.processed_offset,
                      last_analyzed_ms = excluded.last_analyzed_ms,
                      status = excluded.status,
                      discarding_oversized_row = excluded.discarding_oversized_row,
                      cursor_state_json = excluded.cursor_state_json,
                      oversized_row_classification = excluded.oversized_row_classification;
                    """,
                    database: database
                )
                defer { sqlite3_finalize(checkpointStatement) }
                try bind(checkpoint.path, to: checkpointStatement, at: 1, database: database)
                sqlite3_bind_int64(checkpointStatement, 2, Int64(clamping: checkpoint.inode))
                sqlite3_bind_int64(checkpointStatement, 3, Int64(clamping: checkpoint.size))
                sqlite3_bind_int64(checkpointStatement, 4, checkpoint.modifiedAtNanoseconds)
                sqlite3_bind_int64(checkpointStatement, 5, Int64(clamping: checkpoint.processedOffset))
                sqlite3_bind_int64(checkpointStatement, 6, milliseconds(checkpoint.lastAnalyzedAt))
                try bind(checkpoint.status.rawValue, to: checkpointStatement, at: 7, database: database)
                sqlite3_bind_int(checkpointStatement, 8, checkpoint.discardingOversizedRow ? 1 : 0)
                try bind(cursorJSON, to: checkpointStatement, at: 9, database: database)
                try bind(
                    checkpoint.oversizedRowClassification?.rawValue,
                    to: checkpointStatement,
                    at: 10,
                    database: database
                )
                guard sqlite3_step(checkpointStatement) == SQLITE_DONE else {
                    throw sqliteError(database)
                }
                try throwIfCancelled(shouldCancel)
            }
        }
    }

    func recordRun(
        _ performance: SkillAnalysisPerformance,
        quality: SkillInsightsQuality,
        shouldCancel: @escaping @Sendable () -> Bool = { false }
    ) throws {
        try throwIfCancelled(shouldCancel)
        guard let completedAt = performance.lastCompletedAt else {
            throw SkillObservationStoreError.unavailable
        }
        try withConnection { database in
            try transaction(database) {
                try throwIfCancelled(shouldCancel)
                let statement = try prepare(
                    """
                    insert into skill_scan_runs(
                      completed_at_ms, quality, candidate_files, analyzed_files, unchanged_files,
                      pending_files, analyzed_lines, parsed_rows, filtered_rows, malformed_lines,
                      skipped_oversized_rows, skipped_irrelevant_oversized_rows, partial_files,
                      analyzed_bytes, boundary_probe_bytes, cpu_ms, disk_read_bytes,
                      disk_write_bytes, peak_physical_footprint_bytes, database_duration_ms,
                      resource_metrics_available, was_deferred, duration_ms, analyzer_version, model_tokens
                    ) values(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0);
                    """,
                    database: database
                )
                defer { sqlite3_finalize(statement) }
                sqlite3_bind_int64(statement, 1, milliseconds(completedAt))
                try bind(quality.rawValue, to: statement, at: 2, database: database)
                let values = [
                    performance.candidateFiles, performance.analyzedFiles, performance.unchangedFiles,
                    performance.pendingFiles, performance.analyzedLines, performance.parsedRows,
                    performance.filteredRows, performance.malformedLines, performance.skippedOversizedRows,
                    performance.skippedIrrelevantOversizedRows, performance.partialFiles
                ]
                for (index, value) in values.enumerated() {
                    sqlite3_bind_int64(statement, Int32(index + 3), Int64(value))
                }
                sqlite3_bind_int64(statement, 14, Int64(clamping: performance.analyzedBytes))
                sqlite3_bind_int64(statement, 15, Int64(clamping: performance.boundaryProbeBytes))
                sqlite3_bind_int64(statement, 16, Int64(performance.cpuMilliseconds))
                sqlite3_bind_int64(statement, 17, Int64(clamping: performance.diskReadBytes))
                sqlite3_bind_int64(statement, 18, Int64(clamping: performance.diskWriteBytes))
                sqlite3_bind_int64(statement, 19, Int64(clamping: performance.peakPhysicalFootprintBytes))
                sqlite3_bind_int64(statement, 20, Int64(performance.databaseDurationMilliseconds))
                sqlite3_bind_int(statement, 21, performance.resourceMetricsAvailable ? 1 : 0)
                sqlite3_bind_int(statement, 22, performance.wasDeferred ? 1 : 0)
                sqlite3_bind_int64(statement, 23, Int64(performance.durationMilliseconds))
                sqlite3_bind_int64(statement, 24, Int64(performance.analyzerVersion))
                guard sqlite3_step(statement) == SQLITE_DONE else {
                    throw sqliteError(database)
                }
                try throwIfCancelled(shouldCancel)
            }
        }
    }

    func latestRun() -> (performance: SkillAnalysisPerformance, quality: SkillInsightsQuality)? {
        try? withConnection { database in
            let statement = try prepare(
                """
                select completed_at_ms, quality, candidate_files, analyzed_files, unchanged_files,
                       pending_files, analyzed_lines, parsed_rows, filtered_rows, malformed_lines,
                       skipped_oversized_rows, skipped_irrelevant_oversized_rows, partial_files,
                       analyzed_bytes, boundary_probe_bytes, cpu_ms, disk_read_bytes,
                       disk_write_bytes, peak_physical_footprint_bytes, database_duration_ms,
                       resource_metrics_available, was_deferred, duration_ms, analyzer_version
                from skill_scan_runs where was_deferred = 0
                order by completed_at_ms desc limit 1;
                """,
                database: database
            )
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW,
                  let qualityText = text(statement, 1),
                  let quality = SkillInsightsQuality(rawValue: qualityText) else {
                return nil
            }
            return (
                SkillAnalysisPerformance(
                    candidateFiles: integer(statement, 2),
                    analyzedFiles: integer(statement, 3),
                    unchangedFiles: integer(statement, 4),
                    pendingFiles: integer(statement, 5),
                    analyzedLines: integer(statement, 6),
                    parsedRows: integer(statement, 7),
                    filteredRows: integer(statement, 8),
                    malformedLines: integer(statement, 9),
                    skippedOversizedRows: integer(statement, 10),
                    skippedIrrelevantOversizedRows: integer(statement, 11),
                    partialFiles: integer(statement, 12),
                    analyzedBytes: unsigned(statement, 13),
                    boundaryProbeBytes: unsigned(statement, 14),
                    cpuMilliseconds: integer(statement, 15),
                    diskReadBytes: unsigned(statement, 16),
                    diskWriteBytes: unsigned(statement, 17),
                    peakPhysicalFootprintBytes: unsigned(statement, 18),
                    databaseDurationMilliseconds: integer(statement, 19),
                    resourceMetricsAvailable: sqlite3_column_int(statement, 20) != 0,
                    wasDeferred: sqlite3_column_int(statement, 21) != 0,
                    durationMilliseconds: integer(statement, 22),
                    lastCompletedAt: Date(
                        timeIntervalSince1970: Double(sqlite3_column_int64(statement, 0)) / 1_000
                    ),
                    analyzerVersion: integer(statement, 23),
                    modelTokens: 0
                ),
                quality
            )
        }
    }

    func buildSnapshot(
        catalog: SkillCatalogSnapshot,
        now: Date,
        windowDays: Int = 7,
        extraDiagnostics: [String] = []
    ) -> SkillInsightsSnapshot {
        let windowStart = now.addingTimeInterval(-TimeInterval(windowDays * 24 * 60 * 60))
        let aggregates = aggregateRows(from: windowStart, to: now)
        let tokenRows = relatedTokenRows(from: windowStart, to: now)
        let aggregateByID = Dictionary(uniqueKeysWithValues: aggregates.map { ($0.skillID, $0) })
        let tokensByID = Dictionary(uniqueKeysWithValues: tokenRows.map { ($0.skillID, $0) })
        let latest = latestRun()
        let latestDeferral = automaticDeferral()
        let expectedFingerprint = SkillCatalogLoader.analysisFingerprint(
            for: catalog.skills,
            analyzerVersion: SkillSessionAnalyzer.analyzerVersion
        )
        let legacyFingerprint = SkillCatalogLoader.legacyAnalysisFingerprint(
            for: catalog.skills,
            analyzerVersion: SkillSessionAnalyzer.analyzerVersion
        )
        let storedFingerprint = storedAnalysisFingerprint()
        let catalogMatchesLatestAnalysis = storedFingerprint == expectedFingerprint
            || storedFingerprint == legacyFingerprint

        let rows = catalog.skills.map { skill -> SkillInsightRow in
            let aggregate = aggregateByID[skill.id]
            let tokens = tokensByID[skill.id]
            let direct = aggregate?.directCount ?? 0
            let strong = aggregate?.strongCount ?? 0
            let inferred = aggregate?.inferredCount ?? 0
            let relevance = aggregate?.relevanceCount ?? 0
            let unusedRelevance = aggregate?.unusedRelevanceCount ?? 0
            let shadow = skill.enabled ? 0 : relevance
            let misses = skill.enabled ? unusedRelevance : 0
            let misfires = aggregate?.suspectedMisfireCount ?? 0
            let replaced = skill.enabled ? 0 : (aggregate?.replacementSignalCount ?? 0)
            let recommendation = recommendation(
                for: skill,
                direct: direct,
                strong: strong,
                inferred: inferred,
                shadow: shadow,
                misses: misses,
                misfires: misfires
            )
            let evidenceQuality: SkillInsightsQuality
            if latest == nil {
                evidenceQuality = .unavailable
            } else if catalog.quality == .partial
                || latest?.quality == .partial
                || !catalogMatchesLatestAnalysis
                || (aggregate?.partialEvidenceCount ?? 0) > 0 {
                evidenceQuality = .partial
            } else {
                evidenceQuality = .complete
            }
            return SkillInsightRow(
                skill: skill,
                directCount: direct,
                strongCount: strong,
                inferredCount: inferred,
                shadowCount: shadow,
                suspectedMissCount: misses,
                suspectedMisfireCount: misfires,
                replacedByExistingCount: replaced,
                relatedSessionCount: tokens?.relatedSessionCount ?? 0,
                relatedSessionTokens: tokens?.relatedSessionTokens ?? 0,
                recommendation: recommendation,
                evidenceQuality: evidenceQuality
            )
        }
        .sorted {
            if $0.skill.enabled != $1.skill.enabled {
                return $0.skill.enabled && !$1.skill.enabled
            }
            if $0.confirmedUseCount != $1.confirmedUseCount {
                return $0.confirmedUseCount > $1.confirmedUseCount
            }
            if $0.shadowCount != $1.shadowCount {
                return $0.shadowCount > $1.shadowCount
            }
            return $0.skill.name.localizedCaseInsensitiveCompare($1.skill.name) == .orderedAscending
        }

        let quality: SkillInsightsQuality
        if latest == nil || catalog.quality == .unavailable {
            quality = .unavailable
        } else if !catalogMatchesLatestAnalysis {
            quality = .partial
        } else {
            quality = SkillInsightsQuality.combined([catalog.quality, latest!.quality])
        }
        var unverified = [
            "Per-Skill Token attribution is UNAVAILABLE; related Session Tokens are reference totals only.",
            "INFERRED, suspected miss, suspected misfire, replacement, and SHADOW matches are deterministic heuristics, not confirmed activation."
        ]
        if quality != .complete {
            unverified.append("The seven-day report is incomplete; PARTIAL files and catalog diagnostics may omit evidence.")
        }
        if latest != nil, !catalogMatchesLatestAnalysis {
            unverified.append("The Skill catalog changed after the latest analysis; evidence is pending reanalysis.")
        }
        var performance = latest?.performance ?? .empty
        var diagnostics = catalog.diagnostics + extraDiagnostics
        if let latestDeferral,
           latest?.performance.lastCompletedAt.map({ latestDeferral.date > $0 }) ?? true {
            performance.wasDeferred = true
            diagnostics.append("Automatic Skill analysis was deferred: \(latestDeferral.reason).")
        }
        return SkillInsightsSnapshot(
            schemaVersion: 2,
            windowStartedAt: windowStart,
            windowEndedAt: now,
            enabledSkillCount: catalog.enabledCount,
            disabledSkillCount: catalog.disabledCount,
            enabledCatalogTokenEstimate: catalog.enabledCatalogTokenEstimate,
            confirmedUseCount: rows.reduce(0) { $0 + $1.confirmedUseCount },
            suspectedMissCount: rows.reduce(0) { $0 + $1.suspectedMissCount },
            suspectedMisfireCount: rows.reduce(0) { $0 + $1.suspectedMisfireCount },
            shadowHitCount: rows.reduce(0) { $0 + $1.shadowCount },
            retestCount: rows.filter { $0.recommendation == .retest || $0.recommendation == .restoreCandidate }.count,
            quality: quality,
            lastAnalyzedAt: latest?.performance.lastCompletedAt,
            rows: rows,
            performance: performance,
            diagnostics: Array(Set(diagnostics)).sorted(),
            unverified: unverified
        )
    }

    func shouldRunAutomatically(now: Date) -> Bool {
        guard let last = metadataDate(for: "last_automatic_run_ms") else {
            return true
        }
        return now.timeIntervalSince(last) >= Self.automaticInterval
    }

    func nextAutomaticRunDate(now: Date = Date()) -> Date {
        guard let last = metadataDate(for: "last_automatic_run_ms") else {
            return now
        }
        return max(now, last.addingTimeInterval(Self.automaticInterval))
    }

    func markAutomaticRun(
        at date: Date,
        shouldCancel: @escaping @Sendable () -> Bool = { false }
    ) throws {
        try throwIfCancelled(shouldCancel)
        try withConnection { database in
            try transaction(database) {
                try throwIfCancelled(shouldCancel)
                try setMetadataLocked(
                    key: "last_automatic_run_ms",
                    value: String(milliseconds(date)),
                    database: database
                )
                try setMetadataLocked(key: "last_automatic_deferred_ms", value: "", database: database)
                try setMetadataLocked(key: "last_automatic_deferred_reason", value: "", database: database)
                try throwIfCancelled(shouldCancel)
            }
        }
    }

    func markAutomaticDeferral(
        at date: Date,
        reason: String,
        shouldCancel: @escaping @Sendable () -> Bool = { false }
    ) throws {
        try throwIfCancelled(shouldCancel)
        try withConnection { database in
            try transaction(database) {
                try throwIfCancelled(shouldCancel)
                let stamp = String(milliseconds(date))
                try setMetadataLocked(key: "last_automatic_run_ms", value: stamp, database: database)
                try setMetadataLocked(key: "last_automatic_deferred_ms", value: stamp, database: database)
                try setMetadataLocked(key: "last_automatic_deferred_reason", value: reason, database: database)
                try throwIfCancelled(shouldCancel)
            }
        }
    }

    func enforceRetention(
        now: Date,
        retentionDays: Int = 30,
        shouldCancel: @escaping @Sendable () -> Bool = { false }
    ) throws {
        try throwIfCancelled(shouldCancel)
        if let last = metadataDate(for: "last_retention_ms"),
           now.timeIntervalSince(last) < Self.automaticInterval {
            return
        }
        let cutoff = milliseconds(now.addingTimeInterval(-TimeInterval(retentionDays * 24 * 60 * 60)))
        try withConnection { database in
            try transaction(database) {
                try throwIfCancelled(shouldCancel)
                try exec("delete from skill_observations where observed_at_ms < \(cutoff);", database: database)
                try throwIfCancelled(shouldCancel)
                try exec("delete from skill_scan_runs where completed_at_ms < \(cutoff);", database: database)
                try throwIfCancelled(shouldCancel)
                try exec("delete from skill_scan_files where last_analyzed_ms < \(cutoff);", database: database)
                try throwIfCancelled(shouldCancel)
                try setMetadataLocked(
                    key: "last_retention_ms",
                    value: String(milliseconds(now)),
                    database: database
                )
                try throwIfCancelled(shouldCancel)
            }
        }
    }

    private func aggregateRows(from start: Date, to end: Date) -> [AggregateRow] {
        (try? withConnection { database in
            let statement = try prepare(
                """
                with classified as (
                  select o.*,
                    case when o.observation_type = 'relevance_match' and not exists (
                      select 1 from skill_observations u
                      where u.source_file_path = o.source_file_path
                        and u.source_offset = o.source_offset
                        and u.skill_id = o.skill_id
                        and u.observation_type in ('confirmed_use', 'inferred_use')
                    ) then 1 else 0 end as unused_relevance
                  from skill_observations o
                  where o.observed_at_ms >= ? and o.observed_at_ms <= ?
                )
                select skill_id,
                  sum(case when evidence_level = 'DIRECT' and observation_type = 'confirmed_use' then 1 else 0 end),
                  sum(case when evidence_level = 'STRONG' and observation_type = 'confirmed_use' then 1 else 0 end),
                  sum(case when evidence_level = 'INFERRED' and observation_type = 'inferred_use' then 1 else 0 end),
                  sum(case when observation_type = 'relevance_match' then 1 else 0 end),
                  sum(unused_relevance),
                  sum(case when observation_type = 'suspected_misfire' then 1 else 0 end),
                  sum(case when observation_type = 'replacement_signal' then 1 else 0 end),
                  sum(case when quality != 'COMPLETE' then 1 else 0 end)
                from classified group by skill_id;
                """,
                database: database
            )
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_int64(statement, 1, milliseconds(start))
            sqlite3_bind_int64(statement, 2, milliseconds(end))
            var rows: [AggregateRow] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let skillID = text(statement, 0) else { continue }
                rows.append(AggregateRow(
                    skillID: skillID,
                    directCount: integer(statement, 1),
                    strongCount: integer(statement, 2),
                    inferredCount: integer(statement, 3),
                    relevanceCount: integer(statement, 4),
                    unusedRelevanceCount: integer(statement, 5),
                    suspectedMisfireCount: integer(statement, 6),
                    replacementSignalCount: integer(statement, 7),
                    partialEvidenceCount: integer(statement, 8)
                ))
            }
            return rows
        }) ?? []
    }

    private func relatedTokenRows(from start: Date, to end: Date) -> [RelatedTokenRow] {
        (try? withConnection { database in
            let statement = try prepare(
                """
                select skill_id, count(*), coalesce(sum(session_tokens), 0)
                from (
                  select skill_id, session_id, max(coalesce(session_tokens, 0)) as session_tokens
                  from skill_observations
                  where observed_at_ms >= ? and observed_at_ms <= ?
                  group by skill_id, session_id
                ) group by skill_id;
                """,
                database: database
            )
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_int64(statement, 1, milliseconds(start))
            sqlite3_bind_int64(statement, 2, milliseconds(end))
            var rows: [RelatedTokenRow] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let skillID = text(statement, 0) else { continue }
                rows.append(RelatedTokenRow(
                    skillID: skillID,
                    relatedSessionCount: integer(statement, 1),
                    relatedSessionTokens: integer(statement, 2)
                ))
            }
            return rows
        }) ?? []
    }

    private func recommendation(
        for skill: SkillCatalogEntry,
        direct: Int,
        strong: Int,
        inferred: Int,
        shadow: Int,
        misses: Int,
        misfires: Int
    ) -> SkillRecommendation {
        if direct + strong > 0 {
            return skill.enabled ? .keep : .restoreCandidate
        }
        if !skill.enabled {
            if shadow >= 2 || (shadow >= 1 && skill.protectsHighRiskWorkflow) {
                return .retest
            }
            return .continueDisabled
        }
        if misses > 0 || misfires > 0 { return .retest }
        if inferred > 0 { return .continueObserving }
        return .noEvidence
    }

    private func metadataDate(for key: String) -> Date? {
        guard let value = metadataValue(for: key), let milliseconds = Int64(value) else {
            return nil
        }
        return Date(timeIntervalSince1970: Double(milliseconds) / 1_000)
    }

    private func automaticDeferral() -> (date: Date, reason: String)? {
        guard let date = metadataDate(for: "last_automatic_deferred_ms"),
              let reason = metadataValue(for: "last_automatic_deferred_reason"),
              !reason.isEmpty else {
            return nil
        }
        return (date, reason)
    }

    private func metadataValue(for key: String) -> String? {
        try? withConnection { database in
            let statement = try prepare("select value from skill_metadata where key = ? limit 1;", database: database)
            defer { sqlite3_finalize(statement) }
            try bind(key, to: statement, at: 1, database: database)
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            return text(statement, 0)
        }
    }

    private func setMetadataLocked(key: String, value: String, database: OpaquePointer) throws {
        let statement = try prepare(
            """
            insert into skill_metadata(key, value) values(?, ?)
            on conflict(key) do update set value = excluded.value;
            """,
            database: database
        )
        defer { sqlite3_finalize(statement) }
        try bind(key, to: statement, at: 1, database: database)
        try bind(value, to: statement, at: 2, database: database)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw sqliteError(database) }
    }

    private func throwIfCancelled(_ shouldCancel: @Sendable () -> Bool) throws {
        if shouldCancel() {
            throw SkillObservationStoreError.cancelled
        }
    }

    private func withConnection<T>(_ operation: (OpaquePointer) throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        let database = try openIfNeeded()
        return try operation(database)
    }

    private func openIfNeeded() throws -> OpaquePointer {
        if let connection { return connection }
        let directory = databaseURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        _ = chmod(directory.path, mode_t(0o700))
        var opened: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(databasePath, &opened, flags, nil) == SQLITE_OK,
              let opened else {
            if let opened { sqlite3_close(opened) }
            throw SkillObservationStoreError.unavailable
        }
        sqlite3_busy_timeout(opened, 1_000)
        do {
            try exec(schemaSQL, database: opened)
            try migrateSchema(database: opened)
            _ = chmod(databasePath, mode_t(0o600))
            connection = opened
            return opened
        } catch {
            sqlite3_close(opened)
            throw error
        }
    }

    private func migrateSchema(database: OpaquePointer) throws {
        let columns: [(String, String)] = [
            ("candidate_files", "integer not null default 0"),
            ("pending_files", "integer not null default 0"),
            ("parsed_rows", "integer not null default 0"),
            ("filtered_rows", "integer not null default 0"),
            ("skipped_irrelevant_oversized_rows", "integer not null default 0"),
            ("boundary_probe_bytes", "integer not null default 0"),
            ("cpu_ms", "integer not null default 0"),
            ("disk_read_bytes", "integer not null default 0"),
            ("disk_write_bytes", "integer not null default 0"),
            ("peak_physical_footprint_bytes", "integer not null default 0"),
            ("database_duration_ms", "integer not null default 0"),
            ("resource_metrics_available", "integer not null default 0"),
            ("was_deferred", "integer not null default 0")
        ]
        let existing = try tableColumns("skill_scan_runs", database: database)
        for (name, definition) in columns where !existing.contains(name) {
            try exec("alter table skill_scan_runs add column \(name) \(definition);", database: database)
        }
        let scanFileColumns = try tableColumns("skill_scan_files", database: database)
        if !scanFileColumns.contains("oversized_row_classification") {
            try exec(
                "alter table skill_scan_files add column oversized_row_classification text;",
                database: database
            )
        }

        if try metadataValueLocked(for: "neutral_evidence_migration_v1", database: database) == nil {
            try transaction(database) {
                try exec(
                    """
                    delete from skill_observations as legacy
                    where legacy.observation_type in ('suspected_miss', 'shadow_match')
                      and exists (
                        select 1 from skill_observations as neutral
                        where neutral.source_file_path = legacy.source_file_path
                          and neutral.source_offset = legacy.source_offset
                          and neutral.skill_id = legacy.skill_id
                          and neutral.evidence_level = 'INFERRED'
                          and neutral.observation_type = 'relevance_match'
                      );
                    delete from skill_observations as legacy
                    where legacy.observation_type = 'replaced_by_existing'
                      and exists (
                        select 1 from skill_observations as neutral
                        where neutral.source_file_path = legacy.source_file_path
                          and neutral.source_offset = legacy.source_offset
                          and neutral.skill_id = legacy.skill_id
                          and neutral.evidence_level = 'INFERRED'
                          and neutral.observation_type = 'replacement_signal'
                      );
                    update skill_observations
                    set observation_type = 'relevance_match', evidence_level = 'INFERRED'
                    where observation_type in ('suspected_miss', 'shadow_match');
                    update skill_observations
                    set observation_type = 'replacement_signal', evidence_level = 'INFERRED'
                    where observation_type = 'replaced_by_existing';
                    """,
                    database: database
                )
                try setMetadataLocked(key: "neutral_evidence_migration_v1", value: "1", database: database)
            }
        }
    }

    private func tableColumns(_ table: String, database: OpaquePointer) throws -> Set<String> {
        let statement = try prepare("pragma table_info(\(table));", database: database)
        defer { sqlite3_finalize(statement) }
        var result = Set<String>()
        while sqlite3_step(statement) == SQLITE_ROW {
            if let name = text(statement, 1) { result.insert(name) }
        }
        return result
    }

    private func metadataValueLocked(for key: String, database: OpaquePointer) throws -> String? {
        let statement = try prepare("select value from skill_metadata where key = ? limit 1;", database: database)
        defer { sqlite3_finalize(statement) }
        try bind(key, to: statement, at: 1, database: database)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return text(statement, 0)
    }

    private func transaction(_ database: OpaquePointer, operation: () throws -> Void) throws {
        try exec("begin immediate;", database: database)
        do {
            try operation()
            try exec("commit;", database: database)
        } catch {
            try? exec("rollback;", database: database)
            throw error
        }
    }

    private func executeBoundText(
        _ statement: OpaquePointer,
        value: String,
        database: OpaquePointer
    ) throws {
        sqlite3_reset(statement)
        sqlite3_clear_bindings(statement)
        try bind(value, to: statement, at: 1, database: database)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw sqliteError(database) }
    }

    private func prepare(_ sql: String, database: OpaquePointer) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw sqliteError(database)
        }
        return statement
    }

    private func bind(
        _ value: String?,
        to statement: OpaquePointer,
        at index: Int32,
        database: OpaquePointer
    ) throws {
        let status: Int32
        if let value {
            status = sqlite3_bind_text(statement, index, value, -1, Self.sqliteTransient)
        } else {
            status = sqlite3_bind_null(statement, index)
        }
        guard status == SQLITE_OK else { throw sqliteError(database) }
    }

    private func exec(_ sql: String, database: OpaquePointer) throws {
        var errorMessage: UnsafeMutablePointer<Int8>?
        let status = sqlite3_exec(database, sql, nil, nil, &errorMessage)
        guard status == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) }
                ?? String(cString: sqlite3_errmsg(database))
            if let errorMessage { sqlite3_free(errorMessage) }
            throw SkillObservationStoreError.sqlite(message)
        }
    }

    private func sqliteError(_ database: OpaquePointer) -> SkillObservationStoreError {
        .sqlite(String(cString: sqlite3_errmsg(database)))
    }

    private func checkpoint(from statement: OpaquePointer) -> SkillFileCheckpoint? {
        guard let path = text(statement, 0),
              let statusText = text(statement, 6),
              let status = SkillInsightsQuality(rawValue: statusText),
              let cursorJSON = text(statement, 8),
              let cursorData = cursorJSON.data(using: .utf8),
              let cursor = try? JSONDecoder().decode(SkillAnalysisCursorState.self, from: cursorData) else {
            return nil
        }
        let discardingOversizedRow = sqlite3_column_int(statement, 7) != 0
        let storedOversizedClassification = text(statement, 9)
            .flatMap(SkillJSONLRowClassification.init(rawValue:))
        return SkillFileCheckpoint(
            path: path,
            inode: unsigned(statement, 1),
            size: unsigned(statement, 2),
            modifiedAtNanoseconds: sqlite3_column_int64(statement, 3),
            processedOffset: unsigned(statement, 4),
            lastAnalyzedAt: Date(timeIntervalSince1970: Double(sqlite3_column_int64(statement, 5)) / 1_000),
            status: status,
            discardingOversizedRow: discardingOversizedRow,
            oversizedRowClassification: discardingOversizedRow
                ? storedOversizedClassification ?? .parse
                : nil,
            cursorState: cursor
        )
    }

    private func text(_ statement: OpaquePointer, _ index: Int32) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL,
              let pointer = sqlite3_column_text(statement, index) else {
            return nil
        }
        return String(cString: pointer)
    }

    private func integer(_ statement: OpaquePointer, _ index: Int32) -> Int {
        Int(clamping: sqlite3_column_int64(statement, index))
    }

    private func unsigned(_ statement: OpaquePointer, _ index: Int32) -> UInt64 {
        UInt64(max(0, sqlite3_column_int64(statement, index)))
    }

    private func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000).rounded())
    }

    private var schemaSQL: String {
        """
        pragma journal_mode = WAL;
        pragma synchronous = NORMAL;
        create table if not exists skill_metadata(
          key text primary key,
          value text not null
        );
        create table if not exists skill_scan_files(
          path text primary key,
          inode integer not null,
          size integer not null,
          modified_at_nanoseconds integer not null,
          processed_offset integer not null,
          last_analyzed_ms integer not null,
          status text not null,
          discarding_oversized_row integer not null default 0,
          cursor_state_json text not null,
          oversized_row_classification text
        );
        create table if not exists skill_observations(
          id integer primary key autoincrement,
          session_id text not null,
          skill_id text not null,
          skill_name text not null,
          skill_path text not null,
          enabled integer not null,
          evidence_level text not null,
          observation_type text not null,
          observed_at_ms integer not null,
          project_id text,
          session_tokens integer,
          analyzer_version integer not null,
          quality text not null,
          source_file_path text not null,
          source_offset integer not null,
          unique(source_file_path, source_offset, skill_id, evidence_level, observation_type)
        );
        create index if not exists skill_observations_time_idx on skill_observations(observed_at_ms);
        create index if not exists skill_observations_skill_time_idx on skill_observations(skill_id, observed_at_ms);
        create index if not exists skill_observations_source_idx
          on skill_observations(source_file_path, source_offset, skill_id, observation_type);
        create table if not exists skill_scan_runs(
          id integer primary key autoincrement,
          completed_at_ms integer not null,
          quality text not null,
          candidate_files integer not null default 0,
          analyzed_files integer not null,
          unchanged_files integer not null,
          pending_files integer not null default 0,
          analyzed_lines integer not null,
          parsed_rows integer not null default 0,
          filtered_rows integer not null default 0,
          malformed_lines integer not null,
          skipped_oversized_rows integer not null,
          skipped_irrelevant_oversized_rows integer not null default 0,
          partial_files integer not null,
          analyzed_bytes integer not null,
          boundary_probe_bytes integer not null default 0,
          cpu_ms integer not null default 0,
          disk_read_bytes integer not null default 0,
          disk_write_bytes integer not null default 0,
          peak_physical_footprint_bytes integer not null default 0,
          database_duration_ms integer not null default 0,
          resource_metrics_available integer not null default 0,
          was_deferred integer not null default 0,
          duration_ms integer not null,
          analyzer_version integer not null,
          model_tokens integer not null default 0
        );
        create index if not exists skill_scan_runs_time_idx on skill_scan_runs(completed_at_ms);
        """
    }
}

enum SkillObservationStoreError: Error {
    case cancelled
    case unavailable
    case sqlite(String)
}
