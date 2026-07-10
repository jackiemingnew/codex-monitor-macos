import Foundation

enum CodexRadarDataSource: String, Codable, Equatable, Sendable {
    case authorizedAPI
    case publicSummary

    var displayLabel: String {
        switch self {
        case .authorizedAPI:
            "API"
        case .publicSummary:
            "Public"
        }
    }
}

enum CodexRadarPanelState: Equatable, Sendable {
    case disabled
    case loading
    case ready
    case stale
    case error
}

enum CodexRadarScoreBand: Equatable, Sendable {
    case healthy
    case baseline
    case warning
    case critical
    case unknown

    static func classify(_ score: Double?) -> CodexRadarScoreBand {
        guard let score else {
            return .unknown
        }
        if score >= 110 {
            return .healthy
        }
        if score >= 90 {
            return .baseline
        }
        if score >= 60 {
            return .warning
        }
        return .critical
    }
}

struct CodexRadarModelScore: Identifiable, Equatable, Sendable {
    let id: String
    let label: String
    let model: String?
    let reasoningEffort: String?
    let score: Double?
    let status: String?
    let passed: Int?
    let tasks: Int?
    let validTasks: Int?
    let invalidTasks: Int?
    let costUSD: Double?
    let wallTimeHuman: String?

    var scoreBand: CodexRadarScoreBand {
        CodexRadarScoreBand.classify(score)
    }

    var taskSummary: String {
        guard let passed, let denominator = validTasks ?? tasks else {
            return "--/--"
        }
        let result = "\(passed)/\(denominator)"
        guard let invalidTasks, invalidTasks > 0 else {
            return result
        }
        return "\(result) · \(invalidTasks) 无效"
    }
}

struct CodexRadarQuotaRow: Identifiable, Equatable, Sendable {
    var id: String { tier }

    let tier: String
    let fiveH: Double?
    let sevenD: Double?
    let basis: String?

    var displayBasis: String {
        guard let basis = basis?.trimmingCharacters(in: .whitespacesAndNewlines),
              !basis.isEmpty else {
            return "--"
        }
        let normalized = basis.lowercased()
        if normalized.contains("measured") {
            return "实测"
        }
        if normalized.contains("model") {
            return "推测"
        }
        return basis
    }
}

enum CodexRadarTrendDirection: Equatable, Sendable {
    case positive
    case negative
    case neutral
}

struct CodexRadarQuotaTrendPoint: Identifiable, Equatable, Sendable {
    var id: String { date }

    let date: String
    let fiveH20x: Double?
    let sevenD20x: Double?
}

struct CodexRadarQuotaTrendSummary: Equatable, Sendable {
    let startValue: Double
    let endValue: Double
    let delta: Double
    let percentChange: Double
    let direction: CodexRadarTrendDirection
}

struct CodexRadarSnapshot: Equatable, Sendable {
    static let defaultAttributionText = "数据来自 Codex 雷达 codexradar.com"
    static let siteURL = URL(string: "https://codexradar.com")!

    var panelState: CodexRadarPanelState
    var models: [CodexRadarModelScore]
    var quotaRows: [CodexRadarQuotaRow]
    var monitoredAt: Date?
    var quotaUpdatedAt: Date?
    var modelIQDate: String?
    var lastFetchAt: Date?
    var status: String?
    var recommendedAction: String?
    var windowMessage: String?
    var predictionSummary: String?
    var expectedWindow: String?
    var modelRunCostUSD: Double?
    var quotaCalibrationCostUSD: Double?
    var quotaDate: String?
    var quotaTrend: [CodexRadarQuotaTrendPoint]
    var costUSD: Double?
    var dataSource: CodexRadarDataSource
    var fallbackReason: CodexRadarFallbackReason?
    var attributionText: String
    var attributionRequired: Bool
    var siteURL: URL
    var message: String?

    static let disabled = CodexRadarSnapshot(
        panelState: .disabled,
        models: [],
        quotaRows: [],
        monitoredAt: nil,
        quotaUpdatedAt: nil,
        modelIQDate: nil,
        lastFetchAt: nil,
        status: nil,
        recommendedAction: nil,
        windowMessage: nil,
        predictionSummary: nil,
        expectedWindow: nil,
        modelRunCostUSD: nil,
        quotaCalibrationCostUSD: nil,
        quotaDate: nil,
        quotaTrend: [],
        costUSD: nil,
        dataSource: .authorizedAPI,
        fallbackReason: nil,
        attributionText: defaultAttributionText,
        attributionRequired: true,
        siteURL: siteURL,
        message: "Codex Radar 未启用"
    )

    static let loading = CodexRadarSnapshot(
        panelState: .loading,
        models: [],
        quotaRows: [],
        monitoredAt: nil,
        quotaUpdatedAt: nil,
        modelIQDate: nil,
        lastFetchAt: nil,
        status: nil,
        recommendedAction: nil,
        windowMessage: nil,
        predictionSummary: nil,
        expectedWindow: nil,
        modelRunCostUSD: nil,
        quotaCalibrationCostUSD: nil,
        quotaDate: nil,
        quotaTrend: [],
        costUSD: nil,
        dataSource: .authorizedAPI,
        fallbackReason: nil,
        attributionText: defaultAttributionText,
        attributionRequired: true,
        siteURL: siteURL,
        message: "正在读取 Codex Radar"
    )

    var hasDisplayData: Bool {
        !models.isEmpty || !quotaRows.isEmpty
    }

    var displayUpdatedAt: Date? {
        let sourceDates = [monitoredAt, quotaUpdatedAt].compactMap { $0 }
        return sourceDates.max() ?? lastFetchAt
    }

    var signalText: String? {
        expectedWindow?.nilIfBlank
            ?? windowMessage?.nilIfBlank
            ?? predictionSummary?.nilIfBlank
    }

    var quotaTrendSummary: CodexRadarQuotaTrendSummary? {
        let values = quotaTrend.compactMap(\.sevenD20x)
        guard let startValue = values.first,
              let endValue = values.last,
              values.count >= 2,
              startValue != 0 else {
            return nil
        }
        let delta = endValue - startValue
        let direction: CodexRadarTrendDirection
        if delta > 0 {
            direction = .positive
        } else if delta < 0 {
            direction = .negative
        } else {
            direction = .neutral
        }
        return CodexRadarQuotaTrendSummary(
            startValue: startValue,
            endValue: endValue,
            delta: delta,
            percentChange: delta / startValue * 100,
            direction: direction
        )
    }

    func withState(_ state: CodexRadarPanelState, message: String? = nil) -> CodexRadarSnapshot {
        var copy = self
        copy.panelState = state
        copy.message = message
        return copy
    }

    static func decodePublicSummary(
        from data: Data,
        fetchedAt: Date? = nil,
        dataSource: CodexRadarDataSource = .publicSummary,
        fallbackReason: CodexRadarFallbackReason? = nil
    ) throws -> CodexRadarSnapshot {
        let summary = try JSONDecoder().decode(CodexRadarPublicSummary.self, from: data)
        let attribution = summary.apiAccess?.requirements
        let attributionText = attribution?.attributionText?.nilIfBlank ?? defaultAttributionText
        let siteURL = attribution?.site.flatMap(URL.init(string:)) ?? Self.siteURL
        let modelIQ = summary.modelIQ
        let models = modelIQ?.modelCards ?? []
        let quotaRows = modelIQ?.quotaRadar?.rows?.map {
            CodexRadarQuotaRow(
                tier: $0.tier.nilIfBlank ?? "Unknown",
                fiveH: $0.fiveH,
                sevenD: $0.sevenD,
                basis: $0.basis?.nilIfBlank
            )
        } ?? []
        let modelCosts = models.compactMap(\.costUSD)
        let modelRunCostUSD = modelCosts.isEmpty ? nil : modelCosts.reduce(0, +)
        let quotaCalibrationCostUSD = modelIQ?.quotaRadar?.costUSD
        let costUSD = quotaCalibrationCostUSD ?? modelRunCostUSD
        let quotaTrend = modelIQ?.quotaRadar?.trend?.map {
            CodexRadarQuotaTrendPoint(
                date: $0.date,
                fiveH20x: $0.fiveH20x,
                sevenD20x: $0.sevenD20x
            )
        } ?? []

        return CodexRadarSnapshot(
            panelState: .ready,
            models: models,
            quotaRows: quotaRows,
            monitoredAt: summary.monitoredAt.flatMap(CodexRadarDateParser.parse),
            quotaUpdatedAt: modelIQ?.quotaRadar?.updatedAt.flatMap(CodexRadarDateParser.parse),
            modelIQDate: modelIQ?.latest?.date?.nilIfBlank,
            lastFetchAt: fetchedAt,
            status: summary.status?.nilIfBlank,
            recommendedAction: summary.recommendedAction?.nilIfBlank,
            windowMessage: summary.window?.message?.nilIfBlank,
            predictionSummary: summary.prediction?.summary?.nilIfBlank,
            expectedWindow: summary.prediction?.expectedWindow?.nilIfBlank,
            modelRunCostUSD: modelRunCostUSD,
            quotaCalibrationCostUSD: quotaCalibrationCostUSD,
            quotaDate: modelIQ?.quotaRadar?.date?.nilIfBlank,
            quotaTrend: quotaTrend,
            costUSD: costUSD,
            dataSource: dataSource,
            fallbackReason: fallbackReason,
            attributionText: attributionText,
            attributionRequired: attribution?.attributionRequired ?? true,
            siteURL: siteURL,
            message: fallbackReason?.displayMessage
        )
    }
}

enum CodexRadarRefreshPolicy {
    static let presentationMaximumAge: TimeInterval = 30 * 60

    static let automaticRefreshHours: [(hour: Int, minute: Int)] = [
        (8, 20),
        (14, 20)
    ]

    static var beijingCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        return calendar
    }

    static func shouldRefresh(lastFetchAt: Date?, now: Date = Date(), calendar: Calendar = beijingCalendar) -> Bool {
        guard let lastFetchAt else {
            return true
        }
        return lastFetchAt < lastScheduledRefresh(before: now, calendar: calendar)
    }

    static func canManualRefresh(lastManualRefreshAt: Date?, now: Date = Date(), minimumGap: TimeInterval = 300) -> Bool {
        guard let lastManualRefreshAt else {
            return true
        }
        return now.timeIntervalSince(lastManualRefreshAt) >= minimumGap
    }

    static func shouldRefreshOnPresentation(
        lastFetchAt: Date?,
        now: Date = Date(),
        maximumAge: TimeInterval = presentationMaximumAge
    ) -> Bool {
        guard let lastFetchAt else {
            return true
        }
        return now.timeIntervalSince(lastFetchAt) >= maximumAge
    }

    static func lastScheduledRefresh(before now: Date, calendar: Calendar = beijingCalendar) -> Date {
        let todayStart = calendar.startOfDay(for: now)
        let todayCandidates = automaticRefreshHours.compactMap { time in
            calendar.date(bySettingHour: time.hour, minute: time.minute, second: 0, of: todayStart)
        }
        if let latestToday = todayCandidates.filter({ $0 <= now }).max() {
            return latestToday
        }
        let yesterday = calendar.date(byAdding: .day, value: -1, to: todayStart) ?? todayStart
        return automaticRefreshHours.compactMap { time in
            calendar.date(bySettingHour: time.hour, minute: time.minute, second: 0, of: yesterday)
        }.max() ?? yesterday
    }

    static func nextScheduledRefresh(after now: Date, calendar: Calendar = beijingCalendar) -> Date {
        let todayStart = calendar.startOfDay(for: now)
        let todayCandidates = automaticRefreshHours.compactMap { time in
            calendar.date(bySettingHour: time.hour, minute: time.minute, second: 0, of: todayStart)
        }
        if let nextToday = todayCandidates.filter({ $0 > now }).min() {
            return nextToday
        }
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: todayStart) ?? todayStart.addingTimeInterval(86_400)
        return automaticRefreshHours.compactMap { time in
            calendar.date(bySettingHour: time.hour, minute: time.minute, second: 0, of: tomorrow)
        }.min() ?? tomorrow
    }
}

enum CodexRadarDateParser {
    static func parse(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) {
            return date
        }

        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }
}

enum CodexRadarBatchDateFormatter {
    static func displayText(_ value: String?) -> String? {
        guard let value = value?.nilIfBlank else {
            return nil
        }
        let parts = value.split(separator: "-").map(String.init)
        guard parts.count >= 4,
              let month = Int(parts[1]),
              let day = Int(parts[2]) else {
            return value
        }
        let period = parts[3].split(separator: "_").first?.uppercased() ?? ""
        guard period == "AM" || period == "PM" else {
            return value
        }
        return "\(month)/\(day) \(period)"
    }
}

enum CodexRadarCurrencyFormatter {
    static func displayText(_ value: Double?) -> String {
        guard let value else {
            return "--"
        }
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        formatter.currencySymbol = "$"
        formatter.locale = Locale(identifier: "en_US")
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        return formatter.string(from: NSNumber(value: value)) ?? String(format: "$%.2f", value)
    }
}

private struct CodexRadarPublicSummary: Decodable {
    let monitoredAt: String?
    let status: String?
    let recommendedAction: String?
    let window: CodexRadarWindowSummary?
    let prediction: CodexRadarPredictionSummary?
    let apiAccess: CodexRadarAPIAccess?
    let modelIQ: CodexRadarModelIQ?

    enum CodingKeys: String, CodingKey {
        case monitoredAt = "monitored_at"
        case status
        case recommendedAction = "recommended_action"
        case window
        case prediction
        case apiAccess = "api_access"
        case modelIQ = "model_iq"
    }
}

private struct CodexRadarWindowSummary: Decodable {
    let message: String?
}

private struct CodexRadarPredictionSummary: Decodable {
    let summary: String?
    let expectedWindow: String?

    enum CodingKeys: String, CodingKey {
        case summary
        case expectedWindow = "expected_window"
    }
}

private struct CodexRadarAPIAccess: Decodable {
    let requirements: CodexRadarAttributionRequirements?
}

private struct CodexRadarAttributionRequirements: Decodable {
    let attributionRequired: Bool?
    let attributionText: String?
    let site: String?

    enum CodingKeys: String, CodingKey {
        case attributionRequired = "attribution_required"
        case attributionText = "attribution_text"
        case site
    }
}

private struct CodexRadarModelIQ: Decodable {
    private static let maximumModelCards = 5
    private static let preferredLatestSeriesEfforts = ["medium", "low"]

    let latest: CodexRadarModelResult?
    let comparisons: [String: CodexRadarComparison]?
    let quotaRadar: CodexRadarQuotaRadar?

    enum CodingKeys: String, CodingKey {
        case latest
        case comparisons
        case quotaRadar = "quota_radar"
    }

    var modelCards: [CodexRadarModelScore] {
        let entries: [CodexRadarModelEntry]
        guard let latest else {
            entries = comparisonEntries(latestModel: nil)
            return selectedEntries(from: entries, capacity: Self.maximumModelCards).map(\.score)
        }

        let latestDescriptor = CodexRadarModelDescriptor(
            key: nil,
            providedLabel: nil,
            model: latest.model,
            reasoningEffort: latest.reasoningEffort
        )
        let latestID = "latest:\(latestDescriptor.normalizedModel):\(latestDescriptor.reasoningEffort ?? "default")"
        entries = comparisonEntries(latestModel: latestDescriptor.normalizedModel)
        let selectedComparisons = selectedEntries(
            from: entries,
            capacity: Self.maximumModelCards - 1
        )
        return [latest.modelScore(id: latestID, descriptor: latestDescriptor)]
            + selectedComparisons.map(\.score)
    }

    private func comparisonEntries(latestModel: String?) -> [CodexRadarModelEntry] {
        (comparisons ?? [:]).compactMap { key, comparison in
            guard let result = comparison.latest else {
                return nil
            }
            let descriptor = CodexRadarModelDescriptor(
                key: key,
                providedLabel: comparison.label,
                model: result.model,
                reasoningEffort: result.reasoningEffort
            )
            return CodexRadarModelEntry(
                score: result.modelScore(id: key, descriptor: descriptor),
                descriptor: descriptor,
                isLatestSeries: descriptor.normalizedModel == latestModel
            )
        }
        .sorted(by: CodexRadarModelEntry.precedes)
    }

    private func selectedEntries(
        from entries: [CodexRadarModelEntry],
        capacity: Int
    ) -> [CodexRadarModelEntry] {
        guard entries.count > capacity, capacity > 0 else {
            return Array(entries.prefix(max(0, capacity)))
        }

        var selectedIDs = Set<String>()
        func select(_ entry: CodexRadarModelEntry) {
            guard selectedIDs.count < capacity else {
                return
            }
            selectedIDs.insert(entry.score.id)
        }

        for effort in Self.preferredLatestSeriesEfforts {
            if let entry = entries.first(where: {
                $0.isLatestSeries && $0.descriptor.reasoningEffort == effort
            }) {
                select(entry)
            }
        }

        var visitedFamilies = Set<String>()
        for entry in entries where !entry.isLatestSeries {
            let family = entry.descriptor.normalizedModel
            guard visitedFamilies.insert(family).inserted else {
                continue
            }
            let familyEntries = entries.filter { $0.descriptor.normalizedModel == family }
            select(familyEntries.first(where: { $0.descriptor.reasoningEffort == "medium" }) ?? entry)
        }

        for entry in entries {
            select(entry)
        }

        return entries.filter { selectedIDs.contains($0.score.id) }
    }
}

private struct CodexRadarModelEntry {
    let score: CodexRadarModelScore
    let descriptor: CodexRadarModelDescriptor
    let isLatestSeries: Bool

    static func precedes(_ lhs: Self, _ rhs: Self) -> Bool {
        if lhs.descriptor.version != rhs.descriptor.version {
            return CodexRadarModelDescriptor.versionPrecedes(lhs.descriptor.version, rhs.descriptor.version)
        }
        if lhs.isLatestSeries != rhs.isLatestSeries {
            return lhs.isLatestSeries
        }
        if lhs.descriptor.effortRank != rhs.descriptor.effortRank {
            return lhs.descriptor.effortRank > rhs.descriptor.effortRank
        }
        if lhs.score.score != rhs.score.score {
            return (lhs.score.score ?? -.infinity) > (rhs.score.score ?? -.infinity)
        }
        return lhs.score.label.localizedCaseInsensitiveCompare(rhs.score.label) == .orderedAscending
    }
}

private struct CodexRadarModelDescriptor {
    private static let effortRanks = [
        "ultra": 6,
        "xhigh": 5,
        "high": 4,
        "medium": 3,
        "low": 2,
        "minimal": 1
    ]

    let model: String?
    let reasoningEffort: String?
    let label: String
    let normalizedModel: String
    let version: [Int]
    let effortRank: Int

    init(key: String?, providedLabel: String?, model: String?, reasoningEffort: String?) {
        let cleanLabel = providedLabel?.nilIfBlank
        let resolvedEffort = reasoningEffort?.nilIfBlank?.lowercased()
            ?? Self.effort(fromLabel: cleanLabel)
            ?? Self.effort(fromKey: key)
        let resolvedModel = model?.nilIfBlank?.lowercased()
            ?? Self.model(fromLabel: cleanLabel, effort: resolvedEffort)
            ?? Self.model(fromKey: key, effort: resolvedEffort)

        self.model = resolvedModel
        self.reasoningEffort = resolvedEffort
        self.label = cleanLabel
            ?? Self.displayLabel(model: resolvedModel, effort: resolvedEffort)
            ?? key?.replacingOccurrences(of: "_", with: " ")
            ?? "Unknown model"
        self.normalizedModel = resolvedModel ?? "unknown"
        self.version = Self.version(from: resolvedModel ?? cleanLabel)
        self.effortRank = Self.effortRanks[resolvedEffort ?? ""] ?? 0
    }

    static func versionPrecedes(_ lhs: [Int], _ rhs: [Int]) -> Bool {
        let count = max(lhs.count, rhs.count)
        for index in 0..<count {
            let left = index < lhs.count ? lhs[index] : 0
            let right = index < rhs.count ? rhs[index] : 0
            if left != right {
                return left > right
            }
        }
        return false
    }

    private static func effort(fromLabel label: String?) -> String? {
        guard let candidate = label?.split(separator: " ").last?.lowercased(),
              effortRanks[candidate] != nil else {
            return nil
        }
        return candidate
    }

    private static func effort(fromKey key: String?) -> String? {
        guard let candidate = key?.split(separator: "_").last?.lowercased(),
              effortRanks[candidate] != nil else {
            return nil
        }
        return candidate
    }

    private static func model(fromLabel label: String?, effort: String?) -> String? {
        guard let label else {
            return nil
        }
        var parts = label.split(separator: " ").map(String.init)
        if let effort, parts.last?.lowercased() == effort {
            parts.removeLast()
        }
        guard !parts.isEmpty else {
            return nil
        }
        return parts.joined(separator: "-").lowercased()
    }

    private static func model(fromKey key: String?, effort: String?) -> String? {
        guard let key else {
            return nil
        }
        var parts = key.split(separator: "_").map(String.init)
        if let effort, parts.last?.lowercased() == effort {
            parts.removeLast()
        }
        guard parts.count >= 2, parts[0].lowercased() == "gpt" else {
            return nil
        }
        let compactVersion = parts[1]
        let version: String
        if compactVersion.contains(".") || compactVersion.count < 2 {
            version = compactVersion
        } else {
            version = "\(compactVersion.prefix(1)).\(compactVersion.dropFirst())"
        }
        return (["gpt", version] + parts.dropFirst(2)).joined(separator: "-").lowercased()
    }

    private static func displayLabel(model: String?, effort: String?) -> String? {
        guard let model else {
            return nil
        }
        let parts = model.split(separator: "-").map(String.init)
        let base: String
        if parts.count >= 2, parts[0].lowercased() == "gpt" {
            let family = parts.dropFirst(2).map { $0.capitalized }.joined(separator: " ")
            base = family.isEmpty ? "GPT-\(parts[1])" : "GPT-\(parts[1]) \(family)"
        } else {
            base = parts.map { $0.capitalized }.joined(separator: " ")
        }
        guard let effort else {
            return base
        }
        return "\(base) \(effort)"
    }

    private static func version(from value: String?) -> [Int] {
        guard let value else {
            return []
        }
        let tokens = value.split { !$0.isNumber && $0 != "." }
        guard let versionToken = tokens.first(where: { $0.contains(".") }) else {
            return []
        }
        return versionToken.split(separator: ".").compactMap { Int($0) }
    }
}

private struct CodexRadarComparison: Decodable {
    let label: String?
    let latest: CodexRadarModelResult?
}

private struct CodexRadarModelResult: Decodable {
    let date: String?
    let score: Double?
    let status: String?
    let passed: Int?
    let tasks: Int?
    let validTasks: Int?
    let invalidTasks: Int?
    let model: String?
    let reasoningEffort: String?
    let costUSD: Double?
    let wallTimeHuman: String?

    enum CodingKeys: String, CodingKey {
        case date
        case score
        case status
        case passed
        case tasks
        case validTasks = "valid_tasks"
        case invalidTasks = "invalid"
        case model
        case reasoningEffort = "reasoning_effort"
        case costUSD = "cost_usd"
        case wallTimeHuman = "wall_time_human"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        date = try container.decodeIfPresent(String.self, forKey: .date)
        score = container.decodeFlexibleDoubleIfPresent(forKey: .score)
        status = try container.decodeIfPresent(String.self, forKey: .status)
        passed = container.decodeFlexibleIntIfPresent(forKey: .passed)
        tasks = container.decodeFlexibleIntIfPresent(forKey: .tasks)
        validTasks = container.decodeFlexibleIntIfPresent(forKey: .validTasks)
        invalidTasks = container.decodeFlexibleIntIfPresent(forKey: .invalidTasks)
        model = try container.decodeIfPresent(String.self, forKey: .model)
        reasoningEffort = try container.decodeIfPresent(String.self, forKey: .reasoningEffort)
        costUSD = container.decodeFlexibleDoubleIfPresent(forKey: .costUSD)
        wallTimeHuman = try container.decodeIfPresent(String.self, forKey: .wallTimeHuman)
    }

    func modelScore(id: String, descriptor: CodexRadarModelDescriptor) -> CodexRadarModelScore {
        CodexRadarModelScore(
            id: id,
            label: descriptor.label,
            model: descriptor.model,
            reasoningEffort: descriptor.reasoningEffort,
            score: score,
            status: status?.nilIfBlank,
            passed: passed,
            tasks: tasks,
            validTasks: validTasks,
            invalidTasks: invalidTasks,
            costUSD: costUSD,
            wallTimeHuman: wallTimeHuman?.nilIfBlank
        )
    }
}

private struct CodexRadarQuotaRadar: Decodable {
    let date: String?
    let updatedAt: String?
    let costUSD: Double?
    let rows: [CodexRadarQuotaRowDTO]?
    let trend: [CodexRadarQuotaTrendPointDTO]?

    enum CodingKeys: String, CodingKey {
        case date
        case updatedAt = "updated_at"
        case costUSD = "cost_usd"
        case rows
        case trend
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        date = try container.decodeIfPresent(String.self, forKey: .date)
        updatedAt = try container.decodeIfPresent(String.self, forKey: .updatedAt)
        costUSD = container.decodeFlexibleDoubleIfPresent(forKey: .costUSD)
        rows = try container.decodeIfPresent([CodexRadarQuotaRowDTO].self, forKey: .rows)
        trend = try container.decodeIfPresent([CodexRadarQuotaTrendPointDTO].self, forKey: .trend)
    }
}

private struct CodexRadarQuotaTrendPointDTO: Decodable {
    let date: String
    let fiveH20x: Double?
    let sevenD20x: Double?

    enum CodingKeys: String, CodingKey {
        case date
        case fiveH20x = "five_h_20x"
        case sevenD20x = "seven_d_20x"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        date = (try container.decodeIfPresent(String.self, forKey: .date)) ?? "unknown"
        fiveH20x = container.decodeFlexibleDoubleIfPresent(forKey: .fiveH20x)
        sevenD20x = container.decodeFlexibleDoubleIfPresent(forKey: .sevenD20x)
    }
}

private struct CodexRadarQuotaRowDTO: Decodable {
    let tier: String
    let basis: String?
    let fiveH: Double?
    let sevenD: Double?

    enum CodingKeys: String, CodingKey {
        case tier
        case basis
        case fiveH = "five_h"
        case sevenD = "seven_d"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tier = (try container.decodeIfPresent(String.self, forKey: .tier)) ?? "Unknown"
        basis = try container.decodeIfPresent(String.self, forKey: .basis)
        fiveH = container.decodeFlexibleDoubleIfPresent(forKey: .fiveH)
        sevenD = container.decodeFlexibleDoubleIfPresent(forKey: .sevenD)
    }
}

private extension KeyedDecodingContainer {
    func decodeFlexibleDoubleIfPresent(forKey key: Key) -> Double? {
        if let value = try? decodeIfPresent(Double.self, forKey: key) {
            return value
        }
        if let value = try? decodeIfPresent(Int.self, forKey: key) {
            return Double(value)
        }
        if let value = try? decodeIfPresent(String.self, forKey: key) {
            return Double(value.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }

    func decodeFlexibleIntIfPresent(forKey key: Key) -> Int? {
        if let value = try? decodeIfPresent(Int.self, forKey: key) {
            return value
        }
        if let value = try? decodeIfPresent(Double.self, forKey: key) {
            return Int(value.rounded())
        }
        if let value = try? decodeIfPresent(String.self, forKey: key) {
            return Int(value.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
