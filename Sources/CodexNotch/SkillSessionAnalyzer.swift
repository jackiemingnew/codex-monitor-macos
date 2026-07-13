import Foundation
import Darwin
import CryptoKit

struct SkillAnalysisOutcome: Sendable {
    let performance: SkillAnalysisPerformance
    let quality: SkillInsightsQuality
    let diagnostics: [String]
}

final class SkillSessionAnalyzer: @unchecked Sendable {
    static let analyzerVersion = 2

    private struct ThreadRow: Decodable {
        let id: String
        let rolloutPath: String
        let tokensUsed: Int
        let updatedAt: Int
        let createdAt: Int

        enum CodingKeys: String, CodingKey {
            case id
            case rolloutPath = "rollout_path"
            case tokensUsed = "tokens_used"
            case updatedAt = "updated_at"
            case createdAt = "created_at"
        }
    }

    private struct CandidateFile {
        let path: String
        let signature: SkillFileSignature
        let fallbackSessionID: String
        let sessionTokens: Int?
        let createdAt: Date?
        let projectID: String?
    }

    private struct CandidateResult {
        let files: [CandidateFile]
        let diagnostics: [String]
        let isPartial: Bool
        let unavailableFileCount: Int
    }

    private struct FileScanResult {
        let checkpoint: SkillFileCheckpoint
        var observations: [SkillObservationRecord]
        let analyzedLines: Int
        let parsedRows: Int
        let filteredRows: Int
        let malformedLines: Int
        let skippedOversizedRows: Int
        let skippedIrrelevantOversizedRows: Int
        let peakPhysicalFootprintBytes: UInt64
        let analyzedBytes: UInt64
        let boundaryProbeBytes: UInt64
        let stopReason: SkillJSONLStopReason
        let isPartial: Bool
        let diagnostics: [String]
    }

    private struct SkillFileSignature: Equatable {
        let path: String
        let exists: Bool
        let inode: UInt64
        let size: UInt64
        let modifiedAtNanoseconds: Int64
    }

    private let codexDirectory: URL
    private let observationStore: SkillObservationStore
    private let fileManager: FileManager
    private let maxRowBytes: Int
    private let maxBytesPerFilePerRun: UInt64
    private let maxBytesPerRun: UInt64
    private let windowDays: Int
    private let maxWallTime: TimeInterval
    private let maxCPUTime: TimeInterval
    private let fractionalDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private let standardDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    init(
        codexDirectory: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex"),
        observationStore: SkillObservationStore,
        fileManager: FileManager = .default,
        maxRowBytes: Int = 256 * 1024,
        maxBytesPerFilePerRun: UInt64 = 256 * 1024 * 1024,
        maxBytesPerRun: UInt64 = 2 * 1024 * 1024 * 1024,
        windowDays: Int = 7,
        maxWallTime: TimeInterval = 30,
        maxCPUTime: TimeInterval = 15
    ) {
        self.codexDirectory = codexDirectory.standardizedFileURL
        self.observationStore = observationStore
        self.fileManager = fileManager
        let safeRowBytes = max(8 * 1024, maxRowBytes)
        self.maxRowBytes = safeRowBytes
        self.maxBytesPerFilePerRun = max(UInt64(safeRowBytes), maxBytesPerFilePerRun)
        self.maxBytesPerRun = max(UInt64(safeRowBytes), maxBytesPerRun)
        self.windowDays = max(1, windowDays)
        self.maxWallTime = max(0.1, maxWallTime)
        self.maxCPUTime = max(0.1, maxCPUTime)
    }

    func analyze(
        catalog: SkillCatalogSnapshot,
        now: Date = Date(),
        force: Bool = false,
        shouldCancel: @escaping @Sendable () -> Bool = { false }
    ) -> SkillAnalysisOutcome {
        let startedAt = Date()
        let wallDeadline = ProcessInfo.processInfo.systemUptime + maxWallTime
        let reservedCPUSec = min(0.25, maxCPUTime * 0.05)
        let cpuDeadline = SkillProcessResourceSnapshot.processCPUNanoseconds()
            + UInt64(((maxCPUTime - reservedCPUSec) * 1_000_000_000).rounded())
        let resourceStart = SkillProcessResourceSnapshot.capture()
        guard !catalog.skills.isEmpty else {
            var performance = SkillAnalysisPerformance.empty
            performance.lastCompletedAt = now
            performance.durationMilliseconds = elapsedMilliseconds(since: startedAt)
            return SkillAnalysisOutcome(
                performance: performance,
                quality: .unavailable,
                diagnostics: ["Skill analysis is unavailable because the catalog is empty."]
            )
        }

        let matcher = SkillMatcher(catalog: catalog.skills)
        let candidates = candidateFiles(now: now)
        var diagnostics = candidates.diagnostics
        var performance = SkillAnalysisPerformance.empty
        performance.analyzerVersion = Self.analyzerVersion
        performance.candidateFiles = candidates.files.count
        var runQuality = catalog.quality == .complete && !candidates.isPartial
            ? SkillInsightsQuality.complete
            : .partial
        var remainingRunBytes = maxBytesPerRun
        var checkpoints: [String: SkillFileCheckpoint]
        do {
            checkpoints = try observationStore.checkpoints(for: candidates.files.map(\.path))
        } catch {
            diagnostics.append("The Skill checkpoint store is unavailable; no rollout bytes were read.")
            performance.pendingFiles = candidates.files.count
            performance.partialFiles = candidates.unavailableFileCount
            performance.durationMilliseconds = elapsedMilliseconds(since: startedAt)
            performance.lastCompletedAt = now
            performance.modelTokens = 0
            let resourceDelta = resourceStart.delta(to: SkillProcessResourceSnapshot.capture())
            performance.cpuMilliseconds = resourceDelta.cpuMilliseconds
            performance.diskReadBytes = resourceDelta.diskReadBytes
            performance.diskWriteBytes = resourceDelta.diskWriteBytes
            performance.peakPhysicalFootprintBytes = resourceDelta.peakPhysicalFootprintBytes
            performance.resourceMetricsAvailable = resourceDelta.isAvailable
            return SkillAnalysisOutcome(
                performance: performance,
                quality: .partial,
                diagnostics: Array(Set(diagnostics)).sorted()
            )
        }
        let analysisFingerprint = SkillCatalogLoader.analysisFingerprint(
            for: catalog.skills,
            analyzerVersion: Self.analyzerVersion
        )
        let storedFingerprint = observationStore.storedAnalysisFingerprint()
        let legacyFingerprint = SkillCatalogLoader.legacyAnalysisFingerprint(
            for: catalog.skills,
            analyzerVersion: Self.analyzerVersion
        )
        let catalogChanged = storedFingerprint != nil
            && storedFingerprint != analysisFingerprint
            && storedFingerprint != legacyFingerprint
        var resetSucceeded = true
        if force || catalogChanged {
            do {
                try observationStore.removeDerivedData(for: candidates.files.map(\.path))
                checkpoints.removeAll(keepingCapacity: true)
                if catalogChanged {
                    diagnostics.append("The Skill catalog changed; recent rollout evidence was reanalyzed.")
                }
            } catch {
                resetSucceeded = false
                runQuality = .partial
                diagnostics.append("The catalog-aware seven-day reanalysis could not clear all prior derived observations.")
            }
        }

        let orderedCandidates = orderedCandidates(candidates.files, checkpoints: checkpoints)
        var pendingPaths = Set<String>()
        var partialPaths = Set<String>()
        for (index, candidate) in orderedCandidates.enumerated() {
            let budgetStopReason: SkillJSONLStopReason?
            if shouldCancel() {
                budgetStopReason = .cancelled
            } else if remainingRunBytes == 0 {
                budgetStopReason = .byteBudget
            } else if ProcessInfo.processInfo.systemUptime >= wallDeadline {
                budgetStopReason = .wallTimeBudget
            } else if SkillProcessResourceSnapshot.processCPUNanoseconds() >= cpuDeadline {
                budgetStopReason = .cpuBudget
            } else {
                budgetStopReason = nil
            }
            if let budgetStopReason {
                pendingPaths.formUnion(orderedCandidates[index...].map(\.path))
                runQuality = .partial
                diagnostics.append(stopDiagnostic(for: budgetStopReason))
                break
            }
            do {
                var checkpoint = checkpoints[candidate.path]

                if let checkpoint,
                   checkpoint.inode == candidate.signature.inode,
                   checkpoint.size == candidate.signature.size,
                   checkpoint.modifiedAtNanoseconds == candidate.signature.modifiedAtNanoseconds,
                   checkpoint.processedOffset == candidate.signature.size,
                   !checkpoint.discardingOversizedRow {
                    performance.unchangedFiles += 1
                    if checkpoint.status != .complete {
                        partialPaths.insert(candidate.path)
                        runQuality = .partial
                    }
                    continue
                }

                let wasReplaced = checkpoint.map {
                    $0.inode != candidate.signature.inode
                        || candidate.signature.size < $0.processedOffset
                        || ($0.size == candidate.signature.size
                            && $0.modifiedAtNanoseconds != candidate.signature.modifiedAtNanoseconds)
                } ?? false
                if wasReplaced {
                    try observationStore.removeDerivedData(for: [candidate.path])
                    checkpoint = nil
                }

                var result = try autoreleasepool {
                    try scan(
                        candidate: candidate,
                        checkpoint: checkpoint,
                        catalog: catalog.skills,
                        matcher: matcher,
                        byteBudget: min(maxBytesPerFilePerRun, remainingRunBytes),
                        now: now,
                        wallDeadlineUptime: wallDeadline,
                        cpuDeadlineNanoseconds: cpuDeadline,
                        shouldCancel: shouldCancel
                    )
                }
                let databaseStartedAt = Date()
                try observationStore.persist(result.observations, checkpoint: result.checkpoint)
                performance.databaseDurationMilliseconds += elapsedMilliseconds(since: databaseStartedAt)
                checkpoints[candidate.path] = result.checkpoint

                performance.analyzedFiles += 1
                performance.analyzedLines += result.analyzedLines
                performance.parsedRows += result.parsedRows
                performance.filteredRows += result.filteredRows
                performance.malformedLines += result.malformedLines
                performance.skippedOversizedRows += result.skippedOversizedRows
                performance.skippedIrrelevantOversizedRows += result.skippedIrrelevantOversizedRows
                performance.peakPhysicalFootprintBytes = max(
                    performance.peakPhysicalFootprintBytes,
                    result.peakPhysicalFootprintBytes
                )
                performance.analyzedBytes += result.analyzedBytes
                performance.boundaryProbeBytes += result.boundaryProbeBytes
                let totalLogicalRead = result.analyzedBytes + result.boundaryProbeBytes
                remainingRunBytes = remainingRunBytes > totalLogicalRead
                    ? remainingRunBytes - totalLogicalRead
                    : 0
                if result.isPartial {
                    partialPaths.insert(candidate.path)
                    runQuality = .partial
                }
                if result.stopReason != .endOfFile,
                   result.checkpoint.processedOffset < candidate.signature.size {
                    pendingPaths.insert(candidate.path)
                    runQuality = .partial
                }
                diagnostics.append(contentsOf: result.diagnostics)
                result.observations.removeAll(keepingCapacity: false)
                _ = malloc_zone_pressure_relief(nil, 0)
                if result.stopReason == .wallTimeBudget
                    || result.stopReason == .cpuBudget
                    || result.stopReason == .cancelled {
                    if index + 1 < orderedCandidates.count {
                        pendingPaths.formUnion(orderedCandidates[(index + 1)...].map(\.path))
                    }
                    diagnostics.append(stopDiagnostic(for: result.stopReason))
                    break
                }
            } catch {
                partialPaths.insert(candidate.path)
                runQuality = .partial
                diagnostics.append("A rollout file could not be analyzed: \(redactedPathLabel(candidate.path)).")
            }
        }

        if resetSucceeded, storedFingerprint != analysisFingerprint {
            do {
                try observationStore.saveAnalysisFingerprint(analysisFingerprint)
            } catch {
                runQuality = .partial
                diagnostics.append("The Skill catalog analysis fingerprint could not be persisted.")
            }
        }
        performance.pendingFiles = pendingPaths.count
        performance.partialFiles = partialPaths.count + candidates.unavailableFileCount
        performance.durationMilliseconds = elapsedMilliseconds(since: startedAt)
        performance.lastCompletedAt = now
        performance.modelTokens = 0
        let resourceDelta = resourceStart.delta(to: SkillProcessResourceSnapshot.capture())
        performance.cpuMilliseconds = resourceDelta.cpuMilliseconds
        performance.diskReadBytes = resourceDelta.diskReadBytes
        performance.diskWriteBytes = resourceDelta.diskWriteBytes
        performance.peakPhysicalFootprintBytes = max(
            performance.peakPhysicalFootprintBytes,
            resourceDelta.peakPhysicalFootprintBytes
        )
        performance.resourceMetricsAvailable = resourceDelta.isAvailable
        return SkillAnalysisOutcome(
            performance: performance,
            quality: runQuality,
            diagnostics: Array(Set(diagnostics)).sorted()
        )
    }

    private func orderedCandidates(
        _ candidates: [CandidateFile],
        checkpoints: [String: SkillFileCheckpoint]
    ) -> [CandidateFile] {
        candidates.sorted { lhs, rhs in
            let lhsPriority = candidatePriority(lhs, checkpoint: checkpoints[lhs.path])
            let rhsPriority = candidatePriority(rhs, checkpoint: checkpoints[rhs.path])
            if lhsPriority != rhsPriority {
                return lhsPriority < rhsPriority
            }
            if lhs.signature.modifiedAtNanoseconds != rhs.signature.modifiedAtNanoseconds {
                return lhs.signature.modifiedAtNanoseconds > rhs.signature.modifiedAtNanoseconds
            }
            return lhs.path < rhs.path
        }
    }

    private func candidatePriority(
        _ candidate: CandidateFile,
        checkpoint: SkillFileCheckpoint?
    ) -> Int {
        guard let checkpoint else {
            return 1
        }
        if checkpoint.inode != candidate.signature.inode
            || checkpoint.processedOffset < candidate.signature.size {
            return 0
        }
        return 2
    }

    private func stopDiagnostic(for reason: SkillJSONLStopReason) -> String {
        switch reason {
        case .byteBudget:
            "The Skill analysis byte budget was reached; pending files will resume later."
        case .wallTimeBudget:
            "The Skill analysis wall-time budget was reached; pending files will resume later."
        case .cpuBudget:
            "The Skill analysis CPU budget was reached; pending files will resume later."
        case .cancelled:
            "The Skill analysis was cancelled; pending files will resume later."
        case .endOfFile:
            ""
        }
    }

    private func candidateFiles(now: Date) -> CandidateResult {
        let windowStart = now.addingTimeInterval(-TimeInterval(windowDays * 24 * 60 * 60))
        let cutoff = Int(windowStart.timeIntervalSince1970)
        var diagnostics: [String] = []
        var isPartial = false
        var unavailableFileCount = 0
        var rows: [ThreadRow] = []
        let stateDatabase = latestSQLiteDatabase(prefix: "state_", fallback: "state_5.sqlite")

        if fileManager.fileExists(atPath: stateDatabase) {
            let query = """
            select id,
                   coalesce(rollout_path, '') as rollout_path,
                   coalesce(tokens_used, 0) as tokens_used,
                   coalesce(updated_at, 0) as updated_at,
                   coalesce(created_at, 0) as created_at
            from threads
            where coalesce(updated_at, 0) >= \(cutoff);
            """
            do {
                rows = try Shell.sqliteJSON(
                    database: stateDatabase,
                    query: query,
                    as: [ThreadRow].self,
                    readOnly: true
                )
            } catch {
                diagnostics.append("state_*.sqlite could not provide seven-day Skill session references.")
                isPartial = true
            }
        } else {
            diagnostics.append("state_*.sqlite is unavailable; rollout discovery uses file metadata only.")
            isPartial = true
        }

        var rowsBySessionID: [String: ThreadRow] = [:]
        var paths = Set<String>()
        for row in rows {
            rowsBySessionID[row.id.lowercased()] = row
            if !row.rolloutPath.isEmpty {
                paths.insert(URL(fileURLWithPath: row.rolloutPath).standardizedFileURL.path)
            }
        }

        let rolloutRoots = ["sessions", "archived_sessions"].map {
            codexDirectory.appendingPathComponent($0, isDirectory: true)
        }
        for path in CodexSessionFileLocator.recentRolloutPaths(
            roots: rolloutRoots,
            modifiedSince: windowStart,
            fileManager: fileManager
        ) {
            paths.insert(path)
        }

        var seenCanonicalPaths = Set<String>()
        let files = paths.sorted().compactMap { path -> CandidateFile? in
            let signature = fileSignature(path)
            guard signature.exists else {
                diagnostics.append("A referenced rollout file is unavailable: \(redactedPathLabel(path)).")
                isPartial = true
                unavailableFileCount += 1
                return nil
            }
            guard seenCanonicalPaths.insert(signature.path).inserted else {
                return nil
            }
            let sessionID = sessionID(from: path)
            let row = rowsBySessionID[sessionID.lowercased()]
            return CandidateFile(
                path: signature.path,
                signature: signature,
                fallbackSessionID: sessionID,
                sessionTokens: row.map { max(0, $0.tokensUsed) },
                createdAt: row.flatMap { $0.createdAt > 0 ? Date(timeIntervalSince1970: Double($0.createdAt)) : nil },
                projectID: nil
            )
        }
        .sorted { $0.path < $1.path }

        return CandidateResult(
            files: files,
            diagnostics: diagnostics,
            isPartial: isPartial,
            unavailableFileCount: unavailableFileCount
        )
    }

    private func scan(
        candidate: CandidateFile,
        checkpoint: SkillFileCheckpoint?,
        catalog: [SkillCatalogEntry],
        matcher: SkillMatcher,
        byteBudget: UInt64,
        now: Date,
        wallDeadlineUptime: TimeInterval,
        cpuDeadlineNanoseconds: UInt64,
        shouldCancel: @escaping @Sendable () -> Bool
    ) throws -> FileScanResult {
        let windowStart = now.addingTimeInterval(-TimeInterval(windowDays * 24 * 60 * 60))
        let boundary: (offset: UInt64, bytesRead: UInt64)
        if checkpoint == nil,
           let createdAt = candidate.createdAt,
           createdAt < windowStart,
           candidate.signature.size >= 8 * 1024 * 1024 {
            boundary = findWindowStartOffset(
                path: candidate.path,
                fileSize: candidate.signature.size,
                windowStart: windowStart,
                byteBudget: min(byteBudget, 8 * 1024 * 1024)
            )
        } else {
            boundary = (0, 0)
        }
        let startOffset = min(checkpoint?.processedOffset ?? boundary.offset, candidate.signature.size)
        var cursor = checkpoint?.cursorState ?? .empty(sessionID: candidate.fallbackSessionID)
        if cursor.sessionID.isEmpty {
            cursor.sessionID = candidate.fallbackSessionID
        }
        if cursor.projectID == nil {
            cursor.projectID = candidate.projectID
        }
        if let tokens = candidate.sessionTokens {
            cursor.sessionTokens = max(cursor.sessionTokens ?? 0, tokens)
        }
        var observations: [SkillObservationRecord] = []
        let entriesByID = Dictionary(uniqueKeysWithValues: catalog.map { ($0.id, $0) })
        var malformedLines = 0
        var diagnostics: [String] = []
        var hasQualityIssue = checkpoint.map {
            $0.status == .partial && $0.processedOffset == $0.size
        } ?? false

        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: candidate.path))
        defer { try? handle.close() }
        let readResult = try SkillJSONLReader.read(
            handle: handle,
            startOffset: startOffset,
            fileSize: candidate.signature.size,
            byteBudget: byteBudget > boundary.bytesRead ? byteBudget - boundary.bytesRead : 0,
            maxRowBytes: maxRowBytes,
            initialDiscardingOversizedRow: checkpoint?.discardingOversizedRow ?? false,
            wallDeadlineUptime: wallDeadlineUptime,
            cpuDeadlineNanoseconds: cpuDeadlineNanoseconds,
            shouldCancel: shouldCancel
        ) { lineData, sourceOffset in
            autoreleasepool {
                guard let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                    malformedLines += 1
                    hasQualityIssue = true
                    return
                }
                process(
                    object: object,
                    sourceOffset: sourceOffset,
                    candidate: candidate,
                    entriesByID: entriesByID,
                    matcher: matcher,
                    cursor: &cursor,
                    observations: &observations,
                    now: now,
                    windowStart: windowStart
                )
            }
        }

        if readResult.stopReason == .endOfFile, readResult.hasIncompleteRow {
            hasQualityIssue = true
            diagnostics.append("A trailing incomplete JSONL row will be retried after the next append.")
        }
        if readResult.skippedOversizedRows > 0
            || (readResult.stopReason == .endOfFile && readResult.discardingOversizedRow) {
            hasQualityIssue = true
        }
        if malformedLines > 0 {
            diagnostics.append("Malformed JSONL rows were skipped without stopping the file scan.")
        }
        if readResult.skippedOversizedRows > 0
            || (readResult.stopReason == .endOfFile && readResult.discardingOversizedRow) {
            diagnostics.append("Oversized JSONL rows were skipped and were not stored.")
        }

        let scanPending = readResult.stopReason != .endOfFile
            && readResult.processedOffset < candidate.signature.size
        let status: SkillInsightsQuality = hasQualityIssue || scanPending ? .partial : .complete
        let checkpoint = SkillFileCheckpoint(
            path: candidate.path,
            inode: candidate.signature.inode,
            size: candidate.signature.size,
            modifiedAtNanoseconds: candidate.signature.modifiedAtNanoseconds,
            processedOffset: readResult.processedOffset,
            lastAnalyzedAt: now,
            status: status,
            discardingOversizedRow: readResult.discardingOversizedRow,
            cursorState: cursor
        )
        return FileScanResult(
            checkpoint: checkpoint,
            observations: observations,
            analyzedLines: readResult.analyzedLines,
            parsedRows: readResult.parsedRows,
            filteredRows: readResult.filteredRows,
            malformedLines: malformedLines,
            skippedOversizedRows: readResult.skippedOversizedRows,
            skippedIrrelevantOversizedRows: readResult.skippedIrrelevantOversizedRows,
            peakPhysicalFootprintBytes: readResult.peakPhysicalFootprintBytes,
            analyzedBytes: readResult.analyzedBytes,
            boundaryProbeBytes: boundary.bytesRead,
            stopReason: readResult.stopReason,
            isPartial: hasQualityIssue,
            diagnostics: diagnostics
        )
    }

    private func findWindowStartOffset(
        path: String,
        fileSize: UInt64,
        windowStart: Date,
        byteBudget: UInt64
    ) -> (offset: UInt64, bytesRead: UInt64) {
        guard fileSize > 0,
              let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else {
            return (0, 0)
        }
        defer { try? handle.close() }

        var bytesRead: UInt64 = 0
        guard let first = probeTimestampedLine(
                handle: handle,
                atOrAfter: 0,
                fileSize: fileSize,
                byteBudget: byteBudget,
                bytesRead: &bytesRead
              ),
              let last = lastTimestampedLine(
                handle: handle,
                fileSize: fileSize,
                byteBudget: byteBudget,
                bytesRead: &bytesRead
              ) else {
            return (0, bytesRead)
        }
        if first.date >= windowStart {
            return (0, bytesRead)
        }
        if last.date < windowStart {
            return (fileSize, bytesRead)
        }

        var lower = first
        var upper = last
        for _ in 0..<28 where upper.offset > lower.offset + 512 * 1024 {
            let midpoint = lower.offset + (upper.offset - lower.offset) / 2
            guard let probe = probeTimestampedLine(
                handle: handle,
                atOrAfter: midpoint,
                fileSize: fileSize,
                byteBudget: byteBudget,
                bytesRead: &bytesRead
            ) else {
                return (0, bytesRead)
            }
            // Rollout timestamps are append ordered. If a probe violates the
            // established bounds, safety wins and the caller scans from zero.
            guard probe.date >= lower.date, probe.date <= upper.date else {
                return (0, bytesRead)
            }
            if probe.date < windowStart {
                lower = probe
            } else {
                upper = probe
            }
        }

        guard lower.date < windowStart, upper.date >= windowStart,
              let safeOffset = previousUserTurnOffset(
                handle: handle,
                before: upper.offset,
                fileSize: fileSize,
                byteBudget: byteBudget,
                bytesRead: &bytesRead
              ) else {
            return (0, bytesRead)
        }
        return (safeOffset, bytesRead)
    }

    private func probeTimestampedLine(
        handle: FileHandle,
        atOrAfter requestedOffset: UInt64,
        fileSize: UInt64,
        byteBudget: UInt64,
        bytesRead: inout UInt64
    ) -> (offset: UInt64, date: Date)? {
        let maximumProbeBytes = 512 * 1024
        let requested = min(requestedOffset, fileSize)
        let remainingBudget = byteBudget > bytesRead ? byteBudget - bytesRead : 0
        let readCount = min(maximumProbeBytes, Int(clamping: remainingBudget))
        guard readCount > 0 else { return nil }
        try? handle.seek(toOffset: requested)
        guard let data = try? handle.read(upToCount: readCount),
              !data.isEmpty else {
            return nil
        }
        bytesRead += UInt64(data.count)
        let startIndex: Data.Index
        if requested == 0 {
            startIndex = data.startIndex
        } else {
            guard let newline = data.firstIndex(of: 0x0A), newline < data.index(before: data.endIndex) else {
                return nil
            }
            startIndex = data.index(after: newline)
        }
        var lineStart = startIndex
        while lineStart < data.endIndex {
            let lineEnd = data[lineStart...].firstIndex(of: 0x0A) ?? data.endIndex
            let line = data[lineStart..<lineEnd]
            if line.count <= maxRowBytes,
               let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
               let date = eventDate(object["timestamp"]) {
                return (requested + UInt64(lineStart - data.startIndex), date)
            }
            guard lineEnd < data.endIndex else { break }
            lineStart = data.index(after: lineEnd)
        }
        return nil
    }

    private func lastTimestampedLine(
        handle: FileHandle,
        fileSize: UInt64,
        byteBudget: UInt64,
        bytesRead: inout UInt64
    ) -> (offset: UInt64, date: Date)? {
        let maximumProbeBytes = UInt64(512 * 1024)
        let requested = fileSize > maximumProbeBytes ? fileSize - maximumProbeBytes : 0
        let remainingBudget = byteBudget > bytesRead ? byteBudget - bytesRead : 0
        let readCount = min(fileSize - requested, remainingBudget)
        guard readCount > 0 else { return nil }
        try? handle.seek(toOffset: requested)
        guard let data = try? handle.read(upToCount: Int(readCount)),
              !data.isEmpty else {
            return nil
        }
        bytesRead += UInt64(data.count)
        let alignedStart: Data.Index
        if requested == 0 {
            alignedStart = data.startIndex
        } else if let newline = data.firstIndex(of: 0x0A) {
            alignedStart = data.index(after: newline)
        } else {
            return nil
        }
        var latest: (offset: UInt64, date: Date)?
        var lineStart = alignedStart
        while lineStart < data.endIndex {
            let lineEnd = data[lineStart...].firstIndex(of: 0x0A) ?? data.endIndex
            let line = data[lineStart..<lineEnd]
            if line.count <= maxRowBytes,
               let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
               let date = eventDate(object["timestamp"]) {
                latest = (requested + UInt64(lineStart - data.startIndex), date)
            }
            guard lineEnd < data.endIndex else { break }
            lineStart = data.index(after: lineEnd)
        }
        return latest
    }

    private func previousUserTurnOffset(
        handle: FileHandle,
        before offset: UInt64,
        fileSize: UInt64,
        byteBudget: UInt64,
        bytesRead: inout UInt64
    ) -> UInt64? {
        let backtrackBytes = UInt64(2 * 1024 * 1024)
        let earliestStart = offset > backtrackBytes ? offset - backtrackBytes : 0
        let end = min(fileSize, offset + UInt64(maxRowBytes) + 1)
        let remainingBudget = byteBudget > bytesRead ? byteBudget - bytesRead : 0
        let readCount = min(end - earliestStart, remainingBudget)
        guard readCount > 0 else { return nil }
        let start = end - readCount
        try? handle.seek(toOffset: start)
        guard let data = try? handle.read(upToCount: Int(readCount)),
              !data.isEmpty else {
            return nil
        }
        bytesRead += UInt64(data.count)
        let alignedStart: Data.Index
        if start == 0 {
            alignedStart = data.startIndex
        } else if let newline = data.firstIndex(of: 0x0A) {
            alignedStart = data.index(after: newline)
        } else {
            return nil
        }
        var latestUserOffset: UInt64?
        var lineStart = alignedStart
        while lineStart < data.endIndex {
            let lineEnd = data[lineStart...].firstIndex(of: 0x0A) ?? data.endIndex
            let line = data[lineStart..<lineEnd]
            let absoluteOffset = start + UInt64(lineStart - data.startIndex)
            if absoluteOffset <= offset,
               line.count <= maxRowBytes,
               let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
               isUserEvent(object) {
                latestUserOffset = absoluteOffset
            }
            guard lineEnd < data.endIndex else { break }
            lineStart = data.index(after: lineEnd)
        }
        return latestUserOffset
    }

    private func isUserEvent(_ object: [String: Any]) -> Bool {
        let type = object["type"] as? String
        let payload = object["payload"] as? [String: Any] ?? [:]
        let payloadType = payload["type"] as? String
        return payloadType == "user_message"
            || (type == "response_item"
                && payloadType == "message"
                && payload["role"] as? String == "user")
    }

    private func process(
        object: [String: Any],
        sourceOffset: UInt64,
        candidate: CandidateFile,
        entriesByID: [String: SkillCatalogEntry],
        matcher: SkillMatcher,
        cursor: inout SkillAnalysisCursorState,
        observations: inout [SkillObservationRecord],
        now: Date,
        windowStart: Date
    ) {
        let timestamp = eventDate(object["timestamp"]) ?? now
        let type = object["type"] as? String
        let payload = object["payload"] as? [String: Any] ?? [:]
        let payloadType = payload["type"] as? String

        if type == "session_meta" {
            if let id = (payload["id"] as? String) ?? (payload["session_id"] as? String), !id.isEmpty {
                cursor.sessionID = id
            }
            if let cwd = payload["cwd"] as? String {
                cursor.projectID = projectID(for: cwd)
            }
            return
        }

        if type == "turn_context" {
            if let cwd = payload["cwd"] as? String {
                cursor.projectID = projectID(for: cwd)
            }
            return
        }

        if payloadType == "token_count" {
            let tokens = tokenTotal(from: payload)
            if let tokens {
                cursor.sessionTokens = max(cursor.sessionTokens ?? 0, tokens)
            }
        }

        if let userText = userText(type: type, payloadType: payloadType, payload: payload) {
            observations.append(contentsOf: flushTurn(
                cursor: cursor,
                entriesByID: entriesByID,
                sourceFilePath: candidate.path,
                sourceOffset: sourceOffset,
                fallbackDate: timestamp,
                windowStart: windowStart
            ))
            cursor.resetTurn(
                timestampMilliseconds: milliseconds(timestamp),
                sourceOffset: sourceOffset
            )
            let relevant = matcher.relevantSkillIDs(in: userText)
            let direct = matcher.directSkillIDs(in: userText)
            cursor.relevantSkillIDs = relevant
            cursor.directSkillIDs = direct.ids
            cursor.directAmbiguousSkillIDs = direct.ambiguousIDs
            return
        }

        if let assistantText = assistantText(type: type, payloadType: payloadType, payload: payload) {
            cursor.declaredSkillIDs.formUnion(matcher.declaredSkillIDs(in: assistantText))
            if matcher.indicatesReplacement(in: assistantText) {
                cursor.replacementSkillIDs.formUnion(cursor.relevantSkillIDs)
            }
        }

        if let tool = toolCall(type: type, payloadType: payloadType, payload: payload) {
            let referenced = matcher.skillIDsReferencedByPath(in: tool.content)
            if matcher.looksLikeSkillRead(toolName: tool.name, content: tool.content) {
                cursor.readSkillIDs.formUnion(referenced)
            }
            if matcher.isStructuredSkillCall(toolName: tool.name) {
                cursor.structuredSkillIDs.formUnion(referenced)
            }
        }

        let phase = payload["phase"] as? String
        let completesTurn = payloadType == "task_complete"
            || type == "task_complete"
            || phase == "final"
            || phase == "final_answer"
        if completesTurn {
            observations.append(contentsOf: flushTurn(
                cursor: cursor,
                entriesByID: entriesByID,
                sourceFilePath: candidate.path,
                sourceOffset: sourceOffset,
                fallbackDate: timestamp,
                windowStart: windowStart
            ))
            cursor.resetTurn(timestampMilliseconds: nil, sourceOffset: currentSafeOffset(sourceOffset))
        }
    }

    private func flushTurn(
        cursor: SkillAnalysisCursorState,
        entriesByID: [String: SkillCatalogEntry],
        sourceFilePath: String,
        sourceOffset: UInt64,
        fallbackDate: Date,
        windowStart: Date
    ) -> [SkillObservationRecord] {
        guard cursor.hasTurnEvidence else {
            return []
        }
        let observedAt = cursor.turnTimestampMilliseconds.map {
            Date(timeIntervalSince1970: Double($0) / 1_000)
        } ?? fallbackDate
        guard observedAt >= windowStart else {
            return []
        }
        let direct = cursor.directSkillIDs.union(cursor.structuredSkillIDs)
        let strong = cursor.readSkillIDs
            .intersection(cursor.declaredSkillIDs)
            .intersection(cursor.relevantSkillIDs)
            .subtracting(direct)
        let inferred = cursor.declaredSkillIDs
            .subtracting(direct)
            .subtracting(strong)
        let misfires = cursor.declaredSkillIDs
            .union(cursor.readSkillIDs)
            .subtracting(cursor.relevantSkillIDs)
            .subtracting(direct)
        var records: [SkillObservationRecord] = []

        func append(
            ids: some Sequence<String>,
            level: SkillEvidenceLevel,
            type: SkillObservationType,
            forcedQuality: SkillInsightsQuality? = nil
        ) {
            for id in ids {
                guard let skill = entriesByID[id] else {
                    continue
                }
                let quality = forcedQuality
                    ?? (cursor.directAmbiguousSkillIDs.contains(id) ? .partial : .complete)
                records.append(
                    SkillObservationRecord(
                        sessionID: cursor.sessionID,
                        skillID: skill.id,
                        skillName: skill.name,
                        skillPath: skill.path,
                        enabled: skill.enabled,
                        evidenceLevel: level,
                        observationType: type,
                        observedAt: observedAt,
                        projectID: cursor.projectID,
                        sessionTokens: cursor.sessionTokens,
                        analyzerVersion: Self.analyzerVersion,
                        quality: quality,
                        sourceFilePath: sourceFilePath,
                        sourceOffset: cursor.turnSourceOffset == 0 ? sourceOffset : cursor.turnSourceOffset
                    )
                )
            }
        }

        append(ids: direct, level: .direct, type: .confirmedUse)
        append(ids: strong, level: .strong, type: .confirmedUse)
        append(ids: inferred, level: .inferred, type: .inferredUse)
        append(ids: misfires, level: .inferred, type: .suspectedMisfire, forcedQuality: .partial)
        append(
            ids: cursor.relevantSkillIDs,
            level: .inferred,
            type: .relevanceMatch,
            forcedQuality: .partial
        )
        append(
            ids: cursor.relevantSkillIDs.intersection(cursor.replacementSkillIDs),
            level: .inferred,
            type: .replacementSignal,
            forcedQuality: .partial
        )
        return records
    }

    private func userText(type: String?, payloadType: String?, payload: [String: Any]) -> String? {
        if payloadType == "user_message" {
            let values = [payload["message"] as? String].compactMap { $0 }
                + textValues(from: payload["text_elements"])
            let text = values.joined(separator: " ")
            return text.isEmpty ? nil : text
        }
        guard type == "response_item", payloadType == "message", payload["role"] as? String == "user" else {
            return nil
        }
        let text = textValues(from: payload["content"]).joined(separator: " ")
        return text.isEmpty ? nil : text
    }

    private func assistantText(type: String?, payloadType: String?, payload: [String: Any]) -> String? {
        if payloadType == "agent_message" {
            return payload["message"] as? String
        }
        guard type == "response_item", payloadType == "message", payload["role"] as? String == "assistant" else {
            return nil
        }
        let text = textValues(from: payload["content"]).joined(separator: " ")
        return text.isEmpty ? nil : text
    }

    private func textValues(from value: Any?) -> [String] {
        guard let values = value as? [[String: Any]] else {
            return []
        }
        return values.compactMap { item in
            (item["text"] as? String) ?? (item["message"] as? String)
        }
    }

    private func toolCall(type: String?, payloadType: String?, payload: [String: Any]) -> (name: String, content: String)? {
        guard type == "response_item",
              payloadType == "function_call" || payloadType == "custom_tool_call" else {
            return nil
        }
        let name = payload["name"] as? String ?? ""
        let content = (payload["arguments"] as? String)
            ?? (payload["input"] as? String)
            ?? ""
        guard !name.isEmpty || !content.isEmpty else {
            return nil
        }
        return (name, content)
    }

    private func tokenTotal(from payload: [String: Any]) -> Int? {
        guard let info = payload["info"] as? [String: Any] else {
            return nil
        }
        for key in ["last_token_usage", "total_token_usage"] {
            if let usage = info[key] as? [String: Any], let total = integer(usage["total_tokens"]) {
                return max(0, total)
            }
        }
        return nil
    }

    private func integer(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value) }
        return nil
    }

    private func eventDate(_ value: Any?) -> Date? {
        if let number = value as? NSNumber {
            let raw = number.doubleValue
            return Date(timeIntervalSince1970: raw > 10_000_000_000 ? raw / 1_000 : raw)
        }
        guard let value = value as? String else {
            return nil
        }
        if let date = fractionalDateFormatter.date(from: value) {
            return date
        }
        return standardDateFormatter.date(from: value)
    }

    private func latestSQLiteDatabase(prefix: String, fallback: String) -> String {
        let fallbackPath = codexDirectory.appendingPathComponent(fallback).path
        guard let urls = try? fileManager.contentsOfDirectory(
            at: codexDirectory,
            includingPropertiesForKeys: nil
        ) else {
            return fallbackPath
        }
        return urls.compactMap { url -> (Int, String)? in
            guard url.pathExtension == "sqlite" else { return nil }
            let stem = url.deletingPathExtension().lastPathComponent
            guard stem.hasPrefix(prefix), let version = Int(stem.dropFirst(prefix.count)) else { return nil }
            return (version, url.path)
        }
        .max { $0.0 < $1.0 }?.1 ?? fallbackPath
    }

    private func fileSignature(_ path: String) -> SkillFileSignature {
        let canonical = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
        var info = stat()
        let result = canonical.withCString { Darwin.lstat($0, &info) }
        guard result == 0 else {
            return SkillFileSignature(path: canonical, exists: false, inode: 0, size: 0, modifiedAtNanoseconds: 0)
        }
        let modified = Int64(info.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(info.st_mtimespec.tv_nsec)
        return SkillFileSignature(
            path: canonical,
            exists: true,
            inode: UInt64(info.st_ino),
            size: info.st_size > 0 ? UInt64(info.st_size) : 0,
            modifiedAtNanoseconds: modified
        )
    }

    private func sessionID(from path: String) -> String {
        let stem = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        if stem.count >= 36 {
            let suffix = String(stem.suffix(36))
            if suffix.filter({ $0 == "-" }).count == 4 {
                return suffix
            }
        }
        return "rollout-\(SkillCatalogLoader.stableID(for: path))"
    }

    private func projectID(for path: String) -> String {
        let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
        let digest = SHA256.hash(data: Data(normalized.utf8))
        return "project-" + digest.prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    private func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000).rounded())
    }

    private func currentSafeOffset(_ offset: UInt64) -> UInt64 {
        offset == UInt64.max ? offset : offset + 1
    }

    private func elapsedMilliseconds(since date: Date) -> Int {
        max(0, Int((Date().timeIntervalSince(date) * 1_000).rounded()))
    }

    private func redactedPathLabel(_ path: String) -> String {
        let url = URL(fileURLWithPath: path)
        return "\(url.deletingLastPathComponent().lastPathComponent)/\(url.lastPathComponent)"
    }
}

private struct SkillMatcher {
    private struct Terms {
        let exactNames: [String]
        let distinctiveTokens: Set<String>
    }

    private let skills: [SkillCatalogEntry]
    private let skillsByName: [String: [SkillCatalogEntry]]
    private let termsByID: [String: Terms]
    private let directExpression: NSRegularExpression?
    private let declarationMarkers = ["using", "use the", "use `", "skill", "使用", "调用", "启用"]
    private let replacementMarkers = [
        "replaced by", "handled by", "instead of", "without the skill", "existing capability",
        "被现有能力替代", "使用现有能力", "无需该 skill", "替代了"
    ]
    private static let stopWords: Set<String> = [
        "about", "after", "before", "build", "building", "codex", "create", "creating", "current",
        "data", "default", "description", "existing", "file", "files", "from", "help", "into", "local",
        "project", "request", "skill", "skills", "task", "that", "their", "this", "tool", "tools", "when",
        "where", "which", "with", "work", "workflow", "user", "users"
    ]

    init(catalog: [SkillCatalogEntry]) {
        skills = catalog
        skillsByName = Dictionary(grouping: catalog, by: { Self.normalizedName($0.name) })
        directExpression = try? NSRegularExpression(pattern: #"\$([A-Za-z0-9_.:-]+)"#)

        let tokenSets = Dictionary(uniqueKeysWithValues: catalog.map { skill in
            let nameTokens = Self.tokens(in: skill.name)
            let descriptionTokens = Self.tokens(in: skill.description)
            return (skill.id, Set(nameTokens + descriptionTokens))
        })
        var documentFrequency: [String: Int] = [:]
        for tokens in tokenSets.values {
            for token in tokens {
                documentFrequency[token, default: 0] += 1
            }
        }
        let maximumFrequency = max(2, catalog.count / 10)
        termsByID = Dictionary(uniqueKeysWithValues: catalog.map { skill in
            let normalized = Self.normalizedName(skill.name)
            let readable = normalized.replacingOccurrences(of: ":", with: " ")
                .replacingOccurrences(of: "-", with: " ")
                .replacingOccurrences(of: "_", with: " ")
            let exactNames = Array(Set([normalized, readable].filter { $0.count >= 3 }))
            let distinctive = (tokenSets[skill.id] ?? []).filter { token in
                token.count >= 4
                    && !Self.stopWords.contains(token)
                    && (documentFrequency[token] ?? 0) <= maximumFrequency
            }
            return (skill.id, Terms(exactNames: exactNames, distinctiveTokens: Set(distinctive)))
        })
    }

    func directSkillIDs(in text: String) -> (ids: Set<String>, ambiguousIDs: Set<String>) {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        var ids = Set<String>()
        var ambiguous = Set<String>()
        for match in directExpression?.matches(in: text, range: range) ?? [] {
            guard let swiftRange = Range(match.range(at: 1), in: text) else { continue }
            let resolution = resolve(name: String(text[swiftRange]))
            ids.formUnion(resolution.ids)
            ambiguous.formUnion(resolution.ambiguousIDs)
        }
        return (ids, ambiguous)
    }

    func relevantSkillIDs(in text: String) -> Set<String> {
        let normalizedText = Self.normalizedText(text)
        let textTokens = Set(Self.tokens(in: text))
        var result = Set<String>()
        for skill in skills {
            guard let terms = termsByID[skill.id] else { continue }
            let exactNameMatch = terms.exactNames.contains { name in
                normalizedText.contains(name)
            }
            let overlap = terms.distinctiveTokens.intersection(textTokens).count
            if exactNameMatch || overlap >= 2 {
                result.insert(skill.id)
            }
        }
        return result
    }

    func declaredSkillIDs(in text: String) -> Set<String> {
        let normalized = Self.normalizedText(text)
        guard declarationMarkers.contains(where: normalized.contains) else {
            return []
        }
        var result = Set<String>()
        for skill in skills {
            guard let terms = termsByID[skill.id],
                  terms.exactNames.contains(where: normalized.contains) else {
                continue
            }
            result.insert(skill.id)
        }
        return result
    }

    func skillIDsReferencedByPath(in text: String) -> Set<String> {
        guard text.localizedCaseInsensitiveContains("SKILL.md") else {
            return []
        }
        let lowercased = text.lowercased()
        var result = Set<String>()
        for skill in skills {
            let exactPath = skill.path.lowercased()
            let directoryName = URL(fileURLWithPath: skill.path).deletingLastPathComponent().lastPathComponent.lowercased()
            if lowercased.contains(exactPath)
                || lowercased.contains("/\(directoryName)/skill.md") {
                result.insert(skill.id)
            }
        }
        return result
    }

    func looksLikeSkillRead(toolName: String, content: String) -> Bool {
        guard content.localizedCaseInsensitiveContains("SKILL.md") else {
            return false
        }
        let normalized = "\(toolName) \(content)".lowercased()
        return ["skills.read", "skills_read", "sed ", "cat ", "read_file", "open ", "read("].contains {
            normalized.contains($0)
        }
    }

    func isStructuredSkillCall(toolName: String) -> Bool {
        let normalized = toolName.lowercased()
        return normalized == "skills.read"
            || normalized == "skills_read"
            || normalized.hasSuffix("__skills_read")
    }

    func indicatesReplacement(in text: String) -> Bool {
        let normalized = Self.normalizedText(text)
        return replacementMarkers.contains(where: normalized.contains)
    }

    private func resolve(name: String) -> (ids: Set<String>, ambiguousIDs: Set<String>) {
        let matches = skillsByName[Self.normalizedName(name)] ?? []
        if matches.count <= 1 {
            return (Set(matches.map(\.id)), [])
        }
        let enabled = matches.filter { $0.enabled }
        if enabled.count == 1 {
            return (Set([enabled[0].id]), [])
        }
        let ids = Set(matches.map(\.id))
        return (ids, ids)
    }

    private static func normalizedName(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func normalizedText(_ value: String) -> String {
        value.lowercased()
            .replacingOccurrences(of: "_", with: "-")
            .replacingOccurrences(of: "\n", with: " ")
    }

    private static func tokens(in value: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        func commit() {
            guard !current.isEmpty else { return }
            let normalized = rootToken(current)
            if normalized.count >= 3 {
                tokens.append(normalized)
            }
            current = ""
        }
        for character in value.lowercased() {
            if character.isLetter || character.isNumber || character == "+" || character == "." {
                current.append(character)
            } else {
                commit()
            }
        }
        commit()
        return tokens
    }

    private static func rootToken(_ value: String) -> String {
        var token = value
        for suffix in ["ization", "ations", "ation", "ments", "ment", "ing", "ers", "ies", "ed", "es", "s"] {
            if token.count > suffix.count + 4, token.hasSuffix(suffix) {
                token.removeLast(suffix.count)
                break
            }
        }
        if token.count > 8 {
            return String(token.prefix(7))
        }
        return token
    }
}
