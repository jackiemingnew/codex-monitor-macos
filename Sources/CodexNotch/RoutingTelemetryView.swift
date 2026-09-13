import Charts
import SwiftUI

struct RoutingTelemetryView: View {
    @ObservedObject var viewModel: RoutingTelemetryViewModel
    let onOpenAssessmentReport: (RoutingAssessment) -> Void
    @State private var days = 7
    @State private var showMoreData = false

    private var points: [RoutingDailyMetric] {
        Array(viewModel.snapshot.days.suffix(days))
    }

    private var latest: RoutingDailyMetric? {
        points.last
    }

    private var hasDailyObservation: Bool {
        points.contains {
            $0.routingDailyObservedTokenShare != nil
                || $0.ultraRoutingDailyObservedTokenShare != nil
        }
    }

    private var routingGuidance: RoutingDeltaGuidance {
        RoutingDeltaGuidance.evaluate(points)
    }

    private var ultraGuidance: RoutingUltraDeltaGuidance {
        RoutingUltraDeltaGuidance.evaluate(points)
    }

    var body: some View {
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: MonitorTheme.Spacing.row) {
                sourceStrip
                periodPicker
                routingGuidanceCard
                trend
                moreDataButton
                if showMoreData {
                    latestSummary
                    roleBreakdown
                    assessmentCard
                    evidenceBoundary
                }
            }
            .padding(.bottom, MonitorTheme.Spacing.compact)
        }
        .scrollIndicators(.hidden)
        .onChange(of: viewModel.assessment?.generatedAt) { _, generatedAt in
            guard generatedAt != nil, viewModel.manualState == .success, let assessment = viewModel.assessment else { return }
            onOpenAssessmentReport(assessment)
        }
    }

    private var sourceStrip: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("state_*.sqlite · 每点为最近7日滚动快照")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(MonitorTheme.textSecondary)
                Text(sourceStatusText)
                    .font(.system(size: 8.5))
                    .foregroundStyle(MonitorTheme.textSecondary)
            }
            Spacer()
            Text(viewModel.dailyState.label)
                .font(.system(size: 8.5, weight: .bold, design: .rounded))
                .foregroundStyle(statusColor)
                .padding(5)
                .background(MonitorTheme.sectionFill, in: Capsule())
        }
        .padding(.horizontal, MonitorTheme.Spacing.row)
        .frame(height: 42)
        .background(MonitorTheme.rowFill, in: RoundedRectangle(cornerRadius: MonitorTheme.Radius.row, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("路由监测来源与自动状态")
        .accessibilityValue("只读最新版本 state SQLite。\(sourceStatusText)。\(viewModel.dailyState.label)")
    }

    private var periodPicker: some View {
        HStack {
            Text("快照范围")
                .font(.system(size: 10.5, weight: .semibold))
            Spacer()
            Picker("路由快照历史范围", selection: $days) {
                Text("7天").tag(7)
                Text("30天").tag(30)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 160)
        }
        .padding(.horizontal, MonitorTheme.Spacing.row)
        .frame(height: 36)
        .background(MonitorTheme.controlFill, in: RoundedRectangle(cornerRadius: MonitorTheme.Radius.row, style: .continuous))
    }

    private var routingGuidanceCard: some View {
        VStack(alignment: .leading, spacing: MonitorTheme.Spacing.inline) {
            VStack(alignment: .leading, spacing: 1) {
                Text("多代理路由强度")
                    .font(.system(size: 11.5, weight: .semibold))
                Text("每日新增 Token：严格归因子任务 ÷（对应根任务＋子任务）")
                    .font(.system(size: 8.5))
                    .foregroundStyle(MonitorTheme.textSecondary)
            }

            HStack(spacing: 0) {
                routingGuidanceMetric(
                    label: "全部路由",
                    share: routingGuidance.weightedShare,
                    validDays: routingGuidance.validDays,
                    stateLabel: routingGuidanceStateLabel,
                    color: routingGuidanceColor
                )
                Rectangle()
                    .fill(MonitorTheme.separator)
                    .frame(width: MonitorTheme.Stroke.hairline, height: 42)
                    .padding(.horizontal, MonitorTheme.Spacing.row)
                    .accessibilityHidden(true)
                routingGuidanceMetric(
                    label: "Ultra",
                    share: ultraGuidance.weightedShare,
                    validDays: ultraGuidance.validDays,
                    stateLabel: ultraGuidanceStateLabel,
                    color: ultraGuidanceColor
                )
            }

            RoutingGuidanceBand(routingShare: routingGuidance.weightedShare, ultraShare: ultraGuidance.weightedShare)

            VStack(alignment: .leading, spacing: 2) {
                Text("全部：\(routingGuidanceDetail)")
                Text("Ultra：\(ultraGuidanceDetail)")
            }
            .font(.system(size: 8.5, weight: .medium))
            .foregroundStyle(MonitorTheme.textSecondary)

            if let metric = latest {
                Text("累计参考  全部 \(metric.routingIntensityTokenShare.map(percent) ?? "--")  ·  Ultra \(metric.ultraRoutingTokenShare.map(percent) ?? "--")  ·  整体 \(percent(metric.childTokenShare))  ·  根覆盖 \(metric.rootDispatchCoverage.map(percent) ?? "--")")
                    .font(.system(size: 8.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(MonitorTheme.textTertiary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                parentSourceSummary(metric)
            }

            Text("20–35% 是本机运营指导带，不是官方健康标准；累计值仅作参考，不参与判定。")
                .font(.system(size: 7.5))
                .foregroundStyle(MonitorTheme.textSecondary)
        }
        .padding(MonitorTheme.Spacing.row)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(MonitorTheme.sectionFill, in: RoundedRectangle(cornerRadius: MonitorTheme.Radius.section, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: MonitorTheme.Radius.section, style: .continuous)
                .stroke(MonitorTheme.routingCardHairline, lineWidth: MonitorTheme.Stroke.hairline)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("多代理路由强度")
        .accessibilityValue(routingGuidanceAccessibilityValue)
    }

    private func routingGuidanceMetric(
        label: String,
        share: Double?,
        validDays: Int,
        stateLabel: String,
        color: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: MonitorTheme.Spacing.compact) {
                Circle()
                    .fill(color)
                    .frame(width: 5, height: 5)
                    .accessibilityHidden(true)
                Text(label)
                    .font(.system(size: 8.5, weight: .semibold))
                    .foregroundStyle(MonitorTheme.textSecondary)
                Spacer(minLength: MonitorTheme.Spacing.compact)
                Text(stateLabel)
                    .font(.system(size: 7.5, weight: .bold, design: .rounded))
                    .foregroundStyle(color)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            Text(share.map(percent) ?? "--")
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundStyle(share == nil ? MonitorTheme.textSecondary : MonitorTheme.textPrimary)
                .monospacedDigit()
            Text(validDays > 0 ? "\(validDays) 个完整日 · Token 加权" : "等待完整日观测")
                .font(.system(size: 8))
                .foregroundStyle(MonitorTheme.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var moreDataButton: some View {
        Button {
            showMoreData.toggle()
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text("更多数据与报告")
                        .font(.system(size: 10.5, weight: .semibold))
                    Text("角色分布 · 诊断口径 · 手动评估")
                        .font(.system(size: 8))
                        .foregroundStyle(MonitorTheme.textTertiary)
                }
                Spacer()
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .rotationEffect(.degrees(showMoreData ? 180 : 0))
            }
            .foregroundStyle(MonitorTheme.textSecondary)
            .padding(.horizontal, MonitorTheme.Spacing.row)
            .frame(height: 42)
            .background(MonitorTheme.controlFill, in: RoundedRectangle(cornerRadius: MonitorTheme.Radius.row, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("更多数据与报告")
        .accessibilityValue(showMoreData ? "已展开" : "已折叠")
        .accessibilityHint("显示或隐藏角色分布、诊断口径和手动评估")
    }

    private var latestSummary: some View {
        VStack(alignment: .leading, spacing: MonitorTheme.Spacing.inline) {
            Text("最新快照")
                .font(.system(size: 11, weight: .semibold))
            if let metric = latest {
                HStack(spacing: 0) {
                    RoutingSnapshotStat(
                        label: "路由内累计参考",
                        value: metric.routingIntensityTokenShare.map(percent) ?? "--",
                        detail: "仅严格归因路由工作"
                    )
                    snapshotDivider
                    RoutingSnapshotStat(
                        label: "整体累计参考",
                        value: percent(metric.childTokenShare),
                        detail: "全部子任务 ÷ 全部任务"
                    )
                }
                HStack {
                    Text("子任务 \(metric.childThreads)/\(metric.sourceThreads)")
                    Spacer()
                    Text("全部新增 \(HUDTokenFormatter.compact(metric.tokenDelta))")
                    Spacer()
                    Text("身份 \(metric.roleMetadataCovered)/\(metric.childThreads)")
                }
                .font(.system(size: 8.5, weight: .medium, design: .rounded))
                .foregroundStyle(MonitorTheme.textSecondary)
                .monospacedDigit()
                Text("路由内累计＝严格归因子任务÷（已分发根＋严格归因子任务）；整体累计＝全部子任务÷全部任务。")
                    .font(.system(size: 8))
                    .foregroundStyle(MonitorTheme.textTertiary)
                Text(rootCoverageSummary(metric))
                    .font(.system(size: 8.5, weight: .medium, design: .rounded))
                    .foregroundStyle(MonitorTheme.textSecondary)
                    .monospacedDigit()
                parentSourceSummary(metric, includesTokenBurden: true)
                Text("二级以上 \(metric.depthAtLeastTwo) · 孤儿关系 \(metric.orphanEdges) · 循环影响 \(metric.cycleAffectedChildren) · 匿名 Sol \(metric.anonymousSolChildren) · 时长代理 \(duration(metric.createdToUpdatedMedianMilliseconds))")
                    .font(.system(size: 9))
                    .foregroundStyle(MonitorTheme.textTertiary)
            } else {
                Text("暂无已发布快照；打开页面不会触发扫描。")
                    .font(.system(size: 9.5))
                    .foregroundStyle(MonitorTheme.textTertiary)
            }
        }
        .padding(MonitorTheme.Spacing.row)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(MonitorTheme.sectionFill, in: RoundedRectangle(cornerRadius: MonitorTheme.Radius.section, style: .continuous))
    }

    private var snapshotDivider: some View {
        Rectangle()
            .fill(MonitorTheme.separator)
            .frame(width: MonitorTheme.Stroke.hairline, height: 32)
            .padding(.horizontal, MonitorTheme.Spacing.compact)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private func parentSourceSummary(_ metric: RoutingDailyMetric, includesTokenBurden: Bool = false) -> some View {
        if let partition = metric.routingTokenPartition, !partition.parentSourceBuckets.isEmpty {
            let rootGroups = Dictionary(grouping: partition.parentSourceBuckets, by: { sourceEffortLabel($0.effort) })
                .mapValues { $0.reduce(0) { saturatedViewTokens($0, $1.rootThreads) } }
            let rankedRoots = rootGroups.filter { $0.key != "其他" }.sorted {
                $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value
            }
            let shownRoots = Array(rankedRoots.prefix(4))
            let remainingRoots = rankedRoots.dropFirst(4).reduce(rootGroups["其他"] ?? 0) { saturatedViewTokens($0, $1.value) }
            let childTokenGroups = Dictionary(grouping: partition.parentSourceBuckets, by: { sourceEffortLabel($0.effort) })
                .mapValues { $0.reduce(0) { saturatedViewTokens($0, $1.attributedChildCumulativeTokens) } }
            let rankedChildTokens = childTokenGroups.filter { $0.key != "其他" }.sorted {
                $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value
            }
            let shownChildTokens = Array(rankedChildTokens.prefix(4))
            let remainingChildTokens = rankedChildTokens.dropFirst(4).reduce(childTokenGroups["其他"] ?? 0) { saturatedViewTokens($0, $1.value) }
            let totalChildTokens = max(0, partition.attributedChildCumulativeTokens)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: MonitorTheme.Spacing.compact) {
                    Text("发起根任务")
                        .foregroundStyle(MonitorTheme.textTertiary)
                    ForEach(shownRoots, id: \.key) { item in
                        Text("\(item.key) \(item.value)")
                    }
                    if remainingRoots > 0 {
                        Text("其他 \(remainingRoots)")
                    }
                }
                if includesTokenBurden {
                    HStack(spacing: MonitorTheme.Spacing.compact) {
                        Text("子任务 Token")
                            .foregroundStyle(MonitorTheme.textTertiary)
                        ForEach(shownChildTokens, id: \.key) { item in
                            Text("\(item.key) \(sourceShare(item.value, total: totalChildTokens))")
                        }
                        if remainingChildTokens > 0 {
                            Text("其他 \(sourceShare(remainingChildTokens, total: totalChildTokens))")
                        }
                    }
                }
            }
            .font(.system(size: 8, weight: .medium, design: .rounded))
            .foregroundStyle(MonitorTheme.textSecondary)
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("路由来源")
            .accessibilityValue(parentSourceAccessibilityValue(rootGroups: rootGroups, childTokenGroups: childTokenGroups, totalChildTokens: totalChildTokens, includesTokenBurden: includesTokenBurden))
        } else {
            Text("路由来源：旧快照无通用父根桶")
                .font(.system(size: 8))
                .foregroundStyle(MonitorTheme.textTertiary)
        }
    }

    private func sourceEffortLabel(_ effort: RoutingEffortBucket) -> String {
        switch effort {
        case .ultra: "Ultra"
        case .max: "Max"
        case .high, .xhigh: "High"
        case .medium: "Medium"
        case .none, .low, .unknown: "其他"
        }
    }

    private func rootCoverageSummary(_ metric: RoutingDailyMetric) -> String {
        guard let partition = metric.routingTokenPartition else {
            return "根任务分发覆盖 --（旧快照无通用父根分区）"
        }
        return "根任务分发覆盖 \(partition.routedRootThreads)/\(partition.windowRootThreads) · \(partition.routedRootCoverage.map(percent) ?? "--")"
    }

    private func saturatedViewTokens(_ lhs: Int, _ rhs: Int) -> Int {
        let (value, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? Int.max : value
    }

    private func sourceShare(_ value: Int, total: Int) -> String {
        guard total > 0, value > 0 else { return "0%" }
        let share = Double(value) / Double(total)
        return share < 0.001 ? "<0.1%" : percent(share)
    }

    private func rootSourceAccessibility(_ partition: RoutingTokenPartition) -> String {
        let grouped = Dictionary(grouping: partition.parentSourceBuckets, by: { sourceEffortLabel($0.effort) })
            .mapValues { $0.reduce(0) { saturatedViewTokens($0, $1.rootThreads) } }
        let sorted = grouped.sorted { lhs, rhs in
            lhs.value == rhs.value ? lhs.key < rhs.key : lhs.value > rhs.value
        }
        var parts: [String] = []
        for item in sorted {
            parts.append("\(item.key) \(item.value) 个")
        }
        return parts.joined(separator: "，")
    }

    private func parentSourceAccessibilityValue(
        rootGroups: [String: Int],
        childTokenGroups: [String: Int],
        totalChildTokens: Int,
        includesTokenBurden: Bool
    ) -> String {
        let sortedRoots = rootGroups.sorted { lhs, rhs in
            lhs.value == rhs.value ? lhs.key < rhs.key : lhs.value > rhs.value
        }
        var rootParts: [String] = []
        for item in sortedRoots {
            rootParts.append("\(item.key) \(item.value) 个根任务")
        }
        guard includesTokenBurden else { return rootParts.joined(separator: "，") }

        let sortedTokens = childTokenGroups.sorted { lhs, rhs in
            lhs.value == rhs.value ? lhs.key < rhs.key : lhs.value > rhs.value
        }
        var tokenParts: [String] = []
        for item in sortedTokens {
            tokenParts.append("\(item.key) \(sourceShare(item.value, total: totalChildTokens))")
        }
        return rootParts.joined(separator: "，") + "；子任务 Token：" + tokenParts.joined(separator: "，")
    }

    private var roleBreakdown: some View {
        VStack(alignment: .leading, spacing: MonitorTheme.Spacing.inline) {
            HStack {
                Text("子角色分布")
                    .font(.system(size: 11, weight: .semibold))
                Spacer()
                if let latest, let buckets = latest.roleBuckets {
                    Text(roleBreakdownStatus(metric: latest, buckets: buckets))
                        .font(.system(size: 8, weight: .semibold, design: .rounded))
                        .foregroundStyle(roleBreakdownStatusColor(metric: latest, buckets: buckets))
                }
            }
            if let metric = latest {
                if let buckets = metric.roleBuckets {
                    Text(roleBreakdownSummary(metric: metric, buckets: buckets))
                        .font(.system(size: 8.5))
                        .foregroundStyle(MonitorTheme.textTertiary)
                    HStack(spacing: MonitorTheme.Spacing.section) {
                        roleTokenSummary(label: "累计 Token", value: metric.childCumulativeTokens)
                        roleTokenSummary(label: "相邻新增 Token", value: metric.childTokenDelta)
                    }
                    VStack(spacing: 2) {
                        ForEach(buckets) { bucket in
                            RoutingRoleBreakdownRow(bucket: bucket, childTokenTotal: metric.childCumulativeTokens)
                        }
                    }
                } else {
                    Text("旧快照无角色细分。完成下一次轻量扫描后显示新的聚合明细。")
                        .font(.system(size: 9))
                        .foregroundStyle(MonitorTheme.textTertiary)
                        .accessibilityLabel("旧快照无角色细分")
                }
            } else {
                Text("暂无快照；角色明细会在首次轻量扫描后发布。")
                    .font(.system(size: 9))
                    .foregroundStyle(MonitorTheme.textTertiary)
                    .accessibilityLabel("暂无角色明细")
            }
        }
        .padding(MonitorTheme.Spacing.row)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(MonitorTheme.sectionFill, in: RoundedRectangle(cornerRadius: MonitorTheme.Radius.section, style: .continuous))
        .accessibilityElement(children: .contain)
    }

    private func roleBreakdownSummary(metric: RoutingDailyMetric, buckets: [RoutingRoleBucket]) -> String {
        let active = buckets.filter { $0.isActive && $0.childThreads > 0 }.count
        let retired = buckets.filter { $0.isRetired && $0.childThreads > 0 }.count
        let attributed = buckets.filter { !$0.isUnknown }.reduce(0) { $0 + $1.childThreads }
        let history = retired > 0 ? " · 历史角色 \(retired) 类" : ""
        return "已使用 \(active)/\(RoutingRegisteredRole.activeCases.count) 个当前角色 · \(attributed)/\(metric.childThreads) 个子任务已归因\(history)"
    }

    private func roleTokenSummary(label: String, value: Int) -> some View {
        HStack(spacing: MonitorTheme.Spacing.compact) {
            Text(label)
                .foregroundStyle(MonitorTheme.textTertiary)
            Text(HUDTokenFormatter.compact(value))
                .fontWeight(.semibold)
                .foregroundStyle(MonitorTheme.textSecondary)
        }
        .font(.system(size: 8.5, design: .rounded))
    }

    private func roleBreakdownStatus(metric: RoutingDailyMetric, buckets: [RoutingRoleBucket]) -> String {
        let unknown = buckets.first(where: \.isUnknown)?.childThreads ?? 0
        let identityDrift = buckets.contains {
            guard $0.isActive, let matched = $0.identityMatchedThreads else { return false }
            return matched != $0.childThreads
        }
        return metric.roleMetadataMissing > 0 || unknown > 0 || identityDrift ? "PARTIAL" : "COMPLETE"
    }

    private func roleBreakdownStatusColor(metric: RoutingDailyMetric, buckets: [RoutingRoleBucket]) -> Color {
        roleBreakdownStatus(metric: metric, buckets: buckets) == "COMPLETE" ? MonitorTheme.healthy : MonitorTheme.warning
    }

    private var trend: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("路由强度新增趋势")
                    .font(.system(size: 10.5, weight: .semibold))
                Spacer()
                Text("建议带 20–35%")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(MonitorTheme.routingGuidance)
            }
            HStack(spacing: MonitorTheme.Spacing.row) {
                routingTrendLegend(label: "全部路由", color: MonitorTheme.routingTrend, isDiamond: false)
                routingTrendLegend(label: "Ultra", color: MonitorTheme.routingUltraTrend, isDiamond: true)
            }
            if !hasDailyObservation {
                Text("等待完整日观测；不会从累计值伪造历史。")
                    .font(.system(size: 9))
                    .foregroundStyle(MonitorTheme.textTertiary)
            } else {
                RoutingTrendChart(points: points)
            }
        }
        .padding(MonitorTheme.Spacing.row)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(MonitorTheme.sectionFill, in: RoundedRectangle(cornerRadius: MonitorTheme.Radius.section, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: MonitorTheme.Radius.section, style: .continuous)
                .stroke(MonitorTheme.routingCardHairline, lineWidth: MonitorTheme.Stroke.hairline)
        }
    }

    private func routingTrendLegend(label: String, color: Color, isDiamond: Bool) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: isDiamond ? 1 : 3, style: .continuous)
                .fill(color)
                .frame(width: 6, height: 6)
                .rotationEffect(.degrees(isDiamond ? 45 : 0))
            Text(label)
                .font(.system(size: 7.5, weight: .medium))
                .foregroundStyle(MonitorTheme.textSecondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label)趋势")
    }

    private var assessmentCard: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("手动深度评估")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Text(manualLabel)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(manualColor)
            }
            Text("仅 state SQLite 与父子边；不读取 JSONL、联网或调用模型。范围 \(days) 天。")
                .font(.system(size: 9.5))
                .foregroundStyle(MonitorTheme.textTertiary)
            Button(viewModel.manualState == .assessing ? "取消" : "生成并查看 \(days) 天报告") {
                if viewModel.manualState == .assessing {
                    viewModel.cancelAssessment()
                } else {
                    viewModel.assess(days: days)
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .accessibilityIdentifier("routing-depth-assessment")
            .accessibilityLabel(viewModel.manualState == .assessing ? "取消路由深度评估" : "生成并查看路由评估报告")
            .accessibilityHint("评估与轻量扫描串行执行")
            if let assessment = viewModel.assessment {
                HStack {
                    Text("上次 \(Formatters.relativeAge(assessment.generatedAt))前 · \(assessment.periodDays) 天 · 子任务 \(assessment.metrics.childThreads)/\(assessment.metrics.sourceThreads)")
                        .font(.system(size: 9))
                        .foregroundStyle(MonitorTheme.textSecondary)
                    Spacer()
                    Button("查看上次报告") { onOpenAssessmentReport(assessment) }
                        .buttonStyle(.borderless)
                        .font(.system(size: 9))
                        .accessibilityLabel("查看上次路由评估报告")
                }
            }
            if viewModel.manualState == .failed {
                Text("评估失败：无法从本机 state SQLite 生成报告；请确认数据源后重试。")
                    .font(.system(size: 9))
                    .foregroundStyle(MonitorTheme.warning)
                    .accessibilityLabel("评估失败，无法从本机 state SQLite 生成报告")
            }
        }
        .padding(MonitorTheme.Spacing.row)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(MonitorTheme.sectionFill, in: RoundedRectangle(cornerRadius: MonitorTheme.Radius.section, style: .continuous))
    }

    private var evidenceBoundary: some View {
        Text("Verified success rate、Token per verified success、真实 E2E speedup 均为 UNVERIFIED：state SQLite 没有任务结果或真实起止证据。")
            .font(.system(size: 8.5))
            .foregroundStyle(MonitorTheme.textSecondary)
            .accessibilityLabel("证据边界")
            .accessibilityValue("成功率、每成功任务 Token 和真实端到端加速均未验证")
    }

    private var sourceStatusText: String {
        guard let lastUpdated = viewModel.snapshot.lastUpdated else {
            return viewModel.snapshot.automaticStatus
        }
        return "\(viewModel.snapshot.automaticStatus) · \(Formatters.relativeAge(lastUpdated))前更新"
    }

    private var statusColor: Color {
        switch viewModel.dailyState {
        case .ready:
            MonitorTheme.healthy
        case .partial, .stale, .loading:
            MonitorTheme.warning
        case .empty, .unavailable:
            MonitorTheme.textTertiary
        }
    }

    private var routingGuidanceStateLabel: String {
        switch routingGuidance.state {
        case .unavailable: "暂无完整日观测"
        case .observing: "观测中"
        case .low: "低于指导带"
        case .balanced: "在指导带内"
        case .elevated: "高于指导带"
        case .excessive: "显著高于指导带"
        }
    }

    private var routingGuidanceDetail: String {
        switch routingGuidance.state {
        case .unavailable:
            "等待完整日观测；不会用累计值代替新增占比。"
        case .observing:
            "已有 \(routingGuidance.validDays)/\(RoutingDeltaGuidance.minimumValidDays) 个完整日；继续积累后再判定。"
        case .low:
            "低于 20%；可能分发不足，先核对任务是否具备可并行切片。"
        case .balanced:
            "处于 20–35% 指导带；继续结合完成质量与耗时观察。"
        case .elevated:
            "高于 35%；复核重复探索、无效并发和过细任务切分。"
        case .excessive:
            "高于 50%；子任务新增 Token 已超过已分发根任务，优先复核。"
        }
    }

    private var ultraGuidanceStateLabel: String {
        switch ultraGuidance.state {
        case .unavailable: "暂无完整日观测"
        case .observing: "观测中"
        case .low: "低于指导带"
        case .balanced: "在指导带内"
        case .elevated: "高于指导带"
        case .excessive: "显著高于指导带"
        }
    }

    private var ultraGuidanceDetail: String {
        switch ultraGuidance.state {
        case .unavailable:
            "旧快照无完整 Ultra 日；不从累计值伪回填。"
        case .observing:
            "已有 \(ultraGuidance.validDays)/\(RoutingUltraDeltaGuidance.minimumValidDays) 个完整 Ultra 日；继续积累后再判定。"
        case .low:
            "低于 20%；Ultra 根内分发可能偏少。"
        case .balanced:
            "处于 20–35% 指导带。"
        case .elevated:
            "高于 35%；复核 Ultra 根下重复探索与过细切分。"
        case .excessive:
            "高于 50%；Ultra 子任务新增已超过 Ultra 根新增。"
        }
    }

    private var routingGuidanceAccessibilityValue: String {
        var details: [String] = []
        if let share = routingGuidance.weightedShare {
            details.append("全部路由 \(percent(share))，\(routingGuidanceStateLabel)，\(routingGuidance.validDays) 个完整日。\(routingGuidanceDetail)")
        } else {
            details.append("全部路由不可用。\(routingGuidanceDetail)")
        }
        if let share = ultraGuidance.weightedShare {
            details.append("Ultra \(percent(share))，\(ultraGuidanceStateLabel)，\(ultraGuidance.validDays) 个完整日。\(ultraGuidanceDetail)")
        } else {
            details.append("Ultra 不可用。\(ultraGuidanceDetail)")
        }
        if let metric = latest {
            details.append("累计参考：全部路由 \(metric.routingIntensityTokenShare.map(percent) ?? "不可用")，Ultra \(metric.ultraRoutingTokenShare.map(percent) ?? "不可用")，整体占用 \(percent(metric.childTokenShare))")
            if let partition = metric.routingTokenPartition {
                details.append("根任务分发覆盖 \(partition.routedRootThreads) 比 \(partition.windowRootThreads)，\(partition.routedRootCoverage.map(percent) ?? "不可用")")
                details.append("发起根任务：\(rootSourceAccessibility(partition))")
            }
        }
        return details.joined(separator: "；")
    }

    private var routingGuidanceColor: Color {
        switch routingGuidance.state {
        case .balanced:
            MonitorTheme.healthy
        case .low, .elevated:
            MonitorTheme.warning
        case .excessive:
            MonitorTheme.critical
        case .observing:
            MonitorTheme.radarBaseline
        case .unavailable:
            MonitorTheme.textTertiary
        }
    }

    private var ultraGuidanceColor: Color {
        switch ultraGuidance.state {
        case .balanced:
            MonitorTheme.healthy
        case .low, .elevated:
            MonitorTheme.warning
        case .excessive:
            MonitorTheme.critical
        case .observing:
            MonitorTheme.routingUltraTrend
        case .unavailable:
            MonitorTheme.textTertiary
        }
    }

    private var manualLabel: String {
        switch viewModel.manualState {
        case .idle: "待评估"
        case .assessing: "评估中"
        case .success: "已完成"
        case .cancelled: "已取消"
        case .failed: "失败"
        }
    }

    private var manualColor: Color {
        switch viewModel.manualState {
        case .success:
            MonitorTheme.healthy
        case .failed:
            MonitorTheme.critical
        case .assessing, .cancelled:
            MonitorTheme.warning
        case .idle:
            MonitorTheme.textTertiary
        }
    }

    private func percent(_ value: Double) -> String {
        String(format: "%.1f%%", max(0, value) * 100)
    }

    private func duration(_ milliseconds: Int64) -> String {
        if milliseconds < 1_000 {
            return "\(milliseconds)ms"
        }
        return "\(milliseconds / 1_000)s"
    }
}

private struct RoutingGuidanceBand: View {
    let routingShare: Double?
    let ultraShare: Double?

    var body: some View {
        VStack(spacing: 3) {
            GeometryReader { geometry in
                let width = geometry.size.width
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(MonitorTheme.progressTrack)
                    Capsule()
                        .fill(MonitorTheme.routingGuidanceBandFill)
                        .frame(width: width * (RoutingDeltaGuidance.upperBound - RoutingDeltaGuidance.lowerBound))
                        .overlay {
                            Capsule()
                                .stroke(
                                    MonitorTheme.routingGuidanceBoundary,
                                    style: StrokeStyle(lineWidth: MonitorTheme.Stroke.hairline, dash: [2, 2])
                                )
                        }
                        .offset(x: width * RoutingDeltaGuidance.lowerBound)
                    if let routingShare {
                        Circle()
                            .fill(MonitorTheme.routingTrend)
                            .frame(width: 7, height: 7)
                            .overlay(Circle().stroke(MonitorTheme.sectionFill, lineWidth: 1))
                            .offset(x: max(0, min(width - 7, width * min(1, max(0, routingShare)) - 3.5)))
                    }
                    if let ultraShare {
                        RoundedRectangle(cornerRadius: 1, style: .continuous)
                            .fill(MonitorTheme.routingUltraTrend)
                            .frame(width: 6, height: 6)
                            .overlay {
                                RoundedRectangle(cornerRadius: 1, style: .continuous)
                                    .stroke(MonitorTheme.sectionFill, lineWidth: 1)
                            }
                            .rotationEffect(.degrees(45))
                            .offset(x: max(0, min(width - 6, width * min(1, max(0, ultraShare)) - 3)))
                    }
                }
            }
            .frame(height: 7)

            HStack {
                Text("0%")
                Spacer()
                Text("20–35% 建议")
                    .foregroundStyle(MonitorTheme.routingGuidance)
                Spacer()
                Text("100%")
            }
            .font(.system(size: 7.5, weight: .medium, design: .rounded))
            .foregroundStyle(MonitorTheme.textTertiary)
        }
        .accessibilityHidden(true)
    }
}

private struct RoutingRoleBreakdownRow: View {
    let bucket: RoutingRoleBucket
    let childTokenTotal: Int

    private var share: Double {
        childTokenTotal > 0 ? Double(bucket.cumulativeTokens) / Double(childTokenTotal) : 0
    }

    private var accentColor: Color {
        switch bucket.role?.accent {
        case .luna: MonitorTheme.radarBaseline
        case .terra: MonitorTheme.healthy
        case .sol: MonitorTheme.warning
        case nil: MonitorTheme.neutral
        }
    }

    private var tierBadgeLabel: String {
        bucket.isRetired ? "历史" : bucket.tierLabel
    }

    private var detailLabel: String {
        guard let role = bucket.role else { return "当前与历史目录均未注册" }
        if bucket.identityCompleteThreads < bucket.childThreads {
            return "元数据 \(bucket.identityCompleteThreads)/\(bucket.childThreads)"
        }
        if role.isRetired {
            return "\(role.rawValue) · \(role.tierLabel)"
        }
        if let matched = bucket.identityMatchedThreads, matched < bucket.childThreads {
            return "身份匹配 \(matched)/\(bucket.childThreads)"
        }
        return role.rawValue
    }

    private var hasIdentityIssue: Bool {
        bucket.identityCompleteThreads < bucket.childThreads
            || (bucket.isActive && bucket.identityMatchedThreads.map { $0 < bucket.childThreads } == true)
            || bucket.isUnknown
    }

    private var accessibilityIdentity: String {
        guard let role = bucket.role else { return "当前与历史目录均未注册" }
        if bucket.identityCompleteThreads < bucket.childThreads {
            return "元数据完整 \(bucket.identityCompleteThreads) / \(bucket.childThreads)"
        }
        if role.isRetired { return "历史角色" }
        return "身份匹配 \(bucket.identityMatchedThreads.map(String.init) ?? "不可验证") / \(bucket.childThreads)"
    }

    var body: some View {
        VStack(spacing: MonitorTheme.Spacing.micro) {
            HStack(spacing: MonitorTheme.Spacing.compact) {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text(bucket.displayName)
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(MonitorTheme.textPrimary)
                        Text(tierBadgeLabel)
                            .font(.system(size: 7.5, weight: .medium, design: .rounded))
                            .foregroundStyle(MonitorTheme.textSecondary)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(MonitorTheme.controlFill, in: Capsule())
                    }
                    Text(detailLabel)
                        .font(.system(size: 8.5, design: .monospaced))
                        .foregroundStyle(hasIdentityIssue ? MonitorTheme.warning : MonitorTheme.textTertiary)
                }
                Spacer(minLength: MonitorTheme.Spacing.compact)
                VStack(alignment: .trailing, spacing: 1) {
                    Text("\(bucket.childThreads) 个子任务 · 子任务内 \(String(format: "%.1f%%", max(0, share) * 100))")
                        .font(.system(size: 9, weight: .semibold, design: .rounded))
                        .foregroundStyle(MonitorTheme.textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                    Text("累计 \(HUDTokenFormatter.compact(bucket.cumulativeTokens)) · 相邻新增 +\(HUDTokenFormatter.compact(bucket.tokenDelta))")
                        .font(.system(size: 8.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(MonitorTheme.textTertiary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(MonitorTheme.progressTrack)
                    Capsule()
                        .fill(accentColor)
                        .frame(width: max(0, geometry.size.width * min(1, max(0, share))))
                }
            }
            .frame(height: 2)
        }
        .padding(.vertical, MonitorTheme.Spacing.micro)
        .opacity(bucket.childThreads == 0 ? 0.58 : 1)
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("routing-role-\(bucket.id)")
        .accessibilityLabel("\(bucket.displayName)，\(tierBadgeLabel)")
        .accessibilityValue("子任务 \(bucket.childThreads)，\(accessibilityIdentity)，累计 Token \(bucket.cumulativeTokens)，相邻观测新增 \(bucket.tokenDelta)，占子任务 Token \(String(format: "%.1f", max(0, share) * 100))%")
    }
}

private struct RoutingSnapshotStat: View {
    let label: String
    let value: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.system(size: 8))
                .foregroundStyle(MonitorTheme.textTertiary)
            Text(value)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(MonitorTheme.textPrimary)
                .monospacedDigit()
            Text(detail)
                .font(.system(size: 8))
                .foregroundStyle(MonitorTheme.textTertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue("\(value)，\(detail)")
    }
}

private struct RoutingTrendChart: View {
    let points: [RoutingDailyMetric]

    @State private var hoveredIndex: Int?
    @State private var keyboardIndex: Int?

    private var routingPoints: [(index: Int, metric: RoutingDailyMetric, share: Double, segment: Int)] {
        var result: [(index: Int, metric: RoutingDailyMetric, share: Double, segment: Int)] = []
        var segment = 0
        var previousIndex: Int?
        for (index, metric) in points.enumerated() {
            guard let share = metric.routingDailyObservedTokenShare else {
                previousIndex = nil
                continue
            }
            if previousIndex == nil {
                segment += 1
            }
            result.append((index, metric, share, segment))
            previousIndex = index
        }
        return result
    }

    private var ultraPoints: [(index: Int, metric: RoutingDailyMetric, share: Double, segment: Int)] {
        var result: [(index: Int, metric: RoutingDailyMetric, share: Double, segment: Int)] = []
        var segment = 0
        var previousIndex: Int?
        for (index, metric) in points.enumerated() {
            guard let share = metric.ultraRoutingDailyObservedTokenShare else {
                previousIndex = nil
                continue
            }
            if previousIndex == nil {
                segment += 1
            }
            result.append((index, metric, share, segment))
            previousIndex = index
        }
        return result
    }

    private var selectedIndex: Int? {
        hoveredIndex ?? keyboardIndex
    }

    private var activeIndex: Int? {
        selectedIndex ?? points.lastIndex {
            $0.routingDailyObservedTokenShare != nil
                || $0.ultraRoutingDailyObservedTokenShare != nil
        }
    }

    private var selectedPoint: RoutingDailyMetric? {
        guard let index = activeIndex, points.indices.contains(index) else { return nil }
        return points[index]
    }

    private var tooltipAlignment: Alignment {
        guard let activeIndex else { return .topTrailing }
        return activeIndex > points.count / 2 ? .topLeading : .topTrailing
    }

    var body: some View {
        VStack(alignment: .leading, spacing: MonitorTheme.Spacing.inline) {
            ZStack(alignment: tooltipAlignment) {
                Chart {
                    RectangleMark(
                        xStart: .value("开始", 0),
                        xEnd: .value("结束", max(1, points.count - 1)),
                        yStart: .value("建议下限", RoutingDeltaGuidance.lowerBound),
                        yEnd: .value("建议上限", RoutingDeltaGuidance.upperBound)
                    )
                    .foregroundStyle(MonitorTheme.routingGuidanceFill)

                    RuleMark(y: .value("建议下限边界", RoutingDeltaGuidance.lowerBound))
                        .foregroundStyle(MonitorTheme.routingGuidanceBoundary)
                        .lineStyle(StrokeStyle(lineWidth: MonitorTheme.Stroke.hairline, dash: [3, 3]))

                    RuleMark(y: .value("建议上限边界", RoutingDeltaGuidance.upperBound))
                        .foregroundStyle(MonitorTheme.routingGuidanceBoundary)
                        .lineStyle(StrokeStyle(lineWidth: MonitorTheme.Stroke.hairline, dash: [3, 3]))

                    ForEach(Array(routingPoints.enumerated()), id: \.offset) { _, point in
                        LineMark(
                            x: .value("日期", point.index),
                            y: .value("全部路由每日新增 Token 占比", point.share),
                            series: .value("连续证据段", "全部-\(point.segment)")
                        )
                        .interpolationMethod(.linear)
                        .foregroundStyle(MonitorTheme.routingTrend)

                        PointMark(
                            x: .value("日期", point.index),
                            y: .value("全部路由每日新增 Token 占比", point.share)
                        )
                        .symbolSize(20)
                        .foregroundStyle(MonitorTheme.routingTrendPoint)
                    }

                    ForEach(Array(ultraPoints.enumerated()), id: \.offset) { _, point in
                        LineMark(
                            x: .value("日期", point.index),
                            y: .value("Ultra 每日新增 Token 占比", point.share),
                            series: .value("连续证据段", "Ultra-\(point.segment)")
                        )
                        .interpolationMethod(.linear)
                        .foregroundStyle(MonitorTheme.routingUltraTrend)

                        PointMark(
                            x: .value("日期", point.index),
                            y: .value("Ultra 每日新增 Token 占比", point.share)
                        )
                        .symbol(.diamond)
                        .symbolSize(26)
                        .foregroundStyle(MonitorTheme.routingUltraTrendPoint)
                    }

                    if let selectedIndex {
                        RuleMark(x: .value("选择日期", selectedIndex))
                            .foregroundStyle(MonitorTheme.textSecondary.opacity(0.55))
                            .lineStyle(StrokeStyle(lineWidth: MonitorTheme.Stroke.hairline, dash: [3, 3]))
                    }
                }
                .chartLegend(.hidden)
                .chartXScale(domain: 0...max(1, points.count - 1))
                .chartXAxis {
                    AxisMarks(values: axisIndices) { value in
                        AxisGridLine().foregroundStyle(MonitorTheme.separator.opacity(0.45))
                        AxisValueLabel {
                            if let index = value.as(Int.self), points.indices.contains(index) {
                                Text(String(points[index].dayKey.suffix(5)))
                                    .font(.system(size: 8))
                                    .foregroundStyle(MonitorTheme.textTertiary)
                            }
                        }
                    }
                }
                .chartYScale(domain: 0.0...1.0)
                .chartYAxis {
                    AxisMarks(position: .leading, values: [0.0, 0.2, 0.35, 1.0]) { value in
                        AxisGridLine().foregroundStyle(MonitorTheme.separator.opacity(0.45))
                        AxisValueLabel {
                            if let ratio = value.as(Double.self) {
                                Text("\(Int(ratio * 100))%")
                                    .font(.system(size: 8))
                                    .foregroundStyle(MonitorTheme.textTertiary)
                            }
                        }
                    }
                }
                .chartOverlay { proxy in
                    GeometryReader { geometry in
                        Rectangle()
                            .fill(.clear)
                            .contentShape(Rectangle())
                            .onContinuousHover { phase in
                                updateHover(phase, proxy: proxy, geometry: geometry)
                            }
                    }
                }
                .frame(height: 118)

                if let selectedPoint {
                    RoutingTrendTooltip(metric: selectedPoint)
                        .padding(MonitorTheme.Spacing.compact)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .focusable()
            .onKeyPress(.leftArrow) {
                moveKeyboardSelection(by: -1)
                return .handled
            }
            .onKeyPress(.rightArrow) {
                moveKeyboardSelection(by: 1)
                return .handled
            }
            .accessibilityElement(children: .ignore)
            .accessibilityIdentifier("routing-snapshot-trend")
            .accessibilityLabel("全部路由与 Ultra 严格新增 Token 占比趋势")
            .accessibilityValue(accessibilityValueText)
            .accessibilityHint("蓝色为全部路由，琥珀色为 Ultra，绿色区域为百分之二十至三十五的本地指导带。获得键盘焦点后，使用左右方向键选择快照")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment:
                    moveKeyboardSelection(by: 1)
                case .decrement:
                    moveKeyboardSelection(by: -1)
                @unknown default:
                    break
                }
            }

            Text("Ultra 历史仅复用已发布聚合点；缺失日期与通用历史不回填。后续两种口径由同一次轻量扫描持续采集。")
                .font(.system(size: 8))
                .foregroundStyle(MonitorTheme.textSecondary)
        }
    }

    private var axisIndices: [Int] {
        guard points.count > 7 else { return Array(points.indices) }
        let stride = max(1, Int(ceil(Double(points.count - 1) / 5)))
        var values = Array(Swift.stride(from: 0, to: points.count, by: stride))
        if values.last != points.count - 1 {
            values.append(points.count - 1)
        }
        return values
    }

    private var accessibilityValueText: String {
        guard let point = selectedPoint else { return "暂无完整日观测" }
        let routingEvidence = point.routingTokenPartition?.dailyDeltaEvidenceComplete == true ? "完整" : "不完整"
        let ultraEvidence = point.ultraTokenPartition?.dailyDeltaEvidenceComplete == true ? "完整" : "不完整"
        return "\(point.dayKey)，全部路由 \(point.routingDailyObservedTokenShare.map(percentage) ?? "--")，证据\(routingEvidence)；Ultra \(point.ultraRoutingDailyObservedTokenShare.map(percentage) ?? "--")，证据\(ultraEvidence)；本地指导带百分之二十至三十五"
    }

    private func percentage(_ value: Double) -> String {
        String(format: "%.1f%%", max(0, value) * 100)
    }

    private func updateHover(_ phase: HoverPhase, proxy: ChartProxy, geometry: GeometryProxy) {
        switch phase {
        case let .active(location):
            guard let plotFrame = proxy.plotFrame else { return }
            let frame = geometry[plotFrame]
            guard frame.contains(location) else {
                hoveredIndex = nil
                return
            }
            let x = location.x - frame.minX
            guard let index = proxy.value(atX: x, as: Int.self) else { return }
            hoveredIndex = min(max(0, index), points.count - 1)
        case .ended:
            hoveredIndex = nil
        }
    }

    private func moveKeyboardSelection(by offset: Int) {
        guard !points.isEmpty else { return }
        let current = keyboardIndex ?? points.count - 1
        self.keyboardIndex = min(max(0, current + offset), points.count - 1)
    }

}

private struct RoutingTrendTooltip: View {
    let metric: RoutingDailyMetric

    var body: some View {
        VStack(alignment: .leading, spacing: MonitorTheme.Spacing.micro) {
            Text(metric.dayKey)
                .fontWeight(.semibold)
                .foregroundStyle(MonitorTheme.textPrimary)
            value("全部路由", metric.routingDailyObservedTokenShare.map(percentage) ?? "--")
            value("Ultra", metric.ultraRoutingDailyObservedTokenShare.map(percentage) ?? "--")
            value("全部 根 / 子", tokenPair(metric.routingTokenPartition?.rootDailyObservedTokenDelta, metric.routingTokenPartition?.attributedChildDailyObservedTokenDelta))
            value("Ultra 根 / 子", tokenPair(metric.ultraTokenPartition?.ultraRootDailyObservedTokenDelta, metric.ultraTokenPartition?.attributedUltraChildDailyObservedTokenDelta))
            value("证据", evidenceText)
            value("累计参考", "全部 \(metric.routingIntensityTokenShare.map(percentage) ?? "--") · U \(metric.ultraRoutingTokenShare.map(percentage) ?? "--")")
            Text("全部使用已分发根；Ultra 使用精确 Ultra 根。")
                .font(.system(size: 7.5))
                .foregroundStyle(MonitorTheme.textTertiary)
        }
        .font(.system(size: 8.5, weight: .medium))
        .foregroundStyle(MonitorTheme.textSecondary)
        .padding(MonitorTheme.Spacing.row)
        .frame(width: 204)
        .background(MonitorTheme.routingTooltipSurface, in: RoundedRectangle(cornerRadius: MonitorTheme.Radius.row, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: MonitorTheme.Radius.row, style: .continuous)
                .stroke(MonitorTheme.routingTooltipStroke, lineWidth: MonitorTheme.Stroke.hairline)
        }
        .shadow(color: .black.opacity(0.24), radius: 8, x: 0, y: 4)
    }

    private func value(_ label: String, _ text: String) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(MonitorTheme.textSecondary)
            Spacer(minLength: MonitorTheme.Spacing.row)
            Text(text)
                .fontWeight(.semibold)
                .foregroundStyle(MonitorTheme.textPrimary)
                .monospacedDigit()
        }
    }

    private func percentage(_ value: Double) -> String {
        String(format: "%.1f%%", max(0, value) * 100)
    }

    private func tokenDelta(_ value: Int?) -> String {
        value.map { "+\(HUDTokenFormatter.compact($0))" } ?? "--"
    }

    private func tokenPair(_ root: Int?, _ child: Int?) -> String {
        "\(tokenDelta(root)) / \(tokenDelta(child))"
    }

    private var evidenceText: String {
        let routing = metric.routingTokenPartition?.dailyDeltaEvidenceComplete == true ? "全 完整" : "全 不完整"
        let ultra = metric.ultraTokenPartition?.dailyDeltaEvidenceComplete == true ? "U 完整" : "U 不完整"
        return "\(routing) · \(ultra)"
    }
}
