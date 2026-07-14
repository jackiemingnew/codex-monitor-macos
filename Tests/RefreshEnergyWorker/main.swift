import Darwin
import Foundation

private final class BenchmarkLaunchAtLoginManager: LaunchAtLoginManaging {
    var isEnabled = false

    func setEnabled(_ enabled: Bool) throws {
        isEnabled = enabled
    }
}

private struct ProcessResourceUsage {
    let cpuSeconds: Double
    let peakResidentBytes: UInt64
}

private func seconds(_ value: timeval) -> Double {
    Double(value.tv_sec) + Double(value.tv_usec) / 1_000_000
}

private func processResourceUsage() -> ProcessResourceUsage {
    var own = rusage()
    var children = rusage()
    _ = getrusage(RUSAGE_SELF, &own)
    _ = getrusage(RUSAGE_CHILDREN, &children)
    let cpuSeconds = seconds(own.ru_utime)
        + seconds(own.ru_stime)
        + seconds(children.ru_utime)
        + seconds(children.ru_stime)
    return ProcessResourceUsage(
        cpuSeconds: cpuSeconds,
        peakResidentBytes: UInt64(max(0, own.ru_maxrss))
    )
}

private func percentile95(_ samples: [Double]) -> Double {
    guard !samples.isEmpty else {
        return 0
    }
    let sorted = samples.sorted()
    let index = max(0, min(sorted.count - 1, Int(ceil(Double(sorted.count) * 0.95)) - 1))
    return sorted[index]
}

private func sleep(seconds: TimeInterval) async {
    guard seconds > 0 else {
        return
    }
    try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
}

@main
private struct RefreshEnergyWorker {
    @MainActor
    static func main() async {
        let arguments = CommandLine.arguments
        guard arguments.count == 6,
              let warmupSeconds = TimeInterval(arguments[3]),
              let measurementSeconds = TimeInterval(arguments[4]),
              warmupSeconds >= 0,
              measurementSeconds > 0 else {
            FileHandle.standardError.write(
                Data("usage: RefreshEnergyWorker fixed|adaptive FIXTURE_DIR WARMUP_SECONDS MEASUREMENT_SECONDS LABEL\n".utf8)
            )
            exit(64)
        }

        let mode = arguments[1]
        guard mode == "fixed" || mode == "adaptive" else {
            FileHandle.standardError.write(Data("mode must be fixed or adaptive\n".utf8))
            exit(64)
        }

        let fixtureDirectory = URL(fileURLWithPath: arguments[2], isDirectory: true)
        let label = arguments[5]
        let defaultsSuite = "com.alight.codexnotch.refresh-energy.\(label)"
        guard let defaults = UserDefaults(suiteName: defaultsSuite) else {
            FileHandle.standardError.write(Data("unable to create isolated defaults suite\n".utf8))
            exit(70)
        }
        defaults.removePersistentDomain(forName: defaultsSuite)
        defaults.set(30.0, forKey: "activeRefreshInterval")
        defaults.set(180.0, forKey: "idleRefreshInterval")
        defaults.set(300.0, forKey: "usageRefreshInterval")
        defaults.set(180.0, forKey: "watcherRefreshInterval")
        defaults.set(15.0, forKey: "fileChangeRefreshMinimumGap")
        defaults.set(mode == "adaptive", forKey: "adaptiveRefreshEnabled")
        defaults.set(RateLimitSourcePreference.localFilesOnly.rawValue, forKey: "rateLimitSource")
        defaults.set(false, forKey: "showContextMetrics")
        defaults.set(false, forKey: "skillInsightsEnabled")
        defaults.set(false, forKey: "codexRadarEnabled")
        defaults.set(TaskHistoryRange.threeDays.rawValue, forKey: "taskHistoryRange")

        let memoryKeychain = MemorySecretStore()
        let memoryDatabase = MemorySecretStore()
        let settings = CodexNotchSettings(
            defaults: defaults,
            secretStores: SecretStoreFactory(keychain: memoryKeychain, database: memoryDatabase),
            launchAtLoginManager: BenchmarkLaunchAtLoginManager(),
            environment: [:],
            codexRadarLegacyTokenFileURL: fixtureDirectory.appendingPathComponent("missing-radar-token")
        )
        let store = CodexUsageStore(
            codexDirectory: fixtureDirectory,
            stateDatabase: fixtureDirectory.appendingPathComponent("state_5.sqlite").path,
            logsDatabase: fixtureDirectory.appendingPathComponent("logs_2.sqlite").path,
            deltaDatabase: fixtureDirectory.appendingPathComponent("usage-deltas.sqlite").path,
            ripgrepCandidates: [],
            appServerCacheURL: fixtureDirectory.appendingPathComponent("app-server-cache.json")
        )
        let viewModel = UsageViewModel(store: store, settings: settings)
        viewModel.setDetailVisible(false)
        viewModel.setSourceVisible(false)

        await sleep(seconds: warmupSeconds)
        while viewModel.isRefreshing {
            await sleep(seconds: 0.1)
        }

        RefreshShadowMetrics.shared.resetForTesting()
        let cacheAtStart = store.sessionFileCacheStats()
        let resourcesAtStart = processResourceUsage()
        let startedAt = Date()
        var lastSampleAt = startedAt
        var lastResources = resourcesAtStart
        var cpuSamples: [Double] = []
        let deadline = startedAt.addingTimeInterval(measurementSeconds)

        while Date() < deadline {
            await sleep(seconds: min(2, max(0.01, deadline.timeIntervalSinceNow)))
            let sampledAt = Date()
            let resources = processResourceUsage()
            let elapsed = max(0.001, sampledAt.timeIntervalSince(lastSampleAt))
            let cpuDelta = max(0, resources.cpuSeconds - lastResources.cpuSeconds)
            cpuSamples.append(cpuDelta / elapsed * 100)
            lastSampleAt = sampledAt
            lastResources = resources
        }

        let settleDeadline = Date().addingTimeInterval(10)
        while viewModel.isRefreshing, Date() < settleDeadline {
            await sleep(seconds: 0.1)
        }
        await sleep(seconds: 0.25)

        let finishedAt = Date()
        let resourcesAtEnd = processResourceUsage()
        let elapsed = max(0.001, finishedAt.timeIntervalSince(startedAt))
        let cpuSeconds = max(0, resourcesAtEnd.cpuSeconds - resourcesAtStart.cpuSeconds)
        let cacheAtEnd = store.sessionFileCacheStats()
        let refreshMetrics = RefreshShadowMetrics.shared.snapshot()
        let result: [String: Any] = [
            "label": label,
            "mode": mode,
            "warmup_seconds": warmupSeconds,
            "measurement_seconds": elapsed,
            "average_cpu_percent": cpuSeconds / elapsed * 100,
            "p95_cpu_percent": percentile95(cpuSamples),
            "maximum_sample_cpu_percent": cpuSamples.max() ?? 0,
            "peak_resident_bytes": resourcesAtEnd.peakResidentBytes,
            "request_count": refreshMetrics.requestCount,
            "coalesced_request_count": refreshMetrics.coalescedRequestCount,
            "replaced_request_count": refreshMetrics.replacedRequestCount,
            "stale_completion_count": refreshMetrics.staleCompletionCount,
            "schedule_decision_count": refreshMetrics.decisionCount,
            "projected_fixed_refreshes_per_day": refreshMetrics.projectedFixedRefreshesPerDay,
            "projected_adaptive_refreshes_per_day": refreshMetrics.projectedAdaptiveRefreshesPerDay,
            "prefix_scan_delta": cacheAtEnd.prefixScans - cacheAtStart.prefixScans,
            "rate_limit_scan_delta": cacheAtEnd.rateLimitScans - cacheAtStart.rateLimitScans,
            "activity_scan_delta": cacheAtEnd.activityScans - cacheAtStart.activityScans,
            "fast_snapshot_hit_delta": cacheAtEnd.fastSnapshotHits - cacheAtStart.fastSnapshotHits,
            "session_cache_entry_count": cacheAtEnd.entryCount,
            "is_running": viewModel.snapshot.isRunning,
            "is_refreshing": viewModel.isRefreshing,
            "jsonl_context_scans": viewModel.snapshot.monitorStats.jsonlContextScans
        ]

        do {
            let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data("\n".utf8))
        } catch {
            FileHandle.standardError.write(Data("unable to encode result: \(error)\n".utf8))
            defaults.removePersistentDomain(forName: defaultsSuite)
            exit(70)
        }

        defaults.removePersistentDomain(forName: defaultsSuite)
    }
}
