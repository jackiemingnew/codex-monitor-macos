import Foundation

private func analyticsClampedAdd(_ lhs: Int, _ rhs: Int) -> Int {
    let (sum, overflow) = lhs.addingReportingOverflow(rhs)
    return overflow ? Int.max : sum
}

enum CodexAnalyticsQuality: String, Codable, Equatable, Sendable {
    case complete = "COMPLETE"
    case partial = "PARTIAL"
    case unavailable = "UNAVAILABLE"
}

struct CodexAnalyticsBreakdown: Codable, Equatable, Identifiable, Sendable {
    let name: String
    let count: Int
    let share: Double

    var id: String { name }

    var percentLabel: String {
        guard count > 0 else { return "0%" }
        if share > 0, share < 0.01 {
            return "<1%"
        }
        return "\(Int((share * 100).rounded()))%"
    }
}

struct CodexAnalyticsSeriesValue: Codable, Equatable, Identifiable, Sendable {
    let name: String
    let count: Int

    var id: String { name }
}

struct CodexAnalyticsDailyPoint: Codable, Equatable, Identifiable, Sendable {
    let index: Int
    let dateLabel: String
    let values: [CodexAnalyticsSeriesValue]

    var id: Int { index }
    var total: Int { values.reduce(0) { analyticsClampedAdd($0, $1.count) } }

    func count(for members: Set<String>) -> Int {
        values.reduce(0) { partial, value in
            members.contains(value.name) ? analyticsClampedAdd(partial, value.count) : partial
        }
    }
}

struct CodexAnalyticsDisplaySeries: Equatable, Identifiable, Sendable {
    let name: String
    let total: Int
    let members: Set<String>
    let isOther: Bool

    var id: String { name }
}

struct CodexAnalyticsChart: Codable, Equatable, Sendable {
    let points: [CodexAnalyticsDailyPoint]
    let sampledDays: Int
    let expectedDays: Int

    static let empty = CodexAnalyticsChart(points: [], sampledDays: 0, expectedDays: 7)

    var coverageLabel: String { "\(sampledDays)/\(expectedDays) 天" }

    func displaySeries(limit: Int) -> [CodexAnalyticsDisplaySeries] {
        let boundedLimit = max(1, limit)
        var totals: [String: Int] = [:]
        for point in points {
            for value in point.values where value.count > 0 {
                totals[value.name] = analyticsClampedAdd(totals[value.name, default: 0], value.count)
            }
        }
        let sorted = totals
            .map { name, total in
                CodexAnalyticsDisplaySeries(
                    name: name,
                    total: total,
                    members: [name],
                    isOther: false
                )
            }
            .sorted {
                if $0.total == $1.total {
                    return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                }
                return $0.total > $1.total
            }
        guard sorted.count > boundedLimit else { return sorted }

        let leading = Array(sorted.prefix(boundedLimit))
        let remainder = sorted.dropFirst(boundedLimit)
        return leading + [CodexAnalyticsDisplaySeries(
            name: "其他",
            total: remainder.reduce(0) { analyticsClampedAdd($0, $1.total) },
            members: Set(remainder.flatMap(\.members)),
            isOther: true
        )]
    }

    func fullAccessibilityText(label: String) -> String {
        guard !points.isEmpty else { return "\(label)：无每日图表数据" }
        let daily = points.map { point in
            let values = point.values
                .filter { $0.count > 0 }
                .sorted {
                    if $0.count == $1.count {
                        return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                    }
                    return $0.count > $1.count
                }
                .map { "\($0.name) \($0.count)" }
                .joined(separator: "、")
            return "\(point.dateLabel)：\(values.isEmpty ? "0" : values)"
        }
        .joined(separator: "；")
        return "\(label) \(coverageLabel)：\(daily)"
    }
}

struct CodexAnalyticsSnapshot: Codable, Equatable, Sendable {
    let turns: Int?
    let skillsUsed: Int?
    let pluginCalls: Int?
    let surfaces: [CodexAnalyticsBreakdown]
    let models: [CodexAnalyticsBreakdown]
    let turnsByModel: CodexAnalyticsChart
    let turnsBySurface: CodexAnalyticsChart
    let skillsBySkill: CodexAnalyticsChart
    let capturedAt: Date
    let rangeStartLabel: String?
    let rangeEndLabel: String?
    let timeZone: String?
    let quality: CodexAnalyticsQuality
    let qualityIssues: [String]

    static let empty = CodexAnalyticsSnapshot(
        turns: nil,
        skillsUsed: nil,
        pluginCalls: nil,
        surfaces: [],
        models: [],
        turnsByModel: .empty,
        turnsBySurface: .empty,
        skillsBySkill: .empty,
        capturedAt: .distantPast,
        rangeStartLabel: nil,
        rangeEndLabel: nil,
        timeZone: nil,
        quality: .unavailable,
        qualityIssues: ["尚未读取官方网页"]
    )

    var rangeHelpText: String {
        let labels = [rangeStartLabel, rangeEndLabel].compactMap { $0 }
        var parts: [String] = []
        if labels.count == 2 {
            parts.append("\(labels[0]) 至 \(labels[1])")
        } else if let label = labels.first {
            parts.append(label)
        }
        if let timeZone, !timeZone.isEmpty {
            parts.append(timeZone)
        }
        return parts.joined(separator: " · ")
    }

    func compactBreakdown(_ values: [CodexAnalyticsBreakdown], limit: Int = 3) -> [CodexAnalyticsBreakdown] {
        let positive = values
            .filter { $0.count > 0 }
            .sorted {
                if $0.count == $1.count { return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                return $0.count > $1.count
            }
        guard positive.count > limit else { return positive }

        let leading = Array(positive.prefix(limit))
        let remainderCount = positive.dropFirst(limit).reduce(0) { analyticsClampedAdd($0, $1.count) }
        let total = turns ?? values.reduce(0) { analyticsClampedAdd($0, $1.count) }
        guard remainderCount > 0, total > 0 else { return leading }
        return leading + [CodexAnalyticsBreakdown(
            name: "其他",
            count: remainderCount,
            share: Double(remainderCount) / Double(total)
        )]
    }

    func fullBreakdownHelp(label: String, values: [CodexAnalyticsBreakdown]) -> String {
        let content = values
            .filter { $0.count > 0 }
            .sorted {
                if $0.count == $1.count { return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                return $0.count > $1.count
            }
            .map { "\($0.name) \($0.count)（\($0.percentLabel)）" }
            .joined(separator: "、")
        return content.isEmpty ? "\(label)：--" : "\(label)：\(content)"
    }
}

struct CodexWebAnalyticsRawCount: Codable, Equatable, Sendable {
    let name: String
    let count: Int
}

struct CodexWebAnalyticsRawDailyPoint: Codable, Equatable, Sendable {
    let dateLabel: String
    let values: [CodexWebAnalyticsRawCount]
}

struct CodexWebAnalyticsRawSnapshot: Codable, Equatable, Sendable {
    let rangeSelected: Bool
    let turns: Int?
    let skillsUsed: Int?
    let pluginCalls: Int?
    let modelPoints: [CodexWebAnalyticsRawDailyPoint]
    let surfacePoints: [CodexWebAnalyticsRawDailyPoint]
    let skillPoints: [CodexWebAnalyticsRawDailyPoint]
    let expectedDays: Int
    let rangeStartLabel: String?
    let rangeEndLabel: String?
    let timeZone: String?
}

enum CodexWebAnalyticsParseError: LocalizedError, Equatable {
    case oversizedResult
    case invalidResult

    var errorDescription: String? {
        switch self {
        case .oversizedResult:
            "Analytics 网页解析结果超过安全上限"
        case .invalidResult:
            "Analytics 网页返回了无法识别的数据"
        }
    }
}

enum CodexWebAnalyticsParser {
    static let maximumResultBytes = 512 * 1024

    static func decode(_ json: String) throws -> CodexWebAnalyticsRawSnapshot {
        guard let data = json.data(using: .utf8) else {
            throw CodexWebAnalyticsParseError.invalidResult
        }
        guard data.count <= maximumResultBytes else {
            throw CodexWebAnalyticsParseError.oversizedResult
        }
        do {
            return try JSONDecoder().decode(CodexWebAnalyticsRawSnapshot.self, from: data)
        } catch {
            throw CodexWebAnalyticsParseError.invalidResult
        }
    }
}

enum CodexWebAnalyticsSnapshotBuilder {
    private static let supportedExpectedDays = 7
    private static let maximumPoints = 31
    private static let maximumValuesPerPoint = 128

    static func build(
        raw: CodexWebAnalyticsRawSnapshot,
        capturedAt: Date = Date()
    ) -> CodexAnalyticsSnapshot {
        let turns = nonnegative(raw.turns)
        let skills = nonnegative(raw.skillsUsed)
        let plugins = nonnegative(raw.pluginCalls)
        let expectedDays = max(1, min(maximumPoints, raw.expectedDays))
        var issues: [String] = []

        if !raw.rangeSelected {
            issues.append("未确认官网最近 7 天范围")
        }
        if raw.expectedDays != supportedExpectedDays {
            issues.append("网页时间范围不是 7 天")
        }
        if turns == nil { issues.append("缺少总 Turns") }
        if skills == nil { issues.append("缺少 Skills 使用次数") }
        if plugins == nil { issues.append("缺少 Plugin 调用次数") }

        let modelResult = validatedChart(
            raw.modelPoints,
            total: turns,
            expectedDays: expectedDays,
            label: "模型"
        )
        let surfaceResult = validatedChart(
            raw.surfacePoints,
            total: turns,
            expectedDays: expectedDays,
            label: "Surface"
        )
        let skillResult = validatedChart(
            raw.skillPoints,
            total: skills,
            expectedDays: expectedDays,
            label: "Skills"
        )
        issues.append(contentsOf: modelResult.issues)
        issues.append(contentsOf: surfaceResult.issues)
        issues.append(contentsOf: skillResult.issues)

        let nonemptyDateSets = [modelResult.chart, surfaceResult.chart, skillResult.chart]
            .map { $0.points.map(\.dateLabel) }
            .filter { !$0.isEmpty }
        if let firstDates = nonemptyDateSets.first,
           nonemptyDateSets.dropFirst().contains(where: { $0 != firstDates }) {
            issues.append("图表日期集合不一致")
        }

        let hasAnyValue = turns != nil
            || skills != nil
            || plugins != nil
            || !modelResult.chart.points.isEmpty
            || !surfaceResult.chart.points.isEmpty
            || !skillResult.chart.points.isEmpty
        let quality: CodexAnalyticsQuality
        if !hasAnyValue {
            quality = .unavailable
        } else if issues.isEmpty {
            quality = .complete
        } else {
            quality = .partial
        }

        let rangeSource = [modelResult.chart, surfaceResult.chart, skillResult.chart]
            .max { $0.points.count < $1.points.count }
        return CodexAnalyticsSnapshot(
            turns: turns,
            skillsUsed: skills,
            pluginCalls: plugins,
            surfaces: surfaceResult.breakdown,
            models: modelResult.breakdown,
            turnsByModel: modelResult.chart,
            turnsBySurface: surfaceResult.chart,
            skillsBySkill: skillResult.chart,
            capturedAt: capturedAt,
            rangeStartLabel: sanitized(raw.rangeStartLabel, maximumLength: 80)
                ?? rangeSource?.points.first?.dateLabel,
            rangeEndLabel: sanitized(raw.rangeEndLabel, maximumLength: 80)
                ?? rangeSource?.points.last?.dateLabel,
            timeZone: sanitized(raw.timeZone, maximumLength: 80),
            quality: quality,
            qualityIssues: deduplicated(issues)
        )
    }

    private static func validatedChart(
        _ rawPoints: [CodexWebAnalyticsRawDailyPoint],
        total: Int?,
        expectedDays: Int,
        label: String
    ) -> (chart: CodexAnalyticsChart, breakdown: [CodexAnalyticsBreakdown], issues: [String]) {
        var issues: [String] = []
        var points: [CodexAnalyticsDailyPoint] = []
        var seenDates: Set<String> = []

        if rawPoints.count > maximumPoints {
            issues.append("\(label)图表日期超过安全上限")
        }
        for rawPoint in rawPoints.prefix(maximumPoints) {
            guard let dateLabel = sanitized(rawPoint.dateLabel, maximumLength: 80) else {
                issues.append("\(label)图表包含无效日期")
                continue
            }
            guard seenDates.insert(dateLabel).inserted else {
                issues.append("\(label)图表包含重复日期")
                continue
            }
            if rawPoint.values.count > maximumValuesPerPoint {
                issues.append("\(label)图表分类超过安全上限")
            }
            var merged: [String: Int] = [:]
            for rawValue in rawPoint.values.prefix(maximumValuesPerPoint) {
                guard let name = sanitized(rawValue.name, maximumLength: 80),
                      !name.isEmpty,
                      rawValue.count >= 0 else {
                    issues.append("\(label)图表包含无效分类数据")
                    continue
                }
                let current = merged[name, default: 0]
                let (sum, overflow) = current.addingReportingOverflow(rawValue.count)
                if overflow {
                    issues.append("\(label)图表计数溢出")
                } else {
                    merged[name] = sum
                }
            }
            let values = merged
                .map { CodexAnalyticsSeriesValue(name: $0.key, count: $0.value) }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            points.append(CodexAnalyticsDailyPoint(index: points.count, dateLabel: dateLabel, values: values))
        }

        let explicitZeroWithoutSeries = total == 0 && points.isEmpty
        let sampledDays = explicitZeroWithoutSeries ? expectedDays : points.count
        if sampledDays != expectedDays {
            issues.append("\(label)图表只读取到 \(sampledDays)/\(expectedDays) 天")
        }

        let chart = CodexAnalyticsChart(
            points: points,
            sampledDays: sampledDays,
            expectedDays: expectedDays
        )
        var aggregate: [String: Int] = [:]
        var aggregateOverflow = false
        for point in points {
            for value in point.values {
                let current = aggregate[value.name, default: 0]
                let (sum, overflow) = current.addingReportingOverflow(value.count)
                if overflow {
                    aggregateOverflow = true
                } else {
                    aggregate[value.name] = sum
                }
            }
        }
        var aggregateTotal = 0
        for value in aggregate.values {
            let (sum, overflow) = aggregateTotal.addingReportingOverflow(value)
            if overflow {
                aggregateOverflow = true
            } else {
                aggregateTotal = sum
            }
        }
        if aggregateOverflow {
            issues.append("\(label)图表合计溢出")
        }
        if let total {
            if aggregateTotal != total, !explicitZeroWithoutSeries {
                issues.append("\(label)图表合计 \(aggregateTotal) 与官方总数 \(total) 不一致")
            }
        } else {
            issues.append("\(label)图表缺少官方总数校验")
        }

        let isValidated = issues.isEmpty && total != nil
        let breakdown: [CodexAnalyticsBreakdown]
        if isValidated, let total, total > 0 {
            breakdown = aggregate.map { name, count in
                CodexAnalyticsBreakdown(
                    name: name,
                    count: count,
                    share: Double(count) / Double(total)
                )
            }
            .sorted {
                if $0.count == $1.count {
                    return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                }
                return $0.count > $1.count
            }
        } else {
            breakdown = []
        }
        return (chart, breakdown, issues)
    }

    private static func nonnegative(_ value: Int?) -> Int? {
        guard let value, value >= 0 else { return nil }
        return value
    }

    private static func deduplicated(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.filter { seen.insert($0).inserted }
    }

    private static func sanitized(_ value: String?, maximumLength: Int) -> String? {
        guard let value else { return nil }
        let collapsed = value
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !collapsed.isEmpty else { return nil }
        return String(collapsed.prefix(maximumLength))
    }
}

struct CodexAnalyticsCachePolicy: Equatable, Sendable {
    let timeToLive: TimeInterval

    static let standard = CodexAnalyticsCachePolicy(timeToLive: 30 * 60)

    func isFresh(lastSuccessAt: Date?, now: Date = Date()) -> Bool {
        guard let lastSuccessAt else { return false }
        let age = now.timeIntervalSince(lastSuccessAt)
        return age >= 0 && age < timeToLive
    }
}

@MainActor
protocol CodexAnalyticsProviding: AnyObject {
    var isReady: Bool { get }
    var onReadinessChange: ((Bool) -> Void)? { get set }
    func start()
    func reload()
    func clearSession() async
    func fetchSnapshot() async throws -> CodexWebAnalyticsRawSnapshot
}
