import Foundation

final class TestRunner {
    private(set) var failures = 0

    func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard !condition() else { return }
        failures += 1
        FileHandle.standardError.write(Data("FAILED: \(message)\n".utf8))
    }

    func checkEqual<T: Equatable>(_ actual: @autoclosure () -> T, _ expected: T, _ message: String) {
        let actual = actual()
        guard actual == expected else {
            failures += 1
            FileHandle.standardError.write(
                Data("FAILED: \(message) (actual: \(actual), expected: \(expected))\n".utf8)
            )
            return
        }
    }
}

final class RefreshCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() { lock.lock(); value += 1; lock.unlock() }
    func read() -> Int { lock.lock(); defer { lock.unlock() }; return value }
}

private struct LegacyWindow: Codable {
    let pool: AntigravityQuotaPool
    let label: String
    let remainingPercent: Int
    let resetsAt: Int?
}

private struct LegacyCachePayload: Codable {
    let source: String
    let receivedAt: Date
    let sourceUpdatedAt: Date?
    let primary: LegacyWindow
    let secondary: LegacyWindow
}

let runner = TestRunner()
let now = Date(timeIntervalSince1970: 1_800_000_000)
let updatedAt = Int(now.timeIntervalSince1970) - 30
let updatedAtISO = ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: TimeInterval(updatedAt)))
let primaryFiveResetAt = 1_800_001_200
let primaryWeeklyResetAt = 1_800_604_800
let secondaryFiveResetAt = 1_800_002_400
let secondaryWeeklyResetAt = 1_800_700_000

let fullOutput = """
warning: local helper diagnostic
[{"provider":"antigravity","source":"local","usage":{"accountEmail":"private@example.com","identity":{"id":"private"},"loginMethod":"private","primary":{"usedPercent":120,"resetsAt":"\(primaryFiveResetAt)"},"secondary":{"usedPercent":-4,"resetsAt":"\(secondaryFiveResetAt)"},"updatedAt":"\(updatedAtISO)","extraRateWindows":[
  {"id":"gemini-5h","title":"Gemini 5-hour","window":{"usedPercent":12,"windowMinutes":300,"resetsAt":\(primaryFiveResetAt)}},
  {"id":"gemini-weekly","title":"Gemini weekly","window":{"usedPercent":37,"windowMinutes":10080,"resetsAt":\(primaryWeeklyResetAt)}},
  {"id":"claude-gpt-5h","title":"Claude/GPT 5-hour","window":{"usedPercent":42,"windowMinutes":300,"resetsAt":\(secondaryFiveResetAt)}},
  {"id":"claude-gpt-weekly","title":"Claude/GPT weekly","window":{"usedPercent":55,"windowMinutes":10080,"resetsAt":\(secondaryWeeklyResetAt)}},
  {"id":"unrelated","title":"Other provider weekly","window":{"usedPercent":99,"windowMinutes":10080,"resetsAt":\(secondaryWeeklyResetAt)}}
]}}]
"""

do {
    let reading = try AntigravityQuotaParser.parse(fullOutput, receivedAt: now)
    runner.checkEqual(reading.source, "local", "parser should retain only local provenance")
    runner.checkEqual(reading.primaryFiveHour.pool, .primary, "5h primary pool should map to Gemini")
    runner.checkEqual(reading.primaryFiveHour.period, .fiveHour, "primary representative should be 5h")
    runner.checkEqual(reading.secondaryFiveHour.pool, .secondary, "5h secondary pool should map to Claude + GPT")
    runner.checkEqual(reading.primaryFiveHour.remainingPercent, Optional(88), "extra 5h window should override representative primary")
    runner.checkEqual(reading.primarySevenDay?.remainingPercent, Optional(63), "Gemini weekly remaining percent should decode")
    runner.checkEqual(reading.secondaryFiveHour.remainingPercent, Optional(58), "Claude/GPT 5h remaining percent should decode")
    runner.checkEqual(reading.secondarySevenDay?.remainingPercent, Optional(45), "Claude/GPT weekly remaining percent should decode")
    runner.checkEqual(reading.primaryFiveHour.resetsAt, Optional(primaryFiveResetAt), "primary 5h reset should decode")
    runner.checkEqual(reading.primarySevenDay?.resetsAt, Optional(primaryWeeklyResetAt), "primary weekly reset should decode")
    runner.checkEqual(reading.sourceUpdatedAt, Date(timeIntervalSince1970: TimeInterval(updatedAt)), "updatedAt should decode")

    let entry = AntigravityQuotaCacheEntry(reading: reading)
    let testRoot = ProcessInfo.processInfo.environment["AGY_TEST_TMPDIR"]
        .map { URL(fileURLWithPath: $0, isDirectory: true) }
        ?? FileManager.default.temporaryDirectory
    let cacheDirectory = testRoot
        .appendingPathComponent("codex-notch-agy-\(UUID().uuidString)", isDirectory: true)
    let cacheURL = cacheDirectory.appendingPathComponent("antigravity-quota.json")
    let cache = AntigravityQuotaCache(fileURL: cacheURL)
    try cache.save(entry)
    let reloaded = try cache.load()
    runner.checkEqual(reloaded, entry, "new four-window cache should round-trip")
    let permissions = try FileManager.default.attributesOfItem(atPath: cacheURL.path)[.posixPermissions] as? NSNumber
    runner.checkEqual(permissions.map { $0.intValue & 0o777 }, 0o600, "cache file should be mode 0600")
    let persisted = String(decoding: try Data(contentsOf: cacheURL), as: UTF8.self)
    runner.check(!persisted.contains("accountEmail"), "accountEmail must not enter cache")
    runner.check(!persisted.contains("identity"), "identity must not enter cache")
    runner.check(!persisted.contains("loginMethod"), "loginMethod must not enter cache")
    runner.check(!persisted.contains("unrelated"), "unknown extra window metadata must not enter cache")
    runner.check(!persisted.contains("title"), "raw window title must not enter cache")
    runner.check(!persisted.contains("description"), "raw reset description must not enter cache")
    runner.check(persisted.contains("fiveHour"), "normalized period must enter cache")
    runner.check(persisted.contains("sevenDay"), "normalized weekly period must enter cache")
    try? FileManager.default.removeItem(at: cacheDirectory)
} catch {
    runner.check(false, "full four-window parser/cache path threw \(error)")
}

let usageUnknownOutput = """
{"provider":"antigravity","source":"local","usage":{"primary":{"usedPercent":12},"secondary":{"usedPercent":13},"extraRateWindows":[
  {"id":"gemini-weekly","title":"Gemini weekly","usageKnown":false,"window":{"usedPercent":0,"windowMinutes":10080,"resetsAt":1800604800}},
  {"id":"claude-gpt-weekly","title":"Claude/GPT weekly","window":{"usedPercent":0,"windowMinutes":10080,"resetsAt":1800700000,"isSyntheticPlaceholder":true}}
]}}
"""
do {
    let reading = try AntigravityQuotaParser.parse(usageUnknownOutput, receivedAt: now)
    runner.checkEqual(reading.primarySevenDay?.remainingPercent, Optional<Int>.none, "usageKnown=false must not become 100% remaining")
    runner.checkEqual(reading.primarySevenDay?.resetsAt, Optional(1_800_604_800), "unknown weekly window should retain reset")
    runner.checkEqual(reading.secondarySevenDay?.remainingPercent, Optional<Int>.none, "synthetic placeholder must not become 100% remaining")
    runner.checkEqual(reading.secondarySevenDay?.resetsAt, Optional(1_800_700_000), "synthetic placeholder should retain reset")
} catch {
    runner.check(false, "usageKnown=false parser path threw \(error)")
}

let missingWeeklyOutput = """
{"provider":"antigravity","source":"local","usage":{"primary":{"usedPercent":20},"secondary":{"usedPercent":30},"extraRateWindows":[{"id":"unknown","title":"unrelated","window":{"usedPercent":0,"windowMinutes":10080}}]}}
"""
do {
    let reading = try AntigravityQuotaParser.parse(missingWeeklyOutput, receivedAt: now)
    runner.checkEqual(reading.primarySevenDay, nil, "missing explicit weekly must remain nil")
    runner.checkEqual(reading.secondarySevenDay, nil, "unknown weekly must be ignored")
} catch {
    runner.check(false, "missing weekly parser path threw \(error)")
}

let legacyOutput = """
{"provider":"antigravity","source":"local","usage":{"primary":{"usedPercent":120,"resetsAt":1800001200},"secondary":{"usedPercent":-4,"resetsAt":1800002400}}}
"""
do {
    let reading = try AntigravityQuotaParser.parse(legacyOutput, receivedAt: now)
    runner.checkEqual(reading.primary.period, .fiveHour, "legacy primary should decode as 5h")
    runner.checkEqual(reading.secondary.period, .fiveHour, "legacy secondary should decode as 5h")
    runner.checkEqual(reading.primarySevenDay, nil, "legacy payload must not synthesize weekly")
    runner.checkEqual(reading.secondarySevenDay, nil, "legacy payload must not synthesize weekly")
    runner.checkEqual(reading.primary.remainingPercent, Optional(0), "legacy primary should clamp to zero")
    runner.checkEqual(reading.secondary.remainingPercent, Optional(100), "legacy secondary should clamp to one hundred")
} catch {
    runner.check(false, "legacy two-pool parser path threw \(error)")
}

do {
    let testRoot = ProcessInfo.processInfo.environment["AGY_TEST_TMPDIR"]
        .map { URL(fileURLWithPath: $0, isDirectory: true) }
        ?? FileManager.default.temporaryDirectory
    let cacheDirectory = testRoot.appendingPathComponent("codex-notch-agy-legacy-\(UUID().uuidString)", isDirectory: true)
    let cacheURL = cacheDirectory.appendingPathComponent("antigravity-quota.json")
    try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    let legacyPayload = LegacyCachePayload(
        source: "local",
        receivedAt: now,
        sourceUpdatedAt: now,
        primary: LegacyWindow(pool: .primary, label: "Gemini", remainingPercent: 31, resetsAt: 1800001200),
        secondary: LegacyWindow(pool: .secondary, label: "Claude + GPT", remainingPercent: 41, resetsAt: 1800002400)
    )
    try JSONEncoder().encode(legacyPayload).write(to: cacheURL)
    let reloaded = try AntigravityQuotaCache(fileURL: cacheURL).load()
    runner.checkEqual(reloaded?.primary.period, .fiveHour, "old cache primary should default to 5h")
    runner.checkEqual(reloaded?.secondary.period, .fiveHour, "old cache secondary should default to 5h")
    runner.checkEqual(reloaded?.primaryWeekly, nil, "old cache must have no weekly primary")
    runner.checkEqual(reloaded?.secondaryWeekly, nil, "old cache must have no weekly secondary")
    try? FileManager.default.removeItem(at: cacheDirectory)
} catch {
    runner.check(false, "legacy cache decode path threw \(error)")
}

do {
    let invalidPrimary = AntigravityQuotaWindow(pool: .primary, period: .sevenDay, remainingPercent: 4, resetsAt: nil)
    let validSecondary = AntigravityQuotaWindow(pool: .secondary, period: .fiveHour, remainingPercent: 4, resetsAt: nil)
    let invalidEntry = AntigravityQuotaCacheEntry(
        source: "cli",
        receivedAt: now,
        sourceUpdatedAt: nil,
        primaryFiveHour: invalidPrimary,
        secondaryFiveHour: validSecondary
    )
    let cacheURL = FileManager.default.temporaryDirectory.appendingPathComponent("codex-notch-agy-invalid-\(UUID().uuidString).json")
    do {
        try AntigravityQuotaCache(fileURL: cacheURL).save(invalidEntry)
        runner.check(false, "cache should reject a primary period mismatch")
    } catch let error as AntigravityQuotaCacheError {
        runner.checkEqual(error, .invalidEntry, "cache should validate pool and period")
    }
    try? FileManager.default.removeItem(at: cacheURL)
} catch {
    runner.check(false, "cache validation path threw \(error)")
}

do {
    let cacheDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("codex-notch-agy-foreign-source-\(UUID().uuidString)", isDirectory: true)
    let cacheURL = cacheDirectory.appendingPathComponent("antigravity-quota.json")
    try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    let foreignEntry = AntigravityQuotaCacheEntry(
        source: "cli",
        receivedAt: now,
        sourceUpdatedAt: nil,
        primaryFiveHour: AntigravityQuotaWindow(pool: .primary, period: .fiveHour, remainingPercent: 80, resetsAt: nil),
        secondaryFiveHour: AntigravityQuotaWindow(pool: .secondary, period: .fiveHour, remainingPercent: 70, resetsAt: nil)
    )
    try JSONEncoder().encode(foreignEntry).write(to: cacheURL)
    do {
        _ = try AntigravityQuotaCache(fileURL: cacheURL).load()
        runner.check(false, "helper-produced cache must not be relabeled as native local evidence")
    } catch let error as AntigravityQuotaCacheError {
        runner.checkEqual(error, .invalidEntry, "foreign cache source should be rejected")
    }
    try? FileManager.default.removeItem(at: cacheDirectory)
} catch {
    runner.check(false, "foreign cache source fixture threw \(error)")
}

runner.checkEqual(
    AntigravityQuotaPolicy.freshness(receivedAt: now.addingTimeInterval(-900), now: now),
    .fresh,
    "15 minute cache should be fresh"
)
runner.checkEqual(
    AntigravityQuotaPolicy.freshness(receivedAt: now.addingTimeInterval(-901), now: now),
    .stale,
    "cache after 15 minutes should enter stale grace"
)
runner.checkEqual(
    AntigravityQuotaPolicy.freshness(receivedAt: now.addingTimeInterval(-1_801), now: now),
    .expired,
    "cache after 30 minutes should expire"
)
runner.check(AntigravityQuotaPolicy.requiresRefresh(receivedAt: now.addingTimeInterval(-901), now: now), "stale cache should refresh when presented")
runner.check(!AntigravityQuotaPolicy.isWithinStaleGrace(receivedAt: now.addingTimeInterval(-1_801), now: now), "expired cache should not remain visible as stale")

runner.checkEqual(AntigravityLocalProbe.maximumResponseBytes, 256 * 1024, "response cap must remain bounded")
runner.checkEqual(AntigravityLocalProbe.startupBackoffNanoseconds.count, 4, "startup retry count must remain bounded")
runner.checkEqual(AntigravityLocalProbe.startupBackoffNanoseconds.reduce(0, +), 2_200_000_000, "startup retry delay budget must remain bounded")
runner.check(AntigravityLocalProbe.accepts(host: "127.0.0.1", port: 8443, allowedPorts: [8443]), "exact launched loopback port is allowed")
runner.check(!AntigravityLocalProbe.accepts(host: "localhost", port: 8443, allowedPorts: [8443]), "localhost alias is not accepted")
runner.check(!AntigravityLocalProbe.accepts(host: "127.0.0.1", port: 8444, allowedPorts: [8443]), "unowned port is not accepted")
runner.check(!AntigravityLocalPortDiscovery.valid(port: 0), "invalid port is rejected")
runner.check(AntigravityLocalSessionPolicy.ownsPrivateProcessGroup(rootPID: 42, groupPID: 42), "only a private launched process group may be terminated")
runner.check(!AntigravityLocalSessionPolicy.ownsPrivateProcessGroup(rootPID: 42, groupPID: 7), "foreign process groups must never be terminated")
runner.check(AntigravityLocalProbe.acceptsResponse(host: "127.0.0.1", port: 8443, statusCode: 200, expectedBytes: 12, actualBytes: 12, redirected: false), "bounded loopback response is accepted")
runner.check(!AntigravityLocalProbe.acceptsResponse(host: "127.0.0.1", port: 8443, statusCode: 200, expectedBytes: Int64(AntigravityLocalProbe.maximumResponseBytes + 1), actualBytes: 0, redirected: false), "declared oversized response is rejected")
runner.check(!AntigravityLocalProbe.acceptsResponse(host: "127.0.0.1", port: 8443, statusCode: 200, expectedBytes: 0, actualBytes: 0, redirected: true), "redirects are rejected")

let refreshGate = AntigravityQuotaRefreshGate()
let refreshCounter = RefreshCounter()
let refreshDone = DispatchSemaphore(value: 0)
Task.detached {
    await withTaskGroup(of: Void.self) { group in
        for _ in 0..<2 {
            group.addTask {
                _ = try? await refreshGate.fetch {
                    refreshCounter.increment()
                    try await Task.sleep(nanoseconds: 50_000_000)
                    return AntigravityQuotaReading(
                        source: "local", receivedAt: now, sourceUpdatedAt: nil,
                        primaryFiveHour: AntigravityQuotaWindow(pool: .primary, period: .fiveHour, remainingPercent: 1, resetsAt: nil),
                        secondaryFiveHour: AntigravityQuotaWindow(pool: .secondary, period: .fiveHour, remainingPercent: 1, resetsAt: nil)
                    )
                }
            }
        }
        await group.waitForAll()
    }
    refreshDone.signal()
}
_ = refreshDone.wait(timeout: .now() + 2)
runner.checkEqual(refreshCounter.read(), 1, "same-process concurrent refreshes must share one in-flight operation")

do {
    _ = try AntigravityQuotaParser.parse(
        "{\"provider\":\"antigravity\",\"source\":\"local\",\"error\":\"private raw error\"}",
        receivedAt: now
    )
    runner.check(false, "provider error should be rejected")
} catch let error as AntigravityQuotaParseError {
    runner.checkEqual(error, .providerError, "provider error should map to a privacy-safe parse error")
}

do {
    _ = try AntigravityQuotaParser.parse(
        "{\"provider\":\"antigravity\",\"source\":\"remote\",\"usage\":{\"primary\":{\"usedPercent\":1},\"secondary\":{\"usedPercent\":2}}}",
        receivedAt: now
    )
    runner.check(false, "non-local source should be rejected")
} catch let error as AntigravityQuotaParseError {
    runner.checkEqual(error, .sourceRejected, "only native local results should be accepted")
}

let localSummary = """
{"response":{"groups":[{"displayName":"Gemini","buckets":[
{"bucketId":"gemini-5h","remainingFraction":0.88,"resetTime":1800001200},
{"bucketId":"gemini-weekly","remainingFraction":0.63,"resetTime":1800604800}]},
{"displayName":"Claude + GPT","buckets":[
{"bucketId":"claude-gpt-5h","remainingFraction":0.58,"resetTime":1800002400},
{"bucketId":"claude-gpt-weekly","disabled":true,"resetTime":1800700000}]}]}}
"""
do {
    let reading = try AntigravityQuotaParser.parseLocalSummary(Data(localSummary.utf8), receivedAt: now)
    runner.checkEqual(reading.primaryFiveHour.remainingPercent, Optional(88), "local summary should decode Gemini 5h")
    runner.checkEqual(reading.primarySevenDay?.remainingPercent, Optional(63), "local summary should decode Gemini 7d")
    runner.checkEqual(reading.secondaryFiveHour.remainingPercent, Optional(58), "local summary should decode Claude/GPT 5h")
    runner.checkEqual(reading.secondarySevenDay?.remainingPercent, Optional<Int>.none, "disabled bucket must remain unknown")
} catch { runner.check(false, "local summary parsing threw \(error)") }

let displayNameOnlySummary = """
{"response":{"groups":[{"displayName":"Gemini","buckets":[
{"bucketId":"opaque-a","displayName":"5 hour","remainingFraction":0.77},
{"bucketId":"opaque-b","displayName":"Weekly","remainingFraction":0.66}]},
{"displayName":"Claude + GPT","buckets":[
{"bucketId":"opaque-c","displayName":"Session","remainingFraction":0.55},
{"bucketId":"opaque-d","displayName":"7d","remainingFraction":0.44}]}]}}
"""
do {
    let reading = try AntigravityQuotaParser.parseLocalSummary(Data(displayNameOnlySummary.utf8), receivedAt: now)
    runner.checkEqual(reading.primaryFiveHour.remainingPercent, Optional(77), "group and display name classify opaque Gemini bucket")
    runner.checkEqual(reading.primarySevenDay?.remainingPercent, Optional(66), "display-name weekly cadence classifies opaque bucket")
    runner.checkEqual(reading.secondaryFiveHour.remainingPercent, Optional(55), "group and session display classify opaque Claude/GPT bucket")
    runner.checkEqual(reading.secondarySevenDay?.remainingPercent, Optional(44), "display-name 7d cadence classifies opaque bucket")
} catch { runner.check(false, "display-name-only summary parsing threw \(error)") }

let legacyUserStatus = """
{"userStatus":{"cascadeModelConfigData":{"clientModelConfigs":[
{"label":"Gemini 2.5 Pro","modelOrAlias":{"model":"gemini-2.5-pro"},"quotaInfo":{"remainingFraction":0.72,"resetTime":"1800001200"}},
{"label":"Gemini 2.5 Flash","modelOrAlias":{"model":"gemini-2.5-flash"},"quotaInfo":{"remainingFraction":0.61,"resetTime":"1800001300"}},
{"label":"Claude Sonnet","modelOrAlias":{"model":"claude-sonnet"},"quotaInfo":{"remainingFraction":0.48,"resetTime":"1800002400"}},
{"label":"GPT-5","modelOrAlias":{"model":"gpt-5"},"quotaInfo":{"remainingFraction":0.53,"resetTime":"1800002500"}}]}}}
"""
do {
    let reading = try AntigravityQuotaParser.parseLocalResponse(
        .init(path: AntigravityLocalProbe.userStatusPath, data: Data(legacyUserStatus.utf8)), receivedAt: now)
    runner.checkEqual(reading.primaryFiveHour.remainingPercent, Optional(61), "legacy user status chooses conservative Gemini 5h")
    runner.checkEqual(reading.secondaryFiveHour.remainingPercent, Optional(48), "legacy user status chooses conservative Claude/GPT 5h")
    runner.checkEqual(reading.primarySevenDay, nil, "legacy user status never synthesizes Gemini 7d")
    runner.checkEqual(reading.secondarySevenDay, nil, "legacy user status never synthesizes Claude/GPT 7d")
} catch { runner.check(false, "legacy user status parsing threw \(error)") }

do {
    let reading = try AntigravityQuotaParser.parseLocalResponse(
        .init(path: AntigravityLocalProbe.commandModelConfigsPath, data: Data("{\"clientModelConfigs\":[{\"label\":\"Gemini\",\"modelOrAlias\":{\"model\":\"gemini-pro\"},\"quotaInfo\":{\"remaining\":{\"case\":\"remainingFraction\",\"value\":0.8}}},{\"label\":\"GPT\",\"modelOrAlias\":{\"model\":\"gpt-5\"},\"quotaInfo\":{\"remainingFraction\":0.4}}]}".utf8)), receivedAt: now)
    runner.checkEqual(reading.primaryFiveHour.remainingPercent, Optional(80), "command configs parse Gemini legacy 5h")
    runner.checkEqual(reading.secondaryFiveHour.remainingPercent, Optional(40), "command configs parse GPT legacy 5h")
} catch { runner.check(false, "command model config parsing threw \(error)") }

do {
    let quota = try JSONSerialization.jsonObject(with: AntigravityLocalProbe.requestBody(for: AntigravityLocalProbe.quotaSummaryPath)!) as? [String: Any]
    runner.checkEqual(quota?["forceRefresh"] as? Bool, true, "quota summary request must force refresh")
    let legacy = try JSONSerialization.jsonObject(with: AntigravityLocalProbe.requestBody(for: AntigravityLocalProbe.userStatusPath)!) as? [String: Any]
    let metadata = legacy?["metadata"] as? [String: String]
    runner.checkEqual(metadata?["ideName"], "antigravity", "legacy request identifies Antigravity IDE")
    runner.checkEqual(metadata?["extensionName"], "antigravity", "legacy request identifies Antigravity extension")
    runner.checkEqual(metadata?["ideVersion"], "unknown", "legacy request uses non-identifying IDE version")
    runner.checkEqual(metadata?["locale"], "en", "legacy request pins locale")
} catch { runner.check(false, "request-body fixture threw \(error)") }

// The accessibility/help contract is fixed in the same order as this source
// list: Gemini 5h, Gemini 7d, Claude + GPT 5h, Claude + GPT 7d.
let orderedPeriods: [(AntigravityQuotaPool, AntigravityQuotaPeriod)] = [
    (.primary, .fiveHour), (.primary, .sevenDay), (.secondary, .fiveHour), (.secondary, .sevenDay)
]
runner.checkEqual(orderedPeriods.map { "\($0.0.label) \($0.1.label)" }, ["Gemini 5h", "Gemini 7d", "Claude + GPT 5h", "Claude + GPT 7d"], "four windows should keep a deterministic accessibility order")

guard runner.failures == 0 else {
    exit(1)
}
print("Antigravity quota tests passed")
