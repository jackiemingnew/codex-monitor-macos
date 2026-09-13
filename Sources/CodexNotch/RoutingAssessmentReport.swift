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
        let retiredThreads = buckets?.filter(\.isRetired).reduce(0) { $0 + $1.childThreads } ?? 0
        let registeredIdentityMismatches = buckets?.reduce(0) { result, bucket in
            guard bucket.isActive, let matched = bucket.identityMatchedThreads else { return result }
            return result + max(0, bucket.identityCompleteThreads - matched)
        } ?? 0
        if buckets == nil || metric.roleMetadataMissing > 0 || unknownThreads > 0 || registeredIdentityMismatches > 0 {
            identityStatus = .partial
        } else {
            identityStatus = .complete
        }
        efficiencyStatus = .unverified

        let partition = metric.routingTokenPartition
        summary = [
            RoutingAssessmentReportItem(id: "coverage", title: "子任务覆盖", detail: "\(metric.childThreads) / \(metric.sourceThreads) 个窗口内任务"),
            RoutingAssessmentReportItem(id: "burden", title: "整体累计 Token", detail: "\(Self.tokens(metric.cumulativeTokens))（截至评估时的累计值；全部任务）"),
            RoutingAssessmentReportItem(id: "routing-intensity", title: "多代理路由强度", detail: Self.routingTokenShare(metric)),
            RoutingAssessmentReportItem(id: "ultra-intensity", title: "Ultra 单独累计参考", detail: Self.ultraRoutingTokenShare(metric)),
            RoutingAssessmentReportItem(id: "root-coverage", title: "根任务分发覆盖", detail: Self.rootCoverage(partition)),
            RoutingAssessmentReportItem(id: "parent-sources", title: "路由来源（按根任务）", detail: Self.parentSources(partition)),
            RoutingAssessmentReportItem(id: "identity", title: "身份元数据", detail: "完整 \(metric.roleMetadataCovered)；缺失 \(metric.roleMetadataMissing)"),
            RoutingAssessmentReportItem(id: "role-catalog", title: "角色目录", detail: "当前角色 \(RoutingRegisteredRole.activeCases.count) 类；窗口内历史角色任务 \(retiredThreads) 个"),
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
        if partition == nil {
            nextFindings.append(.init(id: "routing-legacy", title: "路由强度不可用", detail: "旧版快照没有通用严格分区；完成下一次扫描后再显示路由强度。"))
        }
        nextFindings.append(.init(id: "evidence", title: "效率结果未验证", detail: "成功率、每成功任务 Token 与真实 E2E speedup 均为 UNVERIFIED。"))
        findings = Array(nextFindings.prefix(5))

        var nextRecommendations: [RoutingAssessmentReportItem] = []
        if metric.orphanEdges > 0 || metric.cycleAffectedChildren > 0 || metric.depthAtLeastTwo > 0 {
            nextRecommendations.append(.init(id: "repair-structure", title: "复核关系采集与嵌套深度", detail: "排查全库孤儿边、循环来源与嵌套深度；下次评估前保持关系写入可追溯。"))
        }
        if buckets == nil {
            nextRecommendations.append(.init(id: "refresh-legacy", title: "刷新角色快照", detail: "运行一次新的轻量扫描，以取得聚合角色细分。"))
        } else if metric.roleMetadataMissing > 0 || unknownThreads > 0 || registeredIdentityMismatches > 0 {
            nextRecommendations.append(.init(id: "repair-identity", title: "补齐角色身份元数据", detail: "确保子任务使用当前角色目录及其匹配的模型和推理强度；历史角色单独保留，不计作当前身份漂移。"))
        }
        nextRecommendations.append(.init(id: "add-outcomes", title: "如需效率结论，另行采集结果证据", detail: "需要经验证的任务结果和真实起止时间；当前 SQLite 证据不足。"))
        recommendations = Array(nextRecommendations.prefix(3))
    }

    var timeRangeText: String { "任务窗口：最近 \(assessment.periodDays) 个本地自然日 · 生成于 \(Self.date(assessment.generatedAt))" }
    var evidenceBoundaryText: String { "仅使用 state SQLite 的聚合结构、元数据和 Token 累计负担。\(assessment.periodDays) 天表示截至评估时的最近活动窗口累计负担，不是该天数的消耗；孤儿关系检查覆盖全库父子边。多代理路由强度只把能够沿完整、唯一、无环、无孤儿父链归属到当前窗口根的子任务计入，分母为实际发生严格分发的根及其已归因子任务；Ultra 单独参考只使用精确 Ultra 根及其严格归因后代，Max 与其他 Effort 不进入该分母。根任务分发覆盖独立显示窗口内有严格归因后代的根占全部根。路由来源先按发起分发的根任务数量展示，子任务 Token 占比仅表示各来源的累计负担，二者不混为一个比例。整体子任务占用则为全部子任务除以全部任务。当前角色按集中目录验证；退役角色仅作历史归因，不作为当前合同漂移。未知角色、模型和推理强度仅进入不透明聚合桶。不读取 JSONL、不联网、不调用模型。" }

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

    private static func routingTokenShare(_ metric: RoutingDailyMetric) -> String {
        let overall = percent(numerator: metric.childCumulativeTokens, denominator: metric.cumulativeTokens)
        guard let partition = metric.routingTokenPartition else {
            return "路由强度 --（旧快照或严格分区不可用）；整体占用 \(overall)（全部子任务÷全部任务）"
        }
        let routing = partition.routingTokenShare.map(percent) ?? "--"
        return "路由内 \(routing)（严格归因子任务÷已分发根与其子任务）；整体占用 \(overall)（全部子任务÷全部任务）；严格归因 \(partition.attributedChildThreads)/\(metric.childThreads) 个子任务，共 \(tokens(partition.attributedChildCumulativeTokens)) Token"
    }

    private static func ultraRoutingTokenShare(_ metric: RoutingDailyMetric) -> String {
        guard let partition = metric.ultraTokenPartition else {
            return "--（旧快照或 Ultra 严格分区不可用）"
        }
        let share = partition.ultraRoutingTokenShare.map(percent) ?? "--"
        return "\(share)（Ultra 严格归因子任务÷Ultra 根与其子任务）；Ultra 根 \(partition.ultraRootThreads) 个，严格归因子任务 \(partition.attributedUltraChildThreads) 个，共 \(tokens(partition.attributedUltraChildCumulativeTokens)) Token"
    }

    private static func rootCoverage(_ partition: RoutingTokenPartition?) -> String {
        guard let partition else { return "--（旧快照或严格分区不可用）" }
        let coverage = partition.routedRootCoverage.map(percent) ?? "--"
        return "\(partition.routedRootThreads)/\(partition.windowRootThreads) 个根（\(coverage)）"
    }

    private static func parentSources(_ partition: RoutingTokenPartition?) -> String {
        guard let partition else { return "--（旧快照或严格分区不可用）" }
        guard !partition.parentSourceBuckets.isEmpty else { return "暂无严格归因父根" }
        return partition.parentSourceBuckets.sorted { lhs, rhs in
            if lhs.rootThreads != rhs.rootThreads {
                return lhs.rootThreads > rhs.rootThreads
            }
            return lhs.id < rhs.id
        }.map { bucket in
            let rootShare = precisePercent(numerator: bucket.rootThreads, denominator: partition.routedRootThreads)
            let childShare = precisePercent(numerator: bucket.attributedChildCumulativeTokens, denominator: partition.attributedChildCumulativeTokens)
            return "\(bucket.modelFamily.rawValue)/\(bucket.effort.rawValue)：\(bucket.rootThreads) 个根（\(rootShare)）；子任务 Token \(tokens(bucket.attributedChildCumulativeTokens))（\(childShare)）"
        }.joined(separator: "；")
    }

    private static func precisePercent(numerator: Int, denominator: Int) -> String {
        guard denominator > 0, numerator > 0 else { return "0%" }
        let share = Double(numerator) / Double(denominator)
        return share < 0.001 ? "<0.1%" : String(format: "%.1f%%", share * 100)
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
        <!doctype html><html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>路由强度评估报告</title><style>body{max-width:760px;margin:40px auto;padding:0 20px;font:15px -apple-system,BlinkMacSystemFont,sans-serif;color:#202124;background:#fff}h1{font-size:26px}h2{font-size:17px;margin-top:28px}p{line-height:1.55;color:#4f5560}ul{padding-left:20px}li{margin:9px 0;line-height:1.45}li span{margin-left:10px;font-weight:600}small{color:#69707a}@media (prefers-color-scheme:dark){body{color:#e8eaed;background:#202124}p{color:#bdc1c6}small{color:#9aa0a6}}</style></head><body><h1>多代理路由强度评估报告</h1><p>\(escape(report.timeRangeText))</p><h2>三类状态</h2><ul>\(status)</ul><h2>关键摘要</h2><ul>\(summary)</ul><h2>关键发现</h2><ul>\(findings)</ul><h2>改进建议</h2><ul>\(recommendations)</ul><h2>证据边界</h2><p>\(escape(report.evidenceBoundaryText))</p><small>本文件为本机手动生成的聚合报告。</small></body></html>
        """
    }

    private static func list(_ items: [RoutingAssessmentReportItem]) -> String {
        items.map { "<li><strong>\(escape($0.title))</strong>：\(escape($0.detail))</li>" }.joined()
    }

    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
}
