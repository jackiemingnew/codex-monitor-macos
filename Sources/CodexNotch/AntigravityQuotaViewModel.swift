import Combine
import Foundation

@MainActor
final class AntigravityQuotaViewModel: ObservableObject {
    @Published private(set) var snapshot: AntigravityQuotaSnapshot
    @Published private(set) var isRefreshing = false

    private let client: any AntigravityQuotaFetching
    private let cache: AntigravityQuotaCache
    private let antigravityLocator: AntigravityExecutableLocator
    private var cachedEntry: AntigravityQuotaCacheEntry?
    private var requestInFlight = false

    init(
        client: any AntigravityQuotaFetching = AntigravityQuotaClient(),
        cache: AntigravityQuotaCache = AntigravityQuotaCache(),
        antigravityLocator: AntigravityExecutableLocator = AntigravityExecutableLocator(),
        now: Date = Date()
    ) {
        self.client = client
        self.cache = cache
        self.antigravityLocator = antigravityLocator
        self.snapshot = .hidden
        loadCachedSnapshot(now: now)
        refreshWhenPresented(now: now)
    }

    func refreshNow(now: Date = Date()) {
        startRefresh(now: now, force: true)
    }

    func refreshWhenPresented(now: Date = Date()) {
        guard AntigravityQuotaPolicy.requiresRefresh(receivedAt: cachedEntry?.receivedAt, now: now) else {
            applyCachedSnapshot(now: now)
            return
        }
        startRefresh(now: now, force: false)
    }

    private func loadCachedSnapshot(now: Date) {
        do {
            cachedEntry = try cache.load()
        } catch {
            cachedEntry = nil
        }
        applyCachedSnapshot(now: now)
    }

    private func startRefresh(now: Date, force: Bool) {
        if !force,
           !AntigravityQuotaPolicy.requiresRefresh(receivedAt: cachedEntry?.receivedAt, now: now) {
            applyCachedSnapshot(now: now)
            return
        }
        guard !requestInFlight else {
            return
        }

        requestInFlight = true
        isRefreshing = true
        if cachedEntry == nil || !AntigravityQuotaPolicy.isWithinStaleGrace(
            receivedAt: cachedEntry?.receivedAt,
            now: now
        ) {
            // Expired values must not briefly reappear while a new read is in flight.
            snapshot = .loading()
        }

        let client = self.client
        let cache = self.cache
        let antigravityLocator = self.antigravityLocator
        Task { @MainActor [weak self] in
            do {
                let reading = try await client.fetch(now: now)
                let entry = AntigravityQuotaCacheEntry(reading: reading)
                try? cache.save(entry)
                guard let self else { return }
                self.cachedEntry = entry
                self.requestInFlight = false
                self.isRefreshing = false
                self.snapshot = .fresh(entry)
            } catch let error as AntigravityQuotaClientError {
                guard let self else { return }
                self.requestInFlight = false
                self.isRefreshing = false
                self.applyFailure(error, now: now, agyAvailable: antigravityLocator.executableURL != nil)
            } catch {
                guard let self else { return }
                self.requestInFlight = false
                self.isRefreshing = false
                _ = error
                self.applyFailure(.invalidResponse, now: now, agyAvailable: antigravityLocator.executableURL != nil)
            }
        }
    }

    private func applyFailure(
        _ error: AntigravityQuotaClientError,
        now: Date,
        agyAvailable: Bool
    ) {
        if let cachedEntry,
           AntigravityQuotaPolicy.isWithinStaleGrace(receivedAt: cachedEntry.receivedAt, now: now) {
            snapshot = .stale(cachedEntry)
            return
        }

        if !agyAvailable, cachedEntry == nil {
            snapshot = .hidden
            return
        }

        let message: String
        switch error {
        case .antigravityExecutableUnavailable:
            message = "不可用"
        case .localSessionUnavailable:
            message = "AGY 本地会话不可用"
        case .invalidResponse:
            message = "本地读取失败"
        }
        snapshot = .unavailable(message: message)
    }

    private func applyCachedSnapshot(now: Date) {
        guard let cachedEntry else {
            snapshot = antigravityLocator.executableURL == nil ? .hidden : .unavailable(message: "暂无配额")
            return
        }
        switch AntigravityQuotaPolicy.freshness(receivedAt: cachedEntry.receivedAt, now: now) {
        case .fresh:
            snapshot = .fresh(cachedEntry)
        case .stale:
            snapshot = .stale(cachedEntry)
        case .expired, .unavailable:
            snapshot = .unavailable(message: "缓存已过期")
        }
    }
}
