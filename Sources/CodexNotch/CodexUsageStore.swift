import Foundation
import Darwin

private enum UsageScanPolicy {
    static var ripgrepCandidates: [String] {
        [
            CodexRuntimeLocator.executable(named: "rg"),
            "/opt/homebrew/bin/rg",
            "/usr/local/bin/rg",
            "/usr/bin/rg"
        ].compactMap { $0 }
    }
    static let runningActivityWindow = 10 * 60
    static let fastSnapshotTokenScanLimit: UInt64 = 2 * 1024 * 1024
    static let largeSessionTokenScanLimit: UInt64 = 20 * 1024 * 1024
    static let staleSessionTokenScanLimit: UInt64 = 2 * 1024 * 1024
    static let recentSessionScanWindow: TimeInterval = 10 * 60
    static let periodUsageTailLineLimit = 4_000
    static let contextUsageTailLineLimit = 200
    static let contextVisibleTaskLimit = 4
    static let estimatedTokenLineBytes: UInt64 = 1_300
    static let periodUsageCacheTTL: TimeInterval = 120
    static let ripgrepTimeout: DispatchTimeInterval = .seconds(12)
    static let appServerFreshCacheTTL: TimeInterval = 5 * 60
    static let appServerStaleGraceTTL: TimeInterval = 15 * 60
    static let appServerRetryDelays: [TimeInterval] = [30, 60, 120, 300]
    static let appServerReboundConfirmationDelay: TimeInterval = 30
    static let appServerReboundThreshold = 10
    static let rateLimitCandidateRecencyWindow: TimeInterval = 10 * 60
    static let rateLimitResetTolerance = 60
    static let rateLimitConsensusMinimumSupport = 2
    static let deltaHistoryRetentionDays = 31
}

typealias AppServerRateLimitLoader = @Sendable (Date) throws -> RateLimitSnapshot

final class CodexUsageStore: @unchecked Sendable {
    static let fastSnapshotCacheMaxAge: TimeInterval = 30

    private struct SessionLineEvent {
        let timestamp: Date
        let topLevelType: String?
        let payloadType: String?
        let payloadPhase: String?
        let payloadStatus: String?
    }

    private struct ModelQuotaFamily {
        let id: String
        let displayName: String
        let matchTerms: [String]
        let windows: [ModelQuotaWindowSpec]

        func matches(_ values: [String?]) -> Bool {
            values.contains { value in
                guard let value else {
                    return false
                }
                let normalized = ModelQuotaFamily.normalized(value)
                return matchTerms.contains { normalized.contains($0) }
            }
        }

        static let spark = ModelQuotaFamily(
            id: "spark",
            displayName: "GPT-5.3-Codex-Spark",
            matchTerms: [
                "spark",
                "bengalfox",
                "gpt-5.3-codex-spark"
            ],
            windows: [
                ModelQuotaWindowSpec(idSuffix: "5h", label: "5h", source: .primary),
                ModelQuotaWindowSpec(idSuffix: "7d", label: "7d", source: .secondary)
            ]
        )

        private static func normalized(_ value: String) -> String {
            value
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "_", with: "-")
                .lowercased()
        }
    }

    private struct ModelQuotaWindowSpec {
        enum Source {
            case primary
            case secondary
        }

        let idSuffix: String
        let label: String
        let source: Source
    }

    private struct ModelQuotaWindowSource {
        let usedPercent: Double?
        let resetAt: Int?
        let resetText: String?
    }

    private static let exposedModelQuotaFamilies: [ModelQuotaFamily] = [.spark]

    private let codexDirectory: URL
    private let stateDatabase: String
    private let logsDatabase: String
    private let deltaDatabase: String
    private let legacyDeltaDatabase: String?
    private let costUsageEstimator: CostUsageEstimator
    private let sessionIndexPath: String
    private let appServerExecutable: String?
    private let appServerRateLimitLoader: AppServerRateLimitLoader?
    private let appServerCacheURL: URL?
    private let ripgrepCandidates: [String]
    private let diagnostics: MonitorDiagnostics?
    private let tokenPattern = /tool_token_count=([0-9]+)/
    private let terminalEventTypes: Set<String> = [
        "task_complete",
        "task_completed",
        "task_stopped",
        "task_failed",
        "task_cancelled",
        "turn_complete",
        "turn_completed",
        "turn_aborted",
        "turn_failed",
        "turn_cancelled"
    ]
    private let cacheLock = NSLock()
    private let deltaCacheSetupLock = NSLock()
    private let deltaWriteLock = NSLock()
    private let costUsagePerformanceLock = NSLock()
    private var fastCache: FastSnapshotCache?
    private var deltaCacheReady = false
    private var recentPathsCache: RecentPathsCache?
    private var recentTaskPathsCache: RecentPathsCache?
    private var appServerRateLimitCache = AppServerRateLimitCache()
    private var periodUsageCache: PeriodUsageCache?
    private var sessionTokenTotalCache: [String: SessionTokenTotalCache] = [:]
    private var sessionContextUsageCache: [String: SessionContextUsageCache] = [:]
    private var sessionPrefixFactsCache: [String: SessionPrefixFactsCache] = [:]
    private var sessionRateLimitCache: [String: SessionRateLimitCache] = [:]
    private var sessionActivityCache: [String: SessionActivityCache] = [:]
    private var sessionFileCacheCounters = SessionFileCacheCounters()
    private var costUsagePerformanceStats = CostUsagePerformanceStats.zero

    init(
        codexDirectory: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex"),
        stateDatabase: String? = nil,
        logsDatabase: String? = nil,
        deltaDatabase: String? = nil,
        ripgrepCandidates: [String]? = nil,
        appServerExecutable: String? = nil,
        appServerRateLimitLoader: AppServerRateLimitLoader? = nil,
        appServerCacheURL: URL? = nil,
        initialAppServerRateLimits: RateLimitSnapshot? = nil,
        diagnostics: MonitorDiagnostics? = nil
    ) {
        self.codexDirectory = codexDirectory
        self.ripgrepCandidates = ripgrepCandidates ?? UsageScanPolicy.ripgrepCandidates
        self.appServerExecutable = appServerExecutable ?? CodexRuntimeLocator.executable(named: "codex")
        self.appServerRateLimitLoader = appServerRateLimitLoader
        let defaultCodexDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex")
            .standardizedFileURL
        self.diagnostics = diagnostics
            ?? (codexDirectory.standardizedFileURL == defaultCodexDirectory ? MonitorDiagnostics.shared : nil)
        self.appServerCacheURL = appServerCacheURL
            ?? (codexDirectory.standardizedFileURL == defaultCodexDirectory
                ? Self.defaultAppServerCacheURL()
                : nil)
        let legacyDeltaPath = codexDirectory.appendingPathComponent("context-guard/usage-deltas.sqlite").path
        self.deltaDatabase = Self.expandedPath(
            deltaDatabase
                ?? ProcessInfo.processInfo.environment["CODEX_USAGE_DELTA_DB"]
                ?? Self.defaultDeltaDatabasePath(for: codexDirectory)
        )
        self.costUsageEstimator = CostUsageEstimator(databasePath: self.deltaDatabase)
        self.legacyDeltaDatabase = self.deltaDatabase == legacyDeltaPath ? nil : legacyDeltaPath
        self.stateDatabase = stateDatabase.map(Self.expandedPath)
            ?? Self.latestSQLiteDatabase(
                in: codexDirectory,
                prefix: "state_",
                fallback: "state_5.sqlite"
            )
        self.logsDatabase = logsDatabase.map(Self.expandedPath)
            ?? Self.latestSQLiteDatabase(
                in: codexDirectory,
                prefix: "logs_",
                fallback: "logs_2.sqlite"
            )
        self.sessionIndexPath = codexDirectory.appendingPathComponent("session_index.jsonl").path
        if let initialAppServerRateLimits {
            self.appServerRateLimitCache.lastSuccess = initialAppServerRateLimits
            self.appServerRateLimitCache.lastSuccessAt = initialAppServerRateLimits.capturedAt ?? Date()
        } else if let persisted = loadPersistedAppServerRateLimits() {
            self.appServerRateLimitCache.lastSuccess = persisted.snapshot
            self.appServerRateLimitCache.lastSuccessAt = persisted.savedAt
        }
    }

    static func defaultDeltaDatabasePath(for codexDirectory: URL) -> String {
        let defaultCodexPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex")
            .standardizedFileURL
            .path
        let requestedCodexPath = codexDirectory.standardizedFileURL.path
        guard requestedCodexPath == defaultCodexPath else {
            return codexDirectory.appendingPathComponent("context-guard/usage-deltas.sqlite").path
        }

        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        return applicationSupport
            .appendingPathComponent("CodexNotch", isDirectory: true)
            .appendingPathComponent("usage-deltas.sqlite")
            .path
    }

    func sessionFileCacheStats() -> SessionFileCacheStats {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        let paths = Set(sessionTokenTotalCache.keys)
            .union(sessionContextUsageCache.keys)
            .union(sessionPrefixFactsCache.keys)
            .union(sessionRateLimitCache.keys)
            .union(sessionActivityCache.keys)
        return SessionFileCacheStats(
            prefixScans: sessionFileCacheCounters.prefixScans,
            rateLimitScans: sessionFileCacheCounters.rateLimitScans,
            activityScans: sessionFileCacheCounters.activityScans,
            fastSnapshotHits: sessionFileCacheCounters.fastSnapshotHits,
            entryCount: paths.count
        )
    }

    private static func defaultAppServerCacheURL() -> URL {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        return applicationSupport
            .appendingPathComponent("CodexNotch", isDirectory: true)
            .appendingPathComponent("app-server-rate-limits.json")
    }

    private static func expandedPath(_ path: String) -> String {
        guard path.hasPrefix("~/") else {
            return path
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(String(path.dropFirst(2)))
            .path
    }

    private static func latestSQLiteDatabase(in directory: URL, prefix: String, fallback: String) -> String {
        let fallbackPath = directory.appendingPathComponent(fallback).path
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else {
            return fallbackPath
        }

        let candidates = urls.compactMap { url -> (version: Int, path: String)? in
            guard url.pathExtension == "sqlite" else {
                return nil
            }
            let name = url.deletingPathExtension().lastPathComponent
            guard name.hasPrefix(prefix) else {
                return nil
            }
            let suffix = name.dropFirst(prefix.count)
            guard let version = Int(suffix) else {
                return nil
            }
            return (version, url.path)
        }

        return candidates.max { $0.version < $1.version }?.path ?? fallbackPath
    }

    func loadSnapshot(
        includePeriodUsage: Bool = true,
        fallbackUsage: PeriodUsage? = nil,
        bypassFastCache: Bool = false,
        rateLimitSource: RateLimitSourcePreference = .appServerFirst,
        taskHistoryRange: TaskHistoryRange = .threeDays,
        includeContextUsage: Bool = false,
        contextTaskLimit: Int = UsageScanPolicy.contextVisibleTaskLimit,
        now: Date = Date()
    ) -> UsageSnapshot {
        let snapshotStartedAt = Date()
        if !bypassFastCache,
           !includePeriodUsage,
           let cachedSnapshot = cachedFastSnapshot(
                now: now,
                fallbackUsage: fallbackUsage,
                rateLimitSource: rateLimitSource,
                taskHistoryRange: taskHistoryRange,
                includeContextUsage: includeContextUsage,
                contextTaskLimit: contextTaskLimit
           ) {
            return cachedSnapshot
        }

        do {
            let databaseThreads = try loadRecentThreads(range: taskHistoryRange, now: now)
            let knownTokens = tokenMap(from: databaseThreads)
            let sessionThreads = loadRecentSessionThreads(
                range: taskHistoryRange,
                now: now,
                knownTokens: knownTokens
            )
            let activeSubagentParents = loadActiveSubagentParentThreads(now: now)
            let subagentUsage = loadSubagentUsage(range: taskHistoryRange, now: now)
            let baseThreads = mergeThreadRecords(databaseThreads + sessionThreads + activeSubagentParents)
            let displayThreads = withSubagentUsage(baseThreads, usage: subagentUsage)
            let usageDeltaDatabaseThreads = try loadUsageDeltaThreads(range: .month, now: now)
            let usageDeltaSessionThreads = loadRecentSessionThreads(
                range: .month,
                now: now,
                knownTokens: tokenMap(from: usageDeltaDatabaseThreads)
            )
            let usageDeltaThreads = mergeThreadRecords(
                usageDeltaDatabaseThreads + usageDeltaSessionThreads + activeSubagentParents
            )
            let activeThreadIDs = ((try? loadActiveThreadIDs(now: now)) ?? [])
                .union(activeSessionThreadIDs(from: displayThreads, now: now))
                .union(activeSubagentParents.map(\.id))
            let cumulativeUsage = loadCumulativeUsage()
            let recentUsage = loadRecentUsage(now: now)
            let rateLimitPaths = candidateRateLimitPaths(from: displayThreads)
            let rateLimitResult = loadRateLimits(
                from: rateLimitPaths,
                source: rateLimitSource,
                now: now,
                diagnosticID: UUID().uuidString
            )
            let deltaStartedAt = Date()
            recordDeltaSnapshot(for: usageDeltaThreads, now: now)
            let usageResult = includePeriodUsage
                ? loadRollingPeriodUsage(for: usageDeltaThreads, now: now)
                : PeriodUsageResult(usage: fallbackUsage ?? .zero, quality: .empty)
            let dailyUsage = loadDailyUsage(for: usageDeltaThreads, now: now)
            let deltas = loadTokenDeltas(for: baseThreads, now: now)
            let aggregateDeltas = loadAggregateTokenDeltas(for: baseThreads, now: now)
            let deltaDurationMs = elapsedMilliseconds(since: deltaStartedAt)
            let taskResult = buildTasks(
                from: displayThreads,
                activeThreadIDs: activeThreadIDs,
                deltas: deltas,
                todayTotalTokens: dailyUsage.usageTodayTokens,
                now: now,
                includeContextUsage: includeContextUsage,
                contextTaskLimit: contextTaskLimit
            )
            let costUsagePathLimit = max(TaskHistoryRange.month.queryLimit * 3, 80)
            let recentTaskPaths = recentTaskSessionPaths(limit: costUsagePathLimit)
            let recentAllSessionPaths = recentSessionPaths(limit: costUsagePathLimit)
            let retainedSessionPathList = recentTaskPaths
                + recentAllSessionPaths
                + displayThreads.map(\.rolloutPath)
                + usageDeltaThreads.map(\.rolloutPath)
                + rateLimitPaths
            let retainedSessionPaths = Set(retainedSessionPathList)
                .filter { !$0.isEmpty && FileManager.default.fileExists(atPath: $0) }
            trimSessionFileCaches(retaining: retainedSessionPaths)
            cacheFastSnapshot(
                threads: displayThreads,
                usageThreads: usageDeltaThreads,
                activeThreadIDs: activeThreadIDs,
                rateLimits: rateLimitResult.snapshot,
                periodUsage: usageResult.usage,
                periodUsageQuality: usageResult.quality,
                dailyUsage: dailyUsage,
                signaturePaths: rateLimitPaths,
                rateLimitSourceName: rateLimitResult.source,
                rateLimitSource: rateLimitSource,
                taskHistoryRange: taskHistoryRange,
                now: now
            )
            let snapshotDurationMs = elapsedMilliseconds(since: snapshotStartedAt)

            return UsageSnapshot(
                primaryPercent: rateLimitResult.snapshot.primaryDisplayPercent(now: now),
                secondaryPercent: rateLimitResult.snapshot.secondaryDisplayPercent(now: now),
                primaryResetsAt: rateLimitResult.snapshot.primaryResetsAt,
                secondaryResetsAt: rateLimitResult.snapshot.secondaryResetsAt,
                primaryWindowMinutes: rateLimitResult.snapshot.primaryWindowMinutes,
                secondaryWindowMinutes: rateLimitResult.snapshot.secondaryWindowMinutes,
                cumulativeUsage: cumulativeUsage,
                recentUsage: recentUsage,
                dailyUsage: dailyUsage,
                usage1h: aggregateDeltas.delta1hTokens,
                usage24h: usageResult.usage.day,
                usage7d: usageResult.usage.week,
                usage30d: usageResult.usage.month,
                periodUsageQuality: usageResult.quality,
                sparkQuotaWindows: displaySparkQuotaWindows(rateLimitResult.snapshot, now: now),
                tasks: taskResult.tasks,
                isRunning: taskResult.tasks.contains { $0.status == .running },
                lastUpdated: now,
                rateLimitCapturedAt: rateLimitResult.snapshot.capturedAt,
                errorMessage: nil,
                monitorStats: MonitorPerformanceStats(
                    lastSnapshotDurationMs: snapshotDurationMs,
                    lastUsageDurationMs: includePeriodUsage ? snapshotDurationMs : nil,
                    lastDeltaDurationMs: deltaDurationMs,
                    lastRateLimitSource: rateLimitResult.source,
                    watchedPathCount: 0,
                    jsonlContextScans: taskResult.contextScans,
                    monitorModelTokens: 0
                ),
                resetCreditCount: rateLimitResult.snapshot.resetCredits?.availableCount(now: now),
                resetCreditExpiryNotice: rateLimitResult.snapshot.resetCredits?.expiryNotice(now: now)
            )
        } catch {
            return errorSnapshot(error, now: now, snapshotDurationMs: elapsedMilliseconds(since: snapshotStartedAt))
        }
    }

    @discardableResult
    func recordDeltaSnapshot(now: Date = Date(), range: TaskHistoryRange = .month) -> Bool {
        let databaseThreads = (try? loadUsageDeltaThreads(range: range, now: now)) ?? []
        let sessionThreads = loadRecentSessionThreads(
            range: range,
            now: now,
            knownTokens: tokenMap(from: databaseThreads)
        )
        let threads = mergeThreadRecords(databaseThreads + sessionThreads + loadActiveSubagentParentThreads(now: now))
        return recordDeltaSnapshot(for: threads, now: now)
    }

    func loadUsageTotals(now: Date = Date()) -> PeriodUsage? {
        let databaseThreads = (try? loadUsageDeltaThreads(range: .month, now: now)) ?? []
        let sessionThreads = loadRecentSessionThreads(
            range: .month,
            now: now,
            knownTokens: tokenMap(from: databaseThreads)
        )
        let threads = mergeThreadRecords(databaseThreads + sessionThreads + loadActiveSubagentParentThreads(now: now))
        return loadRollingPeriodUsage(for: threads, now: now).usage
    }

    func loadDailyUsage(now: Date = Date()) -> DailyUsage {
        let databaseThreads = (try? loadUsageDeltaThreads(range: .month, now: now)) ?? []
        let sessionThreads = loadRecentSessionThreads(
            range: .month,
            now: now,
            knownTokens: tokenMap(from: databaseThreads)
        )
        let threads = mergeThreadRecords(databaseThreads + sessionThreads + loadActiveSubagentParentThreads(now: now))
        return loadDailyUsage(for: threads, now: now)
    }

    func refreshCostUsageSlice(
        now: Date = Date(),
        bypassCadence: Bool = false,
        shouldCancel: @escaping @Sendable () -> Bool = { false }
    ) -> CostUsageScanMetrics {
        let retentionStart = Calendar.current.date(
            byAdding: .day,
            value: -30,
            to: Calendar.current.startOfDay(for: now)
        ) ?? now.addingTimeInterval(-30 * 86_400)
        let paths = CodexSessionFileLocator.recentRolloutPaths(
            roots: [
                codexDirectory.appendingPathComponent("sessions", isDirectory: true),
                codexDirectory.appendingPathComponent("archived_sessions", isDirectory: true)
            ],
            modifiedSince: retentionStart,
            limit: nil
        )
        updateCostUsageCandidates(from: paths, inventoryTruncated: false)

        deltaWriteLock.lock()
        defer { deltaWriteLock.unlock() }
        let metrics = costUsageEstimator.scanSlice(
            now: now,
            bypassCadence: bypassCadence,
            shouldCancel: shouldCancel
        )
        costUsagePerformanceLock.lock()
        costUsagePerformanceStats = CostUsagePerformanceStats(
            scanCount: costUsagePerformanceStats.scanCount + 1,
            jsonlBytesRead: costUsagePerformanceStats.jsonlBytesRead + metrics.jsonlBytesRead,
            filesAdvanced: costUsagePerformanceStats.filesAdvanced + metrics.filesAdvanced,
            databaseWrites: costUsagePerformanceStats.databaseWrites + metrics.databaseWrites
        )
        costUsagePerformanceLock.unlock()
        return metrics
    }

    func costUsagePerformanceStatsSnapshot() -> CostUsagePerformanceStats {
        costUsagePerformanceLock.lock()
        defer { costUsagePerformanceLock.unlock() }
        return costUsagePerformanceStats
    }

    func resetCostUsagePerformanceStatsForTesting() {
        costUsagePerformanceLock.lock()
        costUsagePerformanceStats = .zero
        costUsagePerformanceLock.unlock()
    }

    func loadCostUsageSummary(now: Date = Date()) -> CostUsageSummary {
        deltaWriteLock.lock()
        defer { deltaWriteLock.unlock() }
        return costUsageEstimator.loadSummary(now: now)
    }

    func rateLimitWatchPaths() -> [String] {
        let threads = Array(((try? loadRecentThreads(range: .day)) ?? []).prefix(4))
        return uniqueExistingPaths(
            candidateRateLimitPaths(from: threads, recentLimit: 4)
                + recentSessionActivityWatchPaths(limit: 8)
                + sqliteFileSet(stateDatabase)
                + sqliteFileSet(logsDatabase)
                + [sessionIndexPath]
        )
    }

    @discardableResult
    func refreshAppServerRateLimits(now: Date = Date(), force: Bool = false) -> Bool {
        cacheLock.lock()
        if appServerRateLimitCache.isRefreshing {
            cacheLock.unlock()
            return false
        }
        if !force {
            if let retryNotBefore = appServerRateLimitCache.retryNotBefore,
               now < retryNotBefore {
                cacheLock.unlock()
                return false
            }
            if let lastSuccessAt = appServerRateLimitCache.lastSuccessAt,
               now.timeIntervalSince(lastSuccessAt) < UsageScanPolicy.appServerFreshCacheTTL,
               appServerRateLimitCache.consecutiveFailures == 0,
               !hasReachedMainRateLimitReset(appServerRateLimitCache.lastSuccess, now: now) {
                cacheLock.unlock()
                return false
            }
        }
        appServerRateLimitCache.isRefreshing = true
        appServerRateLimitCache.lastAttemptAt = now
        cacheLock.unlock()

        let startedAt = Date()
        do {
            let snapshot = try fetchAppServerRateLimits(now: now)
            cacheLock.lock()
            if let previous = appServerRateLimitCache.lastSuccess,
               isSuspiciousAppServerRebound(snapshot, comparedTo: previous) {
                if let pending = appServerRateLimitCache.pendingRebound,
                   sameMainRateLimitGeneration(snapshot, pending) {
                    appServerRateLimitCache.pendingRebound = nil
                } else {
                    let retryNotBefore = now.addingTimeInterval(UsageScanPolicy.appServerReboundConfirmationDelay)
                    appServerRateLimitCache.pendingRebound = snapshot
                    appServerRateLimitCache.retryNotBefore = retryNotBefore
                    appServerRateLimitCache.isRefreshing = false
                    let failureCount = appServerRateLimitCache.consecutiveFailures
                    cacheLock.unlock()
                    diagnostics?.record(
                        event: "app_server_refresh",
                        correlationID: UUID().uuidString,
                        fields: [
                            "outcome": "staged_rebound",
                            "failure_kind": NSNull(),
                            "duration_ms": elapsedMilliseconds(since: startedAt),
                            "consecutive_failures": failureCount,
                            "candidate_primary_percent": diagnosticValue(snapshot.primaryPercent),
                            "candidate_secondary_percent": diagnosticValue(snapshot.secondaryPercent),
                            "candidate_primary_reset_at": diagnosticValue(snapshot.primaryResetsAt),
                            "candidate_secondary_reset_at": diagnosticValue(snapshot.secondaryResetsAt),
                            "next_retry_at": Int(retryNotBefore.timeIntervalSince1970)
                        ],
                        deduplicate: false
                    )
                    return false
                }
            } else {
                appServerRateLimitCache.pendingRebound = nil
            }
            appServerRateLimitCache.lastSuccess = snapshot
            appServerRateLimitCache.lastSuccessAt = now
            appServerRateLimitCache.consecutiveFailures = 0
            appServerRateLimitCache.retryNotBefore = nil
            appServerRateLimitCache.isRefreshing = false
            cacheLock.unlock()
            persistAppServerRateLimits(snapshot, savedAt: now)
            diagnostics?.record(
                event: "app_server_refresh",
                correlationID: UUID().uuidString,
                fields: [
                    "outcome": "success",
                    "failure_kind": NSNull(),
                    "duration_ms": elapsedMilliseconds(since: startedAt),
                    "consecutive_failures": 0,
                    "next_retry_at": NSNull()
                ],
                deduplicate: false
            )
            return true
        } catch {
            cacheLock.lock()
            appServerRateLimitCache.consecutiveFailures += 1
            let failureCount = appServerRateLimitCache.consecutiveFailures
            let delayIndex = min(failureCount - 1, UsageScanPolicy.appServerRetryDelays.count - 1)
            let retryDelay = UsageScanPolicy.appServerRetryDelays[delayIndex]
            let retryNotBefore = now.addingTimeInterval(retryDelay)
            appServerRateLimitCache.retryNotBefore = retryNotBefore
            appServerRateLimitCache.isRefreshing = false
            let lastSuccessAge = appServerRateLimitCache.lastSuccessAt.map {
                max(0, Int(now.timeIntervalSince($0).rounded()))
            }
            cacheLock.unlock()
            diagnostics?.record(
                event: "app_server_refresh",
                correlationID: UUID().uuidString,
                fields: [
                    "outcome": "failure",
                    "failure_kind": appServerFailureKind(error),
                    "duration_ms": elapsedMilliseconds(since: startedAt),
                    "consecutive_failures": failureCount,
                    "last_success_age_seconds": diagnosticValue(lastSuccessAge),
                    "next_retry_at": Int(retryNotBefore.timeIntervalSince1970)
                ],
                deduplicate: false
            )
            return false
        }
    }

    func appServerRefreshDelay(now: Date = Date()) -> TimeInterval {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let retryNotBefore = appServerRateLimitCache.retryNotBefore,
           retryNotBefore > now {
            return ceil(retryNotBefore.timeIntervalSince(now))
        }
        if let lastSuccessAt = appServerRateLimitCache.lastSuccessAt {
            let regularDelay = max(0, UsageScanPolicy.appServerFreshCacheTTL - now.timeIntervalSince(lastSuccessAt))
            guard let resetAt = earliestMainRateLimitReset(appServerRateLimitCache.lastSuccess) else {
                return ceil(regularDelay)
            }
            let resetDelay = TimeInterval(resetAt) - now.timeIntervalSince1970
            if resetDelay > 0 {
                return ceil(min(regularDelay, resetDelay))
            }
            return UsageScanPolicy.appServerReboundConfirmationDelay
        }
        return 0
    }

    private func errorSnapshot(_ error: Error, now: Date, snapshotDurationMs: Int? = nil) -> UsageSnapshot {
        UsageSnapshot(
            primaryPercent: nil,
            secondaryPercent: nil,
            primaryResetsAt: nil,
            secondaryResetsAt: nil,
            cumulativeUsage: loadCumulativeUsage(),
            recentUsage: loadRecentUsage(now: now),
            dailyUsage: .empty,
            usage1h: nil,
            usage24h: 0,
            usage7d: 0,
            usage30d: 0,
            periodUsageQuality: .empty,
            sparkQuotaWindows: [],
            tasks: [],
            isRunning: false,
            lastUpdated: now,
            rateLimitCapturedAt: nil,
            errorMessage: error.localizedDescription,
            monitorStats: MonitorPerformanceStats(
                lastSnapshotDurationMs: snapshotDurationMs,
                lastUsageDurationMs: nil,
                lastDeltaDurationMs: nil,
                lastRateLimitSource: "error",
                watchedPathCount: 0,
                jsonlContextScans: 0,
                monitorModelTokens: 0
            )
        )
    }

    private func cachedFastSnapshot(
        now: Date,
        fallbackUsage: PeriodUsage?,
        rateLimitSource: RateLimitSourcePreference,
        taskHistoryRange: TaskHistoryRange,
        includeContextUsage: Bool,
        contextTaskLimit: Int
    ) -> UsageSnapshot? {
        cacheLock.lock()
        let cache = fastCache
        cacheLock.unlock()

        guard let cache,
              cache.rateLimitSource == rateLimitSource,
              cache.taskHistoryRange == taskHistoryRange,
              now.timeIntervalSince(cache.createdAt) >= 0,
              now.timeIntervalSince(cache.createdAt) < Self.fastSnapshotCacheMaxAge else {
            return nil
        }

        let currentSignature = makeSignature(for: cache.rolloutPaths)
        guard currentSignature == cache.signature else {
            if let currentSignature,
               sessionDirectorySignatureChanged(from: cache.signature, to: currentSignature) {
                invalidateRecentSessionPathCaches()
            }
            return nil
        }

        cacheLock.lock()
        sessionFileCacheCounters.fastSnapshotHits += 1
        cacheLock.unlock()

        let snapshotStartedAt = Date()
        let usage = fallbackUsage ?? cache.periodUsage
        let cumulativeUsage = loadCumulativeUsage()
        let recentUsage = loadRecentUsage(now: now)
        let dailyUsage = loadDailyUsage(for: cache.usageThreads, now: now)
        let activeThreadIDs = ((try? loadActiveThreadIDs(now: now)) ?? [])
            .union(activeSessionThreadIDs(from: cache.threads, now: now))
            .union(loadActiveSubagentParentThreads(now: now).map(\.id))
        let deltaStartedAt = Date()
        let deltas = loadTokenDeltas(for: cache.threads, now: now)
        let aggregateDeltas = loadAggregateTokenDeltas(for: cache.threads, now: now)
        let deltaDurationMs = elapsedMilliseconds(since: deltaStartedAt)
        let taskResult = buildTasks(
            from: cache.threads,
            activeThreadIDs: activeThreadIDs,
            deltas: deltas,
            todayTotalTokens: dailyUsage.usageTodayTokens,
            now: now,
            includeContextUsage: includeContextUsage,
            contextTaskLimit: contextTaskLimit
        )
        let snapshotDurationMs = elapsedMilliseconds(since: snapshotStartedAt)
        return UsageSnapshot(
            primaryPercent: cache.rateLimits.primaryDisplayPercent(now: now),
            secondaryPercent: cache.rateLimits.secondaryDisplayPercent(now: now),
            primaryResetsAt: cache.rateLimits.primaryResetsAt,
            secondaryResetsAt: cache.rateLimits.secondaryResetsAt,
            primaryWindowMinutes: cache.rateLimits.primaryWindowMinutes,
            secondaryWindowMinutes: cache.rateLimits.secondaryWindowMinutes,
            cumulativeUsage: cumulativeUsage,
            recentUsage: recentUsage,
            dailyUsage: dailyUsage,
            usage1h: aggregateDeltas.delta1hTokens,
            usage24h: usage.day,
            usage7d: usage.week,
            usage30d: usage.month,
            periodUsageQuality: cache.periodUsageQuality,
            sparkQuotaWindows: displaySparkQuotaWindows(cache.rateLimits, now: now),
            tasks: taskResult.tasks,
            isRunning: taskResult.tasks.contains { $0.status == .running },
            lastUpdated: now,
            rateLimitCapturedAt: cache.rateLimits.capturedAt,
            errorMessage: nil,
            monitorStats: MonitorPerformanceStats(
                lastSnapshotDurationMs: snapshotDurationMs,
                lastUsageDurationMs: nil,
                lastDeltaDurationMs: deltaDurationMs,
                lastRateLimitSource: cache.rateLimitSourceName,
                watchedPathCount: 0,
                jsonlContextScans: taskResult.contextScans,
                monitorModelTokens: 0
            ),
            resetCreditCount: cache.rateLimits.resetCredits?.availableCount(now: now),
            resetCreditExpiryNotice: cache.rateLimits.resetCredits?.expiryNotice(now: now)
        )
    }

    private func updateCostUsageCandidates(
        from paths: [String],
        inventoryTruncated: Bool
    ) {
        var seen: Set<String> = []
        let candidates = paths.compactMap { path -> CostUsageSessionCandidate? in
            guard !path.isEmpty,
                  let sessionID = sessionID(from: path)?.lowercased(),
                  seen.insert(sessionID).inserted else {
                return nil
            }
            return CostUsageSessionCandidate(sessionID: sessionID, path: path)
        }
        costUsageEstimator.updateCandidates(candidates, inventoryTruncated: inventoryTruncated)
    }

    private func cacheFastSnapshot(
        threads: [ThreadRecord],
        usageThreads: [ThreadRecord],
        activeThreadIDs: Set<String>,
        rateLimits: RateLimitSnapshot,
        periodUsage: PeriodUsage,
        periodUsageQuality: PeriodUsageQuality,
        dailyUsage: DailyUsage,
        signaturePaths: [String],
        rateLimitSourceName: String,
        rateLimitSource: RateLimitSourcePreference,
        taskHistoryRange: TaskHistoryRange,
        now: Date
    ) {
        let knownRolloutPaths = Set(signaturePaths + threads.map(\.rolloutPath)).filter { !$0.isEmpty }
        let rolloutDirectories = knownRolloutPaths.map {
            URL(fileURLWithPath: $0).deletingLastPathComponent().path
        }
        let rolloutPaths = Array(
            knownRolloutPaths
                .union(rolloutDirectories)
                .union([
                    codexDirectory.appendingPathComponent("sessions", isDirectory: true).path,
                    codexDirectory.appendingPathComponent("archived_sessions", isDirectory: true).path
                ])
        ).sorted()
        guard let signature = makeSignature(for: rolloutPaths) else {
            return
        }

        cacheLock.lock()
        fastCache = FastSnapshotCache(
            createdAt: now,
            signature: signature,
            rolloutPaths: rolloutPaths,
            threads: threads,
            usageThreads: usageThreads,
            activeThreadIDs: activeThreadIDs,
            rateLimits: rateLimits,
            periodUsage: periodUsage,
            periodUsageQuality: periodUsageQuality,
            dailyUsage: dailyUsage,
            rateLimitSourceName: rateLimitSourceName,
            rateLimitSource: rateLimitSource,
            taskHistoryRange: taskHistoryRange
        )
        cacheLock.unlock()
    }

    private func trimSessionFileCaches(retaining paths: Set<String>) {
        let canonicalPaths = Set(paths.map { fileSignature($0).path })
        cacheLock.lock()
        sessionTokenTotalCache = sessionTokenTotalCache.filter { canonicalPaths.contains($0.key) }
        sessionContextUsageCache = sessionContextUsageCache.filter { canonicalPaths.contains($0.key) }
        sessionPrefixFactsCache = sessionPrefixFactsCache.filter { canonicalPaths.contains($0.key) }
        sessionRateLimitCache = sessionRateLimitCache.filter { canonicalPaths.contains($0.key) }
        sessionActivityCache = sessionActivityCache.filter { canonicalPaths.contains($0.key) }
        cacheLock.unlock()
    }

    private func invalidateRecentSessionPathCaches() {
        cacheLock.lock()
        recentPathsCache = nil
        recentTaskPathsCache = nil
        cacheLock.unlock()
    }

    private func sessionDirectorySignatureChanged(
        from previous: StoreSignature,
        to current: StoreSignature
    ) -> Bool {
        let previousFiles = Dictionary(uniqueKeysWithValues: previous.files.map { ($0.path, $0) })
        return current.files.contains { file in
            let isSessionDirectory = !file.path.hasSuffix(".jsonl")
                && (
                    file.path.hasSuffix("/sessions")
                        || file.path.contains("/sessions/")
                        || file.path.hasSuffix("/archived_sessions")
                        || file.path.contains("/archived_sessions/")
                )
            return isSessionDirectory && previousFiles[file.path] != file
        }
    }

    private func loadRecentThreads(range: TaskHistoryRange = .threeDays, now: Date = Date()) throws -> [ThreadRecord] {
        let since = Int(now.timeIntervalSince1970) - range.seconds
        let createdAtExpression = threadTableColumns().contains("created_at")
            ? "coalesce(created_at, 0)"
            : "0"
        let query = """
        select
          id,
          coalesce(title, '未命名任务') as title,
          coalesce(tokens_used, 0) as tokens_used,
          model,
          reasoning_effort,
          coalesce(rollout_path, '') as rollout_path,
          coalesce(updated_at, 0) as updated_at,
          \(createdAtExpression) as created_at
        from threads
        where archived = 0
          and updated_at >= \(since)
        order by updated_at desc
        limit \(range.queryLimit);
        """
        return withSessionIndexNames(
            try Shell.sqliteJSON(database: stateDatabase, query: query, as: [ThreadRecord].self, readOnly: true)
        )
        .filter { !isSubagentThread($0) }
    }

    private func loadUsageDeltaThreads(range: TaskHistoryRange = .month, now: Date = Date()) throws -> [ThreadRecord] {
        let since = Int(now.timeIntervalSince1970) - range.seconds
        let columns = threadTableColumns()
        let createdAtExpression = columns.contains("created_at") ? "coalesce(created_at, 0)" : "0"
        let recencyCandidates = ["recency_at", "updated_at", "created_at"]
            .filter { columns.contains($0) }
            .map { "nullif(\($0), 0)" }
        let recencyExpression = recencyCandidates.isEmpty
            ? "0"
            : "coalesce(\(recencyCandidates.joined(separator: ", ")), 0)"
        let query = """
        select
          id,
          coalesce(title, '未命名任务') as title,
          coalesce(tokens_used, 0) as tokens_used,
          model,
          reasoning_effort,
          coalesce(rollout_path, '') as rollout_path,
          coalesce(updated_at, 0) as updated_at,
          \(createdAtExpression) as created_at
        from threads
        where \(recencyExpression) >= \(since)
        order by \(recencyExpression) desc;
        """
        return withSessionIndexNames(
            try Shell.sqliteJSON(database: stateDatabase, query: query, as: [ThreadRecord].self, readOnly: true)
        )
        .filter { !isSubagentThread($0) }
    }

    func loadCumulativeUsage() -> CumulativeUsage {
        let query = """
        select
          coalesce(sum(case when archived = 0 then coalesce(tokens_used, 0) else 0 end), 0) as active_tokens,
          coalesce(sum(case when archived = 1 then coalesce(tokens_used, 0) else 0 end), 0) as archived_tokens,
          coalesce(sum(coalesce(tokens_used, 0)), 0) as all_tokens,
          coalesce(sum(case when archived = 0 then 1 else 0 end), 0) as active_sessions,
          coalesce(sum(case when archived = 1 then 1 else 0 end), 0) as archived_sessions,
          count(*) as all_sessions
        from threads;
        """
        guard let record = try? Shell.sqliteJSON(
            database: stateDatabase,
            query: query,
            as: [CumulativeUsageRecord].self,
            readOnly: true
        ).first else {
            return .empty
        }

        return CumulativeUsage(
            activeTokens: record.activeTokens,
            archivedTokens: record.archivedTokens,
            allTokens: record.allTokens,
            activeSessions: record.activeSessions,
            archivedSessions: record.archivedSessions,
            allSessions: record.allSessions
        )
    }

    func loadRecentUsage(now: Date = Date(), windowDays: Int = 20) -> RecentUsage {
        let safeWindowDays = max(1, windowDays)
        let start = Int(now.timeIntervalSince1970) - (safeWindowDays * 24 * 60 * 60)
        let recencyExpression = recentUsageRecencyExpression()
        let query = """
        select
          coalesce(sum(case when archived = 0 then coalesce(tokens_used, 0) else 0 end), 0) as usage_20d_active_tokens,
          coalesce(sum(case when archived = 1 then coalesce(tokens_used, 0) else 0 end), 0) as usage_20d_archived_tokens,
          coalesce(sum(coalesce(tokens_used, 0)), 0) as usage_20d_all_tokens,
          coalesce(sum(case when archived = 0 then 1 else 0 end), 0) as usage_20d_active_sessions,
          coalesce(sum(case when archived = 1 then 1 else 0 end), 0) as usage_20d_archived_sessions,
          count(*) as usage_20d_all_sessions
        from threads
        where \(recencyExpression) >= \(start);
        """
        guard let record = try? Shell.sqliteJSON(
            database: stateDatabase,
            query: query,
            as: [RecentUsageRecord].self,
            readOnly: true
        ).first else {
            return .empty
        }

        return RecentUsage(
            usage20dActiveTokens: record.usage20dActiveTokens,
            usage20dArchivedTokens: record.usage20dArchivedTokens,
            usage20dAllTokens: record.usage20dAllTokens,
            usage20dActiveSessions: record.usage20dActiveSessions,
            usage20dArchivedSessions: record.usage20dArchivedSessions,
            usage20dAllSessions: record.usage20dAllSessions,
            windowDays: safeWindowDays
        )
    }

    private func loadStateWindowUsageTotals(now: Date = Date()) -> PeriodUsage? {
        let dayStart = Int(now.timeIntervalSince1970) - (24 * 60 * 60)
        let weekStart = Int(now.timeIntervalSince1970) - (7 * 24 * 60 * 60)
        let monthStart = Int(now.timeIntervalSince1970) - (30 * 24 * 60 * 60)
        let recencyExpression = recentUsageRecencyExpression()
        let query = """
        select
          coalesce(sum(case when \(recencyExpression) >= \(dayStart) then coalesce(tokens_used, 0) else 0 end), 0) as day,
          coalesce(sum(case when \(recencyExpression) >= \(weekStart) then coalesce(tokens_used, 0) else 0 end), 0) as week,
          coalesce(sum(case when \(recencyExpression) >= \(monthStart) then coalesce(tokens_used, 0) else 0 end), 0) as month
        from threads;
        """
        guard let record = try? Shell.sqliteJSON(
            database: stateDatabase,
            query: query,
            as: [PeriodUsageRecord].self,
            readOnly: true
        ).first else {
            return nil
        }

        return PeriodUsage(day: record.day, week: record.week, month: record.month)
    }

    private func loadRollingPeriodUsage(for threads: [ThreadRecord], now: Date) -> PeriodUsageResult {
        let nowMs = Int64((now.timeIntervalSince1970 * 1_000).rounded())
        let dayCutoff = nowMs - Int64(24 * 60 * 60 * 1_000)
        let weekCutoff = nowMs - Int64(7 * 24 * 60 * 60 * 1_000)
        let monthCutoff = nowMs - Int64(30 * 24 * 60 * 60 * 1_000)
        let rows = loadRollingDeltaRows(
            for: threads,
            tenMinuteCutoff: nil,
            oneHourCutoff: nil,
            dayCutoff: dayCutoff,
            weekCutoff: weekCutoff,
            monthCutoff: monthCutoff,
            todayCutoff: nil
        )

        var usage24h = 0
        var usage7d = 0
        var usage30d = 0
        var missing24h = 0
        var missing7d = 0
        var missing30d = 0

        for row in rows {
            if let delta = rollingDelta(current: row.tokensUsed, baseline: row.baseline24h, createdAtMs: row.createdAtMs, cutoffMs: dayCutoff) {
                usage24h += delta
            } else {
                missing24h += 1
            }
            if let delta = rollingDelta(current: row.tokensUsed, baseline: row.baseline7d, createdAtMs: row.createdAtMs, cutoffMs: weekCutoff) {
                usage7d += delta
            } else {
                missing7d += 1
            }
            if let delta = rollingDelta(current: row.tokensUsed, baseline: row.baseline30d, createdAtMs: row.createdAtMs, cutoffMs: monthCutoff) {
                usage30d += delta
            } else {
                missing30d += 1
            }
        }

        return PeriodUsageResult(
            usage: PeriodUsage(day: usage24h, week: usage7d, month: usage30d),
            quality: PeriodUsageQuality(
                usage24hPartial: missing24h > 0,
                usage7dPartial: missing7d > 0,
                usage30dPartial: missing30d > 0,
                missing24hBaselines: missing24h,
                missing7dBaselines: missing7d,
                missing30dBaselines: missing30d
            )
        )
    }

    private func loadDailyUsage(for threads: [ThreadRecord], now: Date) -> DailyUsage {
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: now)
        let dayStartMs = Int64((dayStart.timeIntervalSince1970 * 1_000).rounded())
        let rows = loadRollingDeltaRows(
            for: threads,
            tenMinuteCutoff: nil,
            oneHourCutoff: nil,
            dayCutoff: nil,
            weekCutoff: nil,
            monthCutoff: nil,
            todayCutoff: dayStartMs
        )

        var todayTokens = 0
        var missing = 0
        for row in rows {
            if let delta = rollingDelta(current: row.tokensUsed, baseline: row.baselineToday, createdAtMs: row.createdAtMs, cutoffMs: dayStartMs) {
                todayTokens += delta
            } else {
                missing += 1
            }
        }

        return DailyUsage(
            usageTodayTokens: todayTokens,
            dayStartedAt: dayStart,
            timeZoneIdentifier: TimeZone.current.identifier,
            isPartial: missing > 0,
            missingBaselineSessions: missing
        )
    }

    private func loadRollingDeltaRows(
        for threads: [ThreadRecord],
        tenMinuteCutoff: Int64?,
        oneHourCutoff: Int64?,
        dayCutoff: Int64?,
        weekCutoff: Int64?,
        monthCutoff: Int64?,
        todayCutoff: Int64?
    ) -> [RollingDeltaRecord] {
        let currentRows = threads
            .filter { !$0.id.isEmpty && $0.tokensUsed >= 0 }
            .map { thread -> String in
                let id = sqliteLiteral(thread.id.lowercased())
                let tokens = max(0, thread.tokensUsed)
                let createdAtMs = Int64(max(0, thread.createdAt)) * 1_000
                return "(\(id), \(tokens), \(createdAtMs))"
            }

        guard !currentRows.isEmpty else {
            return []
        }

        ensureDeltaCacheSchema()

        let tenMinuteSelect = baselineSelectSQL(cutoff: tenMinuteCutoff, alias: "baseline_10m")
        let oneHourSelect = baselineSelectSQL(cutoff: oneHourCutoff, alias: "baseline_1h")
        let daySelect = baselineSelectSQL(cutoff: dayCutoff, alias: "baseline_24h")
        let weekSelect = baselineSelectSQL(cutoff: weekCutoff, alias: "baseline_7d")
        let monthSelect = baselineSelectSQL(cutoff: monthCutoff, alias: "baseline_30d")
        let todaySelect = baselineSelectSQL(cutoff: todayCutoff, alias: "baseline_today")
        let query = """
        WITH current_rows(thread_id, tokens_used, created_at_ms) AS (
          VALUES \(currentRows.joined(separator: ",\n                 "))
        )
        SELECT
          current_rows.thread_id,
          current_rows.tokens_used,
          current_rows.created_at_ms,
          \(tenMinuteSelect),
          \(oneHourSelect),
          \(daySelect),
          \(weekSelect),
          \(monthSelect),
          \(todaySelect)
        FROM current_rows;
        """

        return (try? Shell.sqliteJSON(
            database: deltaDatabase,
            query: query,
            as: [RollingDeltaRecord].self,
            readOnly: true
        )) ?? []
    }

    private func baselineSelectSQL(cutoff: Int64?, alias: String) -> String {
        guard let cutoff else {
            return "NULL AS \(alias)"
        }
        return """
        (
            SELECT baseline.tokens_used
            FROM (
              SELECT h.tokens_used, h.observed_at_ms
              FROM token_snapshot_history AS h
              WHERE h.thread_id = current_rows.thread_id
                AND h.observed_at_ms <= \(cutoff)
              UNION ALL
              SELECT s.tokens_used, s.observed_at_ms
              FROM token_snapshots AS s
              WHERE s.thread_id = current_rows.thread_id
                AND s.observed_at_ms <= \(cutoff)
            ) AS baseline
            ORDER BY baseline.observed_at_ms DESC
            LIMIT 1
          ) AS \(alias)
        """
    }

    private func rollingDelta(
        current: Int,
        baseline: Int?,
        allowCreatedFallback: Bool = true,
        createdAtMs: Int64,
        cutoffMs: Int64
    ) -> Int? {
        if let baseline {
            return max(0, current - baseline)
        }
        if allowCreatedFallback, createdAtMs > 0 && createdAtMs >= cutoffMs {
            return max(0, current)
        }
        return nil
    }

    @discardableResult
    private func ensureDeltaCacheReady() -> Bool {
        deltaCacheSetupLock.lock()
        defer { deltaCacheSetupLock.unlock() }

        if deltaCacheReady {
            return true
        }

        ensureDeltaDatabaseDirectory()
        do {
            try Shell.sqliteExec(database: deltaDatabase, query: deltaSchemaSQL())

            if deltaMetadataValue(for: "legacy_import_completed") != 1 {
                try Shell.sqliteExec(database: deltaDatabase, query: legacyDeltaMigrationSQL())
            }

            if deltaMetadataValue(for: "history_compaction_completed") != 1 {
                try Shell.sqliteExec(database: deltaDatabase, query: deltaHistoryCompactionSQL())
            }

            let currentSchemaVersion = deltaMetadataValue(for: "schema_version") ?? 0
            var maintenanceStatements = [
                """
                CREATE INDEX IF NOT EXISTS idx_token_snapshot_history_observed_at
                  ON token_snapshot_history(observed_at_ms);
                """
            ]
            if currentSchemaVersion < 2 {
                maintenanceStatements.append("ANALYZE token_snapshot_history;")
                maintenanceStatements.append(
                    """
                    INSERT INTO delta_cache_metadata(key, value)
                    VALUES('schema_version', 2)
                    ON CONFLICT(key) DO UPDATE SET value = excluded.value;
                    """
                )
            }
            try Shell.sqliteExec(
                database: deltaDatabase,
                query: maintenanceStatements.joined(separator: "\n")
            )
            deltaCacheReady = true
            return true
        } catch {
            return false
        }
    }

    private func ensureDeltaCacheSchema() {
        _ = ensureDeltaCacheReady()
    }

    private func deltaMetadataValue(for key: String) -> Int64? {
        let records = (try? Shell.sqliteJSON(
            database: deltaDatabase,
            query: "SELECT value FROM delta_cache_metadata WHERE key = \(sqliteLiteral(key)) LIMIT 1;",
            as: [DeltaCacheMetadataRecord].self,
            readOnly: true
        )) ?? []
        return records.first?.value
    }

    private func recentUsageRecencyExpression() -> String {
        let columns = threadTableColumns()
        let candidates = ["recency_at", "updated_at", "created_at"]
            .filter { columns.contains($0) }
            .map { "nullif(\($0), 0)" }
        guard !candidates.isEmpty else {
            return "0"
        }
        return "coalesce(\(candidates.joined(separator: ", ")), 0)"
    }

    private func threadTableColumns() -> Set<String> {
        let records = (try? Shell.sqliteJSON(
            database: stateDatabase,
            query: "pragma table_info(threads);",
            as: [SQLiteNameRecord].self,
            readOnly: true
        )) ?? []
        return Set(records.map(\.name))
    }

    private func loadRecentSessionThreads(
        range: TaskHistoryRange,
        now: Date,
        includeSubagents: Bool = false,
        knownTokens: [String: Int] = [:]
    ) -> [ThreadRecord] {
        let names = loadSessionIndexThreadNames()
        return loadRecentSessionCandidates(
            range: range,
            now: now,
            knownTokens: knownTokens
        ).compactMap { candidate in
            let meta = sessionMeta(from: candidate.path)
            guard includeSubagents || meta?.isSubagent != true else {
                return nil
            }

            let runtime = sessionRuntimeInfo(from: candidate.path)
            let title = names[candidate.sessionID] ?? sessionTitle(from: candidate.path) ?? "未命名任务"
            let tokensUsed = tokenTotalForFastSnapshot(
                path: candidate.path,
                databaseTokens: candidate.databaseTokens
            )
            return ThreadRecord(
                id: candidate.sessionID,
                title: title,
                tokensUsed: tokensUsed,
                model: runtime?.model,
                reasoningEffort: runtime?.reasoningEffort,
                rolloutPath: candidate.path,
                updatedAt: candidate.updatedAt,
                createdAt: candidate.databaseTokens > 0 ? 0 : candidate.updatedAt
            )
        }
    }

    private func loadSessionUsageThreads(
        range: TaskHistoryRange,
        now: Date,
        knownTokens: [String: Int] = [:],
        includeArchivedSessions: Bool = false
    ) -> [ThreadRecord] {
        loadRecentSessionCandidates(
            range: range,
            now: now,
            knownTokens: knownTokens,
            includeArchivedSessions: includeArchivedSessions
        ).compactMap { candidate in
            let tokensUsed = tokenTotalForPeriodUsage(
                path: candidate.path,
                databaseTokens: candidate.databaseTokens,
                modifiedAt: candidate.modifiedAt,
                now: now
            )
            guard tokensUsed > 0 else {
                return nil
            }

            return ThreadRecord(
                id: candidate.sessionID,
                title: "",
                tokensUsed: tokensUsed,
                model: nil,
                reasoningEffort: nil,
                rolloutPath: candidate.path,
                updatedAt: candidate.updatedAt,
                createdAt: candidate.databaseTokens > 0 ? 0 : candidate.updatedAt
            )
        }
    }

    private func loadRecentSessionCandidates(
        range: TaskHistoryRange,
        now: Date,
        knownTokens: [String: Int],
        includeArchivedSessions: Bool = false
    ) -> [RecentSessionCandidate] {
        let since = Int(now.timeIntervalSince1970) - range.seconds
        let pathLimit = max(range.queryLimit * 3, 80)
        let paths = includeArchivedSessions
            ? recentSessionPaths(limit: pathLimit)
            : recentTaskSessionPaths(limit: pathLimit)
        let pathSessionIDs = paths.compactMap { sessionID(from: $0)?.lowercased() }
        var resolvedKnownTokens = knownTokens
        let missingTokenIDs = pathSessionIDs.filter { resolvedKnownTokens[$0] == nil }
        if !missingTokenIDs.isEmpty {
            resolvedKnownTokens.merge(loadThreadTokenMap(for: missingTokenIDs), uniquingKeysWith: max)
        }

        return paths.compactMap { path in
            guard let sessionID = sessionID(from: path),
                  let attributes = try? FileManager.default.attributesOfItem(atPath: path),
                  let modifiedAt = attributes[.modificationDate] as? Date else {
                return nil
            }

            let updatedAt = Int(modifiedAt.timeIntervalSince1970)
            guard updatedAt >= since else {
                return nil
            }

            return RecentSessionCandidate(
                path: path,
                sessionID: sessionID,
                modifiedAt: modifiedAt,
                updatedAt: updatedAt,
                databaseTokens: resolvedKnownTokens[sessionID.lowercased()] ?? 0
            )
        }
    }

    private func activeSessionThreadIDs(from threads: [ThreadRecord], now: Date) -> Set<String> {
        return Set(threads.compactMap { thread in
            sessionLooksActive(path: thread.rolloutPath, fallbackUpdatedAt: thread.updatedAt, now: now) ? thread.id : nil
        })
    }

    private func isSubagentThread(_ thread: ThreadRecord) -> Bool {
        guard !thread.rolloutPath.isEmpty,
              let meta = sessionMeta(from: thread.rolloutPath) else {
            return false
        }
        return meta.isSubagent
    }

    private func loadActiveSubagentParentThreads(now: Date) -> [ThreadRecord] {
        let paths = recentTaskSessionPaths(limit: 48)
        let names = loadSessionIndexThreadNames()

        let parents = paths.compactMap { path -> ThreadRecord? in
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
                  let modifiedAt = attributes[.modificationDate] as? Date,
                  let meta = sessionMeta(from: path),
                  meta.isSubagent,
                  let parentThreadID = meta.parentThreadID,
                  !parentThreadID.isEmpty,
                  sessionLooksActive(path: path, fallbackUpdatedAt: Int(modifiedAt.timeIntervalSince1970), now: now) else {
                return nil
            }
            let parentPath = sessionPath(for: parentThreadID)
            let runtime = parentPath.flatMap(sessionRuntimeInfo(from:))
            let title = parentPath.flatMap { names[parentThreadID] ?? sessionTitle(from: $0) }
                ?? names[parentThreadID]
                ?? "正在运行的 Codex 任务"
            let parentUpdatedAt = parentPath.flatMap { path -> Int? in
                guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
                      let modifiedAt = attributes[.modificationDate] as? Date else {
                    return nil
                }
                return Int(modifiedAt.timeIntervalSince1970)
            } ?? 0
            let updatedAt = max(parentUpdatedAt, Int(modifiedAt.timeIntervalSince1970))
            return ThreadRecord(
                id: parentThreadID,
                title: title,
                tokensUsed: parentPath.flatMap(sessionTokenTotal(from:)) ?? 0,
                model: runtime?.model,
                reasoningEffort: runtime?.reasoningEffort,
                rolloutPath: parentPath ?? "",
                updatedAt: updatedAt,
                createdAt: 0
            )
        }

        return mergeThreadRecords(parents)
    }

    private func loadSubagentUsage(range: TaskHistoryRange, now: Date) -> [String: (count: Int, tokens: Int)] {
        let since = Int(now.timeIntervalSince1970) - range.seconds
        let paths = recentTaskSessionPaths(limit: max(range.queryLimit * 3, 80))
        let sessionIDsByPath = Dictionary(
            uniqueKeysWithValues: paths.compactMap { path -> (String, String)? in
                guard let id = sessionID(from: path)?.lowercased() else {
                    return nil
                }
                return (path, id)
            }
        )
        let knownTokens = loadThreadTokenMap(for: Array(sessionIDsByPath.values))
        var usage: [String: (count: Int, tokens: Int)] = [:]

        for path in paths {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
                  let modifiedAt = attributes[.modificationDate] as? Date,
                  let sessionID = sessionIDsByPath[path],
                  Int(modifiedAt.timeIntervalSince1970) >= since,
                  let meta = sessionMeta(from: path),
                  meta.isSubagent,
                  let parentThreadID = meta.parentThreadID,
                  !parentThreadID.isEmpty else {
                continue
            }

            let key = parentThreadID.lowercased()
            let current = usage[key] ?? (count: 0, tokens: 0)
            let isActive = sessionLooksActive(
                path: path,
                fallbackUpdatedAt: Int(modifiedAt.timeIntervalSince1970),
                now: now
            )
            let knownTokenTotal = knownTokens[sessionID] ?? 0
            let tokenTotal = tokenTotalForFastSnapshot(path: path, databaseTokens: knownTokenTotal, allowInactiveScan: false)
            usage[key] = (
                count: current.count + (isActive ? 1 : 0),
                tokens: current.tokens + tokenTotal
            )
        }

        return usage
    }

    private func withSubagentUsage(
        _ threads: [ThreadRecord],
        usage: [String: (count: Int, tokens: Int)]
    ) -> [ThreadRecord] {
        guard !usage.isEmpty else {
            return threads
        }

        return threads.map { thread in
            guard let summary = usage[thread.id.lowercased()] else {
                return thread
            }
            let count = summary.count

            return ThreadRecord(
                id: thread.id,
                title: thread.title,
                tokensUsed: thread.tokensUsed,
                model: thread.model,
                reasoningEffort: thread.reasoningEffort,
                rolloutPath: thread.rolloutPath,
                updatedAt: thread.updatedAt,
                createdAt: thread.createdAt,
                activeSubagentCount: count
            )
        }
    }

    private func parentTokenCount(for thread: ThreadRecord) -> Int {
        guard !thread.rolloutPath.isEmpty else {
            return thread.tokensUsed
        }
        return tokenTotalForFastSnapshot(path: thread.rolloutPath, databaseTokens: thread.tokensUsed)
    }

    private func tokenTotalForFastSnapshot(
        path: String,
        databaseTokens: Int,
        allowInactiveScan: Bool = true
    ) -> Int {
        guard !path.isEmpty else {
            return databaseTokens
        }

        let signature = fileSignature(path)
        guard signature.exists else {
            return databaseTokens
        }

        guard allowInactiveScan || databaseTokens <= 0 else {
            return databaseTokens
        }

        if databaseTokens > 0, signature.size > UsageScanPolicy.fastSnapshotTokenScanLimit {
            return databaseTokens
        }

        return max(databaseTokens, sessionTokenTotal(from: path) ?? 0)
    }

    private func tokenTotalForPeriodUsage(
        path: String,
        databaseTokens: Int,
        modifiedAt: Date,
        now: Date
    ) -> Int {
        guard !path.isEmpty else {
            return databaseTokens
        }

        let signature = fileSignature(path)
        guard signature.exists else {
            return databaseTokens
        }

        if databaseTokens > 0, signature.size > UsageScanPolicy.largeSessionTokenScanLimit {
            return databaseTokens
        }

        let changedRecently = now.timeIntervalSince(modifiedAt) < UsageScanPolicy.recentSessionScanWindow
        if changedRecently {
            return max(databaseTokens, sessionTokenTotal(from: path) ?? 0)
        }

        if databaseTokens > 0 {
            return databaseTokens
        }

        guard signature.size <= UsageScanPolicy.staleSessionTokenScanLimit else {
            return 0
        }

        return sessionTokenTotal(from: path) ?? 0
    }

    private func tokenMap(from threads: [ThreadRecord]) -> [String: Int] {
        Dictionary(
            threads.map { ($0.id.lowercased(), $0.tokensUsed) },
            uniquingKeysWith: max
        )
    }

    @discardableResult
    private func recordDeltaSnapshot(for threads: [ThreadRecord], now: Date) -> Bool {
        let rows = threads
            .filter { !$0.id.isEmpty && $0.tokensUsed >= 0 }
            .map { thread -> String in
                let id = sqliteLiteral(thread.id.lowercased())
                let tokens = max(0, thread.tokensUsed)
                let updatedAtMs = max(0, thread.updatedAt) * 1_000
                return "(\(id), \(tokens), \(updatedAtMs), __OBSERVED_AT_MS__)"
            }

        guard !rows.isEmpty else {
            return false
        }

        let cleanupRows = threads
            .filter { !$0.id.isEmpty && $0.tokensUsed >= 0 }
            .map { thread in
                "(\(sqliteLiteral(thread.id.lowercased())), \(max(0, thread.tokensUsed)))"
            }
            .joined(separator: ",\n")
        let observedAtMs = Int64((now.timeIntervalSince1970 * 1_000).rounded())
        let values = rows
            .joined(separator: ",\n")
            .replacingOccurrences(of: "__OBSERVED_AT_MS__", with: String(observedAtMs))
        let pruneIntervalMs = Int64(24 * 60 * 60 * 1_000)
        let retentionCutoffMs = observedAtMs - Int64(
            UsageScanPolicy.deltaHistoryRetentionDays * 24 * 60 * 60 * 1_000
        )
        let query = """
        BEGIN IMMEDIATE;
        WITH current_rows(thread_id, tokens_used) AS (
          VALUES \(cleanupRows)
        )
        DELETE FROM token_snapshots
        WHERE EXISTS (
          SELECT 1
          FROM current_rows
          WHERE current_rows.thread_id = lower(token_snapshots.thread_id)
            AND token_snapshots.tokens_used > current_rows.tokens_used
        );

        WITH current_rows(thread_id, tokens_used) AS (
          VALUES \(cleanupRows)
        )
        DELETE FROM token_snapshot_history
        WHERE EXISTS (
          SELECT 1
          FROM current_rows
          WHERE current_rows.thread_id = lower(token_snapshot_history.thread_id)
            AND token_snapshot_history.tokens_used > current_rows.tokens_used
        );

        WITH current_rows(thread_id, tokens_used, updated_at_ms, observed_at_ms) AS (
          VALUES \(values)
        )
        INSERT INTO token_snapshot_history(thread_id, tokens_used, updated_at_ms, observed_at_ms)
        SELECT thread_id, tokens_used, updated_at_ms, observed_at_ms
        FROM current_rows
        WHERE COALESCE(
          (
            SELECT token_snapshots.tokens_used
            FROM token_snapshots
            WHERE lower(token_snapshots.thread_id) = current_rows.thread_id
            LIMIT 1
          ),
          (
            SELECT token_snapshot_history.tokens_used
            FROM token_snapshot_history
            WHERE lower(token_snapshot_history.thread_id) = current_rows.thread_id
            ORDER BY token_snapshot_history.observed_at_ms DESC
            LIMIT 1
          ),
          -1
        ) != current_rows.tokens_used
        ON CONFLICT(thread_id, observed_at_ms) DO UPDATE SET
          tokens_used = excluded.tokens_used,
          updated_at_ms = excluded.updated_at_ms;

        INSERT INTO token_snapshots(thread_id, tokens_used, updated_at_ms, observed_at_ms)
        VALUES \(values)
        ON CONFLICT(thread_id) DO UPDATE SET
          tokens_used = excluded.tokens_used,
          updated_at_ms = excluded.updated_at_ms,
          observed_at_ms = excluded.observed_at_ms;

        DELETE FROM token_snapshot_history
        WHERE observed_at_ms < \(retentionCutoffMs)
          AND COALESCE(
            (SELECT value FROM delta_cache_metadata WHERE key = 'last_history_prune_ms'),
            0
          ) <= \(observedAtMs - pruneIntervalMs);

        INSERT INTO delta_cache_metadata(key, value)
        SELECT 'last_history_prune_ms', \(observedAtMs)
        WHERE COALESCE(
          (SELECT value FROM delta_cache_metadata WHERE key = 'last_history_prune_ms'),
          0
        ) <= \(observedAtMs - pruneIntervalMs)
        ON CONFLICT(key) DO UPDATE SET value = excluded.value;
        COMMIT;
        """

        guard ensureDeltaCacheReady() else {
            return false
        }

        deltaWriteLock.lock()
        defer { deltaWriteLock.unlock() }
        do {
            try Shell.sqliteExec(database: deltaDatabase, query: query)
            return true
        } catch {
            return false
        }
    }

    private func ensureDeltaDatabaseDirectory() {
        let directory = URL(fileURLWithPath: deltaDatabase).deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func deltaSchemaSQL() -> String {
        """
        CREATE TABLE IF NOT EXISTS token_snapshots (
          thread_id TEXT PRIMARY KEY,
          tokens_used INTEGER NOT NULL,
          updated_at_ms INTEGER NOT NULL,
          observed_at_ms INTEGER NOT NULL
        );
        CREATE TABLE IF NOT EXISTS token_snapshot_history (
          thread_id TEXT NOT NULL,
          tokens_used INTEGER NOT NULL,
          updated_at_ms INTEGER NOT NULL,
          observed_at_ms INTEGER NOT NULL,
          PRIMARY KEY(thread_id, observed_at_ms)
        );
        CREATE TABLE IF NOT EXISTS delta_cache_metadata (
          key TEXT PRIMARY KEY,
          value INTEGER NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_token_snapshot_history_lookup
          ON token_snapshot_history(thread_id, observed_at_ms DESC);
        """
    }

    private func legacyDeltaMigrationSQL() -> String {
        let legacyExists = legacyDeltaDatabase.map(FileManager.default.fileExists(atPath:)) ?? false
        let hasSnapshots = legacyDeltaDatabase.map {
            legacyExists && legacyDeltaHasTable("token_snapshots", database: $0)
        } ?? false
        let hasHistory = legacyDeltaDatabase.map {
            legacyExists && legacyDeltaHasTable("token_snapshot_history", database: $0)
        } ?? false
        let shouldAttach = hasSnapshots || hasHistory

        var statements: [String] = []
        if shouldAttach, let legacyDeltaDatabase {
            statements.append("ATTACH DATABASE \(sqliteLiteral(legacyDeltaDatabase)) AS legacy_delta;")
        }
        statements.append("BEGIN IMMEDIATE;")
        if hasSnapshots {
            statements.append("""
            INSERT OR IGNORE INTO token_snapshots(thread_id, tokens_used, updated_at_ms, observed_at_ms)
            SELECT lower(thread_id), tokens_used, updated_at_ms, observed_at_ms
            FROM legacy_delta.token_snapshots
            WHERE NOT EXISTS (
              SELECT 1 FROM main.delta_cache_metadata
              WHERE key = 'legacy_import_completed' AND value >= 1
            );
            """)
        }
        if hasHistory {
            statements.append("""
            INSERT OR IGNORE INTO token_snapshot_history(thread_id, tokens_used, updated_at_ms, observed_at_ms)
            SELECT lower(thread_id), tokens_used, updated_at_ms, observed_at_ms
            FROM legacy_delta.token_snapshot_history
            WHERE NOT EXISTS (
              SELECT 1 FROM main.delta_cache_metadata
              WHERE key = 'legacy_import_completed' AND value >= 1
            );
            """)
        }
        statements.append("""
        INSERT INTO delta_cache_metadata(key, value)
        VALUES('legacy_import_completed', 1)
        ON CONFLICT(key) DO UPDATE SET value = excluded.value;
        """)
        statements.append("COMMIT;")
        if shouldAttach {
            statements.append("DETACH DATABASE legacy_delta;")
        }
        return statements.joined(separator: "\n")
    }

    private func deltaHistoryCompactionSQL() -> String {
        """
        BEGIN IMMEDIATE;
        DELETE FROM token_snapshot_history
        WHERE rowid IN (
          SELECT row_id
          FROM (
            SELECT
              rowid AS row_id,
              tokens_used,
              LAG(tokens_used) OVER (
                PARTITION BY lower(thread_id)
                ORDER BY observed_at_ms, rowid
              ) AS previous_tokens
            FROM token_snapshot_history
          )
          WHERE previous_tokens = tokens_used
        )
          AND NOT EXISTS (
            SELECT 1 FROM delta_cache_metadata
            WHERE key = 'history_compaction_completed' AND value >= 1
          );

        INSERT INTO delta_cache_metadata(key, value)
        VALUES('history_compaction_completed', 1)
        ON CONFLICT(key) DO UPDATE SET value = excluded.value;
        COMMIT;
        """
    }

    private func legacyDeltaHasTable(_ table: String, database: String) -> Bool {
        let query = """
        SELECT name
        FROM sqlite_master
        WHERE type = 'table'
          AND name = \(sqliteLiteral(table))
        LIMIT 1;
        """
        let records = (try? Shell.sqliteJSON(
            database: database,
            query: query,
            as: [SQLiteNameRecord].self,
            readOnly: true
        )) ?? []
        return !records.isEmpty
    }

    private func loadThreadTokenMap(for ids: [String]) -> [String: Int] {
        let uniqueIDs = Array(Set(ids.filter { !$0.isEmpty })).sorted()
        guard !uniqueIDs.isEmpty else {
            return [:]
        }

        let quotedIDs = uniqueIDs
            .map { "'\($0.replacingOccurrences(of: "'", with: "''"))'" }
            .joined(separator: ",")
        let query = """
        select id, coalesce(tokens_used, 0) as tokens_used
        from threads
        where id in (\(quotedIDs));
        """

        guard let records = try? Shell.sqliteJSON(database: stateDatabase, query: query, as: [ThreadTokenRecord].self, readOnly: true) else {
            return [:]
        }

        return Dictionary(
            records.map { ($0.id.lowercased(), $0.tokensUsed) },
            uniquingKeysWith: max
        )
    }

    private func mergeThreadRecords(_ records: [ThreadRecord]) -> [ThreadRecord] {
        var merged: [String: ThreadRecord] = [:]

        for record in records {
            guard !record.id.isEmpty else {
                continue
            }

            if let existing = merged[record.id] {
                merged[record.id] = mergeThreadRecord(existing, with: record)
            } else {
                merged[record.id] = record
            }
        }

        return merged.values.sorted {
            if $0.updatedAt == $1.updatedAt {
                return $0.title < $1.title
            }
            return $0.updatedAt > $1.updatedAt
        }
    }

    private func mergeThreadRecord(_ existing: ThreadRecord, with candidate: ThreadRecord) -> ThreadRecord {
        let updatedAt = max(existing.updatedAt, candidate.updatedAt)
        let createdAt = [existing.createdAt, candidate.createdAt].filter { $0 > 0 }.min() ?? 0
        let title = bestTitle(existing.title, candidate.title)
        let tokensUsed = max(existing.tokensUsed, candidate.tokensUsed)
        let rolloutPath = candidate.rolloutPath.isEmpty ? existing.rolloutPath : candidate.rolloutPath

        return ThreadRecord(
            id: existing.id,
            title: title,
            tokensUsed: tokensUsed,
            model: existing.model ?? candidate.model,
            reasoningEffort: existing.reasoningEffort ?? candidate.reasoningEffort,
            rolloutPath: rolloutPath,
            updatedAt: updatedAt,
            createdAt: createdAt,
            activeSubagentCount: max(existing.activeSubagentCount, candidate.activeSubagentCount)
        )
    }

    private func bestTitle(_ first: String, _ second: String) -> String {
        let firstTrimmed = first.trimmingCharacters(in: .whitespacesAndNewlines)
        let secondTrimmed = second.trimmingCharacters(in: .whitespacesAndNewlines)

        if firstTrimmed.isEmpty || firstTrimmed == "未命名任务" {
            return secondTrimmed.isEmpty ? "未命名任务" : secondTrimmed
        }
        return firstTrimmed
    }

    private func loadThreadsForPeriodUsage(now: Date) throws -> [ThreadRecord] {
        let monthStart = Int(now.timeIntervalSince1970) - (30 * 24 * 60 * 60)
        let query = """
        select
          id,
          coalesce(title, '未命名任务') as title,
          coalesce(tokens_used, 0) as tokens_used,
          model,
          reasoning_effort,
          coalesce(rollout_path, '') as rollout_path,
          coalesce(updated_at, 0) as updated_at
        from threads
        where updated_at >= \(monthStart)
        order by updated_at desc;
        """
        return withSessionIndexNames(
            try Shell.sqliteJSON(database: stateDatabase, query: query, as: [ThreadRecord].self, readOnly: true)
        )
    }

    private func loadArchivedThreadIDs() -> Set<String> {
        let query = """
        select id
        from threads
        where archived = 1;
        """
        guard let records = try? Shell.sqliteJSON(
            database: stateDatabase,
            query: query,
            as: [ThreadIDRecord].self,
            readOnly: true
        ) else {
            return []
        }
        return Set(records.map { $0.id.lowercased() })
    }

    private func withSessionIndexNames(_ threads: [ThreadRecord]) -> [ThreadRecord] {
        let indexedNames = loadSessionIndexThreadNames()
        guard !indexedNames.isEmpty else {
            return threads
        }

        return threads.map { thread in
            guard let indexedName = indexedNames[thread.id],
                  !indexedName.isEmpty,
                  indexedName != thread.title else {
                return thread
            }

            return ThreadRecord(
                id: thread.id,
                title: indexedName,
                tokensUsed: thread.tokensUsed,
                model: thread.model,
                reasoningEffort: thread.reasoningEffort,
                rolloutPath: thread.rolloutPath,
                updatedAt: thread.updatedAt,
                createdAt: thread.createdAt,
                activeSubagentCount: thread.activeSubagentCount
            )
        }
    }

    private func loadSessionIndexThreadNames() -> [String: String] {
        guard let content = try? String(contentsOfFile: sessionIndexPath, encoding: .utf8) else {
            return [:]
        }

        let decoder = JSONDecoder()
        var names: [String: String] = [:]

        for line in content.split(whereSeparator: \.isNewline) {
            guard let record = try? decoder.decode(SessionIndexRecord.self, from: Data(line.utf8)) else {
                continue
            }

            let name = record.threadName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else {
                continue
            }
            names[record.id] = name
        }

        return names
    }

    private func loadPeriodUsage(now: Date, threads: [ThreadRecord]) throws -> PeriodUsage {
        let rolloutPaths = Array(Set(threads.map(\.rolloutPath)).filter { !$0.isEmpty }).sorted()
        let signature = makeUsageSignature(for: rolloutPaths)
        if let signature,
           let cached = cachedPeriodUsage(now: now, signature: signature) {
            return cached
        }

        let rolloutUsage = loadPeriodUsageFromRollouts(now: now, threads: threads)
        let logUsage = (try? loadPeriodUsageFromLogs(now: now)) ?? .zero
        let usage = maxPeriodUsage(rolloutUsage, logUsage)

        if let signature {
            cachePeriodUsage(usage, signature: signature, now: now)
        }

        return usage
    }

    private func maxPeriodUsage(_ lhs: PeriodUsage, _ rhs: PeriodUsage) -> PeriodUsage {
        PeriodUsage(
            day: max(lhs.day, rhs.day),
            week: max(lhs.week, rhs.week),
            month: max(lhs.month, rhs.month)
        )
    }

    private func cachedPeriodUsage(now: Date, signature: StoreSignature) -> PeriodUsage? {
        cacheLock.lock()
        let cache = periodUsageCache
        cacheLock.unlock()

        guard let cache,
              cache.signature == signature,
              now.timeIntervalSince(cache.createdAt) < UsageScanPolicy.periodUsageCacheTTL else {
            return nil
        }
        return cache.usage
    }

    private func cachePeriodUsage(_ usage: PeriodUsage, signature: StoreSignature, now: Date) {
        cacheLock.lock()
        periodUsageCache = PeriodUsageCache(createdAt: now, signature: signature, usage: usage)
        cacheLock.unlock()
    }

    private func loadPeriodUsageFromLogs(now: Date) throws -> PeriodUsage {
        let oldest = Int(now.timeIntervalSince1970) - (30 * 24 * 60 * 60)
        let query = """
        select ts, feedback_log_body
        from logs
        where target = 'codex_otel.trace_safe'
          and feedback_log_body like '%event.kind=response.completed%'
          and feedback_log_body like '%tool_token_count=%'
          and ts >= \(oldest)
        order by ts desc;
        """

        let records = try Shell.sqliteJSON(database: logsDatabase, query: query, as: [UsageLogRecord].self, readOnly: true)
        let dayStart = Int(now.timeIntervalSince1970) - (24 * 60 * 60)
        let weekStart = Int(now.timeIntervalSince1970) - (7 * 24 * 60 * 60)

        var day = 0
        var week = 0
        var month = 0

        for record in records {
            guard let tokens = extractTokenCount(from: record.feedbackLogBody) else {
                continue
            }
            month += tokens
            if record.ts >= weekStart {
                week += tokens
            }
            if record.ts >= dayStart {
                day += tokens
            }
        }

        return PeriodUsage(day: day, week: week, month: month)
    }

    private func loadPeriodUsageFromRollouts(now: Date, threads: [ThreadRecord]) -> PeriodUsage {
        let paths = Array(Set(threads.map(\.rolloutPath)).filter {
            !$0.isEmpty && FileManager.default.fileExists(atPath: $0)
        }).sorted()
        if let usage = loadPeriodUsageWithRipgrep(now: now, paths: paths) {
            return usage
        }

        let dayStart = now.addingTimeInterval(-24 * 60 * 60)
        let weekStart = now.addingTimeInterval(-7 * 24 * 60 * 60)
        let monthStart = now.addingTimeInterval(-30 * 24 * 60 * 60)

        var day = 0
        var week = 0
        var month = 0

        func add(tokens: Int, date: Date) {
            guard tokens > 0, date >= monthStart else {
                return
            }

            month += tokens
            if date >= weekStart {
                week += tokens
            }
            if date >= dayStart {
                day += tokens
            }
        }

        var recordsByPath: [String: ThreadRecord] = [:]
        for thread in threads where !thread.rolloutPath.isEmpty {
            if let existing = recordsByPath[thread.rolloutPath] {
                recordsByPath[thread.rolloutPath] = mergeThreadRecord(existing, with: thread)
            } else {
                recordsByPath[thread.rolloutPath] = thread
            }
        }

        for thread in recordsByPath.values {
            let signature = fileSignature(thread.rolloutPath)
            if signature.exists,
               signature.size <= UsageScanPolicy.largeSessionTokenScanLimit {
                if let scanned = loadPeriodUsageFromRolloutTail(now: now, path: thread.rolloutPath),
                   scanned.foundTokenEvents {
                    day += scanned.usage.day
                    week += scanned.usage.week
                    month += scanned.usage.month
                }
                continue
            }

            guard !signature.exists else {
                continue
            }

            guard thread.tokensUsed > 0 else {
                continue
            }
            add(
                tokens: thread.tokensUsed,
                date: Date(timeIntervalSince1970: TimeInterval(thread.updatedAt))
            )
        }

        return PeriodUsage(day: day, week: week, month: month)
    }

    private func loadPeriodUsageFromRolloutTail(
        now: Date,
        path: String
    ) -> (usage: PeriodUsage, foundTokenEvents: Bool)? {
        guard let output = tokenCountLines(
            from: path,
            lineLimit: UsageScanPolicy.periodUsageTailLineLimit
        ) else {
            return nil
        }

        let dayStart = now.addingTimeInterval(-24 * 60 * 60)
        let weekStart = now.addingTimeInterval(-7 * 24 * 60 * 60)
        let monthStart = now.addingTimeInterval(-30 * 24 * 60 * 60)

        var day = 0
        var week = 0
        var month = 0
        var foundTokenEvents = false

        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let event = parseTokenCountEvent(String(line)) else {
                continue
            }

            foundTokenEvents = true
            guard event.date >= monthStart else {
                continue
            }

            month += event.tokens
            if event.date >= weekStart {
                week += event.tokens
            }
            if event.date >= dayStart {
                day += event.tokens
            }
        }

        return (PeriodUsage(day: day, week: week, month: month), foundTokenEvents)
    }

    private func loadPeriodUsageWithRipgrep(now: Date, paths: [String]) -> PeriodUsage? {
        guard let executable = ripgrepExecutable(),
              !paths.isEmpty else {
            return nil
        }

        guard let output = runRipgrepTokenSearch(executable: executable, paths: paths) else {
            return nil
        }

        let dayStart = now.addingTimeInterval(-24 * 60 * 60)
        let weekStart = now.addingTimeInterval(-7 * 24 * 60 * 60)
        let monthStart = now.addingTimeInterval(-30 * 24 * 60 * 60)

        var day = 0
        var week = 0
        var month = 0

        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let jsonStart = rawLine.firstIndex(of: "{") else {
                continue
            }

            let line = String(rawLine[jsonStart...])
            guard let event = parseTokenCountEvent(line),
                  event.date >= monthStart else {
                continue
            }

            month += event.tokens
            if event.date >= weekStart {
                week += event.tokens
            }
            if event.date >= dayStart {
                day += event.tokens
            }
        }

        return PeriodUsage(day: day, week: week, month: month)
    }

    private func runRipgrepTokenSearch(executable: String, paths: [String]) -> String? {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-notch-token-lines-\(UUID().uuidString).txt")
        defer {
            try? FileManager.default.removeItem(at: outputURL)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [
            "-c",
            """
            rg="$1"
            out="$2"
            bytes="$3"
            shift 3
            {
              for path in "$@"; do
                /usr/bin/tail -c "$bytes" -- "$path"
                printf '\\n'
              done
            } | "$rg" --fixed-strings --no-heading --color never -- '"token_count"' > "$out"
            status=$?
            if [ "$status" -eq 1 ]; then
              exit 0
            fi
            exit "$status"
            """,
            "codex-notch-token-search",
            executable,
            outputURL.path,
            String(UsageScanPolicy.periodUsageTailLineLimit * Int(UsageScanPolicy.estimatedTokenLineBytes))
        ] + paths
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return nil
        }

        let completed = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            process.waitUntilExit()
            completed.signal()
        }

        if completed.wait(timeout: .now() + UsageScanPolicy.ripgrepTimeout) == .timedOut {
            Shell.terminateProcessTree(rootPID: process.processIdentifier, signal: SIGTERM)
            if completed.wait(timeout: .now() + .milliseconds(200)) == .timedOut {
                Shell.terminateProcessTree(rootPID: process.processIdentifier, signal: SIGKILL)
                _ = completed.wait(timeout: .now() + .milliseconds(300))
            }
            return nil
        }

        guard let data = try? Data(contentsOf: outputURL) else {
            return nil
        }

        if !data.isEmpty {
            return String(decoding: data, as: UTF8.self)
        }

        guard process.terminationStatus == 0 else {
            return nil
        }
        return String(decoding: data, as: UTF8.self)
    }

    private func ripgrepExecutable() -> String? {
        ripgrepCandidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private func loadActiveThreadIDs(now: Date) throws -> Set<String> {
        let since = Int(now.timeIntervalSince1970) - UsageScanPolicy.runningActivityWindow
        let query = """
        select
          thread_id,
          max(case
            when feedback_log_body like '%response.output_item.added%'
              or feedback_log_body like '%response.output_text.delta%'
              or feedback_log_body like '%"status":"in_progress"%'
            then ts else 0 end) as latest_activity,
          max(case
            when feedback_log_body like '%"phase":"final_answer"%'
              or feedback_log_body like '%"phase": "final_answer"%'
              or feedback_log_body like '%"type":"task_complete"%'
              or feedback_log_body like '%"type": "task_complete"%'
              or feedback_log_body like '%"type":"task_completed"%'
              or feedback_log_body like '%"type": "task_completed"%'
              or feedback_log_body like '%"type":"task_stopped"%'
              or feedback_log_body like '%"type": "task_stopped"%'
              or feedback_log_body like '%"type":"task_failed"%'
              or feedback_log_body like '%"type": "task_failed"%'
              or feedback_log_body like '%"type":"task_cancelled"%'
              or feedback_log_body like '%"type": "task_cancelled"%'
            then ts else 0 end) as latest_done
        from logs
        where thread_id is not null
          and ts >= \(since)
        group by thread_id;
        """

        let records = try Shell.sqliteJSON(database: logsDatabase, query: query, as: [ActivityRecord].self, readOnly: true)
        let nowEpoch = Int(now.timeIntervalSince1970)

        return Set(records.compactMap { record in
            guard let threadId = record.threadId, !threadId.isEmpty else {
                return nil
            }
            let activity = record.latestActivity ?? 0
            let done = record.latestDone ?? 0
            if activity > done && nowEpoch - activity < UsageScanPolicy.runningActivityWindow {
                return threadId
            }
            if activity > 0 && activity >= done && nowEpoch - activity < 20 {
                return threadId
            }
            return nil
        })
    }

    private func loadTokenDeltas(for threads: [ThreadRecord], now: Date) -> [String: TokenDeltaWindow] {
        guard !threads.isEmpty else {
            return [:]
        }

        let nowMs = Int64((now.timeIntervalSince1970 * 1_000).rounded())
        let tenMinutesAgo = nowMs - Int64(10 * 60 * 1_000)
        let oneHourAgo = nowMs - Int64(60 * 60 * 1_000)
        let twentyFourHoursAgo = nowMs - Int64(24 * 60 * 60 * 1_000)
        let dayStartMs = Int64((Calendar.current.startOfDay(for: now).timeIntervalSince1970 * 1_000).rounded())
        let records = loadRollingDeltaRows(
            for: threads,
            tenMinuteCutoff: tenMinutesAgo,
            oneHourCutoff: oneHourAgo,
            dayCutoff: twentyFourHoursAgo,
            weekCutoff: nil,
            monthCutoff: nil,
            todayCutoff: dayStartMs
        )

        return Dictionary(
            records.map {
                (
                    $0.threadId.lowercased(),
                    TokenDeltaWindow(
                        delta10mTokens: rollingDelta(
                            current: $0.tokensUsed,
                            baseline: $0.baseline10m,
                            allowCreatedFallback: false,
                            createdAtMs: $0.createdAtMs,
                            cutoffMs: tenMinutesAgo
                        ),
                        delta1hTokens: rollingDelta(
                            current: $0.tokensUsed,
                            baseline: $0.baseline1h,
                            allowCreatedFallback: false,
                            createdAtMs: $0.createdAtMs,
                            cutoffMs: oneHourAgo
                        ),
                        delta24hTokens: rollingDelta(
                            current: $0.tokensUsed,
                            baseline: $0.baseline24h,
                            allowCreatedFallback: false,
                            createdAtMs: $0.createdAtMs,
                            cutoffMs: twentyFourHoursAgo
                        ),
                        deltaTodayTokens: rollingDelta(
                            current: $0.tokensUsed,
                            baseline: $0.baselineToday,
                            createdAtMs: $0.createdAtMs,
                            cutoffMs: dayStartMs
                        )
                    )
                )
            },
            uniquingKeysWith: { first, _ in first }
        )
    }

    private func loadAggregateTokenDeltas(for threads: [ThreadRecord], now: Date) -> TokenDeltaWindow {
        guard !threads.isEmpty else {
            return TokenDeltaWindow(delta10mTokens: nil, delta1hTokens: nil)
        }

        let nowMs = Int64((now.timeIntervalSince1970 * 1_000).rounded())
        let tenMinutesAgo = nowMs - Int64(10 * 60 * 1_000)
        let oneHourAgo = nowMs - Int64(60 * 60 * 1_000)
        let rows = loadRollingDeltaRows(
            for: threads,
            tenMinuteCutoff: tenMinutesAgo,
            oneHourCutoff: oneHourAgo,
            dayCutoff: nil,
            weekCutoff: nil,
            monthCutoff: nil,
            todayCutoff: nil
        )

        let delta10m = rows.compactMap {
            rollingDelta(
                current: $0.tokensUsed,
                baseline: $0.baseline10m,
                allowCreatedFallback: false,
                createdAtMs: $0.createdAtMs,
                cutoffMs: tenMinutesAgo
            )
        }.reduce(0, +)
        let delta1h = rows.compactMap {
            rollingDelta(
                current: $0.tokensUsed,
                baseline: $0.baseline1h,
                allowCreatedFallback: false,
                createdAtMs: $0.createdAtMs,
                cutoffMs: oneHourAgo
            )
        }.reduce(0, +)

        return TokenDeltaWindow(
            delta10mTokens: delta10m,
            delta1hTokens: delta1h
        )
    }

    private func totalDelta24h(for threads: [ThreadRecord], deltas: [String: TokenDeltaWindow]) -> Int {
        let trackedIDs = Set(threads.map { $0.id.lowercased() })
        return trackedIDs.reduce(0) { total, threadID in
            total + max(0, deltas[threadID]?.delta24hTokens ?? 0)
        }
    }

    private func buildTasks(
        from threads: [ThreadRecord],
        activeThreadIDs: Set<String>,
        deltas: [String: TokenDeltaWindow],
        todayTotalTokens: Int,
        now: Date,
        includeContextUsage: Bool = false,
        contextTaskLimit: Int = UsageScanPolicy.contextVisibleTaskLimit
    ) -> BuildTasksResult {
        var contextScanCount = 0
        let tasks = threads.enumerated().map { index, thread -> CodexTask in
            let updatedAt = Date(timeIntervalSince1970: TimeInterval(thread.updatedAt))
            let status: TaskStatus = activeThreadIDs.contains(thread.id) ? .running : .recent
            let model = thread.model ?? "模型未知"
            let effort = Formatters.reasoningEffortLabel(thread.reasoningEffort)
            let detail = "\(model) · \(effort) · \(Formatters.relativeAge(updatedAt, now: now))前"
            let delta = deltas[thread.id.lowercased()]
            let shouldLoadContext = includeContextUsage && (status == .running || index < contextTaskLimit)
            let contextResult = shouldLoadContext
                ? contextUsage(for: thread.rolloutPath)
                : (usage: nil, didScan: false)
            if contextResult.didScan {
                contextScanCount += 1
            }

            return CodexTask(
                id: thread.id,
                title: Formatters.shortTitle(thread.title),
                status: status,
                detail: detail,
                tokenCount: thread.tokensUsed,
                updatedAt: updatedAt,
                activeSubagentCount: thread.activeSubagentCount,
                delta10mTokens: delta?.delta10mTokens,
                delta1hTokens: delta?.delta1hTokens,
                todayTokens: delta?.deltaTodayTokens,
                todaySharePercent: CodexTask.sharePercent(
                    tokens: delta?.deltaTodayTokens,
                    totalTokens: todayTotalTokens
                ),
                contextInputTokens: contextResult.usage?.inputTokens,
                contextWindowTokens: contextResult.usage?.windowTokens,
                contextPercent: contextResult.usage?.percent,
                contextUpdatedAt: contextResult.usage?.updatedAt
            )
        }

        let running = tasks.filter { $0.status == .running }
        if !running.isEmpty {
            return BuildTasksResult(
                tasks: running + tasks.filter { $0.status != .running },
                contextScans: contextScanCount
            )
        }
        return BuildTasksResult(tasks: tasks, contextScans: contextScanCount)
    }

    private func sessionLooksActive(path: String, fallbackUpdatedAt: Int, now: Date) -> Bool {
        guard !path.isEmpty else {
            return false
        }

        let nowEpoch = Int(now.timeIntervalSince1970)
        guard nowEpoch - fallbackUpdatedAt < UsageScanPolicy.runningActivityWindow else {
            return false
        }

        let signature = fileSignature(path)
        let cacheKey = signature.path
        cacheLock.lock()
        let cached = sessionActivityCache[cacheKey]
        cacheLock.unlock()

        let facts: SessionActivityCache
        if let cached, cached.signature == signature {
            facts = cached
        } else {
            let text = fileSuffix(from: path, maxBytes: 256 * 1024)
            var latestActivity: Date?
            var latestDone: Date?

            if let text {
                for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
                    let lineText = String(line)
                    guard let event = sessionLineEvent(fromJSONLine: lineText) else {
                        continue
                    }

                    if sessionLineMarksCompletion(event) {
                        latestDone = maxDate(latestDone, event.timestamp)
                    }

                    if sessionLineMarksActivity(event) {
                        latestActivity = maxDate(latestActivity, event.timestamp)
                    }
                }
            }

            facts = SessionActivityCache(
                signature: signature,
                latestActivity: latestActivity,
                latestDone: latestDone,
                readSucceeded: text != nil
            )
            cacheLock.lock()
            sessionActivityCache[cacheKey] = facts
            sessionFileCacheCounters.activityScans += 1
            cacheLock.unlock()
        }

        guard facts.readSucceeded else {
            return nowEpoch - fallbackUpdatedAt < 12
        }

        if let latestActivity = facts.latestActivity {
            let done = facts.latestDone ?? .distantPast
            if latestActivity > done,
               now.timeIntervalSince(latestActivity) < TimeInterval(UsageScanPolicy.runningActivityWindow) {
                return true
            }
            if now.timeIntervalSince(latestActivity) < 12,
               facts.latestDone == nil {
                return true
            }
        }

        return false
    }

    private func sessionLineEvent(fromJSONLine line: String) -> SessionLineEvent? {
        guard line.contains(#""timestamp""#),
              let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let value = object["timestamp"] as? String,
              let timestamp = parseTimestamp(value) else {
            return nil
        }

        let payload = object["payload"] as? [String: Any]
        return SessionLineEvent(
            timestamp: timestamp,
            topLevelType: object["type"] as? String,
            payloadType: payload?["type"] as? String,
            payloadPhase: payload?["phase"] as? String,
            payloadStatus: payload?["status"] as? String
        )
    }

    private func sessionLineMarksCompletion(_ event: SessionLineEvent) -> Bool {
        let phase = event.payloadPhase?.lowercased()
        if phase == "final" || phase == "final_answer" {
            return true
        }

        guard let payloadType = event.payloadType?.lowercased() else {
            return false
        }

        if terminalEventTypes.contains(payloadType) {
            return true
        }

        return false
    }

    private func sessionLineMarksActivity(_ event: SessionLineEvent) -> Bool {
        if event.topLevelType == "response_item" {
            return true
        }

        let payloadType = event.payloadType?.lowercased()
        if payloadType == "response.output_item.added" || payloadType == "response.output_text.delta" {
            return true
        }

        return event.payloadStatus?.lowercased() == "in_progress"
    }

    private func timestamp(fromJSONLine line: String) -> Date? {
        guard line.contains(#""timestamp""#),
              let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let value = object["timestamp"] as? String else {
            return nil
        }
        return parseTimestamp(value)
    }

    private func maxDate(_ lhs: Date?, _ rhs: Date) -> Date {
        guard let lhs else {
            return rhs
        }
        return max(lhs, rhs)
    }

    private func sessionTitle(from path: String) -> String? {
        sessionPrefixFacts(from: path).title
    }

    private func sessionPrefixFacts(from path: String) -> SessionPrefixFacts {
        let empty = SessionPrefixFacts(meta: nil, runtime: nil, title: nil)
        let signature = fileSignature(path)
        guard signature.exists else {
            return empty
        }
        let cacheKey = signature.path

        cacheLock.lock()
        let cached = sessionPrefixFactsCache[cacheKey]
        cacheLock.unlock()
        if let cached, cached.signature == signature {
            return cached.facts
        }

        let scanLimit: UInt64 = 1_024 * 1_024
        let isAppend = cached?.signature.inode == signature.inode
            && (cached?.signature.size ?? 0) <= signature.size
            && (cached?.signature.modifiedAtNanoseconds ?? 0) <= signature.modifiedAtNanoseconds
        if let cached,
           isAppend,
           cached.scannedBytes >= scanLimit
                || (cached.facts.meta != nil && cached.facts.runtime != nil && cached.facts.title != nil) {
            let retained = SessionPrefixFactsCache(
                signature: signature,
                scannedBytes: cached.scannedBytes,
                facts: cached.facts
            )
            cacheLock.lock()
            sessionPrefixFactsCache[cacheKey] = retained
            cacheLock.unlock()
            return retained.facts
        }

        let text = filePrefix(from: path, maxBytes: Int(scanLimit))
        let parsed = SessionPrefixFacts(
            meta: text.flatMap(parseSessionMeta(from:)),
            runtime: text.flatMap(parseSessionRuntimeInfo(from:)),
            title: text.flatMap(parseSessionTitle(from:))
        )
        let facts = isAppend
            ? SessionPrefixFacts(
                meta: cached?.facts.meta ?? parsed.meta,
                runtime: cached?.facts.runtime ?? parsed.runtime,
                title: cached?.facts.title ?? parsed.title
            )
            : parsed
        cacheLock.lock()
        sessionPrefixFactsCache[cacheKey] = SessionPrefixFactsCache(
            signature: signature,
            scannedBytes: min(signature.size, scanLimit),
            facts: facts
        )
        sessionFileCacheCounters.prefixScans += 1
        cacheLock.unlock()
        return facts
    }

    private func parseSessionTitle(from text: String) -> String? {
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard line.contains(#""role":"user""#) || line.contains(#""role": "user""#),
                  let data = String(line).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let payload = object["payload"] as? [String: Any],
                  payload["type"] as? String == "message",
                  payload["role"] as? String == "user",
                  let content = payload["content"] as? [[String: Any]] else {
                continue
            }

            for item in content {
                guard let text = item["text"] as? String,
                      let title = normalizedSessionTitle(from: text) else {
                    continue
                }
                return title
            }
        }

        return nil
    }

    private func normalizedSessionTitle(from text: String) -> String? {
        var candidate = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let requestRange = candidate.range(of: "## My request for Codex:") {
            candidate = String(candidate[requestRange.upperBound...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        for line in candidate.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  !trimmed.hasPrefix("<environment_context"),
                  !trimmed.hasPrefix("</environment_context"),
                  !trimmed.hasPrefix("<permissions instructions"),
                  !trimmed.hasPrefix("<app-context"),
                  !trimmed.hasPrefix("# Files mentioned"),
                  !trimmed.hasPrefix("# In app browser"),
                  !trimmed.hasPrefix("## My request for Codex:"),
                  !trimmed.hasPrefix("- ") else {
                continue
            }
            return trimmed
        }

        return nil
    }

    private func sessionID(from path: String) -> String? {
        let name = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        let pieces = name.split(separator: "-", omittingEmptySubsequences: false)
        guard pieces.count >= 5 else {
            return nil
        }

        let suffix = pieces.suffix(5).joined(separator: "-")
        let idPieces = suffix.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        guard idPieces.map(\.count) == [8, 4, 4, 4, 12] else {
            return nil
        }

        let hex = CharacterSet(charactersIn: "0123456789abcdefABCDEF")
        guard idPieces.joined().unicodeScalars.allSatisfy({ hex.contains($0) }) else {
            return nil
        }

        return suffix.lowercased()
    }

    private func sessionTokenTotal(from path: String) -> Int? {
        let signature = fileSignature(path)
        guard signature.exists else {
            return nil
        }
        let cacheKey = signature.path

        cacheLock.lock()
        if let cached = sessionTokenTotalCache[cacheKey],
           cached.signature == signature {
            cacheLock.unlock()
            return cached.foundTokenEvent ? cached.tokens : nil
        }

        let cached = sessionTokenTotalCache[cacheKey]
        cacheLock.unlock()

        let scanStart: UInt64
        let initialTotal: Int
        let initialPendingLine: String
        let hadTokenEvent: Bool
        if let cached,
           cached.bytesScanned < signature.size,
           cached.signature.inode == signature.inode,
           cached.signature.size <= signature.size,
           cached.signature.modifiedAtNanoseconds <= signature.modifiedAtNanoseconds {
            scanStart = cached.bytesScanned
            initialTotal = cached.tokens
            initialPendingLine = cached.pendingLine
            hadTokenEvent = cached.foundTokenEvent
        } else {
            scanStart = 0
            initialTotal = 0
            initialPendingLine = ""
            hadTokenEvent = false
        }

        guard let scan = scanSessionTokenTotal(
            from: path,
            startingAt: scanStart,
            endingAt: signature.size,
            initialTotal: initialTotal,
            initialPendingLine: initialPendingLine,
            hadTokenEvent: hadTokenEvent
        ) else {
            return nil
        }

        cacheLock.lock()
        sessionTokenTotalCache[cacheKey] = SessionTokenTotalCache(
            signature: signature,
            bytesScanned: scan.bytesScanned,
            tokens: scan.tokens,
            pendingLine: scan.pendingLine,
            foundTokenEvent: scan.foundTokenEvent
        )
        cacheLock.unlock()
        return scan.foundTokenEvent ? scan.tokens : nil
    }

    private func scanSessionTokenTotal(
        from path: String,
        startingAt: UInt64 = 0,
        endingAt: UInt64,
        initialTotal: Int = 0,
        initialPendingLine: String = "",
        hadTokenEvent: Bool = false
    ) -> SessionTokenScanResult? {
        guard FileManager.default.fileExists(atPath: path),
              let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else {
            return nil
        }
        defer {
            try? handle.close()
        }

        guard startingAt <= endingAt else {
            return nil
        }

        do {
            try handle.seek(toOffset: startingAt)
        } catch {
            return nil
        }

        var pending = initialPendingLine
        var total = initialTotal
        var foundTokenEvent = hadTokenEvent
        var bytesScanned = startingAt

        while bytesScanned < endingAt {
            let data: Data
            do {
                let remaining = endingAt - bytesScanned
                let chunkSize = Int(min(UInt64(1024 * 1024), remaining))
                data = try handle.read(upToCount: chunkSize) ?? Data()
            } catch {
                return nil
            }
            if data.isEmpty {
                break
            }
            bytesScanned += UInt64(data.count)

            pending += String(decoding: data, as: UTF8.self)
            let lines = pending.split(separator: "\n", omittingEmptySubsequences: false)
            guard let lastLine = lines.last else {
                continue
            }
            pending = String(lastLine)

            for line in lines.dropLast() where line.contains(#""token_count""#) {
                guard let event = parseTokenCountEvent(String(line)) else {
                    continue
                }
                total += event.tokens
                foundTokenEvent = true
            }
        }

        if pending.contains(#""token_count""#),
           let event = parseTokenCountEvent(pending) {
            total += event.tokens
            pending = ""
            foundTokenEvent = true
        }

        return SessionTokenScanResult(
            bytesScanned: bytesScanned,
            tokens: total,
            pendingLine: pending,
            foundTokenEvent: foundTokenEvent
        )
    }

    private func filePrefix(from path: String, maxBytes: Int) -> String? {
        guard FileManager.default.fileExists(atPath: path) else {
            return nil
        }

        do {
            let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
            defer {
                try? handle.close()
            }
            let data = try handle.read(upToCount: maxBytes) ?? Data()
            return String(decoding: data, as: UTF8.self)
        } catch {
            return nil
        }
    }

    private func fileSuffix(from path: String, maxBytes: UInt64) -> String? {
        guard FileManager.default.fileExists(atPath: path) else {
            return nil
        }

        do {
            let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
            defer {
                try? handle.close()
            }

            let fileSize = try handle.seekToEnd()
            let start = fileSize > maxBytes ? fileSize - maxBytes : 0
            try handle.seek(toOffset: start)
            let data = try handle.readToEnd() ?? Data()
            return String(decoding: data, as: UTF8.self)
        } catch {
            return nil
        }
    }

    private func sessionMeta(from path: String) -> SessionMetaInfo? {
        sessionPrefixFacts(from: path).meta
    }

    private func parseSessionMeta(from text: String) -> SessionMetaInfo? {
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard line.contains(#""session_meta""#) else {
                continue
            }

            let lineText = String(line)
            guard let data = lineText.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["type"] as? String == "session_meta",
                  let payload = object["payload"] as? [String: Any] else {
                if let fallback = fallbackSessionMeta(from: lineText) {
                    return fallback
                }
                continue
            }

            let source = payload["source"] as? [String: Any]
            let subagentSource = source?["subagent"] as? [String: Any]
            let hasSubagentSource = subagentSource != nil
            let threadSource = payload["thread_source"] as? String
            let threadSpawn = subagentSource?["thread_spawn"] as? [String: Any]
            let parentThreadID = (
                payload["parent_thread_id"] as? String
                    ?? payload["parentThreadId"] as? String
                    ?? threadSpawn?["parent_thread_id"] as? String
                    ?? threadSpawn?["parentThreadId"] as? String
            )?.lowercased()
            let isSubagent = threadSource == "subagent" || hasSubagentSource

            return SessionMetaInfo(
                isSubagent: isSubagent,
                parentThreadID: isSubagent ? parentThreadID : nil
            )
        }

        return nil
    }

    private func fallbackSessionMeta(from line: String) -> SessionMetaInfo? {
        guard line.range(of: #""type"\s*:\s*"session_meta""#, options: .regularExpression) != nil else {
            return nil
        }

        let threadSource = jsonStringValue(for: "thread_source", in: line)
        let hasSubagentSource = line.range(
            of: #""source"\s*:\s*\{\s*"subagent"\s*:"#,
            options: .regularExpression
        ) != nil
        let isSubagent = threadSource == "subagent" || hasSubagentSource
        guard isSubagent else {
            return SessionMetaInfo(isSubagent: false, parentThreadID: nil)
        }

        return SessionMetaInfo(
            isSubagent: true,
            parentThreadID: (
                jsonStringValue(for: "parent_thread_id", in: line)
                    ?? jsonStringValue(for: "parentThreadId", in: line)
            )?.lowercased()
        )
    }

    private func jsonStringValue(for key: String, in line: String) -> String? {
        let escapedKey = NSRegularExpression.escapedPattern(for: key)
        let pattern = #"""# + escapedKey + #""\s*:\s*"((?:\\.|[^"\\])*)""#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }

        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        guard let match = regex.firstMatch(in: line, range: range),
              let valueRange = Range(match.range(at: 1), in: line) else {
            return nil
        }
        return String(line[valueRange])
    }

    private func sessionRuntimeInfo(from path: String) -> SessionRuntimeInfo? {
        sessionPrefixFacts(from: path).runtime
    }

    private func parseSessionRuntimeInfo(from text: String) -> SessionRuntimeInfo? {
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard line.contains(#""turn_context""#),
                  let data = String(line).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["type"] as? String == "turn_context",
                  let payload = object["payload"] as? [String: Any] else {
                continue
            }

            let settings = (payload["collaboration_mode"] as? [String: Any])?["settings"] as? [String: Any]
            let model = stringValue(payload["model"]) ?? stringValue(settings?["model"])
            let reasoningEffort = stringValue(payload["effort"])
                ?? stringValue(payload["reasoning_effort"])
                ?? stringValue(settings?["reasoning_effort"])

            if model != nil || reasoningEffort != nil {
                return SessionRuntimeInfo(model: model, reasoningEffort: reasoningEffort)
            }
        }

        return nil
    }

    private func candidateRateLimitPaths(from threads: [ThreadRecord], recentLimit: Int = 80) -> [String] {
        var seen = Set<String>()
        var paths: [String] = []

        for path in threads.map(\.rolloutPath) + recentTaskSessionPaths(limit: recentLimit) {
            guard !path.isEmpty, seen.insert(path).inserted else {
                continue
            }
            guard sessionMeta(from: path)?.isSubagent != true else {
                continue
            }
            paths.append(path)
        }

        return paths
    }

    private func recentSessionActivityWatchPaths(limit: Int = 80) -> [String] {
        let paths = recentTaskSessionPaths(limit: limit)
        let directories = paths.map { URL(fileURLWithPath: $0).deletingLastPathComponent().path }
        return paths + directories
    }

    private func uniqueExistingPaths(_ paths: [String]) -> [String] {
        var seen = Set<String>()
        return paths.compactMap { path in
            guard !path.isEmpty else {
                return nil
            }
            let normalizedPath = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
            guard FileManager.default.fileExists(atPath: normalizedPath),
                  seen.insert(normalizedPath).inserted else {
                return nil
            }
            return normalizedPath
        }
    }

    private func recentTaskSessionPaths(limit: Int) -> [String] {
        cacheLock.lock()
        let cachedPaths = recentTaskPathsCache
        cacheLock.unlock()

        if let cachedPaths,
           cachedPaths.collectedLimit >= limit,
           Date().timeIntervalSince(cachedPaths.createdAt) < 5 {
            return Array(cachedPaths.paths.prefix(limit))
        }

        let collectedLimit = max(limit, cachedPaths?.collectedLimit ?? 0)
        let paths = collectRecentSessionPaths(
            roots: [codexDirectory.appendingPathComponent("sessions")],
            limit: collectedLimit
        )

        cacheLock.lock()
        recentTaskPathsCache = RecentPathsCache(
            createdAt: Date(),
            paths: paths,
            collectedLimit: collectedLimit
        )
        cacheLock.unlock()

        return Array(paths.prefix(limit))
    }

    private func recentSessionPaths(limit: Int) -> [String] {
        cacheLock.lock()
        let cachedPaths = recentPathsCache
        cacheLock.unlock()

        if let cachedPaths,
           cachedPaths.collectedLimit >= limit,
           Date().timeIntervalSince(cachedPaths.createdAt) < 5 {
            return Array(cachedPaths.paths.prefix(limit))
        }

        let roots = [
            codexDirectory.appendingPathComponent("sessions"),
            codexDirectory.appendingPathComponent("archived_sessions")
        ]

        let collectedLimit = max(limit, 8, cachedPaths?.collectedLimit ?? 0)
        let paths = collectRecentSessionPaths(roots: roots, limit: collectedLimit)

        cacheLock.lock()
        recentPathsCache = RecentPathsCache(
            createdAt: Date(),
            paths: paths,
            collectedLimit: collectedLimit
        )
        cacheLock.unlock()

        return Array(paths.prefix(limit))
    }

    private func sessionPath(for sessionID: String) -> String? {
        let normalized = sessionID.lowercased()
        let roots = [
            codexDirectory.appendingPathComponent("sessions"),
            codexDirectory.appendingPathComponent("archived_sessions")
        ]
        return collectRecentSessionPaths(roots: roots, limit: 1_000)
            .first { path in
                self.sessionID(from: path)?.lowercased() == normalized
            }
    }

    private func collectRecentSessionPaths(roots: [URL], limit: Int) -> [String] {
        CodexSessionFileLocator.recentRolloutPaths(roots: roots, limit: limit)
    }

    private struct LocalRateLimitSelection {
        let snapshot: RateLimitSnapshot
        let candidateCount: Int
        let recentCandidateCount: Int
        let generationCount: Int
        let recentGenerationCount: Int
        let selectionReason: String
        let selectedGenerationSupport: Int
    }

    private struct LocalGenerationDecision {
        let snapshot: RateLimitSnapshot?
        let reason: String
        let support: Int
    }

    private struct LocalRateLimitGeneration {
        let snapshot: RateLimitSnapshot
        let support: Int
        let activeWindowCount: Int
    }

    private struct MainRateLimitMerge {
        let snapshot: RateLimitSnapshot
        let primaryReason: String
        let secondaryReason: String
        let officialWindowCount: Int
    }

    private struct RateLimitWindowDecision {
        let percent: Int?
        let resetsAt: Int?
        let windowMinutes: Int?
        let reason: String
        let usesOfficial: Bool
    }

    private enum AppServerCacheFreshness: String {
        case fresh
        case stale
    }

    private struct AvailableAppServerRateLimits {
        let snapshot: RateLimitSnapshot
        let freshness: AppServerCacheFreshness
        let ageSeconds: Int

        var sourceName: String {
            "app-server-\(freshness.rawValue)"
        }
    }

    private func loadRateLimits(
        from paths: [String],
        source: RateLimitSourcePreference,
        now: Date,
        diagnosticID: String
    ) -> RateLimitLoadResult {
        let localSelection = loadLatestRateLimits(from: paths, now: now)
        let local = localSelection.snapshot
        switch source {
        case .appServerFirst:
            let appServer = availableAppServerRateLimits(now: now)
            if let appServer, hasMainRateLimitData(appServer.snapshot) {
                let merge = authoritativeMainRateLimits(
                    appServer: appServer,
                    local: localSelection,
                    now: now
                )
                let result = RateLimitLoadResult(
                    snapshot: merge.snapshot.withSparkQuotaWindows(
                        mergedSparkQuotaWindows(from: [appServer.snapshot, local], now: now, preferSourceOrder: true)
                    ),
                    source: merge.officialWindowCount > 0
                        ? appServer.sourceName
                        : (hasMainRateLimitData(local) ? "local-jsonl" : "none")
                )
                return loggedRateLimitResult(
                    result,
                    preference: source,
                    appServer: appServer,
                    local: localSelection,
                    primaryReason: merge.primaryReason,
                    secondaryReason: merge.secondaryReason,
                    diagnosticID: diagnosticID
                )
            }

            if hasMainRateLimitData(local) {
                if let appServer, hasAnyRateLimitData(appServer.snapshot) {
                    let result = RateLimitLoadResult(
                        snapshot: local.withSparkQuotaWindows(
                            mergedSparkQuotaWindows(from: [appServer.snapshot, local], now: now, preferSourceOrder: true)
                        ).withResetCredits(appServer.snapshot.resetCredits),
                        source: "local-jsonl"
                    )
                    return loggedRateLimitResult(
                        result,
                        preference: source,
                        appServer: appServer,
                        local: localSelection,
                        primaryReason: "local_jsonl_only",
                        secondaryReason: "local_jsonl_only",
                        diagnosticID: diagnosticID
                    )
                }
                return loggedRateLimitResult(
                    RateLimitLoadResult(snapshot: local, source: "local-jsonl"),
                    preference: source,
                    appServer: appServer,
                    local: localSelection,
                    primaryReason: "local_jsonl_only",
                    secondaryReason: "local_jsonl_only",
                    diagnosticID: diagnosticID
                )
            }

            if let appServer, hasAnyRateLimitData(appServer.snapshot) {
                return loggedRateLimitResult(
                    RateLimitLoadResult(snapshot: appServer.snapshot, source: appServer.sourceName),
                    preference: source,
                    appServer: appServer,
                    local: localSelection,
                    primaryReason: "app_server_only",
                    secondaryReason: "app_server_only",
                    diagnosticID: diagnosticID
                )
            }

            return loggedRateLimitResult(
                RateLimitLoadResult(
                    snapshot: local,
                    source: hasAnyRateLimitData(local) ? "local-jsonl" : "none"
                ),
                preference: source,
                appServer: appServer,
                local: localSelection,
                primaryReason: "unavailable",
                secondaryReason: "unavailable",
                diagnosticID: diagnosticID
            )
        case .localFilesOnly:
            return loggedRateLimitResult(
                RateLimitLoadResult(
                    snapshot: local,
                    source: hasAnyRateLimitData(local) ? "local-jsonl" : "none"
                ),
                preference: source,
                appServer: nil,
                local: localSelection,
                primaryReason: hasMainRateLimitData(local) ? "local_jsonl_only" : "unavailable",
                secondaryReason: hasMainRateLimitData(local) ? "local_jsonl_only" : "unavailable",
                diagnosticID: diagnosticID
            )
        }
    }

    private func authoritativeMainRateLimits(
        appServer: AvailableAppServerRateLimits,
        local: LocalRateLimitSelection,
        now: Date
    ) -> MainRateLimitMerge {
        let localSnapshot = local.snapshot
        let primary = authoritativeRateLimitWindow(
            official: (
                appServer.snapshot.primaryPercent,
                appServer.snapshot.primaryResetsAt,
                appServer.snapshot.primaryWindowMinutes
            ),
            fallback: (
                localSnapshot.primaryPercent,
                localSnapshot.primaryResetsAt,
                localSnapshot.primaryWindowMinutes
            ),
            officialReason: "app_server_\(appServer.freshness.rawValue)",
            now: now
        )
        let secondaryFallback = isWeeklyOnlyMainRateLimit(appServer.snapshot)
            ? (percent: nil, resetsAt: nil, windowMinutes: nil)
            : (
                percent: localSnapshot.secondaryPercent,
                resetsAt: localSnapshot.secondaryResetsAt,
                windowMinutes: localSnapshot.secondaryWindowMinutes
            )
        let secondary = authoritativeRateLimitWindow(
            official: (
                appServer.snapshot.secondaryPercent,
                appServer.snapshot.secondaryResetsAt,
                appServer.snapshot.secondaryWindowMinutes
            ),
            fallback: secondaryFallback,
            officialReason: "app_server_\(appServer.freshness.rawValue)",
            now: now
        )

        return MainRateLimitMerge(
            snapshot: RateLimitSnapshot(
                primaryPercent: primary.percent,
                secondaryPercent: secondary.percent,
                primaryResetsAt: primary.resetsAt,
                secondaryResetsAt: secondary.resetsAt,
                primaryWindowMinutes: primary.windowMinutes,
                secondaryWindowMinutes: secondary.windowMinutes,
                capturedAt: appServer.snapshot.capturedAt ?? localSnapshot.capturedAt,
                isPrimaryCodexLimit: appServer.snapshot.isPrimaryCodexLimit || localSnapshot.isPrimaryCodexLimit,
                sparkQuotaWindows: appServer.snapshot.sparkQuotaWindows,
                resetCredits: appServer.snapshot.resetCredits
            ),
            primaryReason: primary.reason,
            secondaryReason: secondary.reason,
            officialWindowCount: [primary, secondary].filter(\.usesOfficial).count
        )
    }

    private func isWeeklyOnlyMainRateLimit(_ snapshot: RateLimitSnapshot) -> Bool {
        snapshot.primaryWindowMinutes == 10_080
            && snapshot.secondaryPercent == nil
            && snapshot.secondaryResetsAt == nil
            && snapshot.secondaryWindowMinutes == nil
    }

    private func authoritativeRateLimitWindow(
        official: (percent: Int?, resetsAt: Int?, windowMinutes: Int?),
        fallback: (percent: Int?, resetsAt: Int?, windowMinutes: Int?),
        officialReason: String,
        now: Date
    ) -> RateLimitWindowDecision {
        if official.percent == nil, official.resetsAt == nil, official.windowMinutes == nil {
            return RateLimitWindowDecision(
                percent: fallback.percent,
                resetsAt: fallback.resetsAt,
                windowMinutes: fallback.windowMinutes,
                reason: fallback.percent == nil && fallback.resetsAt == nil && fallback.windowMinutes == nil
                    ? "unavailable"
                    : "local_jsonl_only",
                usesOfficial: false
            )
        }

        let resetNeedsConfirmation = official.resetsAt.map { $0 <= Int(now.timeIntervalSince1970) } ?? false
        return RateLimitWindowDecision(
            percent: official.percent,
            resetsAt: official.resetsAt,
            windowMinutes: official.windowMinutes,
            reason: resetNeedsConfirmation ? "\(officialReason)_pending_reset_refresh" : officialReason,
            usesOfficial: true
        )
    }

    private func isSuspiciousAppServerRebound(
        _ candidate: RateLimitSnapshot,
        comparedTo previous: RateLimitSnapshot
    ) -> Bool {
        let primaryIncrease = quotaIncrease(candidate.primaryPercent, over: previous.primaryPercent)
        let secondaryIncrease = quotaIncrease(candidate.secondaryPercent, over: previous.secondaryPercent)
        return primaryIncrease >= UsageScanPolicy.appServerReboundThreshold
            || secondaryIncrease >= UsageScanPolicy.appServerReboundThreshold
    }

    private func quotaIncrease(_ candidate: Int?, over previous: Int?) -> Int {
        guard let candidate, let previous else {
            return 0
        }
        return candidate - previous
    }

    private func sameMainRateLimitGeneration(
        _ lhs: RateLimitSnapshot,
        _ rhs: RateLimitSnapshot
    ) -> Bool {
        sameRateLimitReset(lhs.primaryResetsAt, rhs.primaryResetsAt)
            && sameRateLimitReset(lhs.secondaryResetsAt, rhs.secondaryResetsAt)
    }

    private func sameRateLimitReset(_ lhs: Int?, _ rhs: Int?) -> Bool {
        switch (lhs, rhs) {
        case (.none, .none):
            true
        case (.some(let lhs), .some(let rhs)):
            abs(TimeInterval(lhs) - TimeInterval(rhs)) <= TimeInterval(UsageScanPolicy.rateLimitResetTolerance)
        default:
            false
        }
    }

    private func earliestMainRateLimitReset(_ snapshot: RateLimitSnapshot?) -> Int? {
        guard let snapshot else {
            return nil
        }
        return [snapshot.primaryResetsAt, snapshot.secondaryResetsAt]
            .compactMap { $0 }
            .min()
    }

    private func hasReachedMainRateLimitReset(_ snapshot: RateLimitSnapshot?, now: Date) -> Bool {
        guard let resetAt = earliestMainRateLimitReset(snapshot) else {
            return false
        }
        return resetAt <= Int(now.timeIntervalSince1970)
    }

    private func hasMainRateLimitData(_ snapshot: RateLimitSnapshot) -> Bool {
        snapshot.primaryPercent != nil
            || snapshot.secondaryPercent != nil
            || snapshot.primaryResetsAt != nil
            || snapshot.secondaryResetsAt != nil
    }

    private func hasAnyRateLimitData(_ snapshot: RateLimitSnapshot) -> Bool {
        hasMainRateLimitData(snapshot)
            || !snapshot.sparkQuotaWindows.isEmpty
            || snapshot.resetCredits != nil
    }

    private func loggedRateLimitResult(
        _ result: RateLimitLoadResult,
        preference: RateLimitSourcePreference,
        appServer: AvailableAppServerRateLimits?,
        local: LocalRateLimitSelection,
        primaryReason: String,
        secondaryReason: String,
        diagnosticID: String
    ) -> RateLimitLoadResult {
        let localSnapshot = local.snapshot
        let finalSnapshot = result.snapshot
        let appServerSnapshot = appServer?.snapshot
        let cacheMetrics = appServerCacheMetrics(now: Date())
        diagnostics?.record(
            event: "quota_resolution",
            correlationID: diagnosticID,
            fields: [
                "preference": preference.rawValue,
                "result_source": result.source,
                "primary_decision": primaryReason,
                "secondary_decision": secondaryReason,
                "reset_tolerance_seconds": UsageScanPolicy.rateLimitResetTolerance,
                "local_consensus_minimum_support": UsageScanPolicy.rateLimitConsensusMinimumSupport,
                "local_candidate_count": local.candidateCount,
                "local_recent_candidate_count": local.recentCandidateCount,
                "local_generation_count": local.generationCount,
                "local_recent_generation_count": local.recentGenerationCount,
                "local_selection_reason": local.selectionReason,
                "local_selected_generation_support": local.selectedGenerationSupport,
                "app_server_cache_state": appServer?.freshness.rawValue ?? cacheMetrics.state,
                "app_server_cache_age_seconds": diagnosticValue(appServer?.ageSeconds ?? cacheMetrics.ageSeconds),
                "app_server_consecutive_failures": cacheMetrics.consecutiveFailures,
                "app_server_next_retry_at": diagnosticValue(epochSeconds(cacheMetrics.nextRetryAt)),
                "app_server_pending_rebound": cacheMetrics.hasPendingRebound,
                "app_server_primary_percent": diagnosticValue(appServerSnapshot?.primaryPercent),
                "app_server_secondary_percent": diagnosticValue(appServerSnapshot?.secondaryPercent),
                "app_server_primary_reset_at": diagnosticValue(appServerSnapshot?.primaryResetsAt),
                "app_server_secondary_reset_at": diagnosticValue(appServerSnapshot?.secondaryResetsAt),
                "app_server_captured_at": diagnosticValue(epochSeconds(appServerSnapshot?.capturedAt)),
                "local_primary_percent": diagnosticValue(localSnapshot.primaryPercent),
                "local_secondary_percent": diagnosticValue(localSnapshot.secondaryPercent),
                "local_primary_reset_at": diagnosticValue(localSnapshot.primaryResetsAt),
                "local_secondary_reset_at": diagnosticValue(localSnapshot.secondaryResetsAt),
                "local_captured_at": diagnosticValue(epochSeconds(localSnapshot.capturedAt)),
                "result_primary_percent": diagnosticValue(finalSnapshot.primaryPercent),
                "result_secondary_percent": diagnosticValue(finalSnapshot.secondaryPercent),
                "result_primary_reset_at": diagnosticValue(finalSnapshot.primaryResetsAt),
                "result_secondary_reset_at": diagnosticValue(finalSnapshot.secondaryResetsAt)
            ]
        )
        return result
    }

    private func diagnosticValue<T>(_ value: T?) -> Any {
        value.map { $0 as Any } ?? NSNull()
    }

    private func epochSeconds(_ date: Date?) -> Int? {
        date.map { Int($0.timeIntervalSince1970) }
    }

    private func loadLatestRateLimits(from paths: [String], now: Date) -> LocalRateLimitSelection {
        let snapshots = paths
            .filter { !$0.isEmpty && FileManager.default.fileExists(atPath: $0) }
            .compactMap { readRateLimitSnapshot(from: $0) }
        let sparkQuotaWindows = mergedSparkQuotaWindows(from: snapshots, now: now)
        let primaryCandidates = snapshots.filter { $0.isPrimaryCodexLimit && hasMainRateLimitData($0) }
        let fallbackCandidates = snapshots.filter { hasMainRateLimitData($0) }
        let candidates = primaryCandidates.isEmpty ? fallbackCandidates : primaryCandidates
        let recentCandidates = recentRateLimitCandidates(candidates)
        let decision = selectLocalRateLimitGeneration(from: recentCandidates, now: now)
        let empty = RateLimitSnapshot(
            primaryPercent: nil,
            secondaryPercent: nil,
            primaryResetsAt: nil,
            secondaryResetsAt: nil,
            capturedAt: nil,
            isPrimaryCodexLimit: false,
            sparkQuotaWindows: []
        )
        return LocalRateLimitSelection(
            snapshot: (decision.snapshot ?? empty).withSparkQuotaWindows(sparkQuotaWindows),
            candidateCount: candidates.count,
            recentCandidateCount: recentCandidates.count,
            generationCount: Set(candidates.map(rateLimitGenerationKey)).count,
            recentGenerationCount: Set(recentCandidates.map(rateLimitGenerationKey)).count,
            selectionReason: decision.reason,
            selectedGenerationSupport: decision.support
        )
    }

    private func selectLocalRateLimitGeneration(
        from snapshots: [RateLimitSnapshot],
        now: Date
    ) -> LocalGenerationDecision {
        guard !snapshots.isEmpty else {
            return LocalGenerationDecision(snapshot: nil, reason: "unavailable", support: 0)
        }

        let nowEpoch = Int(now.timeIntervalSince1970)
        let generations = Dictionary(grouping: snapshots, by: rateLimitGenerationKey)
            .compactMap { _, members -> LocalRateLimitGeneration? in
                guard let snapshot = members.max(by: {
                    ($0.capturedAt ?? .distantPast) < ($1.capturedAt ?? .distantPast)
                }) else {
                    return nil
                }
                let activeWindowCount = [snapshot.primaryResetsAt, snapshot.secondaryResetsAt]
                    .compactMap { $0 }
                    .filter { $0 > nowEpoch }
                    .count
                return LocalRateLimitGeneration(
                    snapshot: snapshot,
                    support: members.count,
                    activeWindowCount: activeWindowCount
                )
            }

        guard generations.count > 1 else {
            let generation = generations[0]
            return LocalGenerationDecision(
                snapshot: generation.snapshot,
                reason: "single_generation",
                support: generation.support
            )
        }

        if let newestGeneration = generations.max(by: {
            ($0.snapshot.capturedAt ?? .distantPast) < ($1.snapshot.capturedAt ?? .distantPast)
        }), isWeeklyOnlyMainRateLimit(newestGeneration.snapshot) {
            return LocalGenerationDecision(
                snapshot: newestGeneration.snapshot,
                reason: "latest_weekly_only_topology",
                support: newestGeneration.support
            )
        }

        let maxActiveWindowCount = generations.map(\.activeWindowCount).max() ?? 0
        let activeCandidates = generations.filter { $0.activeWindowCount == maxActiveWindowCount }
        let maxSupport = activeCandidates.map(\.support).max() ?? 0
        let supportedCandidates = activeCandidates.filter { $0.support == maxSupport }
        let selected = supportedCandidates.min {
            isOlderRateLimitGeneration($0.snapshot, $1.snapshot)
        } ?? generations[0]

        let reason: String
        if activeCandidates.count < generations.count {
            reason = "post_reset_generation"
        } else if supportedCandidates.count < activeCandidates.count {
            reason = "majority_future_generation"
        } else {
            reason = "tie_earlier_reset"
        }
        return LocalGenerationDecision(
            snapshot: selected.snapshot,
            reason: reason,
            support: selected.support
        )
    }

    private func recentRateLimitCandidates(_ snapshots: [RateLimitSnapshot]) -> [RateLimitSnapshot] {
        guard let latestCapturedAt = snapshots.compactMap(\.capturedAt).max() else {
            return snapshots
        }
        let recent = snapshots.filter { snapshot in
            guard let capturedAt = snapshot.capturedAt else {
                return false
            }
            return latestCapturedAt.timeIntervalSince(capturedAt) <= UsageScanPolicy.rateLimitCandidateRecencyWindow
        }
        return recent.isEmpty ? snapshots : recent
    }

    private func isOlderRateLimitGeneration(_ lhs: RateLimitSnapshot, _ rhs: RateLimitSnapshot) -> Bool {
        let lhsSecondary = lhs.secondaryResetsAt ?? Int.min
        let rhsSecondary = rhs.secondaryResetsAt ?? Int.min
        if lhsSecondary != rhsSecondary {
            return lhsSecondary < rhsSecondary
        }
        let lhsPrimary = lhs.primaryResetsAt ?? Int.min
        let rhsPrimary = rhs.primaryResetsAt ?? Int.min
        if lhsPrimary != rhsPrimary {
            return lhsPrimary < rhsPrimary
        }
        return (lhs.capturedAt ?? .distantPast) < (rhs.capturedAt ?? .distantPast)
    }

    private func rateLimitGenerationKey(_ snapshot: RateLimitSnapshot) -> String {
        "\(snapshot.primaryResetsAt ?? -1):\(snapshot.secondaryResetsAt ?? -1)"
    }

    private func mergedSparkQuotaWindows(
        from snapshots: [RateLimitSnapshot],
        now: Date = Date(),
        preferSourceOrder: Bool = false
    ) -> [SparkQuotaWindow] {
        let sortedSnapshots = if preferSourceOrder {
            Array(snapshots.enumerated())
        } else {
            snapshots
                .enumerated()
                .sorted {
                    let leftTime = $0.element.capturedAt ?? .distantPast
                    let rightTime = $1.element.capturedAt ?? .distantPast
                    if leftTime != rightTime {
                        return leftTime > rightTime
                    }
                    return $0.offset < $1.offset
                }
        }
        return sortedSnapshots
            .flatMap { snapshots in
                snapshots.element.sparkQuotaWindows
                    .filter { !$0.isExpired(at: now) }
            }
            .deduplicatedSparkQuotaWindows
    }

    private func displaySparkQuotaWindows(_ snapshot: RateLimitSnapshot, now: Date) -> [SparkQuotaWindow] {
        snapshot.sparkQuotaWindows
            .filter { !$0.isExpired(at: now) }
            .map { window in
            SparkQuotaWindow(
                id: window.id,
                label: window.label,
                remainingPercent: window.displayRemainingPercent(now: now),
                usedPercent: window.usedPercent,
                resetAt: window.resetAt,
                resetText: window.resetText
            )
        }
    }

    private func availableAppServerRateLimits(now: Date) -> AvailableAppServerRateLimits? {
        cacheLock.lock()
        let snapshot = appServerRateLimitCache.lastSuccess
        let lastSuccessAt = appServerRateLimitCache.lastSuccessAt
        let failureCount = appServerRateLimitCache.consecutiveFailures
        cacheLock.unlock()

        guard let snapshot, let lastSuccessAt else {
            return nil
        }
        let age = max(0, now.timeIntervalSince(lastSuccessAt))
        guard age <= UsageScanPolicy.appServerStaleGraceTTL else {
            return nil
        }
        let freshness: AppServerCacheFreshness = age < UsageScanPolicy.appServerFreshCacheTTL
            && failureCount == 0
            ? .fresh
            : .stale
        return AvailableAppServerRateLimits(
            snapshot: snapshot,
            freshness: freshness,
            ageSeconds: Int(age.rounded())
        )
    }

    private func fetchAppServerRateLimits(now: Date) throws -> RateLimitSnapshot {
        if let appServerRateLimitLoader {
            return try appServerRateLimitLoader(now)
        }
        guard let appServerExecutable,
              FileManager.default.isExecutableFile(atPath: appServerExecutable) else {
            throw AppServerRateLimitRefreshError.missingExecutable
        }
        let output = try Shell.run(
            "/bin/zsh",
            ["-lc", appServerRateLimitScript(executable: appServerExecutable)],
            timeout: 8
        )
        guard let snapshot = parseAppServerRateLimits(output: output, now: now) else {
            throw AppServerRateLimitRefreshError.parseFailed
        }
        return snapshot
    }

    private func appServerFailureKind(_ error: Error) -> String {
        switch error {
        case ShellError.timedOut:
            "timeout"
        case ShellError.launchFailed:
            "launch_failed"
        case ShellError.nonZeroExit:
            "nonzero_exit"
        case AppServerRateLimitRefreshError.missingExecutable:
            "missing_executable"
        case AppServerRateLimitRefreshError.parseFailed:
            "parse_failed"
        default:
            "unavailable"
        }
    }

    private func loadPersistedAppServerRateLimits() -> PersistedAppServerRateLimitCache? {
        guard let appServerCacheURL,
              let data = try? Data(contentsOf: appServerCacheURL) else {
            return nil
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        guard let persisted = try? decoder.decode(PersistedAppServerRateLimitCache.self, from: data),
              persisted.version == PersistedAppServerRateLimitCache.currentVersion else {
            return nil
        }
        return persisted
    }

    private func persistAppServerRateLimits(_ snapshot: RateLimitSnapshot, savedAt: Date) {
        guard let appServerCacheURL else {
            return
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        let persisted = PersistedAppServerRateLimitCache(
            version: PersistedAppServerRateLimitCache.currentVersion,
            savedAt: savedAt,
            snapshot: snapshot
        )
        guard let data = try? encoder.encode(persisted) else {
            return
        }
        let directory = appServerCacheURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: directory.path
            )
            try data.write(to: appServerCacheURL, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: appServerCacheURL.path
            )
        } catch {
            diagnostics?.record(
                event: "app_server_cache_write",
                correlationID: UUID().uuidString,
                fields: ["outcome": "failure"],
                deduplicate: true
            )
        }
    }

    private func appServerCacheMetrics(now: Date) -> AppServerCacheMetrics {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        let ageSeconds = appServerRateLimitCache.lastSuccessAt.map {
            max(0, Int(now.timeIntervalSince($0).rounded()))
        }
        let state: String
        if let ageSeconds {
            if TimeInterval(ageSeconds) > UsageScanPolicy.appServerStaleGraceTTL {
                state = "expired"
            } else if TimeInterval(ageSeconds) >= UsageScanPolicy.appServerFreshCacheTTL
                        || appServerRateLimitCache.consecutiveFailures > 0 {
                state = "stale"
            } else {
                state = "fresh"
            }
        } else {
            state = "unavailable"
        }
        return AppServerCacheMetrics(
            state: state,
            ageSeconds: ageSeconds,
            consecutiveFailures: appServerRateLimitCache.consecutiveFailures,
            nextRetryAt: appServerRateLimitCache.retryNotBefore,
            hasPendingRebound: appServerRateLimitCache.pendingRebound != nil
        )
    }

    private func appServerRateLimitScript(executable: String) -> String {
        let initialize = #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientInfo":{"name":"codex-notch","version":"0.1.2"},"capabilities":{"experimentalApi":true}}}"#
        let initialized = #"{"jsonrpc":"2.0","method":"initialized"}"#
        let readRateLimits = #"{"jsonrpc":"2.0","id":2,"method":"account/rateLimits/read","params":null}"#

        return """
        {
          printf '%s\\n' '\(initialize)' '\(initialized)' '\(readRateLimits)'
          sleep 5.5
        } | \(shellQuoted(executable)) app-server --stdio
        """
    }

    private func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    func parseAppServerRateLimits(output: String, now: Date) -> RateLimitSnapshot? {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        for line in output.split(separator: "\n", omittingEmptySubsequences: true).reversed() {
            guard line.contains(#""id":2"#),
                  let data = line.data(using: .utf8),
                  let response = try? decoder.decode(AppServerRateLimitResponse.self, from: data),
                  let result = response.result else {
                continue
            }

            let snapshot = result.rateLimitsByLimitId?["codex"] ?? result.rateLimits
            guard isCodexMainRateLimit(snapshot.limitId) else {
                continue
            }

            return RateLimitSnapshot(
                primaryPercent: remainingPercent(fromUsedPercent: snapshot.primary?.usedPercent),
                secondaryPercent: remainingPercent(fromUsedPercent: snapshot.secondary?.usedPercent),
                primaryResetsAt: snapshot.primary?.resetsAt,
                secondaryResetsAt: snapshot.secondary?.resetsAt,
                primaryWindowMinutes: snapshot.primary?.durationMinutes,
                secondaryWindowMinutes: snapshot.secondary?.durationMinutes,
                capturedAt: now,
                isPrimaryCodexLimit: true,
                sparkQuotaWindows: sparkQuotaWindows(from: result.rateLimitsByLimitId ?? [:]),
                resetCredits: resetCreditInventory(from: result.rateLimitResetCredits)
            )
        }

        return nil
    }

    private func resetCreditInventory(
        from source: AppServerResetCreditInventory?
    ) -> ResetCreditInventory? {
        guard let source, let availableCount = source.availableCount else {
            return nil
        }
        let credits = source.credits?.compactMap { credit -> ResetCredit? in
            guard let status = credit.status?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !status.isEmpty else {
                return nil
            }
            return ResetCredit(status: status, expiresAt: credit.expiresAt)
        }
        return ResetCreditInventory(
            reportedAvailableCount: max(0, availableCount),
            credits: credits
        )
    }

    private func sparkQuotaWindows(from snapshotsByLimitID: [String: AppServerRateLimitSnapshot]) -> [SparkQuotaWindow] {
        snapshotsByLimitID
            .sorted { lhs, rhs in lhs.key < rhs.key }
            .flatMap { key, snapshot -> [SparkQuotaWindow] in
                guard let family = modelQuotaFamily(
                    matching: [key, snapshot.limitId, snapshot.limitName],
                    in: Self.exposedModelQuotaFamilies
                ) else {
                    return []
                }
                return modelQuotaWindows(
                    family: family,
                    windowIDPrefix: snapshot.limitId ?? key,
                    primary: modelQuotaWindowSource(snapshot.primary),
                    secondary: modelQuotaWindowSource(snapshot.secondary)
                )
            }
            .deduplicatedSparkQuotaWindows
    }

    private func modelQuotaWindows(
        family: ModelQuotaFamily,
        windowIDPrefix: String,
        primary: ModelQuotaWindowSource?,
        secondary: ModelQuotaWindowSource?
    ) -> [SparkQuotaWindow] {
        family.windows.compactMap { spec in
            let source = switch spec.source {
            case .primary:
                primary
            case .secondary:
                secondary
            }
            return sparkQuotaWindow(
                id: "\(windowIDPrefix)-\(spec.idSuffix)",
                label: spec.label,
                usedPercent: source?.usedPercent,
                resetAt: source?.resetAt,
                resetText: source?.resetText
            )
        }
    }

    private func sparkQuotaWindows(
        primary: [String: Any]?,
        secondary: [String: Any]?
    ) -> [SparkQuotaWindow] {
        modelQuotaWindows(
            family: .spark,
            windowIDPrefix: ModelQuotaFamily.spark.id,
            primary: modelQuotaWindowSource(primary),
            secondary: modelQuotaWindowSource(secondary)
        )
    }

    private func modelQuotaWindowSource(_ window: AppServerRateLimitWindow?) -> ModelQuotaWindowSource? {
        guard let window else {
            return nil
        }
        return ModelQuotaWindowSource(
            usedPercent: Double(window.usedPercent),
            resetAt: window.resetsAt,
            resetText: nil
        )
    }

    private func modelQuotaWindowSource(_ window: [String: Any]?) -> ModelQuotaWindowSource? {
        guard let window else {
            return nil
        }
        return ModelQuotaWindowSource(
            usedPercent: doubleValue(window["used_percent"]),
            resetAt: intValue(window["resets_at"]),
            resetText: stringValue(window["reset_label"])
        )
    }

    private func sparkQuotaWindow(
        id: String,
        label: String,
        usedPercent: Double?,
        resetAt: Int?,
        resetText: String?
    ) -> SparkQuotaWindow? {
        guard usedPercent != nil || resetAt != nil || resetText != nil else {
            return nil
        }
        let used = usedPercent.map { min(100, max(0, $0)) }
        let remaining = used.map { Int((100 - $0).rounded()) }
        return SparkQuotaWindow(
            id: id,
            label: label,
            remainingPercent: remaining,
            usedPercent: used,
            resetAt: resetAt,
            resetText: resetText
        )
    }

    private func modelQuotaFamily(matching values: [String?], in families: [ModelQuotaFamily]) -> ModelQuotaFamily? {
        families.first { $0.matches(values) }
    }

    private func readRateLimitSnapshot(from rolloutPath: String) -> RateLimitSnapshot? {
        let signature = fileSignature(rolloutPath)
        guard signature.exists else {
            return nil
        }
        let cacheKey = signature.path

        cacheLock.lock()
        let cached = sessionRateLimitCache[cacheKey]
        cacheLock.unlock()
        if let cached, cached.signature == signature {
            return cached.snapshot
        }

        let snapshot = scanRateLimitSnapshot(from: rolloutPath)
        cacheLock.lock()
        sessionRateLimitCache[cacheKey] = SessionRateLimitCache(
            signature: signature,
            snapshot: snapshot
        )
        sessionFileCacheCounters.rateLimitScans += 1
        cacheLock.unlock()
        return snapshot
    }

    private func scanRateLimitSnapshot(from rolloutPath: String) -> RateLimitSnapshot? {
        guard let output = tokenCountLines(from: rolloutPath, lineLimit: 600) else {
            return nil
        }

        let meta = sessionMeta(from: rolloutPath)
        let runtime = sessionRuntimeInfo(from: rolloutPath)
        let isSubagentSession = meta?.isSubagent == true
        let isSparkRuntime = modelQuotaFamily(
            matching: [runtime?.model],
            in: Self.exposedModelQuotaFamilies
        ) != nil
        let lines = output.split(separator: "\n", omittingEmptySubsequences: true).reversed()
        for line in lines {
            guard line.contains("\"token_count\""),
                  let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let timestamp = object["timestamp"] as? String,
                  let capturedAt = parseTimestamp(timestamp),
                  let payload = object["payload"] as? [String: Any],
                  payload["type"] as? String == "token_count",
                  let rateLimits = payload["rate_limits"] as? [String: Any] else {
                continue
            }

            let limitID = stringValue(rateLimits["limit_id"])
            let limitName = stringValue(rateLimits["limit_name"])
            let primary = rateLimits["primary"] as? [String: Any]
            let secondary = rateLimits["secondary"] as? [String: Any]
            let primaryPercent = remainingPercent(fromUsedPercent: primary?["used_percent"])
            let secondaryPercent = remainingPercent(fromUsedPercent: secondary?["used_percent"])
            let primaryResetsAt = intValue(primary?["resets_at"])
            let secondaryResetsAt = intValue(secondary?["resets_at"])
            let primaryWindowMinutes = intValue(primary?["window_minutes"])
                ?? intValue(primary?["window_duration_mins"])
            let secondaryWindowMinutes = intValue(secondary?["window_minutes"])
                ?? intValue(secondary?["window_duration_mins"])
            let sparkFamily = modelQuotaFamily(
                matching: [limitID, limitName, runtime?.model],
                in: Self.exposedModelQuotaFamilies
            )
            let isMainCodexLimit = isCodexMainRateLimit(limitID)
                && !isSubagentSession
                && !isSparkRuntime
            let sparkWindows = sparkFamily != nil
                ? sparkQuotaWindows(
                    primary: primary,
                    secondary: secondary
                )
                : []

            if isMainCodexLimit || !sparkWindows.isEmpty {
                return RateLimitSnapshot(
                    primaryPercent: isMainCodexLimit ? primaryPercent : nil,
                    secondaryPercent: isMainCodexLimit ? secondaryPercent : nil,
                    primaryResetsAt: isMainCodexLimit ? primaryResetsAt : nil,
                    secondaryResetsAt: isMainCodexLimit ? secondaryResetsAt : nil,
                    primaryWindowMinutes: isMainCodexLimit ? primaryWindowMinutes : nil,
                    secondaryWindowMinutes: isMainCodexLimit ? secondaryWindowMinutes : nil,
                    capturedAt: capturedAt,
                    isPrimaryCodexLimit: isMainCodexLimit,
                    sparkQuotaWindows: sparkWindows
                )
            }
        }

        return nil
    }

    private func extractTokenCount(from text: String) -> Int? {
        guard let match = text.firstMatch(of: tokenPattern) else {
            return nil
        }
        return Int(match.1)
    }

    private func tokenCountLines(from rolloutPath: String, lineLimit: Int) -> String? {
        guard FileManager.default.fileExists(atPath: rolloutPath) else {
            return nil
        }

        do {
            let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: rolloutPath))
            defer {
                try? handle.close()
            }

            let fileSize = try handle.seekToEnd()
            let bytesPerLine = UsageScanPolicy.estimatedTokenLineBytes
            let maxBytes = min(fileSize, UInt64(lineLimit) * bytesPerLine)
            try handle.seek(toOffset: fileSize - maxBytes)
            let data = try handle.readToEnd() ?? Data()
            let text = String(decoding: data, as: UTF8.self)
            let lines = text
                .split(separator: "\n", omittingEmptySubsequences: true)
                .filter { $0.contains("\"token_count\"") }
                .suffix(lineLimit)

            return lines.joined(separator: "\n")
        } catch {
            return nil
        }
    }

    private func contextUsage(for rolloutPath: String) -> (usage: TokenContextUsage?, didScan: Bool) {
        guard !rolloutPath.isEmpty else {
            return (nil, false)
        }

        let signature = fileSignature(rolloutPath)
        guard signature.exists else {
            return (nil, false)
        }
        let cacheKey = signature.path
        cacheLock.lock()
        let cached = sessionContextUsageCache[cacheKey]
        cacheLock.unlock()

        if let cached, cached.signature == signature {
            return (cached.usage, false)
        }

        let usage = scanContextUsage(from: rolloutPath)
        cacheLock.lock()
        sessionContextUsageCache[cacheKey] = SessionContextUsageCache(signature: signature, usage: usage)
        cacheLock.unlock()
        return (usage, true)
    }

    private func scanContextUsage(from rolloutPath: String) -> TokenContextUsage? {
        guard let output = tokenCountLines(
            from: rolloutPath,
            lineLimit: UsageScanPolicy.contextUsageTailLineLimit
        ) else {
            return nil
        }

        let lines = output.split(separator: "\n", omittingEmptySubsequences: true).reversed()
        for line in lines {
            guard let usage = TokenContextUsageParser.parse(line: String(line)) else {
                continue
            }
            return usage
        }

        return nil
    }

    private func parseTokenCountEvent(_ line: String) -> (date: Date, tokens: Int)? {
        if lineContainsTokenCountPayload(line),
           let timestamp = fastJSONStringValue(for: "timestamp", in: line),
           let date = parseTimestamp(timestamp),
           let tokens = fastLastTokenUsageTotal(in: line) {
            return (date, tokens)
        }

        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let timestamp = object["timestamp"] as? String,
              let date = parseTimestamp(timestamp),
              let payload = object["payload"] as? [String: Any],
              payload["type"] as? String == "token_count",
              let info = payload["info"] as? [String: Any],
              let lastUsage = info["last_token_usage"] as? [String: Any],
              let tokens = intValue(lastUsage["total_tokens"]) else {
            return nil
        }

        return (date, tokens)
    }

    private func lineContainsTokenCountPayload(_ line: String) -> Bool {
        line.contains(#""type":"token_count""#)
            || line.contains(#""type": "token_count""#)
            || line.contains(#""type" : "token_count""#)
    }

    private func fastLastTokenUsageTotal(in line: String) -> Int? {
        guard let usageRange = line.range(of: #""last_token_usage""#),
              let tokenRange = line[usageRange.upperBound...].range(of: #""total_tokens""#),
              let colonRange = line[tokenRange.upperBound...].range(of: ":") else {
            return nil
        }

        var index = colonRange.upperBound
        while index < line.endIndex, line[index].isWhitespace {
            index = line.index(after: index)
        }

        let start = index
        while index < line.endIndex, line[index].isNumber {
            index = line.index(after: index)
        }

        guard start < index else {
            return nil
        }
        return Int(line[start..<index])
    }

    private func fastJSONStringValue(for key: String, in line: String) -> String? {
        guard let keyRange = line.range(of: #"""# + key + #"""#),
              let colonRange = line[keyRange.upperBound...].range(of: ":"),
              let quoteStart = line[colonRange.upperBound...].firstIndex(of: "\"") else {
            return nil
        }

        var index = line.index(after: quoteStart)
        var value = ""
        var isEscaped = false

        while index < line.endIndex {
            let character = line[index]
            if isEscaped {
                value.append(character)
                isEscaped = false
            } else if character == "\\" {
                isEscaped = true
            } else if character == "\"" {
                return value
            } else {
                value.append(character)
            }
            index = line.index(after: index)
        }

        return nil
    }

    private func parseTimestamp(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) {
            return date
        }

        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    private func makeUsageSignature(for rolloutPaths: [String]) -> StoreSignature? {
        let databasePaths = sqliteFileSet(stateDatabase) + sqliteFileSet(logsDatabase) + [sessionIndexPath]
        let paths = databasePaths + rolloutPaths.filter { !$0.isEmpty }
        guard !paths.isEmpty else {
            return nil
        }

        return StoreSignature(files: paths.map(fileSignature).sorted { $0.path < $1.path })
    }

    private func makeSignature(for rolloutPaths: [String]) -> StoreSignature? {
        let databasePaths = sqliteFileSet(stateDatabase) + sqliteFileSet(logsDatabase) + [sessionIndexPath]
        let paths = databasePaths + rolloutPaths.filter { !$0.isEmpty }
        guard !paths.isEmpty else {
            return nil
        }

        return StoreSignature(files: paths.map(fileSignature).sorted { $0.path < $1.path })
    }

    private func sqliteFileSet(_ database: String) -> [String] {
        [
            database,
            "\(database)-wal",
            "\(database)-shm"
        ]
    }

    private func fileSignature(_ path: String) -> FileSignature {
        let canonicalPath = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        var fileInfo = stat()
        let status = canonicalPath.withCString { pointer in
            Darwin.lstat(pointer, &fileInfo)
        }
        guard status == 0 else {
            return FileSignature(
                path: canonicalPath,
                exists: false,
                inode: 0,
                size: 0,
                modifiedAtNanoseconds: 0,
                directoryFingerprint: 0
            )
        }

        let size = fileInfo.st_size > 0 ? UInt64(fileInfo.st_size) : 0
        let modifiedAtNanoseconds = Int64(fileInfo.st_mtimespec.tv_sec) * 1_000_000_000
            + Int64(fileInfo.st_mtimespec.tv_nsec)
        let isDirectory = (fileInfo.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR)
        return FileSignature(
            path: canonicalPath,
            exists: true,
            inode: UInt64(fileInfo.st_ino),
            size: size,
            modifiedAtNanoseconds: modifiedAtNanoseconds,
            directoryFingerprint: isDirectory ? directoryFingerprint(canonicalPath) : 0
        )
    }

    private func directoryFingerprint(_ path: String) -> UInt64 {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: path) else {
            return 0
        }

        return entries.sorted().reduce(UInt64(1_469_598_103_934_665_603)) { partial, entry in
            entry.utf8.reduce(partial) { hash, byte in
                (hash ^ UInt64(byte)) &* 1_099_511_628_211
            } ^ 0xff
        }
    }

    private func sqliteLiteral(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "''"))'"
    }

    private func intValue(_ value: Any?) -> Int? {
        if let int = value as? Int {
            return int
        }
        if let double = value as? Double {
            return Int(double.rounded())
        }
        if let number = value as? NSNumber {
            return number.intValue
        }
        return nil
    }

    private func stringValue(_ value: Any?) -> String? {
        guard let string = value as? String else {
            return nil
        }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func doubleValue(_ value: Any?) -> Double? {
        if let double = value as? Double {
            return double
        }
        if let int = value as? Int {
            return Double(int)
        }
        if let number = value as? NSNumber {
            return number.doubleValue
        }
        if let string = value as? String {
            return Double(string.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }

    private func remainingPercent(fromUsedPercent value: Any?) -> Int? {
        guard let usedPercent = intValue(value) else {
            return nil
        }
        return min(100, max(0, 100 - usedPercent))
    }

    private func isCodexMainRateLimit(_ value: String?) -> Bool {
        value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: "-")
            .lowercased() == "codex"
    }

    private func elapsedMilliseconds(since start: Date) -> Int {
        max(0, Int((Date().timeIntervalSince(start) * 1_000).rounded()))
    }
}

private struct FastSnapshotCache {
    let createdAt: Date
    let signature: StoreSignature
    let rolloutPaths: [String]
    let threads: [ThreadRecord]
    let usageThreads: [ThreadRecord]
    let activeThreadIDs: Set<String>
    let rateLimits: RateLimitSnapshot
    let periodUsage: PeriodUsage
    let periodUsageQuality: PeriodUsageQuality
    let dailyUsage: DailyUsage
    let rateLimitSourceName: String
    let rateLimitSource: RateLimitSourcePreference
    let taskHistoryRange: TaskHistoryRange
}

private struct RateLimitLoadResult {
    let snapshot: RateLimitSnapshot
    let source: String
}

private struct BuildTasksResult {
    let tasks: [CodexTask]
    let contextScans: Int
}

private struct CumulativeUsageRecord: Decodable {
    let activeTokens: Int
    let archivedTokens: Int
    let allTokens: Int
    let activeSessions: Int
    let archivedSessions: Int
    let allSessions: Int

    enum CodingKeys: String, CodingKey {
        case activeTokens = "active_tokens"
        case archivedTokens = "archived_tokens"
        case allTokens = "all_tokens"
        case activeSessions = "active_sessions"
        case archivedSessions = "archived_sessions"
        case allSessions = "all_sessions"
    }
}

private struct RecentUsageRecord: Decodable {
    let usage20dActiveTokens: Int
    let usage20dArchivedTokens: Int
    let usage20dAllTokens: Int
    let usage20dActiveSessions: Int
    let usage20dArchivedSessions: Int
    let usage20dAllSessions: Int

    enum CodingKeys: String, CodingKey {
        case usage20dActiveTokens = "usage_20d_active_tokens"
        case usage20dArchivedTokens = "usage_20d_archived_tokens"
        case usage20dAllTokens = "usage_20d_all_tokens"
        case usage20dActiveSessions = "usage_20d_active_sessions"
        case usage20dArchivedSessions = "usage_20d_archived_sessions"
        case usage20dAllSessions = "usage_20d_all_sessions"
    }
}

private struct PeriodUsageRecord: Decodable {
    let day: Int
    let week: Int
    let month: Int
}

private struct PeriodUsageResult {
    let usage: PeriodUsage
    let quality: PeriodUsageQuality
}

private struct RollingDeltaRecord: Decodable {
    let threadId: String
    let tokensUsed: Int
    let createdAtMs: Int64
    let baseline10m: Int?
    let baseline1h: Int?
    let baseline24h: Int?
    let baseline7d: Int?
    let baseline30d: Int?
    let baselineToday: Int?

    enum CodingKeys: String, CodingKey {
        case threadId = "thread_id"
        case tokensUsed = "tokens_used"
        case createdAtMs = "created_at_ms"
        case baseline10m = "baseline_10m"
        case baseline1h = "baseline_1h"
        case baseline24h = "baseline_24h"
        case baseline7d = "baseline_7d"
        case baseline30d = "baseline_30d"
        case baselineToday = "baseline_today"
    }
}

private struct RecentPathsCache {
    let createdAt: Date
    let paths: [String]
    let collectedLimit: Int
}

private struct SessionTokenTotalCache {
    let signature: FileSignature
    let bytesScanned: UInt64
    let tokens: Int
    let pendingLine: String
    let foundTokenEvent: Bool
}

private struct SessionContextUsageCache {
    let signature: FileSignature
    let usage: TokenContextUsage?
}

struct SessionFileCacheStats {
    let prefixScans: Int
    let rateLimitScans: Int
    let activityScans: Int
    let fastSnapshotHits: Int
    let entryCount: Int
}

private struct SessionFileCacheCounters {
    var prefixScans = 0
    var rateLimitScans = 0
    var activityScans = 0
    var fastSnapshotHits = 0
}

private struct SessionPrefixFacts {
    let meta: SessionMetaInfo?
    let runtime: SessionRuntimeInfo?
    let title: String?
}

private struct SessionPrefixFactsCache {
    let signature: FileSignature
    let scannedBytes: UInt64
    let facts: SessionPrefixFacts
}

private struct SessionRateLimitCache {
    let signature: FileSignature
    let snapshot: RateLimitSnapshot?
}

private struct SessionActivityCache {
    let signature: FileSignature
    let latestActivity: Date?
    let latestDone: Date?
    let readSucceeded: Bool
}

private struct TokenDeltaWindow {
    let delta10mTokens: Int?
    let delta1hTokens: Int?
    let delta24hTokens: Int?
    let deltaTodayTokens: Int?

    init(delta10mTokens: Int?, delta1hTokens: Int?, delta24hTokens: Int? = nil, deltaTodayTokens: Int? = nil) {
        self.delta10mTokens = delta10mTokens
        self.delta1hTokens = delta1hTokens
        self.delta24hTokens = delta24hTokens
        self.deltaTodayTokens = deltaTodayTokens
    }
}

private struct TokenDeltaRecord: Decodable {
    let threadId: String
    let delta10mTokens: Int?
    let delta1hTokens: Int?
    let delta24hTokens: Int?

    enum CodingKeys: String, CodingKey {
        case threadId = "thread_id"
        case delta10mTokens = "delta_10m_tokens"
        case delta1hTokens = "delta_1h_tokens"
        case delta24hTokens = "delta_24h_tokens"
    }
}

private struct TokenDeltaAggregateRecord: Decodable {
    let delta10mTokens: Int?
    let delta1hTokens: Int?

    enum CodingKeys: String, CodingKey {
        case delta10mTokens = "delta_10m_tokens"
        case delta1hTokens = "delta_1h_tokens"
    }
}

private struct SQLiteNameRecord: Decodable {
    let name: String
}

private struct DeltaCacheMetadataRecord: Decodable {
    let value: Int64
}

private struct SessionTokenScanResult {
    let bytesScanned: UInt64
    let tokens: Int
    let pendingLine: String
    let foundTokenEvent: Bool
}

private struct RecentSessionCandidate {
    let path: String
    let sessionID: String
    let modifiedAt: Date
    let updatedAt: Int
    let databaseTokens: Int
}

private struct AppServerRateLimitCache {
    var lastSuccess: RateLimitSnapshot?
    var lastSuccessAt: Date?
    var lastAttemptAt: Date?
    var consecutiveFailures = 0
    var retryNotBefore: Date?
    var pendingRebound: RateLimitSnapshot?
    var isRefreshing = false
}

private struct PersistedAppServerRateLimitCache: Codable {
    static let currentVersion = 2

    let version: Int
    let savedAt: Date
    let snapshot: RateLimitSnapshot
}

private struct AppServerCacheMetrics {
    let state: String
    let ageSeconds: Int?
    let consecutiveFailures: Int
    let nextRetryAt: Date?
    let hasPendingRebound: Bool
}

private enum AppServerRateLimitRefreshError: Error {
    case missingExecutable
    case parseFailed
}

private struct PeriodUsageCache {
    let createdAt: Date
    let signature: StoreSignature
    let usage: PeriodUsage
}

private struct SessionMetaInfo {
    let isSubagent: Bool
    let parentThreadID: String?
}

private struct SessionRuntimeInfo {
    let model: String?
    let reasoningEffort: String?
}

private struct AppServerRateLimitResponse: Decodable {
    let id: Int?
    let result: AppServerRateLimitResult?
}

private struct AppServerRateLimitResult: Decodable {
    let rateLimits: AppServerRateLimitSnapshot
    let rateLimitsByLimitId: [String: AppServerRateLimitSnapshot]?
    let rateLimitResetCredits: AppServerResetCreditInventory?
}

private struct AppServerResetCreditInventory: Decodable {
    let availableCount: Int?
    let credits: [AppServerResetCredit]?
}

private struct AppServerResetCredit: Decodable {
    let status: String?
    let expiresAt: Int?
}

private struct AppServerRateLimitSnapshot: Decodable {
    let limitId: String?
    let limitName: String?
    let primary: AppServerRateLimitWindow?
    let secondary: AppServerRateLimitWindow?
}

private struct AppServerRateLimitWindow: Decodable {
    let usedPercent: Int
    let resetsAt: Int?
    let windowDurationMins: Int?
    let windowMinutes: Int?

    var durationMinutes: Int? {
        windowDurationMins ?? windowMinutes
    }
}

private struct StoreSignature: Equatable {
    let files: [FileSignature]
}

private struct FileSignature: Equatable {
    let path: String
    let exists: Bool
    let inode: UInt64
    let size: UInt64
    let modifiedAtNanoseconds: Int64
    let directoryFingerprint: UInt64
}
