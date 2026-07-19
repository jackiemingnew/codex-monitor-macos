import Foundation
import WebKit

enum CodexWebAnalyticsProviderError: LocalizedError, Equatable {
    case loginRequired
    case pageNotReady
    case rangeSelectionFailed
    case blockedNavigation
    case extractionFailed

    var errorDescription: String? {
        switch self {
        case .loginRequired:
            "请先登录 Codex Analytics 网页"
        case .pageNotReady:
            "Codex Analytics 网页尚未加载完成"
        case .rangeSelectionFailed:
            "官网没有提供可识别的最近 7 天范围"
        case .blockedNavigation:
            "登录跳转到了未允许的网站"
        case .extractionFailed:
            "无法从 Codex Analytics 网页读取指标"
        }
    }
}

@MainActor
final class CodexWebAnalyticsProvider: NSObject, CodexAnalyticsProviding, WKNavigationDelegate {
    static let analyticsURL = URL(string: "https://chatgpt.com/codex/cloud/settings/analytics")!
    private static let extractionLayoutSize = CGSize(width: 1120, height: 760)

    private static let allowedHostSuffixes = [
        "chatgpt.com",
        "openai.com",
        "accounts.google.com",
        "appleid.apple.com",
        "login.microsoftonline.com",
        "login.live.com"
    ]

    /// Accessing the web view is an explicit opt-in to the WebKit-backed path.
    /// Construction of this provider (including app launch) stays WebKit-free.
    var webView: WKWebView { materialize() }
    private let websiteDataStore: WKWebsiteDataStore
    private var storage: WKWebView?
    private(set) var isReady = false
    var onReadinessChange: ((Bool) -> Void)?
    private var started = false
    private var blockedNavigation = false
    private var authenticatedRedirectAttempted = false
    private var readinessGeneration = 0
    private var readinessTask: Task<Void, Never>?
    private var idleReleaseTask: Task<Void, Never>?

    var hasMaterialized: Bool { storage != nil }

    init(websiteDataStore: WKWebsiteDataStore = .default()) {
        self.websiteDataStore = websiteDataStore
        super.init()
        // Keep only the injected store. WKWebView is materialized lazily by
        // materialize(), never as a side effect of provider initialization.
    }

    func start() {
        let webView = materialize()
        cancelIdleRelease()
        if started {
            // A retained WKWebView can finish its first load before SwiftUI attaches it
            // to the visible browser window. Re-arm the bounded readiness probe whenever
            // the window or detail page asks the provider to start again.
            scheduleReadinessChecks()
            return
        }
        started = true
        webView.load(URLRequest(url: Self.analyticsURL))
    }

    func reload() {
        let webView = materialize()
        cancelIdleRelease()
        blockedNavigation = false
        authenticatedRedirectAttempted = false
        if Self.isAnalyticsPage(webView.url) {
            webView.reload()
        } else {
            webView.load(URLRequest(url: Self.analyticsURL))
        }
    }

    func clearSession() async {
        let webView = materialize()
        cancelIdleRelease()
        readinessTask?.cancel()
        readinessTask = nil
        webView.stopLoading()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            websiteDataStore.removeData(
                ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
                modifiedSince: .distantPast
            ) {
                continuation.resume()
            }
        }
        blockedNavigation = false
        authenticatedRedirectAttempted = false
        setReady(false)
        started = true
        webView.load(URLRequest(url: Self.analyticsURL))
    }

    func fetchSnapshot() async throws -> CodexWebAnalyticsRawSnapshot {
        guard !blockedNavigation else {
            throw CodexWebAnalyticsProviderError.blockedNavigation
        }
        guard isReady else {
            throw CodexWebAnalyticsProviderError.loginRequired
        }

        guard let webView = storage else {
            throw CodexWebAnalyticsProviderError.pageNotReady
        }
        let value = try await webView.callAsyncJavaScript(
            Self.extractionJavaScript,
            arguments: [:],
            in: nil,
            contentWorld: .page
        )
        guard let json = value as? String else {
            throw CodexWebAnalyticsProviderError.extractionFailed
        }
        let snapshot = try CodexWebAnalyticsParser.decode(json)
        guard snapshot.rangeSelected else {
            throw CodexWebAnalyticsProviderError.rangeSelectionFailed
        }
        return snapshot
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        readinessGeneration &+= 1
        setReady(false)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        scheduleReadinessChecks()
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
        guard navigationAction.targetFrame?.isMainFrame != false,
              let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }
        if url.scheme == "about" {
            decisionHandler(.allow)
            return
        }
        guard url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(),
              Self.allowedHostSuffixes.contains(where: { host == $0 || host.hasSuffix(".\($0)") }) else {
            blockedNavigation = true
            setReady(false)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    private func refreshReadiness() async {
        guard let webView = storage else { return }
        guard Self.isAnalyticsPage(webView.url) else {
            setReady(false)
            await returnToAnalyticsAfterLoginIfNeeded()
            return
        }
        do {
            let result = try await webView.evaluateJavaScript(
                "document.body && (document.body.innerText.includes('Codex 分析') || document.body.innerText.includes('Codex analytics') || document.body.innerText.includes('Skills used'))"
            )
            let ready = (result as? Bool) == true
            if ready {
                authenticatedRedirectAttempted = false
            }
            setReady(ready)
        } catch {
            setReady(false)
        }
    }

    private func scheduleReadinessChecks() {
        readinessTask?.cancel()
        readinessGeneration &+= 1
        let generation = readinessGeneration
        readinessTask = Task { @MainActor [weak self] in
            defer {
                if self?.readinessGeneration == generation {
                    self?.readinessTask = nil
                }
            }
            for attempt in 0..<120 {
                guard let self, self.readinessGeneration == generation, !Task.isCancelled else { return }
                await self.refreshReadiness()
                guard self.readinessGeneration == generation, !self.isReady, !Task.isCancelled else { return }
                if attempt < 119 {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                }
            }
        }
    }

    private func returnToAnalyticsAfterLoginIfNeeded() async {
        guard !authenticatedRedirectAttempted,
              webView.url?.host?.lowercased() == Self.analyticsURL.host else {
            return
        }
        do {
            let result = try await webView.evaluateJavaScript(#"""
            Array.from(document.querySelectorAll("button")).some((button) => {
              const label = (button.getAttribute("aria-label") || "").toLowerCase();
              return label.includes("个人资料") || label.includes("profile");
            })
            """#)
            guard (result as? Bool) == true else { return }
            authenticatedRedirectAttempted = true
            webView.load(URLRequest(url: Self.analyticsURL))
        } catch {
            return
        }
    }

    private static func isAnalyticsPage(_ url: URL?) -> Bool {
        guard url?.scheme?.lowercased() == "https",
              url?.host?.lowercased() == analyticsURL.host else {
            return false
        }
        let actualPath = url?.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let expectedPath = analyticsURL.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return actualPath == expectedPath
    }

    private func setReady(_ ready: Bool) {
        guard isReady != ready else { return }
        isReady = ready
        onReadinessChange?(ready)
    }

    /// Schedule a safe, non-destructive release of the WebKit object. Website
    /// data is intentionally retained; clearSession() is the only data-removal
    /// path.
    func scheduleIdleRelease(after delay: TimeInterval = 30 * 60) {
        idleReleaseTask?.cancel()
        guard hasMaterialized else { return }
        let boundedDelay = max(0, delay)
        idleReleaseTask = Task { @MainActor [weak self] in
            let nanoseconds = UInt64(min(boundedDelay, TimeInterval(UInt64.max) / 1_000_000_000) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled else { return }
            self?.releaseIfIdle()
        }
    }

    func cancelIdleRelease() {
        idleReleaseTask?.cancel()
        idleReleaseTask = nil
    }

    /// Drop all strong references held by this provider without touching the
    /// injected WebsiteDataStore. The next explicit webView/start/reload access
    /// creates a fresh WKWebView backed by the same store.
    func releaseIfIdle() {
        idleReleaseTask?.cancel()
        idleReleaseTask = nil
        // An independently opened browser window may still retain and display
        // this view even while the HUD is hidden. Never tear down a mounted
        // WebKit view; windowWillClose removes the hosting hierarchy first.
        guard storage?.window == nil else { return }
        readinessTask?.cancel()
        readinessTask = nil
        readinessGeneration &+= 1
        storage?.stopLoading()
        storage?.navigationDelegate = nil
        storage = nil
        setReady(false)
        started = false
        blockedNavigation = false
        authenticatedRedirectAttempted = false
    }

    private func materialize() -> WKWebView {
        cancelIdleRelease()
        if let storage { return storage }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = websiteDataStore
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        let webView = WKWebView(
            frame: CGRect(origin: .zero, size: Self.extractionLayoutSize),
            configuration: configuration
        )
        webView.navigationDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        storage = webView
        return webView
    }

    static let extractionJavaScript = #"""
    const delay = (milliseconds) => new Promise((resolve) => setTimeout(resolve, milliseconds));
    const trimmedText = (element) => (element?.textContent || "").trim();
    const parseCount = (text) => {
      if (text == null) return null;
      const normalized = String(text).replace(/[,_\s]/g, "");
      const match = normalized.match(/-?\d+/);
      if (!match) return null;
      const value = Number(match[0]);
      return Number.isSafeInteger(value) && value >= 0 ? value : null;
    };
    const findLeaf = (labels) => {
      const leaves = Array.from(document.querySelectorAll("body *"))
        .filter((element) => element.children.length === 0);
      for (const label of labels) {
        const normalizedLabel = label.toLowerCase();
        const visible = leaves.find((element) => {
          if (trimmedText(element).toLowerCase() !== normalizedLabel) return false;
          const style = getComputedStyle(element);
          const bounds = element.getBoundingClientRect();
          return style.display !== "none"
            && style.visibility !== "hidden"
            && bounds.width > 0
            && bounds.height > 0;
        });
        if (visible) return visible;
      }
      const wanted = new Set(labels.map((value) => value.toLowerCase()));
      return leaves.find((element) => wanted.has(trimmedText(element).toLowerCase())) || null;
    };
    const readKPI = (labels) => {
      const label = findLeaf(labels);
      if (!label || !label.parentElement) return null;
      const numericValueInBranch = (branch, preferredOnly) => {
        const preferred = [
          ...(branch.matches?.(".tabular-nums") ? [branch] : []),
          ...Array.from(branch.querySelectorAll?.(".tabular-nums") || [])
        ].filter((element, index, elements) =>
          !elements.some((other, otherIndex) => otherIndex !== index && element.contains(other))
        );
        const candidates = preferred.length > 0 || preferredOnly
          ? preferred
          : [branch, ...Array.from(branch.querySelectorAll?.("*") || [])].filter((element) => {
              if (element.children.length !== 0) return false;
              return /^\s*[\d,_]+\s*$/.test(trimmedText(element));
            });
        if (candidates.length !== 1) return null;
        return parseCount(trimmedText(candidates[0]));
      };

      let container = label.parentElement;
      for (let depth = 0; container && depth < 5; depth += 1, container = container.parentElement) {
        const siblingBranches = Array.from(container.children).filter((branch) => !branch.contains(label));
        const preferredValues = siblingBranches
          .map((branch) => numericValueInBranch(branch, true))
          .filter((value) => value != null);
        if (preferredValues.length === 1) return preferredValues[0];

        const fallbackValues = siblingBranches
          .map((branch) => numericValueInBranch(branch, false))
          .filter((value) => value != null);
        if (fallbackValues.length === 1) return fallbackValues[0];
      }
      return null;
    };
    const findChartRoot = (labels) => {
      let node = findLeaf(labels);
      while (node && !node.querySelector?.("svg.recharts-surface")) node = node.parentElement;
      return node || null;
    };
    const findTurnsRoot = () => findChartRoot(["轮次", "Turns"]);
    const findSkillsRoot = () => findChartRoot(["Skills used"]);
    const clickButton = async (labels) => {
      const wanted = new Set(labels.map((value) => value.toLowerCase()));
      const button = Array.from(document.querySelectorAll("button")).find((element) =>
        wanted.has(trimmedText(element).toLowerCase())
      );
      if (!button) return false;
      button.click();
      await delay(1000);
      return true;
    };
    const visibleTooltip = (root) => Array.from(root.querySelectorAll(".recharts-tooltip-wrapper"))
      .find((element) => getComputedStyle(element).visibility === "visible");
    const tooltipValues = (tooltip) => {
      if (!tooltip) return null;
      const date = trimmedText(tooltip.querySelector(".font-medium"));
      if (!date) return null;
      const rows = Array.from(tooltip.querySelectorAll('[data-testid="chart-tooltip-row"]'));
      const values = [];
      for (const row of rows) {
        const name = trimmedText(row.querySelector('[data-testid="chart-tooltip-label"]'));
        const count = parseCount(trimmedText(row.lastElementChild));
        const normalizedName = name.toLowerCase();
        const isTotal = ["total", "总计", "合计"].includes(normalizedName);
        if (name && count != null && !isTotal) values.push({ name, count });
      }
      return { date, values };
    };
    const dispatchMove = (target, svg, clientX, clientY) => {
      const options = { bubbles: true, cancelable: true, clientX, clientY, view: window };
      for (const type of ["pointermove", "mousemove", "mouseover"]) {
        try { target.dispatchEvent(new MouseEvent(type, options)); } catch (_) {}
        if (target !== svg) {
          try { svg.dispatchEvent(new MouseEvent(type, options)); } catch (_) {}
        }
      }
    };
    const readChart = async (root) => {
      const svg = root?.querySelector("svg.recharts-surface");
      const clip = svg?.querySelector("clipPath rect");
      if (!root || !svg || !clip) return { points: [] };

      svg.scrollIntoView({ block: "center" });
      await delay(250);
      const bounds = svg.getBoundingClientRect();
      const viewBox = svg.viewBox?.baseVal;
      const svgWidth = viewBox?.width || Number(svg.getAttribute("width")) || bounds.width;
      const svgHeight = viewBox?.height || Number(svg.getAttribute("height")) || bounds.height;
      const clipX = Number(clip.getAttribute("x"));
      const clipY = Number(clip.getAttribute("y"));
      const clipWidth = Number(clip.getAttribute("width"));
      const clipHeight = Number(clip.getAttribute("height"));
      if (![bounds.width, bounds.height, svgWidth, svgHeight, clipX, clipY, clipWidth, clipHeight].every(Number.isFinite)) {
        return { points: [] };
      }

      const points = [];
      const seenDates = new Set();
      const expectedDays = 7;
      const sampleCount = expectedDays * 2;
      const edgeInset = Math.min(2, Math.max(0.5, clipWidth / 500));
      const usableWidth = Math.max(0, clipWidth - edgeInset * 2);
      for (let index = 0; index < sampleCount; index += 1) {
        const ratio = sampleCount === 1 ? 0 : index / (sampleCount - 1);
        const xInSVG = clipX + edgeInset + usableWidth * ratio;
        const yInSVG = clipY + Math.max(1, Math.min(clipHeight - 1, clipHeight * 0.5));
        const clientX = bounds.left + (xInSVG / svgWidth) * bounds.width;
        const clientY = bounds.top + (yInSVG / svgHeight) * bounds.height;
        const target = document.elementFromPoint(clientX, clientY) || svg;
        dispatchMove(target, svg, clientX, clientY);
        await delay(65);
        const point = tooltipValues(visibleTooltip(root));
        if (!point || seenDates.has(point.date)) continue;
        seenDates.add(point.date);
        points.push({ dateLabel: point.date, values: point.values });
        if (seenDates.size === expectedDays) break;
      }
      return { points };
    };
    const readTurnsChart = async (toggleLabels) => {
      const clicked = await clickButton(toggleLabels);
      if (!clicked) return { points: [] };
      return readChart(findTurnsRoot());
    };

    const rangeSelected = await clickButton([
      "7天", "7 天", "7日", "1周", "1 周", "7 days", "7 day", "1 week", "7D"
    ]);
    if (!rangeSelected) {
      return JSON.stringify({
        rangeSelected: false,
        turns: null,
        skillsUsed: null,
        pluginCalls: null,
        modelPoints: [],
        surfacePoints: [],
        skillPoints: [],
        expectedDays: 7,
        rangeStartLabel: null,
        rangeEndLabel: null,
        timeZone: Intl.DateTimeFormat().resolvedOptions().timeZone || null
      });
    }

    const turns = readKPI(["轮次", "Turns"]);
    const skillsUsed = readKPI(["Skills used"]);
    const pluginCalls = readKPI(["Plugins calls", "Plugin calls"]);
    const model = await readTurnsChart(["By model", "按模型"]);
    const surface = await readTurnsChart(["By surface", "按 Surface", "按界面"]);
    const skills = await readChart(findSkillsRoot());
    const rangePoints = [model.points, surface.points, skills.points]
      .sort((left, right) => right.length - left.length)[0] || [];
    const result = {
      rangeSelected,
      turns,
      skillsUsed,
      pluginCalls,
      modelPoints: model.points,
      surfacePoints: surface.points,
      skillPoints: skills.points,
      expectedDays: 7,
      rangeStartLabel: rangePoints[0]?.dateLabel || null,
      rangeEndLabel: rangePoints[rangePoints.length - 1]?.dateLabel || null,
      timeZone: Intl.DateTimeFormat().resolvedOptions().timeZone || null
    };
    return JSON.stringify(result);
    """#
}
