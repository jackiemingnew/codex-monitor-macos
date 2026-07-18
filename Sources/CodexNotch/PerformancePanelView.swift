import SwiftUI

struct PerformancePanelView: View {
    @ObservedObject var viewModel: PerformanceMonitorViewModel

    var body: some View {
        VStack(spacing: MonitorTheme.Spacing.row) {
            diagnosticBanner
            processTable
            footer
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder
    private var diagnosticBanner: some View {
        if let finding = viewModel.findings.first {
            HStack(alignment: .top, spacing: MonitorTheme.Spacing.row) {
                Image(systemName: finding.severity == .critical ? "exclamationmark.triangle.fill" : "exclamationmark.circle.fill")
                    .foregroundStyle(color(for: finding.severity))
                VStack(alignment: .leading, spacing: MonitorTheme.Spacing.micro) {
                    Text(finding.title)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(MonitorTheme.textPrimary)
                    Text(finding.detail)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(MonitorTheme.textSecondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            .padding(MonitorTheme.Spacing.row)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(color(for: finding.severity).opacity(0.10), in: RoundedRectangle(cornerRadius: MonitorTheme.Radius.row, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: MonitorTheme.Radius.row, style: .continuous)
                    .stroke(color(for: finding.severity).opacity(0.24), lineWidth: MonitorTheme.Stroke.hairline)
            )
            .accessibilityElement(children: .combine)
        } else if viewModel.currentSample != nil {
            HStack(spacing: MonitorTheme.Spacing.inline) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(MonitorTheme.healthy)
                Text("当前采样未见持续资源异常")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(MonitorTheme.textPrimary)
                Spacer()
            }
            .padding(MonitorTheme.Spacing.row)
            .background(MonitorTheme.healthy.opacity(0.08), in: RoundedRectangle(cornerRadius: MonitorTheme.Radius.row, style: .continuous))
        } else if let errorMessage = viewModel.errorMessage {
            Text("采样失败：\(errorMessage)")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(MonitorTheme.critical)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(MonitorTheme.Spacing.row)
                .background(MonitorTheme.critical.opacity(0.08), in: RoundedRectangle(cornerRadius: MonitorTheme.Radius.row, style: .continuous))
        } else {
            Text("正在建立 30 秒资源基线…")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(MonitorTheme.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(MonitorTheme.Spacing.row)
                .background(MonitorTheme.sectionFill, in: RoundedRectangle(cornerRadius: MonitorTheme.Radius.row, style: .continuous))
        }
    }

    private var processTable: some View {
        VStack(spacing: 0) {
            tableHeader
            ForEach(rows) { row in
                PerformanceMetricRow(row: row)
            }
        }
        .background(MonitorTheme.sectionFill, in: RoundedRectangle(cornerRadius: MonitorTheme.Radius.section, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: MonitorTheme.Radius.section, style: .continuous)
                .stroke(MonitorTheme.hairline, lineWidth: MonitorTheme.Stroke.hairline)
        )
    }

    private var tableHeader: some View {
        HStack(spacing: MonitorTheme.Spacing.row) {
            Text("对象").frame(maxWidth: .infinity, alignment: .leading)
            Text("CPU").frame(width: 58, alignment: .trailing)
            Text("内存").frame(width: 72, alignment: .trailing)
            Text("30秒峰值").frame(width: 70, alignment: .trailing)
            Text("进程").frame(width: 54, alignment: .trailing)
        }
        .font(MonitorTheme.Typography.tableHeader)
        .foregroundStyle(MonitorTheme.textSecondary)
        .padding(.horizontal, MonitorTheme.Spacing.panel)
        .frame(height: 28)
        .overlay(alignment: .bottom) {
            Rectangle().fill(MonitorTheme.separator).frame(height: MonitorTheme.Stroke.hairline)
        }
    }

    private var rows: [PerformanceMetricDisplay] {
        guard let sample = viewModel.currentSample else {
            return PerformanceTargetKind.allCases.map {
                PerformanceMetricDisplay(kind: $0, target: .unavailable($0), peakCPU: nil)
            }
        }
        return PerformanceTargetKind.allCases.map { kind in
            PerformanceMetricDisplay(
                kind: kind,
                target: sample.target(kind),
                peakCPU: viewModel.peakCPU(for: kind)
            )
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: MonitorTheme.Spacing.compact) {
            HStack {
                Text(viewModel.backgroundMonitoringEnabled ? "后台监控：已开启" : "后台监控：已关闭")
                Text("·")
                Text(memoryPressureText)
                Spacer()
                Text(sampleAgeText)
            }
            Text("FPS：macOS 不提供轻量的跨应用真实帧率；WindowServer CPU 仅表示合成压力。WebKit PID 归属需通过刷新标签验证。")
                .lineLimit(2)
        }
        .font(.system(size: 10.2, weight: .medium))
        .foregroundStyle(MonitorTheme.textTertiary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var memoryPressureText: String {
        guard let free = viewModel.currentSample?.systemMemoryFreePercent else {
            return "系统可用内存：--"
        }
        return "系统可用内存：\(free)%"
    }

    private var sampleAgeText: String {
        guard let date = viewModel.currentSample?.capturedAt else {
            return "尚未采样"
        }
        return "更新于 \(Formatters.relativeAge(date))"
    }

    private func color(for severity: PerformanceSeverity) -> Color {
        switch severity {
        case .critical:
            MonitorTheme.critical
        case .warning:
            MonitorTheme.warning
        case .normal:
            MonitorTheme.healthy
        case .unavailable:
            MonitorTheme.textTertiary
        }
    }
}

private struct PerformanceMetricDisplay: Identifiable {
    let kind: PerformanceTargetKind
    let target: PerformanceTargetSample
    let peakCPU: Double?

    var id: String { kind.rawValue }

    var title: String {
        switch kind {
        case .chatGPT: "Codex / ChatGPT"
        case .safariHost: "Safari 主进程组"
        case .webKitContent: "最热 WebKit 内容"
        case .windowServer: "WindowServer"
        }
    }

    var processText: String {
        if let pid = target.pid {
            return "PID \(pid)"
        }
        return target.processCount > 0 ? "\(target.processCount) 个" : "--"
    }
}

private struct PerformanceMetricRow: View {
    let row: PerformanceMetricDisplay

    var body: some View {
        HStack(spacing: MonitorTheme.Spacing.row) {
            Text(row.title)
                .font(MonitorTheme.Typography.tableBody)
                .foregroundStyle(MonitorTheme.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(value(row.target.processCount > 0 ? PerformanceFormatting.cpu(row.target.cpuPercent) : nil))
                .frame(width: 58, alignment: .trailing)
            Text(value(row.target.processCount > 0 ? PerformanceFormatting.bytes(row.target.residentBytes) : nil))
                .frame(width: 72, alignment: .trailing)
            Text(value(row.peakCPU.map(PerformanceFormatting.cpu)))
                .frame(width: 70, alignment: .trailing)
            Text(row.processText)
                .foregroundStyle(MonitorTheme.textSecondary)
                .frame(width: 54, alignment: .trailing)
        }
        .font(MonitorTheme.Typography.tableValue)
        .foregroundStyle(MonitorTheme.textPrimary)
        .monospacedDigit()
        .padding(.horizontal, MonitorTheme.Spacing.panel)
        .frame(height: 38)
        .overlay(alignment: .bottom) {
            Rectangle().fill(MonitorTheme.separator).frame(height: MonitorTheme.Stroke.hairline)
        }
        .accessibilityElement(children: .combine)
    }

    private func value(_ text: String?) -> String {
        text ?? "--"
    }
}
