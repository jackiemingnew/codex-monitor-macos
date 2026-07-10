import AppKit
import Charts
import SwiftUI

struct CodexRadarPanelView: View {
    let radar: CodexRadarSnapshot

    private let gridColumns = [
        GridItem(.flexible(minimum: 128), spacing: MonitorTheme.Spacing.inline),
        GridItem(.flexible(minimum: 128), spacing: MonitorTheme.Spacing.inline),
        GridItem(.flexible(minimum: 128), spacing: MonitorTheme.Spacing.inline)
    ]

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: MonitorTheme.Spacing.inline) {
                if let message = radar.message {
                    fallbackMessage(message)
                }

                intelligenceHeader
                modelGrid

                if radar.signalText != nil {
                    signalStrip
                }

                quotaHeader
                quotaTable
                footer
            }
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var intelligenceHeader: some View {
        HStack(spacing: MonitorTheme.Spacing.row) {
            Text("降智雷达")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(MonitorTheme.textPrimary)

            if let batch = CodexRadarBatchDateFormatter.displayText(radar.modelIQDate) {
                Text(batch)
                    .font(.system(size: 9.5, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(MonitorTheme.textTertiary)
            }

            Spacer(minLength: MonitorTheme.Spacing.row)

            Text("本次 \(CodexRadarCurrencyFormatter.displayText(radar.modelRunCostUSD))")
                .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(MonitorTheme.textPrimary)
                .lineLimit(1)
        }
        .frame(height: 20)
    }

    @ViewBuilder
    private var modelGrid: some View {
        if radar.models.isEmpty {
            emptyMessage(radar.message ?? "暂无 Codex Radar 模型数据")
        } else {
            LazyVGrid(columns: gridColumns, spacing: MonitorTheme.Spacing.inline) {
                ForEach(radar.models) { model in
                    CodexRadarModelScoreCard(model: model)
                }
            }
        }
    }

    private var signalStrip: some View {
        HStack(spacing: MonitorTheme.Spacing.row) {
            Circle()
                .fill(statusColor(radar.status))
                .frame(width: 6, height: 6)

            Text(radar.signalText ?? "")
                .font(.system(size: 9.8, weight: .medium))
                .foregroundStyle(MonitorTheme.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let action = actionText(radar.recommendedAction) {
                Text(action)
                    .font(.system(size: 8.5, weight: .semibold))
                    .foregroundStyle(statusColor(radar.status))
                    .lineLimit(1)
                    .padding(.horizontal, MonitorTheme.Spacing.inline)
                    .padding(.vertical, 2)
                    .background(
                        statusColor(radar.status).opacity(0.12),
                        in: RoundedRectangle(cornerRadius: MonitorTheme.Radius.chip, style: .continuous)
                    )
            }
        }
        .padding(.horizontal, MonitorTheme.Spacing.section)
        .frame(height: 28)
        .background(
            MonitorTheme.rowFill,
            in: RoundedRectangle(cornerRadius: MonitorTheme.Radius.row, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: MonitorTheme.Radius.row, style: .continuous)
                .stroke(MonitorTheme.hairline, lineWidth: MonitorTheme.Stroke.hairline)
        )
    }

    private var quotaHeader: some View {
        HStack(spacing: MonitorTheme.Spacing.row) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: MonitorTheme.Spacing.inline) {
                    Text("额度雷达")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(MonitorTheme.textPrimary)

                    if let batch = CodexRadarBatchDateFormatter.displayText(radar.quotaDate) {
                        Text(batch)
                            .font(.system(size: 9, weight: .medium, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(MonitorTheme.textTertiary)
                    }
                }

                if let quotaCost = radar.quotaCalibrationCostUSD {
                    Text("校准 \(CodexRadarCurrencyFormatter.displayText(quotaCost))")
                        .font(.system(size: 8.4, weight: .medium, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(MonitorTheme.textTertiary)
                }
            }

            Spacer(minLength: MonitorTheme.Spacing.compact)

            if let summary = radar.quotaTrendSummary {
                CodexRadarQuotaSparkline(
                    points: Array(radar.quotaTrend.suffix(10)),
                    direction: summary.direction
                )
                .frame(width: 74, height: 25)

                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(CodexRadarCurrencyFormatter.displayText(summary.startValue)) → \(CodexRadarCurrencyFormatter.displayText(summary.endValue))")
                        .font(.system(size: 8.4, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(MonitorTheme.textSecondary)
                    Text(trendDeltaText(summary))
                        .font(.system(size: 8.7, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(trendColor(summary.direction))
                }
                .lineLimit(1)
                .minimumScaleFactor(0.72)
            }
        }
        .frame(height: 32)
    }

    private var quotaTable: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                tableHeader("档位")
                    .frame(maxWidth: .infinity, alignment: .leading)
                tableHeader("5h额度")
                    .frame(width: 90, alignment: .trailing)
                tableHeader("7d额度")
                    .frame(width: 96, alignment: .trailing)
                tableHeader("来源")
                    .frame(width: 66, alignment: .trailing)
            }
            .padding(.horizontal, MonitorTheme.Spacing.section)
            .frame(height: 23)

            Rectangle()
                .fill(MonitorTheme.separator)
                .frame(height: MonitorTheme.Stroke.hairline)

            if radar.quotaRows.isEmpty {
                HStack {
                    Text("暂无额度雷达摘要")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(MonitorTheme.textSecondary)
                    Spacer()
                }
                .padding(.horizontal, MonitorTheme.Spacing.section)
                .frame(height: 30)
            } else {
                ForEach(radar.quotaRows) { row in
                    CodexRadarQuotaTableRow(row: row)
                }
            }
        }
        .background(
            MonitorTheme.rowFill,
            in: RoundedRectangle(cornerRadius: MonitorTheme.Radius.section, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: MonitorTheme.Radius.section, style: .continuous)
                .stroke(MonitorTheme.hairline, lineWidth: MonitorTheme.Stroke.hairline)
        )
    }

    private var footer: some View {
        HStack(spacing: MonitorTheme.Spacing.row) {
            Text("\(radar.attributionText) · \(radar.dataSource.displayLabel)")
                .font(.system(size: 9.2, weight: .medium))
                .foregroundStyle(MonitorTheme.textTertiary)
                .lineLimit(1)
                .minimumScaleFactor(0.72)

            Spacer(minLength: MonitorTheme.Spacing.row)

            Button {
                NSWorkspace.shared.open(radar.siteURL)
            } label: {
                Image(systemName: "arrow.up.forward.app")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(MonitorTheme.textSecondary)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("打开 codexradar.com")
        }
        .frame(height: 18)
        .padding(.horizontal, 2)
    }

    private func fallbackMessage(_ message: String) -> some View {
        HStack(spacing: MonitorTheme.Spacing.inline) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(MonitorTheme.warning)
            Text(message)
                .font(.system(size: 9.4, weight: .medium))
                .foregroundStyle(MonitorTheme.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, MonitorTheme.Spacing.section)
        .frame(height: 26)
        .background(
            MonitorTheme.warning.opacity(0.08),
            in: RoundedRectangle(cornerRadius: MonitorTheme.Radius.row, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: MonitorTheme.Radius.row, style: .continuous)
                .stroke(MonitorTheme.warning.opacity(0.22), lineWidth: MonitorTheme.Stroke.hairline)
        )
    }

    private func emptyMessage(_ message: String) -> some View {
        HStack {
            Text(message)
                .font(.system(size: 10.2, weight: .semibold))
                .foregroundStyle(MonitorTheme.textSecondary)
                .lineLimit(2)
            Spacer()
        }
        .padding(.horizontal, MonitorTheme.Spacing.section)
        .frame(minHeight: 48)
        .background(
            MonitorTheme.rowFill,
            in: RoundedRectangle(cornerRadius: MonitorTheme.Radius.row, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: MonitorTheme.Radius.row, style: .continuous)
                .stroke(MonitorTheme.hairline, lineWidth: MonitorTheme.Stroke.hairline)
        )
    }

    private func tableHeader(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9.4, weight: .semibold))
            .foregroundStyle(MonitorTheme.textSecondary)
    }

    private func actionText(_ action: String?) -> String? {
        guard let action = action?.trimmingCharacters(in: .whitespacesAndNewlines),
              !action.isEmpty else {
            return nil
        }
        switch action.lowercased() {
        case "wait":
            return "WAIT"
        case "reset_completed":
            return "DONE"
        case "open":
            return "OPEN"
        default:
            return action.replacingOccurrences(of: "_", with: " ").uppercased()
        }
    }

    private func statusColor(_ status: String?) -> Color {
        switch status?.lowercased() {
        case "green", "open", "normal":
            MonitorTheme.healthy
        case "yellow", "warning", "community_confirmed":
            MonitorTheme.warning
        case "red", "error", "closed":
            MonitorTheme.critical
        default:
            MonitorTheme.textPrimary
        }
    }

    private func trendDeltaText(_ summary: CodexRadarQuotaTrendSummary) -> String {
        let sign = summary.delta > 0 ? "+" : ""
        return "\(sign)\(CodexRadarCurrencyFormatter.displayText(summary.delta)) · \(sign)\(String(format: "%.1f", summary.percentChange))%"
    }

    private func trendColor(_ direction: CodexRadarTrendDirection) -> Color {
        switch direction {
        case .positive:
            MonitorTheme.healthy
        case .negative:
            MonitorTheme.critical
        case .neutral:
            MonitorTheme.textTertiary
        }
    }
}

private struct CodexRadarModelScoreCard: View {
    let model: CodexRadarModelScore

    var body: some View {
        VStack(alignment: .leading, spacing: MonitorTheme.Spacing.compact) {
            HStack(spacing: 5) {
                Circle()
                    .fill(scoreColor)
                    .frame(width: 6, height: 6)

                Text(model.label)
                    .font(.system(size: 9.8, weight: .semibold))
                    .foregroundStyle(MonitorTheme.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }

            Text(scoreText)
                .font(.system(size: 19, weight: .semibold, design: .rounded))
                .foregroundStyle(scoreColor)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
                .monospacedDigit()

            HStack(spacing: 5) {
                Text(model.taskSummary)
                    .foregroundStyle(metadataColor)
                if let wallTimeHuman = model.wallTimeHuman {
                    Text(wallTimeHuman)
                        .foregroundStyle(MonitorTheme.textTertiary)
                }
            }
            .font(.system(size: 8.5, weight: .medium))
            .lineLimit(1)
            .minimumScaleFactor(0.68)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, minHeight: 70, alignment: .leading)
        .background(
            MonitorTheme.rowFill,
            in: RoundedRectangle(cornerRadius: MonitorTheme.Radius.row, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: MonitorTheme.Radius.row, style: .continuous)
                .stroke(MonitorTheme.hairline, lineWidth: MonitorTheme.Stroke.hairline)
        )
        .overlay(alignment: .leading) {
            Capsule()
                .fill(scoreColor.opacity(0.9))
                .frame(width: 2, height: 34)
                .padding(.leading, 1.5)
        }
    }

    private var scoreText: String {
        model.score.map { String(format: "%.1f", $0) } ?? "--"
    }

    private var scoreColor: Color {
        switch model.scoreBand {
        case .healthy:
            MonitorTheme.healthy
        case .baseline:
            MonitorTheme.radarBaseline
        case .warning:
            MonitorTheme.warning
        case .critical:
            MonitorTheme.critical
        case .unknown:
            MonitorTheme.textTertiary
        }
    }

    private var metadataColor: Color {
        (model.invalidTasks ?? 0) > 0 ? MonitorTheme.warning : MonitorTheme.textTertiary
    }
}

private struct CodexRadarQuotaTableRow: View {
    let row: CodexRadarQuotaRow

    var body: some View {
        HStack(spacing: 0) {
            Text(row.tier)
                .font(.system(size: 10.2, weight: .semibold))
                .foregroundStyle(MonitorTheme.textPrimary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            quotaText(row.fiveH)
                .frame(width: 90, alignment: .trailing)

            quotaText(row.sevenD)
                .frame(width: 96, alignment: .trailing)

            Text(row.displayBasis)
                .font(.system(size: 9.2, weight: .medium))
                .foregroundStyle(MonitorTheme.textTertiary)
                .lineLimit(1)
                .frame(width: 66, alignment: .trailing)
                .help(row.basis ?? "来源未提供")
        }
        .padding(.horizontal, MonitorTheme.Spacing.section)
        .frame(height: 27)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(MonitorTheme.separator)
                .frame(height: MonitorTheme.Stroke.hairline)
        }
    }

    private func quotaText(_ value: Double?) -> some View {
        Text(CodexRadarCurrencyFormatter.displayText(value))
            .font(.system(size: 9.8, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(value == nil ? MonitorTheme.textTertiary : MonitorTheme.textPrimary)
            .lineLimit(1)
            .minimumScaleFactor(0.75)
    }
}

private struct CodexRadarQuotaSparkline: View {
    let points: [CodexRadarQuotaTrendPoint]
    let direction: CodexRadarTrendDirection

    private var chartPoints: [CodexRadarQuotaChartPoint] {
        points.compactMap { point -> Double? in
            guard let value = point.sevenD20x else {
                return nil
            }
            return value
        }
        .enumerated()
        .map { CodexRadarQuotaChartPoint(index: $0.offset, value: $0.element) }
    }

    var body: some View {
        Chart(chartPoints) { point in
            LineMark(
                x: .value("批次", point.index),
                y: .value("7d额度", point.value)
            )
            .interpolationMethod(.linear)
            .foregroundStyle(color)
            .lineStyle(StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))

            if point.index == chartPoints.last?.index {
                PointMark(
                    x: .value("批次", point.index),
                    y: .value("7d额度", point.value)
                )
                .symbolSize(14)
                .foregroundStyle(color)
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartPlotStyle { plot in
            plot.background(.clear)
        }
        .accessibilityLabel("20x Pro 7天额度趋势")
    }

    private var color: Color {
        switch direction {
        case .positive:
            MonitorTheme.healthy
        case .negative:
            MonitorTheme.critical
        case .neutral:
            MonitorTheme.textTertiary
        }
    }
}

private struct CodexRadarQuotaChartPoint: Identifiable {
    var id: Int { index }

    let index: Int
    let value: Double
}
