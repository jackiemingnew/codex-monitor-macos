import Foundation

enum AntigravityQuotaParseError: Error, Equatable, LocalizedError {
    case invalidJSON
    case providerRejected
    case sourceRejected
    case providerError
    case missingUsage
    case missingPool(String)

    var errorDescription: String? {
        switch self {
        case .invalidJSON:
            "AGY 返回内容无法解析"
        case .providerRejected:
            "AGY provider 不匹配"
        case .sourceRejected:
            "AGY source 不匹配"
        case .providerError:
            "AGY 本地会话返回错误"
        case .missingUsage:
            "AGY 用量字段缺失"
        case .missingPool(let pool):
            "AGY \(pool) 配额字段缺失"
        }
    }
}

enum AntigravityQuotaParser {
    static let expectedProvider = "antigravity"
    static let expectedSource = "local"
    static let acceptedResultSources: Set<String> = ["local"]

    static func accepts(resultSource: String?) -> Bool {
        guard let resultSource else { return false }
        return acceptedResultSources.contains(resultSource)
    }

    static func parse(_ output: String, receivedAt: Date = Date()) throws -> AntigravityQuotaReading {
        let responses = decodeResponses(from: output)
        guard !responses.isEmpty else {
            throw AntigravityQuotaParseError.invalidJSON
        }

        // The local response form is normally an array. If the service emits
        // more than one provider, choose the requested provider and let the
        // normal provider/source checks reject everything else.
        let response = responses.first(where: { $0.provider == expectedProvider }) ?? responses[0]

        if let error = response.error?.trimmingCharacters(in: .whitespacesAndNewlines), !error.isEmpty {
            _ = error // detect only; never retain or persist helper error text
            throw AntigravityQuotaParseError.providerError
        }
        guard response.provider == expectedProvider else {
            throw AntigravityQuotaParseError.providerRejected
        }
        guard accepts(resultSource: response.source), let resultSource = response.source else {
            throw AntigravityQuotaParseError.sourceRejected
        }
        guard let usage = response.usage else {
            throw AntigravityQuotaParseError.missingUsage
        }
        guard let primary = usage.primary else {
            throw AntigravityQuotaParseError.missingPool("primary")
        }
        guard let secondary = usage.secondary else {
            throw AntigravityQuotaParseError.missingPool("secondary")
        }

        let extras = (usage.extraRateWindows ?? []) + (response.extraRateWindows ?? [])
        let classified = extras.enumerated().compactMap { index, named in
            classify(named, sourceOrder: index)
        }

        // The extraRateWindows collection is authoritative whenever it can be
        // classified by pool and period. Representative primary/secondary
        // fields remain a five-hour fallback only; their window duration must
        // never turn them into an inferred weekly value.
        let primaryFiveHour = choose(
            pool: .primary,
            period: .fiveHour,
            from: classified
        ) ?? fallbackWindow(primary, pool: .primary)
        let primarySevenDay = choose(
            pool: .primary,
            period: .sevenDay,
            from: classified
        )
        let secondaryFiveHour = choose(
            pool: .secondary,
            period: .fiveHour,
            from: classified
        ) ?? fallbackWindow(secondary, pool: .secondary)
        let secondarySevenDay = choose(
            pool: .secondary,
            period: .sevenDay,
            from: classified
        )

        return AntigravityQuotaReading(
            source: resultSource,
            receivedAt: receivedAt,
            sourceUpdatedAt: usage.updatedAt?.date,
            primaryFiveHour: primaryFiveHour,
            primarySevenDay: primarySevenDay,
            secondaryFiveHour: secondaryFiveHour,
            secondarySevenDay: secondarySevenDay
        )
    }

    /// Converts only the quota fields from the local language-server response
    /// into the normalized slots. Account, token and free-form metadata are
    /// discarded before a reading can be returned or cached.
    static func parseLocalResponse(_ response: AntigravityLocalProbe.Response, receivedAt: Date = Date()) throws -> AntigravityQuotaReading {
        switch response.path {
        case AntigravityLocalProbe.quotaSummaryPath:
            return try parseLocalSummary(response.data, receivedAt: receivedAt)
        case AntigravityLocalProbe.userStatusPath, AntigravityLocalProbe.commandModelConfigsPath:
            return try parseLegacyLocalConfig(response.data, receivedAt: receivedAt)
        default:
            throw AntigravityQuotaParseError.invalidJSON
        }
    }

    static func parseLocalSummary(_ data: Data, receivedAt: Date = Date()) throws -> AntigravityQuotaReading {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AntigravityQuotaParseError.invalidJSON
        }
        var extras: [[String: Any]] = []
        for group in dictionaries(in: root) {
            guard let buckets = group["buckets"] as? [[String: Any]] else { continue }
            let groupName = text(group["displayName"] ?? group["display_name"])
            for bucket in buckets {
                let descriptor = [groupName, text(bucket["displayName"] ?? bucket["display_name"]), text(bucket["bucketId"] ?? bucket["bucket_id"])]
                    .joined(separator: " ")
                guard classifyPool(descriptor.lowercased()) != nil,
                      periodMinutes(in: descriptor) != nil else { continue }
                let remaining = fraction(in: bucket)
                let reset = bucket["resetTime"] ?? bucket["reset_time"]
                extras.append([
                    "id": descriptor,
                    "title": descriptor,
                    "usageKnown": bucket["disabled"] as? Bool != true && remaining != nil,
                    "window": ["usedPercent": remaining.map { (1 - $0) * 100 } as Any, "windowMinutes": periodMinutes(in: descriptor) as Any, "resetsAt": reset as Any]
                ])
            }
        }
        // Status/config fallbacks may expose primary/secondary only. They are
        // intentionally normalized as 5h representatives and never fabricate 7d.
        let primary = summaryFiveHour(pool: .primary, extras: extras)
            ?? firstWindow(named: ["gemini", "primary"], in: root)
        let secondary = summaryFiveHour(pool: .secondary, extras: extras)
            ?? firstWindow(named: ["claude", "gpt", "secondary"], in: root)
        guard let primary, let secondary else { throw AntigravityQuotaParseError.missingUsage }
        let object: [String: Any] = ["provider": expectedProvider, "source": expectedSource, "usage": ["primary": primary, "secondary": secondary, "extraRateWindows": extras]]
        let normalized = try JSONSerialization.data(withJSONObject: object)
        return try parse(String(decoding: normalized, as: UTF8.self), receivedAt: receivedAt)
    }

    private static func parseLegacyLocalConfig(_ data: Data, receivedAt: Date) throws -> AntigravityQuotaReading {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AntigravityQuotaParseError.invalidJSON
        }
        let configs = dictionaries(in: root).compactMap {
            ($0["clientModelConfigs"] ?? $0["client_model_configs"]) as? [[String: Any]]
        }.first ?? []
        var candidates: [AntigravityQuotaWindow] = []
        for config in configs {
            let alias = (config["modelOrAlias"] ?? config["model_or_alias"]) as? [String: Any]
            let descriptor = [
                text(config["label"]),
                text(alias?["model"]),
                text(config["displayName"] ?? config["display_name"]),
                text(config["modelName"] ?? config["model_name"]),
                text(config["name"]),
                text(config["modelId"] ?? config["model_id"] ?? config["id"])
            ].joined(separator: " ").lowercased()
            guard let quota = (config["quotaInfo"] ?? config["quota_info"]) as? [String: Any],
                  let pool = classifyPool(descriptor) else { continue }
            let remaining = quota["disabled"] as? Bool == true ? nil : fraction(in: quota).map { AntigravityQuotaWindow.clamp(Int(($0 * 100).rounded())) }
            let reset = FlexibleTimestamp.fromJSON(quota["resetTime"] ?? quota["reset_time"])
            candidates.append(AntigravityQuotaWindow(pool: pool, period: .fiveHour, remainingPercent: remaining, resetsAt: reset))
        }
        guard !candidates.isEmpty else { throw AntigravityQuotaParseError.missingUsage }
        func conservative(_ pool: AntigravityQuotaPool) -> AntigravityQuotaWindow {
            let matches = candidates.filter { $0.pool == pool }
            guard let selected = matches.sorted(by: { ($0.remainingPercent ?? 101) < ($1.remainingPercent ?? 101) }).first else {
                return AntigravityQuotaWindow(pool: pool, period: .fiveHour, remainingPercent: nil, resetsAt: nil)
            }
            return selected
        }
        return AntigravityQuotaReading(source: expectedSource, receivedAt: receivedAt, sourceUpdatedAt: nil,
                                       primaryFiveHour: conservative(.primary), primarySevenDay: nil,
                                       secondaryFiveHour: conservative(.secondary), secondarySevenDay: nil)
    }

    private static func dictionaries(in object: Any) -> [[String: Any]] {
        if let dictionary = object as? [String: Any] {
            return [dictionary] + dictionary.values.flatMap(dictionaries(in:))
        }
        if let values = object as? [Any] { return values.flatMap(dictionaries(in:)) }
        return []
    }

    private static func fraction(in dictionary: [String: Any]) -> Double? {
        if let value = number(dictionary["remainingFraction"] ?? dictionary["remaining_fraction"]) { return value }
        if text(dictionary["case"]) == "remainingFraction", let value = number(dictionary["value"]) { return value }
        if let remaining = dictionary["remaining"] as? [String: Any], let value = fraction(in: remaining) { return value }
        return nil
    }

    private static func number(_ value: Any?) -> Double? {
        if let value = value as? NSNumber { return value.doubleValue }
        if let value = value as? String { return Double(value) }
        return nil
    }

    private static func text(_ value: Any?) -> String {
        value as? String ?? ""
    }

    private static func periodMinutes(in name: String) -> Int? {
        classifyPeriod(name.lowercased(), windowMinutes: nil)?.period.windowMinutes
    }

    private static func firstWindow(named names: [String], in root: [String: Any]) -> [String: Any]? {
        dictionaries(in: root).first { dictionary in
            let descriptor = String(describing: dictionary["displayName"] ?? dictionary["display_name"] ?? dictionary["name"] ?? "").lowercased()
            return names.contains { descriptor.contains($0) } && dictionary["usedPercent"] != nil
        }
    }

    private static func summaryFiveHour(pool: AntigravityQuotaPool, extras: [[String: Any]]) -> [String: Any]? {
        extras.first { extra in
            let descriptor = String(describing: extra["id"] ?? "").lowercased()
            let matchesPool = pool == .primary
                ? descriptor.contains("gemini") || descriptor.contains("primary")
                : descriptor.contains("claude") || descriptor.contains("gpt") || descriptor.contains("secondary")
            return matchesPool && periodMinutes(in: descriptor) == AntigravityQuotaPeriod.fiveHour.windowMinutes
        }?["window"] as? [String: Any]
    }

    static func remainingPercent(fromUsedPercent usedPercent: Double?) -> Int? {
        guard let usedPercent, usedPercent.isFinite else {
            return nil
        }
        let clampedUsed = min(100, max(0, usedPercent))
        return AntigravityQuotaWindow.clamp(Int((100 - clampedUsed).rounded()))
    }

    private struct RawResponse: Decodable {
        let provider: String?
        let source: String?
        let error: String?
        let usage: RawUsage?
        let extraRateWindows: [RawNamedRateWindow]?

        private enum CodingKeys: String, CodingKey {
            case provider
            case source
            case error
            case usage
            case extraRateWindows
            case extraRateWindowsSnake = "extra_rate_windows"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            provider = try container.decodeIfPresent(String.self, forKey: .provider)
            source = try container.decodeIfPresent(String.self, forKey: .source)
            error = try container.decodeIfPresent(String.self, forKey: .error)
            usage = try container.decodeIfPresent(RawUsage.self, forKey: .usage)
            extraRateWindows = try container.decodeIfPresent([RawNamedRateWindow].self, forKey: .extraRateWindows)
                ?? container.decodeIfPresent([RawNamedRateWindow].self, forKey: .extraRateWindowsSnake)
        }
    }

    private struct RawUsage: Decodable {
        let primary: RawWindow?
        let secondary: RawWindow?
        let updatedAt: FlexibleTimestamp?
        let extraRateWindows: [RawNamedRateWindow]?

        private enum CodingKeys: String, CodingKey {
            case primary
            case secondary
            case updatedAt
            case updatedAtSnake = "updated_at"
            case extraRateWindows
            case extraRateWindowsSnake = "extra_rate_windows"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            primary = try container.decodeIfPresent(RawWindow.self, forKey: .primary)
            secondary = try container.decodeIfPresent(RawWindow.self, forKey: .secondary)
            updatedAt = try container.decodeIfPresent(FlexibleTimestamp.self, forKey: .updatedAt)
                ?? container.decodeIfPresent(FlexibleTimestamp.self, forKey: .updatedAtSnake)
            extraRateWindows = try container.decodeIfPresent([RawNamedRateWindow].self, forKey: .extraRateWindows)
                ?? container.decodeIfPresent([RawNamedRateWindow].self, forKey: .extraRateWindowsSnake)
        }
    }

    private struct RawNamedRateWindow: Decodable {
        let id: String?
        let title: String?
        let window: RawWindow?
        let usageKnown: Bool?

        private enum CodingKeys: String, CodingKey {
            case id
            case title
            case window
            case usageKnown
            case usageKnownSnake = "usage_known"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decodeIfPresent(String.self, forKey: .id)
            title = try container.decodeIfPresent(String.self, forKey: .title)
            window = try container.decodeIfPresent(RawWindow.self, forKey: .window)
            usageKnown = try container.decodeIfPresent(Bool.self, forKey: .usageKnown)
                ?? container.decodeIfPresent(Bool.self, forKey: .usageKnownSnake)
        }
    }

    private struct RawWindow: Decodable {
        let usedPercent: FlexiblePercent?
        let windowMinutes: FlexibleInt?
        let resetsAt: FlexibleTimestamp?
        let resetDescription: String?
        let isSyntheticPlaceholder: Bool?

        private enum CodingKeys: String, CodingKey {
            case usedPercent
            case usedPercentSnake = "used_percent"
            case windowMinutes
            case windowMinutesSnake = "window_minutes"
            case resetsAt
            case resetsAtSnake = "resets_at"
            case resetDescription
            case resetDescriptionSnake = "reset_description"
            case isSyntheticPlaceholder
            case isSyntheticPlaceholderSnake = "is_synthetic_placeholder"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            usedPercent = try container.decodeIfPresent(FlexiblePercent.self, forKey: .usedPercent)
                ?? container.decodeIfPresent(FlexiblePercent.self, forKey: .usedPercentSnake)
            windowMinutes = try container.decodeIfPresent(FlexibleInt.self, forKey: .windowMinutes)
                ?? container.decodeIfPresent(FlexibleInt.self, forKey: .windowMinutesSnake)
            resetsAt = try container.decodeIfPresent(FlexibleTimestamp.self, forKey: .resetsAt)
                ?? container.decodeIfPresent(FlexibleTimestamp.self, forKey: .resetsAtSnake)
            resetDescription = try container.decodeIfPresent(String.self, forKey: .resetDescription)
                ?? container.decodeIfPresent(String.self, forKey: .resetDescriptionSnake)
            isSyntheticPlaceholder = try container.decodeIfPresent(Bool.self, forKey: .isSyntheticPlaceholder)
                ?? container.decodeIfPresent(Bool.self, forKey: .isSyntheticPlaceholderSnake)
        }
    }

    private struct ClassifiedWindow {
        let pool: AntigravityQuotaPool
        let period: AntigravityQuotaPeriod
        let window: AntigravityQuotaWindow
        let hasDurationMatch: Bool
        let sourceOrder: Int
    }

    private static func fallbackWindow(
        _ raw: RawWindow,
        pool: AntigravityQuotaPool
    ) -> AntigravityQuotaWindow {
        AntigravityQuotaWindow(
            pool: pool,
            period: .fiveHour,
            remainingPercent: remainingPercent(fromUsedPercent: raw.usedPercent?.value),
            resetsAt: raw.resetsAt?.seconds
        )
    }

    private static func classify(
        _ named: RawNamedRateWindow,
        sourceOrder: Int
    ) -> ClassifiedWindow? {
        guard let rawWindow = named.window else {
            return nil
        }

        let descriptor = [named.id, named.title]
            .compactMap { $0?.lowercased() }
            .joined(separator: " ")
            .replacingOccurrences(of: "_", with: "-")
        guard let pool = classifyPool(descriptor) else {
            return nil
        }
        guard let periodResult = classifyPeriod(descriptor, windowMinutes: rawWindow.windowMinutes?.value) else {
            return nil
        }

        let resetDescriptor = rawWindow.resetDescription?.lowercased() ?? ""
        let synthetic = rawWindow.isSyntheticPlaceholder == true
            || descriptor.contains("synthetic")
            || descriptor.contains("placeholder")
            || descriptor.contains("unknown")
            || resetDescriptor.contains("synthetic")
            || resetDescriptor.contains("placeholder")
            || resetDescriptor.contains("unknown")
        let isKnown = named.usageKnown != false && !synthetic
        let remaining = isKnown
            ? remainingPercent(fromUsedPercent: rawWindow.usedPercent?.value)
            : nil
        let window = AntigravityQuotaWindow(
            pool: pool,
            period: periodResult.period,
            remainingPercent: remaining,
            resetsAt: rawWindow.resetsAt?.seconds
        )
        return ClassifiedWindow(
            pool: pool,
            period: periodResult.period,
            window: window,
            hasDurationMatch: periodResult.hasDurationMatch,
            sourceOrder: sourceOrder
        )
    }

    private static func classifyPool(_ descriptor: String) -> AntigravityQuotaPool? {
        if descriptor.contains("gemini") || descriptor.contains("primary") {
            return .primary
        }
        if descriptor.contains("claude") || descriptor.contains("gpt") || descriptor.contains("secondary") {
            return .secondary
        }
        return nil
    }

    private static func classifyPeriod(
        _ descriptor: String,
        windowMinutes: Int?
    ) -> (period: AntigravityQuotaPeriod, hasDurationMatch: Bool)? {
        // Duration is the strongest signal in the official contract.
        if windowMinutes == AntigravityQuotaPeriod.fiveHour.windowMinutes {
            return (.fiveHour, true)
        }
        if windowMinutes == AntigravityQuotaPeriod.sevenDay.windowMinutes {
            return (.sevenDay, true)
        }

        if descriptor.contains("weekly")
            || descriptor.contains("7d")
            || descriptor.contains("7-day")
            || descriptor.contains("7 day") {
            return (.sevenDay, false)
        }
        if descriptor.contains("5h")
            || descriptor.contains("5-hour")
            || descriptor.contains("5 hour")
            || descriptor.contains("five hour")
            || descriptor.contains("five-hour")
            || descriptor.contains("session") {
            return (.fiveHour, false)
        }
        return nil
    }

    private static func choose(
        pool: AntigravityQuotaPool,
        period: AntigravityQuotaPeriod,
        from candidates: [ClassifiedWindow]
    ) -> AntigravityQuotaWindow? {
        candidates
            .filter { $0.pool == pool && $0.period == period }
            .sorted {
                if $0.hasDurationMatch != $1.hasDurationMatch {
                    return $0.hasDurationMatch && !$1.hasDurationMatch
                }
                // Prefer a known value when duplicate aliases describe the
                // same period, then keep source order stable.
                if ($0.window.remainingPercent != nil) != ($1.window.remainingPercent != nil) {
                    return $0.window.remainingPercent != nil
                }
                return $0.sourceOrder < $1.sourceOrder
            }
            .first?
            .window
    }

    private static func decodeResponses(from output: String) -> [RawResponse] {
        let decoder = JSONDecoder()
        let data = Data(output.utf8)
        var decoded: [RawResponse] = []
        if let response = try? decoder.decode(RawResponse.self, from: data) {
            decoded.append(response)
        }
        if let responses = try? decoder.decode([RawResponse].self, from: data) {
            decoded.append(contentsOf: responses)
        }
        if decoded.contains(where: { $0.provider == expectedProvider }) {
            return decoded
        }

        // A few local service versions prefix/suffix diagnostics.
        // Scan balanced JSON values without retaining the raw payload anywhere
        // in the model or cache.
        let bytes = Array(data)
        var candidates: [[UInt8]] = []
        for start in bytes.indices where bytes[start] == 91 || bytes[start] == 123 { // [ or {
            var depth = 0
            var inString = false
            var escaped = false
            for index in start..<bytes.count {
                let byte = bytes[index]
                if inString {
                    if escaped {
                        escaped = false
                    } else if byte == 92 {
                        escaped = true
                    } else if byte == 34 {
                        inString = false
                    }
                    continue
                }
                if byte == 34 {
                    inString = true
                    continue
                }
                if byte == 91 || byte == 123 {
                    depth += 1
                } else if byte == 93 || byte == 125 {
                    depth -= 1
                    if depth == 0 {
                        candidates.append(Array(bytes[start...index]))
                        break
                    }
                }
            }
        }
        for candidate in candidates {
            if let response = try? decoder.decode(RawResponse.self, from: Data(candidate)) {
                decoded.append(response)
            }
            if let responses = try? decoder.decode([RawResponse].self, from: Data(candidate)) {
                decoded.append(contentsOf: responses)
            }
        }
        return decoded
    }
}

private struct FlexiblePercent: Decodable, Sendable {
    let value: Double

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let integer = try? container.decode(Int.self) {
            value = Double(integer)
            return
        }
        if let number = try? container.decode(Double.self) {
            value = number
            return
        }
        if let string = try? container.decode(String.self),
           let number = Double(string.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "%", with: "")) {
            value = number
            return
        }
        throw DecodingError.dataCorruptedError(in: container, debugDescription: "invalid AGY percent")
    }
}

private struct FlexibleInt: Decodable, Sendable {
    let value: Int

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let integer = try? container.decode(Int.self) {
            value = integer
            return
        }
        if let number = try? container.decode(Double.self), number.isFinite {
            value = Int(number.rounded())
            return
        }
        if let string = try? container.decode(String.self),
           let number = Double(string.trimmingCharacters(in: .whitespacesAndNewlines)),
           number.isFinite {
            value = Int(number.rounded())
            return
        }
        throw DecodingError.dataCorruptedError(in: container, debugDescription: "invalid AGY window duration")
    }
}

private struct FlexibleTimestamp: Decodable, Sendable {
    let seconds: Int
    let date: Date

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let integer = try? container.decode(Int.self) {
            self.init(Double(integer))
            return
        }
        if let number = try? container.decode(Double.self), number.isFinite {
            self.init(number)
            return
        }
        if let string = try? container.decode(String.self) {
            if let number = Double(string), number.isFinite {
                self.init(number)
                return
            }
            let fractionalFormatter = ISO8601DateFormatter()
            fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractionalFormatter.date(from: string)
                ?? ISO8601DateFormatter().date(from: string) {
                self.init(seconds: Int(date.timeIntervalSince1970.rounded()), date: date)
                return
            }
        }
        throw DecodingError.dataCorruptedError(in: container, debugDescription: "invalid AGY timestamp")
    }

    private init(_ rawValue: Double) {
        // Some local adapters emit milliseconds while the normal
        // contract is Unix seconds. Keep the cache unit stable.
        let normalized = rawValue > 100_000_000_000 ? rawValue / 1_000 : rawValue
        self.seconds = Int(normalized.rounded())
        self.date = Date(timeIntervalSince1970: normalized)
    }

    private init(seconds: Int, date: Date) {
        self.seconds = seconds
        self.date = date
    }

    static func fromJSON(_ value: Any?) -> Int? {
        if let value = value as? Int { return FlexibleTimestamp(Double(value)).seconds }
        if let value = value as? Double, value.isFinite { return FlexibleTimestamp(value).seconds }
        if let value = value as? String {
            if let number = Double(value), number.isFinite { return FlexibleTimestamp(number).seconds }
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return (fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value))
                .map { Int($0.timeIntervalSince1970.rounded()) }
        }
        return nil
    }
}
