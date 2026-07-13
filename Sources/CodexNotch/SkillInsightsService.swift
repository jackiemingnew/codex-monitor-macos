import Foundation

final class SkillInsightsService: @unchecked Sendable {
    private let catalogLoader: SkillCatalogLoader
    private let observationStore: SkillObservationStore
    private let analyzer: SkillSessionAnalyzer
    private let automaticDeferralReason: @Sendable () -> String?
    private let catalogLock = NSLock()
    private let automaticAttemptLock = NSLock()
    private var cachedCatalog: SkillCatalogSnapshot?
    private var lastAutomaticAttemptAt: Date?
    private static let automaticInterval: TimeInterval = 7 * 24 * 60 * 60

    init(
        codexDirectory: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex"),
        configURL: URL? = nil,
        skillRoots: [URL]? = nil,
        databaseURL: URL = SkillObservationStore.defaultDatabaseURL(),
        maxRowBytes: Int = 256 * 1024,
        maxBytesPerFilePerRun: UInt64 = 256 * 1024 * 1024,
        maxBytesPerRun: UInt64 = 2 * 1024 * 1024 * 1024,
        maxWallTime: TimeInterval = 30,
        maxCPUTime: TimeInterval = 15,
        automaticDeferralReason: @escaping @Sendable () -> String? = SkillInsightsService.systemDeferralReason
    ) {
        let store = SkillObservationStore(databaseURL: databaseURL)
        catalogLoader = SkillCatalogLoader(
            codexDirectory: codexDirectory,
            configURL: configURL,
            skillRoots: skillRoots
        )
        observationStore = store
        self.automaticDeferralReason = automaticDeferralReason
        analyzer = SkillSessionAnalyzer(
            codexDirectory: codexDirectory,
            observationStore: store,
            maxRowBytes: maxRowBytes,
            maxBytesPerFilePerRun: maxBytesPerFilePerRun,
            maxBytesPerRun: maxBytesPerRun,
            maxWallTime: maxWallTime,
            maxCPUTime: maxCPUTime
        )
    }

    func currentSnapshot(now: Date = Date()) -> SkillInsightsSnapshot {
        observationStore.buildSnapshot(catalog: catalog(now: now, refresh: false), now: now)
    }

    func analyzeRecentWeek(
        force: Bool,
        automatic: Bool,
        now: Date = Date(),
        shouldCancel: @escaping @Sendable () -> Bool = { false }
    ) -> SkillInsightsSnapshot {
        if automatic, !observationStore.shouldRunAutomatically(now: now) {
            return currentSnapshot(now: now)
        }
        if automatic {
            automaticAttemptLock.lock()
            lastAutomaticAttemptAt = now
            automaticAttemptLock.unlock()
        }

        if automatic, let reason = automaticDeferralReason() {
            do {
                try observationStore.markAutomaticDeferral(at: now, reason: reason)
            } catch {
                return observationStore.buildSnapshot(
                    catalog: cachedCatalogForDeferredAttempt(now: now),
                    now: now,
                    extraDiagnostics: ["Automatic Skill analysis was deferred, but the schedule marker could not be persisted."]
                )
            }
            return observationStore.buildSnapshot(
                catalog: cachedCatalogForDeferredAttempt(now: now),
                now: now,
                extraDiagnostics: ["Automatic Skill analysis was deferred: \(reason)."]
            )
        }

        var scheduleDiagnostics: [String] = []
        if automatic {
            do {
                try observationStore.markAutomaticRun(at: now)
            } catch {
                scheduleDiagnostics.append("The weekly automatic Skill schedule marker could not be persisted.")
            }
        }
        let catalog = catalog(now: now, refresh: true)
        let outcome = analyzer.analyze(
            catalog: catalog,
            now: now,
            force: force,
            shouldCancel: shouldCancel
        )
        var diagnostics = outcome.diagnostics + scheduleDiagnostics
        do {
            try observationStore.recordRun(outcome.performance, quality: outcome.quality)
        } catch {
            diagnostics.append("The derived Skill observation database could not persist the completed run.")
        }
        do {
            try observationStore.enforceRetention(now: now)
        } catch {
            diagnostics.append("The weekly Skill observation retention cleanup could not complete.")
        }
        return observationStore.buildSnapshot(
            catalog: catalog,
            now: now,
            extraDiagnostics: diagnostics
        )
    }

    func nextAutomaticRunDate(now: Date = Date()) -> Date {
        let persisted = observationStore.nextAutomaticRunDate(now: now)
        automaticAttemptLock.lock()
        let inMemory = lastAutomaticAttemptAt?.addingTimeInterval(Self.automaticInterval)
        automaticAttemptLock.unlock()
        guard let inMemory else { return persisted }
        return persisted > inMemory ? persisted : inMemory
    }

    func export(_ snapshot: SkillInsightsSnapshot, format: SkillInsightExportFormat) throws -> Data {
        switch format {
        case .markdown:
            return Data(SkillInsightsReportRenderer.markdown(snapshot).utf8)
        case .json:
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            encoder.dateEncodingStrategy = .iso8601
            return try encoder.encode(snapshot)
        }
    }

    private func catalog(now: Date, refresh: Bool) -> SkillCatalogSnapshot {
        catalogLock.lock()
        defer { catalogLock.unlock() }
        if !refresh, let cachedCatalog {
            return cachedCatalog
        }
        let loaded = catalogLoader.load(now: now, forceReload: refresh)
        cachedCatalog = loaded
        return loaded
    }

    private func cachedCatalogForDeferredAttempt(now: Date) -> SkillCatalogSnapshot {
        catalogLock.lock()
        defer { catalogLock.unlock() }
        if let cachedCatalog {
            return cachedCatalog
        }
        return SkillCatalogSnapshot(
            skills: [],
            quality: .unavailable,
            diagnostics: ["Skill catalog loading was skipped with the deferred automatic analysis."],
            loadedAt: now
        )
    }

    private static func systemDeferralReason() -> String? {
        let processInfo = ProcessInfo.processInfo
        if processInfo.isLowPowerModeEnabled {
            return "Low Power Mode is enabled"
        }
        switch processInfo.thermalState {
        case .serious, .critical:
            return "the Mac thermal state is \(processInfo.thermalState == .critical ? "critical" : "serious")"
        case .nominal, .fair:
            return nil
        @unknown default:
            return "the Mac thermal state is unavailable"
        }
    }
}

enum SkillInsightsReportRenderer {
    static func markdown(_ snapshot: SkillInsightsSnapshot) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let period = "\(formatter.string(from: snapshot.windowStartedAt)) — \(formatter.string(from: snapshot.windowEndedAt))"
        let lastAnalyzed = snapshot.lastAnalyzedAt.map(formatter.string(from:)) ?? "UNAVAILABLE"

        var lines = [
            "# Codex Monitor Skill Insights",
            "",
            "- Observation period: \(period)",
            "- Data quality: \(snapshot.quality.rawValue)",
            "- Last analyzed: \(lastAnalyzed)",
            "- Enabled / disabled Skills: \(snapshot.enabledSkillCount) / \(snapshot.disabledSkillCount)",
            "- Enabled catalog/context cost: ~\(snapshot.enabledCatalogTokenEstimate) Token",
            "- Per-Skill Token: UNAVAILABLE",
            "",
            "## 1. Observation period and completeness",
            "",
            "Candidate files: \(snapshot.performance.candidateFiles); analyzed: \(snapshot.performance.analyzedFiles); pending: \(snapshot.performance.pendingFiles); partial: \(snapshot.performance.partialFiles); parsed/filtered rows: \(snapshot.performance.parsedRows)/\(snapshot.performance.filteredRows); logical JSONL bytes: \(snapshot.performance.analyzedBytes); CPU: \(snapshot.performance.cpuMilliseconds) ms; database: \(snapshot.performance.databaseDurationMilliseconds) ms; duration: \(snapshot.performance.durationMilliseconds) ms; model Token: 0.",
            "",
            "## 2. Most-used Skills",
            ""
        ]
        appendRows(
            snapshot.rows.filter { $0.confirmedUseCount > 0 }.sorted { $0.confirmedUseCount > $1.confirmedUseCount },
            to: &lines,
            value: { "DIRECT \($0.directCount), STRONG \($0.strongCount), related Sessions \($0.relatedSessionCount), related Session Token \($0.relatedSessionTokens)" }
        )

        lines.append(contentsOf: ["", "## 3. Should-trigger but possibly missed", ""])
        appendRows(
            snapshot.rows.filter { $0.suspectedMissCount > 0 },
            to: &lines,
            value: { "suspected misses \($0.suspectedMissCount)" }
        )

        lines.append(contentsOf: ["", "## 4. Suspected misfires", ""])
        appendRows(
            snapshot.rows.filter { $0.suspectedMisfireCount > 0 },
            to: &lines,
            value: { "suspected misfires \($0.suspectedMisfireCount)" }
        )

        lines.append(contentsOf: ["", "## 5. Disabled Skill SHADOW matches", ""])
        appendRows(
            snapshot.rows.filter { $0.shadowCount > 0 },
            to: &lines,
            value: { "SHADOW \($0.shadowCount)" }
        )

        lines.append(contentsOf: ["", "## 6. Candidates replaced by existing capability", ""])
        appendRows(
            snapshot.rows.filter { $0.replacedByExistingCount > 0 },
            to: &lines,
            value: { "replacement observations \($0.replacedByExistingCount)" }
        )

        lines.append(contentsOf: ["", "## 7. Suggested sampling and retest", ""])
        appendRows(
            snapshot.rows.filter { $0.recommendation == .retest || $0.recommendation == .restoreCandidate },
            to: &lines,
            value: { $0.recommendation.rawValue }
        )

        lines.append(contentsOf: ["", "## 8. Conclusions", ""])
        for recommendation in [
            SkillRecommendation.keep,
            .continueDisabled,
            .retest,
            .restoreCandidate
        ] {
            let names = snapshot.rows.filter { $0.recommendation == recommendation }.map { $0.skill.name }
            lines.append("- \(recommendation.rawValue): \(names.isEmpty ? "None" : names.joined(separator: ", "))")
        }

        lines.append(contentsOf: ["", "## 9. UNVERIFIED", ""])
        if snapshot.unverified.isEmpty {
            lines.append("- None")
        } else {
            lines.append(contentsOf: snapshot.unverified.map { "- \($0)" })
        }

        if !snapshot.diagnostics.isEmpty {
            lines.append(contentsOf: ["", "## Diagnostics", ""])
            lines.append(contentsOf: snapshot.diagnostics.map { "- \($0)" })
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func appendRows(
        _ rows: [SkillInsightRow],
        to lines: inout [String],
        value: (SkillInsightRow) -> String
    ) {
        if rows.isEmpty {
            lines.append("- None")
            return
        }
        lines.append(contentsOf: rows.map { row in
            "- `\(row.skill.name)` (`\(row.skill.path)`): \(value(row)); evidence quality \(row.evidenceQuality.rawValue)."
        })
    }
}
