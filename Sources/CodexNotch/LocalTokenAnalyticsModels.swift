import Foundation

enum AnalyticsDataMode: String, CaseIterable, Identifiable, Sendable {
    case official
    case localTokens

    var id: String { rawValue }

    var title: String {
        switch self {
        case .official:
            "官方轮次"
        case .localTokens:
            "本地 Token"
        }
    }

    var refreshSource: AnalyticsRefreshSource {
        switch self {
        case .official:
            .officialWebPage
        case .localTokens:
            .publishedLocalCostSnapshot
        }
    }
}

enum AnalyticsRefreshSource: String, Equatable, Sendable {
    case officialWebPage
    case publishedLocalCostSnapshot
}

enum LocalTokenAnalyticsPeriod: String, CaseIterable, Identifiable, Sendable {
    case today
    case sevenDays
    case thirtyDays

    var id: String { rawValue }

    var title: String {
        switch self {
        case .today:
            "今日"
        case .sevenDays:
            "7天"
        case .thirtyDays:
            "30天"
        }
    }

    var dayCount: Int {
        switch self {
        case .today:
            1
        case .sevenDays:
            7
        case .thirtyDays:
            30
        }
    }
}

struct CostUsageModelDayBucket: Equatable, Sendable {
    let dayKey: String
    let model: String
    let inputTokens: Int
    let cachedInputTokens: Int
    let outputTokens: Int
    let costNanos: Int64
    let isPriced: Bool
    let usesSparkProxy: Bool

    init(
        dayKey: String,
        model: String,
        inputTokens: Int,
        cachedInputTokens: Int,
        outputTokens: Int,
        costNanos: Int64,
        isPriced: Bool,
        usesSparkProxy: Bool
    ) {
        let input = max(0, inputTokens)
        self.dayKey = dayKey
        self.model = model
        self.inputTokens = input
        self.cachedInputTokens = min(input, max(0, cachedInputTokens))
        self.outputTokens = max(0, outputTokens)
        self.costNanos = max(0, costNanos)
        self.isPriced = isPriced
        self.usesSparkProxy = usesSparkProxy
    }

    var uncachedInputTokens: Int {
        max(0, inputTokens - cachedInputTokens)
    }

    var totalTokens: Int {
        Self.saturatingAdd(inputTokens, outputTokens)
    }

    var apiEquivalentUSD: Double? {
        guard isPriced else { return nil }
        return Double(costNanos) / 1_000_000_000
    }

    private static func saturatingAdd(_ lhs: Int, _ rhs: Int) -> Int {
        let (value, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? Int.max : value
    }
}

struct LocalTokenModelUsage: Identifiable, Equatable, Sendable {
    let model: String
    let inputTokens: Int
    let cachedInputTokens: Int
    let outputTokens: Int
    let costNanos: Int64
    let isPriced: Bool
    let usesSparkProxy: Bool

    var id: String { model }

    var uncachedInputTokens: Int {
        max(0, inputTokens - cachedInputTokens)
    }

    var totalTokens: Int {
        Self.saturatingAdd(inputTokens, outputTokens)
    }

    var apiEquivalentUSD: Double? {
        guard isPriced else { return nil }
        return Double(costNanos) / 1_000_000_000
    }

    func share(of periodTotal: Int) -> Double {
        guard periodTotal > 0 else { return 0 }
        return Double(totalTokens) / Double(periodTotal)
    }

    static func aggregate(model: String, buckets: [CostUsageModelDayBucket]) -> LocalTokenModelUsage {
        LocalTokenModelUsage(
            model: model,
            inputTokens: buckets.reduce(0) { saturatingAdd($0, $1.inputTokens) },
            cachedInputTokens: buckets.reduce(0) { saturatingAdd($0, $1.cachedInputTokens) },
            outputTokens: buckets.reduce(0) { saturatingAdd($0, $1.outputTokens) },
            costNanos: buckets.reduce(Int64(0)) { saturatingAdd($0, $1.costNanos) },
            isPriced: !buckets.isEmpty && buckets.allSatisfy(\.isPriced),
            usesSparkProxy: buckets.contains(where: \.usesSparkProxy)
        )
    }

    static func aggregate(model: String, usages: [LocalTokenModelUsage]) -> LocalTokenModelUsage {
        LocalTokenModelUsage(
            model: model,
            inputTokens: usages.reduce(0) { saturatingAdd($0, $1.inputTokens) },
            cachedInputTokens: usages.reduce(0) { saturatingAdd($0, $1.cachedInputTokens) },
            outputTokens: usages.reduce(0) { saturatingAdd($0, $1.outputTokens) },
            costNanos: usages.reduce(Int64(0)) { saturatingAdd($0, $1.costNanos) },
            isPriced: !usages.isEmpty && usages.allSatisfy(\.isPriced),
            usesSparkProxy: usages.contains(where: \.usesSparkProxy)
        )
    }

    private static func saturatingAdd(_ lhs: Int, _ rhs: Int) -> Int {
        let (value, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? Int.max : value
    }

    private static func saturatingAdd(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        let (value, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? Int64.max : value
    }
}

struct LocalTokenDayUsage: Identifiable, Equatable, Sendable {
    let dayKey: String
    let models: [LocalTokenModelUsage]

    var id: String { dayKey }

    var totalTokens: Int {
        models.reduce(0) { partial, usage in
            let (value, overflow) = partial.addingReportingOverflow(usage.totalTokens)
            return overflow ? Int.max : value
        }
    }

    func usage(for members: [String], displayName: String) -> LocalTokenModelUsage {
        LocalTokenModelUsage.aggregate(
            model: displayName,
            usages: models.filter { members.contains($0.model) }
        )
    }
}

struct LocalTokenDisplaySeries: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let members: [String]
    let totalTokens: Int
    let isOther: Bool
}

struct LocalTokenAnalyticsReport: Equatable, Sendable {
    static let preferredModelOrder = [
        "gpt-5.6-sol",
        "gpt-5.6-terra",
        "gpt-5.6-luna",
        "codex-auto-review"
    ]

    let period: LocalTokenAnalyticsPeriod
    let days: [LocalTokenDayUsage]
    let models: [LocalTokenModelUsage]
    let tokenQuality: CostUsageQuality
    let pricingQuality: CostUsageQuality
    let lastUpdated: Date?

    var totalTokens: Int {
        models.reduce(0) { partial, usage in
            let (value, overflow) = partial.addingReportingOverflow(usage.totalTokens)
            return overflow ? Int.max : value
        }
    }

    var usesSparkProxy: Bool {
        models.contains(where: \.usesSparkProxy)
    }

    func axisDayKeys(maximumLabels: Int = 6) -> [String] {
        guard maximumLabels > 0, !days.isEmpty else { return [] }
        let keys = days.map(\.dayKey)
        guard keys.count > maximumLabels, maximumLabels > 1 else {
            return maximumLabels == 1 ? [keys[keys.count - 1]] : keys
        }
        let stride = Int(ceil(Double(keys.count - 1) / Double(maximumLabels - 1)))
        var indices = Array(Swift.stride(from: 0, to: keys.count - 1, by: stride))
        indices.append(keys.count - 1)
        return indices.prefix(maximumLabels).map { keys[$0] }
    }

    static func make(
        summary: CostUsageSummary,
        period: LocalTokenAnalyticsPeriod,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> LocalTokenAnalyticsReport {
        let dayKeys = dayKeys(for: period, now: now, calendar: calendar)
        let includedDays = Set(dayKeys)
        let filteredBuckets = summary.modelBuckets.filter { includedDays.contains($0.dayKey) }
        let bucketsByDay = Dictionary(grouping: filteredBuckets, by: \.dayKey)
        let days = dayKeys.map { dayKey in
            let bucketsByModel = Dictionary(grouping: bucketsByDay[dayKey, default: []], by: \.model)
            let models = bucketsByModel.map { model, buckets in
                LocalTokenModelUsage.aggregate(model: model, buckets: buckets)
            }.filter { $0.totalTokens > 0 }
                .sorted(by: usageSort)
            return LocalTokenDayUsage(dayKey: dayKey, models: models)
        }
        let allBucketsByModel = Dictionary(grouping: filteredBuckets, by: \.model)
        let models = allBucketsByModel.map { model, buckets in
            LocalTokenModelUsage.aggregate(model: model, buckets: buckets)
        }.filter { $0.totalTokens > 0 }
            .sorted(by: usageSort)

        return LocalTokenAnalyticsReport(
            period: period,
            days: days,
            models: models,
            tokenQuality: summary.tokenQuality,
            pricingQuality: summary.quality,
            lastUpdated: summary.lastUpdated
        )
    }

    func displaySeries(limit: Int = 6) -> [LocalTokenDisplaySeries] {
        guard limit > 0, !models.isEmpty else { return [] }
        let usageByModel = Dictionary(uniqueKeysWithValues: models.map { ($0.model, $0) })
        let preferred = Self.preferredModelOrder.compactMap { usageByModel[$0] }
        let remaining = models.filter { !Self.preferredModelOrder.contains($0.model) }
        let ordered = preferred + remaining

        if ordered.count <= limit {
            return ordered.map(Self.series(for:))
        }

        let explicitLimit = max(0, limit - 1)
        let selected = Array(ordered.prefix(explicitLimit))
        let selectedNames = Set(selected.map(\.model))
        let other = models.filter { !selectedNames.contains($0.model) }
        var series = selected.map(Self.series(for:))
        if !other.isEmpty {
            series.append(
                LocalTokenDisplaySeries(
                    id: "__other__",
                    name: "其他",
                    members: other.map(\.model),
                    totalTokens: other.reduce(0) { partial, usage in
                        let (value, overflow) = partial.addingReportingOverflow(usage.totalTokens)
                        return overflow ? Int.max : value
                    },
                    isOther: true
                )
            )
        }
        return series
    }

    private static func series(for usage: LocalTokenModelUsage) -> LocalTokenDisplaySeries {
        LocalTokenDisplaySeries(
            id: usage.model,
            name: usage.model,
            members: [usage.model],
            totalTokens: usage.totalTokens,
            isOther: false
        )
    }

    private static func usageSort(_ lhs: LocalTokenModelUsage, _ rhs: LocalTokenModelUsage) -> Bool {
        if lhs.totalTokens == rhs.totalTokens {
            return lhs.model.localizedStandardCompare(rhs.model) == .orderedAscending
        }
        return lhs.totalTokens > rhs.totalTokens
    }

    private static func dayKeys(
        for period: LocalTokenAnalyticsPeriod,
        now: Date,
        calendar: Calendar
    ) -> [String] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        let start = calendar.startOfDay(for: now)

        return (0..<period.dayCount).reversed().map { daysBefore in
            let date = calendar.date(byAdding: .day, value: -daysBefore, to: start)
                ?? start.addingTimeInterval(-TimeInterval(daysBefore) * 86_400)
            return formatter.string(from: date)
        }
    }
}
