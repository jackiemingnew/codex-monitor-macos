import AppKit
import SwiftUI

struct MenuBarStatusView: View {
    @ObservedObject var viewModel: UsageViewModel
    @ObservedObject var remoteViewModel: RemoteMonitorViewModel
    @ObservedObject var newAPIViewModel: BalanceMonitorViewModel
    @ObservedObject var subAPIViewModel: BalanceMonitorViewModel
    @ObservedObject var settings: CodexNotchSettings

    var body: some View {
        HStack(spacing: 4) {
            CodexMenuBarMark(color: statusColor)

            switch effectiveDisplaySource {
            case .automatic, .codex:
                Text(Formatters.percent(mainQuotaWindow?.remainingPercent))
                    .font(.system(size: 10.2, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.primary)
                    .monospacedDigit()
                    .fixedSize(horizontal: true, vertical: false)
            case .remoteCodex:
                compactExternalText("CPA", count: remoteViewModel.snapshot.quotaCount + remoteViewModel.snapshot.abnormalCount)
            case .newAPI:
                compactExternalText("New", count: newAPIViewModel.snapshot.accounts.count)
            case .subAPI:
                compactExternalText("Sub", count: subAPIViewModel.snapshot.accounts.count)
            }
        }
        .padding(.horizontal, 4)
        .frame(width: MenuBarMetrics.width, height: MenuBarMetrics.height, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private func compactExternalText(_ title: String, count: Int) -> some View {
        Text("\(title) \(count)")
            .font(.system(size: 9.2, weight: .semibold, design: .rounded))
            .foregroundStyle(statusColor)
            .monospacedDigit()
    }

    private var effectiveDisplaySource: NotchDisplaySource {
        HUDDisplaySourceResolver.resolve(
            selected: settings.notchDisplaySource,
            remoteEnabled: settings.remoteMonitorEnabled,
            remoteSeverity: remoteViewModel.snapshot.panelSeverity,
            newAPIEnabled: settings.newAPIMonitorEnabled,
            newAPISeverity: newAPIViewModel.snapshot.panelSeverity,
            subAPIEnabled: settings.subAPIMonitorEnabled,
            subAPISeverity: subAPIViewModel.snapshot.panelSeverity
        )
    }

    private var mainQuotaWindow: MainQuotaWindow? {
        viewModel.snapshot.mainQuotaWindows.first
    }

    private var statusColor: Color {
        switch effectiveDisplaySource {
        case .automatic, .codex:
            viewModel.snapshot.isRunning ? MonitorTheme.running : Color.secondary
        case .remoteCodex:
            severityColor(remoteViewModel.snapshot.panelSeverity)
        case .newAPI:
            severityColor(newAPIViewModel.snapshot.panelSeverity)
        case .subAPI:
            severityColor(subAPIViewModel.snapshot.panelSeverity)
        }
    }

    private func severityColor(_ severity: RemoteAlertSeverity) -> Color {
        switch severity {
        case .none:
            Color.primary
        case .warning:
            MonitorTheme.warning
        case .error:
            MonitorTheme.critical
        }
    }

    private var accessibilityText: String {
        switch effectiveDisplaySource {
        case .automatic, .codex:
            "Codex \(viewModel.snapshot.isRunning ? "运行中" : "空闲")，\(mainQuotaWindow?.accessibilityLabel ?? "额度")剩余 \(Formatters.percent(mainQuotaWindow?.remainingPercent))"
        case .remoteCodex:
            "CLIProxyAPI，异常 \(remoteViewModel.snapshot.quotaCount + remoteViewModel.snapshot.abnormalCount)"
        case .newAPI:
            "NewAPI，账户 \(newAPIViewModel.snapshot.accounts.count)"
        case .subAPI:
            "Sub2API，账户 \(subAPIViewModel.snapshot.accounts.count)"
        }
    }
}

private struct CodexMenuBarMark: View {
    let color: Color

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            HStack(alignment: .center, spacing: 1) {
                Capsule().frame(width: 2, height: 6)
                Capsule().frame(width: 2, height: 11)
                Capsule().frame(width: 2, height: 8)
            }
            .foregroundStyle(Color.primary)

            Circle()
                .fill(color)
                .frame(width: 3.5, height: 3.5)
                .overlay(Circle().stroke(Color.black.opacity(0.18), lineWidth: 0.4))
        }
        .frame(width: 15, height: 14)
    }
}

enum MenuBarMetrics {
    static let width: CGFloat = 52
    static let height: CGFloat = NSStatusBar.system.thickness
}
