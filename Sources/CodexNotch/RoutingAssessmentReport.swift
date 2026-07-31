import Foundation

enum RoutingAssessmentReportStatus: String, Equatable, Sendable {
    case complete = "COMPLETE"
    case partial = "PARTIAL"
    case unverified = "UNVERIFIED"

    var label: String { rawValue }
}

struct RoutingAssessmentReportItem: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let detail: String
}

/// A presentation-only interpretation of a persisted aggregate assessment.
/// It intentionally contains no row identifiers, titles, prompts, or paths.
struct RoutingAssessmentReport: Equatable, Sendable {
    let assessment: RoutingAssessment
    let structureStatus: RoutingAssessmentReportStatus
    let identityStatus: RoutingAssessmentReportStatus
    let efficiencyStatus: RoutingAssessmentReportStatus
    let summary: [RoutingAssessmentReportItem]
    let findings: [RoutingAssessmentReportItem]
    let recommendations: [RoutingAssessmentReportItem]

    init(assessment: RoutingAssessment) {
        self.assessment = assessment
        let metric = assessment.metrics
        structureStatus = metric.quality == .complete ? .complete : .partial

        let buckets = metric.roleBuckets
        let unknownBucket = buckets?.first(where: \.isUnknown)
        let unknownThreads = unknownBucket?.childThreads ?? 0
        let unknownTokenShare = Self.percent(numerator: unknownBucket?.cumulativeTokens ?? 0, denominator: metric.childCumulativeTokens)
        let registeredIdentityMismatches = buckets?.reduce(0) { result, bucket in
            guard bucket.role != nil, let matched = bucket.identityMatchedThreads else { return result }
            return result + max(0, bucket.identityCompleteThreads - matched)
        } ?? 0
        if buckets == nil || metric.roleMetadataMissing > 0 || unknownThreads > 0 || registeredIdentityMismatches > 0 {
            identityStatus = .partial
        } else {
            identityStatus = .complete
        }
        efficiencyStatus = .unverified

        summary = [
            RoutingAssessmentReportItem(id: "coverage", title: "子任务覆盖", detail: "\(metric.childThreads) / \(metric.sourceThreads) 个窗口内任务"),
            RoutingAssessmentReportItem(id: "burden", title: "子任务累计 Token", detail: "\(Self.tokens(metric.childCumulativeTokens))（截至评估时的累计值）"),
            RoutingAssessmentReportItem(id: "dual-token-share", title: "双口径 Token 占比", detail: Self.dualTokenShare(metric)),
            RoutingAssessmentReportItem(id: "identity", title: "身份元数据", detail: "完整 \(metric.roleMetadataCovered)；缺失 \(metric.roleMetadataMissing)"),
            RoutingAssessmentReportItem(id: "structure", title: "结构关系", detail: "深度≥2：\(metric.depthAtLeastTwo) · 全库孤儿：\(metric.orphanEdges) · 循环影响：\(metric.cycleAffectedChildren)")
        ]

        var nextFindings: [RoutingAssessmentReportItem] = []
        if metric.quality != .complete {
            nextFindings.append(.init(id: "quality", title: "结构证据为 PARTIAL", detail: "本次聚合质量为 \(metric.quality.rawValue)，不能作为完整关系图证明。"))
        }
        if metric.orphanEdges > 0 || metric.cycleAffectedChildren > 0 || metric.depthAtLeastTwo > 0 {
            nextFindings.append(.init(id: "topology", title: "发现结构异常或嵌套", detail: "深度≥2：\(metric.depthAtLeastTwo)，全库孤儿关系：\(metric.orphanEdges)，循环影响子任务：\(metric.cycleAffectedChildren)。"))
        }
        if buckets == nil {
            nextFindings.append(.init(id: "legacy", title: "角色明细不可用", detail: "旧版快照没有角色桶；这不是零角色或完整身份证据。"))
        } else if metric.roleMetadataMissing > 0 || unknownThreads > 0 || registeredIdentityMismatches > 0 {
            nextFindings.append(.init(id: "identity", title: "身份归属不完整", detail: "缺失：\(metric.roleMetadataMissing)，未知角色：\(unknownThreads)（未知角色累计 Token 占子任务累计 Token \(unknownTokenShare)），已知角色身份不匹配：\(registeredIdentityMismatches)。"))
        }
        nextFindings.append(.init(id: "evidence", title: "效率结果未验证", detail: "成功率、每成功任务 Token 与真实 E2E speedup 均为 UNVERIFIED。"))
        findings = Array(nextFindings.prefix(4))

        var nextRecommendations: [RoutingAssessmentReportItem] = []
        if metric.orphanEdges > 0 || metric.cycleAffectedChildren > 0 || metric.depthAtLeastTwo > 0 {
            nextRecommendations.append(.init(id: "repair-structure", title: "复核关系采集与嵌套深度", detail: "排查全库孤儿边、循环来源与嵌套深度；下次评估前保持关系写入可追溯。"))
        }
        if buckets == nil {
            nextRecommendations.append(.init(id: "refresh-legacy", title: "刷新角色快照", detail: "运行一次新的轻量扫描，以取得聚合角色细分。"))
        } else if metric.roleMetadataMissing > 0 || unknownThreads > 0 || registeredIdentityMismatches > 0 {
            nextRecommendations.append(.init(id: "repair-identity", title: "补齐角色身份元数据", detail: "确保子任务有已注册角色及其匹配的模型和推理强度元数据。"))
        }
        nextRecommendations.append(.init(id: "add-outcomes", title: "如需效率结论，另行采集结果证据", detail: "需要经验证的任务结果和真实起止时间；当前 SQLite 证据不足。"))
        recommendations = Array(nextRecommendations.prefix(3))
    }

    var timeRangeText: String { "任务窗口：最近 \(assessment.periodDays) 个本地自然日 · 生成于 \(Self.date(assessment.generatedAt))" }
    var evidenceBoundaryText: String { "仅使用 state SQLite 的聚合结构、元数据和 Token 累计负担。30 天表示截至评估时的最近活动窗口累计负担，不是 30 天消耗；孤儿关系检查覆盖全库父子边。双口径均为截至评估时的累计占比：整体为子任务除以窗口内全部任务；Ultra 路由只把能够沿唯一、无环、无孤儿父链归属到窗口内 gpt-5.6-sol/ultra 根的子任务计入，分母为这些 Ultra 根及其已归因子任务，Max 根不计入。其余子任务保留在整体口径，不强行归入 Ultra。不读取 JSONL、不联网、不调用模型。" }

    private static func tokens(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: value)) ?? "0"
    }

    private static func date(_ value: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: value)
    }

    private static func percent(numerator: Int, denominator: Int) -> String {
        guard denominator > 0 else { return "0%" }
        return "\(Int((Double(max(0, numerator)) / Double(denominator) * 100).rounded()))%"
    }

    private static func percent(_ value: Double) -> String {
        "\(Int((max(0, value) * 100).rounded()))%"
    }

    private static func dualTokenShare(_ metric: RoutingDailyMetric) -> String {
        let overall = percent(numerator: metric.childCumulativeTokens, denominator: metric.cumulativeTokens)
        guard let partition = metric.ultraTokenPartition else {
            return "整体 \(overall)；Ultra 路由内 --（旧快照或严格分区不可用）；Max 根不计入"
        }
        let ultra = partition.ultraRoutingTokenShare.map(percent) ?? "--"
        return "整体 \(overall)（子任务÷全部任务）；Ultra 路由内 \(ultra)（已归因子任务÷Ultra 根与其子任务）；严格归因 \(partition.attributedUltraChildThreads)/\(metric.childThreads) 个子任务，共 \(tokens(partition.attributedUltraChildCumulativeTokens)) Token；Max 根不计入"
    }
}

enum RoutingAssessmentReportHTMLRenderer {
    static func render(_ report: RoutingAssessmentReport) -> String {
        let status = [
            ("结构", report.structureStatus.label),
            ("身份", report.identityStatus.label),
            ("效率", report.efficiencyStatus.label)
        ].map { "<li><strong>\(escape($0.0))</strong><span>\(escape($0.1))</span></li>" }.joined()
        let summary = list(report.summary)
        let findings = list(report.findings)
        let recommendations = list(report.recommendations)
        return """
        <!doctype html><html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>路由手动评估报告</title><style>body{max-width:760px;margin:40px auto;padding:0 20px;font:15px -apple-system,BlinkMacSystemFont,sans-serif;color:#202124;background:#fff}h1{font-size:26px}h2{font-size:17px;margin-top:28px}p{line-height:1.55;color:#4f5560}ul{padding-left:20px}li{margin:9px 0;line-height:1.45}li span{margin-left:10px;font-weight:600}small{color:#69707a}@media (prefers-color-scheme:dark){body{color:#e8eaed;background:#202124}p{color:#bdc1c6}small{color:#9aa0a6}}</style></head><body><h1>路由手动评估报告</h1><p>\(escape(report.timeRangeText))</p><h2>三类状态</h2><ul>\(status)</ul><h2>关键摘要</h2><ul>\(summary)</ul><h2>关键发现</h2><ul>\(findings)</ul><h2>改进建议</h2><ul>\(recommendations)</ul><h2>证据边界</h2><p>\(escape(report.evidenceBoundaryText))</p><small>本文件为本机手动生成的聚合报告。</small></body></html>
        """
    }

    private static func list(_ items: [RoutingAssessmentReportItem]) -> String {
        items.map { "<li><strong>\(escape($0.title))</strong>：\(escape($0.detail))</li>" }.joined()
    }

    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
}
