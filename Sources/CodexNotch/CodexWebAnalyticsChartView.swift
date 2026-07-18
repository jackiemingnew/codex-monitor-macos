import Charts
import SwiftUI

struct CodexWebAnalyticsChartView: View {
    @ObservedObject var viewModel: CodexWebAnalyticsViewModel
    let onOpenBrowser: () -> Void

    @State private var turnsMode: TurnsMode = .model

    private var snapshot: CodexAnalyticsSnapshot { viewModel.snapshot }

    var body: some View {
        ScrollView(.vertical) {
            LazyVStack(spacing: MonitorTheme.Spacing.row) {
                sourceStrip

                AnalyticsChartCard(
                    title: "轮次",
                    total: snapshot.turns,
                    chart: turnsChart,
                    seriesLimit: 6,
                    palette: MonitorTheme.analyticsTurnsPalette,
                    emptyMessage: chartEmptyMessage(total: snapshot.turns)
                ) {
                    Picker("Turns 分类", selection: $turnsMode) {
                        ForEach(TurnsMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 158)
                    .accessibilityLabel("Turns 分类")
                }

                AnalyticsChartCard(
                    title: "Skills used",
                    total: snapshot.skillsUsed,
                    chart: snapshot.skillsBySkill,
                    seriesLimit: 8,
                    palette: MonitorTheme.analyticsSkillsPalette,
                    emptyMessage: chartEmptyMessage(total: snapshot.skillsUsed)
                ) {
                    EmptyView()
                }

                HStack(spacing: MonitorTheme.Spacing.inline) {
                    Text("Plugin calls")
                    Text(countText(snapshot.pluginCalls))
                        .foregroundStyle(MonitorTheme.textPrimary)
                        .monospacedDigit()
                    Spacer()
                    Text("仅保留内存 · 不影响 RUN/IDLE")
                }
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(MonitorTheme.textTertiary)
                .padding(.horizontal, MonitorTheme.Spacing.compact)
                .accessibilityElement(children: .combine)
            }
            .padding(.bottom, MonitorTheme.Spacing.compact)
        }
        .scrollIndicators(.hidden)
        .accessibilityElement(children: .contain)
    }

    private var turnsChart: CodexAnalyticsChart {
        switch turnsMode {
        case .model:
            snapshot.turnsByModel
        case .surface:
            snapshot.turnsBySurface
        }
    }

    private var sourceStrip: some View {
        HStack(spacing: MonitorTheme.Spacing.inline) {
            Text("官方网页 · 最近 7 天")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(MonitorTheme.textSecondary)

            Text(viewModel.state.label)
                .font(.system(size: 8.5, weight: .semibold, design: .rounded))
                .foregroundStyle(statusColor)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(statusColor.opacity(0.14), in: Capsule())

            Spacer(minLength: MonitorTheme.Spacing.compact)

            Text(updatedText)
                .font(.system(size: 8.5, weight: .medium))
                .foregroundStyle(MonitorTheme.textTertiary)
                .lineLimit(1)

            Button(action: onOpenBrowser) {
                Label(viewModel.isWebSessionReady ? "官网" : "登录", systemImage: "globe")
                    .font(.system(size: 9.5, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(MonitorTheme.textSecondary)
            .help("打开应用自有的 Codex Analytics 网页会话")
        }
        .padding(.horizontal, MonitorTheme.Spacing.row)
        .frame(height: 34)
        .background(MonitorTheme.rowFill, in: RoundedRectangle(cornerRadius: MonitorTheme.Radius.row, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: MonitorTheme.Radius.row, style: .continuous)
                .stroke(MonitorTheme.hairline, lineWidth: MonitorTheme.Stroke.hairline)
        }
        .help(sourceHelpText)
        .accessibilityElement(children: .combine)
    }

    private func chartEmptyMessage(total: Int?) -> String {
        if total == 0 {
            return "最近 7 天为 0"
        }
        return viewModel.state.message
    }

    private func countText(_ value: Int?) -> String {
        guard let value else { return "--" }
        return value.formatted(.number.grouping(.automatic))
    }

    private var updatedText: String {
        guard snapshot.capturedAt != .distantPast else { return viewModel.state.message }
        return "\(Formatters.relativeAge(snapshot.capturedAt))前更新"
    }

    private var statusColor: Color {
        switch viewModel.state {
        case .ready:
            MonitorTheme.healthy
        case .partial, .stale:
            MonitorTheme.warning
        case .loading:
            MonitorTheme.radarBaseline
        case .loginRequired, .unavailable:
            MonitorTheme.textTertiary
        }
    }

    private var sourceHelpText: String {
        var parts = [viewModel.state.message]
        if !snapshot.rangeHelpText.isEmpty {
            parts.append(snapshot.rangeHelpText)
        }
        if !snapshot.qualityIssues.isEmpty {
            parts.append("质量：\(snapshot.qualityIssues.joined(separator: "；"))")
        }
        parts.append("数据来自用户可见网页；不调用内部接口，不影响本地 RUN/IDLE。")
        return parts.joined(separator: " ")
    }
}

private enum TurnsMode: String, CaseIterable, Identifiable {
    case model
    case surface

    var id: String { rawValue }

    var title: String {
        switch self {
        case .model:
            "By model"
        case .surface:
            "By surface"
        }
    }
}

private struct AnalyticsChartCard<Controls: View>: View {
    let title: String
    let total: Int?
    let chart: CodexAnalyticsChart
    let seriesLimit: Int
    let palette: [Color]
    let emptyMessage: String
    let controls: Controls

    init(
        title: String,
        total: Int?,
        chart: CodexAnalyticsChart,
        seriesLimit: Int,
        palette: [Color],
        emptyMessage: String,
        @ViewBuilder controls: () -> Controls
    ) {
        self.title = title
        self.total = total
        self.chart = chart
        self.seriesLimit = seriesLimit
        self.palette = palette
        self.emptyMessage = emptyMessage
        self.controls = controls()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: MonitorTheme.Spacing.inline) {
            HStack(alignment: .top, spacing: MonitorTheme.Spacing.row) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(title)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(MonitorTheme.textSecondary)
                    Text(totalText)
                        .font(.system(size: 24, weight: .medium, design: .rounded))
                        .foregroundStyle(MonitorTheme.textPrimary)
                        .monospacedDigit()
                }

                Spacer(minLength: MonitorTheme.Spacing.row)

                VStack(alignment: .trailing, spacing: MonitorTheme.Spacing.compact) {
                    controls
                    Text(chart.coverageLabel)
                        .font(.system(size: 8.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(coverageColor)
                }
            }

            if chart.points.isEmpty || chart.displaySeries(limit: seriesLimit).isEmpty {
                AnalyticsChartEmptyState(message: emptyMessage)
            } else {
                AnalyticsStackedAreaChart(
                    chart: chart,
                    seriesLimit: seriesLimit,
                    palette: palette
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
        .accessibilityLabel("\(title)，最近 7 天")
        .accessibilityValue(accessibilityValue)
        .help(chart.fullAccessibilityText(label: title))
    }

    private var totalText: String {
        guard let total else { return "--" }
        return total.formatted(.number.grouping(.automatic))
    }

    private var coverageColor: Color {
        chart.sampledDays == chart.expectedDays ? MonitorTheme.healthy : MonitorTheme.warning
    }

    private var accessibilityValue: String {
        "总数 \(totalText)，图表覆盖 \(chart.coverageLabel)。\(chart.fullAccessibilityText(label: title))"
    }
}

private struct AnalyticsChartEmptyState: View {
    let message: String

    var body: some View {
        VStack(spacing: MonitorTheme.Spacing.inline) {
            Image(systemName: "chart.xyaxis.line")
                .font(.system(size: 18, weight: .medium))
            Text(message)
                .font(.system(size: 10.5, weight: .medium))
                .multilineTextAlignment(.center)
        }
        .foregroundStyle(MonitorTheme.textTertiary)
        .frame(maxWidth: .infinity)
        .frame(height: 188)
        .accessibilityElement(children: .combine)
    }
}

private struct AnalyticsStackedAreaChart: View {
    let chart: CodexAnalyticsChart
    let seriesLimit: Int
    let palette: [Color]

    @State private var hoveredIndex: Int?

    private var series: [CodexAnalyticsDisplaySeries] {
        chart.displaySeries(limit: seriesLimit)
    }

    private var paletteForSeries: [Color] {
        guard !palette.isEmpty else { return [MonitorTheme.radarBaseline] }
        return series.indices.map { palette[$0 % palette.count] }
    }

    private var highlightedIndex: Int? {
        hoveredIndex ?? chart.points.last?.index
    }

    var body: some View {
        VStack(alignment: .leading, spacing: MonitorTheme.Spacing.inline) {
            ZStack(alignment: .topTrailing) {
                Chart {
                    ForEach(series) { chartSeries in
                        ForEach(chart.points) { point in
                            AreaMark(
                                x: .value("日期", point.index),
                                y: .value("次数", point.count(for: chartSeries.members)),
                                stacking: .standard
                            )
                            .interpolationMethod(.catmullRom)
                            .foregroundStyle(by: .value("系列", chartSeries.name))
                            .opacity(chartSeries.isOther ? 0.72 : 0.88)
                        }
                    }

                    if let highlightedIndex,
                       let point = chart.points.first(where: { $0.index == highlightedIndex }) {
                        RuleMark(x: .value("高亮日期", highlightedIndex))
                            .foregroundStyle(MonitorTheme.textSecondary.opacity(0.55))
                            .lineStyle(StrokeStyle(lineWidth: MonitorTheme.Stroke.hairline, dash: [3, 3]))

                        PointMark(
                            x: .value("高亮日期", highlightedIndex),
                            y: .value("当日总数", point.total)
                        )
                        .symbolSize(34)
                        .foregroundStyle(MonitorTheme.textPrimary)
                    }
                }
                .chartForegroundStyleScale(
                    domain: series.map(\.name),
                    range: paletteForSeries
                )
                .chartLegend(.hidden)
                .chartXAxis {
                    AxisMarks(values: chart.points.map(\.index)) { value in
                        AxisGridLine().foregroundStyle(MonitorTheme.separator.opacity(0.45))
                        AxisValueLabel {
                            if let index = value.as(Int.self),
                               let point = chart.points.first(where: { $0.index == index }) {
                                Text(compactDate(point.dateLabel))
                                    .font(.system(size: 8))
                                    .foregroundStyle(MonitorTheme.textTertiary)
                            }
                        }
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { _ in
                        AxisGridLine().foregroundStyle(MonitorTheme.separator.opacity(0.55))
                        AxisValueLabel()
                            .font(.system(size: 8))
                            .foregroundStyle(MonitorTheme.textTertiary)
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
                .frame(height: 190)

                if let hoveredPoint {
                    AnalyticsChartTooltip(
                        point: hoveredPoint,
                        series: series,
                        palette: paletteForSeries
                    )
                    .padding(.top, MonitorTheme.Spacing.compact)
                    .padding(.trailing, MonitorTheme.Spacing.compact)
                    .allowsHitTesting(false)
                }
            }

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 112), alignment: .leading)],
                alignment: .leading,
                spacing: MonitorTheme.Spacing.compact
            ) {
                ForEach(Array(series.enumerated()), id: \.element.id) { index, item in
                    HStack(spacing: MonitorTheme.Spacing.compact) {
                        Circle()
                            .fill(paletteForSeries[index])
                            .frame(width: 6, height: 6)
                        Text(item.name)
                            .font(.system(size: 8.5, weight: .medium))
                            .foregroundStyle(MonitorTheme.textSecondary)
                            .lineLimit(1)
                    }
                    .help("\(item.name)：\(item.total)")
                }
            }
        }
    }

    private var hoveredPoint: CodexAnalyticsDailyPoint? {
        guard let hoveredIndex else { return nil }
        return chart.points.first { $0.index == hoveredIndex }
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
            hoveredIndex = chart.points.min {
                abs($0.index - index) < abs($1.index - index)
            }?.index
        case .ended:
            hoveredIndex = nil
        }
    }

    private func compactDate(_ label: String) -> String {
        if let comma = label.firstIndex(of: ",") {
            return String(label[..<comma])
        }
        return label
    }
}

private struct AnalyticsChartTooltip: View {
    let point: CodexAnalyticsDailyPoint
    let series: [CodexAnalyticsDisplaySeries]
    let palette: [Color]

    var body: some View {
        VStack(alignment: .leading, spacing: MonitorTheme.Spacing.compact) {
            Text(point.dateLabel)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(MonitorTheme.textPrimary)

            ForEach(Array(series.enumerated()), id: \.element.id) { index, item in
                let count = point.count(for: item.members)
                if count > 0 {
                    HStack(spacing: MonitorTheme.Spacing.compact) {
                        Rectangle()
                            .fill(palette[index])
                            .frame(width: 7, height: 7)
                        Text(item.name)
                            .lineLimit(1)
                        Spacer(minLength: MonitorTheme.Spacing.row)
                        Text(count.formatted(.number.grouping(.automatic)))
                            .monospacedDigit()
                    }
                }
            }

            Divider()
            HStack {
                Text("Total")
                Spacer(minLength: MonitorTheme.Spacing.row)
                Text(point.total.formatted(.number.grouping(.automatic)))
                    .monospacedDigit()
            }
            .fontWeight(.semibold)
        }
        .font(.system(size: 9, weight: .medium))
        .foregroundStyle(MonitorTheme.textSecondary)
        .padding(MonitorTheme.Spacing.row)
        .frame(width: 168)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: MonitorTheme.Radius.row, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: MonitorTheme.Radius.row, style: .continuous)
                .stroke(MonitorTheme.panelStroke, lineWidth: MonitorTheme.Stroke.hairline)
        }
        .shadow(color: .black.opacity(0.22), radius: 8, x: 0, y: 4)
        .accessibilityElement(children: .combine)
    }
}
