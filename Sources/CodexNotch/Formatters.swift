import Foundation

enum Formatters {
    enum QuotaResetDisplayStyle {
        case time
        case date
    }

    static func compactTokens(_ value: Int) -> String {
        let absolute = abs(value)
        if absolute >= 100_000_000 {
            return String(format: "%.1f亿", Double(value) / 100_000_000)
        }
        if absolute >= 10_000 {
            return String(format: "%.0f万", Double(value) / 10_000)
        }
        if absolute >= 1_000 {
            return String(format: "%.1f千", Double(value) / 1_000)
        }
        return "\(value)"
    }

    static func compactTokens(_ value: Int, isPartial: Bool) -> String {
        let formatted = compactTokens(value)
        return isPartial ? "≥\(formatted)" : formatted
    }

    static func compactTokensEnglish(_ value: Int) -> String {
        let absolute = abs(value)
        if absolute >= 1_000_000_000 {
            return String(format: "%.1fB", Double(value) / 1_000_000_000)
        }
        if absolute >= 1_000_000 {
            return String(format: "%.1fM", Double(value) / 1_000_000)
        }
        if absolute >= 1_000 {
            return String(format: "%.1fK", Double(value) / 1_000)
        }
        return "\(value)"
    }

    static func compactTokensEnglish(_ value: Int, isPartial: Bool) -> String {
        let formatted = compactTokensEnglish(value)
        return isPartial ? "≥\(formatted)" : formatted
    }

    static func partialUsageHelp(
        label: String,
        isPartial: Bool,
        missingBaselineSessions: Int
    ) -> String? {
        guard isPartial else {
            return nil
        }
        guard missingBaselineSessions > 0 else {
            return "\(label)缺少完整历史基线，当前数值为已确认最低值。"
        }
        return "\(label)有 \(missingBaselineSessions) 个会话缺少历史基线，当前数值为已确认最低值。"
    }

    static func apiEquivalentCost(_ window: CostEstimateWindow) -> String {
        guard let usd = window.usd, usd.isFinite, usd >= 0 else {
            return window.isPartial ? "回填中" : "--"
        }

        let amount: String
        if usd > 0, usd < 0.01 {
            amount = "<$0.01"
        } else if usd < 100 {
            amount = String(format: "$%.2f", usd)
        } else if usd < 1_000 {
            amount = String(format: "$%.1f", usd)
        } else if usd < 1_000_000 {
            let formatter = NumberFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.numberStyle = .decimal
            formatter.maximumFractionDigits = 0
            formatter.minimumFractionDigits = 0
            amount = "$" + (formatter.string(from: NSNumber(value: usd)) ?? String(format: "%.0f", usd))
        } else {
            amount = String(format: "$%.1fM", usd / 1_000_000)
        }
        return "≈\(amount)\(window.isPartial ? "*" : "")"
    }

    static func apiEquivalentCostHelp(
        label: String,
        window: CostEstimateWindow,
        summary: CostUsageSummary
    ) -> String {
        var parts = [
            "\(label)按 OpenAI API 标准单价等值估算，不是 ChatGPT/Codex 订阅账单。",
            "不含 Priority、区域溢价和工具调用费。"
        ]
        if window.usd == nil, window.isPartial {
            parts.append("正在后台扫描完整本地历史；完成前不发布局部金额。")
        } else if window.isPartial {
            parts.append("带 * 表示窗口包含未知模型；当前金额只统计可确认定价的模型。")
        }
        if summary.usesSparkProxy {
            parts.append("Spark 使用 GPT-5.3-Codex 标准单价作为代理。")
        }
        if window.tokenCount != nil {
            parts.append("Token 与费用来自同一份完整历史快照。")
        }
        if let lastUpdated = summary.lastUpdated {
            parts.append("费用缓存于 \(relativeAge(lastUpdated))前更新。")
        }
        return parts.joined(separator: " ")
    }

    static func reasoningEffortLabel(_ effort: String?) -> String {
        switch effort {
        case "none":
            "无推理"
        case "minimal":
            "极低推理"
        case "low":
            "低推理"
        case "medium":
            "中等推理"
        case "high":
            "高推理"
        case "xhigh":
            "超高推理"
        case "ultra":
            "极致推理"
        case let value? where !value.isEmpty:
            value
        default:
            "推理未知"
        }
    }

    static func percent(_ value: Int?) -> String {
        guard let value else {
            return "--"
        }
        return "\(value)%"
    }

    static func percent(_ value: Double?) -> String {
        guard let value, value.isFinite else {
            return "--"
        }
        return String(format: "%.1f%%", value)
    }

    static func wholePercent(_ value: Double?) -> String {
        guard let value, value.isFinite else {
            return "--"
        }
        return "\(Int(value.rounded()))%"
    }

    static func compactTokensWithShare(tokens: Int?, sharePercent: Double?) -> String {
        guard let tokens else {
            return "--"
        }
        return "\(compactTokens(tokens)) \(wholePercent(sharePercent))"
    }

    static func quotaResetText(
        _ resetAt: Int?,
        style: QuotaResetDisplayStyle = .time,
        now: Date = Date(),
        timeZone: TimeZone = .current
    ) -> String? {
        guard let resetAt, resetAt > Int(now.timeIntervalSince1970) else {
            return nil
        }

        let resetDate = Date(timeIntervalSince1970: TimeInterval(resetAt))
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        switch style {
        case .time:
            formatter.dateFormat = "HH:mm"
        case .date:
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = timeZone
            let currentYear = calendar.component(.year, from: now)
            let resetYear = calendar.component(.year, from: resetDate)
            formatter.dateFormat = currentYear == resetYear ? "M/d" : "yyyy/M/d"
        }
        return "\(formatter.string(from: resetDate)) 恢复"
    }

    static func signedCompactTokens(_ value: Int?) -> String {
        guard let value else {
            return "--"
        }
        guard value > 0 else {
            return "0"
        }
        return "+\(compactTokens(value))"
    }

    static func signedCompactTokensEnglish(_ value: Int?) -> String {
        guard let value else {
            return "--"
        }
        guard value > 0 else {
            return "0"
        }
        return "+\(compactTokensEnglish(value))"
    }

    static func compactTokenRatio(_ numerator: Int?, _ denominator: Int?) -> String {
        guard let numerator, let denominator, denominator > 0 else {
            return "--"
        }
        return "\(compactTokens(numerator))/\(compactTokens(denominator))"
    }

    static func shortTitle(_ title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return "未命名任务"
        }
        if trimmed.count <= 22 {
            return trimmed
        }
        let end = trimmed.index(trimmed.startIndex, offsetBy: 22)
        return String(trimmed[..<end]) + "..."
    }

    static func relativeAge(_ date: Date, now: Date = Date()) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 60 {
            return "\(seconds)秒"
        }
        if seconds < 3600 {
            return "\(seconds / 60)分钟"
        }
        if seconds < 86400 {
            return "\(seconds / 3600)小时"
        }
        return "\(seconds / 86400)天"
    }

    static func compactDuration(until date: Date, now: Date = Date()) -> String {
        let seconds = max(0, Int(date.timeIntervalSince(now)))
        if seconds < 60 {
            return "不到1分钟"
        }
        if seconds < 3_600 {
            return "\(max(1, seconds / 60))分钟"
        }
        if seconds < 86_400 {
            let hours = max(1, seconds / 3_600)
            return "\(hours)小时"
        }
        let days = max(1, seconds / 86_400)
        return "\(days)天"
    }
}
