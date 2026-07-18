import SwiftUI

struct CodexWebAnalyticsPanelView: View {
    @ObservedObject var viewModel: CodexWebAnalyticsViewModel
    let onOpenAnalytics: () -> Void
    let onOpenBrowser: () -> Void

    private var snapshot: CodexAnalyticsSnapshot { viewModel.snapshot }

    var body: some View {
        HStack(spacing: MonitorTheme.Spacing.inline) {
            Text("官方数据 · 7天")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(MonitorTheme.textSecondary)
                .lineLimit(1)

            Text(viewModel.state.label)
                .font(.system(size: 8, weight: .semibold, design: .rounded))
                .foregroundStyle(statusColor)
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(statusColor.opacity(0.14), in: Capsule())

            Spacer(minLength: 0)

            compactKPI("T", value: snapshot.turns)
            compactKPI("S", value: snapshot.skillsUsed)
            compactKPI("P", value: snapshot.pluginCalls)

            Button(action: onOpenAnalytics) {
                Label("图表", systemImage: "chart.xyaxis.line")
                    .font(.system(size: 9, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(MonitorTheme.textSecondary)
            .help("打开原生 Analytics 图表页")

            Button(action: onOpenBrowser) {
                Image(systemName: "globe")
                    .font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(MonitorTheme.textSecondary)
            .help(viewModel.isWebSessionReady ? "查看 Codex Analytics 官网" : "登录 Codex Analytics 官网")
            .accessibilityLabel(viewModel.isWebSessionReady ? "查看官网" : "网页登录")
        }
        .padding(.horizontal, MonitorTheme.Spacing.row)
        .frame(height: IslandMetrics.detailAnalyticsHeight)
        .background(MonitorTheme.rowFill, in: RoundedRectangle(cornerRadius: MonitorTheme.Radius.row, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: MonitorTheme.Radius.row, style: .continuous)
                .stroke(MonitorTheme.hairline, lineWidth: MonitorTheme.Stroke.hairline)
        }
        .help(helpText)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityText)
    }

    private func compactKPI(_ label: String, value: Int?) -> some View {
        VStack(spacing: 0) {
            Text(label)
                .font(.system(size: 7.5, weight: .semibold, design: .rounded))
                .foregroundStyle(MonitorTheme.textTertiary)
            Text(countText(value))
                .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                .foregroundStyle(MonitorTheme.textPrimary)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .frame(width: 42)
    }

    private func countText(_ value: Int?) -> String {
        guard let value else { return "--" }
        return value.formatted(.number.grouping(.automatic))
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

    private var helpText: String {
        var parts = [viewModel.state.message]
        if !snapshot.rangeHelpText.isEmpty {
            parts.append(snapshot.rangeHelpText)
        }
        if snapshot.capturedAt != .distantPast {
            parts.append("\(Formatters.relativeAge(snapshot.capturedAt))前更新")
        }
        if !snapshot.qualityIssues.isEmpty {
            parts.append("质量：\(snapshot.qualityIssues.joined(separator: "；"))")
        }
        parts.append("T 为 Turns，S 为 Skills，P 为 Plugin calls。数据来自用户可见网页。")
        return parts.joined(separator: " ")
    }

    private var accessibilityText: String {
        "官方最近 7 天 Analytics。Turns \(countText(snapshot.turns))，Skills \(countText(snapshot.skillsUsed))，Plugin calls \(countText(snapshot.pluginCalls))。\(helpText)"
    }
}
