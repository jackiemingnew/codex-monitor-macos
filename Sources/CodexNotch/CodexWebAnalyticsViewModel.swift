import Combine
import Foundation

enum CodexWebAnalyticsState: Equatable, Sendable {
    case loginRequired
    case loading
    case ready
    case partial(String)
    case stale(String)
    case unavailable(String)

    var label: String {
        switch self {
        case .loginRequired:
            "需登录"
        case .loading:
            "读取中"
        case .ready:
            "COMPLETE"
        case .partial:
            "PARTIAL"
        case .stale:
            "STALE"
        case .unavailable:
            "UNAVAILABLE"
        }
    }

    var message: String {
        switch self {
        case .loginRequired:
            "首次登录后由本应用 WebKit 复用会话"
        case .loading:
            "正在读取最近 7 天网页指标"
        case .ready:
            "官方个人 Pro Analytics 网页"
        case let .partial(message), let .stale(message), let .unavailable(message):
            message
        }
    }
}

@MainActor
final class CodexWebAnalyticsViewModel: ObservableObject {
    @Published private(set) var snapshot: CodexAnalyticsSnapshot = .empty
    @Published private(set) var state: CodexWebAnalyticsState = .loginRequired
    @Published private(set) var isRefreshing = false
    @Published private(set) var isWebSessionReady = false
    @Published private(set) var isClearingWebSession = false

    private let provider: CodexAnalyticsProviding
    private let cachePolicy: CodexAnalyticsCachePolicy
    private let now: () -> Date
    private var refreshTask: Task<Void, Never>?
    private var clearTask: Task<Void, Never>?
    private var lastSuccessAt: Date?

    init(
        provider: CodexAnalyticsProviding,
        cachePolicy: CodexAnalyticsCachePolicy = .standard,
        now: @escaping () -> Date = Date.init
    ) {
        self.provider = provider
        self.cachePolicy = cachePolicy
        self.now = now
        isWebSessionReady = provider.isReady
        provider.onReadinessChange = { [weak self] ready in
            guard let self else { return }
            self.isWebSessionReady = ready
            guard !self.isClearingWebSession else { return }
            if ready {
                self.refresh(force: true)
            } else if self.lastSuccessAt != nil {
                self.state = .stale("网页会话需要重新登录")
            } else {
                self.state = .loginRequired
            }
        }
    }

    var sessionStatusLabel: String {
        isWebSessionReady ? "已登录（App 会话）" : "未登录"
    }

    func startBrowserSession() {
        provider.start()
        if provider.isReady {
            refresh(force: false)
        }
    }

    func reloadWebPage() {
        provider.reload()
    }

    func setOfficialAnalyticsVisible(_ visible: Bool) {
        if visible {
            provider.cancelIdleRelease()
        } else {
            provider.scheduleIdleRelease(after: 30 * 60)
        }
    }

    func refreshWhenPresented() {
        guard clearTask == nil else { return }
        if cachePolicy.isFresh(lastSuccessAt: lastSuccessAt, now: now()) {
            applySnapshotState()
            return
        }
        guard provider.isReady else {
            if lastSuccessAt == nil {
                state = .loginRequired
            } else {
                state = .stale("缓存已超过 30 分钟，请重新打开网页")
            }
            return
        }
        refresh(force: true)
    }

    func refresh(force: Bool) {
        guard clearTask == nil else { return }
        if !force, cachePolicy.isFresh(lastSuccessAt: lastSuccessAt, now: now()) {
            applySnapshotState()
            return
        }
        guard provider.isReady else {
            if lastSuccessAt == nil {
                state = .loginRequired
            } else {
                state = .stale("网页会话需要重新登录")
            }
            return
        }
        guard refreshTask == nil else { return }

        isRefreshing = true
        state = .loading
        refreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.isRefreshing = false
                self.refreshTask = nil
            }
            do {
                let raw = try await self.provider.fetchSnapshot()
                guard !Task.isCancelled else { return }
                let capturedAt = self.now()
                let next = CodexWebAnalyticsSnapshotBuilder.build(raw: raw, capturedAt: capturedAt)
                guard next.quality != .unavailable else {
                    self.handleFailure("网页没有返回可用指标")
                    return
                }
                self.snapshot = next
                self.lastSuccessAt = capturedAt
                self.applySnapshotState()
            } catch {
                guard !Task.isCancelled else { return }
                self.handleFailure(Self.userMessage(for: error))
            }
        }
    }

    func clearWebSession() {
        guard clearTask == nil else { return }
        refreshTask?.cancel()
        refreshTask = nil
        isRefreshing = false
        isClearingWebSession = true
        state = .loading

        clearTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.isClearingWebSession = false
                self.clearTask = nil
            }
            await self.provider.clearSession()
            self.snapshot = .empty
            self.lastSuccessAt = nil
            self.isWebSessionReady = false
            self.state = .loginRequired
        }
    }

    private func applySnapshotState() {
        switch snapshot.quality {
        case .complete:
            state = .ready
        case .partial:
            state = .partial(snapshot.qualityIssues.joined(separator: "；"))
        case .unavailable:
            state = .unavailable("网页没有返回可用指标")
        }
    }

    private func handleFailure(_ message: String) {
        if lastSuccessAt != nil {
            state = .stale(message)
        } else if !provider.isReady {
            state = .loginRequired
        } else {
            state = .unavailable(message)
        }
    }

    private static func userMessage(for error: Error) -> String {
        if let localized = error as? LocalizedError,
           let message = localized.errorDescription,
           !message.isEmpty {
            return String(message.prefix(180))
        }
        return "读取 Analytics 网页失败"
    }
}
