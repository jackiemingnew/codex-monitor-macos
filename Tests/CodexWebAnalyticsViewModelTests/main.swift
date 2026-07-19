import Combine
import Darwin
import Foundation
import WebKit

@MainActor
private final class FakeCodexAnalyticsProvider: CodexAnalyticsProviding {
    enum TestError: LocalizedError {
        case unavailable

        var errorDescription: String? { "模拟网页读取失败" }
    }

    var isReady: Bool
    var onReadinessChange: ((Bool) -> Void)?
    var fetchCount = 0
    var startCount = 0
    var reloadCount = 0
    var clearCount = 0
    var result: CodexWebAnalyticsRawSnapshot
    var fetchDelayNanoseconds: UInt64 = 0
    var shouldFail = false

    init(isReady: Bool, result: CodexWebAnalyticsRawSnapshot) {
        self.isReady = isReady
        self.result = result
    }

    func start() {
        startCount += 1
    }

    func reload() {
        reloadCount += 1
    }

    func setReady(_ value: Bool) {
        isReady = value
        onReadinessChange?(value)
    }

    func clearSession() async {
        clearCount += 1
        setReady(false)
    }

    func fetchSnapshot() async throws -> CodexWebAnalyticsRawSnapshot {
        fetchCount += 1
        if fetchDelayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: fetchDelayNanoseconds)
        }
        if shouldFail {
            throw TestError.unavailable
        }
        return result
    }
}

@MainActor
private final class TestRunner {
    private(set) var failures = 0

    func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard !condition() else { return }
        failures += 1
        FileHandle.standardError.write(Data("FAILED: \(message)\n".utf8))
    }

    func checkEqual<T: Equatable>(_ actual: @autoclosure () -> T, _ expected: T, _ message: String) {
        let actualValue = actual()
        guard actualValue == expected else {
            failures += 1
            FileHandle.standardError.write(
                Data("FAILED: \(message) (actual: \(actualValue), expected: \(expected))\n".utf8)
            )
            return
        }
    }
}

@main
struct CodexWebAnalyticsViewModelTests {
    @MainActor
    static func main() async {
        let runner = TestRunner()
        let productionProvider = CodexWebAnalyticsProvider()
        runner.check(!productionProvider.hasMaterialized, "provider construction must not materialize WebKit")
        let productionWebView = productionProvider.webView
        runner.check(productionProvider.hasMaterialized, "explicit webView access should materialize WebKit")
        runner.check(
            productionWebView.configuration.websiteDataStore === WKWebsiteDataStore.default(),
            "production web Analytics should use the app-owned persistent WebKit store"
        )
        runner.check(
            productionWebView.bounds.width >= 900
                && productionWebView.bounds.height >= 620,
            "web Analytics should have a chart layout before its visible window is first attached"
        )
        productionProvider.releaseIfIdle()
        runner.check(!productionProvider.hasMaterialized, "idle release should drop the WebKit object")
        let recreatedWebView = productionProvider.webView
        runner.check(productionProvider.hasMaterialized, "a released provider should recreate WebKit on demand")
        runner.check(
            recreatedWebView.configuration.websiteDataStore === productionWebView.configuration.websiteDataStore,
            "recreated WebKit should retain the injected WebsiteDataStore identity"
        )
        let isolatedStore = WKWebsiteDataStore.nonPersistent()
        let isolatedProvider = CodexWebAnalyticsProvider(websiteDataStore: isolatedStore)
        runner.check(
            isolatedProvider.webView.configuration.websiteDataStore === isolatedStore,
            "web Analytics tests should be able to inject an isolated WebKit store"
        )
        isolatedProvider.webView.loadHTMLString(
            #"""
            <!doctype html>
            <html>
              <head>
                <style>
                  body { margin: 0; font-family: sans-serif; }
                  .metric { display: flex; width: 320px; min-height: 40px; }
                  .metric > div { flex: 1; }
                </style>
              </head>
              <body id="fixture-ready">
                <button>7天</button>
                <div class="metric" style="display: none">
                  <div><div><span>轮次</span></div></div>
                  <div><div><span class="tabular-nums">999</span></div></div>
                </div>
                <div class="metric">
                  <div><div><span>轮次</span></div></div>
                  <div><div><span class="tabular-nums">123</span></div></div>
                </div>
                <div class="metric">
                  <div><div><span>Skills used</span></div></div>
                  <div><div><span class="tabular-nums">12</span></div></div>
                </div>
                <div class="metric">
                  <div><div><span>Plugins calls</span></div></div>
                  <div><div><span class="tabular-nums">0</span></div></div>
                </div>
              </body>
            </html>
            """#,
            baseURL: nil
        )
        let fixtureLoaded = await waitForWebFixture(isolatedProvider.webView)
        runner.check(fixtureLoaded, "nested KPI web fixture should finish loading")
        if fixtureLoaded {
            do {
                let value = try await isolatedProvider.webView.callAsyncJavaScript(
                    CodexWebAnalyticsProvider.extractionJavaScript,
                    arguments: [:],
                    in: nil,
                    contentWorld: .page
                )
                let json = value as? String
                runner.check(json != nil, "nested KPI extraction should return JSON")
                if let json {
                    let snapshot = try CodexWebAnalyticsParser.decode(json)
                    runner.checkEqual(snapshot.turns, 123, "visible nested Turns should win over a hidden duplicate")
                    runner.checkEqual(snapshot.skillsUsed, 12, "nested Skills used should be extracted")
                    runner.checkEqual(snapshot.pluginCalls, 0, "nested zero Plugin calls should be preserved")
                }
            } catch {
                runner.check(false, "nested KPI extraction should succeed: \(error)")
            }
        }

        let fixture = CodexWebAnalyticsRawSnapshot(
            rangeSelected: true,
            turns: 100,
            skillsUsed: 12,
            pluginCalls: 0,
            modelPoints: sevenDayPoints([
                CodexWebAnalyticsRawCount(name: "gpt-main", count: 70),
                CodexWebAnalyticsRawCount(name: "gpt-fast", count: 30)
            ]),
            surfacePoints: sevenDayPoints([
                CodexWebAnalyticsRawCount(name: "Desktop", count: 80),
                CodexWebAnalyticsRawCount(name: "CLI", count: 20)
            ]),
            skillPoints: sevenDayPoints([
                CodexWebAnalyticsRawCount(name: "Openai Docs", count: 12)
            ]),
            expectedDays: 7,
            rangeStartLabel: "Jul 11, 2026",
            rangeEndLabel: "Jul 17, 2026",
            timeZone: "Asia/Shanghai"
        )
        let provider = FakeCodexAnalyticsProvider(isReady: false, result: fixture)
        provider.fetchDelayNanoseconds = 40_000_000
        var clock = Date(timeIntervalSince1970: 20_000)
        let viewModel = CodexWebAnalyticsViewModel(provider: provider, now: { clock })

        viewModel.refresh(force: true)
        await Task.yield()
        runner.checkEqual(provider.fetchCount, 0, "missing web login must not start a fetch")
        runner.checkEqual(viewModel.state, .loginRequired, "missing web login should remain login-required")

        provider.setReady(true)
        viewModel.refresh(force: true)
        viewModel.refresh(force: true)
        let initialFetchFinished = await waitUntil { !viewModel.isRefreshing }
        runner.check(initialFetchFinished, "initial web Analytics fetch should finish")
        runner.checkEqual(provider.fetchCount, 1, "concurrent web refreshes should coalesce")
        runner.checkEqual(viewModel.state, .ready, "a complete web snapshot should finish ready")
        runner.checkEqual(viewModel.snapshot.turns, 100, "successful web fetch should publish Turns")

        viewModel.refreshWhenPresented()
        await Task.yield()
        runner.checkEqual(provider.fetchCount, 1, "fresh web Analytics should not refetch")

        clock = clock.addingTimeInterval(1_800)
        viewModel.refreshWhenPresented()
        let expiredFetchFinished = await waitUntil { !viewModel.isRefreshing }
        runner.check(expiredFetchFinished, "expired web Analytics fetch should finish")
        runner.checkEqual(provider.fetchCount, 2, "expired web Analytics should refresh when presented")

        provider.shouldFail = true
        viewModel.refresh(force: true)
        let failedFetchFinished = await waitUntil { !viewModel.isRefreshing }
        runner.check(failedFetchFinished, "failed web Analytics refresh should finish")
        runner.checkEqual(provider.fetchCount, 3, "manual force refresh should bypass the cache")
        runner.checkEqual(viewModel.snapshot.turns, 100, "failed refresh should retain the last successful snapshot")
        if case .stale = viewModel.state {
            // Expected.
        } else {
            runner.check(false, "failed refresh with cached data should be stale")
        }

        provider.setReady(false)
        runner.checkEqual(viewModel.snapshot.turns, 100, "losing the web session must not erase cached data")
        if case .stale = viewModel.state {
            // Expected.
        } else {
            runner.check(false, "losing the session with cached data should be stale")
        }

        viewModel.clearWebSession()
        let clearFinished = await waitUntil { !viewModel.isClearingWebSession }
        runner.check(clearFinished, "clearing the app-owned web session should finish")
        runner.checkEqual(provider.clearCount, 1, "clearing login should call the provider exactly once")
        runner.checkEqual(viewModel.snapshot, .empty, "clearing login should remove the in-memory Analytics snapshot")
        runner.checkEqual(viewModel.state, .loginRequired, "clearing login should return to login-required")

        if runner.failures == 0 {
            print("Codex web Analytics ViewModel tests passed")
        } else {
            exit(1)
        }
    }

    @MainActor
    private static func waitUntil(
        timeoutNanoseconds: UInt64 = 2_000_000_000,
        condition: @escaping @MainActor () -> Bool
    ) async -> Bool {
        let started = DispatchTime.now().uptimeNanoseconds
        while !condition() {
            if DispatchTime.now().uptimeNanoseconds - started >= timeoutNanoseconds {
                return false
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return true
    }

    @MainActor
    private static func waitForWebFixture(
        _ webView: WKWebView,
        timeoutNanoseconds: UInt64 = 2_000_000_000
    ) async -> Bool {
        let started = DispatchTime.now().uptimeNanoseconds
        while DispatchTime.now().uptimeNanoseconds - started < timeoutNanoseconds {
            if let result = try? await webView.evaluateJavaScript(
                "document.getElementById('fixture-ready') !== null"
            ), (result as? Bool) == true {
                return true
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return false
    }

    private static func sevenDayPoints(
        _ firstDayValues: [CodexWebAnalyticsRawCount]
    ) -> [CodexWebAnalyticsRawDailyPoint] {
        (0..<7).map { index in
            CodexWebAnalyticsRawDailyPoint(
                dateLabel: "Jul \(11 + index), 2026",
                values: firstDayValues.map { value in
                    CodexWebAnalyticsRawCount(name: value.name, count: index == 0 ? value.count : 0)
                }
            )
        }
    }
}
