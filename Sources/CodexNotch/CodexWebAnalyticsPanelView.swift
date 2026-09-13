import SwiftUI

struct CodexWebAnalyticsPanelView: View {
    @ObservedObject var viewModel: CodexWebAnalyticsViewModel
    let onOpenAnalytics: () -> Void
    let onOpenBrowser: () -> Void

    private var snapshot: CodexAnalyticsSnapshot { viewModel.snapshot }

    var body: some View {
        VStack(alignment: .leading, spacing: MonitorTheme.Spacing.micro) {
            HStack(spacing: MonitorTheme.Spacing.inline) {
                Image(systemName: "chart.xyaxis.line")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(MonitorTheme.accentBlue)
                    .accessibilityHidden(true)
                Text("官方 Analytics")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(MonitorTheme.textPrimary)
                Text("· \(viewModel.state.label)")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(statusColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)

                Spacer(minLength: MonitorTheme.Spacing.compact)

                Button(action: onOpenAnalytics) {
                    Label("图表", systemImage: "chart.xyaxis.line")
                        .font(.system(size: 9, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(MonitorTheme.accentBlue)
                .help("打开原生 Analytics 图表页")

                Button(action: onOpenBrowser) {
                    Label(viewModel.isWebSessionReady ? "连接官网" : "需登录", systemImage: "arrow.up.right")
                        .font(.system(size: 9, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(MonitorTheme.accentBlue)
                .help(viewModel.isWebSessionReady ? "查看 Codex Analytics 官网" : "登录 Codex Analytics 官网")
                .accessibilityLabel(viewModel.isWebSessionReady ? "查看官网" : "登录官网")
            }

            HStack(spacing: MonitorTheme.Spacing.inline) {
                Text("官网数据 · 最近 7 天")
                    .font(.system(size: 8.5, weight: .medium))
                    .foregroundStyle(MonitorTheme.textSecondary)
                Text(updatedText)
                    .font(.system(size: 8.5, weight: .medium))
                    .foregroundStyle(MonitorTheme.textTertiary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .accessibilityHidden(true)
        }
        .padding(.horizontal, MonitorTheme.Spacing.row)
        .frame(height: IslandMetrics.detailAnalyticsHeight, alignment: .center)
        .background(MonitorTheme.sectionFill)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(MonitorTheme.separator)
                .frame(height: MonitorTheme.Stroke.hairline)
        }
        .help(helpText)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityText)
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

    private var updatedText: String {
        guard snapshot.capturedAt != .distantPast else { return viewModel.state.message }
        return "\(Formatters.relativeAge(snapshot.capturedAt))前更新"
    }

    private var accessibilityText: String {
        "官方最近 7 天 Analytics。Turns \(countText(snapshot.turns))，Skills \(countText(snapshot.skillsUsed))，Plugin calls \(countText(snapshot.pluginCalls))。\(helpText)"
    }
}
