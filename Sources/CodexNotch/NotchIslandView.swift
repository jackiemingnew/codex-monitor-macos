import AppKit
import SwiftUI

private enum DetailPage: String, CaseIterable, Identifiable {
    case local
    case remote

    var id: String { rawValue }

    var title: String {
        switch self {
        case .local:
            "本机"
        case .remote:
            "远程"
        }
    }
}

struct NotchIslandView: View {
    @ObservedObject var viewModel: UsageViewModel
    @ObservedObject var remoteViewModel: RemoteMonitorViewModel
    @ObservedObject var overlayState: OverlayState
    @ObservedObject var settings: CodexNotchSettings
    let onSettings: () -> Void
    @State private var pulse = false

    private var snapshot: UsageSnapshot {
        viewModel.snapshot
    }

    var body: some View {
        ZStack(alignment: .top) {
            islandBackground
            collapsedContent
        }
        .frame(
            width: IslandMetrics.width,
            height: IslandMetrics.collapsedHeight,
            alignment: .top
        )
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                overlayState.isExpanded.toggle()
            }
        }
        .contextMenu {
            Button("设置") {
                onSettings()
            }
            Button("刷新") {
                viewModel.refreshAll()
            }
            Divider()
            Button("退出 Codex 刘海") {
                NSApp.terminate(nil)
            }
        }
        .onAppear {
            pulse = true
        }
    }

    private var islandBackground: some View {
        BottomRoundedRectangle(radius: 21)
            .fill(Color.black.opacity(0.985))
            .frame(
                width: IslandMetrics.width,
                height: IslandMetrics.collapsedHeight,
                alignment: .top
            )
            .overlay(alignment: .top) {
                centerNotchMask
            }
    }

    private var centerNotchMask: some View {
        BottomRoundedRectangle(radius: 20)
            .fill(Color.black)
            .frame(width: IslandMetrics.notchWidth, height: IslandMetrics.collapsedHeight)
            .offset(x: 0, y: 0)
    }

    private var collapsedContent: some View {
        HStack(spacing: 0) {
            statusBlock
                .frame(width: IslandMetrics.shoulderWidth, height: IslandMetrics.collapsedHeight - 4)

            Color.clear
                .frame(width: IslandMetrics.notchWidth, height: IslandMetrics.collapsedHeight)

            rateLimitBlock
                .frame(width: IslandMetrics.shoulderWidth, height: IslandMetrics.collapsedHeight - 4)
        }
        .frame(width: IslandMetrics.width, height: IslandMetrics.collapsedHeight, alignment: .top)
    }

    private var statusBlock: some View {
        HStack(spacing: 5) {
            RemoteAlertBadge(severity: remoteViewModel.snapshot.panelSeverity)
            StatusDot(isRunning: snapshot.isRunning, pulse: pulse, enablePulse: settings.enablePulse)
            Text("Codex")
                .font(.system(size: 10.2, weight: .bold))
                .foregroundStyle(snapshot.isRunning ? .white.opacity(0.94) : .white.opacity(0.74))
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.trailing, 4)
    }

    private var rateLimitBlock: some View {
        VStack(alignment: .leading, spacing: 1) {
            RateLimitRow(
                label: "5h",
                percent: snapshot.primaryPercent,
                color: Color(red: 0.61, green: 0.95, blue: 0.68)
            )
            RateLimitRow(
                label: "7d",
                percent: snapshot.secondaryPercent,
                color: Color(red: 0.50, green: 0.78, blue: 1.00)
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 4)
    }
}

private struct RateLimitRow: View {
    let label: String
    let percent: Int?
    let color: Color

    var body: some View {
        HStack(spacing: 0) {
            Text(label)
                .frame(width: 14, alignment: .leading)
                .foregroundStyle(.white.opacity(0.60))

            Color.clear
                .frame(width: 3)

            if let percent {
                HStack(spacing: 0) {
                    Text("\(percent)")
                        .frame(width: 22, alignment: .trailing)
                    Text("%")
                        .fixedSize(horizontal: true, vertical: false)
                }
                .foregroundStyle(color)
            } else {
                Text("--")
                    .frame(width: 24, alignment: .leading)
                    .foregroundStyle(color)
            }
        }
        .font(.system(size: 9.0, weight: .bold, design: .rounded))
        .monospacedDigit()
        .frame(width: 50, alignment: .leading)
    }
}

struct DetailPanelView: View {
    @ObservedObject var viewModel: UsageViewModel
    @ObservedObject var remoteViewModel: RemoteMonitorViewModel
    @ObservedObject var settings: CodexNotchSettings
    let onSettings: () -> Void
    let onLocalRefresh: () -> Void
    let onRemoteRefresh: () -> Void
    @State private var detailPage: DetailPage = .local

    private var snapshot: UsageSnapshot {
        viewModel.snapshot
    }

    var body: some View {
        ZStack(alignment: .top) {
            BottomRoundedRectangle(radius: 24)
                .fill(Color.black.opacity(0.985))

            VStack(spacing: 10) {
                header
                pageSwitcher

                Group {
                    if detailPage == .local {
                        localContent
                    } else {
                        remoteContent
                    }
                }
                .frame(maxHeight: .infinity, alignment: .top)
            }
            .padding(.horizontal, 14)
            .padding(.top, IslandMetrics.detailTopPadding)
            .padding(.bottom, IslandMetrics.detailBottomPadding)
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .frame(width: IslandMetrics.width, height: detailHeight)
        .clipShape(BottomRoundedRectangle(radius: 24))
    }

    private var displayedTasks: [CodexTask] {
        snapshot.tasks
    }

    private var detailHeight: CGFloat {
        let localHeight = IslandMetrics.detailHeight(
            taskRows: IslandMetrics.visibleTaskRows,
            showsPeriodUsage: settings.showPeriodUsage
        )
        guard settings.remoteMonitorEnabled else {
            return localHeight
        }
        return max(
            localHeight,
            IslandMetrics.remoteDetailHeight(accountRows: remoteViewModel.snapshot.accounts.count)
        )
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 6) {
            Text(headerTitle)
                .font(.system(size: 11, weight: .heavy))
                .foregroundStyle(.white.opacity(0.82))
                .lineLimit(1)
                .frame(height: IslandMetrics.detailHeaderHeight, alignment: .center)

            Spacer()

            Text(headerStatus)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(headerStatusColor)
                .lineLimit(1)
                .frame(height: IslandMetrics.detailHeaderHeight, alignment: .center)

            Button(action: refreshCurrentPage) {
                RefreshIcon(isRefreshing: isCurrentPageRefreshing)
            }
            .buttonStyle(IconButtonStyle())
            .disabled(isCurrentPageRefreshing)
            .help(detailPage == .local ? "刷新本机" : "刷新远程")

            Button(action: onSettings) {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 10, weight: .bold))
            }
            .buttonStyle(IconButtonStyle())
            .help("设置")
        }
        .frame(height: IslandMetrics.detailHeaderHeight, alignment: .center)
    }

    private var headerTitle: String {
        switch detailPage {
        case .local:
            snapshot.isRunning ? "正在运行" : "最近活动"
        case .remote:
            "远程账号"
        }
    }

    private var headerStatus: String {
        switch detailPage {
        case .local:
            return snapshot.isRunning ? "\(snapshot.tasks.filter { $0.status == .running }.count) 个任务" : "空闲"
        case .remote:
            if remoteViewModel.snapshot.usageMessage != nil {
                return "用量旧"
            }
            return remoteHeaderStatus
        }
    }

    private var headerStatusColor: Color {
        switch detailPage {
        case .local:
            snapshot.isRunning ? Color(red: 0.61, green: 0.95, blue: 0.68) : .white.opacity(0.48)
        case .remote:
            remoteStatusColor
        }
    }

    private var remoteHeaderStatus: String {
        switch remoteViewModel.snapshot.panelState {
        case .disabled:
            "未启用"
        case .notConfigured:
            "待配置"
        case .loading:
            "读取中"
        case .healthy:
            "正常"
        case .warning:
            "提醒"
        case .error:
            "异常"
        }
    }

    private var remoteStatusColor: Color {
        switch remoteViewModel.snapshot.panelSeverity {
        case .none:
            return remoteViewModel.snapshot.usageMessage == nil
                ? Color(red: 0.61, green: 0.95, blue: 0.68)
                : Color(red: 1.0, green: 0.55, blue: 0.25)
        case .warning:
            return Color(red: 1.0, green: 0.55, blue: 0.25)
        case .error:
            return Color(red: 1.0, green: 0.28, blue: 0.30)
        }
    }

    private var isCurrentPageRefreshing: Bool {
        switch detailPage {
        case .local:
            viewModel.isRefreshing
        case .remote:
            remoteViewModel.isRefreshing
        }
    }

    private var pageSwitcher: some View {
        HStack(spacing: 6) {
            ForEach(DetailPage.allCases) { page in
                Button {
                    detailPage = page
                } label: {
                    ZStack {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(detailPage == page ? Color.white.opacity(0.12) : Color.white.opacity(0.035))

                        Text(page.title)
                            .font(.system(size: 10, weight: .bold))
                    }
                    .frame(maxWidth: .infinity, minHeight: IslandMetrics.detailPageSwitcherHeight)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)
                .foregroundStyle(detailPage == page ? .white.opacity(0.92) : .white.opacity(0.48))
            }
        }
        .frame(height: IslandMetrics.detailPageSwitcherHeight)
    }

    private func refreshCurrentPage() {
        switch detailPage {
        case .local:
            onLocalRefresh()
        case .remote:
            onRemoteRefresh()
        }
    }

    private var localContent: some View {
        VStack(spacing: 10) {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 7) {
                    ForEach(displayedTasks) { task in
                        TaskRow(task: task)
                    }

                    if displayedTasks.isEmpty {
                        emptyState
                    }
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)

            if settings.showPeriodUsage {
                periodUsage
            }
        }
        .frame(maxHeight: .infinity, alignment: .bottom)
    }

    private var remoteContent: some View {
        VStack(spacing: 8) {
            remoteSummary

            Group {
                if remoteViewModel.snapshot.accounts.isEmpty {
                    remoteMessage
                } else {
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(spacing: 7) {
                            ForEach(remoteViewModel.snapshot.accounts) { account in
                                RemoteAccountRow(account: account)
                            }
                        }
                    }
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)

            cpaUsageSummary
        }
        .frame(maxHeight: .infinity, alignment: .bottom)
    }

    private var remoteSummary: some View {
        HStack(spacing: 8) {
            RemoteSummaryCell(label: "正常", value: "\(remoteViewModel.snapshot.healthyCount)")
            RemoteSummaryCell(label: "配额", value: "\(remoteViewModel.snapshot.quotaCount)")
            RemoteSummaryCell(label: "异常", value: "\(remoteViewModel.snapshot.abnormalCount)")
        }
    }

    private var remoteMessage: some View {
        HStack {
            Text(remoteViewModel.snapshot.message ?? "暂无远程账号")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.white.opacity(0.58))
                .lineLimit(2)
            Spacer()
        }
        .padding(.horizontal, 10)
        .frame(minHeight: 50)
        .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
    }

    private var cpaUsageSummary: some View {
        HStack(spacing: 8) {
            PeriodUsageCell(label: "24小时", value: Formatters.compactTokens(remoteViewModel.snapshot.usage24h))
            PeriodUsageCell(label: "7天", value: Formatters.compactTokens(remoteViewModel.snapshot.usage7d))
            PeriodUsageCell(label: "30天", value: Formatters.compactTokens(remoteViewModel.snapshot.usage30d))
        }
    }

    private var emptyState: some View {
        HStack {
            Text(snapshot.errorMessage ?? "暂无 Codex 活动")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.58))
                .lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, 10)
        .frame(height: 36)
        .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
    }

    private var periodUsage: some View {
        HStack(spacing: 8) {
            PeriodUsageCell(label: "24小时", value: Formatters.compactTokens(snapshot.usage24h))
            PeriodUsageCell(label: "7天", value: Formatters.compactTokens(snapshot.usage7d))
            PeriodUsageCell(label: "30天", value: Formatters.compactTokens(snapshot.usage30d))
        }
        .padding(.top, 1)
    }
}

private struct RemoteAlertBadge: View {
    let severity: RemoteAlertSeverity

    var body: some View {
        if severity != .none {
            Text("!")
                .font(.system(size: 7, weight: .heavy, design: .rounded))
                .foregroundStyle(.black.opacity(0.88))
                .frame(width: 10, height: 10)
                .background(color, in: Circle())
                .shadow(color: color.opacity(0.45), radius: 5, x: 0, y: 0)
                .help(severity == .error ? "远程账号异常" : "远程账号配额提醒")
        }
    }

    private var color: Color {
        switch severity {
        case .none:
            .clear
        case .warning:
            Color(red: 1.0, green: 0.55, blue: 0.25)
        case .error:
            Color(red: 1.0, green: 0.28, blue: 0.30)
        }
    }
}

private struct StatusDot: View {
    let isRunning: Bool
    let pulse: Bool
    let enablePulse: Bool

    var body: some View {
        ZStack {
            if isRunning && enablePulse {
                Circle()
                    .stroke(Color(red: 0.20, green: 0.94, blue: 0.43).opacity(0.28), lineWidth: 4)
                    .frame(width: 8, height: 8)
                    .scaleEffect(pulse ? 1.45 : 0.95)
                    .opacity(pulse ? 0.16 : 0.44)
                    .animation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true), value: pulse)
            }

            Circle()
                .fill(isRunning ? Color(red: 0.20, green: 0.94, blue: 0.43) : Color(red: 0.31, green: 0.33, blue: 0.37))
                .frame(width: 8, height: 8)
                .shadow(
                    color: isRunning ? Color(red: 0.20, green: 0.94, blue: 0.43).opacity(0.9) : .white.opacity(0.08),
                    radius: isRunning ? 8 : 1,
                    x: 0,
                    y: 0
                )
        }
        .frame(width: 12, height: 12)
    }
}

private struct IconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white.opacity(configuration.isPressed ? 0.68 : 0.58))
            .frame(width: 18, height: 18)
            .background(Color.white.opacity(configuration.isPressed ? 0.08 : 0.035), in: Circle())
    }
}

private struct RefreshIcon: View {
    let isRefreshing: Bool

    var body: some View {
        Group {
            if isRefreshing {
                TimelineView(.animation) { context in
                    icon
                        .rotationEffect(.degrees(rotationAngle(at: context.date)))
                        .foregroundStyle(Color(red: 0.61, green: 0.95, blue: 0.68))
                }
            } else {
                icon
            }
        }
    }

    private var icon: some View {
        Image(systemName: "arrow.clockwise")
            .font(.system(size: 10, weight: .bold))
    }

    private func rotationAngle(at date: Date) -> Double {
        let cycle = 0.85
        let progress = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: cycle) / cycle
        return progress * 360
    }
}

private struct TaskRow: View {
    let task: CodexTask

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Text(task.title)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 4)

                Text(task.status.label)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(statusColor)
            }

            HStack(spacing: 6) {
                Text(task.detail)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.56))
                    .lineLimit(1)

                Spacer(minLength: 8)

                if task.activeSubagentCount > 0 {
                    Text("活跃子代理 \(task.activeSubagentCount)")
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .foregroundStyle(Color(red: 0.61, green: 0.95, blue: 0.68))
                        .lineLimit(1)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(
                            Color(red: 0.61, green: 0.95, blue: 0.68).opacity(0.11),
                            in: RoundedRectangle(cornerRadius: 4, style: .continuous)
                        )
                }

                Text(Formatters.compactTokens(task.tokenCount))
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.66))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
    }

    private var statusColor: Color {
        switch task.status {
        case .running:
            Color(red: 0.61, green: 0.95, blue: 0.68)
        case .recent:
            Color(red: 0.50, green: 0.78, blue: 1.00)
        case .idle:
            .white.opacity(0.48)
        }
    }
}

private struct RemoteAccountRow: View {
    let account: RemoteCodexAccount

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(account.state.color)
                .frame(width: 8, height: 8)
                .shadow(color: account.state.color.opacity(0.45), radius: 4, x: 0, y: 0)

            VStack(alignment: .leading, spacing: 4) {
                Text(account.displayName)
                    .font(.system(size: 10.5, weight: .bold))
                    .foregroundStyle(.white.opacity(0.90))
                    .lineLimit(1)
                    .truncationMode(.tail)

                HStack(spacing: 5) {
                    if let planLabel = account.planLabel {
                        Text(planLabel)
                            .font(.system(size: 8.5, weight: .heavy, design: .rounded))
                            .foregroundStyle(.black.opacity(0.84))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Color(red: 0.98, green: 0.86, blue: 0.36), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                    }

                    Text(account.detailText)
                        .font(.system(size: 9.3, weight: .medium))
                        .foregroundStyle(.white.opacity(0.50))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 4) {
                Text(account.stateReasonText)
                    .font(.system(size: 10, weight: .heavy))
                    .foregroundStyle(account.state.color)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                Text(account.quotaSummaryText)
                    .font(.system(size: 9.3, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(quotaColor)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(width: 102, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(height: 62)
        .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
    }

    private var quotaColor: Color {
        if account.quotaError != nil {
            return Color(red: 1.0, green: 0.55, blue: 0.25)
        }
        if account.quotaWindows.contains(where: \.reachesThreshold) {
            return Color(red: 1.0, green: 0.55, blue: 0.25)
        }
        return .white.opacity(0.62)
    }
}

private struct RemoteSummaryCell: View {
    let label: String
    let value: String

    var body: some View {
        VStack(spacing: 2) {
            Text(label)
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(.white.opacity(0.50))
            Text(value)
                .font(.system(size: 11, weight: .heavy, design: .rounded))
                .foregroundStyle(.white.opacity(0.90))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 7)
        .background(Color.white.opacity(0.026), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct PeriodUsageCell: View {
    let label: String
    let value: String

    var body: some View {
        VStack(spacing: 3) {
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.52))
            Text(value)
                .font(.system(size: 11, weight: .heavy, design: .rounded))
                .foregroundStyle(.white.opacity(0.92))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(Color.white.opacity(0.026), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
