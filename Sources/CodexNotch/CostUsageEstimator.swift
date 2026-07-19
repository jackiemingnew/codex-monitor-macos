import Darwin
import CryptoKit
import Foundation
import SQLite3

struct CostUsageScanBudget: Equatable, Sendable {
    let maxBytes: UInt64
    let maxCPUNanoseconds: UInt64
    let maxWallTime: TimeInterval
    let maxRowBytes: Int

    static let automatic = CostUsageScanBudget(
        maxBytes: 8 * 1024 * 1024,
        maxCPUNanoseconds: 50 * 1_000_000,
        maxWallTime: 0.250,
        maxRowBytes: 256 * 1024
    )
}

enum CostUsageScanStopReason: String, Equatable, Sendable {
    case caughtUp
    case byteBudget
    case cpuBudget
    case wallTimeBudget
    case cancelled
    case deferredFork
    case cadence
    case unavailable
}

struct CostUsageScanMetrics: Equatable, Sendable {
    let jsonlBytesRead: UInt64
    let filesAdvanced: Int
    let databaseWrites: Int
    let skippedOversizedRows: Int
    let stopReason: CostUsageScanStopReason
    let isComplete: Bool

    static let unavailable = CostUsageScanMetrics(
        jsonlBytesRead: 0,
        filesAdvanced: 0,
        databaseWrites: 0,
        skippedOversizedRows: 0,
        stopReason: .unavailable,
        isComplete: false
    )

    var shouldContinueGeneration: Bool {
        guard !isComplete else {
            return false
        }
        switch stopReason {
        case .byteBudget, .cpuBudget, .wallTimeBudget, .deferredFork:
            return true
        case .caughtUp, .cancelled, .cadence, .unavailable:
            return false
        }
    }
}

struct CostUsagePerformanceStats: Equatable, Sendable {
    let scanCount: Int
    let jsonlBytesRead: UInt64
    let filesAdvanced: Int
    let databaseWrites: Int
    var inventoryEnumerations: Int

    static let zero = CostUsagePerformanceStats(
        scanCount: 0,
        jsonlBytesRead: 0,
        filesAdvanced: 0,
        databaseWrites: 0,
        inventoryEnumerations: 0
    )
}

enum CostUsageInventoryDecision: Equatable, Sendable {
    case skipCadence(isComplete: Bool)
    case reuseCandidates
    case enumerate
}

struct CostUsageSessionCandidate: Equatable, Sendable {
    let sessionID: String
    let path: String
}

enum CostUsageScanExecutor {
    private final class CancellationState: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false

        func cancel() {
            lock.lock()
            cancelled = true
            lock.unlock()
        }

        func isCancelled() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return cancelled
        }
    }

    private static let queue = DispatchQueue(
        label: "com.jacklandrin.codexnotch.cost-usage-scan",
        qos: .utility
    )

    static func run<Result: Sendable>(
        _ work: @escaping @Sendable (@escaping @Sendable () -> Bool) -> Result
    ) async -> Result {
        let cancellation = CancellationState()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                queue.async {
                    let shouldCancel: @Sendable () -> Bool = {
                        cancellation.isCancelled()
                    }
                    continuation.resume(returning: work(shouldCancel))
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
    }
}

enum CostUsageRefreshPolicy {
    static let minimumAutomaticInterval: TimeInterval = 5 * 60
    static let generationContinuationInterval: TimeInterval = 5

    static func continuationDelay(after metrics: CostUsageScanMetrics) -> TimeInterval? {
        metrics.shouldContinueGeneration ? generationContinuationInterval : nil
    }

    static func shouldRequestRefresh(
        showsPeriodUsage: Bool,
        reason: RefreshReason,
        environment: RefreshEnvironment
    ) -> Bool {
        guard showsPeriodUsage,
              reason != .presentation,
              !environment.isConstrained else {
            return false
        }
        return true
    }
}

enum CostUsagePricing {
    struct Price: Equatable, Sendable {
        let inputPerMillion: Double
        let cachedInputPerMillion: Double
        let outputPerMillion: Double
        let longContextThreshold: Int?
        let usesSparkProxy: Bool
    }

    struct Estimate: Equatable, Sendable {
        let usd: Double
        let normalizedModel: String
        let usesSparkProxy: Bool
    }

    static let version = 2

    static func estimate(
        model rawModel: String,
        inputTokens: Int,
        cachedInputTokens: Int,
        outputTokens: Int
    ) -> Estimate? {
        let model = normalizeModel(rawModel)
        guard let price = price(for: model) else {
            return nil
        }

        let input = max(0, inputTokens)
        let cached = min(input, max(0, cachedInputTokens))
        let uncached = input - cached
        let output = max(0, outputTokens)
        let usesLongContext = price.longContextThreshold.map { input > $0 } ?? false
        let inputMultiplier = usesLongContext ? 2.0 : 1.0
        let outputMultiplier = usesLongContext ? 1.5 : 1.0
        let cost = (
            Double(uncached) * price.inputPerMillion * inputMultiplier
                + Double(cached) * price.cachedInputPerMillion * inputMultiplier
                + Double(output) * price.outputPerMillion * outputMultiplier
        ) / 1_000_000

        return Estimate(
            usd: max(0, cost),
            normalizedModel: model,
            usesSparkProxy: price.usesSparkProxy
        )
    }

    static func normalizeModel(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if value.hasPrefix("openai/") {
            value.removeFirst("openai/".count)
        }
        if value == "gpt-5.6" {
            return "gpt-5.6-sol"
        }
        if let suffix = value.range(of: #"-\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) {
            let base = String(value[..<suffix.lowerBound])
            if price(for: base) != nil {
                return base
            }
        }
        return String(value.prefix(128))
    }

    private static func price(for model: String) -> Price? {
        switch model {
        case "gpt-5.6-sol":
            Price(
                inputPerMillion: 5,
                cachedInputPerMillion: 0.5,
                outputPerMillion: 30,
                longContextThreshold: 272_000,
                usesSparkProxy: false
            )
        case "gpt-5.6-terra":
            Price(
                inputPerMillion: 2.5,
                cachedInputPerMillion: 0.25,
                outputPerMillion: 15,
                longContextThreshold: 272_000,
                usesSparkProxy: false
            )
        case "gpt-5.6-luna":
            Price(
                inputPerMillion: 1,
                cachedInputPerMillion: 0.1,
                outputPerMillion: 6,
                longContextThreshold: 272_000,
                usesSparkProxy: false
            )
        case "gpt-5.5":
            Price(
                inputPerMillion: 5,
                cachedInputPerMillion: 0.5,
                outputPerMillion: 30,
                longContextThreshold: 272_000,
                usesSparkProxy: false
            )
        case "gpt-5.3-codex":
            Price(
                inputPerMillion: 1.75,
                cachedInputPerMillion: 0.175,
                outputPerMillion: 14,
                longContextThreshold: nil,
                usesSparkProxy: false
            )
        case "gpt-5.3-codex-spark":
            Price(
                inputPerMillion: 1.75,
                cachedInputPerMillion: 0.175,
                outputPerMillion: 14,
                longContextThreshold: nil,
                usesSparkProxy: true
            )
        case "gpt-5.4-mini":
            Price(
                inputPerMillion: 0.75,
                cachedInputPerMillion: 0.075,
                outputPerMillion: 4.5,
                longContextThreshold: nil,
                usesSparkProxy: false
            )
        default:
            nil
        }
    }
}

final class CostUsageEstimator: @unchecked Sendable {
    private enum MetadataKey {
        static let schemaVersion = "cost_schema_version"
        static let pricingVersion = "cost_pricing_version"
        static let timeZoneFingerprint = "cost_timezone_fingerprint"
        static let scanStatus = "cost_scan_status"
        static let lastSliceMS = "cost_last_slice_ms"
        static let lastUpdateMS = "cost_last_update_ms"
        static let publishedSchemaVersion = "cost_published_schema_version"
        static let publishedPricingVersion = "cost_published_pricing_version"
        static let publishedTimeZoneFingerprint = "cost_published_timezone_fingerprint"
        static let publishedAtMS = "cost_published_at_ms"
        static let generationCursor = "cost_generation_cursor"
        static let generationInventoryTruncated = "cost_generation_inventory_truncated"
        static let generationStartedMS = "cost_generation_started_ms"
    }

    private static let schemaVersion: Int64 = 5
    private static let retentionDays = 31

    private let databasePath: String
    private let lock = NSLock()
    private var candidates: [CostUsageSessionCandidate] = []
    private var inventoryTruncated = false
    private var inventoryRequiresScan = true
    private var schemaReady = false
    private var lastAutomaticAttemptAt: Date?

    init(databasePath: String) {
        self.databasePath = databasePath
    }

    /// Decides whether the caller needs to enumerate rollout files. This is
    /// deliberately separate from `scanSlice` so the store can avoid the
    /// expensive inventory walk on ordinary cadence hits.
    func preflightInventoryDecision(
        now: Date = Date(),
        bypassCadence: Bool,
        reuseExistingCandidates: Bool
    ) -> CostUsageInventoryDecision {
        lock.lock()
        defer { lock.unlock() }

        if reuseExistingCandidates, !candidates.isEmpty {
            return .reuseCandidates
        }
        if bypassCadence {
            return .enumerate
        }

        do {
            let database = try CostUsageSQLiteDatabase(path: databasePath)
            try ensureSchema(in: database)
            let activeGeneration = try hasActiveGeneration(in: database)
            let minimumInterval = activeGeneration
                ? CostUsageRefreshPolicy.generationContinuationInterval
                : CostUsageRefreshPolicy.minimumAutomaticInterval
            let latestAttempt = [
                lastAutomaticAttemptAt,
                metadataValue(MetadataKey.lastSliceMS, in: database).map {
                    Date(timeIntervalSince1970: TimeInterval($0) / 1_000)
                }
            ].compactMap { $0 }.max()
            if let latestAttempt,
               now.timeIntervalSince(latestAttempt) >= 0,
               now.timeIntervalSince(latestAttempt) < minimumInterval {
                return .skipCadence(
                    isComplete: metadataValue(MetadataKey.scanStatus, in: database) == 2
                )
            }

            if activeGeneration, !candidates.isEmpty {
                return .reuseCandidates
            }
            return .enumerate
        } catch {
            // If the database cannot be opened/read, let scanSlice perform its
            // normal error handling after a fresh inventory attempt.
            return .enumerate
        }
    }

    func updateCandidates(
        _ candidates: [CostUsageSessionCandidate],
        inventoryTruncated: Bool
    ) {
        var seen: Set<String> = []
        let unique = candidates.filter { candidate in
            !candidate.sessionID.isEmpty
                && !candidate.path.isEmpty
                && seen.insert(candidate.sessionID.lowercased()).inserted
        }
        lock.lock()
        let previousIDs = Set(self.candidates.map { $0.sessionID.lowercased() })
        let nextIDs = Set(unique.map { $0.sessionID.lowercased() })
        if previousIDs != nextIDs || self.inventoryTruncated != inventoryTruncated {
            inventoryRequiresScan = true
        }
        self.candidates = unique
        self.inventoryTruncated = inventoryTruncated
        lock.unlock()
    }

    func scanSlice(
        now: Date = Date(),
        budget: CostUsageScanBudget = .automatic,
        bypassCadence: Bool = false,
        shouldCancel: @escaping @Sendable () -> Bool = { false }
    ) -> CostUsageScanMetrics {
        autoreleasepool {
            lock.lock()
            defer { lock.unlock() }

            guard !shouldCancel() else {
                return CostUsageScanMetrics(
                    jsonlBytesRead: 0,
                    filesAdvanced: 0,
                    databaseWrites: 0,
                    skippedOversizedRows: 0,
                    stopReason: .cancelled,
                    isComplete: false
                )
            }

            do {
            let database = try CostUsageSQLiteDatabase(path: databasePath)
            try ensureSchema(in: database)
            let minimumInterval = try hasActiveGeneration(in: database)
                ? CostUsageRefreshPolicy.generationContinuationInterval
                : CostUsageRefreshPolicy.minimumAutomaticInterval
            let latestAttempt = [
                lastAutomaticAttemptAt,
                metadataValue(MetadataKey.lastSliceMS, in: database).map {
                    Date(timeIntervalSince1970: TimeInterval($0) / 1_000)
                }
            ].compactMap { $0 }.max()
            if !bypassCadence,
               let latestAttempt,
               now.timeIntervalSince(latestAttempt) >= 0,
               now.timeIntervalSince(latestAttempt) < minimumInterval {
                return CostUsageScanMetrics(
                    jsonlBytesRead: 0,
                    filesAdvanced: 0,
                    databaseWrites: 0,
                    skippedOversizedRows: 0,
                    stopReason: .cadence,
                    isComplete: metadataValue(MetadataKey.scanStatus, in: database) == 2
                )
            }
            lastAutomaticAttemptAt = now

            let timeZoneFingerprint = Self.timeZoneFingerprint(TimeZone.current.identifier)
            let semanticsMatch = metadataValue(MetadataKey.schemaVersion, in: database) == Self.schemaVersion
                && metadataValue(MetadataKey.pricingVersion, in: database) == Int64(CostUsagePricing.version)
                && metadataValue(MetadataKey.timeZoneFingerprint, in: database) == timeZoneFingerprint
            var setupWrites = 0
            if !semanticsMatch {
                try resetDerivedCostData(
                    in: database,
                    timeZoneFingerprint: timeZoneFingerprint,
                    now: now
                )
                setupWrites = 1
                inventoryRequiresScan = true
            }

            var checkpoints = try loadCheckpoints(from: database)
            let liveFileCandidates = currentFileCandidates(now: now)
            let liveCandidatesByID = Dictionary(
                uniqueKeysWithValues: liveFileCandidates.map { ($0.sessionID, $0) }
            )
            let publishedSemanticsMatch = metadataValue(
                MetadataKey.publishedSchemaVersion,
                in: database
            ) == Self.schemaVersion
                && metadataValue(
                    MetadataKey.publishedPricingVersion,
                    in: database
                ) == Int64(CostUsagePricing.version)
                && metadataValue(
                    MetadataKey.publishedTimeZoneFingerprint,
                    in: database
                ) == timeZoneFingerprint
            var databaseWrites = setupWrites
            var generationTargets = try loadGenerationTargets(from: database)

            if !generationTargets.isEmpty {
                let generationWasTruncated = metadataValue(
                    MetadataKey.generationInventoryTruncated,
                    in: database
                ) == 1
                let invalidTarget = generationTargets.contains { target in
                    guard let live = liveCandidatesByID[target.sessionID] else {
                        return true
                    }
                    return !target.canRead(from: live.signature)
                }
                if invalidTarget || (generationWasTruncated && !inventoryTruncated) {
                    try clearGeneration(in: database)
                    generationTargets = []
                    databaseWrites += 1
                }
            }

            if generationTargets.isEmpty {
                if !inventoryTruncated {
                    let currentSessionIDs = Set(liveFileCandidates.map(\.sessionID))
                    let removedSessionIDs = checkpoints.keys.filter { !currentSessionIDs.contains($0) }
                    for sessionID in removedSessionIDs {
                        try deleteSession(sessionID, in: database)
                        checkpoints.removeValue(forKey: sessionID)
                        databaseWrites += 1
                    }
                }

                let liveSnapshotIsComplete = !inventoryTruncated
                    && liveFileCandidates.allSatisfy { file in
                        checkpoints[file.sessionID]?.matchesCompleted(file.signature) == true
                    }
                    && checkpoints.values.allSatisfy { !$0.tracker.sawRelevantOversizedRow }
                if liveSnapshotIsComplete,
                   databaseWrites == 0,
                   publishedSemanticsMatch {
                    inventoryRequiresScan = false
                    return CostUsageScanMetrics(
                        jsonlBytesRead: 0,
                        filesAdvanced: 0,
                        databaseWrites: 0,
                        skippedOversizedRows: 0,
                        stopReason: .caughtUp,
                        isComplete: true
                    )
                }

                guard !liveFileCandidates.isEmpty else {
                    let complete = !inventoryTruncated
                    if complete, databaseWrites > 0 || !publishedSemanticsMatch {
                        try publishCompletedCostData(
                            in: database,
                            timeZoneFingerprint: timeZoneFingerprint,
                            now: now,
                            clearsGeneration: true
                        )
                        databaseWrites += 1
                    } else if databaseWrites > 0 {
                        try updateScanMetadata(
                            complete: false,
                            timeZoneFingerprint: timeZoneFingerprint,
                            now: now,
                            in: database
                        )
                        databaseWrites += 1
                    }
                    if complete {
                        inventoryRequiresScan = false
                    }
                    return CostUsageScanMetrics(
                        jsonlBytesRead: 0,
                        filesAdvanced: 0,
                        databaseWrites: databaseWrites,
                        skippedOversizedRows: 0,
                        stopReason: .caughtUp,
                        isComplete: complete
                    )
                }

                generationTargets = try startGeneration(
                    candidates: liveFileCandidates,
                    inventoryTruncated: inventoryTruncated,
                    now: now,
                    in: database
                )
                databaseWrites += 1
            }

            let generationCursor = Int(metadataValue(
                MetadataKey.generationCursor,
                in: database
            ) ?? -1)
            let fileCandidates = Self.orderedGenerationCandidates(
                targets: generationTargets,
                liveCandidates: liveCandidatesByID,
                after: generationCursor
            )
            let knownSessionIDs = Set(generationTargets.map(\.sessionID))

            let startedCPU = SkillProcessResourceSnapshot.processCPUNanoseconds()
            let wallDeadline = ProcessInfo.processInfo.systemUptime + max(0, budget.maxWallTime)
            let cpuDeadline = startedCPU + budget.maxCPUNanoseconds
            var remainingBytes = budget.maxBytes
            var totalBytes: UInt64 = 0
            var filesAdvanced = 0
            var skippedOversizedRows = 0
            var deferredFork = false
            var stopReason: CostUsageScanStopReason = .caughtUp

            for file in fileCandidates {
                if shouldCancel() {
                    stopReason = .cancelled
                    break
                }
                if remainingBytes == 0 {
                    stopReason = .byteBudget
                    break
                }
                if ProcessInfo.processInfo.systemUptime >= wallDeadline {
                    stopReason = .wallTimeBudget
                    break
                }
                if SkillProcessResourceSnapshot.processCPUNanoseconds() >= cpuDeadline {
                    stopReason = .cpuBudget
                    break
                }

                let checkpoint = checkpoints[file.sessionID]
                if checkpoint?.matchesCompleted(file.signature) == true {
                    continue
                }

                let resetRequired = checkpoint.map { !$0.canResume(file.signature) } ?? false
                let initialCheckpoint = resetRequired ? nil : checkpoint
                var state = initialCheckpoint?.tracker ?? CostUsageTrackerState()
                let startOffset = initialCheckpoint?.processedOffset ?? 0
                let accumulator = CostUsageFileAccumulator(
                    sessionID: file.sessionID,
                    initialState: state,
                    sinceDay: Self.dayKey(for: Self.startOfRetentionWindow(now: now)),
                    untilDay: Self.dayKey(for: now),
                    resolveForkBaseline: { parentID, forkAtMS in
                        try Self.resolveForkBaseline(
                            parentID: parentID,
                            forkAtMS: forkAtMS,
                            knownSessionIDs: knownSessionIDs,
                            checkpoints: checkpoints,
                            database: database
                        )
                    }
                )

                let readResult = try CostUsageJSONLReader.read(
                    path: file.path,
                    startOffset: startOffset,
                    fileSize: file.signature.size,
                    byteBudget: remainingBytes,
                    maxRowBytes: budget.maxRowBytes,
                    initialDiscardingOversizedRow: state.discardingOversizedRow,
                    initialDiscardingOversizedRowIsRelevant: state.discardingOversizedRowIsRelevant,
                    wallDeadlineUptime: wallDeadline,
                    cpuDeadlineNanoseconds: cpuDeadline,
                    shouldCancel: shouldCancel,
                    processTruncatedPrefix: { prefix in
                        accumulator.processTruncatedPrefix(prefix)
                    },
                    process: { line in
                        accumulator.process(line: line)
                    }
                )
                totalBytes += readResult.bytesRead
                remainingBytes = remainingBytes > readResult.bytesRead
                    ? remainingBytes - readResult.bytesRead
                    : 0
                skippedOversizedRows += readResult.skippedOversizedRows

                if readResult.requiresFullRescan {
                    try deleteSession(file.sessionID, in: database)
                    checkpoints.removeValue(forKey: file.sessionID)
                    try setMetadata(
                        MetadataKey.generationCursor,
                        value: Int64(file.ordinal),
                        in: database
                    )
                    databaseWrites += 2
                    filesAdvanced += 1
                    stopReason = .deferredFork
                    continue
                }
                if readResult.deferredFork {
                    try setMetadata(
                        MetadataKey.generationCursor,
                        value: Int64(file.ordinal),
                        in: database
                    )
                    databaseWrites += 1
                    deferredFork = true
                    stopReason = .deferredFork
                    continue
                }
                if readResult.stopReason == .cancelled || shouldCancel() {
                    stopReason = .cancelled
                    break
                }

                state = accumulator.state
                state.discardingOversizedRow = readResult.discardingOversizedRow
                state.discardingOversizedRowIsRelevant = readResult.discardingOversizedRowIsRelevant
                state.sawRelevantOversizedRow = state.sawRelevantOversizedRow
                    || readResult.skippedRelevantOversizedRows > 0
                let reachedFrozenTarget = readResult.bytesRead
                    >= file.signature.size - min(startOffset, file.signature.size)
                let trimsTrailingIncompleteRow = reachedFrozenTarget
                    && readResult.stopReason == .endOfFile
                    && readResult.hasIncompleteRow
                    && !readResult.discardingOversizedRow
                let checkpointSignature = trimsTrailingIncompleteRow
                    ? file.signature.replacingSize(with: readResult.processedOffset)
                    : file.signature
                let complete = readResult.processedOffset >= checkpointSignature.size
                    && (!readResult.hasIncompleteRow
                        || trimsTrailingIncompleteRow
                        || readResult.discardingOversizedRow)
                let nextCheckpoint = CostUsageCheckpoint(
                    sessionID: file.sessionID,
                    inode: checkpointSignature.inode,
                    fileSize: checkpointSignature.size,
                    modifiedAtNanoseconds: checkpointSignature.modifiedAtNanoseconds,
                    processedOffset: readResult.processedOffset,
                    tracker: state,
                    complete: complete,
                    lastEventAtMS: state.lastEventAtMS,
                    sourceModifiedAtMS: checkpointSignature.modifiedAtMilliseconds
                )

                let madeProgress = resetRequired
                    || (checkpoint == nil && complete)
                    || readResult.processedOffset != startOffset
                    || !accumulator.bucketDeltas.isEmpty
                    || !accumulator.lineagePoints.isEmpty
                    || trimsTrailingIncompleteRow
                if madeProgress {
                    try persist(
                        checkpoint: nextCheckpoint,
                        resetSession: resetRequired,
                        buckets: accumulator.bucketDeltas,
                        lineagePoints: accumulator.lineagePoints,
                        usageRows: accumulator.usageRows,
                        generationCursor: file.ordinal,
                        generationTargetSize: trimsTrailingIncompleteRow
                            ? readResult.processedOffset
                            : nil,
                        in: database
                    )
                    checkpoints[file.sessionID] = nextCheckpoint
                    if trimsTrailingIncompleteRow,
                       let index = generationTargets.firstIndex(where: {
                           $0.sessionID == file.sessionID
                       }) {
                        generationTargets[index] = generationTargets[index].replacingTargetSize(
                            with: readResult.processedOffset
                        )
                    }
                    filesAdvanced += 1
                    databaseWrites += 1
                } else if readResult.bytesRead > 0 {
                    try setMetadata(
                        MetadataKey.generationCursor,
                        value: Int64(file.ordinal),
                        in: database
                    )
                    databaseWrites += 1
                }

                switch readResult.stopReason {
                case .byteBudget:
                    stopReason = .byteBudget
                case .cpuBudget:
                    stopReason = .cpuBudget
                case .wallTimeBudget:
                    stopReason = .wallTimeBudget
                case .cancelled:
                    stopReason = .cancelled
                case .endOfFile:
                    break
                }
                if readResult.stopReason != .endOfFile {
                    break
                }
            }

            let generationInventoryTruncated = metadataValue(
                MetadataKey.generationInventoryTruncated,
                in: database
            ) == 1
            let complete = !generationInventoryTruncated
                && generationTargets.allSatisfy { target in
                    guard let checkpoint = checkpoints[target.sessionID] else {
                        return false
                    }
                    return checkpoint.matchesCompleted(target.signature)
                        && !checkpoint.tracker.sawRelevantOversizedRow
                }
            if complete {
                let targetByID = Dictionary(
                    uniqueKeysWithValues: generationTargets.map { ($0.sessionID, $0) }
                )
                let liveStillMatchesGeneration = !inventoryTruncated
                    && liveFileCandidates.count == generationTargets.count
                    && liveFileCandidates.allSatisfy { live in
                        targetByID[live.sessionID]?.signature == live.signature
                    }
                inventoryRequiresScan = !liveStillMatchesGeneration
                try publishCompletedCostData(
                    in: database,
                    timeZoneFingerprint: timeZoneFingerprint,
                    now: now,
                    clearsGeneration: true
                )
                databaseWrites += 1
            } else if databaseWrites > 0 {
                try updateScanMetadata(
                    complete: false,
                    timeZoneFingerprint: timeZoneFingerprint,
                    now: now,
                    in: database
                )
                databaseWrites += 1
            }
            if stopReason == .caughtUp, deferredFork {
                stopReason = .deferredFork
            }

            return CostUsageScanMetrics(
                jsonlBytesRead: totalBytes,
                filesAdvanced: filesAdvanced,
                databaseWrites: databaseWrites,
                skippedOversizedRows: skippedOversizedRows,
                stopReason: complete && totalBytes == 0 ? .caughtUp : stopReason,
                isComplete: complete
            )
            } catch {
                return .unavailable
            }
        }
    }

    func loadSummary(now: Date = Date()) -> CostUsageSummary {
        lock.lock()
        defer { lock.unlock() }

        do {
            // Presentation consumes only a previously published snapshot. Do
            // not create or migrate the cache from a view appearance; the
            // explicit scanner is the sole schema-writing path.
            guard FileManager.default.fileExists(atPath: databasePath) else {
                return .unavailable
            }
            let database = try CostUsageSQLiteDatabase(path: databasePath, readOnly: true)
            let timeZoneFingerprint = Self.timeZoneFingerprint(TimeZone.current.identifier)
            let lastWorkingUpdate = metadataValue(MetadataKey.lastUpdateMS, in: database).map {
                Date(timeIntervalSince1970: TimeInterval($0) / 1_000)
            }
            guard metadataValue(MetadataKey.publishedSchemaVersion, in: database) == Self.schemaVersion,
                  metadataValue(MetadataKey.publishedPricingVersion, in: database) == Int64(CostUsagePricing.version),
                  metadataValue(MetadataKey.publishedTimeZoneFingerprint, in: database) == timeZoneFingerprint else {
                if metadataValue(MetadataKey.scanStatus, in: database) == 1 {
                    return .backfilling(lastUpdated: lastWorkingUpdate)
                }
                return .unavailable
            }

            let today = Self.dayKey(for: now)
            let sevenDayStart = Self.dayKey(for: Self.calendarDate(daysBefore: 6, now: now))
            let thirtyDayStart = Self.dayKey(for: Self.calendarDate(daysBefore: 29, now: now))
            let rows = try loadBucketSummary(
                sinceDay: thirtyDayStart,
                untilDay: today,
                from: database
            )
            let modelBuckets = try loadPublishedModelBuckets(
                sinceDay: thirtyDayStart,
                untilDay: today,
                from: database
            )
            let todayWindow = Self.makeWindow(
                rows: rows.filter { $0.day == today },
                globallyPartial: false
            )
            let sevenDayWindow = Self.makeWindow(
                rows: rows.filter { $0.day >= sevenDayStart },
                globallyPartial: false
            )
            let thirtyDayWindow = Self.makeWindow(rows: rows, globallyPartial: false)
            let hasAnyTokens = rows.contains { $0.totalTokens > 0 }
            let quality: CostUsageQuality
            if !hasAnyTokens {
                quality = .unavailable
            } else if rows.allSatisfy({ $0.unknownTokens == 0 }) {
                quality = .complete
            } else {
                quality = .partial
            }
            let lastUpdated = metadataValue(MetadataKey.publishedAtMS, in: database).map {
                Date(timeIntervalSince1970: TimeInterval($0) / 1_000)
            }

            return CostUsageSummary(
                today: todayWindow,
                sevenDays: sevenDayWindow,
                thirtyDays: thirtyDayWindow,
                quality: quality,
                lastUpdated: lastUpdated,
                usesSparkProxy: rows.contains(where: \.usesSparkProxy),
                tokenQuality: .complete,
                modelBuckets: modelBuckets
            )
        } catch {
            return .unavailable
        }
    }

    private func ensureSchema(in database: CostUsageSQLiteDatabase) throws {
        if schemaReady {
            return
        }
        try database.execute(
            """
            CREATE TABLE IF NOT EXISTS delta_cache_metadata (
              key TEXT PRIMARY KEY,
              value INTEGER NOT NULL
            );
            CREATE TABLE IF NOT EXISTS cost_usage_checkpoints (
              session_id TEXT PRIMARY KEY,
              inode INTEGER NOT NULL,
              file_size INTEGER NOT NULL,
              modified_at_ns INTEGER NOT NULL,
              processed_offset INTEGER NOT NULL,
              tracker_json TEXT NOT NULL,
              complete INTEGER NOT NULL,
              last_event_at_ms INTEGER,
              source_modified_at_ms INTEGER NOT NULL
            );
            CREATE TABLE IF NOT EXISTS cost_usage_buckets (
              session_id TEXT NOT NULL,
              day_key TEXT NOT NULL,
              model TEXT NOT NULL,
              input_tokens INTEGER NOT NULL,
              cached_input_tokens INTEGER NOT NULL,
              output_tokens INTEGER NOT NULL,
              cost_nanos INTEGER NOT NULL,
              is_priced INTEGER NOT NULL,
              uses_spark_proxy INTEGER NOT NULL,
              PRIMARY KEY(session_id, day_key, model)
            );
            CREATE TABLE IF NOT EXISTS cost_usage_rows (
              session_id TEXT NOT NULL,
              row_key BLOB NOT NULL,
              day_key TEXT NOT NULL,
              model TEXT NOT NULL,
              input_tokens INTEGER NOT NULL,
              cached_input_tokens INTEGER NOT NULL,
              output_tokens INTEGER NOT NULL,
              cost_nanos INTEGER NOT NULL,
              is_priced INTEGER NOT NULL,
              uses_spark_proxy INTEGER NOT NULL,
              PRIMARY KEY(session_id, row_key)
            );
            CREATE TABLE IF NOT EXISTS cost_usage_published_buckets (
              session_id TEXT NOT NULL,
              day_key TEXT NOT NULL,
              model TEXT NOT NULL,
              input_tokens INTEGER NOT NULL,
              cached_input_tokens INTEGER NOT NULL,
              output_tokens INTEGER NOT NULL,
              cost_nanos INTEGER NOT NULL,
              is_priced INTEGER NOT NULL,
              uses_spark_proxy INTEGER NOT NULL,
              PRIMARY KEY(session_id, day_key, model)
            );
            CREATE TABLE IF NOT EXISTS cost_usage_lineage_points (
              session_id TEXT NOT NULL,
              event_at_ms INTEGER NOT NULL,
              event_index INTEGER NOT NULL,
              input_tokens INTEGER NOT NULL,
              cached_input_tokens INTEGER NOT NULL,
              output_tokens INTEGER NOT NULL,
              PRIMARY KEY(session_id, event_at_ms, event_index)
            );
            CREATE TABLE IF NOT EXISTS cost_usage_scan_targets (
              session_id TEXT PRIMARY KEY,
              inode INTEGER NOT NULL,
              target_size INTEGER NOT NULL,
              modified_at_ns INTEGER NOT NULL,
              source_modified_at_ms INTEGER NOT NULL,
              ordinal INTEGER NOT NULL UNIQUE
            );
            CREATE INDEX IF NOT EXISTS idx_cost_usage_buckets_day
              ON cost_usage_buckets(day_key);
            CREATE INDEX IF NOT EXISTS idx_cost_usage_rows_key
              ON cost_usage_rows(row_key);
            CREATE INDEX IF NOT EXISTS idx_cost_usage_published_buckets_day
              ON cost_usage_published_buckets(day_key);
            CREATE INDEX IF NOT EXISTS idx_cost_usage_lineage_lookup
              ON cost_usage_lineage_points(session_id, event_at_ms DESC, event_index DESC);
            """
        )
        schemaReady = true
    }

    private func currentFileCandidates(now: Date) -> [CostUsageFileCandidate] {
        let cutoff = Self.startOfRetentionWindow(now: now).timeIntervalSince1970
        return candidates.compactMap { candidate in
            guard let signature = CostUsageFileSignature(path: candidate.path),
                  signature.modifiedAtSeconds >= cutoff else {
                return nil
            }
            return CostUsageFileCandidate(
                sessionID: candidate.sessionID.lowercased(),
                path: candidate.path,
                signature: signature
            )
        }.sorted {
            if $0.signature.modifiedAtNanoseconds == $1.signature.modifiedAtNanoseconds {
                return $0.sessionID < $1.sessionID
            }
            return $0.signature.modifiedAtNanoseconds > $1.signature.modifiedAtNanoseconds
        }
    }

    private func loadGenerationTargets(
        from database: CostUsageSQLiteDatabase
    ) throws -> [CostUsageGenerationTarget] {
        let statement = try database.statement(
            """
            SELECT session_id, inode, target_size, modified_at_ns,
                   source_modified_at_ms, ordinal
            FROM cost_usage_scan_targets
            ORDER BY ordinal;
            """
        )
        var targets: [CostUsageGenerationTarget] = []
        while try statement.step() {
            guard let sessionID = statement.string(at: 0) else {
                continue
            }
            targets.append(
                CostUsageGenerationTarget(
                    sessionID: sessionID,
                    inode: UInt64(bitPattern: statement.int64(at: 1)),
                    targetSize: UInt64(max(0, statement.int64(at: 2))),
                    modifiedAtNanoseconds: statement.int64(at: 3),
                    sourceModifiedAtMS: statement.int64(at: 4),
                    ordinal: Int(statement.int64(at: 5))
                )
            )
        }
        return targets
    }

    private func hasActiveGeneration(in database: CostUsageSQLiteDatabase) throws -> Bool {
        let statement = try database.statement(
            "SELECT 1 FROM cost_usage_scan_targets LIMIT 1;"
        )
        return try statement.step()
    }

    private func startGeneration(
        candidates: [CostUsageFileCandidate],
        inventoryTruncated: Bool,
        now: Date,
        in database: CostUsageSQLiteDatabase
    ) throws -> [CostUsageGenerationTarget] {
        // Persist one finite pass boundary across slices; otherwise active files
        // move live EOF faster than a complete inventory can be published. See ADR 0003.
        let targets = candidates.enumerated().map { ordinal, candidate in
            CostUsageGenerationTarget(
                sessionID: candidate.sessionID,
                inode: candidate.signature.inode,
                targetSize: candidate.signature.size,
                modifiedAtNanoseconds: candidate.signature.modifiedAtNanoseconds,
                sourceModifiedAtMS: candidate.signature.modifiedAtMilliseconds,
                ordinal: ordinal
            )
        }
        try database.execute("BEGIN IMMEDIATE;")
        do {
            try database.execute("DELETE FROM cost_usage_scan_targets;")
            let statement = try database.statement(
                """
                INSERT INTO cost_usage_scan_targets(
                  session_id, inode, target_size, modified_at_ns,
                  source_modified_at_ms, ordinal
                ) VALUES(?, ?, ?, ?, ?, ?);
                """
            )
            for target in targets {
                statement.reset()
                statement.bind(target.sessionID, at: 1)
                statement.bind(Int64(bitPattern: target.inode), at: 2)
                statement.bind(Int64(clamping: target.targetSize), at: 3)
                statement.bind(target.modifiedAtNanoseconds, at: 4)
                statement.bind(target.sourceModifiedAtMS, at: 5)
                statement.bind(target.ordinal, at: 6)
                try statement.run()
            }
            try setMetadata(MetadataKey.generationCursor, value: -1, in: database)
            try setMetadata(
                MetadataKey.generationInventoryTruncated,
                value: inventoryTruncated ? 1 : 0,
                in: database
            )
            try setMetadata(
                MetadataKey.generationStartedMS,
                value: Int64((now.timeIntervalSince1970 * 1_000).rounded()),
                in: database
            )
            try database.execute("COMMIT;")
        } catch {
            try? database.execute("ROLLBACK;")
            throw error
        }
        return targets
    }

    private func clearGeneration(
        in database: CostUsageSQLiteDatabase,
        insideTransaction: Bool = false
    ) throws {
        if !insideTransaction {
            try database.execute("BEGIN IMMEDIATE;")
        }
        do {
            try database.execute("DELETE FROM cost_usage_scan_targets;")
            for key in [
                MetadataKey.generationCursor,
                MetadataKey.generationInventoryTruncated,
                MetadataKey.generationStartedMS
            ] {
                try deleteMetadata(key, in: database)
            }
            if !insideTransaction {
                try database.execute("COMMIT;")
            }
        } catch {
            if !insideTransaction {
                try? database.execute("ROLLBACK;")
            }
            throw error
        }
    }

    private static func orderedGenerationCandidates(
        targets: [CostUsageGenerationTarget],
        liveCandidates: [String: CostUsageFileCandidate],
        after cursor: Int
    ) -> [CostUsageGenerationFileCandidate] {
        let sorted = targets.sorted { $0.ordinal < $1.ordinal }
        let splitIndex = sorted.firstIndex { $0.ordinal > cursor } ?? 0
        let rotated = Array(sorted[splitIndex...]) + Array(sorted[..<splitIndex])
        return rotated.compactMap { target in
            guard let live = liveCandidates[target.sessionID] else {
                return nil
            }
            return CostUsageGenerationFileCandidate(
                sessionID: target.sessionID,
                path: live.path,
                signature: target.signature,
                ordinal: target.ordinal
            )
        }
    }

    private func resetDerivedCostData(
        in database: CostUsageSQLiteDatabase,
        timeZoneFingerprint: Int64,
        now: Date
    ) throws {
        try database.execute("BEGIN IMMEDIATE;")
        do {
            try database.execute("DELETE FROM cost_usage_lineage_points;")
            try database.execute("DELETE FROM cost_usage_rows;")
            try database.execute("DELETE FROM cost_usage_buckets;")
            try database.execute("DELETE FROM cost_usage_published_buckets;")
            try database.execute("DELETE FROM cost_usage_checkpoints;")
            try database.execute("DELETE FROM cost_usage_scan_targets;")
            for key in [
                MetadataKey.publishedSchemaVersion,
                MetadataKey.publishedPricingVersion,
                MetadataKey.publishedTimeZoneFingerprint,
                MetadataKey.publishedAtMS,
                MetadataKey.generationCursor,
                MetadataKey.generationInventoryTruncated,
                MetadataKey.generationStartedMS
            ] {
                let statement = try database.statement(
                    "DELETE FROM delta_cache_metadata WHERE key = ?;"
                )
                statement.bind(key, at: 1)
                try statement.run()
            }
            try setMetadata(MetadataKey.schemaVersion, value: Self.schemaVersion, in: database)
            try setMetadata(MetadataKey.pricingVersion, value: Int64(CostUsagePricing.version), in: database)
            try setMetadata(MetadataKey.timeZoneFingerprint, value: timeZoneFingerprint, in: database)
            try setMetadata(MetadataKey.scanStatus, value: 1, in: database)
            try setMetadata(
                MetadataKey.lastUpdateMS,
                value: Int64((now.timeIntervalSince1970 * 1_000).rounded()),
                in: database
            )
            try database.execute("COMMIT;")
        } catch {
            try? database.execute("ROLLBACK;")
            throw error
        }
    }

    private func persist(
        checkpoint: CostUsageCheckpoint,
        resetSession: Bool,
        buckets: [CostUsageBucketKey: CostUsageBucketDelta],
        lineagePoints: [CostUsageLineagePoint],
        usageRows: [CostUsageRowOccurrence],
        generationCursor: Int,
        generationTargetSize: UInt64?,
        in database: CostUsageSQLiteDatabase
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let trackerData = try encoder.encode(checkpoint.tracker)
        guard let trackerJSON = String(data: trackerData, encoding: .utf8) else {
            throw CostUsageSQLiteError.encoding
        }

        try database.execute("BEGIN IMMEDIATE;")
        do {
            if resetSession {
                try deleteSession(checkpoint.sessionID, in: database, insideTransaction: true)
            }

            let bucketStatement = try database.statement(
                """
                INSERT INTO cost_usage_buckets(
                  session_id, day_key, model, input_tokens, cached_input_tokens,
                  output_tokens, cost_nanos, is_priced, uses_spark_proxy
                ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(session_id, day_key, model) DO UPDATE SET
                  input_tokens = input_tokens + excluded.input_tokens,
                  cached_input_tokens = cached_input_tokens + excluded.cached_input_tokens,
                  output_tokens = output_tokens + excluded.output_tokens,
                  cost_nanos = cost_nanos + excluded.cost_nanos,
                  is_priced = MIN(is_priced, excluded.is_priced),
                  uses_spark_proxy = MAX(uses_spark_proxy, excluded.uses_spark_proxy);
                """
            )
            for (key, delta) in buckets {
                bucketStatement.reset()
                bucketStatement.bind(checkpoint.sessionID, at: 1)
                bucketStatement.bind(key.day, at: 2)
                bucketStatement.bind(key.model, at: 3)
                bucketStatement.bind(Int64(delta.input), at: 4)
                bucketStatement.bind(Int64(delta.cached), at: 5)
                bucketStatement.bind(Int64(delta.output), at: 6)
                bucketStatement.bind(delta.costNanos, at: 7)
                bucketStatement.bind(delta.isPriced ? 1 : 0, at: 8)
                bucketStatement.bind(delta.usesSparkProxy ? 1 : 0, at: 9)
                try bucketStatement.run()
            }

            let rowStatement = try database.statement(
                """
                INSERT OR IGNORE INTO cost_usage_rows(
                  session_id, row_key, day_key, model, input_tokens,
                  cached_input_tokens, output_tokens, cost_nanos, is_priced,
                  uses_spark_proxy
                ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
                """
            )
            for row in usageRows {
                rowStatement.reset()
                rowStatement.bind(checkpoint.sessionID, at: 1)
                rowStatement.bind(row.key, at: 2)
                rowStatement.bind(row.day, at: 3)
                rowStatement.bind(row.model, at: 4)
                rowStatement.bind(Int64(row.input), at: 5)
                rowStatement.bind(Int64(row.cached), at: 6)
                rowStatement.bind(Int64(row.output), at: 7)
                rowStatement.bind(row.costNanos, at: 8)
                rowStatement.bind(row.isPriced ? 1 : 0, at: 9)
                rowStatement.bind(row.usesSparkProxy ? 1 : 0, at: 10)
                try rowStatement.run()
            }

            let lineageStatement = try database.statement(
                """
                INSERT OR REPLACE INTO cost_usage_lineage_points(
                  session_id, event_at_ms, event_index, input_tokens,
                  cached_input_tokens, output_tokens
                ) VALUES(?, ?, ?, ?, ?, ?);
                """
            )
            for point in lineagePoints {
                lineageStatement.reset()
                lineageStatement.bind(checkpoint.sessionID, at: 1)
                lineageStatement.bind(point.eventAtMS, at: 2)
                lineageStatement.bind(Int64(point.eventIndex), at: 3)
                lineageStatement.bind(Int64(point.totals.input), at: 4)
                lineageStatement.bind(Int64(point.totals.cached), at: 5)
                lineageStatement.bind(Int64(point.totals.output), at: 6)
                try lineageStatement.run()
            }

            let checkpointStatement = try database.statement(
                """
                INSERT INTO cost_usage_checkpoints(
                  session_id, inode, file_size, modified_at_ns, processed_offset,
                  tracker_json, complete, last_event_at_ms, source_modified_at_ms
                ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(session_id) DO UPDATE SET
                  inode = excluded.inode,
                  file_size = excluded.file_size,
                  modified_at_ns = excluded.modified_at_ns,
                  processed_offset = excluded.processed_offset,
                  tracker_json = excluded.tracker_json,
                  complete = excluded.complete,
                  last_event_at_ms = excluded.last_event_at_ms,
                  source_modified_at_ms = excluded.source_modified_at_ms;
                """
            )
            checkpointStatement.bind(checkpoint.sessionID, at: 1)
            checkpointStatement.bind(Int64(bitPattern: checkpoint.inode), at: 2)
            checkpointStatement.bind(Int64(clamping: checkpoint.fileSize), at: 3)
            checkpointStatement.bind(checkpoint.modifiedAtNanoseconds, at: 4)
            checkpointStatement.bind(Int64(clamping: checkpoint.processedOffset), at: 5)
            checkpointStatement.bind(trackerJSON, at: 6)
            checkpointStatement.bind(checkpoint.complete ? 1 : 0, at: 7)
            checkpointStatement.bind(checkpoint.lastEventAtMS, at: 8)
            checkpointStatement.bind(checkpoint.sourceModifiedAtMS, at: 9)
            try checkpointStatement.run()
            if let generationTargetSize {
                let targetStatement = try database.statement(
                    "UPDATE cost_usage_scan_targets SET target_size = ? WHERE session_id = ?;"
                )
                targetStatement.bind(Int64(clamping: generationTargetSize), at: 1)
                targetStatement.bind(checkpoint.sessionID, at: 2)
                try targetStatement.run()
            }
            try setMetadata(
                MetadataKey.generationCursor,
                value: Int64(generationCursor),
                in: database
            )
            try database.execute("COMMIT;")
        } catch {
            try? database.execute("ROLLBACK;")
            throw error
        }
    }

    private func deleteSession(
        _ sessionID: String,
        in database: CostUsageSQLiteDatabase,
        insideTransaction: Bool = false
    ) throws {
        if !insideTransaction {
            try database.execute("BEGIN IMMEDIATE;")
        }
        do {
            for table in [
                "cost_usage_lineage_points", "cost_usage_rows",
                "cost_usage_buckets", "cost_usage_checkpoints"
            ] {
                let statement = try database.statement("DELETE FROM \(table) WHERE session_id = ?;")
                statement.bind(sessionID, at: 1)
                try statement.run()
            }
            if !insideTransaction {
                try database.execute("COMMIT;")
            }
        } catch {
            if !insideTransaction {
                try? database.execute("ROLLBACK;")
            }
            throw error
        }
    }

    private func updateScanMetadata(
        complete: Bool,
        timeZoneFingerprint: Int64,
        now: Date,
        in database: CostUsageSQLiteDatabase
    ) throws {
        let nowMS = Int64((now.timeIntervalSince1970 * 1_000).rounded())
        try database.execute("BEGIN IMMEDIATE;")
        do {
            try setMetadata(MetadataKey.schemaVersion, value: Self.schemaVersion, in: database)
            try setMetadata(MetadataKey.pricingVersion, value: Int64(CostUsagePricing.version), in: database)
            try setMetadata(MetadataKey.timeZoneFingerprint, value: timeZoneFingerprint, in: database)
            try setMetadata(MetadataKey.scanStatus, value: complete ? 2 : 1, in: database)
            try setMetadata(MetadataKey.lastSliceMS, value: nowMS, in: database)
            try setMetadata(MetadataKey.lastUpdateMS, value: nowMS, in: database)
            try database.execute("COMMIT;")
        } catch {
            try? database.execute("ROLLBACK;")
            throw error
        }
    }

    private func publishCompletedCostData(
        in database: CostUsageSQLiteDatabase,
        timeZoneFingerprint: Int64,
        now: Date,
        clearsGeneration: Bool = false
    ) throws {
        let nowMS = Int64((now.timeIntervalSince1970 * 1_000).rounded())
        try database.execute("BEGIN IMMEDIATE;")
        do {
            try database.execute("DELETE FROM cost_usage_published_buckets;")
            try database.execute(
                """
                INSERT INTO cost_usage_published_buckets(
                  session_id, day_key, model, input_tokens, cached_input_tokens,
                  output_tokens, cost_nanos, is_priced, uses_spark_proxy
                )
                WITH unique_rows AS (
                  SELECT row_key,
                         MIN(day_key) AS day_key,
                         MIN(model) AS model,
                         MIN(input_tokens) AS input_tokens,
                         MIN(cached_input_tokens) AS cached_input_tokens,
                         MIN(output_tokens) AS output_tokens,
                         MIN(cost_nanos) AS cost_nanos,
                         MIN(is_priced) AS is_priced,
                         MAX(uses_spark_proxy) AS uses_spark_proxy
                  FROM cost_usage_rows
                  GROUP BY row_key
                )
                SELECT '__deduplicated__', day_key, model,
                       SUM(input_tokens), SUM(cached_input_tokens), SUM(output_tokens),
                       SUM(cost_nanos), MIN(is_priced), MAX(uses_spark_proxy)
                FROM unique_rows
                GROUP BY day_key, model;
                """
            )
            try setMetadata(
                MetadataKey.publishedSchemaVersion,
                value: Self.schemaVersion,
                in: database
            )
            try setMetadata(
                MetadataKey.publishedPricingVersion,
                value: Int64(CostUsagePricing.version),
                in: database
            )
            try setMetadata(
                MetadataKey.publishedTimeZoneFingerprint,
                value: timeZoneFingerprint,
                in: database
            )
            try setMetadata(MetadataKey.publishedAtMS, value: nowMS, in: database)
            if clearsGeneration {
                try clearGeneration(in: database, insideTransaction: true)
            }
            try setMetadata(MetadataKey.schemaVersion, value: Self.schemaVersion, in: database)
            try setMetadata(MetadataKey.pricingVersion, value: Int64(CostUsagePricing.version), in: database)
            try setMetadata(MetadataKey.timeZoneFingerprint, value: timeZoneFingerprint, in: database)
            try setMetadata(MetadataKey.scanStatus, value: 2, in: database)
            try setMetadata(MetadataKey.lastSliceMS, value: nowMS, in: database)
            try setMetadata(MetadataKey.lastUpdateMS, value: nowMS, in: database)
            try database.execute("COMMIT;")
        } catch {
            try? database.execute("ROLLBACK;")
            throw error
        }
    }

    private func metadataValue(_ key: String, in database: CostUsageSQLiteDatabase) -> Int64? {
        guard let statement = try? database.statement(
            "SELECT value FROM delta_cache_metadata WHERE key = ? LIMIT 1;"
        ) else {
            return nil
        }
        statement.bind(key, at: 1)
        guard (try? statement.step()) == true else {
            return nil
        }
        return statement.int64(at: 0)
    }

    private func setMetadata(
        _ key: String,
        value: Int64,
        in database: CostUsageSQLiteDatabase
    ) throws {
        let statement = try database.statement(
            """
            INSERT INTO delta_cache_metadata(key, value) VALUES(?, ?)
            ON CONFLICT(key) DO UPDATE SET value = excluded.value;
            """
        )
        statement.bind(key, at: 1)
        statement.bind(value, at: 2)
        try statement.run()
    }

    private func deleteMetadata(
        _ key: String,
        in database: CostUsageSQLiteDatabase
    ) throws {
        let statement = try database.statement(
            "DELETE FROM delta_cache_metadata WHERE key = ?;"
        )
        statement.bind(key, at: 1)
        try statement.run()
    }

    private func loadCheckpoints(
        from database: CostUsageSQLiteDatabase
    ) throws -> [String: CostUsageCheckpoint] {
        let statement = try database.statement(
            """
            SELECT session_id, inode, file_size, modified_at_ns, processed_offset,
                   tracker_json, complete, last_event_at_ms, source_modified_at_ms
            FROM cost_usage_checkpoints;
            """
        )
        let decoder = JSONDecoder()
        var checkpoints: [String: CostUsageCheckpoint] = [:]
        while try statement.step() {
            guard let sessionID = statement.string(at: 0),
                  let trackerJSON = statement.string(at: 5),
                  let trackerData = trackerJSON.data(using: .utf8),
                  let tracker = try? decoder.decode(CostUsageTrackerState.self, from: trackerData) else {
                continue
            }
            checkpoints[sessionID] = CostUsageCheckpoint(
                sessionID: sessionID,
                inode: UInt64(bitPattern: statement.int64(at: 1)),
                fileSize: UInt64(max(0, statement.int64(at: 2))),
                modifiedAtNanoseconds: statement.int64(at: 3),
                processedOffset: UInt64(max(0, statement.int64(at: 4))),
                tracker: tracker,
                complete: statement.int64(at: 6) != 0,
                lastEventAtMS: statement.optionalInt64(at: 7),
                sourceModifiedAtMS: statement.int64(at: 8)
            )
        }
        return checkpoints
    }

    private func loadBucketSummary(
        sinceDay: String,
        untilDay: String,
        from database: CostUsageSQLiteDatabase
    ) throws -> [CostUsageDaySummaryRow] {
        let statement = try database.statement(
            """
            SELECT day_key,
                   SUM(cost_nanos),
                   SUM(input_tokens + output_tokens),
                   SUM(CASE WHEN is_priced = 0 THEN input_tokens + output_tokens ELSE 0 END),
                   MAX(uses_spark_proxy)
            FROM cost_usage_published_buckets
            WHERE day_key >= ? AND day_key <= ?
            GROUP BY day_key
            ORDER BY day_key;
            """
        )
        statement.bind(sinceDay, at: 1)
        statement.bind(untilDay, at: 2)
        var rows: [CostUsageDaySummaryRow] = []
        while try statement.step() {
            guard let day = statement.string(at: 0) else {
                continue
            }
            rows.append(
                CostUsageDaySummaryRow(
                    day: day,
                    costNanos: statement.int64(at: 1),
                    totalTokens: Int(statement.int64(at: 2)),
                    unknownTokens: Int(statement.int64(at: 3)),
                    usesSparkProxy: statement.int64(at: 4) != 0
                )
            )
        }
        return rows
    }

    private func loadPublishedModelBuckets(
        sinceDay: String,
        untilDay: String,
        from database: CostUsageSQLiteDatabase
    ) throws -> [CostUsageModelDayBucket] {
        let statement = try database.statement(
            """
            SELECT day_key,
                   model,
                   SUM(input_tokens),
                   SUM(cached_input_tokens),
                   SUM(output_tokens),
                   SUM(cost_nanos),
                   MIN(is_priced),
                   MAX(uses_spark_proxy)
            FROM cost_usage_published_buckets
            WHERE day_key >= ? AND day_key <= ?
            GROUP BY day_key, model
            ORDER BY day_key, model;
            """
        )
        statement.bind(sinceDay, at: 1)
        statement.bind(untilDay, at: 2)
        var buckets: [CostUsageModelDayBucket] = []
        while try statement.step() {
            guard let dayKey = statement.string(at: 0),
                  let model = statement.string(at: 1) else {
                continue
            }
            buckets.append(
                CostUsageModelDayBucket(
                    dayKey: dayKey,
                    model: model,
                    inputTokens: Int(statement.int64(at: 2)),
                    cachedInputTokens: Int(statement.int64(at: 3)),
                    outputTokens: Int(statement.int64(at: 4)),
                    costNanos: statement.int64(at: 5),
                    isPriced: statement.int64(at: 6) != 0,
                    usesSparkProxy: statement.int64(at: 7) != 0
                )
            )
        }
        return buckets
    }

    private static func resolveForkBaseline(
        parentID: String,
        forkAtMS: Int64,
        knownSessionIDs: Set<String>,
        checkpoints: [String: CostUsageCheckpoint],
        database: CostUsageSQLiteDatabase
    ) throws -> CostUsageForkBaseline {
        let key = parentID.lowercased()
        guard let checkpoint = checkpoints[key] else {
            return knownSessionIDs.contains(key) ? .unresolved : .unavailable
        }
        guard checkpoint.complete else {
            return .unresolved
        }
        // CodexBar indexes a rollout by the id in its first session_meta row, not by the UUID
        // embedded in the filename. Exported fork rollouts can therefore have a filename id
        // that is not a resolvable parent id. Treat that case as unavailable so the child uses
        // CodexBar's bounded unresolved-fork fallback instead of subtracting the wrong snapshot.
        guard checkpoint.tracker.primarySessionMetadataID?.lowercased() == key else {
            return .unavailable
        }
        let statement = try database.statement(
            """
            SELECT input_tokens, cached_input_tokens, output_tokens
            FROM cost_usage_lineage_points
            WHERE session_id = ? AND event_at_ms <= ?
            ORDER BY event_at_ms DESC, event_index DESC
            LIMIT 1;
            """
        )
        statement.bind(key, at: 1)
        statement.bind(forkAtMS, at: 2)
        if try statement.step() {
            return .resolved(
                CostUsageTokenTotals(
                    input: Int(statement.int64(at: 0)),
                    cached: Int(statement.int64(at: 1)),
                    output: Int(statement.int64(at: 2))
                )
            )
        }
        return .resolved(.zero)
    }

    private static func makeWindow(
        rows: [CostUsageDaySummaryRow],
        globallyPartial: Bool
    ) -> CostEstimateWindow {
        let totalTokens = rows.reduce(0) { $0 + $1.totalTokens }
        let unknownTokens = rows.reduce(0) { $0 + $1.unknownTokens }
        let pricedTokens = max(0, totalTokens - unknownTokens)
        let costNanos = rows.reduce(Int64(0)) { partial, row in
            let (value, overflow) = partial.addingReportingOverflow(row.costNanos)
            return overflow ? Int64.max : value
        }
        let usd = pricedTokens > 0 ? Double(costNanos) / 1_000_000_000 : nil
        return CostEstimateWindow(
            usd: usd,
            isPartial: globallyPartial || unknownTokens > 0,
            tokenCount: totalTokens
        )
    }

    private static func startOfRetentionWindow(now: Date) -> Date {
        Calendar.current.date(
            byAdding: .day,
            value: -(retentionDays - 1),
            to: Calendar.current.startOfDay(for: now)
        ) ?? now.addingTimeInterval(-TimeInterval(retentionDays - 1) * 86_400)
    }

    private static func calendarDate(daysBefore: Int, now: Date) -> Date {
        Calendar.current.date(
            byAdding: .day,
            value: -max(0, daysBefore),
            to: Calendar.current.startOfDay(for: now)
        ) ?? now.addingTimeInterval(-TimeInterval(max(0, daysBefore)) * 86_400)
    }

    private static func dayKey(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private static func timeZoneFingerprint(_ value: String) -> Int64 {
        var hash: UInt64 = 1_469_598_103_934_665_603
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return Int64(bitPattern: hash)
    }
}

private struct CostUsageFileSignature: Equatable {
    let inode: UInt64
    let size: UInt64
    let modifiedAtNanoseconds: Int64
    let modifiedAtMilliseconds: Int64
    let modifiedAtSeconds: TimeInterval

    init(
        inode: UInt64,
        size: UInt64,
        modifiedAtNanoseconds: Int64,
        modifiedAtMilliseconds: Int64
    ) {
        self.inode = inode
        self.size = size
        self.modifiedAtNanoseconds = modifiedAtNanoseconds
        self.modifiedAtMilliseconds = modifiedAtMilliseconds
        modifiedAtSeconds = TimeInterval(modifiedAtMilliseconds) / 1_000
    }

    init?(path: String) {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let size = (attributes[.size] as? NSNumber)?.uint64Value,
              let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value,
              let modifiedAt = attributes[.modificationDate] as? Date else {
            return nil
        }
        self.inode = inode
        self.size = size
        modifiedAtSeconds = modifiedAt.timeIntervalSince1970
        modifiedAtMilliseconds = Int64((modifiedAtSeconds * 1_000).rounded())
        modifiedAtNanoseconds = Int64((modifiedAtSeconds * 1_000_000_000).rounded())
    }

    func replacingSize(with size: UInt64) -> CostUsageFileSignature {
        CostUsageFileSignature(
            inode: inode,
            size: size,
            modifiedAtNanoseconds: modifiedAtNanoseconds,
            modifiedAtMilliseconds: modifiedAtMilliseconds
        )
    }
}

private struct CostUsageFileCandidate {
    let sessionID: String
    let path: String
    let signature: CostUsageFileSignature
}

private struct CostUsageGenerationTarget {
    let sessionID: String
    let inode: UInt64
    let targetSize: UInt64
    let modifiedAtNanoseconds: Int64
    let sourceModifiedAtMS: Int64
    let ordinal: Int

    var signature: CostUsageFileSignature {
        CostUsageFileSignature(
            inode: inode,
            size: targetSize,
            modifiedAtNanoseconds: modifiedAtNanoseconds,
            modifiedAtMilliseconds: sourceModifiedAtMS
        )
    }

    func canRead(from liveSignature: CostUsageFileSignature) -> Bool {
        inode == liveSignature.inode
            && liveSignature.size >= targetSize
            && (liveSignature.size > targetSize
                || liveSignature.modifiedAtNanoseconds == modifiedAtNanoseconds)
    }

    func replacingTargetSize(with targetSize: UInt64) -> CostUsageGenerationTarget {
        CostUsageGenerationTarget(
            sessionID: sessionID,
            inode: inode,
            targetSize: targetSize,
            modifiedAtNanoseconds: modifiedAtNanoseconds,
            sourceModifiedAtMS: sourceModifiedAtMS,
            ordinal: ordinal
        )
    }
}

private struct CostUsageGenerationFileCandidate {
    let sessionID: String
    let path: String
    let signature: CostUsageFileSignature
    let ordinal: Int
}

private struct CostUsageCheckpoint {
    let sessionID: String
    let inode: UInt64
    let fileSize: UInt64
    let modifiedAtNanoseconds: Int64
    let processedOffset: UInt64
    let tracker: CostUsageTrackerState
    let complete: Bool
    let lastEventAtMS: Int64?
    let sourceModifiedAtMS: Int64

    func matchesCompleted(_ signature: CostUsageFileSignature) -> Bool {
        complete
            && inode == signature.inode
            && fileSize == signature.size
            && modifiedAtNanoseconds == signature.modifiedAtNanoseconds
            && processedOffset == signature.size
    }

    func canResume(_ signature: CostUsageFileSignature) -> Bool {
        inode == signature.inode
            && signature.size >= processedOffset
            && signature.size >= fileSize
            && (signature.size > fileSize || modifiedAtNanoseconds == signature.modifiedAtNanoseconds)
    }
}

private struct CostUsageDaySummaryRow {
    let day: String
    let costNanos: Int64
    let totalTokens: Int
    let unknownTokens: Int
    let usesSparkProxy: Bool
}

private struct CostUsageTokenTotals: Codable, Equatable, Sendable {
    var input: Int
    var cached: Int
    var output: Int

    static let zero = CostUsageTokenTotals(input: 0, cached: 0, output: 0)
}

private struct CostUsageTrackerState: Codable, Equatable {
    var currentModel: String?
    var currentTurnID: String?
    var lastUsageModel: String?
    var countedTotals: CostUsageTokenTotals?
    var rawTotalsBaseline: CostUsageTokenTotals?
    var watermark: CostUsageTokenTotals?
    var seenRawTotals: [CostUsageTokenTotals] = []
    var sawDivergentTotals = false
    var sawInterleavedTotals = false
    var eventIndex = 0
    var forkSnapshotCountedTotals: CostUsageTokenTotals?
    var forkSnapshotRawBaseline: CostUsageTokenTotals?
    var forkSnapshotWatermark: CostUsageTokenTotals?
    var forkSnapshotSeenRawTotals: [CostUsageTokenTotals] = []
    var forkSnapshotSawDivergentTotals = false
    var forkSnapshotSawInterleavedTotals = false
    var forkSnapshotEventIndex = 0
    var primarySessionMetadataID: String?
    var forkParentID: String?
    var forkAtMS: Int64?
    var inheritedTotals: CostUsageTokenTotals?
    var remainingInheritedTotals: CostUsageTokenTotals?
    var forkBaselineResolved = false
    var forkBaselineUnavailable = false
    var unresolvedForkTotalWatermark: CostUsageTokenTotals?
    var lastEventAtMS: Int64?
    var discardingOversizedRow = false
    var discardingOversizedRowIsRelevant = false
    var sawRelevantOversizedRow = false
}

private struct CostUsageBucketKey: Hashable {
    let day: String
    let model: String
}

private struct CostUsageBucketDelta {
    var input = 0
    var cached = 0
    var output = 0
    var costNanos: Int64 = 0
    var isPriced = true
    var usesSparkProxy = false
}

private struct CostUsageLineagePoint {
    let eventAtMS: Int64
    let eventIndex: Int
    let totals: CostUsageTokenTotals
}

private struct CostUsageRowOccurrence {
    let key: Data
    let day: String
    let model: String
    let input: Int
    let cached: Int
    let output: Int
    let costNanos: Int64
    let isPriced: Bool
    let usesSparkProxy: Bool
}

private enum CostUsageForkBaseline {
    case resolved(CostUsageTokenTotals)
    case unavailable
    case unresolved
}

private enum CostUsageLineDirective {
    case continueReading
    case deferFork
    case fullRescan
}

private final class CostUsageFileAccumulator {
    let sessionID: String
    private(set) var state: CostUsageTrackerState
    private(set) var bucketDeltas: [CostUsageBucketKey: CostUsageBucketDelta] = [:]
    private(set) var lineagePoints: [CostUsageLineagePoint] = []
    private(set) var usageRows: [CostUsageRowOccurrence] = []

    private let sinceDay: String
    private let untilDay: String
    private let resolveForkBaseline: (String, Int64) throws -> CostUsageForkBaseline

    init(
        sessionID: String,
        initialState: CostUsageTrackerState,
        sinceDay: String,
        untilDay: String,
        resolveForkBaseline: @escaping (String, Int64) throws -> CostUsageForkBaseline
    ) {
        self.sessionID = sessionID
        state = initialState
        self.sinceDay = sinceDay
        self.untilDay = untilDay
        self.resolveForkBaseline = resolveForkBaseline
    }

    func process(line: Data) -> CostUsageLineDirective {
        autoreleasepool {
            guard CostUsageRowClassifier.couldAffectCost(line),
                  let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let type = object["type"] as? String else {
                return .continueReading
            }

            switch type {
            case "session_meta":
                guard let payload = object["payload"] as? [String: Any] else {
                    return .continueReading
                }
                let metadataID = [
                    payload["session_id"], payload["sessionId"], payload["id"],
                    object["session_id"], object["sessionId"], object["id"]
                ].lazy.compactMap(Self.nonEmptyString).first?.lowercased()
                if state.primarySessionMetadataID == nil, let metadataID {
                    // CodexBar uses only the first session metadata identity for both fork
                    // lookup and cross-file usage-row deduplication.
                    state.primarySessionMetadataID = metadataID
                }
                let parentID = [
                    payload["forked_from_id"], payload["forkedFromId"],
                    payload["parent_session_id"], payload["parentSessionId"]
                ].lazy.compactMap(Self.nonEmptyString).first?.lowercased()
                guard let parentID else {
                    return .continueReading
                }
                let timestamp = Self.timestampMilliseconds(payload["timestamp"])
                    ?? Self.timestampMilliseconds(object["timestamp"])
                guard let timestamp else {
                    return .deferFork
                }
                if state.forkParentID != nil {
                    // Fork rollouts can embed ancestor session metadata. CodexBar keeps the
                    // first confirmed fork identity; later embedded metadata must not replace it.
                    return .continueReading
                }
                state.forkParentID = parentID
                state.forkAtMS = timestamp
                return resolveForkIfNeeded()

            case "turn_context":
                guard let payload = object["payload"] as? [String: Any] else {
                    return .continueReading
                }
                let info = payload["info"] as? [String: Any]
                let candidates = [
                    payload["model"], payload["model_name"], info?["model"],
                    info?["model_name"]
                ]
                var sawModelField = false
                var selectedModel: String?
                for candidate in candidates {
                    guard candidate is String else {
                        continue
                    }
                    sawModelField = true
                    if let model = Self.nonEmptyString(candidate) {
                        selectedModel = model
                        break
                    }
                }
                if let selectedModel {
                    state.currentModel = selectedModel
                } else if sawModelField {
                    // An explicitly empty context field clears stale model evidence.
                    state.currentModel = ""
                }
                return .continueReading

            case "event_msg":
                guard let payload = object["payload"] as? [String: Any] else {
                    return .continueReading
                }
                if payload["type"] as? String == "task_started" {
                    state.currentTurnID = Self.turnID(payload)
                    return .continueReading
                }
                guard payload["type"] as? String == "token_count",
                      let info = payload["info"] as? [String: Any],
                      let eventAtMS = Self.timestampMilliseconds(object["timestamp"]) else {
                    return .continueReading
                }
                if state.forkParentID != nil, !state.forkBaselineResolved {
                    let directive = resolveForkIfNeeded()
                    guard directive == .continueReading else {
                        return directive
                    }
                }
                let recordModel = Self.nonEmptyString(info["model"])
                    ?? Self.nonEmptyString(info["model_name"])
                    ?? Self.nonEmptyString(payload["model"])
                    ?? Self.nonEmptyString(object["model"])
                let last = (info["last_token_usage"] as? [String: Any]).map(Self.tokenTotals)
                let total = (info["total_token_usage"] as? [String: Any]).map(Self.tokenTotals)
                handleTokenCount(
                    eventAtMS: eventAtMS,
                    model: Self.nonEmptyString(state.currentModel)
                        ?? recordModel
                        ?? "unknown",
                    turnID: Self.turnID(payload) ?? state.currentTurnID,
                    last: last,
                    total: total
                )
                return .continueReading

            default:
                return .continueReading
            }
        }
    }

    func processTruncatedPrefix(_ prefix: Data) {
        guard let model = CostUsageTruncatedTurnContext.model(from: prefix) else {
            return
        }
        state.currentModel = model
    }

    private func resolveForkIfNeeded() -> CostUsageLineDirective {
        guard !state.forkBaselineResolved,
              let parentID = state.forkParentID,
              let forkAtMS = state.forkAtMS else {
            return .continueReading
        }
        do {
            switch try resolveForkBaseline(parentID, forkAtMS) {
            case let .resolved(totals):
                state.inheritedTotals = totals
                state.remainingInheritedTotals = totals
                state.forkBaselineResolved = true
                state.forkBaselineUnavailable = false
                return .continueReading
            case .unavailable:
                state.inheritedTotals = nil
                state.remainingInheritedTotals = nil
                state.forkBaselineResolved = true
                state.forkBaselineUnavailable = true
                return .continueReading
            case .unresolved:
                return .deferFork
            }
        } catch {
            return .deferFork
        }
    }

    private func handleTokenCount(
        eventAtMS: Int64,
        model rawModel: String,
        turnID: String?,
        last: CostUsageTokenTotals?,
        total: CostUsageTokenTotals?
    ) {
        state.lastEventAtMS = max(state.lastEventAtMS ?? eventAtMS, eventAtMS)
        recordForkSnapshot(eventAtMS: eventAtMS, last: last, total: total)
        var remainingInherited = state.remainingInheritedTotals

        func adjustedLast(_ value: CostUsageTokenTotals) -> CostUsageTokenTotals {
            guard var remaining = remainingInherited else {
                return value
            }
            let adjusted = CostUsageTokenTotals(
                input: max(0, value.input - remaining.input),
                cached: max(0, value.cached - remaining.cached),
                output: max(0, value.output - remaining.output)
            )
            remaining.input = max(0, remaining.input - value.input)
            remaining.cached = max(0, remaining.cached - value.cached)
            remaining.output = max(0, remaining.output - value.output)
            remainingInherited = remaining == .zero ? nil : remaining
            return adjusted
        }

        let adjustedTotal = total.map { raw -> CostUsageTokenTotals in
            guard let inherited = state.inheritedTotals else {
                return raw
            }
            return CostUsageTokenTotals(
                input: max(0, raw.input - inherited.input),
                cached: max(0, raw.cached - inherited.cached),
                output: max(0, raw.output - inherited.output)
            )
        }

        let normalizedUsageModel = CostUsagePricing.normalizeModel(rawModel)

        if let adjustedTotal {
            if state.seenRawTotals.contains(adjustedTotal) {
                return
            }
            latchInterleavedIfNeeded(adjustedTotal)
        }
        let watermarkBaseline = state.watermark ?? state.rawTotalsBaseline
        defer {
            if let adjustedTotal {
                commitObserved(adjustedTotal)
            }
        }

        func totalsDerivedDelta(_ current: CostUsageTokenTotals) -> CostUsageTokenTotals {
            if state.sawInterleavedTotals {
                return Self.containedDelta(
                    watermark: watermarkBaseline,
                    counted: state.countedTotals,
                    current: current
                )
            }
            if state.sawDivergentTotals {
                return Self.divergentDelta(
                    rawBaseline: watermarkBaseline,
                    countedBaseline: state.countedTotals,
                    current: current
                )
            }
            return Self.totalDelta(from: watermarkBaseline, to: current)
        }

        func commit(_ delta: CostUsageTokenTotals, rawBaseline: CostUsageTokenTotals) {
            state.countedTotals = Self.add(state.countedTotals ?? .zero, delta)
            state.rawTotalsBaseline = rawBaseline
            if state.rawTotalsBaseline != state.countedTotals {
                state.sawDivergentTotals = true
            }
        }

        var delta = CostUsageTokenTotals.zero
        if state.forkBaselineUnavailable, let current = total {
            let hadPriorUnresolvedTotal = state.unresolvedForkTotalWatermark != nil
            state.unresolvedForkTotalWatermark = current
            guard let last, hadPriorUnresolvedTotal else {
                return
            }
            delta = Self.minTotals(
                last,
                Self.totalDelta(from: watermarkBaseline, to: current)
            )
            state.countedTotals = Self.add(state.countedTotals ?? .zero, delta)
            state.rawTotalsBaseline = state.countedTotals
        } else if let current = adjustedTotal,
           state.forkParentID != nil,
           state.forkBaselineResolved {
            if state.sawInterleavedTotals {
                delta = Self.postLatchDelta(
                    watermark: watermarkBaseline,
                    counted: state.countedTotals,
                    current: current,
                    adjustedLast: last.map(adjustedLast)
                )
            } else {
                delta = totalsDerivedDelta(current)
            }
            commit(delta, rawBaseline: current)
            remainingInherited = nil
        } else if let last {
            let rawLast = last
            let hadInheritedReplay = remainingInherited != nil
            var adjusted = adjustedLast(rawLast)
            if let current = adjustedTotal {
                if state.sawInterleavedTotals {
                    adjusted = Self.postLatchDelta(
                        watermark: watermarkBaseline,
                        counted: state.countedTotals,
                        current: current,
                        adjustedLast: adjusted
                    )
                    remainingInherited = nil
                } else {
                    let totalDelta = Self.totalDelta(from: watermarkBaseline, to: current)
                    if !hadInheritedReplay,
                       Self.shouldPreferTotalDelta(
                           rawBaseline: watermarkBaseline,
                           current: current,
                           totalDelta: totalDelta,
                           lastDelta: rawLast,
                           sawDivergent: state.sawDivergentTotals
                       ) {
                        adjusted = totalDelta
                        remainingInherited = nil
                    }
                }
                delta = adjusted
                commit(adjusted, rawBaseline: current)
            } else {
                delta = adjusted
                state.countedTotals = Self.add(state.countedTotals ?? .zero, adjusted)
                state.rawTotalsBaseline = state.countedTotals
                raiseWatermark(to: state.countedTotals ?? .zero)
            }
        } else if let current = adjustedTotal {
            delta = totalsDerivedDelta(current)
            commit(delta, rawBaseline: current)
            remainingInherited = nil
        } else {
            return
        }
        state.remainingInheritedTotals = remainingInherited

        guard delta != .zero else {
            return
        }
        let eventIndex = state.eventIndex
        state.eventIndex += 1

        let date = Date(timeIntervalSince1970: TimeInterval(eventAtMS) / 1_000)
        let day = Self.dayKey(date)
        guard day >= sinceDay, day <= untilDay else {
            return
        }
        let estimate = CostUsagePricing.estimate(
            model: normalizedUsageModel,
            inputTokens: delta.input,
            cachedInputTokens: delta.cached,
            outputTokens: delta.output
        )
        var rowCostNanos: Int64 = 0
        if let estimate {
            let nanos = estimate.usd * 1_000_000_000
            if nanos.isFinite {
                let rounded = nanos.rounded()
                rowCostNanos = rounded >= Double(Int64.max)
                    ? Int64.max
                    : Int64(max(0, rounded))
            }
        }
        let row = CostUsageRowOccurrence(
            key: usageRowKey(
                day: day,
                model: normalizedUsageModel,
                turnID: turnID,
                eventIndex: eventIndex,
                delta: delta
            ),
            day: day,
            model: normalizedUsageModel,
            input: delta.input,
            cached: min(delta.input, delta.cached),
            output: delta.output,
            costNanos: rowCostNanos,
            isPriced: estimate != nil,
            usesSparkProxy: estimate?.usesSparkProxy == true
        )
        usageRows.append(row)

        let key = CostUsageBucketKey(day: day, model: normalizedUsageModel)
        var bucket = bucketDeltas[key] ?? CostUsageBucketDelta()
        bucket.input += delta.input
        bucket.cached += min(delta.input, delta.cached)
        bucket.output += delta.output
        if let estimate {
            let (sum, overflow) = bucket.costNanos.addingReportingOverflow(rowCostNanos)
            bucket.costNanos = overflow ? Int64.max : sum
            bucket.usesSparkProxy = bucket.usesSparkProxy || estimate.usesSparkProxy
        } else {
            bucket.isPriced = false
        }
        bucketDeltas[key] = bucket
    }

    private func usageRowKey(
        day: String,
        model: String,
        turnID: String?,
        eventIndex: Int,
        delta: CostUsageTokenTotals
    ) -> Data {
        let identity = state.primarySessionMetadataID.map { "session:\($0)" }
            ?? "file:\(sessionID)"
        let raw = [
            identity,
            turnID ?? "",
            String(eventIndex),
            day,
            model,
            String(delta.input),
            String(delta.cached),
            String(delta.output)
        ].joined(separator: "\u{1F}")
        return Data(SHA256.hash(data: Data(raw.utf8)))
    }

    private func recordForkSnapshot(
        eventAtMS: Int64,
        last: CostUsageTokenTotals?,
        total: CostUsageTokenTotals?
    ) {
        guard last != nil || total != nil else {
            return
        }

        let base = state.forkSnapshotCountedTotals ?? .zero
        if let total, state.forkSnapshotSeenRawTotals.contains(total) {
            appendForkSnapshot(base, eventAtMS: eventAtMS)
            return
        }

        if let total, let watermark = state.forkSnapshotWatermark,
           total.input < watermark.input
            || total.cached < watermark.cached
            || total.output < watermark.output {
            state.forkSnapshotSawInterleavedTotals = true
        }
        let watermarkBaseline = state.forkSnapshotWatermark ?? state.forkSnapshotRawBaseline
        let next: CostUsageTokenTotals

        if let last {
            var delta = last
            if let total {
                if state.forkSnapshotSawInterleavedTotals {
                    delta = Self.postLatchDelta(
                        watermark: watermarkBaseline,
                        counted: state.forkSnapshotCountedTotals,
                        current: total,
                        adjustedLast: last
                    )
                } else {
                    let totalDelta = Self.totalDelta(from: watermarkBaseline, to: total)
                    if Self.shouldPreferTotalDelta(
                        rawBaseline: watermarkBaseline,
                        current: total,
                        totalDelta: totalDelta,
                        lastDelta: last,
                        sawDivergent: state.forkSnapshotSawDivergentTotals
                    ) {
                        delta = totalDelta
                    }
                }
                next = Self.add(base, delta)
                state.forkSnapshotRawBaseline = total
                if total != next {
                    state.forkSnapshotSawDivergentTotals = true
                }
            } else {
                next = Self.add(base, delta)
                state.forkSnapshotRawBaseline = next
                state.forkSnapshotWatermark = Self.maxTotals(state.forkSnapshotWatermark, next)
            }
        } else if let total {
            let delta: CostUsageTokenTotals
            if state.forkSnapshotSawInterleavedTotals {
                delta = Self.containedDelta(
                    watermark: watermarkBaseline,
                    counted: state.forkSnapshotCountedTotals,
                    current: total
                )
            } else if state.forkSnapshotSawDivergentTotals {
                delta = Self.divergentDelta(
                    rawBaseline: watermarkBaseline,
                    countedBaseline: state.forkSnapshotCountedTotals,
                    current: total
                )
            } else {
                delta = Self.totalDelta(from: watermarkBaseline, to: total)
            }
            next = Self.add(base, delta)
            state.forkSnapshotRawBaseline = total
            if total != next {
                state.forkSnapshotSawDivergentTotals = true
            }
        } else {
            return
        }

        state.forkSnapshotCountedTotals = next
        if let total {
            state.forkSnapshotWatermark = Self.maxTotals(state.forkSnapshotWatermark, total)
            if !state.forkSnapshotSeenRawTotals.contains(total) {
                state.forkSnapshotSeenRawTotals.append(total)
                if state.forkSnapshotSeenRawTotals.count > 64 {
                    state.forkSnapshotSeenRawTotals.removeFirst(
                        state.forkSnapshotSeenRawTotals.count - 64
                    )
                }
            }
        }
        appendForkSnapshot(next, eventAtMS: eventAtMS)
    }

    private func appendForkSnapshot(_ totals: CostUsageTokenTotals, eventAtMS: Int64) {
        lineagePoints.append(
            CostUsageLineagePoint(
                eventAtMS: eventAtMS,
                eventIndex: state.forkSnapshotEventIndex,
                totals: totals
            )
        )
        state.forkSnapshotEventIndex += 1
    }

    private func latchInterleavedIfNeeded(_ totals: CostUsageTokenTotals) {
        guard let watermark = state.watermark else {
            return
        }
        if totals.input < watermark.input
            || totals.cached < watermark.cached
            || totals.output < watermark.output {
            state.sawInterleavedTotals = true
        }
    }

    private func commitObserved(_ totals: CostUsageTokenTotals) {
        raiseWatermark(to: totals)
        if !state.seenRawTotals.contains(totals) {
            state.seenRawTotals.append(totals)
            if state.seenRawTotals.count > 64 {
                state.seenRawTotals.removeFirst(state.seenRawTotals.count - 64)
            }
        }
    }

    private func raiseWatermark(to totals: CostUsageTokenTotals) {
        state.watermark = Self.maxTotals(state.watermark, totals)
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let value = value as? String else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func turnID(_ payload: [String: Any]) -> String? {
        if let direct = nonEmptyString(payload["turn_id"])
            ?? nonEmptyString(payload["turnId"])
            ?? nonEmptyString(payload["id"]) {
            return direct
        }
        guard let info = payload["info"] as? [String: Any] else {
            return nil
        }
        return nonEmptyString(info["turn_id"])
            ?? nonEmptyString(info["turnId"])
            ?? nonEmptyString(info["id"])
    }

    private static func tokenTotals(_ value: [String: Any]) -> CostUsageTokenTotals {
        CostUsageTokenTotals(
            input: max(0, intValue(value["input_tokens"])),
            cached: max(0, intValue(value["cached_input_tokens"] ?? value["cache_read_input_tokens"])),
            output: max(0, intValue(value["output_tokens"]))
        )
    }

    private static func intValue(_ value: Any?) -> Int {
        if let number = value as? NSNumber {
            return number.intValue
        }
        if let text = value as? String, let number = Int(text) {
            return number
        }
        return 0
    }

    private static func timestampMilliseconds(_ value: Any?) -> Int64? {
        if let number = value as? NSNumber {
            let raw = number.doubleValue
            return Int64((raw > 10_000_000_000 ? raw : raw * 1_000).rounded())
        }
        guard let text = nonEmptyString(value) else {
            return nil
        }
        if let raw = Double(text) {
            return Int64((raw > 10_000_000_000 ? raw : raw * 1_000).rounded())
        }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = fractional.date(from: text) ?? ISO8601DateFormatter().date(from: text)
        return date.map { Int64(($0.timeIntervalSince1970 * 1_000).rounded()) }
    }

    private static func dayKey(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private static func add(
        _ lhs: CostUsageTokenTotals,
        _ rhs: CostUsageTokenTotals
    ) -> CostUsageTokenTotals {
        CostUsageTokenTotals(
            input: lhs.input + rhs.input,
            cached: lhs.cached + rhs.cached,
            output: lhs.output + rhs.output
        )
    }

    private static func minTotals(
        _ lhs: CostUsageTokenTotals,
        _ rhs: CostUsageTokenTotals
    ) -> CostUsageTokenTotals {
        CostUsageTokenTotals(
            input: min(lhs.input, rhs.input),
            cached: min(lhs.cached, rhs.cached),
            output: min(lhs.output, rhs.output)
        )
    }

    private static func maxTotals(
        _ lhs: CostUsageTokenTotals?,
        _ rhs: CostUsageTokenTotals
    ) -> CostUsageTokenTotals {
        guard let lhs else {
            return rhs
        }
        return CostUsageTokenTotals(
            input: max(lhs.input, rhs.input),
            cached: max(lhs.cached, rhs.cached),
            output: max(lhs.output, rhs.output)
        )
    }

    private static func totalDelta(
        from baseline: CostUsageTokenTotals?,
        to current: CostUsageTokenTotals
    ) -> CostUsageTokenTotals {
        let baseline = baseline ?? .zero
        return CostUsageTokenTotals(
            input: max(0, current.input - baseline.input),
            cached: max(0, current.cached - baseline.cached),
            output: max(0, current.output - baseline.output)
        )
    }

    private static func divergentDelta(
        rawBaseline: CostUsageTokenTotals?,
        countedBaseline: CostUsageTokenTotals?,
        current: CostUsageTokenTotals
    ) -> CostUsageTokenTotals {
        let raw = rawBaseline ?? .zero
        let counted = countedBaseline ?? .zero
        func delta(_ raw: Int, _ counted: Int, _ current: Int) -> Int {
            current >= raw ? max(0, current - raw) : max(0, current - counted)
        }
        return CostUsageTokenTotals(
            input: delta(raw.input, counted.input, current.input),
            cached: delta(raw.cached, counted.cached, current.cached),
            output: delta(raw.output, counted.output, current.output)
        )
    }

    private static func containedDelta(
        watermark: CostUsageTokenTotals?,
        counted: CostUsageTokenTotals?,
        current: CostUsageTokenTotals
    ) -> CostUsageTokenTotals {
        let watermark = watermark ?? .zero
        let counted = counted ?? .zero
        func component(_ water: Int, _ counted: Int, _ current: Int) -> Int {
            current >= water
                ? max(0, current - max(water, counted))
                : max(0, current - counted)
        }
        return CostUsageTokenTotals(
            input: component(watermark.input, counted.input, current.input),
            cached: component(watermark.cached, counted.cached, current.cached),
            output: component(watermark.output, counted.output, current.output)
        )
    }

    private static func postLatchDelta(
        watermark: CostUsageTokenTotals?,
        counted: CostUsageTokenTotals?,
        current: CostUsageTokenTotals,
        adjustedLast: CostUsageTokenTotals?
    ) -> CostUsageTokenTotals {
        let contained = containedDelta(watermark: watermark, counted: counted, current: current)
        guard let adjustedLast else {
            return contained
        }
        return minTotals(adjustedLast, contained)
    }

    private static func shouldPreferTotalDelta(
        rawBaseline: CostUsageTokenTotals?,
        current: CostUsageTokenTotals,
        totalDelta: CostUsageTokenTotals,
        lastDelta: CostUsageTokenTotals,
        sawDivergent: Bool
    ) -> Bool {
        guard !sawDivergent, let rawBaseline else {
            return false
        }
        let currentAtLeastBaseline = current.input >= rawBaseline.input
            && current.cached >= rawBaseline.cached
            && current.output >= rawBaseline.output
        let totalWithinLast = totalDelta.input <= lastDelta.input
            && totalDelta.cached <= lastDelta.cached
            && totalDelta.output <= lastDelta.output
        return currentAtLeastBaseline && totalWithinLast
    }
}

private enum CostUsageJSONLStopReason: Equatable {
    case endOfFile
    case byteBudget
    case cpuBudget
    case wallTimeBudget
    case cancelled
}

private struct CostUsageJSONLReadResult {
    let processedOffset: UInt64
    let bytesRead: UInt64
    let skippedOversizedRows: Int
    let skippedRelevantOversizedRows: Int
    let discardingOversizedRow: Bool
    let discardingOversizedRowIsRelevant: Bool
    let hasIncompleteRow: Bool
    let deferredFork: Bool
    let requiresFullRescan: Bool
    let stopReason: CostUsageJSONLStopReason
}

private enum CostUsageJSONLReader {
    private static let chunkBytes = 64 * 1024

    static func read(
        path: String,
        startOffset: UInt64,
        fileSize: UInt64,
        byteBudget: UInt64,
        maxRowBytes: Int,
        initialDiscardingOversizedRow: Bool,
        initialDiscardingOversizedRowIsRelevant: Bool,
        wallDeadlineUptime: TimeInterval,
        cpuDeadlineNanoseconds: UInt64,
        shouldCancel: @escaping @Sendable () -> Bool,
        processTruncatedPrefix: (Data) -> Void,
        process: (Data) -> CostUsageLineDirective
    ) throws -> CostUsageJSONLReadResult {
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? handle.close() }
        try handle.seek(toOffset: startOffset)

        var currentOffset = startOffset
        var lineStartOffset = startOffset
        var committedOffset = startOffset
        var bytesRead: UInt64 = 0
        var lineBuffer = Data()
        lineBuffer.reserveCapacity(min(max(1, maxRowBytes), chunkBytes))
        var discardingOversized = initialDiscardingOversizedRow
        var discardingOversizedIsRelevant = initialDiscardingOversizedRowIsRelevant
        var skippedOversized = 0
        var skippedRelevantOversized = 0
        var deferredFork = false
        var requiresFullRescan = false
        var stopReason: CostUsageJSONLStopReason?

        while currentOffset < fileSize, bytesRead < byteBudget {
            if shouldCancel() {
                stopReason = .cancelled
                break
            }
            if ProcessInfo.processInfo.systemUptime >= wallDeadlineUptime {
                stopReason = .wallTimeBudget
                break
            }
            if SkillProcessResourceSnapshot.processCPUNanoseconds() >= cpuDeadlineNanoseconds {
                stopReason = .cpuBudget
                break
            }

            let remainingFile = fileSize - currentOffset
            let remainingBudget = byteBudget - bytesRead
            let requested = Int(min(UInt64(chunkBytes), remainingFile, remainingBudget))
            guard requested > 0,
                  let chunk = try handle.read(upToCount: requested),
                  !chunk.isEmpty else {
                break
            }
            let chunkStart = currentOffset
            bytesRead += UInt64(chunk.count)
            currentOffset += UInt64(chunk.count)

            var cursor = 0
            while cursor < chunk.count {
                let newline = chunk[cursor...].firstIndex(of: 0x0A)
                let end = newline ?? chunk.endIndex
                let segment = chunk[cursor..<end]
                if !discardingOversized, !segment.isEmpty {
                    let available = max(0, maxRowBytes - lineBuffer.count)
                    let accepted = min(available, segment.count)
                    if accepted > 0 {
                        lineBuffer.append(segment.prefix(accepted))
                    }
                    if accepted < segment.count {
                        processTruncatedPrefix(lineBuffer)
                        discardingOversizedIsRelevant = CostUsageRowClassifier.requiresCompleteRow(lineBuffer)
                        lineBuffer.removeAll(keepingCapacity: true)
                        discardingOversized = true
                    }
                }

                guard let newline else {
                    break
                }
                let lineEndOffset = chunkStart + UInt64(newline + 1)
                if discardingOversized {
                    skippedOversized += 1
                    if discardingOversizedIsRelevant {
                        skippedRelevantOversized += 1
                    }
                    discardingOversized = false
                    discardingOversizedIsRelevant = false
                } else if !lineBuffer.isEmpty {
                    switch process(lineBuffer) {
                    case .continueReading:
                        break
                    case .deferFork:
                        deferredFork = true
                    case .fullRescan:
                        requiresFullRescan = true
                    }
                }
                lineBuffer.removeAll(keepingCapacity: true)
                committedOffset = lineEndOffset
                lineStartOffset = lineEndOffset
                cursor = newline + 1

                if deferredFork || requiresFullRescan {
                    break
                }
                if shouldCancel() {
                    stopReason = .cancelled
                    break
                }
                if ProcessInfo.processInfo.systemUptime >= wallDeadlineUptime {
                    stopReason = .wallTimeBudget
                    break
                }
                if SkillProcessResourceSnapshot.processCPUNanoseconds() >= cpuDeadlineNanoseconds {
                    stopReason = .cpuBudget
                    break
                }
            }
            if deferredFork || requiresFullRescan || stopReason != nil {
                break
            }
        }

        if stopReason == nil {
            if currentOffset >= fileSize {
                stopReason = .endOfFile
            } else if bytesRead >= byteBudget {
                stopReason = .byteBudget
            } else {
                stopReason = .endOfFile
            }
        }

        let hasIncompleteRow = !lineBuffer.isEmpty || discardingOversized
        let processedOffset: UInt64
        if deferredFork || requiresFullRescan {
            processedOffset = startOffset
        } else if discardingOversized {
            processedOffset = currentOffset
        } else if hasIncompleteRow {
            processedOffset = lineStartOffset
        } else {
            processedOffset = committedOffset
        }
        return CostUsageJSONLReadResult(
            processedOffset: processedOffset,
            bytesRead: bytesRead,
            skippedOversizedRows: skippedOversized,
            skippedRelevantOversizedRows: skippedRelevantOversized,
            discardingOversizedRow: discardingOversized,
            discardingOversizedRowIsRelevant: discardingOversizedIsRelevant,
            hasIncompleteRow: hasIncompleteRow,
            deferredFork: deferredFork,
            requiresFullRescan: requiresFullRescan,
            stopReason: stopReason ?? .endOfFile
        )
    }
}

private enum CostUsageRowClassifier {
    private static let probes = [
        Data("\"session_meta\"".utf8),
        Data("\"turn_context\"".utf8),
        Data("\"token_count\"".utf8),
        Data("\"task_started\"".utf8)
    ]

    static func couldAffectCost(_ data: Data) -> Bool {
        probes.contains { data.range(of: $0) != nil }
    }

    static func requiresCompleteRow(_ data: Data) -> Bool {
        data.range(of: probes[0]) != nil
            || data.range(of: probes[2]) != nil
            || data.range(of: probes[3]) != nil
    }
}

private enum CostUsageTruncatedTurnContext {
    static func model(from data: Data) -> String? {
        guard data.range(of: Data("\"turn_context\"".utf8)) != nil else {
            return nil
        }
        let text = String(decoding: data, as: UTF8.self)
        guard let payload = objectField("payload", in: text[...]),
              stringField("type", in: text[...]) == "turn_context" else {
            return nil
        }
        let info = objectField("info", in: payload)
        let candidates = [
            stringFieldAllowingEmpty("model", in: payload),
            stringFieldAllowingEmpty("model_name", in: payload),
            info.flatMap { stringFieldAllowingEmpty("model", in: $0) },
            info.flatMap { stringFieldAllowingEmpty("model_name", in: $0) }
        ]
        var sawCandidate = false
        for candidate in candidates {
            guard let candidate else {
                continue
            }
            sawCandidate = true
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        if sawCandidate, isCompleteObject(payload) {
            return ""
        }
        return nil
    }

    private static func isCompleteObject(_ text: Substring) -> Bool {
        guard text.first == "{" else {
            return false
        }
        var index = text.startIndex
        var depth = 0
        while index < text.endIndex {
            switch text[index] {
            case "{":
                depth += 1
                text.formIndex(after: &index)
            case "}":
                depth -= 1
                text.formIndex(after: &index)
                if depth == 0 {
                    return true
                }
                if depth < 0 {
                    return false
                }
            case "\"":
                guard parseString(in: text, index: &index) != nil else {
                    return false
                }
            default:
                text.formIndex(after: &index)
            }
        }
        return false
    }

    private static func stringField(_ key: String, in text: Substring) -> String? {
        guard let value = stringFieldAllowingEmpty(key, in: text), !value.isEmpty else {
            return nil
        }
        return value
    }

    private static func stringFieldAllowingEmpty(_ key: String, in text: Substring) -> String? {
        field(key, in: text) { source, index in
            parseString(in: source, index: &index)
        }
    }

    private static func objectField(_ key: String, in text: Substring) -> Substring? {
        field(key, in: text) { source, index in
            guard index < source.endIndex, source[index] == "{" else {
                return nil
            }
            return source[index...]
        }
    }

    private static func field<T>(
        _ key: String,
        in text: Substring,
        parseValue: (Substring, inout String.Index) -> T?
    ) -> T? {
        var index = text.startIndex
        var depth = 0
        while index < text.endIndex {
            switch text[index] {
            case "{":
                depth += 1
                text.formIndex(after: &index)
            case "}":
                depth -= 1
                text.formIndex(after: &index)
            case "\"":
                var next = index
                guard let parsedKey = parseString(in: text, index: &next) else {
                    return nil
                }
                index = next
                guard depth == 1, parsedKey == key else {
                    continue
                }
                skipWhitespace(in: text, index: &index)
                guard index < text.endIndex, text[index] == ":" else {
                    continue
                }
                text.formIndex(after: &index)
                skipWhitespace(in: text, index: &index)
                if let value = parseValue(text, &index) {
                    return value
                }
            default:
                text.formIndex(after: &index)
            }
        }
        return nil
    }

    private static func parseString(in text: Substring, index: inout String.Index) -> String? {
        guard index < text.endIndex, text[index] == "\"" else {
            return nil
        }
        text.formIndex(after: &index)
        var value = ""
        var escaped = false
        while index < text.endIndex {
            let character = text[index]
            text.formIndex(after: &index)
            if escaped {
                value.append(character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "\"" {
                return value
            } else {
                value.append(character)
            }
        }
        return nil
    }

    private static func skipWhitespace(in text: Substring, index: inout String.Index) {
        while index < text.endIndex, text[index].isWhitespace {
            text.formIndex(after: &index)
        }
    }
}

private enum CostUsageSQLiteError: Error {
    case open(String)
    case prepare(String)
    case execute(String)
    case encoding
}

private final class CostUsageSQLiteDatabase {
    private var handle: OpaquePointer?

    init(path: String, readOnly: Bool = false) throws {
        if !readOnly {
            let directory = URL(fileURLWithPath: path).deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let flags = readOnly
            ? SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
            : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK,
              let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            if let handle {
                sqlite3_close(handle)
            }
            throw CostUsageSQLiteError.open(message)
        }
        sqlite3_busy_timeout(handle, 1_000)
    }

    deinit {
        if let handle {
            sqlite3_close(handle)
        }
    }

    func execute(_ sql: String) throws {
        guard let handle else {
            throw CostUsageSQLiteError.open("closed")
        }
        var message: UnsafeMutablePointer<Int8>?
        let status = sqlite3_exec(handle, sql, nil, nil, &message)
        guard status == SQLITE_OK else {
            let detail = message.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(handle))
            if let message {
                sqlite3_free(message)
            }
            throw CostUsageSQLiteError.execute(detail)
        }
    }

    func statement(_ sql: String) throws -> CostUsageSQLiteStatement {
        guard let handle else {
            throw CostUsageSQLiteError.open("closed")
        }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw CostUsageSQLiteError.prepare(String(cString: sqlite3_errmsg(handle)))
        }
        return CostUsageSQLiteStatement(handle: handle, statement: statement)
    }
}

private final class CostUsageSQLiteStatement {
    private let handle: OpaquePointer
    private let statement: OpaquePointer

    init(handle: OpaquePointer, statement: OpaquePointer) {
        self.handle = handle
        self.statement = statement
    }

    deinit {
        sqlite3_finalize(statement)
    }

    func reset() {
        sqlite3_reset(statement)
        sqlite3_clear_bindings(statement)
    }

    func bind(_ value: String?, at index: Int32) {
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }
        _ = value.withCString { pointer in
            sqlite3_bind_text(statement, index, pointer, -1, costUsageSQLiteTransient)
        }
    }

    func bind(_ value: Data, at index: Int32) {
        value.withUnsafeBytes { bytes in
            _ = sqlite3_bind_blob(
                statement,
                index,
                bytes.baseAddress,
                Int32(bytes.count),
                costUsageSQLiteTransient
            )
        }
    }

    func bind(_ value: Int64?, at index: Int32) {
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }
        sqlite3_bind_int64(statement, index, value)
    }

    func bind(_ value: Int, at index: Int32) {
        sqlite3_bind_int64(statement, index, Int64(value))
    }

    func run() throws {
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw CostUsageSQLiteError.execute(String(cString: sqlite3_errmsg(handle)))
        }
    }

    func step() throws -> Bool {
        let status = sqlite3_step(statement)
        if status == SQLITE_ROW {
            return true
        }
        if status == SQLITE_DONE {
            return false
        }
        throw CostUsageSQLiteError.execute(String(cString: sqlite3_errmsg(handle)))
    }

    func int64(at index: Int32) -> Int64 {
        sqlite3_column_int64(statement, index)
    }

    func optionalInt64(at index: Int32) -> Int64? {
        sqlite3_column_type(statement, index) == SQLITE_NULL ? nil : int64(at: index)
    }

    func string(at index: Int32) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL,
              let value = sqlite3_column_text(statement, index) else {
            return nil
        }
        return String(cString: value)
    }
}

private let costUsageSQLiteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
