import Foundation

/// The two fixed pools exposed by the Antigravity adapter.
enum AntigravityQuotaPool: String, CaseIterable, Identifiable, Codable, Sendable {
    case primary
    case secondary

    var id: String { rawValue }

    var label: String {
        switch self {
        case .primary:
            "Gemini"
        case .secondary:
            "Claude + GPT"
        }
    }
}

/// A quota period is part of the normalized contract. Legacy two-slot cache
/// entries are migrated to five-hour windows by the provider-specific fallback
/// contract; no weekly value is inferred.
enum AntigravityQuotaPeriod: String, CaseIterable, Identifiable, Codable, Sendable {
    case fiveHour
    case sevenDay

    var id: String { rawValue }

    var label: String {
        switch self {
        case .fiveHour:
            "5h"
        case .sevenDay:
            "7d"
        }
    }

    var windowMinutes: Int {
        switch self {
        case .fiveHour:
            300
        case .sevenDay:
            10_080
        }
    }
}

/// A normalized pool/period window. Labels are computed display values rather
/// than persisted source metadata (raw ids/titles/descriptions stay out of
/// the cache).
struct AntigravityQuotaWindow: Codable, Equatable, Sendable, Identifiable {
    let pool: AntigravityQuotaPool
    let period: AntigravityQuotaPeriod
    let remainingPercent: Int?
    let resetsAt: Int?

    var id: String { "\(pool.rawValue)-\(period.rawValue)" }
    var label: String { pool.label }
    var periodLabel: String { period.label }

    init(
        pool: AntigravityQuotaPool,
        period: AntigravityQuotaPeriod,
        remainingPercent: Int?,
        resetsAt: Int?
    ) {
        self.pool = pool
        self.period = period
        if let remainingPercent {
            self.remainingPercent = Self.clamp(remainingPercent)
        } else {
            self.remainingPercent = nil
        }
        self.resetsAt = resetsAt
    }

    /// Legacy callers represented the primary/secondary slots as five-hour
    /// windows. Keep that initializer for source and cache compatibility.
    init(pool: AntigravityQuotaPool, remainingPercent: Int?, resetsAt: Int?) {
        self.init(pool: pool, period: .fiveHour, remainingPercent: remainingPercent, resetsAt: resetsAt)
    }

    init(pool: AntigravityQuotaPool, remainingPercent: Int, resetsAt: Int?) {
        self.init(pool: pool, period: .fiveHour, remainingPercent: remainingPercent, resetsAt: resetsAt)
    }

    private enum CodingKeys: String, CodingKey {
        case pool
        case period
        case remainingPercent
        case resetsAt
        // Accepted only when reading an older cache. It is never encoded.
        case label
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let pool = try container.decode(AntigravityQuotaPool.self, forKey: .pool)
        let period = try Self.decodePeriod(from: container)
        let remaining = try container.decodeIfPresent(Int.self, forKey: .remainingPercent)
        let resetsAt = try container.decodeIfPresent(Int.self, forKey: .resetsAt)
        self.init(pool: pool, period: period, remainingPercent: remaining, resetsAt: resetsAt)
    }

    private static func decodePeriod(
        from container: KeyedDecodingContainer<CodingKeys>
    ) throws -> AntigravityQuotaPeriod {
        guard let raw = try container.decodeIfPresent(String.self, forKey: .period) else {
            // Old primary/secondary cache entries had no period and are
            // explicitly defined as five-hour representatives.
            return .fiveHour
        }
        switch raw.lowercased().replacingOccurrences(of: "_", with: "-") {
        case "fivehour", "5h", "5-hour", "5 hour", "session":
            return .fiveHour
        case "sevenday", "7d", "weekly", "7-day", "7 day":
            return .sevenDay
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .period,
                in: container,
                debugDescription: "invalid AGY normalized period"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(pool, forKey: .pool)
        try container.encode(period, forKey: .period)
        try container.encodeIfPresent(remainingPercent, forKey: .remainingPercent)
        try container.encodeIfPresent(resetsAt, forKey: .resetsAt)
    }

    static func clamp(_ value: Int) -> Int {
        min(100, max(0, value))
    }
}

struct AntigravityQuotaReading: Equatable, Sendable {
    let source: String
    let receivedAt: Date
    let sourceUpdatedAt: Date?
    let primaryFiveHour: AntigravityQuotaWindow
    let primarySevenDay: AntigravityQuotaWindow?
    let secondaryFiveHour: AntigravityQuotaWindow
    let secondarySevenDay: AntigravityQuotaWindow?

    // Compatibility aliases for the old two-slot adapter and for callers that
    // use "weekly" terminology for the seven-day period.
    var primary: AntigravityQuotaWindow { primaryFiveHour }
    var secondary: AntigravityQuotaWindow { secondaryFiveHour }
    var primaryWeekly: AntigravityQuotaWindow? { primarySevenDay }
    var secondaryWeekly: AntigravityQuotaWindow? { secondarySevenDay }
    var primary5h: AntigravityQuotaWindow { primaryFiveHour }
    var primary7d: AntigravityQuotaWindow? { primarySevenDay }
    var secondary5h: AntigravityQuotaWindow { secondaryFiveHour }
    var secondary7d: AntigravityQuotaWindow? { secondarySevenDay }

    init(
        source: String = "local",
        receivedAt: Date,
        sourceUpdatedAt: Date?,
        primaryFiveHour: AntigravityQuotaWindow,
        primarySevenDay: AntigravityQuotaWindow? = nil,
        secondaryFiveHour: AntigravityQuotaWindow,
        secondarySevenDay: AntigravityQuotaWindow? = nil
    ) {
        self.source = source
        self.receivedAt = receivedAt
        self.sourceUpdatedAt = sourceUpdatedAt
        self.primaryFiveHour = primaryFiveHour
        self.primarySevenDay = primarySevenDay
        self.secondaryFiveHour = secondaryFiveHour
        self.secondarySevenDay = secondarySevenDay
    }

    init(
        source: String = "local",
        receivedAt: Date,
        sourceUpdatedAt: Date?,
        primaryFiveHour: AntigravityQuotaWindow,
        primaryWeekly: AntigravityQuotaWindow?,
        secondaryFiveHour: AntigravityQuotaWindow,
        secondaryWeekly: AntigravityQuotaWindow?
    ) {
        self.init(
            source: source,
            receivedAt: receivedAt,
            sourceUpdatedAt: sourceUpdatedAt,
            primaryFiveHour: primaryFiveHour,
            primarySevenDay: primaryWeekly,
            secondaryFiveHour: secondaryFiveHour,
            secondarySevenDay: secondaryWeekly
        )
    }

    /// Legacy initializer: representative primary/secondary slots are 5h.
    init(
        source: String = "local",
        receivedAt: Date,
        sourceUpdatedAt: Date?,
        primaryRemainingPercent: Int?,
        primaryResetsAt: Int?,
        secondaryRemainingPercent: Int?,
        secondaryResetsAt: Int?
    ) {
        self.init(
            source: source,
            receivedAt: receivedAt,
            sourceUpdatedAt: sourceUpdatedAt,
            primaryFiveHour: AntigravityQuotaWindow(
                pool: .primary,
                period: .fiveHour,
                remainingPercent: primaryRemainingPercent,
                resetsAt: primaryResetsAt
            ),
            secondaryFiveHour: AntigravityQuotaWindow(
                pool: .secondary,
                period: .fiveHour,
                remainingPercent: secondaryRemainingPercent,
                resetsAt: secondaryResetsAt
            )
        )
    }

    init(
        source: String = "local",
        receivedAt: Date,
        sourceUpdatedAt: Date?,
        primary: AntigravityQuotaWindow,
        secondary: AntigravityQuotaWindow
    ) {
        self.init(
            source: source,
            receivedAt: receivedAt,
            sourceUpdatedAt: sourceUpdatedAt,
            primaryFiveHour: primary,
            secondaryFiveHour: secondary
        )
    }
}

/// The only persisted AGY representation. It contains normalized pool,
/// period, remaining, and reset values, plus the cache provenance timestamps;
/// it never stores source ids/titles/descriptions or account identity data.
struct AntigravityQuotaCacheEntry: Codable, Equatable, Sendable {
    let source: String
    let receivedAt: Date
    let sourceUpdatedAt: Date?
    let primaryFiveHour: AntigravityQuotaWindow
    let primarySevenDay: AntigravityQuotaWindow?
    let secondaryFiveHour: AntigravityQuotaWindow
    let secondarySevenDay: AntigravityQuotaWindow?

    var primary: AntigravityQuotaWindow { primaryFiveHour }
    var secondary: AntigravityQuotaWindow { secondaryFiveHour }
    var primaryWeekly: AntigravityQuotaWindow? { primarySevenDay }
    var secondaryWeekly: AntigravityQuotaWindow? { secondarySevenDay }
    var primary5h: AntigravityQuotaWindow { primaryFiveHour }
    var primary7d: AntigravityQuotaWindow? { primarySevenDay }
    var secondary5h: AntigravityQuotaWindow { secondaryFiveHour }
    var secondary7d: AntigravityQuotaWindow? { secondarySevenDay }

    init(reading: AntigravityQuotaReading) {
        self.source = reading.source
        self.receivedAt = reading.receivedAt
        self.sourceUpdatedAt = reading.sourceUpdatedAt
        self.primaryFiveHour = reading.primaryFiveHour
        self.primarySevenDay = reading.primarySevenDay
        self.secondaryFiveHour = reading.secondaryFiveHour
        self.secondarySevenDay = reading.secondarySevenDay
    }

    init(
        source: String,
        receivedAt: Date,
        sourceUpdatedAt: Date?,
        primaryFiveHour: AntigravityQuotaWindow,
        primarySevenDay: AntigravityQuotaWindow? = nil,
        secondaryFiveHour: AntigravityQuotaWindow,
        secondarySevenDay: AntigravityQuotaWindow? = nil
    ) {
        self.source = source
        self.receivedAt = receivedAt
        self.sourceUpdatedAt = sourceUpdatedAt
        self.primaryFiveHour = primaryFiveHour
        self.primarySevenDay = primarySevenDay
        self.secondaryFiveHour = secondaryFiveHour
        self.secondarySevenDay = secondarySevenDay
    }

    init(
        source: String,
        receivedAt: Date,
        sourceUpdatedAt: Date?,
        primaryFiveHour: AntigravityQuotaWindow,
        primaryWeekly: AntigravityQuotaWindow?,
        secondaryFiveHour: AntigravityQuotaWindow,
        secondaryWeekly: AntigravityQuotaWindow?
    ) {
        self.init(
            source: source,
            receivedAt: receivedAt,
            sourceUpdatedAt: sourceUpdatedAt,
            primaryFiveHour: primaryFiveHour,
            primarySevenDay: primaryWeekly,
            secondaryFiveHour: secondaryFiveHour,
            secondarySevenDay: secondaryWeekly
        )
    }

    /// Legacy initializer: representative primary/secondary slots are 5h.
    init(
        source: String,
        receivedAt: Date,
        sourceUpdatedAt: Date?,
        primary: AntigravityQuotaWindow,
        secondary: AntigravityQuotaWindow
    ) {
        self.init(
            source: source,
            receivedAt: receivedAt,
            sourceUpdatedAt: sourceUpdatedAt,
            primaryFiveHour: primary,
            secondaryFiveHour: secondary
        )
    }

    private enum CodingKeys: String, CodingKey {
        case source
        case receivedAt
        case sourceUpdatedAt
        case primaryFiveHour
        case primarySevenDay
        case secondaryFiveHour
        case secondarySevenDay
        case primaryWeekly
        case secondaryWeekly
        // Legacy cache keys.
        case primary
        case secondary
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Do not relabel helper-produced legacy cache as native evidence. A
        // non-local source is rejected by AntigravityQuotaCache and forces a
        // fresh app-owned loopback read.
        source = try container.decode(String.self, forKey: .source)
        receivedAt = try container.decode(Date.self, forKey: .receivedAt)
        sourceUpdatedAt = try container.decodeIfPresent(Date.self, forKey: .sourceUpdatedAt)
        primaryFiveHour = try container.decodeIfPresent(AntigravityQuotaWindow.self, forKey: .primaryFiveHour)
            ?? container.decode(AntigravityQuotaWindow.self, forKey: .primary)
        secondaryFiveHour = try container.decodeIfPresent(AntigravityQuotaWindow.self, forKey: .secondaryFiveHour)
            ?? container.decode(AntigravityQuotaWindow.self, forKey: .secondary)
        primarySevenDay = try container.decodeIfPresent(AntigravityQuotaWindow.self, forKey: .primarySevenDay)
            ?? container.decodeIfPresent(AntigravityQuotaWindow.self, forKey: .primaryWeekly)
        secondarySevenDay = try container.decodeIfPresent(AntigravityQuotaWindow.self, forKey: .secondarySevenDay)
            ?? container.decodeIfPresent(AntigravityQuotaWindow.self, forKey: .secondaryWeekly)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(source, forKey: .source)
        try container.encode(receivedAt, forKey: .receivedAt)
        try container.encodeIfPresent(sourceUpdatedAt, forKey: .sourceUpdatedAt)
        try container.encode(primaryFiveHour, forKey: .primaryFiveHour)
        try container.encodeIfPresent(primarySevenDay, forKey: .primarySevenDay)
        try container.encode(secondaryFiveHour, forKey: .secondaryFiveHour)
        try container.encodeIfPresent(secondarySevenDay, forKey: .secondarySevenDay)
    }
}

enum AntigravityQuotaFreshness: Equatable, Sendable {
    case fresh
    case stale
    case expired
    case unavailable
}

enum AntigravityQuotaAvailability: Equatable, Sendable {
    case hidden
    case loading
    case fresh
    case stale
    case unavailable
}

struct AntigravityQuotaSnapshot: Equatable, Sendable {
    let availability: AntigravityQuotaAvailability
    let source: String?
    let receivedAt: Date?
    let sourceUpdatedAt: Date?
    let primaryFiveHour: AntigravityQuotaWindow?
    let primarySevenDay: AntigravityQuotaWindow?
    let secondaryFiveHour: AntigravityQuotaWindow?
    let secondarySevenDay: AntigravityQuotaWindow?
    let message: String?

    var primary: AntigravityQuotaWindow? { primaryFiveHour }
    var secondary: AntigravityQuotaWindow? { secondaryFiveHour }
    var primaryWeekly: AntigravityQuotaWindow? { primarySevenDay }
    var secondaryWeekly: AntigravityQuotaWindow? { secondarySevenDay }
    var primary5h: AntigravityQuotaWindow? { primaryFiveHour }
    var primary7d: AntigravityQuotaWindow? { primarySevenDay }
    var secondary5h: AntigravityQuotaWindow? { secondaryFiveHour }
    var secondary7d: AntigravityQuotaWindow? { secondarySevenDay }

    var shouldDisplay: Bool {
        availability != .hidden
    }

    var freshness: AntigravityQuotaFreshness {
        switch availability {
        case .fresh:
            .fresh
        case .stale:
            .stale
        case .hidden, .loading, .unavailable:
            .unavailable
        }
    }

    var freshnessLabel: String {
        switch availability {
        case .hidden:
            ""
        case .loading:
            "读取中"
        case .fresh:
            "已更新"
        case .stale:
            "缓存"
        case .unavailable:
            "不可用"
        }
    }

    var entry: AntigravityQuotaCacheEntry? {
        guard let source,
              let receivedAt,
              let primaryFiveHour,
              let secondaryFiveHour else {
            return nil
        }
        return AntigravityQuotaCacheEntry(
            source: source,
            receivedAt: receivedAt,
            sourceUpdatedAt: sourceUpdatedAt,
            primaryFiveHour: primaryFiveHour,
            primarySevenDay: primarySevenDay,
            secondaryFiveHour: secondaryFiveHour,
            secondarySevenDay: secondarySevenDay
        )
    }

    static let hidden = AntigravityQuotaSnapshot(
        availability: .hidden,
        source: nil,
        receivedAt: nil,
        sourceUpdatedAt: nil,
        primaryFiveHour: nil,
        primarySevenDay: nil,
        secondaryFiveHour: nil,
        secondarySevenDay: nil,
        message: nil
    )

    static func loading(from entry: AntigravityQuotaCacheEntry? = nil) -> AntigravityQuotaSnapshot {
        snapshot(availability: .loading, entry: entry, message: entry == nil ? "正在读取" : nil)
    }

    static func fresh(_ entry: AntigravityQuotaCacheEntry) -> AntigravityQuotaSnapshot {
        snapshot(availability: .fresh, entry: entry, message: nil)
    }

    static func stale(_ entry: AntigravityQuotaCacheEntry) -> AntigravityQuotaSnapshot {
        snapshot(availability: .stale, entry: entry, message: "AGY 数据较旧，等待本地会话更新")
    }

    static func unavailable(message: String) -> AntigravityQuotaSnapshot {
        AntigravityQuotaSnapshot(
            availability: .unavailable,
            source: nil,
            receivedAt: nil,
            sourceUpdatedAt: nil,
            primaryFiveHour: nil,
            primarySevenDay: nil,
            secondaryFiveHour: nil,
            secondarySevenDay: nil,
            message: message
        )
    }

    private static func snapshot(
        availability: AntigravityQuotaAvailability,
        entry: AntigravityQuotaCacheEntry?,
        message: String?
    ) -> AntigravityQuotaSnapshot {
        AntigravityQuotaSnapshot(
            availability: availability,
            source: entry?.source,
            receivedAt: entry?.receivedAt,
            sourceUpdatedAt: entry?.sourceUpdatedAt,
            primaryFiveHour: entry?.primaryFiveHour,
            primarySevenDay: entry?.primarySevenDay,
            secondaryFiveHour: entry?.secondaryFiveHour,
            secondarySevenDay: entry?.secondarySevenDay,
            message: message
        )
    }
}
