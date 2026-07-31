import CryptoKit
import Foundation
import SQLite3

enum RoutingTelemetryStoreError: Error, Equatable { case sourceUnavailable, schemaUnavailable, sqlite(String), cancelled }

/// SQLite-only route telemetry. Source access is one READONLY transaction; derived storage has aggregates plus hashed baselines only.
final class RoutingTelemetryStore: @unchecked Sendable {
    private struct ThreadRow { let id: String; let recencyMs, createdMs, updatedMs: Int64; let tokens: Int; let role, model, effort: String? }
    private struct Edge { let parent, child: String }
    private struct StoredDaily { let metric: RoutingDailyMetric; let observedAt: Date }
    private struct StrictTopology { let partition: RoutingUltraTokenPartition; let classifications: [String: String] }
    private struct MetricBuild { let metric: RoutingDailyMetric; let strictClassifications: [String: String] }
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    private let sourceURL: URL
    private let databaseURL: URL
    private let lock = NSLock()

    init(sourceURL: URL? = nil, databaseURL: URL = RoutingTelemetryStore.defaultDatabaseURL()) {
        self.sourceURL = sourceURL ?? Self.defaultStateDatabaseURL()
        self.databaseURL = databaseURL
    }

    static func defaultStateDatabaseURL(codexDirectory: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)) -> URL {
        let candidates = (try? FileManager.default.contentsOfDirectory(at: codexDirectory, includingPropertiesForKeys: nil)) ?? []
        let versioned = candidates.compactMap { url -> (Int, URL)? in
            let match = url.lastPathComponent.wholeMatch(of: /state_([0-9]+)\.sqlite/)
            return match.flatMap { (Int($0.1) ?? -1, url) }
        }
        return versioned.max(by: { $0.0 < $1.0 })?.1 ?? codexDirectory.appendingPathComponent("state.sqlite")
    }

    static func defaultDatabaseURL() -> URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return root.appendingPathComponent("CodexNotch", isDirectory: true).appendingPathComponent("routing-telemetry.sqlite")
    }

    /// Presentation opens an existing database READONLY. It never creates directories, schema, or a database file.
    func loadPublished(days: Int = 30, now: Date = Date()) -> RoutingTelemetrySnapshot {
        guard FileManager.default.fileExists(atPath: databaseURL.path) else { return .empty }
        do {
            return try synchronized {
                try withExistingDerivedDatabase { db in
                    let stored = try loadDaily(db, days: days)
                    let assessment = try loadLatestAssessment(db)
                    guard let latest = stored.last else { return RoutingTelemetrySnapshot(days: [], state: .empty, lastUpdated: nil, automaticStatus: "每日 21:00 本地时间", latestAssessment: assessment) }
                    let stale = now.timeIntervalSince(latest.observedAt) > 36 * 3600
                    let state: RoutingDailyState = latest.metric.quality == .unavailable ? .unavailable : (stale ? .stale : (latest.metric.quality == .partial ? .partial : .ready))
                    return RoutingTelemetrySnapshot(days: stored.map(\.metric), state: state, lastUpdated: latest.observedAt, automaticStatus: "每日 21:00 本地时间", latestAssessment: assessment)
                }
            }
        } catch { return RoutingTelemetrySnapshot(days: [], state: .unavailable, lastUpdated: nil, automaticStatus: "派生数据库不可用", latestAssessment: nil) }
    }

    func hasSuccessfulSnapshot(after date: Date) -> Bool {
        guard FileManager.default.fileExists(atPath: databaseURL.path) else { return false }
        return (try? synchronized {
            try withExistingDerivedDatabase { db in
                let s = try prepare("SELECT 1 FROM routing_daily WHERE observed_at_ms >= ? AND quality IN ('COMPLETE','PARTIAL') LIMIT 1;", db); defer { sqlite3_finalize(s) }
                sqlite3_bind_int64(s, 1, millis(date)); return sqlite3_step(s) == SQLITE_ROW
            }
        }) ?? false
    }

    func lightScan(days: Int = 7, now: Date = Date(), shouldCancel: @escaping @Sendable () -> Bool = { false }) throws -> RoutingTelemetrySnapshot {
        let start = Date(); let source = try readSource(days: days, now: now, shouldCancel: shouldCancel)
        let build = try makeMetric(source.recent, allIDs: source.allIDs, hasDuplicateIDs: source.hasDuplicateIDs, edges: source.edges, now: now, readRows: source.readRows, scanMilliseconds: Int(Date().timeIntervalSince(start) * 1000), shouldCancel: shouldCancel)
        var metric = build.metric
        if shouldCancel() { throw RoutingTelemetryStoreError.cancelled }
        try synchronized {
            try withWritableDerivedDatabase { db in
                try ensureSchema(db); try execute("BEGIN IMMEDIATE;", db)
                do {
                    let previous = try latestObservedAt(db)
                    let childIDs = Set(source.edges.map(\.child))
                    // A corrupt source can repeat a thread ID. Keep baseline attribution
                    // deterministic and let makeMetric publish PARTIAL with no strict partition.
                    var childRoleKeys: [String: String] = [:]
                    for row in source.recent where childIDs.contains(row.id) {
                        if childRoleKeys[row.id] == nil {
                            childRoleKeys[row.id] = roleBucketKey(row.role)
                        }
                    }
                    let baseline = try updateBaselines(source.recent, childRoleKeys: childRoleKeys, strictClassifications: build.strictClassifications, previousObservedAt: previous, db: db, now: now, shouldCancel: shouldCancel)
                    metric = replacing(metric, tokenDelta: baseline.totalDelta, childTokenDelta: baseline.childDelta, roleTokenDeltas: baseline.roleDeltas, missingBaselines: baseline.missing, tokenRollbacks: baseline.rollbacks, derivedWrites: baseline.writes + 1, quality: worse(metric.quality, baseline.quality))
                    let prior = try loadDaily(dayKey: metric.dayKey, db: db)
                    metric = mergingDailyStrictDelta(metric, baseline: baseline, prior: prior)
                    try upsertDaily(metric, observedAt: now, db: db)
                    try prune(db, now: now)
                    if shouldCancel() { throw RoutingTelemetryStoreError.cancelled }
                    try execute("COMMIT;", db)
                } catch { _ = try? execute("ROLLBACK;", db); throw error }
            }
        }
        return loadPublished(days: max(30, days), now: now)
    }

    func assess(days: Int, now: Date = Date(), shouldCancel: @escaping @Sendable () -> Bool = { false }) throws -> RoutingAssessment {
        let source = try readSource(days: days, now: now, shouldCancel: shouldCancel)
        let metric = try makeMetric(source.recent, allIDs: source.allIDs, hasDuplicateIDs: source.hasDuplicateIDs, edges: source.edges, now: now, readRows: source.readRows, scanMilliseconds: 0, shouldCancel: shouldCancel).metric
        let result = RoutingAssessment(periodDays: days, generatedAt: now, metrics: metric, verifiedSuccessRate: "UNVERIFIED", tokenPerVerifiedSuccess: "UNVERIFIED", trueEndToEndSpeedup: "UNVERIFIED")
        if shouldCancel() { throw RoutingTelemetryStoreError.cancelled }
        try synchronized {
            try withWritableDerivedDatabase { db in
                try ensureSchema(db)
                try execute("BEGIN IMMEDIATE;", db)
                do {
                    if shouldCancel() { throw RoutingTelemetryStoreError.cancelled }
                    try saveAssessment(result, db: db)
                    try prune(db, now: now)
                    if shouldCancel() { throw RoutingTelemetryStoreError.cancelled }
                    try execute("COMMIT;", db)
                } catch { _ = try? execute("ROLLBACK;", db); throw error }
            }
        }
        return result
    }

    private func readSource(days: Int, now: Date, shouldCancel: @escaping @Sendable () -> Bool) throws -> (recent: [ThreadRow], allIDs: Set<String>, hasDuplicateIDs: Bool, edges: [Edge], readRows: Int) {
        guard FileManager.default.fileExists(atPath: sourceURL.path) else { throw RoutingTelemetryStoreError.sourceUnavailable }
        var db: OpaquePointer?; guard sqlite3_open_v2(sourceURL.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK, let db else { throw RoutingTelemetryStoreError.sourceUnavailable }; defer { sqlite3_close(db) }
        try execute("PRAGMA query_only=ON; BEGIN;", db); defer { _ = try? execute("ROLLBACK;", db) }
        let tables = try tableNames(db); guard tables.contains("threads"), tables.contains("thread_spawn_edges") else { throw RoutingTelemetryStoreError.schemaUnavailable }
        let cols = try columnNames("threads", db); guard let id = pick(["id", "thread_id"], cols) else { throw RoutingTelemetryStoreError.schemaUnavailable }
        let recency = timestampExpression(["recency_at_ms", "recency_at", "updated_at_ms", "updated_at", "created_at_ms", "created_at"], cols)
        guard recency != "NULL" else { throw RoutingTelemetryStoreError.schemaUnavailable }
        let created = timestampExpression(["created_at_ms", "created_at"], cols), updated = timestampExpression(["updated_at_ms", "updated_at"], cols)
        let field: (String) -> String = { self.pick([$0], cols).map(Self.identifier) ?? "NULL" }
        let role = textExpression(["agent_role", "role"], cols)
        let model = textExpression(["model", "model_name"], cols)
        let effort = textExpression(["reasoning_effort", "effort"], cols)
        let s = try prepare("SELECT \(Self.identifier(id)), \(recency), \(created), \(updated), \(field("tokens_used")), \(role), \(model), \(effort) FROM threads WHERE \(recency) >= ?;", db); defer { sqlite3_finalize(s) }
        sqlite3_bind_int64(s, 1, millis(startOfWindow(days: days, now: now)))
        var recent: [ThreadRow] = []
        while sqlite3_step(s) == SQLITE_ROW {
            if shouldCancel() { throw RoutingTelemetryStoreError.cancelled }
            guard let rawID = sqlite3_column_text(s, 0) else { continue }
            recent.append(ThreadRow(id: String(cString: rawID), recencyMs: integer(s, 1), createdMs: integer(s, 2), updatedMs: integer(s, 3), tokens: max(0, Int(integer(s, 4))), role: text(s, 5), model: text(s, 6), effort: text(s, 7)))
        }
        let ids = try prepare("SELECT \(Self.identifier(id)) FROM threads;", db); defer { sqlite3_finalize(ids) }; var allIDs: Set<String> = []; var hasDuplicateIDs = false
        while sqlite3_step(ids) == SQLITE_ROW { if shouldCancel() { throw RoutingTelemetryStoreError.cancelled }; if let value = text(ids, 0), !allIDs.insert(value).inserted { hasDuplicateIDs = true } }
        let edgeCols = try columnNames("thread_spawn_edges", db); guard let parent = pick(["parent_thread_id", "parent_id", "source_thread_id"], edgeCols), let child = pick(["child_thread_id", "child_id", "target_thread_id"], edgeCols) else { throw RoutingTelemetryStoreError.schemaUnavailable }
        let e = try prepare("SELECT \(Self.identifier(parent)), \(Self.identifier(child)) FROM thread_spawn_edges;", db); defer { sqlite3_finalize(e) }; var edges: [Edge] = []
        while sqlite3_step(e) == SQLITE_ROW { if shouldCancel() { throw RoutingTelemetryStoreError.cancelled }; if let p = text(e, 0), let c = text(e, 1), !p.isEmpty, !c.isEmpty { edges.append(Edge(parent: p, child: c)) } }
        return (recent, allIDs, hasDuplicateIDs, edges, recent.count + allIDs.count + edges.count)
    }

    private func makeMetric(_ rows: [ThreadRow], allIDs: Set<String>, hasDuplicateIDs: Bool, edges: [Edge], now: Date, readRows: Int, scanMilliseconds: Int, shouldCancel: @escaping @Sendable () -> Bool) throws -> MetricBuild {
        let recentIDs = Set(rows.map(\.id)), recentChildren = Set(edges.map(\.child)).intersection(recentIDs)
        let relevant = edges.filter { recentChildren.contains($0.child) }
        let parentMap = Dictionary(grouping: edges, by: \.child).mapValues { $0.map(\.parent) }
        if shouldCancel() { throw RoutingTelemetryStoreError.cancelled }
        let nodesWithParents = Set(parentMap.keys)
        let depthTwo = Set(recentChildren.filter { child in
            (parentMap[child] ?? []).contains(where: nodesWithParents.contains)
        })
        var cycleMemo: [String: Bool] = [:]
        func reachesCycle(_ node: String, path: inout Set<String>) throws -> Bool {
            if shouldCancel() { throw RoutingTelemetryStoreError.cancelled }
            if path.contains(node) { return true }
            if let cached = cycleMemo[node] { return cached }
            path.insert(node)
            var result = false
            for parent in parentMap[node] ?? [] {
                if try reachesCycle(parent, path: &path) {
                    result = true
                    break
                }
            }
            path.remove(node)
            cycleMemo[node] = result
            return result
        }
        var cycleAffectedChildren: Set<String> = []
        for child in recentChildren {
            var path: Set<String> = []
            if try reachesCycle(child, path: &path) {
                cycleAffectedChildren.insert(child)
            }
        }
        let childRows = rows.filter { recentChildren.contains($0.id) }
        let covered = childRows.filter { !$0.role.orEmpty.isEmpty && !$0.model.orEmpty.isEmpty && !$0.effort.orEmpty.isEmpty }.count
        let spans = rows.compactMap { row -> Int64? in
            guard row.createdMs > 0, row.updatedMs > 0 else { return nil }
            return max(Int64(0), row.updatedMs - row.createdMs)
        }.sorted()
        let median: Int64
        if spans.isEmpty {
            median = 0
        } else if spans.count.isMultiple(of: 2) {
            let upper = spans[spans.count / 2]
            let lower = spans[spans.count / 2 - 1]
            median = lower + (upper - lower) / 2
        } else {
            median = spans[spans.count / 2]
        }
        let orphanEdges = edges.filter { !allIDs.contains($0.parent) || !allIDs.contains($0.child) }.count
        let topology = hasDuplicateIDs ? nil : try makeStrictTopology(rows: rows, recentChildren: recentChildren, allIDs: allIDs, parentMap: parentMap, shouldCancel: shouldCancel)
        let quality: RoutingTelemetryQuality = rows.isEmpty || hasDuplicateIDs || !cycleAffectedChildren.isEmpty || orphanEdges > 0 ? .partial : .complete
        let metric = RoutingDailyMetric(dayKey: RoutingTelemetryScanPolicy.localDayKey(now), sourceThreads: rows.count, edgeCount: relevant.count, rootThreads: rows.filter { !recentChildren.contains($0.id) }.count, childThreads: childRows.count, roleMetadataCovered: covered, roleMetadataMissing: max(0, childRows.count - covered), depthAtLeastTwo: depthTwo.count, orphanEdges: orphanEdges, cycleAffectedChildren: cycleAffectedChildren.count, anonymousSolChildren: childRows.filter { $0.role.orEmpty.isEmpty && $0.model.orEmpty.lowercased().contains("sol") }.count, cumulativeTokens: rows.reduce(0) { saturated($0, $1.tokens) }, childCumulativeTokens: childRows.reduce(0) { saturated($0, $1.tokens) }, tokenDelta: 0, childTokenDelta: 0, missingBaselines: 0, tokenRollbacks: 0, createdToUpdatedMedianMilliseconds: median, readRows: readRows, derivedWrites: 0, scanMilliseconds: scanMilliseconds, quality: quality, roleBuckets: makeRoleBuckets(childRows), ultraTokenPartition: topology?.partition)
        return MetricBuild(metric: metric, strictClassifications: topology?.classifications ?? [:])
    }

    private func makeStrictTopology(rows: [ThreadRow], recentChildren: Set<String>, allIDs: Set<String>, parentMap: [String: [String]], shouldCancel: @escaping @Sendable () -> Bool) throws -> StrictTopology {
        let rowsByID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        let rootRows = rows.filter { parentMap[$0.id] == nil }
        let ultraRoots = rootRows.filter { isExactSolRoot($0, effort: "ultra") }
        let maxRoots = rootRows.filter { isExactSolRoot($0, effort: "max") }
        var attributedIDs: Set<String> = []
        for childID in recentChildren {
            if shouldCancel() { throw RoutingTelemetryStoreError.cancelled }
            var node = childID
            var visited: Set<String> = []
            var attributable = true
            while let parents = parentMap[node] {
                if !visited.insert(node).inserted || parents.count != 1 || !allIDs.contains(node) {
                    attributable = false
                    break
                }
                let parent = parents[0]
                guard allIDs.contains(parent) else { attributable = false; break }
                node = parent
            }
            guard attributable, visited.insert(node).inserted, let root = rowsByID[node], isExactSolRoot(root, effort: "ultra") else { continue }
            attributedIDs.insert(childID)
        }
        let attributedRows = rows.filter { attributedIDs.contains($0.id) }
        let unattributedRows = rows.filter { recentChildren.contains($0.id) && !attributedIDs.contains($0.id) }
        let partition = RoutingUltraTokenPartition(
            ultraRootThreads: ultraRoots.count,
            ultraRootCumulativeTokens: ultraRoots.reduce(0) { saturated($0, $1.tokens) },
            maxRootThreads: maxRoots.count,
            maxRootCumulativeTokens: maxRoots.reduce(0) { saturated($0, $1.tokens) },
            attributedUltraChildThreads: attributedRows.count,
            attributedUltraChildCumulativeTokens: attributedRows.reduce(0) { saturated($0, $1.tokens) },
            unattributedChildThreads: unattributedRows.count,
            unattributedChildCumulativeTokens: unattributedRows.reduce(0) { saturated($0, $1.tokens) }
        )
        var classifications = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, "other") })
        for root in ultraRoots { classifications[root.id] = "root" }
        for childID in attributedIDs { classifications[childID] = "child" }
        return StrictTopology(partition: partition, classifications: classifications)
    }

    private func isExactSolRoot(_ row: ThreadRow, effort: String) -> Bool {
        normalized(row.model) == "gpt-5.6-sol" && normalized(row.effort) == effort
    }

    private func normalized(_ value: String?) -> String {
        value.orEmpty.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func withExistingDerivedDatabase<T>(_ body: (OpaquePointer) throws -> T) throws -> T { var db: OpaquePointer?; guard sqlite3_open_v2(databaseURL.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK, let db else { throw RoutingTelemetryStoreError.sqlite("open readonly") }; defer { sqlite3_close(db) }; return try body(db) }
    private func withWritableDerivedDatabase<T>(_ body: (OpaquePointer) throws -> T) throws -> T { try FileManager.default.createDirectory(at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true); try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: databaseURL.deletingLastPathComponent().path); var db: OpaquePointer?; guard sqlite3_open_v2(databaseURL.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK, let db else { throw RoutingTelemetryStoreError.sqlite("open derived") }; defer { sqlite3_close(db) }; try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: databaseURL.path); return try body(db) }
    private func ensureSchema(_ db: OpaquePointer) throws {
        try execute("CREATE TABLE IF NOT EXISTS routing_daily(day_key TEXT PRIMARY KEY, observed_at_ms INTEGER NOT NULL, payload BLOB NOT NULL, quality TEXT NOT NULL); CREATE TABLE IF NOT EXISTS routing_baselines(thread_key TEXT PRIMARY KEY, tokens INTEGER NOT NULL, last_seen_ms INTEGER NOT NULL, strict_class TEXT); CREATE TABLE IF NOT EXISTS routing_assessments(id INTEGER PRIMARY KEY, generated_at_ms INTEGER NOT NULL, period_days INTEGER NOT NULL, payload BLOB NOT NULL);", db)
        if try !columnNames("routing_baselines", db).contains("strict_class") {
            try execute("ALTER TABLE routing_baselines ADD COLUMN strict_class TEXT;", db)
        }
    }
    private func loadDaily(_ db: OpaquePointer, days: Int) throws -> [StoredDaily] { let s = try prepare("SELECT observed_at_ms,payload FROM routing_daily ORDER BY day_key DESC LIMIT ?;", db); defer { sqlite3_finalize(s) }; sqlite3_bind_int(s, 1, Int32(days)); var values: [StoredDaily] = []; while sqlite3_step(s) == SQLITE_ROW, let bytes = sqlite3_column_blob(s, 1), let metric = try? JSONDecoder().decode(RoutingDailyMetric.self, from: Data(bytes: bytes, count: Int(sqlite3_column_bytes(s, 1)))) { values.append(StoredDaily(metric: metric, observedAt: Date(timeIntervalSince1970: Double(sqlite3_column_int64(s, 0)) / 1000))) }; return Array(values.reversed()) }
    private func loadDaily(dayKey: String, db: OpaquePointer) throws -> RoutingDailyMetric? { let s = try prepare("SELECT payload FROM routing_daily WHERE day_key=?;", db); defer { sqlite3_finalize(s) }; sqlite3_bind_text(s, 1, dayKey, -1, Self.transient); guard sqlite3_step(s) == SQLITE_ROW, let bytes = sqlite3_column_blob(s, 0) else { return nil }; return try? JSONDecoder().decode(RoutingDailyMetric.self, from: Data(bytes: bytes, count: Int(sqlite3_column_bytes(s, 0)))) }
    private func latestObservedAt(_ db: OpaquePointer) throws -> Date? { let s = try prepare("SELECT max(observed_at_ms) FROM routing_daily;", db); defer { sqlite3_finalize(s) }; guard sqlite3_step(s) == SQLITE_ROW, sqlite3_column_type(s, 0) != SQLITE_NULL else { return nil }; return Date(timeIntervalSince1970: Double(sqlite3_column_int64(s, 0)) / 1000) }
    private func loadLatestAssessment(_ db: OpaquePointer) throws -> RoutingAssessment? { let s = try prepare("SELECT payload FROM routing_assessments ORDER BY generated_at_ms DESC LIMIT 1;", db); defer { sqlite3_finalize(s) }; guard sqlite3_step(s) == SQLITE_ROW, let bytes = sqlite3_column_blob(s, 0) else { return nil }; return try? JSONDecoder().decode(RoutingAssessment.self, from: Data(bytes: bytes, count: Int(sqlite3_column_bytes(s, 0)))) }
    private func upsertDaily(_ metric: RoutingDailyMetric, observedAt: Date, db: OpaquePointer) throws { let s = try prepare("INSERT INTO routing_daily(day_key,observed_at_ms,payload,quality) VALUES(?,?,?,?) ON CONFLICT(day_key) DO UPDATE SET observed_at_ms=excluded.observed_at_ms,payload=excluded.payload,quality=excluded.quality;", db); defer { sqlite3_finalize(s) }; let data = try JSONEncoder().encode(metric); sqlite3_bind_text(s, 1, metric.dayKey, -1, Self.transient); sqlite3_bind_int64(s, 2, millis(observedAt)); _ = data.withUnsafeBytes { sqlite3_bind_blob(s, 3, $0.baseAddress, Int32(data.count), Self.transient) }; sqlite3_bind_text(s, 4, metric.quality.rawValue, -1, Self.transient); guard sqlite3_step(s) == SQLITE_DONE else { throw RoutingTelemetryStoreError.sqlite("daily write") } }
    private func saveAssessment(_ value: RoutingAssessment, db: OpaquePointer) throws { let s = try prepare("INSERT INTO routing_assessments(generated_at_ms,period_days,payload) VALUES(?,?,?);", db); defer { sqlite3_finalize(s) }; let data = try JSONEncoder().encode(value); sqlite3_bind_int64(s, 1, millis(value.generatedAt)); sqlite3_bind_int(s, 2, Int32(value.periodDays)); _ = data.withUnsafeBytes { sqlite3_bind_blob(s, 3, $0.baseAddress, Int32(data.count), Self.transient) }; guard sqlite3_step(s) == SQLITE_DONE else { throw RoutingTelemetryStoreError.sqlite("assessment write") } }
    private func updateBaselines(_ rows: [ThreadRow], childRoleKeys: [String: String], strictClassifications: [String: String], previousObservedAt: Date?, db: OpaquePointer, now: Date, shouldCancel: @escaping @Sendable () -> Bool) throws -> (totalDelta: Int, childDelta: Int, roleDeltas: [String: Int], missing: Int, rollbacks: Int, writes: Int, quality: RoutingTelemetryQuality, strictRootDelta: Int, strictChildDelta: Int, strictEvidenceComplete: Bool) {
        let read = try prepare("SELECT tokens,last_seen_ms,strict_class FROM routing_baselines WHERE thread_key=?;", db)
        let write = try prepare("INSERT INTO routing_baselines(thread_key,tokens,last_seen_ms,strict_class) VALUES(?,?,?,?) ON CONFLICT(thread_key) DO UPDATE SET tokens=excluded.tokens,last_seen_ms=excluded.last_seen_ms,strict_class=excluded.strict_class;", db)
        defer { sqlite3_finalize(read); sqlite3_finalize(write) }
        var total = 0, child = 0, missing = 0, rollbacks = 0, strictRoot = 0, strictChild = 0
        var roleDeltas: [String: Int] = [:]
        var strictEvidenceComplete = true
        for row in rows {
            if shouldCancel() { throw RoutingTelemetryStoreError.cancelled }
            let key = Self.hash(row.id)
            let currentClass = strictClassifications[row.id] ?? "other"
            let isStrictParticipant = currentClass == "root" || currentClass == "child"
            sqlite3_reset(read); sqlite3_clear_bindings(read); sqlite3_bind_text(read, 1, key, -1, Self.transient)
            let found = sqlite3_step(read) == SQLITE_ROW
            let prior = found ? Int(sqlite3_column_int64(read, 0)) : 0
            let priorSeen = found ? sqlite3_column_int64(read, 1) : 0
            let priorClass = found ? text(read, 2) : nil
            let newlyCreated = !found && previousObservedAt.map { row.createdMs > millis($0) } == true
            let increase: Int?
            if !found && !newlyCreated { missing += 1; increase = nil }
            else if row.tokens < prior { rollbacks += 1; increase = nil }
            else { increase = row.tokens - prior }
            if let increase {
                total = saturated(total, increase)
                if let roleKey = childRoleKeys[row.id] {
                    child = saturated(child, increase)
                    roleDeltas[roleKey] = saturated(roleDeltas[roleKey] ?? 0, increase)
                }
            }

            // Strict daily guidance may use an increment only when the same hashed
            // observation lineage and a non-sensitive root/child/other class agree.
            let stale = found && millis(now) - priorSeen > 48 * 3600 * 1000
            let classDrift = found && priorClass != currentClass
            let unsafeStrictLine = isStrictParticipant && ((!found && !newlyCreated) || (found && (priorClass == nil || stale || row.tokens < prior)))
            if classDrift || unsafeStrictLine { strictEvidenceComplete = false }
            if isStrictParticipant, !classDrift, !unsafeStrictLine, let increase {
                if currentClass == "root" { strictRoot = saturated(strictRoot, increase) }
                else { strictChild = saturated(strictChild, increase) }
            }

            sqlite3_reset(write); sqlite3_clear_bindings(write)
            sqlite3_bind_text(write, 1, key, -1, Self.transient)
            sqlite3_bind_int64(write, 2, Int64(row.tokens))
            sqlite3_bind_int64(write, 3, millis(now))
            sqlite3_bind_text(write, 4, currentClass, -1, Self.transient)
            guard sqlite3_step(write) == SQLITE_DONE else { throw RoutingTelemetryStoreError.sqlite("baseline write") }
        }
        return (total, child, roleDeltas, missing, rollbacks, rows.count, missing > 0 || rollbacks > 0 ? .partial : .complete, strictRoot, strictChild, strictEvidenceComplete)
    }
    private func mergingDailyStrictDelta(_ metric: RoutingDailyMetric, baseline: (totalDelta: Int, childDelta: Int, roleDeltas: [String: Int], missing: Int, rollbacks: Int, writes: Int, quality: RoutingTelemetryQuality, strictRootDelta: Int, strictChildDelta: Int, strictEvidenceComplete: Bool), prior: RoutingDailyMetric?) -> RoutingDailyMetric {
        guard let partition = metric.ultraTokenPartition else { return metric }
        let priorPartition = prior?.ultraTokenPartition
        let priorHasStrictDelta = priorPartition?.ultraRootDailyObservedTokenDelta != nil
            && priorPartition?.attributedUltraChildDailyObservedTokenDelta != nil
            && priorPartition?.dailyDeltaEvidenceComplete != nil
        let priorObservations = prior == nil ? 0 : (priorPartition?.dailyMergeObservationCount ?? 1)
        let root = priorHasStrictDelta ? saturated(priorPartition?.ultraRootDailyObservedTokenDelta ?? 0, baseline.strictRootDelta) : baseline.strictRootDelta
        let child = priorHasStrictDelta ? saturated(priorPartition?.attributedUltraChildDailyObservedTokenDelta ?? 0, baseline.strictChildDelta) : baseline.strictChildDelta
        let evidenceComplete = prior == nil
            ? baseline.strictEvidenceComplete
            : priorHasStrictDelta && priorPartition?.dailyDeltaEvidenceComplete == true && baseline.strictEvidenceComplete
        let mergedPartition = partition.withDailyObservedDelta(root: root, child: child, evidenceComplete: evidenceComplete, mergeObservationCount: priorObservations + 1)
        return RoutingDailyMetric(dayKey: metric.dayKey, sourceThreads: metric.sourceThreads, edgeCount: metric.edgeCount, rootThreads: metric.rootThreads, childThreads: metric.childThreads, roleMetadataCovered: metric.roleMetadataCovered, roleMetadataMissing: metric.roleMetadataMissing, depthAtLeastTwo: metric.depthAtLeastTwo, orphanEdges: metric.orphanEdges, cycleAffectedChildren: metric.cycleAffectedChildren, anonymousSolChildren: metric.anonymousSolChildren, cumulativeTokens: metric.cumulativeTokens, childCumulativeTokens: metric.childCumulativeTokens, tokenDelta: metric.tokenDelta, childTokenDelta: metric.childTokenDelta, missingBaselines: metric.missingBaselines, tokenRollbacks: metric.tokenRollbacks, createdToUpdatedMedianMilliseconds: metric.createdToUpdatedMedianMilliseconds, readRows: metric.readRows, derivedWrites: metric.derivedWrites, scanMilliseconds: metric.scanMilliseconds, quality: metric.quality, roleBuckets: metric.roleBuckets, ultraTokenPartition: mergedPartition)
    }
    private func prune(_ db: OpaquePointer, now: Date) throws { let calendar = Calendar.current; let retainedDayStart = calendar.date(byAdding: .day, value: -(RoutingTelemetryScanPolicy.dayRetention - 1), to: calendar.startOfDay(for: now)) ?? now; let dailyCutoff = RoutingTelemetryScanPolicy.localDayKey(retainedDayStart); let assessmentCutoff = millis(retainedDayStart); let baselineCutoff = millis(calendar.date(byAdding: .day, value: -RoutingTelemetryScanPolicy.baselineRetentionDays, to: calendar.startOfDay(for: now)) ?? now); for (sql, value) in [("DELETE FROM routing_daily WHERE day_key < ?;", dailyCutoff), ("DELETE FROM routing_assessments WHERE generated_at_ms < ?;", String(assessmentCutoff)), ("DELETE FROM routing_baselines WHERE last_seen_ms < ?;", String(baselineCutoff))] { let s = try prepare(sql, db); defer { sqlite3_finalize(s) }; if sql.contains("daily") { sqlite3_bind_text(s, 1, value, -1, Self.transient) } else { sqlite3_bind_int64(s, 1, Int64(value) ?? 0) }; guard sqlite3_step(s) == SQLITE_DONE else { throw RoutingTelemetryStoreError.sqlite("prune") } } }
    private func synchronized<T>(_ body: () throws -> T) rethrows -> T { lock.lock(); defer { lock.unlock() }; return try body() }
    private func replacing(_ m: RoutingDailyMetric, tokenDelta: Int, childTokenDelta: Int, roleTokenDeltas: [String: Int], missingBaselines: Int, tokenRollbacks: Int, derivedWrites: Int, quality: RoutingTelemetryQuality) -> RoutingDailyMetric { RoutingDailyMetric(dayKey: m.dayKey, sourceThreads: m.sourceThreads, edgeCount: m.edgeCount, rootThreads: m.rootThreads, childThreads: m.childThreads, roleMetadataCovered: m.roleMetadataCovered, roleMetadataMissing: m.roleMetadataMissing, depthAtLeastTwo: m.depthAtLeastTwo, orphanEdges: m.orphanEdges, cycleAffectedChildren: m.cycleAffectedChildren, anonymousSolChildren: m.anonymousSolChildren, cumulativeTokens: m.cumulativeTokens, childCumulativeTokens: m.childCumulativeTokens, tokenDelta: tokenDelta, childTokenDelta: childTokenDelta, missingBaselines: missingBaselines, tokenRollbacks: tokenRollbacks, createdToUpdatedMedianMilliseconds: m.createdToUpdatedMedianMilliseconds, readRows: m.readRows, derivedWrites: derivedWrites, scanMilliseconds: m.scanMilliseconds, quality: quality, roleBuckets: m.roleBuckets?.map { $0.withTokenDelta(roleTokenDeltas[$0.id] ?? 0) }, ultraTokenPartition: m.ultraTokenPartition) }
    private func roleBucketKey(_ rawRole: String?) -> String { RoutingRegisteredRole(rawValue: rawRole ?? "")?.rawValue ?? "unknown" }
    private func makeRoleBuckets(_ childRows: [ThreadRow]) -> [RoutingRoleBucket] {
        var counts = Dictionary(uniqueKeysWithValues: RoutingRegisteredRole.allCases.map { ($0.rawValue, (threads: 0, tokens: 0, complete: 0, matched: 0)) })
        var unknown = (threads: 0, tokens: 0, complete: 0)
        for row in childRows {
            let key = roleBucketKey(row.role)
            let isComplete = !row.role.orEmpty.isEmpty && !row.model.orEmpty.isEmpty && !row.effort.orEmpty.isEmpty
            if key == "unknown" { unknown.threads += 1; unknown.tokens = saturated(unknown.tokens, row.tokens); if isComplete { unknown.complete += 1 } }
            else if var value = counts[key] {
                value.threads += 1
                value.tokens = saturated(value.tokens, row.tokens)
                if isComplete { value.complete += 1 }
                if RoutingRegisteredRole(rawValue: key)?.matches(model: row.model, effort: row.effort) == true { value.matched += 1 }
                counts[key] = value
            }
        }
        var result = RoutingRegisteredRole.allCases.map { role -> RoutingRoleBucket in
            let value = counts[role.rawValue]!
            return RoutingRoleBucket(role: role, childThreads: value.threads, cumulativeTokens: value.tokens, tokenDelta: 0, identityCompleteThreads: value.complete, identityMatchedThreads: value.matched)
        }
        if unknown.threads > 0 {
            result.append(RoutingRoleBucket(role: nil, childThreads: unknown.threads, cumulativeTokens: unknown.tokens, tokenDelta: 0, identityCompleteThreads: unknown.complete, identityMatchedThreads: nil))
        }
        return result
    }
    private func textExpression(_ candidates: [String], _ columns: Set<String>) -> String {
        let values = candidates.filter(columns.contains).map { "NULLIF(\(Self.identifier($0)), '')" }
        if values.isEmpty { return "NULL" }
        return values.count == 1 ? values[0] : "COALESCE(\(values.joined(separator: ",")))"
    }
    private func timestampExpression(_ candidates: [String], _ columns: Set<String>) -> String { let values = candidates.filter(columns.contains).map { name in let col = Self.identifier(name); return name.hasSuffix("_ms") ? "NULLIF(\(col),0)" : "NULLIF(\(col),0) * 1000" }; if values.isEmpty { return "NULL" }; return values.count == 1 ? values[0] : "COALESCE(\(values.joined(separator: ",")))" }
    private func tableNames(_ db: OpaquePointer) throws -> Set<String> { let s = try prepare("SELECT name FROM sqlite_master WHERE type='table';", db); defer { sqlite3_finalize(s) }; var result: Set<String> = []; while sqlite3_step(s) == SQLITE_ROW { if let t = text(s, 0) { result.insert(t) } }; return result }
    private func columnNames(_ table: String, _ db: OpaquePointer) throws -> Set<String> { let s = try prepare("PRAGMA table_info(\(Self.identifier(table)));", db); defer { sqlite3_finalize(s) }; var result: Set<String> = []; while sqlite3_step(s) == SQLITE_ROW { if let t = text(s, 1) { result.insert(t) } }; return result }
    private func prepare(_ sql: String, _ db: OpaquePointer) throws -> OpaquePointer { var s: OpaquePointer?; guard sqlite3_prepare_v2(db, sql, -1, &s, nil) == SQLITE_OK, let s else { throw RoutingTelemetryStoreError.sqlite(String(cString: sqlite3_errmsg(db))) }; return s }
    private func execute(_ sql: String, _ db: OpaquePointer) throws { guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw RoutingTelemetryStoreError.sqlite(String(cString: sqlite3_errmsg(db))) } }
    private func pick(_ candidates: [String], _ values: Set<String>) -> String? { candidates.first(where: values.contains) }
    private func integer(_ s: OpaquePointer, _ index: Int32) -> Int64 { sqlite3_column_type(s, index) == SQLITE_NULL ? 0 : sqlite3_column_int64(s, index) }
    private func text(_ s: OpaquePointer, _ index: Int32) -> String? { guard sqlite3_column_type(s, index) != SQLITE_NULL, let value = sqlite3_column_text(s, index) else { return nil }; return String(cString: value) }
    private func startOfWindow(days: Int, now: Date) -> Date { Calendar.current.date(byAdding: .day, value: -(max(1, days) - 1), to: Calendar.current.startOfDay(for: now)) ?? now }
    private func millis(_ date: Date) -> Int64 { Int64(date.timeIntervalSince1970 * 1000) }
    private func saturated(_ a: Int, _ b: Int) -> Int { let (v, overflow) = a.addingReportingOverflow(b); return overflow ? Int.max : v }
    private func worse(_ a: RoutingTelemetryQuality, _ b: RoutingTelemetryQuality) -> RoutingTelemetryQuality { a == .unavailable || b == .unavailable ? .unavailable : (a == .partial || b == .partial ? .partial : .complete) }
    private static func identifier(_ name: String) -> String { "\"\(name.replacingOccurrences(of: "\"", with: "\"\""))\"" }
    private static func hash(_ id: String) -> String { SHA256.hash(data: Data(id.utf8)).map { String(format: "%02x", $0) }.joined() }
}

private extension Optional where Wrapped == String { var orEmpty: String { self ?? "" } }
