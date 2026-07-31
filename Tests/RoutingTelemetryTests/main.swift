import Foundation
import SQLite3

@main
struct RoutingTelemetryTests {
    static func main() {
        var failures: [String] = []
        func check(_ condition: @autoclosure () -> Bool, _ message: String) { if !condition() { failures.append(message) } }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("routing-telemetry-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("state.sqlite")
        let derived = root.appendingPathComponent("routing.sqlite")
        let now = Date(timeIntervalSince1970: 1_784_160_000) // 2026-07-30 local-ish fixture instant

        let missing = RoutingTelemetryStore(sourceURL: source, databaseURL: derived)
        do { _ = try missing.lightScan(now: now); check(false, "missing schema must fail closed") }
        catch RoutingTelemetryStoreError.sourceUnavailable { }
        catch { check(false, "missing DB should report source unavailable") }
        let presentationOnly = root.appendingPathComponent("presentation-only.sqlite")
        check(
            RoutingTelemetryStore(sourceURL: source, databaseURL: presentationOnly).loadPublished() == .empty
                && !FileManager.default.fileExists(atPath: presentationOnly.path),
            "presentation load must not create a derived database"
        )

        let missingEdgeSource = root.appendingPathComponent("missing-edge.sqlite")
        var missingEdgeDB: OpaquePointer?
        check(sqlite3_open(missingEdgeSource.path, &missingEdgeDB) == SQLITE_OK, "missing-edge fixture should open")
        exec(missingEdgeDB, "CREATE TABLE threads(id TEXT, recency_at_ms INTEGER);")
        sqlite3_close(missingEdgeDB)
        do {
            _ = try RoutingTelemetryStore(sourceURL: missingEdgeSource, databaseURL: root.appendingPathComponent("missing-edge-derived.sqlite")).lightScan(now: now)
            check(false, "missing edge table must fail closed")
        } catch RoutingTelemetryStoreError.schemaUnavailable { }
        catch { check(false, "missing edge table should report schema unavailable") }

        let stateDirectory = root.appendingPathComponent("states", isDirectory: true)
        try! FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: stateDirectory.appendingPathComponent("state_2.sqlite").path, contents: Data())
        FileManager.default.createFile(atPath: stateDirectory.appendingPathComponent("state_10.sqlite").path, contents: Data())
        FileManager.default.createFile(atPath: stateDirectory.appendingPathComponent("state_misc.sqlite").path, contents: Data())
        check(RoutingTelemetryStore.defaultStateDatabaseURL(codexDirectory: stateDirectory).lastPathComponent == "state_10.sqlite", "highest numeric state DB must win")

        var db: OpaquePointer?
        check(sqlite3_open(source.path, &db) == SQLITE_OK, "fixture source should open")
        defer { sqlite3_close(db) }
        exec(db, "CREATE TABLE threads(id TEXT, recency_at_ms INTEGER, created_at_ms INTEGER, updated_at_ms INTEGER, tokens_used INTEGER, role TEXT, model TEXT, reasoning_effort TEXT, title TEXT, rollout_path TEXT);")
        exec(db, "CREATE TABLE thread_spawn_edges(parent_thread_id TEXT, child_thread_id TEXT);")
        let t = Int64(now.timeIntervalSince1970 * 1000)
        exec(db, "INSERT INTO threads VALUES ('root-sensitive-id', \(t), \(t-1000), \(t), 100, 'orchestrator', 'gpt-5.6-sol', 'high', 'very private title', '/private/rollout.jsonl');")
        exec(db, "INSERT INTO threads VALUES ('child-a', \(t), \(t-800), \(t), 50, 'terra-implementer', 'gpt-5.6-terra', 'medium', 'do not persist', '/secret');")
        exec(db, "INSERT INTO threads VALUES ('child-sol', \(t), \(t-700), \(t), 30, 'unregistered-secret-role', 'gpt-5.6-sol', NULL, 'do not persist', '/secret');")
        exec(db, "INSERT INTO threads VALUES ('grandchild', \(t), \(t-600), \(t), 20, 'code-explorer', 'gpt-5.6-terra', 'high', 'do not persist', '/secret');")
        exec(db, "INSERT INTO threads VALUES ('zero-span', \(t), \(t), \(t), 0, 'orchestrator', 'gpt-5.6-sol', 'high', 'do not persist', '/secret');")
        exec(db, "INSERT INTO threads VALUES ('old-parent', \(t-3_456_000_000), \(t-3_456_001_000), \(t-3_456_000_000), 1, 'orchestrator', 'gpt-5.6-sol', 'high', 'do not persist', '/secret');")
        exec(db, "INSERT INTO thread_spawn_edges VALUES ('root-sensitive-id','child-a'); INSERT INTO thread_spawn_edges VALUES ('root-sensitive-id','child-sol'); INSERT INTO thread_spawn_edges VALUES ('child-a','grandchild'); INSERT INTO thread_spawn_edges VALUES ('gone-parent','child-a'); INSERT INTO thread_spawn_edges VALUES ('old-parent','child-sol'); INSERT INTO thread_spawn_edges VALUES ('root-sensitive-id','gone-child');")
        sqlite3_close(db); db = nil

        let store = RoutingTelemetryStore(sourceURL: source, databaseURL: derived)
        let first = try! store.lightScan(now: now)
        let firstMetric = first.days.last!
        check(firstMetric.depthAtLeastTwo == 1, "grandchild should be depth >= 2")
        check(firstMetric.orphanEdges == 2, "missing parent and missing child edges should be orphaned, but an old existing parent should not")
        check(firstMetric.anonymousSolChildren == 0, "unknown registered-role bucket must not be inferred as anonymous Sol")
        check(firstMetric.roleMetadataCovered == 2 && firstMetric.roleMetadataMissing == 1, "child metadata coverage should be explicit")
        check(firstMetric.missingBaselines == 5 && firstMetric.tokenDelta == 0, "first observation must not invent delta")
        check(firstMetric.createdToUpdatedMedianMilliseconds == 700, "median must include valid zero spans and average the two middle values")
        check(firstMetric.ultraTokenPartition?.attributedUltraChildThreads == 0 && firstMetric.ultraTokenPartition?.unattributedChildThreads == 3 && firstMetric.ultraRoutingTokenShare == nil, "orphan, window-external, and non-Ultra root paths must remain unattributed")
        let firstBuckets = firstMetric.roleBuckets ?? []
        check(firstBuckets.prefix(10).map(\.role) == RoutingRegisteredRole.allCases.map(Optional.some), "registered roles must materialize in fixed global order")
        check(firstBuckets.count == 11 && firstBuckets.filter { $0.role != nil && $0.childThreads == 0 }.count == 8, "all ten known roles must retain zero buckets and unknown appears only when nonzero")
        check(firstBuckets.reduce(0) { $0 + $1.childThreads } == firstMetric.childThreads && firstBuckets.reduce(0) { $0 + $1.cumulativeTokens } == firstMetric.childCumulativeTokens && firstBuckets.reduce(0) { $0 + $1.tokenDelta } == firstMetric.childTokenDelta, "role buckets must reconcile child count, cumulative tokens, and first-observation delta")
        check(firstBuckets.first(where: { $0.role == .terraImplementer })?.childThreads == 1 && firstBuckets.first(where: { $0.role == .codeExplorer })?.childThreads == 1, "same model with distinct exact roles must not merge")
        check(firstBuckets.first(where: { $0.role == .terraImplementer })?.identityMatchedThreads == 1 && firstBuckets.first(where: { $0.role == .codeExplorer })?.identityMatchedThreads == 0, "role identity must validate the observed model and effort against the registered contract")
        check(RoutingRegisteredRole.solUltraTerra.tierLabel == "Terra Medium" && RoutingRegisteredRole.codeReviewer.tierLabel == "Sol Medium" && RoutingRegisteredRole.commitPusher.tierLabel == "Luna Low", "role tier labels must match the registered model contracts")
        check(store.hasSuccessfulSnapshot(after: now.addingTimeInterval(-1)), "a published PARTIAL scan still satisfies the once-daily catch-up gate")

        let legacySchemaDerived = root.appendingPathComponent("legacy-baseline-schema.sqlite")
        check(sqlite3_open(legacySchemaDerived.path, &db) == SQLITE_OK, "legacy baseline schema fixture should open")
        exec(db, "CREATE TABLE routing_daily(day_key TEXT PRIMARY KEY, observed_at_ms INTEGER NOT NULL, payload BLOB NOT NULL, quality TEXT NOT NULL); CREATE TABLE routing_baselines(thread_key TEXT PRIMARY KEY, tokens INTEGER NOT NULL, last_seen_ms INTEGER NOT NULL); CREATE TABLE routing_assessments(id INTEGER PRIMARY KEY, generated_at_ms INTEGER NOT NULL, period_days INTEGER NOT NULL, payload BLOB NOT NULL);")
        sqlite3_close(db); db = nil
        _ = try! RoutingTelemetryStore(sourceURL: source, databaseURL: legacySchemaDerived).lightScan(now: now)
        check(scalarInt(legacySchemaDerived, "SELECT count(*) FROM pragma_table_info('routing_baselines') WHERE name = 'strict_class';") == 1, "existing routing_baselines must migrate in place with only the non-sensitive strict class")

        check(sqlite3_open(source.path, &db) == SQLITE_OK, "fixture source should reopen")
        exec(db, "UPDATE threads SET tokens_used = CASE id WHEN 'root-sensitive-id' THEN 110 WHEN 'child-a' THEN 70 WHEN 'child-sol' THEN 10 ELSE tokens_used END;")
        sqlite3_close(db); db = nil
        let second = try! store.lightScan(now: now.addingTimeInterval(60))
        let secondMetric = second.days.last!
        check(secondMetric.tokenDelta == 30, "second scan should use adjacent token deltas and clamp rollback")
        check(secondMetric.childTokenDelta == 20, "child delta should remain separate")
        check(secondMetric.tokenRollbacks == 1, "token rollback must be marked")
        check(secondMetric.quality == .partial, "rollback makes scan partial")
        check(secondMetric.ultraTokenPartition != nil, "adjacent-delta replacement must preserve the strict Ultra partition")
        check((secondMetric.roleBuckets ?? []).reduce(0) { $0 + $1.tokenDelta } == secondMetric.childTokenDelta && secondMetric.roleBuckets?.first(where: { $0.role == .terraImplementer })?.tokenDelta == 20, "role deltas must reconcile and preserve the exact child role")
        check(second.lastUpdated == now.addingTimeInterval(60), "published freshness must use persisted observation time")
        check((try? FileManager.default.attributesOfItem(atPath: derived.path)[.posixPermissions] as? NSNumber).map { ($0.intValue & 0o777) == 0o600 } == true, "derived DB must be 0600")
        check((try? FileManager.default.attributesOfItem(atPath: derived.deletingLastPathComponent().path)[.posixPermissions] as? NSNumber).map { ($0.intValue & 0o777) == 0o700 } == true, "derived directory must be 0700")
        check(sqlite3_open(source.path, &db) == SQLITE_OK, "fixture source should reopen for role reassignment")
        exec(db, "UPDATE threads SET role = 'code-explorer', model = 'gpt-5.6-luna', reasoning_effort = 'high', tokens_used = 80 WHERE id = 'child-a';")
        sqlite3_close(db); db = nil
        let reassigned = try! store.lightScan(now: now.addingTimeInterval(90))
        let reassignedMetric = reassigned.days.last!
        check(reassignedMetric.childTokenDelta == 10 && reassignedMetric.roleBuckets?.first(where: { $0.role == .codeExplorer })?.tokenDelta == 10 && reassignedMetric.roleBuckets?.first(where: { $0.role == .terraImplementer })?.tokenDelta == 0, "a role change attributes the indivisible adjacent delta to current exact metadata and still reconciles")
        check(sqlite3_open(source.path, &db) == SQLITE_OK, "fixture source should reopen for new-thread baseline")
        exec(db, "INSERT INTO threads VALUES ('newborn', \(t + 91_000), \(t + 91_000), \(t + 91_000), 5, 'quick-implementer', 'gpt-5.6-luna', 'low', 'do not persist', '/secret'); INSERT INTO thread_spawn_edges VALUES ('root-sensitive-id','newborn');")
        sqlite3_close(db); db = nil
        let third = try! store.lightScan(now: now.addingTimeInterval(120))
        check(third.days.last?.tokenDelta == 5, "new thread uses zero baseline and the daily row keeps the latest adjacent-observation delta")

        let dualRoleSource = root.appendingPathComponent("dual-role.sqlite")
        check(sqlite3_open(dualRoleSource.path, &db) == SQLITE_OK, "dual-role fixture should open")
        exec(db, "CREATE TABLE threads(id TEXT PRIMARY KEY, recency_at_ms INTEGER, created_at_ms INTEGER, updated_at_ms INTEGER, tokens_used INTEGER, agent_role TEXT, role TEXT, model TEXT, reasoning_effort TEXT); CREATE TABLE thread_spawn_edges(parent_thread_id TEXT, child_thread_id TEXT); INSERT INTO threads VALUES ('dual-root', \(t), \(t), \(t), 1, NULL, 'orchestrator', 'gpt-5.6-sol', 'max'); INSERT INTO threads VALUES ('dual-child', \(t), \(t), \(t), 2, '', 'terra-reviewer', 'gpt-5.6-terra', 'high'); INSERT INTO thread_spawn_edges VALUES ('dual-root','dual-child');")
        sqlite3_close(db); db = nil
        let dualRole = try! RoutingTelemetryStore(sourceURL: dualRoleSource, databaseURL: root.appendingPathComponent("dual-role-derived.sqlite")).lightScan(now: now)
        check(dualRole.days.last?.roleBuckets?.first(where: { $0.role == .terraReviewer })?.childThreads == 1 && dualRole.days.last?.roleMetadataCovered == 1, "empty or null agent_role must fall back row-wise to the legacy role column")

        let partitionSource = root.appendingPathComponent("ultra-partition.sqlite")
        check(sqlite3_open(partitionSource.path, &db) == SQLITE_OK, "ultra partition fixture should open")
        exec(db, "CREATE TABLE threads(id TEXT, recency_at_ms INTEGER, created_at_ms INTEGER, updated_at_ms INTEGER, tokens_used INTEGER, role TEXT, model TEXT, reasoning_effort TEXT); CREATE TABLE thread_spawn_edges(parent_thread_id TEXT, child_thread_id TEXT); INSERT INTO threads VALUES ('ultra-root', \(t), \(t), \(t), 100, 'orchestrator', ' GPT-5.6-SOL ', 'ULTRA'); INSERT INTO threads VALUES ('max-root', \(t), \(t), \(t), 1000, 'orchestrator', 'gpt-5.6-sol', 'max'); INSERT INTO threads VALUES ('unknown-effort-root', \(t), \(t), \(t), 40, 'orchestrator', 'gpt-5.6-sol', NULL); INSERT INTO threads VALUES ('ultra-child', \(t), \(t), \(t), 50, 'terra-implementer', 'gpt-5.6-terra', 'medium'); INSERT INTO threads VALUES ('ultra-grandchild', \(t), \(t), \(t), 25, 'code-explorer', 'gpt-5.6-luna', 'high'); INSERT INTO threads VALUES ('max-child', \(t), \(t), \(t), 200, 'terra-implementer', 'gpt-5.6-terra', 'medium'); INSERT INTO threads VALUES ('multi-parent-child', \(t), \(t), \(t), 10, 'terra-implementer', 'gpt-5.6-terra', 'medium'); INSERT INTO threads VALUES ('unknown-effort-child', \(t), \(t), \(t), 15, 'terra-implementer', 'gpt-5.6-terra', 'medium'); INSERT INTO thread_spawn_edges VALUES ('ultra-root','ultra-child'); INSERT INTO thread_spawn_edges VALUES ('ultra-child','ultra-grandchild'); INSERT INTO thread_spawn_edges VALUES ('max-root','max-child'); INSERT INTO thread_spawn_edges VALUES ('ultra-root','multi-parent-child'); INSERT INTO thread_spawn_edges VALUES ('max-root','multi-parent-child'); INSERT INTO thread_spawn_edges VALUES ('unknown-effort-root','unknown-effort-child');")
        sqlite3_close(db); db = nil
        let partitionMetric = try! RoutingTelemetryStore(sourceURL: partitionSource, databaseURL: root.appendingPathComponent("ultra-partition-derived.sqlite")).lightScan(now: now).days.last!
        let partition = partitionMetric.ultraTokenPartition
        check(partitionMetric.childTokenShare == Double(300) / Double(1440), "overall child share must keep all recent edge-child tokens over all recent tokens")
        check(partition?.ultraRootCumulativeTokens == 100 && partition?.attributedUltraChildCumulativeTokens == 75 && partition?.maxRootCumulativeTokens == 1000, "strict partition must retain Ultra roots, attributed descendants, and Max roots separately")
        check(partition?.unattributedChildThreads == 3 && partition?.unattributedChildCumulativeTokens == 225 && partition?.ultraRoutingTokenShare == Double(75) / Double(175), "Max descendants, multi-parent children, and children of roots with missing effort must be excluded from the Ultra denominator")
        let saturatedPartition = RoutingUltraTokenPartition(ultraRootThreads: 1, ultraRootCumulativeTokens: Int.max, maxRootThreads: 0, maxRootCumulativeTokens: 0, attributedUltraChildThreads: 1, attributedUltraChildCumulativeTokens: Int.max, unattributedChildThreads: 0, unattributedChildCumulativeTokens: 0)
        check(saturatedPartition.ultraRoutingTokenShare == 0.5, "two saturated aggregates must not overflow the Ultra denominator")
        let partitionReport = RoutingAssessmentReport(assessment: RoutingAssessment(periodDays: 7, generatedAt: now, metrics: partitionMetric, verifiedSuccessRate: "UNVERIFIED", tokenPerVerifiedSuccess: "UNVERIFIED", trueEndToEndSpeedup: "UNVERIFIED"))
        let partitionShareDetail = partitionReport.summary.first(where: { $0.id == "dual-token-share" })?.detail ?? ""
        check(partitionShareDetail.contains("整体 21%") && partitionShareDetail.contains("Ultra 路由内 43%") && partitionShareDetail.contains("Max 根不计入"), "report must state both computed denominators and Max exclusion")
        let partitionHTML = RoutingAssessmentReportHTMLRenderer.render(partitionReport)
        check(partitionHTML.contains("整体 21%") && partitionHTML.contains("Ultra 路由内 43%") && partitionHTML.contains("Max 根不计入"), "HTML report must reuse the two explicit Token denominators")

        let dailyDeltaSource = root.appendingPathComponent("ultra-daily-delta.sqlite")
        let dailyDeltaDerived = root.appendingPathComponent("ultra-daily-delta-derived.sqlite")
        check(sqlite3_open(dailyDeltaSource.path, &db) == SQLITE_OK, "daily delta fixture should open")
        exec(db, "CREATE TABLE threads(id TEXT PRIMARY KEY, recency_at_ms INTEGER, created_at_ms INTEGER, updated_at_ms INTEGER, tokens_used INTEGER, role TEXT, model TEXT, reasoning_effort TEXT); CREATE TABLE thread_spawn_edges(parent_thread_id TEXT, child_thread_id TEXT); INSERT INTO threads VALUES ('daily-ultra-root', \(t), \(t-1_000), \(t), 100, 'orchestrator', 'gpt-5.6-sol', 'ultra'); INSERT INTO threads VALUES ('daily-ultra-child', \(t), \(t-1_000), \(t), 20, 'terra-implementer', 'gpt-5.6-terra', 'medium'); INSERT INTO threads VALUES ('daily-max-root', \(t), \(t-1_000), \(t), 1_000, 'orchestrator', 'gpt-5.6-sol', 'max'); INSERT INTO threads VALUES ('daily-max-child', \(t), \(t-1_000), \(t), 100, 'terra-implementer', 'gpt-5.6-terra', 'medium'); INSERT INTO thread_spawn_edges VALUES ('daily-ultra-root','daily-ultra-child'); INSERT INTO thread_spawn_edges VALUES ('daily-max-root','daily-max-child');")
        sqlite3_close(db); db = nil
        let dailyDeltaStore = RoutingTelemetryStore(sourceURL: dailyDeltaSource, databaseURL: dailyDeltaDerived)
        let warm = try! dailyDeltaStore.lightScan(now: now)
        check(warm.days.last?.ultraTokenPartition?.dailyDeltaEvidenceComplete == false && warm.days.last?.ultraRoutingDailyObservedTokenShare == nil, "first strict observation must establish a baseline without fabricating a daily share")
        let nextDay = now.addingTimeInterval(24 * 3600)
        check(sqlite3_open(dailyDeltaSource.path, &db) == SQLITE_OK, "daily delta fixture should reopen")
        exec(db, "UPDATE threads SET tokens_used = CASE id WHEN 'daily-ultra-root' THEN 130 WHEN 'daily-ultra-child' THEN 35 WHEN 'daily-max-root' THEN \(9_000) WHEN 'daily-max-child' THEN \(8_000) ELSE tokens_used END;")
        sqlite3_close(db); db = nil
        let firstDaily = try! dailyDeltaStore.lightScan(now: nextDay).days.last!
        check(firstDaily.ultraTokenPartition?.ultraRootDailyObservedTokenDelta == 30 && firstDaily.ultraTokenPartition?.attributedUltraChildDailyObservedTokenDelta == 15 && firstDaily.ultraTokenPartition?.dailyDeltaEvidenceComplete == true && firstDaily.ultraRoutingDailyObservedTokenShare == Double(15) / Double(45), "strict daily share must use same-scan hashed-baseline increases and exclude Max growth")
        check(sqlite3_open(dailyDeltaSource.path, &db) == SQLITE_OK, "daily delta fixture should reopen for same-day merge")
        exec(db, "UPDATE threads SET tokens_used = CASE id WHEN 'daily-ultra-root' THEN 140 WHEN 'daily-ultra-child' THEN 40 ELSE tokens_used END;")
        sqlite3_close(db); db = nil
        let secondDaily = try! dailyDeltaStore.lightScan(now: nextDay.addingTimeInterval(60)).days.last!
        check(secondDaily.ultraTokenPartition?.ultraRootDailyObservedTokenDelta == 40 && secondDaily.ultraTokenPartition?.attributedUltraChildDailyObservedTokenDelta == 20 && secondDaily.ultraTokenPartition?.dailyMergeObservationCount == 2 && secondDaily.ultraRoutingDailyObservedTokenShare == Double(20) / Double(60), "same-day strict observations must accumulate instead of being overwritten by manual refresh")
        check(sqlite3_open(dailyDeltaSource.path, &db) == SQLITE_OK, "daily delta fixture should reopen for new strict root")
        let newRootCreated = t + 24 * 3600 * 1000 + 61_000
        exec(db, "INSERT INTO threads VALUES ('daily-new-ultra-root', \(newRootCreated), \(newRootCreated), \(newRootCreated), 8, 'orchestrator', 'gpt-5.6-sol', 'ultra');")
        sqlite3_close(db); db = nil
        let withNewRoot = try! dailyDeltaStore.lightScan(now: nextDay.addingTimeInterval(120)).days.last!
        check(withNewRoot.ultraTokenPartition?.ultraRootDailyObservedTokenDelta == 48 && withNewRoot.ultraTokenPartition?.attributedUltraChildDailyObservedTokenDelta == 20 && withNewRoot.ultraTokenPartition?.dailyDeltaEvidenceComplete == true, "a thread created after the previous observation may safely establish a zero strict baseline")

        let legacyClassSource = root.appendingPathComponent("legacy-strict-class.sqlite")
        let legacyClassDerived = root.appendingPathComponent("legacy-strict-class-derived.sqlite")
        check(sqlite3_open(legacyClassSource.path, &db) == SQLITE_OK, "legacy strict-class fixture should open")
        exec(db, "CREATE TABLE threads(id TEXT PRIMARY KEY, recency_at_ms INTEGER, created_at_ms INTEGER, updated_at_ms INTEGER, tokens_used INTEGER, role TEXT, model TEXT, reasoning_effort TEXT); CREATE TABLE thread_spawn_edges(parent_thread_id TEXT, child_thread_id TEXT); INSERT INTO threads VALUES ('legacy-root', \(t), \(t-1_000), \(t), 10, 'orchestrator', 'gpt-5.6-sol', 'ultra'); INSERT INTO threads VALUES ('legacy-child', \(t), \(t-1_000), \(t), 10, 'terra-implementer', 'gpt-5.6-terra', 'medium'); INSERT INTO thread_spawn_edges VALUES ('legacy-root','legacy-child');")
        sqlite3_close(db); db = nil
        let legacyClassStore = RoutingTelemetryStore(sourceURL: legacyClassSource, databaseURL: legacyClassDerived)
        _ = try! legacyClassStore.lightScan(now: now)
        check(sqlite3_open(legacyClassDerived.path, &db) == SQLITE_OK, "legacy derived fixture should open")
        exec(db, "UPDATE routing_baselines SET strict_class = NULL;")
        sqlite3_close(db); db = nil
        check(sqlite3_open(legacyClassSource.path, &db) == SQLITE_OK, "legacy strict-class source should reopen")
        exec(db, "UPDATE threads SET tokens_used = 20;")
        sqlite3_close(db); db = nil
        let legacyClassMetric = try! legacyClassStore.lightScan(now: nextDay).days.last!
        check(legacyClassMetric.ultraTokenPartition?.dailyDeltaEvidenceComplete == false && legacyClassMetric.ultraRoutingDailyObservedTokenShare == nil, "migrated baselines without a strict class must fail closed")

        check(sqlite3_open(dailyDeltaSource.path, &db) == SQLITE_OK, "daily delta fixture should reopen for rollback")
        exec(db, "UPDATE threads SET tokens_used = 130 WHERE id = 'daily-ultra-root';")
        sqlite3_close(db); db = nil
        let rollbackDaily = try! dailyDeltaStore.lightScan(now: nextDay.addingTimeInterval(24 * 3600)).days.last!
        check(rollbackDaily.ultraTokenPartition?.dailyDeltaEvidenceComplete == false && rollbackDaily.ultraRoutingDailyObservedTokenShare == nil, "a strict token rollback must make that daily guidance evidence unavailable")
        check(sqlite3_open(dailyDeltaSource.path, &db) == SQLITE_OK, "daily delta fixture should reopen for class drift")
        exec(db, "UPDATE threads SET reasoning_effort = 'max', tokens_used = 150 WHERE id = 'daily-ultra-root';")
        sqlite3_close(db); db = nil
        let driftDaily = try! dailyDeltaStore.lightScan(now: nextDay.addingTimeInterval(48 * 3600)).days.last!
        check(driftDaily.ultraTokenPartition?.dailyDeltaEvidenceComplete == false && driftDaily.ultraRoutingDailyObservedTokenShare == nil, "Ultra-to-Max class drift must not feed strict daily guidance")

        let staleSource = root.appendingPathComponent("stale-strict-delta.sqlite")
        check(sqlite3_open(staleSource.path, &db) == SQLITE_OK, "stale strict fixture should open")
        exec(db, "CREATE TABLE threads(id TEXT PRIMARY KEY, recency_at_ms INTEGER, created_at_ms INTEGER, updated_at_ms INTEGER, tokens_used INTEGER, role TEXT, model TEXT, reasoning_effort TEXT); CREATE TABLE thread_spawn_edges(parent_thread_id TEXT, child_thread_id TEXT); INSERT INTO threads VALUES ('stale-root', \(t), \(t-1_000), \(t), 10, 'orchestrator', 'gpt-5.6-sol', 'ultra'); INSERT INTO threads VALUES ('stale-child', \(t), \(t-1_000), \(t), 10, 'terra-implementer', 'gpt-5.6-terra', 'medium'); INSERT INTO thread_spawn_edges VALUES ('stale-root','stale-child');")
        sqlite3_close(db); db = nil
        let staleStore = RoutingTelemetryStore(sourceURL: staleSource, databaseURL: root.appendingPathComponent("stale-strict-delta-derived.sqlite"))
        _ = try! staleStore.lightScan(now: now)
        check(sqlite3_open(staleSource.path, &db) == SQLITE_OK, "stale strict fixture should reopen")
        exec(db, "UPDATE threads SET tokens_used = 20;")
        sqlite3_close(db); db = nil
        let staleMetric = try! staleStore.lightScan(now: now.addingTimeInterval(49 * 3600)).days.last!
        check(staleMetric.ultraTokenPartition?.dailyDeltaEvidenceComplete == false && staleMetric.ultraRoutingDailyObservedTokenShare == nil, "a strict participant returning after 48 hours must not create a guidance increment")
        let saturatedDailyPartition = RoutingUltraTokenPartition(ultraRootThreads: 1, ultraRootCumulativeTokens: 0, maxRootThreads: 0, maxRootCumulativeTokens: 0, attributedUltraChildThreads: 1, attributedUltraChildCumulativeTokens: 0, unattributedChildThreads: 0, unattributedChildCumulativeTokens: 0, ultraRootDailyObservedTokenDelta: Int.max, attributedUltraChildDailyObservedTokenDelta: Int.max, dailyDeltaEvidenceComplete: true, dailyMergeObservationCount: 1)
        check(saturatedDailyPartition.ultraRoutingDailyObservedTokenShare == 0.5, "strict daily denominator must avoid Int overflow")

        let duplicateSource = root.appendingPathComponent("duplicate-id.sqlite")
        check(sqlite3_open(duplicateSource.path, &db) == SQLITE_OK, "duplicate ID fixture should open")
        exec(db, "CREATE TABLE threads(id TEXT, recency_at_ms INTEGER, created_at_ms INTEGER, updated_at_ms INTEGER, tokens_used INTEGER, role TEXT, model TEXT, reasoning_effort TEXT); CREATE TABLE thread_spawn_edges(parent_thread_id TEXT, child_thread_id TEXT); INSERT INTO threads VALUES ('dup-root', \(t), \(t), \(t), 1, 'orchestrator', 'gpt-5.6-sol', 'ultra'); INSERT INTO threads VALUES ('dup-root', \(t), \(t), \(t), 2, 'orchestrator', 'gpt-5.6-sol', 'ultra'); INSERT INTO threads VALUES ('dup-child', \(t), \(t), \(t), 3, 'terra-implementer', 'gpt-5.6-terra', 'medium'); INSERT INTO thread_spawn_edges VALUES ('dup-root','dup-child');")
        sqlite3_close(db); db = nil
        let duplicateMetric = try! RoutingTelemetryStore(sourceURL: duplicateSource, databaseURL: root.appendingPathComponent("duplicate-id-derived.sqlite")).lightScan(now: now).days.last!
        check(duplicateMetric.quality == .partial && duplicateMetric.ultraTokenPartition == nil, "duplicate IDs must not trap or pretend strict attribution is precise")

        let cycleSource = root.appendingPathComponent("cycle.sqlite")
        check(sqlite3_open(cycleSource.path, &db) == SQLITE_OK, "cycle fixture should open")
        exec(db, "CREATE TABLE threads(id TEXT, recency_at_ms INTEGER, created_at_ms INTEGER, updated_at_ms INTEGER, tokens_used INTEGER, role TEXT, model TEXT, reasoning_effort TEXT); CREATE TABLE thread_spawn_edges(parent_thread_id TEXT, child_thread_id TEXT); INSERT INTO threads VALUES ('a', \(t), \(t), \(t), 1, 'worker', 'gpt-5.6-sol', 'low'); INSERT INTO threads VALUES ('b', \(t), \(t), \(t), 1, 'worker', 'gpt-5.6-terra', 'low'); INSERT INTO thread_spawn_edges VALUES ('a','b'); INSERT INTO thread_spawn_edges VALUES ('b','a');")
        sqlite3_close(db); db = nil
        let cycle = try! RoutingTelemetryStore(sourceURL: cycleSource, databaseURL: root.appendingPathComponent("cycle-derived.sqlite")).lightScan(now: now)
        check((cycle.days.last?.cycleAffectedChildren ?? 0) == 2 && cycle.days.last?.quality == .partial, "cycle-affected children must be counted once and make route quality partial")
        check(cycle.days.last?.ultraTokenPartition?.attributedUltraChildThreads == 0 && cycle.days.last?.ultraTokenPartition?.unattributedChildThreads == 2 && cycle.days.last?.ultraRoutingTokenShare == nil, "cycle paths must stay outside the strict Ultra numerator")
        let assessment = try! store.assess(days: 30, now: now)
        check(assessment.verifiedSuccessRate == "UNVERIFIED" && assessment.tokenPerVerifiedSuccess == "UNVERIFIED" && assessment.trueEndToEndSpeedup == "UNVERIFIED", "deep assessment must preserve evidence boundary")
        let report = RoutingAssessmentReport(assessment: assessment)
        check(report.efficiencyStatus == .unverified, "success, token-per-success, and E2E claims must always remain unverified")
        check(report.structureStatus == .partial && report.findings.contains(where: { $0.id == "topology" }), "partial metric quality and structural anomalies must be visible in the report")
        check(report.summary.first(where: { $0.id == "structure" })?.detail.contains("全库孤儿") == true && report.evidenceBoundaryText.contains("孤儿关系检查覆盖全库父子边"), "report must distinguish the full-table orphan check from the recent task window")
        check(report.identityStatus == .partial && report.findings.contains(where: { $0.id == "identity" }), "unknown roles, missing metadata, and registered-role mismatches must make report identity partial")
        let unknownShareReport = RoutingAssessmentReport(assessment: RoutingAssessment(periodDays: 7, generatedAt: now, metrics: firstMetric, verifiedSuccessRate: "UNVERIFIED", tokenPerVerifiedSuccess: "UNVERIFIED", trueEndToEndSpeedup: "UNVERIFIED"))
        check(unknownShareReport.findings.first(where: { $0.id == "identity" })?.detail.contains("未知角色累计 Token 占子任务累计 Token 30%") == true, "identity finding must include the unknown token burden share with a safe denominator")
        check(report.summary.first(where: { $0.id == "burden" })?.detail.contains("截至评估时的累计值") == true && report.evidenceBoundaryText.contains("不是 30 天消耗"), "30-day report burden must be as-of, not consumption")
        let reportHTML = RoutingAssessmentReportHTMLRenderer.render(report)
        check(!reportHTML.contains("root-sensitive-id") && !reportHTML.contains("very private title") && !reportHTML.contains("unregistered-secret-role") && !reportHTML.contains("/secret"), "report HTML must not include raw IDs or sensitive source content")
        let zeroMetric = RoutingDailyMetric(dayKey: "2026-07-30", sourceThreads: 0, edgeCount: 0, rootThreads: 0, childThreads: 0, roleMetadataCovered: 0, roleMetadataMissing: 0, depthAtLeastTwo: 0, orphanEdges: 0, cycleAffectedChildren: 0, anonymousSolChildren: 0, cumulativeTokens: 0, childCumulativeTokens: 0, tokenDelta: 0, childTokenDelta: 0, missingBaselines: 0, tokenRollbacks: 0, createdToUpdatedMedianMilliseconds: 0, readRows: 0, derivedWrites: 0, scanMilliseconds: 0, quality: .complete, roleBuckets: RoutingRegisteredRole.allCases.map(RoutingRoleBucket.zero))
        func guidanceMetric(_ dayKey: String, _ root: Int, _ child: Int, _ complete: Bool = true) -> RoutingDailyMetric {
            RoutingDailyMetric(dayKey: dayKey, sourceThreads: 0, edgeCount: 0, rootThreads: 0, childThreads: 0, roleMetadataCovered: 0, roleMetadataMissing: 0, depthAtLeastTwo: 0, orphanEdges: 0, cycleAffectedChildren: 0, anonymousSolChildren: 0, cumulativeTokens: 0, childCumulativeTokens: 0, tokenDelta: 0, childTokenDelta: 0, missingBaselines: 0, tokenRollbacks: 0, createdToUpdatedMedianMilliseconds: 0, readRows: 0, derivedWrites: 0, scanMilliseconds: 0, quality: .complete, roleBuckets: RoutingRegisteredRole.allCases.map(RoutingRoleBucket.zero), ultraTokenPartition: RoutingUltraTokenPartition(ultraRootThreads: 0, ultraRootCumulativeTokens: 0, maxRootThreads: 0, maxRootCumulativeTokens: 0, attributedUltraChildThreads: 0, attributedUltraChildCumulativeTokens: 0, unattributedChildThreads: 0, unattributedChildCumulativeTokens: 0, ultraRootDailyObservedTokenDelta: root, attributedUltraChildDailyObservedTokenDelta: child, dailyDeltaEvidenceComplete: complete, dailyMergeObservationCount: 1))
        }
        let observingGuidance = RoutingUltraDeltaGuidance.evaluate([guidanceMetric("1", 80, 20), guidanceMetric("2", 80, 20)])
        check(observingGuidance.state == .observing && observingGuidance.validDays == 2 && observingGuidance.weightedShare == 0.2, "strict guidance must wait for three valid local days")
        check(RoutingUltraDeltaGuidance.evaluate([guidanceMetric("1", 80, 20), guidanceMetric("2", 80, 20), guidanceMetric("3", 80, 20)]).state == .balanced, "exactly 20% must enter the balanced band")
        check(RoutingUltraDeltaGuidance.evaluate([guidanceMetric("1", 65, 35), guidanceMetric("2", 65, 35), guidanceMetric("3", 65, 35)]).state == .balanced, "exactly 35% must remain in the balanced band")
        check(RoutingUltraDeltaGuidance.evaluate([guidanceMetric("1", 50, 50), guidanceMetric("2", 50, 50), guidanceMetric("3", 50, 50)]).state == .elevated, "exactly 50% must remain elevated rather than excessive")
        check(RoutingUltraDeltaGuidance.evaluate([guidanceMetric("1", 80, 20), guidanceMetric("2", 64, 36), guidanceMetric("3", 50, 50)]).state == .elevated && RoutingUltraDeltaGuidance.evaluate([guidanceMetric("1", 80, 20), guidanceMetric("2", 30, 70), guidanceMetric("3", 30, 70)]).state == .excessive, "guidance must separate elevated and review-required strict shares")
        let weightedGuidance = RoutingUltraDeltaGuidance.evaluate([guidanceMetric("1", 1, 9), guidanceMetric("2", 90, 10), guidanceMetric("3", 90, 10)])
        check(weightedGuidance.state == .low && weightedGuidance.weightedShare == Double(29) / Double(210), "guidance must weight valid days by strict observed Tokens rather than averaging daily percentages")
        let unavailableGuidance = RoutingUltraDeltaGuidance.evaluate([zeroMetric, guidanceMetric("bad", 1, 1, false)])
        check(unavailableGuidance.state == .unavailable && unavailableGuidance.validDays == 0 && unavailableGuidance.weightedShare == nil, "legacy, incomplete, and zero-denominator snapshots must stay outside guidance")
        let zeroReport = RoutingAssessmentReport(assessment: RoutingAssessment(periodDays: 7, generatedAt: now, metrics: zeroMetric, verifiedSuccessRate: "UNVERIFIED", tokenPerVerifiedSuccess: "UNVERIFIED", trueEndToEndSpeedup: "UNVERIFIED"))
        check(zeroReport.structureStatus == .complete && zeroReport.identityStatus == .complete && zeroReport.summary.first(where: { $0.id == "burden" })?.detail.contains("0") == true, "zero values with complete new buckets should remain explicit and complete where evidence permits")
        check(zeroReport.summary.first(where: { $0.id == "dual-token-share" })?.detail.contains("Ultra 路由内 --") == true, "zero or absent strict denominator must display unavailable rather than zero")
        var depthOnlyPayload = try! JSONSerialization.jsonObject(with: JSONEncoder().encode(zeroMetric)) as! [String: Any]
        depthOnlyPayload["depthAtLeastTwo"] = 1
        let depthOnlyMetric = try! JSONDecoder().decode(RoutingDailyMetric.self, from: JSONSerialization.data(withJSONObject: depthOnlyPayload))
        let depthOnlyReport = RoutingAssessmentReport(assessment: RoutingAssessment(periodDays: 7, generatedAt: now, metrics: depthOnlyMetric, verifiedSuccessRate: "UNVERIFIED", tokenPerVerifiedSuccess: "UNVERIFIED", trueEndToEndSpeedup: "UNVERIFIED"))
        check(depthOnlyReport.recommendations.contains(where: { $0.id == "repair-structure" }), "nested depth alone must trigger a structural review recommendation")
        let countingProbe = CancellationProbe(cancelAt: .max)
        let countingStore = RoutingTelemetryStore(sourceURL: source, databaseURL: root.appendingPathComponent("counting-assessment.sqlite"))
        _ = try! countingStore.assess(days: 30, now: now, shouldCancel: countingProbe.checkpoint)
        let cancellationProbe = CancellationProbe(cancelAt: countingProbe.count)
        let cancelledAssessmentURL = root.appendingPathComponent("cancelled-assessment.sqlite")
        let cancellingStore = RoutingTelemetryStore(sourceURL: source, databaseURL: cancelledAssessmentURL)
        do {
            _ = try cancellingStore.assess(days: 30, now: now, shouldCancel: cancellationProbe.checkpoint)
            check(false, "final pre-commit cancellation must stop assessment publication")
        } catch RoutingTelemetryStoreError.cancelled { }
        catch { check(false, "assessment cancellation must not become an unrelated failure") }
        check(scalarInt(cancelledAssessmentURL, "SELECT count(*) FROM routing_assessments;") == 0, "cancelled assessment transaction must roll back")
        check((try? Data(contentsOf: derived)).map { !String(decoding: $0, as: UTF8.self).contains("root-sensitive-id") && !String(decoding: $0, as: UTF8.self).contains("very private title") && !String(decoding: $0, as: UTF8.self).contains("rollout.jsonl") && !String(decoding: $0, as: UTF8.self).contains("unregistered-secret-role") } == true, "derived DB must not persist raw IDs, sensitive fields, or unknown raw roles")

        var legacyPayload = try! JSONSerialization.jsonObject(with: JSONEncoder().encode(firstMetric)) as! [String: Any]
        legacyPayload.removeValue(forKey: "roleBuckets")
        legacyPayload.removeValue(forKey: "ultraTokenPartition")
        let legacyMetric = try! JSONDecoder().decode(RoutingDailyMetric.self, from: JSONSerialization.data(withJSONObject: legacyPayload))
        check(legacyMetric.roleBuckets == nil && legacyMetric.ultraTokenPartition == nil, "old payload without aggregate extensions must decode as legacy rather than empty detail")
        let legacyReport = RoutingAssessmentReport(assessment: RoutingAssessment(periodDays: 7, generatedAt: now, metrics: legacyMetric, verifiedSuccessRate: "UNVERIFIED", tokenPerVerifiedSuccess: "UNVERIFIED", trueEndToEndSpeedup: "UNVERIFIED"))
        check(legacyReport.identityStatus == .partial && legacyReport.findings.contains(where: { $0.id == "legacy" }), "legacy nil role buckets must be explicitly partial rather than treated as empty")

        let retentionURL = root.appendingPathComponent("retention.sqlite")
        let retentionStore = RoutingTelemetryStore(sourceURL: source, databaseURL: retentionURL)
        for offset in (-90)...0 {
            let observation = Calendar.current.date(byAdding: .day, value: offset, to: now)!
            _ = try! retentionStore.lightScan(now: observation)
            _ = try! retentionStore.assess(days: 7, now: observation)
        }
        check(scalarInt(retentionURL, "SELECT count(*) FROM routing_daily;") == 90, "daily retention must keep exactly 90 local day keys")
        check(scalarInt(retentionURL, "SELECT count(*) FROM routing_assessments;") == 90, "assessment retention must keep exactly 90 local days")
        check(retentionStore.loadPublished(days: 30, now: now).days.count == 30, "presentation must load a 30-snapshot history")

        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let beforeNine = calendar.date(from: DateComponents(year: 2026, month: 3, day: 8, hour: 20, minute: 59))!
        let next = RoutingTelemetryScanPolicy.nextAutomaticRunDate(now: beforeNine, calendar: calendar)
        check(calendar.component(.hour, from: next) == 21 && calendar.component(.day, from: next) == 8, "21:00 schedule should survive DST boundary")
        check(RoutingTelemetryScanPolicy.automaticDeferralReason(lowPower: true, thermalState: .nominal) != nil, "low power must defer automatic work")
        check(RoutingTelemetryScanPolicy.automaticDeferralReason(lowPower: false, thermalState: .serious) != nil, "serious thermal pressure must defer automatic work")
        check(RoutingTelemetryScanPolicy.automaticDeferralReason(lowPower: false, thermalState: .fair) == nil, "fair thermal state may run")
        do { _ = try store.lightScan(now: now, shouldCancel: { true }); check(false, "cancelled scan must stop") }
        catch RoutingTelemetryStoreError.cancelled { }
        catch { check(false, "cancel must not become an unrelated failure") }

        if failures.isEmpty { print("RoutingTelemetryTests: PASS") } else { failures.forEach { FileHandle.standardError.write(Data("FAIL: \($0)\n".utf8)) }; exit(1) }
    }

    private static func exec(_ db: OpaquePointer?, _ sql: String) {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { fatalError("fixture SQL failed") }
    }

    private static func scalarInt(_ url: URL, _ sql: String) -> Int {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else { return -1 }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return -1 }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return -1 }
        return Int(sqlite3_column_int64(statement, 0))
    }
}

private final class CancellationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let cancelAt: Int
    private(set) var count = 0

    init(cancelAt: Int) {
        self.cancelAt = cancelAt
    }

    func checkpoint() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        count += 1
        return count >= cancelAt
    }
}
