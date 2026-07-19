import Charts
import SwiftUI

struct LocalTokenAnalyticsView: View {
    let summary: CostUsageSummary
    let isEnabled: Bool

    @State private var period: LocalTokenAnalyticsPeriod = .sevenDays

    private var report: LocalTokenAnalyticsReport {
        LocalTokenAnalyticsReport.make(summary: summary, period: period)
    }

    var body: some View {
        ScrollView(.vertical) {
            LazyVStack(spacing: MonitorTheme.Spacing.row) {
                if isEnabled {
                    sourceStrip
                    periodPicker

                    if report.totalTokens > 0 {
                        LocalTokenSummaryCard(report: report)
                        LocalTokenRankingCard(report: report)
                        disclosureNote
                    } else {
                        emptyState
                    }
                } else {
                    disabledState
                }
            }
            .padding(.bottom, MonitorTheme.Spacing.compact)
        }
        .scrollIndicators(.hidden)
        .accessibilityElement(children: .contain)
    }

    private var sourceStrip: some View {
        HStack(spacing: MonitorTheme.Spacing.inline) {
            VStack(alignment: .leading, spacing: 1) {
                Text("本机 JSONL · 已发布快照")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(MonitorTheme.textSecondary)
                Text("父任务 + 子代理 · 不做任务下钻")
                    .font(.system(size: 8.5, weight: .medium))
                    .foregroundStyle(MonitorTheme.textTertiary)
            }

            LocalTokenQualityBadge(
                label: tokenQualityLabel,
                color: tokenQualityColor
            )

            if summary.tokenQuality == .complete,
               summary.quality == .partial {
                LocalTokenQualityBadge(label: "费用 PARTIAL", color: MonitorTheme.warning)
            }

            Spacer(minLength: MonitorTheme.Spacing.compact)

            Text(updatedText)
                .font(.system(size: 8.5, weight: .medium))
                .foregroundStyle(MonitorTheme.textTertiary)
                .lineLimit(1)
        }
        .padding(.horizontal, MonitorTheme.Spacing.row)
        .frame(height: 42)
        .background(MonitorTheme.rowFill, in: RoundedRectangle(cornerRadius: MonitorTheme.Radius.row, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: MonitorTheme.Radius.row, style: .continuous)
                .stroke(MonitorTheme.hairline, lineWidth: MonitorTheme.Stroke.hairline)
        }
        .help(sourceHelp)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("本地 Token 数据源")
        .accessibilityValue(sourceHelp)
    }

    private var periodPicker: some View {
        HStack(spacing: MonitorTheme.Spacing.row) {
            Text("周期")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(MonitorTheme.textSecondary)

            Spacer(minLength: MonitorTheme.Spacing.row)

            Picker("本地 Token 周期", selection: $period) {
                ForEach(LocalTokenAnalyticsPeriod.allCases) { item in
                    Text(item.title).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 210)
            .accessibilityLabel("本地 Token 周期")
            .accessibilityHint("选择今日、最近 7 个本地自然日或最近 30 个本地自然日")
        }
        .padding(.horizontal, MonitorTheme.Spacing.row)
        .frame(height: 36)
        .background(MonitorTheme.controlFill, in: RoundedRectangle(cornerRadius: MonitorTheme.Radius.row, style: .continuous))
    }

    private var emptyState: some View {
        LocalTokenMessageCard(
            systemImage: summary.tokenQuality == .partial ? "clock.arrow.circlepath" : "chart.xyaxis.line",
            title: emptyTitle,
            message: emptyMessage
        )
    }

    private var disabledState: some View {
        LocalTokenMessageCard(
            systemImage: "slider.horizontal.3",
            title: "本地周期用量未启用",
            message: "请在设置中启用“显示 今日 / 7天 / 30天”。此页面不会偷偷启动扫描。"
        )
    }

    private var disclosureNote: some View {
        Text("Token = input + output；cached input 是 input 子集。费用为 API 标准单价等值估算，不是订阅账单。")
            .font(.system(size: 8.5, weight: .medium))
            .foregroundStyle(MonitorTheme.textTertiary)
            .padding(.horizontal, MonitorTheme.Spacing.compact)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel("指标说明")
            .accessibilityValue("总 Token 等于输入加输出，缓存输入是输入的子集，不重复相加。费用是 API 标准单价等值估算，不是订阅账单。")
    }

    private var tokenQualityLabel: String {
        switch summary.tokenQuality {
        case .complete:
            "Token COMPLETE"
        case .partial:
            "Token 回填中"
        case .unavailable:
            "Token 无数据"
        }
    }

    private var tokenQualityColor: Color {
        switch summary.tokenQuality {
        case .complete:
            MonitorTheme.healthy
        case .partial:
            MonitorTheme.warning
        case .unavailable:
            MonitorTheme.textTertiary
        }
    }

    private var updatedText: String {
        guard let lastUpdated = summary.lastUpdated else { return "尚未发布" }
        return "\(Formatters.relativeAge(lastUpdated))前更新"
    }

    private var sourceHelp: String {
        var parts = [
            "只读取成本扫描协调器已发布的本地数值快照，汇总当前与归档父任务及子代理。",
            "不读取网页、不发起网络请求，也不提供父子代理拆分。",
            tokenQualityLabel
        ]
        if summary.tokenQuality == .complete, summary.quality == .partial {
            parts.append("Token 完整；部分模型未定价，仅影响费用说明。")
        }
        if summary.usesSparkProxy {
            parts.append("Spark 使用 GPT-5.3-Codex 标准单价作为代理。")
        }
        return parts.joined(separator: " ")
    }

    private var emptyTitle: String {
        switch summary.tokenQuality {
        case .complete:
            "\(period.title)暂无本地 Token"
        case .partial:
            "正在回填本地 Token"
        case .unavailable:
            "暂无已发布快照"
        }
    }

    private var emptyMessage: String {
        switch summary.tokenQuality {
        case .complete:
            "该本地自然日周期内没有已发布的模型 Token。"
        case .partial:
            "完整扫描发布前不会显示局部 Token；可使用右上角刷新继续现有扫描。"
        case .unavailable:
            "使用右上角刷新启动现有成本扫描协调器；不会读取官网 Analytics。"
        }
    }
}

private struct LocalTokenQualityBadge: View {
    let label: String
    let color: Color

    var body: some View {
        Text(label)
            .font(.system(size: 8, weight: .semibold, design: .rounded))
            .foregroundStyle(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(color.opacity(0.14), in: Capsule())
    }
}

private struct LocalTokenMessageCard: View {
    let systemImage: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: MonitorTheme.Spacing.row) {
            Image(systemName: systemImage)
                .font(.system(size: 19, weight: .medium))
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(MonitorTheme.textSecondary)
            Text(message)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(MonitorTheme.textTertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 330)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 220)
        .background(MonitorTheme.sectionFill, in: RoundedRectangle(cornerRadius: MonitorTheme.Radius.section, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: MonitorTheme.Radius.section, style: .continuous)
                .stroke(MonitorTheme.hairline, lineWidth: MonitorTheme.Stroke.hairline)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct LocalTokenSummaryCard: View {
    let report: LocalTokenAnalyticsReport

    var body: some View {
        VStack(alignment: .leading, spacing: MonitorTheme.Spacing.inline) {
            HStack(alignment: .top, spacing: MonitorTheme.Spacing.row) {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Token")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(MonitorTheme.textSecondary)
                    Text(Formatters.compactTokensEnglish(report.totalTokens))
                        .font(.system(size: 24, weight: .medium, design: .rounded))
                        .foregroundStyle(MonitorTheme.textPrimary)
                        .monospacedDigit()
                }

                Spacer(minLength: MonitorTheme.Spacing.row)

                VStack(alignment: .trailing, spacing: MonitorTheme.Spacing.micro) {
                    Text(report.period.title)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(MonitorTheme.textSecondary)
                    Text("\(report.days.filter { $0.totalTokens > 0 }.count)/\(report.period.dayCount) 天")
                        .font(.system(size: 8.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(MonitorTheme.healthy)
                }
            }

            if report.period == .today {
                LocalTokenCompositionBar(report: report)
            } else {
                LocalTokenStackedTrendChart(report: report)
            }
        }
        .padding(MonitorTheme.Spacing.section)
        .background(MonitorTheme.sectionFill, in: RoundedRectangle(cornerRadius: MonitorTheme.Radius.section, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: MonitorTheme.Radius.section, style: .continuous)
                .stroke(MonitorTheme.hairline, lineWidth: MonitorTheme.Stroke.hairline)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(report.period.title)本地 Token")
        .accessibilityValue(LocalTokenText.reportAccessibility(report))
        .help(LocalTokenText.reportAccessibility(report))
    }
}

private struct LocalTokenStackedTrendChart: View {
    let report: LocalTokenAnalyticsReport

    @State private var hoveredIndex: Int?
    @State private var keyboardIndex: Int?

    private var series: [LocalTokenDisplaySeries] {
        report.displaySeries(limit: 6)
    }

    private var palette: [Color] {
        series.map { LocalTokenPalette.color(for: $0) }
    }

    private var selectedIndex: Int? {
        hoveredIndex ?? keyboardIndex
    }

    var body: some View {
        VStack(alignment: .leading, spacing: MonitorTheme.Spacing.inline) {
            ZStack(alignment: tooltipAlignment) {
                Chart {
                    ForEach(series) { item in
                        ForEach(Array(report.days.enumerated()), id: \.element.id) { index, day in
                            AreaMark(
                                x: .value("日期", index),
                                y: .value("Token", day.usage(for: item.members, displayName: item.name).totalTokens),
                                stacking: .standard
                            )
                            .interpolationMethod(.linear)
                            .foregroundStyle(by: .value("模型", item.name))
                            .opacity(item.isOther ? 0.68 : 0.86)
                        }
                    }

                    if let selectedIndex,
                       report.days.indices.contains(selectedIndex) {
                        RuleMark(x: .value("选择日期", selectedIndex))
                            .foregroundStyle(MonitorTheme.textSecondary.opacity(0.58))
                            .lineStyle(StrokeStyle(lineWidth: MonitorTheme.Stroke.hairline, dash: [3, 3]))
                    }
                }
                .chartForegroundStyleScale(domain: series.map(\.name), range: palette)
                .chartLegend(.hidden)
                .chartXAxis {
                    AxisMarks(values: axisIndices) { value in
                        AxisGridLine().foregroundStyle(MonitorTheme.separator.opacity(0.45))
                        AxisValueLabel {
                            if let index = value.as(Int.self), report.days.indices.contains(index) {
                                Text(LocalTokenText.compactDate(report.days[index].dayKey))
                                    .font(.system(size: 8))
                                    .foregroundStyle(MonitorTheme.textTertiary)
                            }
                        }
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                        AxisGridLine().foregroundStyle(MonitorTheme.separator.opacity(0.55))
                        AxisValueLabel {
                            if let tokens = value.as(Int.self) {
                                Text(Formatters.compactTokensEnglish(tokens))
                                    .font(.system(size: 8))
                                    .foregroundStyle(MonitorTheme.textTertiary)
                            }
                        }
                    }
                }
                .chartPlotStyle { plot in
                    plot.background(.clear)
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
                .frame(height: 226)

                if let selectedDay {
                    LocalTokenDayTooltip(day: selectedDay, series: series, palette: palette)
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
            .accessibilityIdentifier("local-token-daily-trend")
            .accessibilityLabel("\(report.period.title)每日模型 Token 堆叠趋势")
            .accessibilityValue(accessibilityValueText)
            .accessibilityHint("获得键盘焦点后，使用左右方向键选择日期")
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

            LocalTokenLegend(series: series, palette: palette)
        }
    }

    private var selectedDay: LocalTokenDayUsage? {
        guard let selectedIndex, report.days.indices.contains(selectedIndex) else { return nil }
        return report.days[selectedIndex]
    }

    private var accessibilityValueText: String {
        guard let selectedDay else {
            return "共 \(report.days.count) 天，未选择日期"
        }
        let usage = LocalTokenModelUsage.aggregate(model: "全部模型", usages: selectedDay.models)
        return "\(LocalTokenText.fullDate(selectedDay.dayKey))，\(LocalTokenText.usageDetails(usage, periodTotal: report.totalTokens))"
    }

    private var tooltipAlignment: Alignment {
        guard let selectedIndex else { return .topTrailing }
        return selectedIndex > report.days.count / 2 ? .topLeading : .topTrailing
    }

    private var axisIndices: [Int] {
        let keys = Set(report.axisDayKeys(maximumLabels: report.period == .thirtyDays ? 6 : 7))
        return report.days.indices.filter { keys.contains(report.days[$0].dayKey) }
    }

    private func updateHover(
        _ phase: HoverPhase,
        proxy: ChartProxy,
        geometry: GeometryProxy
    ) {
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
            hoveredIndex = min(max(0, index), report.days.count - 1)
        case .ended:
            hoveredIndex = nil
        }
    }

    private func moveKeyboardSelection(by offset: Int) {
        guard !report.days.isEmpty else { return }
        guard let current = keyboardIndex else {
            // The first directional action selects its edge instead of moving
            // past it: right/increment starts at the first day, while
            // left/decrement starts at the last day.
            keyboardIndex = offset >= 0 ? 0 : report.days.count - 1
            return
        }
        keyboardIndex = min(max(0, current + offset), report.days.count - 1)
    }
}

private struct LocalTokenCompositionBar: View {
    let report: LocalTokenAnalyticsReport

    @State private var hoveredSeriesID: String?
    @State private var keyboardSeriesIndex: Int?

    private var series: [LocalTokenDisplaySeries] {
        report.displaySeries(limit: 6)
    }

    private var palette: [Color] {
        series.map { LocalTokenPalette.color(for: $0) }
    }

    private var day: LocalTokenDayUsage {
        report.days.last ?? LocalTokenDayUsage(dayKey: "", models: [])
    }

    private var selectedSeriesID: String? {
        hoveredSeriesID ?? keyboardSeriesIndex.flatMap { series.indices.contains($0) ? series[$0].id : nil }
    }

    private var selectedSeries: LocalTokenDisplaySeries? {
        guard let selectedSeriesID else { return nil }
        return series.first { $0.id == selectedSeriesID }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: MonitorTheme.Spacing.inline) {
            ZStack(alignment: .topTrailing) {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: MonitorTheme.Radius.segment, style: .continuous)
                            .fill(MonitorTheme.progressTrack)

                        ForEach(Array(series.enumerated()), id: \.element.id) { index, item in
                            let usage = day.usage(for: item.members, displayName: item.name)
                            let share = usage.share(of: day.totalTokens)
                            Rectangle()
                                .fill(palette[index])
                                .frame(width: max(1, geometry.size.width * share))
                                .offset(x: geometry.size.width * leadingShare(before: index))
                                .contentShape(Rectangle())
                                .onContinuousHover { phase in
                                    switch phase {
                                    case .active:
                                        hoveredSeriesID = item.id
                                    case .ended:
                                        if hoveredSeriesID == item.id {
                                            hoveredSeriesID = nil
                                        }
                                    }
                                }
                                .help(LocalTokenText.usageDetails(usage, periodTotal: day.totalTokens))
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: MonitorTheme.Radius.segment, style: .continuous))
                }
                .frame(height: 32)

                if selectedSeriesID != nil {
                    LocalTokenDayTooltip(day: day, series: series, palette: palette)
                        .padding(.top, 38)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .frame(height: selectedSeriesID == nil ? 44 : 212, alignment: .top)
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
            .accessibilityIdentifier("local-token-today-composition")
            .accessibilityLabel("今日模型 Token 组成")
            .accessibilityValue(accessibilityValueText)
            .accessibilityHint("获得键盘焦点后，使用左右方向键选择模型")
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

            LocalTokenLegend(series: series, palette: palette)
        }
    }

    private func leadingShare(before index: Int) -> Double {
        guard index > 0 else { return 0 }
        return series[..<index].reduce(0) { partial, item in
            partial + day.usage(for: item.members, displayName: item.name).share(of: day.totalTokens)
        }
    }

    private var accessibilityValueText: String {
        guard let selectedSeries else {
            return "共 \(series.count) 个模型，未选择模型"
        }
        let usage = day.usage(for: selectedSeries.members, displayName: selectedSeries.name)
        return "\(selectedSeries.name)，\(LocalTokenText.usageDetails(usage, periodTotal: day.totalTokens))"
    }

    private func moveKeyboardSelection(by offset: Int) {
        guard !series.isEmpty else { return }
        guard let current = keyboardSeriesIndex else {
            // Match the trend chart: the first directional action establishes
            // the corresponding edge rather than skipping it.
            keyboardSeriesIndex = offset >= 0 ? 0 : series.count - 1
            return
        }
        keyboardSeriesIndex = min(max(0, current + offset), series.count - 1)
    }
}

private struct LocalTokenLegend: View {
    let series: [LocalTokenDisplaySeries]
    let palette: [Color]

    var body: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 112), alignment: .leading)],
            alignment: .leading,
            spacing: MonitorTheme.Spacing.compact
        ) {
            ForEach(Array(series.enumerated()), id: \.element.id) { index, item in
                HStack(spacing: MonitorTheme.Spacing.compact) {
                    Circle()
                        .fill(palette[index])
                        .frame(width: 6, height: 6)
                    Text(item.name)
                        .font(.system(size: 8.5, weight: .medium))
                        .foregroundStyle(MonitorTheme.textSecondary)
                        .lineLimit(1)
                }
                .help("\(item.name)：\(item.totalTokens.formatted(.number.grouping(.automatic))) Token")
            }
        }
    }
}

private struct LocalTokenDayTooltip: View {
    let day: LocalTokenDayUsage
    let series: [LocalTokenDisplaySeries]
    let palette: [Color]

    private var totalUsage: LocalTokenModelUsage {
        LocalTokenModelUsage.aggregate(model: "全部模型", usages: day.models)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: MonitorTheme.Spacing.micro) {
            Text(LocalTokenText.fullDate(day.dayKey))
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(MonitorTheme.textPrimary)

            ForEach(Array(series.enumerated()), id: \.element.id) { index, item in
                let usage = day.usage(for: item.members, displayName: item.name)
                if usage.totalTokens > 0 {
                    HStack(spacing: MonitorTheme.Spacing.compact) {
                        Rectangle()
                            .fill(palette[index])
                            .frame(width: 7, height: 7)
                        Text(item.name)
                            .lineLimit(1)
                        Spacer(minLength: MonitorTheme.Spacing.row)
                        Text(usage.totalTokens.formatted(.number.grouping(.automatic)))
                            .monospacedDigit()
                    }
                }
            }

            Divider()

            tooltipDetail("未缓存输入", totalUsage.uncachedInputTokens)
            tooltipDetail("缓存输入", totalUsage.cachedInputTokens)
            tooltipDetail("输出", totalUsage.outputTokens)

            HStack {
                Text("总 Token")
                Spacer(minLength: MonitorTheme.Spacing.row)
                Text(totalUsage.totalTokens.formatted(.number.grouping(.automatic)))
                    .monospacedDigit()
            }
            .fontWeight(.semibold)

            HStack {
                Text("API 等值")
                Spacer(minLength: MonitorTheme.Spacing.row)
                Text(LocalTokenText.cost(totalUsage))
                    .foregroundStyle(totalUsage.isPriced ? MonitorTheme.textSecondary : MonitorTheme.warning)
            }
        }
        .font(.system(size: 8.5, weight: .medium))
        .foregroundStyle(MonitorTheme.textSecondary)
        .padding(MonitorTheme.Spacing.row)
        .frame(width: 214)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: MonitorTheme.Radius.row, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: MonitorTheme.Radius.row, style: .continuous)
                .stroke(MonitorTheme.panelStroke, lineWidth: MonitorTheme.Stroke.hairline)
        }
        .shadow(color: .black.opacity(0.24), radius: 8, x: 0, y: 4)
        .accessibilityHidden(true)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(LocalTokenText.fullDate(day.dayKey)) Token 详情")
        .accessibilityValue(LocalTokenText.usageDetails(totalUsage, periodTotal: totalUsage.totalTokens))
    }

    private func tooltipDetail(_ label: String, _ value: Int) -> some View {
        HStack {
            Text(label)
            Spacer(minLength: MonitorTheme.Spacing.row)
            Text(value.formatted(.number.grouping(.automatic)))
                .monospacedDigit()
        }
    }
}

private struct LocalTokenRankingCard: View {
    let report: LocalTokenAnalyticsReport

    var body: some View {
        VStack(alignment: .leading, spacing: MonitorTheme.Spacing.compact) {
            HStack {
                Text("全模型排行")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(MonitorTheme.textSecondary)
                Spacer()
                Text("\(report.models.count) 个模型")
                    .font(.system(size: 8.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(MonitorTheme.textTertiary)
            }
            .padding(.bottom, MonitorTheme.Spacing.micro)

            ForEach(Array(report.models.enumerated()), id: \.element.id) { index, usage in
                LocalTokenRankingRow(
                    rank: index + 1,
                    usage: usage,
                    periodTotal: report.totalTokens
                )
            }
        }
        .padding(MonitorTheme.Spacing.section)
        .background(MonitorTheme.sectionFill, in: RoundedRectangle(cornerRadius: MonitorTheme.Radius.section, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: MonitorTheme.Radius.section, style: .continuous)
                .stroke(MonitorTheme.hairline, lineWidth: MonitorTheme.Stroke.hairline)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(report.period.title)全模型 Token 排行")
    }
}

private struct LocalTokenRankingRow: View {
    let rank: Int
    let usage: LocalTokenModelUsage
    let periodTotal: Int

    private var shareText: String {
        LocalTokenText.share(usage.share(of: periodTotal))
    }

    var body: some View {
        HStack(spacing: MonitorTheme.Spacing.inline) {
            Text("\(rank)")
                .font(.system(size: 9, weight: .semibold, design: .rounded))
                .foregroundStyle(MonitorTheme.textTertiary)
                .monospacedDigit()
                .frame(width: 16, alignment: .trailing)

            Circle()
                .fill(LocalTokenPalette.color(forModel: usage.model, isOther: false))
                .frame(width: 7, height: 7)

            VStack(alignment: .leading, spacing: 1) {
                Text(usage.model)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(MonitorTheme.textSecondary)
                    .lineLimit(1)
                Text(LocalTokenText.costLabel(usage))
                    .font(.system(size: 8, weight: .medium))
                    .foregroundStyle(usage.isPriced ? MonitorTheme.textTertiary : MonitorTheme.warning)
                    .lineLimit(1)
            }

            Spacer(minLength: MonitorTheme.Spacing.row)

            VStack(alignment: .trailing, spacing: 1) {
                Text(Formatters.compactTokensEnglish(usage.totalTokens))
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(MonitorTheme.textPrimary)
                    .monospacedDigit()
                Text(shareText)
                    .font(.system(size: 8.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(MonitorTheme.textSecondary)
                    .monospacedDigit()
            }
            .frame(width: 76, alignment: .trailing)
        }
        .padding(.horizontal, MonitorTheme.Spacing.inline)
        .frame(height: 39)
        .background(MonitorTheme.rowFill, in: RoundedRectangle(cornerRadius: MonitorTheme.Radius.row, style: .continuous))
        .focusable()
        .help(LocalTokenText.usageDetails(usage, periodTotal: periodTotal))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("第 \(rank) 名，\(usage.model)")
        .accessibilityValue(LocalTokenText.usageDetails(usage, periodTotal: periodTotal))
    }
}

private enum LocalTokenPalette {
    static func color(for series: LocalTokenDisplaySeries) -> Color {
        color(forModel: series.name, isOther: series.isOther)
    }

    static func color(forModel model: String, isOther: Bool) -> Color {
        if isOther { return MonitorTheme.textTertiary }
        switch model {
        case "gpt-5.6-sol":
            return MonitorTheme.analyticsTurnsPalette[0]
        case "codex-auto-review":
            return MonitorTheme.analyticsTurnsPalette[1]
        case "gpt-5.6-terra":
            return MonitorTheme.analyticsTurnsPalette[5]
        case "gpt-5.6-luna":
            return MonitorTheme.analyticsTurnsPalette[4]
        default:
            let palette = [
                MonitorTheme.analyticsTurnsPalette[2],
                MonitorTheme.analyticsTurnsPalette[3],
                MonitorTheme.analyticsSkillsPalette[6],
                MonitorTheme.analyticsSkillsPalette[7],
                MonitorTheme.analyticsSkillsPalette[8]
            ]
            let scalarTotal = model.unicodeScalars.reduce(0) { ($0 + Int($1.value)) % palette.count }
            return palette[scalarTotal]
        }
    }
}

private enum LocalTokenText {
    static func share(_ value: Double) -> String {
        let percent = max(0, value) * 100
        if percent > 0, percent < 0.01 {
            return "<0.01%"
        }
        if percent < 1 {
            return String(format: "%.2f%%", percent)
        }
        return String(format: "%.1f%%", percent)
    }

    static func cost(_ usage: LocalTokenModelUsage) -> String {
        guard usage.isPriced, let usd = usage.apiEquivalentUSD else {
            return "未定价"
        }
        return Formatters.apiEquivalentCost(
            CostEstimateWindow(usd: usd, isPartial: false, tokenCount: usage.totalTokens)
        )
    }

    static func costLabel(_ usage: LocalTokenModelUsage) -> String {
        guard usage.isPriced else { return "API 等值：未定价" }
        let proxy = usage.usesSparkProxy ? " · Spark 代理价" : ""
        return "API 等值 \(cost(usage))\(proxy)"
    }

    static func usageDetails(_ usage: LocalTokenModelUsage, periodTotal: Int) -> String {
        var parts = [
            "总 Token \(usage.totalTokens.formatted(.number.grouping(.automatic)))",
            "占比 \(share(usage.share(of: periodTotal)))",
            "未缓存输入 \(usage.uncachedInputTokens.formatted(.number.grouping(.automatic)))",
            "缓存输入 \(usage.cachedInputTokens.formatted(.number.grouping(.automatic)))",
            "输出 \(usage.outputTokens.formatted(.number.grouping(.automatic)))",
            "API 等值 \(cost(usage))"
        ]
        if usage.usesSparkProxy {
            parts.append("Spark 使用 GPT-5.3-Codex 标准单价代理")
        }
        return parts.joined(separator: "；")
    }

    static func reportAccessibility(_ report: LocalTokenAnalyticsReport) -> String {
        let modelText = report.models.map {
            "\($0.model) \($0.totalTokens.formatted(.number.grouping(.automatic))) Token，占比 \(share($0.share(of: report.totalTokens)))"
        }.joined(separator: "；")
        return "总 Token \(report.totalTokens.formatted(.number.grouping(.automatic)))。\(modelText)"
    }

    static func compactDate(_ dayKey: String) -> String {
        let parts = dayKey.split(separator: "-")
        guard parts.count == 3 else { return dayKey }
        return "\(Int(parts[1]) ?? 0)/\(Int(parts[2]) ?? 0)"
    }

    static func fullDate(_ dayKey: String) -> String {
        let parts = dayKey.split(separator: "-")
        guard parts.count == 3 else { return dayKey }
        return "\(parts[0])年\(Int(parts[1]) ?? 0)月\(Int(parts[2]) ?? 0)日"
    }
}
