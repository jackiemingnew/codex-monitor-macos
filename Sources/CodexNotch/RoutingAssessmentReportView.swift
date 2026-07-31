import AppKit
import SwiftUI

struct RoutingAssessmentReportView: View {
    let report: RoutingAssessmentReport
    let onOpenInBrowser: () -> Result<Void, Error>
    @State private var browserFeedback: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MonitorTheme.Spacing.section) {
                VStack(alignment: .leading, spacing: MonitorTheme.Spacing.micro) {
                    Text("路由手动评估报告").font(.system(size: 22, weight: .bold)).accessibilityAddTraits(.isHeader)
                    Text(report.timeRangeText).font(.system(size: 11)).foregroundStyle(MonitorTheme.settingsTextSecondary)
                }
                statusRow
                section("关键摘要", items: report.summary)
                section("关键发现", items: report.findings)
                section("改进建议", items: report.recommendations)
                VStack(alignment: .leading, spacing: MonitorTheme.Spacing.inline) {
                    Text("证据边界").font(.system(size: 12, weight: .semibold)).accessibilityAddTraits(.isHeader)
                    Text(report.evidenceBoundaryText).font(.system(size: 10)).foregroundStyle(MonitorTheme.settingsTextSecondary)
                }
                HStack {
                    Button("在浏览器中查看") {
                        switch onOpenInBrowser() {
                        case .success: browserFeedback = "已在默认浏览器打开本机聚合报告。"
                        case .failure: browserFeedback = "无法打开本机报告。请稍后重试。"
                        }
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("在浏览器中查看路由评估报告")
                    .accessibilityHint("手动写入本机聚合 HTML 后在默认浏览器打开")
                    if let browserFeedback {
                        Text(browserFeedback).font(.system(size: 10)).foregroundStyle(browserFeedback.hasPrefix("无法") ? MonitorTheme.settingsWarning : MonitorTheme.settingsTextSecondary)
                            .accessibilityLabel("浏览器报告状态：\(browserFeedback)")
                    }
                }
            }
            .padding(MonitorTheme.Spacing.section)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .foregroundStyle(MonitorTheme.settingsTextPrimary)
        .background(Color(nsColor: .windowBackgroundColor))
        .scrollIndicators(.automatic)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("路由手动评估报告")
    }

    private var statusRow: some View {
        HStack(spacing: MonitorTheme.Spacing.row) {
            status("结构", report.structureStatus)
            status("身份", report.identityStatus)
            status("效率", report.efficiencyStatus)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("报告状态")
        .accessibilityValue("结构 \(report.structureStatus.label)，身份 \(report.identityStatus.label)，效率 \(report.efficiencyStatus.label)")
    }

    private func status(_ title: String, _ status: RoutingAssessmentReportStatus) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 10)).foregroundStyle(MonitorTheme.settingsTextSecondary)
            Text(status.label).font(.system(size: 11, weight: .bold, design: .rounded)).foregroundStyle(statusColor(status))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(MonitorTheme.Spacing.row)
        .background(MonitorTheme.settingsSurfaceElevatedFill, in: RoundedRectangle(cornerRadius: MonitorTheme.Radius.row, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: MonitorTheme.Radius.row, style: .continuous).stroke(MonitorTheme.settingsHairline, lineWidth: MonitorTheme.Stroke.settingsHairline))
    }

    private func section(_ title: String, items: [RoutingAssessmentReportItem]) -> some View {
        VStack(alignment: .leading, spacing: MonitorTheme.Spacing.inline) {
            Text(title).font(.system(size: 12, weight: .semibold)).accessibilityAddTraits(.isHeader)
            ForEach(items) { item in
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title).font(.system(size: 11, weight: .semibold))
                    Text(item.detail).font(.system(size: 10)).foregroundStyle(MonitorTheme.settingsTextSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(MonitorTheme.Spacing.row)
        .background(MonitorTheme.settingsSurfaceFill, in: RoundedRectangle(cornerRadius: MonitorTheme.Radius.section, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: MonitorTheme.Radius.section, style: .continuous).stroke(MonitorTheme.settingsHairline, lineWidth: MonitorTheme.Stroke.settingsHairline))
    }

    private func statusColor(_ status: RoutingAssessmentReportStatus) -> Color {
        switch status {
        case .complete: MonitorTheme.settingsSuccess
        case .partial: MonitorTheme.settingsWarning
        case .unverified: MonitorTheme.settingsTextSecondary
        }
    }
}

@MainActor
final class RoutingAssessmentReportWindowController {
    private var window: NSWindow?

    func show(assessment: RoutingAssessment) {
        let report = RoutingAssessmentReport(assessment: assessment)
        let window = window ?? makeWindow(report: report)
        window.contentView = NSHostingView(rootView: RoutingAssessmentReportView(report: report, onOpenInBrowser: { Self.openInBrowser(report) }))
        self.window = window
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func makeWindow(report: RoutingAssessmentReport) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 620), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "路由手动评估报告"
        window.backgroundColor = .windowBackgroundColor
        window.minSize = NSSize(width: 620, height: 460)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: RoutingAssessmentReportView(report: report, onOpenInBrowser: { Self.openInBrowser(report) }))
        return window
    }

    private static func openInBrowser(_ report: RoutingAssessmentReport) -> Result<Void, Error> {
        do {
            let folder = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("CodexNotch", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
            let url = folder.appendingPathComponent("routing-assessment-report.html", isDirectory: false)
            guard let data = RoutingAssessmentReportHTMLRenderer.render(report).data(using: .utf8) else { throw CocoaError(.fileWriteInapplicableStringEncoding) }
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            guard NSWorkspace.shared.open(url) else { throw CocoaError(.fileNoSuchFile) }
            return .success(())
        } catch { return .failure(error) }
    }
}
