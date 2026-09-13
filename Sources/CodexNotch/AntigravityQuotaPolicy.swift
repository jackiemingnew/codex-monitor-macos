import Foundation

enum AntigravityQuotaPolicy {
    static let freshAge: TimeInterval = 15 * 60
    static let staleGrace: TimeInterval = 30 * 60

    static func freshness(
        receivedAt: Date?,
        now: Date = Date()
    ) -> AntigravityQuotaFreshness {
        guard let receivedAt else {
            return .unavailable
        }
        let age = now.timeIntervalSince(receivedAt)
        guard age >= 0 else {
            return .fresh
        }
        if age <= freshAge {
            return .fresh
        }
        if age <= staleGrace {
            return .stale
        }
        return .expired
    }

    static func requiresRefresh(
        receivedAt: Date?,
        now: Date = Date()
    ) -> Bool {
        switch freshness(receivedAt: receivedAt, now: now) {
        case .fresh:
            false
        case .stale, .expired, .unavailable:
            true
        }
    }

    static func isWithinStaleGrace(
        receivedAt: Date?,
        now: Date = Date()
    ) -> Bool {
        switch freshness(receivedAt: receivedAt, now: now) {
        case .fresh, .stale:
            true
        case .expired, .unavailable:
            false
        }
    }
}
