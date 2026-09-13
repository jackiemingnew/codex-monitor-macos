import AppKit
import SwiftUI

enum DetailPage: String, CaseIterable, Identifiable {
    case codex
    case analytics
    case performance
    case skillInsights
    case codexRadar
    case remoteCodex
    case newAPI
    case subAPI

    var id: String { rawValue }

    var title: String {
        switch self {
        case .codex:
            "Codex"
        case .analytics:
            "Analytics"
        case .performance:
            "性能"
        case .skillInsights:
            "Skills"
        case .codexRadar:
            "Codex Radar"
        case .remoteCodex:
            "CLIProxyAPI"
        case .newAPI:
            "NewAPI"
        case .subAPI:
            "Sub2API"
        }
    }
}

private struct CollapsedMetric: Identifiable {
    let id: String
    let label: String
    let value: String
    let color: Color
    var labelWidth: CGFloat? = nil
    var valueWidth: CGFloat? = nil
    var helpText: String? = nil
}

private struct HUDVisualEffectView: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow
    var state: NSVisualEffectView.State = .active

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = state
        view.isEmphasized = false
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        view.blendingMode = blendingMode
        view.state = state
    }
}

struct NotchIslandView: View {
    @ObservedObject var viewModel: UsageViewModel
    @ObservedObject var remoteViewModel: RemoteMonitorViewModel
    @ObservedObject var newAPIViewModel: BalanceMonitorViewModel
    @ObservedObject var subAPIViewModel: BalanceMonitorViewModel
    @ObservedObject var settings: CodexNotchSettings
    @State private var pulse = false

    private var snapshot: UsageSnapshot {
        viewModel.snapshot
    }

    var body: some View {
        ZStack(alignment: .top) {
            collapsedContent
        }
        .frame(
            width: IslandMetrics.collapsedWidth,
            height: IslandMetrics.collapsedHeight,
            alignment: .top
        )
        .onAppear {
            pulse = true
        }
    }

    private var collapsedContent: some View {
        HStack(spacing: MonitorTheme.Spacing.inline) {
            statusBlock

            rateLimitBlock
        }
        .padding(.horizontal, IslandMetrics.collapsedPillHorizontalPadding)
        .padding(.top, 4)
        .frame(
            width: IslandMetrics.collapsedWidth,
            height: IslandMetrics.collapsedHeight - 8,
            alignment: .center
        )
        .background(collapsedBackground)
        .clipShape(RoundedRectangle(cornerRadius: MonitorTheme.Radius.collapsedPill, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: MonitorTheme.Radius.collapsedPill, style: .continuous))
        .shadow(color: .black.opacity(0.18), radius: 9, x: 0, y: 4)
        .frame(
            width: IslandMetrics.collapsedWidth,
            height: IslandMetrics.collapsedHeight,
            alignment: .top
        )
    }

    private var collapsedBackground: some View {
        ZStack {
            HUDVisualEffectView(material: .hudWindow)
            RoundedRectangle(cornerRadius: MonitorTheme.Radius.collapsedPill, style: .continuous)
                .fill(MonitorTheme.Pill.tint)
            RoundedRectangle(cornerRadius: MonitorTheme.Radius.collapsedPill, style: .continuous)
                .stroke(MonitorTheme.Pill.panelStroke, lineWidth: MonitorTheme.Stroke.panel)
        }
    }

    private var statusBlock: some View {
        HStack(spacing: 5) {
            if effectiveDisplaySource == .codex {
                StatusDot(isRunning: snapshot.isRunning, pulse: pulse, enablePulse: settings.enablePulse)
            } else {
                SeverityDot(severity: collapsedSeverity, pulse: pulse, enablePulse: settings.enablePulse)
            }
            Text(collapsedStateLabel)
                .font(.system(size: 10.6, weight: .semibold))
                .foregroundStyle(collapsedTitleColor)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .layoutPriority(1)
        .frame(width: collapsedStatusWidth, alignment: .leading)
    }

    private var rateLimitBlock: some View {
        HStack(spacing: MonitorTheme.Spacing.compact) {
            ForEach(collapsedMetrics) { metric in
                CollapsedMetricRow(metric: metric)
            }
        }
        .layoutPriority(2)
    }

    private var collapsedStatusWidth: CGFloat? {
        effectiveDisplaySource == .codex ? 46 : nil
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

    private var collapsedTitle: String {
        switch effectiveDisplaySource {
        case .automatic, .codex:
            "Codex"
        case .remoteCodex:
            "CLIProxyAPI"
        case .newAPI:
            "NewAPI"
        case .subAPI:
            "Sub2API"
        }
    }

    private var collapsedStateLabel: String {
        guard effectiveDisplaySource == .codex else {
            return collapsedTitle
        }
        return snapshot.isRunning ? "RUN" : "IDLE"
    }

    private var collapsedTitleColor: Color {
        if effectiveDisplaySource == .codex {
            return snapshot.isRunning ? MonitorTheme.Pill.textPrimary : MonitorTheme.Pill.textSecondary
        }
        switch collapsedSeverity {
        case .none:
            return MonitorTheme.Pill.textPrimary
        case .warning:
            return MonitorTheme.Pill.warning
        case .error:
            return MonitorTheme.Pill.critical
        }
    }

    private var collapsedSeverity: RemoteAlertSeverity {
        switch effectiveDisplaySource {
        case .automatic, .codex:
            .none
        case .remoteCodex:
            remoteViewModel.snapshot.panelSeverity
        case .newAPI:
            newAPIViewModel.snapshot.panelSeverity
        case .subAPI:
            subAPIViewModel.snapshot.panelSeverity
        }
    }

    private var collapsedMetrics: [CollapsedMetric] {
        switch effectiveDisplaySource {
        case .automatic, .codex:
            let todayUsage = HUDTodayUsageDisplay.resolve(snapshot: snapshot)
            var metrics = snapshot.mainQuotaWindows.map { window in
                CollapsedMetric(
                    id: "quota-\(window.id)",
                    label: window.compactLabel,
                    value: Formatters.percent(window.remainingPercent),
                    color: MonitorTheme.pillQuotaColor(for: window.remainingPercent),
                    labelWidth: 13,
                    valueWidth: 34
                )
            }
            metrics.append(
                CollapsedMetric(
                    id: "tok",
                    label: "Today",
                    value: todayUsage.tokenCount.map {
                        Formatters.compactTokensEnglish($0, isPartial: todayUsage.isPartial)
                    } ?? (todayUsage.isBackfilling ? "回填中" : "--"),
                    color: MonitorTheme.Pill.textPrimary,
                    labelWidth: 28,
                    valueWidth: 50,
                    helpText: todayUsage.helpText(label: "Today")
                )
            )
            return metrics
        case .remoteCodex:
            let remote = remoteViewModel.snapshot
            return [
                CollapsedMetric(id: "ok", label: "正", value: "\(remote.healthyCount)", color: MonitorTheme.Pill.healthy, labelWidth: 10, valueWidth: 18),
                CollapsedMetric(id: "bad", label: "异", value: "\(remote.quotaCount + remote.abnormalCount)", color: collapsedSeverity == .error ? MonitorTheme.Pill.critical : MonitorTheme.Pill.warning, labelWidth: 10, valueWidth: 18)
            ]
        case .newAPI:
            return balanceCollapsedMetrics(newAPIViewModel.snapshot)
        case .subAPI:
            return balanceCollapsedMetrics(subAPIViewModel.snapshot)
        }
    }

    private func balanceCollapsedMetrics(_ snapshot: BalanceMonitorSnapshot) -> [CollapsedMetric] {
        [
            CollapsedMetric(id: "\(snapshot.source.rawValue)-accounts", label: "账", value: "\(snapshot.accounts.count)", color: MonitorTheme.Pill.healthy, labelWidth: 10, valueWidth: 18),
            CollapsedMetric(id: "\(snapshot.source.rawValue)-amount", label: "余", value: snapshot.totalAmountText, color: MonitorTheme.Pill.textPrimary, labelWidth: 10, valueWidth: 52)
        ]
    }

}

private struct CollapsedMetricRow: View {
    let metric: CollapsedMetric

    @ViewBuilder
    var body: some View {
        if let helpText = metric.helpText {
            row
                .help(helpText)
                .accessibilityHint(helpText)
        } else {
            row
        }
    }

    private var row: some View {
        HStack(spacing: MonitorTheme.Spacing.compact) {
            Text(metric.label)
                .font(.system(size: 8.4, weight: .medium))
                .foregroundStyle(MonitorTheme.Pill.textTertiary)
                .lineLimit(1)
                .minimumScaleFactor(0.70)
                .frame(width: metric.labelWidth, alignment: .trailing)

            Text(metric.value)
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(metric.color)
                .lineLimit(1)
                .minimumScaleFactor(0.68)
                .monospacedDigit()
                .frame(width: metric.valueWidth, alignment: .leading)
        }
    }
}

struct DetailPanelView: View {
    @ObservedObject var viewModel: UsageViewModel
    @ObservedObject var antigravityQuotaViewModel: AntigravityQuotaViewModel
    @ObservedObject var agySidecarHealthViewModel: AGYSidecarHealthViewModel
    @ObservedObject var analyticsViewModel: CodexWebAnalyticsViewModel
    @ObservedObject var routingTelemetryViewModel: RoutingTelemetryViewModel
    @ObservedObject var performanceViewModel: PerformanceMonitorViewModel
    @ObservedObject var skillInsightsCoordinator: SkillInsightsFeatureCoordinator
    @ObservedObject var remoteViewModel: RemoteMonitorViewModel
    @ObservedObject var newAPIViewModel: BalanceMonitorViewModel
    @ObservedObject var subAPIViewModel: BalanceMonitorViewModel
    @ObservedObject var codexRadarViewModel: CodexRadarViewModel
    @ObservedObject var settings: CodexNotchSettings
    let onSettings: () -> Void
    let onAnalyticsBrowser: () -> Void
    let onOpenAssessmentReport: (RoutingAssessment) -> Void
    let onLocalRefresh: () -> Void
    let onRemoteRefresh: () -> Void
    let onNewAPIRefresh: () -> Void
    let onSubAPIRefresh: () -> Void
    let onCodexRadarRefresh: () -> Void
    let onPageSelected: (DetailPage) -> Void
    let onAnalyticsModeSelected: (AnalyticsDataMode) -> Void
    @State private var detailPage: DetailPage = .codex
    @State private var analyticsMode: AnalyticsDataMode = .official
    @State private var showsAllTaskRoots = false

    private var snapshot: UsageSnapshot {
        viewModel.snapshot
    }

    var body: some View {
        ZStack(alignment: .top) {
            BottomRoundedRectangle(radius: MonitorTheme.Radius.detailBottom)
                .fill(MonitorTheme.detailBackground)

            BottomRoundedRectangle(radius: MonitorTheme.Radius.detailBottom)
                .stroke(MonitorTheme.panelStroke, lineWidth: MonitorTheme.Stroke.panel)
                .shadow(color: .black.opacity(0.10), radius: 16, x: 0, y: 8)

            VStack(spacing: MonitorTheme.Spacing.section) {
                header
                pageSwitcher

                Group {
                    switch selectedPage {
                    case .codex:
                        localContent
                    case .analytics:
                        analyticsContent
                    case .performance:
                        performanceContent
                    case .skillInsights:
                        skillInsightsContent
                    case .codexRadar:
                        codexRadarContent
                    case .remoteCodex:
                        remoteContent
                    case .newAPI:
                        balanceContent(newAPIViewModel)
                    case .subAPI:
                        balanceContent(subAPIViewModel)
                    }
                }
                .frame(maxHeight: .infinity, alignment: .top)
            }
            .padding(.horizontal, MonitorTheme.Spacing.panel)
            .padding(.top, IslandMetrics.detailTopPadding)
            .padding(.bottom, IslandMetrics.detailBottomPadding)
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .frame(width: IslandMetrics.width, height: detailHeight)
        .clipShape(BottomRoundedRectangle(radius: MonitorTheme.Radius.detailBottom))
        .onAppear {
            onPageSelected(selectedPage)
        }
        .onChange(of: selectedPage) { _, page in
            onPageSelected(page)
        }
    }

    private var displayedTasks: [CodexTask] {
        HUDTaskPresentation.visibleRoots(
            from: snapshot.tasks,
            isExpanded: showsAllTaskRoots,
            limit: HUDTaskPresentation.defaultVisibleRootLimit
        )
    }

    private var totalRootCount: Int {
        snapshot.tasks.count
    }

    private var allRunningRootCount: Int {
        HUDTaskPresentation.runningRootCount(in: snapshot.tasks)
    }

    private var todayUsageDisplay: HUDTodayUsageDisplay {
        HUDTodayUsageDisplay.resolve(snapshot: snapshot)
    }

    private var taskTodayDenominator: Int? {
        HUDTaskPresentation.todayDenominator(snapshot: snapshot)
    }

    private var todayDayKey: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }

    private var residualLocalTokenCount: Int? {
        HUDTaskPresentation.residualLocalTokens(
            summary: snapshot.costUsage,
            tasks: snapshot.tasks,
            todayKey: todayDayKey
        )
    }

    private var showsResidualLocalRecord: Bool {
        showsAllTaskRoots && (residualLocalTokenCount ?? 0) > 0
    }

    private var taskCountSummary: String {
        HUDTaskPresentation.countSummary(
            runningCount: allRunningRootCount,
            visibleRootCount: displayedTasks.count,
            totalRootCount: totalRootCount
        )
    }

    private var detailHeight: CGFloat {
        let localHeight = IslandMetrics.detailHeight(
            taskRows: IslandMetrics.visibleTaskRows,
            showsPeriodUsage: settings.showPeriodUsage,
            showsSparkQuota: settings.showSparkQuota,
            showsAntigravityQuota: antigravityQuotaViewModel.snapshot.shouldDisplay
                || agySidecarHealthViewModel.shouldDisplay
        )
        guard settings.remoteMonitorEnabled else {
            let balanceRows = [
                settings.newAPIMonitorEnabled ? newAPIViewModel.snapshot.accounts.count : nil,
                settings.subAPIMonitorEnabled ? subAPIViewModel.snapshot.accounts.count : nil
            ].compactMap { $0 }
            guard !balanceRows.isEmpty else {
                return localHeight
            }
            return max(localHeight, IslandMetrics.remoteDetailHeight(accountRows: max(1, balanceRows.max() ?? 1)))
        }
        let rows = [
            remoteViewModel.snapshot.accounts.count,
            settings.newAPIMonitorEnabled ? newAPIViewModel.snapshot.accounts.count : nil,
            settings.subAPIMonitorEnabled ? subAPIViewModel.snapshot.accounts.count : nil
        ].compactMap { $0 }
        return max(
            localHeight,
            IslandMetrics.remoteDetailHeight(
                accountRows: max(1, rows.max() ?? 1),
                usesTallRows: remoteViewModel.snapshot.accounts.contains { $0.displayQuotaWindows.count > 2 }
            )
        )
    }

    private var header: some View {
        HStack(alignment: .center, spacing: MonitorTheme.Spacing.row) {
            Text(headerTitle)
                .font(MonitorTheme.Typography.detailTitle)
                .foregroundStyle(MonitorTheme.textPrimary)
                .lineLimit(1)
                .frame(height: IslandMetrics.detailHeaderHeight, alignment: .center)

            HStack(spacing: MonitorTheme.Spacing.compact) {
                Circle()
                    .fill(headerStatusColor)
                    .frame(width: 8, height: 8)
                    .accessibilityHidden(true)
                Text(headerStatus)
                    .font(MonitorTheme.Typography.detailStatus)
                    .foregroundStyle(headerStatusColor)
                    .lineLimit(1)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("状态")
            .accessibilityValue(headerStatus)

            Spacer(minLength: MonitorTheme.Spacing.row)

            HStack(spacing: MonitorTheme.Spacing.wide) {
                Button(action: refreshCurrentPage) {
                    RefreshIcon(isRefreshing: isCurrentPageRefreshing)
                }
                .buttonStyle(IconButtonStyle())
                .disabled(isCurrentPageRefreshing)
                .help(refreshHelp)
                .accessibilityLabel(refreshHelp)

                Button(action: onSettings) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(IconButtonStyle())
                .help("设置")
                .accessibilityLabel("打开监测设置")
            }
        }
        .frame(height: IslandMetrics.detailHeaderHeight, alignment: .center)
    }

    private var headerTitle: String {
        switch selectedPage {
        case .codex:
            "Codex Monitor"
        case .analytics:
            switch analyticsMode {
            case .official: "官方 Analytics"
            case .localTokens: "本地 Token Analytics"
            case .routing: "路由监测"
            }
        case .performance:
            "性能诊断"
        case .skillInsights:
            "Skill Insights"
        case .codexRadar:
            "Codex Radar"
        case .remoteCodex:
            "CLIProxyAPI 账号"
        case .newAPI:
            "NewAPI 余额"
        case .subAPI:
            "Sub2API 余额"
        }
    }

    private var headerStatus: String {
        switch selectedPage {
        case .codex:
            return snapshot.isRunning ? "运行中" : "空闲"
        case .analytics:
            switch analyticsMode {
            case .official: return analyticsViewModel.state.label
            case .localTokens: return localAnalyticsStatus
            case .routing: return routingTelemetryViewModel.manualState == .assessing ? "评估中" : routingTelemetryViewModel.dailyState.label
            }
        case .performance:
            if performanceViewModel.backgroundMonitoringEnabled {
                return "记录中"
            }
            return performanceViewModel.currentSample == nil ? "待采样" : "已关闭"
        case .skillInsights:
            return skillInsightsCoordinator.snapshot.quality.rawValue
        case .codexRadar:
            return codexRadarHeaderStatus
        case .remoteCodex:
            if remoteViewModel.snapshot.usageUnavailableForSource {
                return "仅账号"
            }
            if remoteViewModel.snapshot.usageMessage != nil {
                return "用量旧"
            }
            return remoteHeaderStatus
        case .newAPI:
            return balanceHeaderStatus(newAPIViewModel.snapshot)
        case .subAPI:
            return balanceHeaderStatus(subAPIViewModel.snapshot)
        }
    }

    private var headerStatusColor: Color {
        switch selectedPage {
        case .codex:
            snapshot.isRunning ? MonitorTheme.running : MonitorTheme.textTertiary
        case .analytics:
            switch analyticsMode {
            case .official: analyticsStatusColor
            case .localTokens: localAnalyticsStatusColor
            case .routing: routingTelemetryStatusColor
            }
        case .performance:
            performanceStatusColor
        case .skillInsights:
            skillInsightsQualityColor
        case .codexRadar:
            codexRadarHeaderStatusColor
        case .remoteCodex:
            remoteStatusColor
        case .newAPI:
            balanceStatusColor(newAPIViewModel.snapshot)
        case .subAPI:
            balanceStatusColor(subAPIViewModel.snapshot)
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
                ? MonitorTheme.healthy
                : MonitorTheme.warning
        case .warning:
            return MonitorTheme.warning
        case .error:
            return MonitorTheme.critical
        }
    }

    private var isCurrentPageRefreshing: Bool {
        switch selectedPage {
        case .codex:
            viewModel.isRefreshing || analyticsViewModel.isRefreshing
        case .analytics:
            switch analyticsMode {
            case .official: analyticsViewModel.isRefreshing
            case .localTokens: viewModel.isCostUsageRefreshing
            case .routing: routingTelemetryViewModel.dailyState == .loading || routingTelemetryViewModel.manualState == .assessing
            }
        case .performance:
            performanceViewModel.isRefreshing
        case .skillInsights:
            skillInsightsCoordinator.isAnalyzing
        case .codexRadar:
            codexRadarViewModel.isRefreshing
        case .remoteCodex:
            remoteViewModel.isRefreshing
        case .newAPI:
            newAPIViewModel.isRefreshing
        case .subAPI:
            subAPIViewModel.isRefreshing
        }
    }

    private var refreshHelp: String {
        switch selectedPage {
        case .codex:
            "刷新 Codex"
        case .analytics:
            switch analyticsMode {
            case .official: "刷新官方 Analytics"
            case .localTokens: "刷新本地 Token"
            case .routing: "刷新路由监测（轻量扫描）"
            }
        case .performance:
            "立即采样性能"
        case .skillInsights:
            "增量分析最近 7 天"
        case .codexRadar:
            "刷新 Codex Radar"
        case .remoteCodex:
            "刷新 CLIProxyAPI"
        case .newAPI:
            "刷新 NewAPI"
        case .subAPI:
            "刷新 Sub2API"
        }
    }

    private var pageSwitcher: some View {
        HStack(spacing: 2) {
            ForEach(availablePages) { page in
                PageSwitcherButton(
                    title: page.title,
                    isSelected: selectedPage == page
                ) {
                    detailPage = page
                }
            }
        }
        .frame(height: IslandMetrics.detailPageSwitcherHeight)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(MonitorTheme.separator)
                .frame(height: MonitorTheme.Stroke.hairline)
        }
    }

    private var availablePages: [DetailPage] {
        var pages: [DetailPage] = [.codex, .analytics, .performance]
        if settings.skillInsightsEnabled {
            pages.append(.skillInsights)
        }
        if settings.codexRadarEnabled {
            pages.append(.codexRadar)
        }
        if settings.remoteMonitorEnabled {
            pages.append(.remoteCodex)
        }
        if settings.newAPIMonitorEnabled {
            pages.append(.newAPI)
        }
        if settings.subAPIMonitorEnabled {
            pages.append(.subAPI)
        }
        return pages
    }

    private var selectedPage: DetailPage {
        availablePages.contains(detailPage) ? detailPage : .codex
    }

    private func refreshCurrentPage() {
        switch selectedPage {
        case .codex:
            onLocalRefresh()
        case .analytics:
            switch analyticsMode {
            case .official: analyticsViewModel.refresh(force: true)
            case .localTokens: viewModel.refreshLocalTokenAnalytics()
            case .routing: routingTelemetryViewModel.refreshLight()
            }
        case .performance:
            performanceViewModel.refreshNow()
        case .skillInsights:
            skillInsightsCoordinator.analyzeRecentWeek()
        case .codexRadar:
            onCodexRadarRefresh()
        case .remoteCodex:
            onRemoteRefresh()
        case .newAPI:
            onNewAPIRefresh()
        case .subAPI:
            onSubAPIRefresh()
        }
    }

    private var localContent: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(spacing: MonitorTheme.Spacing.row) {
                localQuotaSummary
                localDataProvenance
                if settings.showPeriodUsage {
                    costDisclosure
                }
                if settings.showSparkQuota {
                    sparkQuotaStrip
                }
                localTaskTable
                if antigravityQuotaViewModel.snapshot.shouldDisplay || agySidecarHealthViewModel.shouldDisplay {
                    antigravityQuotaStrip
                }

                CodexWebAnalyticsPanelView(
                    viewModel: analyticsViewModel,
                    onOpenAnalytics: {
                        detailPage = .analytics
                    },
                    onOpenBrowser: onAnalyticsBrowser
                )
            }
            .padding(.bottom, MonitorTheme.Spacing.compact)
        }
        .scrollIndicators(.hidden)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var performanceContent: some View {
        PerformancePanelView(viewModel: performanceViewModel)
    }

    private var analyticsContent: some View {
        VStack(spacing: MonitorTheme.Spacing.row) {
            Picker("Analytics 数据源", selection: $analyticsMode) {
                ForEach(AnalyticsDataMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityLabel("Analytics 数据源")

            Group {
                if analyticsMode == .official {
                    CodexWebAnalyticsChartView(
                        viewModel: analyticsViewModel,
                        onOpenBrowser: onAnalyticsBrowser
                    )
                } else if analyticsMode == .localTokens {
                    LocalTokenAnalyticsView(
                        summary: snapshot.costUsage,
                        isEnabled: settings.showPeriodUsage
                    )
                } else {
                    RoutingTelemetryView(viewModel: routingTelemetryViewModel, onOpenAssessmentReport: onOpenAssessmentReport)
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .onAppear {
            onAnalyticsModeSelected(analyticsMode)
        }
        .onChange(of: analyticsMode) { _, mode in
            onAnalyticsModeSelected(mode)
        }
    }

    private var localAnalyticsStatus: String {
        guard settings.showPeriodUsage else { return "未启用" }
        if viewModel.isCostUsageRefreshing {
            return "扫描中"
        }
        switch snapshot.costUsage.tokenQuality {
        case .complete:
            return "COMPLETE"
        case .partial:
            return "回填中"
        case .unavailable:
            return "无数据"
        }
    }

    private var localAnalyticsStatusColor: Color {
        guard settings.showPeriodUsage else { return MonitorTheme.textTertiary }
        if viewModel.isCostUsageRefreshing {
            return MonitorTheme.radarBaseline
        }
        switch snapshot.costUsage.tokenQuality {
        case .complete:
            return MonitorTheme.healthy
        case .partial:
            return MonitorTheme.warning
        case .unavailable:
            return MonitorTheme.textTertiary
        }
    }

    private var analyticsStatusColor: Color {
        switch analyticsViewModel.state {
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

    private var routingTelemetryStatusColor: Color {
        if routingTelemetryViewModel.manualState == .assessing {
            return MonitorTheme.warning
        }
        switch routingTelemetryViewModel.dailyState {
        case .ready:
            return MonitorTheme.healthy
        case .partial, .stale:
            return MonitorTheme.warning
        case .loading:
            return MonitorTheme.radarBaseline
        case .empty, .unavailable:
            return MonitorTheme.textTertiary
        }
    }

    private var performanceStatusColor: Color {
        guard performanceViewModel.backgroundMonitoringEnabled else {
            return MonitorTheme.textTertiary
        }
        switch performanceViewModel.severity {
        case .critical:
            return MonitorTheme.critical
        case .warning:
            return MonitorTheme.warning
        case .normal:
            return MonitorTheme.healthy
        case .unavailable:
            return MonitorTheme.textTertiary
        }
    }

    private var skillInsightsContent: some View {
        SkillInsightsPanelView(viewModel: skillInsightsCoordinator)
    }

    private var skillInsightsQualityColor: Color {
        switch skillInsightsCoordinator.snapshot.quality {
        case .complete:
            MonitorTheme.healthy
        case .partial:
            MonitorTheme.warning
        case .unavailable:
            MonitorTheme.textTertiary
        }
    }

    private var localQuotaSummary: some View {
        HStack(alignment: .top, spacing: 0) {
            weeklyQuotaSummary
                .frame(maxWidth: .infinity, alignment: .leading)

            Rectangle()
                .fill(MonitorTheme.separator)
                .frame(width: MonitorTheme.Stroke.hairline)
                .padding(.vertical, MonitorTheme.Spacing.compact)
                .padding(.horizontal, MonitorTheme.Spacing.wide)
                .accessibilityHidden(true)

            todayTokenSummary
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, MonitorTheme.Spacing.compact)
        .padding(.vertical, MonitorTheme.Spacing.section)
        .frame(height: snapshot.mainQuotaWindows.count > 1 ? 140 : 116)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("额度与今日 Token")
        .accessibilityValue(quotaSummaryAccessibilityText)
    }

    private var weeklyQuotaSummary: some View {
        let window = weeklyQuotaWindow
        return VStack(alignment: .leading, spacing: MonitorTheme.Spacing.compact) {
            Text(window.kind == .weekly ? "本周剩余额度" : "\(window.title)剩余额度")
                .font(MonitorTheme.Typography.quotaLabel)
                .foregroundStyle(MonitorTheme.textSecondary)
            Text(Formatters.percent(window.remainingPercent))
                .font(MonitorTheme.Typography.heroValue)
                .foregroundStyle(quotaColor(for: window.remainingPercent))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.72)
            CapsuleQuotaBar(value: window.remainingPercent, color: quotaColor(for: window.remainingPercent))
                .frame(maxWidth: 220)
            Text(quotaMetaText(for: window) ?? "重置时间未知")
                .font(MonitorTheme.Typography.quotaMeta)
                .foregroundStyle(MonitorTheme.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
                .help(quotaHelp(for: window))
            if let additional = snapshot.mainQuotaWindows.first(where: { $0.id != window.id }) {
                Text("\(additional.compactLabel) 剩余 \(Formatters.percent(additional.remainingPercent))")
                    .font(MonitorTheme.Typography.quotaMeta)
                    .foregroundStyle(MonitorTheme.textSecondary)
                    .help(quotaHelp(for: additional))
                    .accessibilityLabel(quotaHelp(for: additional))
            }
        }
        .frame(maxHeight: .infinity, alignment: .topLeading)
    }

    private var todayTokenSummary: some View {
        let today = HUDTodayUsageDisplay.resolve(snapshot: snapshot)
        return VStack(alignment: .leading, spacing: MonitorTheme.Spacing.compact) {
            Text("今日 Token")
                .font(MonitorTheme.Typography.quotaLabel)
                .foregroundStyle(MonitorTheme.textSecondary)
            Text(today.tokenCount.map { HUDTokenFormatter.compact($0) + (today.isPartial ? "*" : "") } ?? (today.isBackfilling ? "回填中" : "--"))
                .font(MonitorTheme.Typography.heroValue)
                .foregroundStyle(MonitorTheme.textPrimary)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.64)
                .help(todayTokenHelp)
                .accessibilityLabel("今日 Token")
                .accessibilityValue(todayTokenHelp)

            if settings.showPeriodUsage {
                VStack(alignment: .leading, spacing: MonitorTheme.Spacing.micro) {
                    periodSummaryLine(label: "近 7 天", value: sevenDayTokenText, help: periodTokenHelp(isSevenDays: true))
                    periodSummaryLine(label: "近 30 天", value: thirtyDayTokenText, help: periodTokenHelp(isSevenDays: false))
                }
            } else {
                Text("周期统计未启用")
                    .font(MonitorTheme.Typography.quotaMeta)
                    .foregroundStyle(MonitorTheme.textSecondary)
            }
        }
        .frame(maxHeight: .infinity, alignment: .topLeading)
    }

    private func periodSummaryLine(label: String, value: String, help: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: MonitorTheme.Spacing.inline) {
            Text(label)
                .font(MonitorTheme.Typography.periodLabel)
                .foregroundStyle(MonitorTheme.textSecondary)
            Text(value)
                .font(MonitorTheme.Typography.periodValue)
                .foregroundStyle(MonitorTheme.textPrimary)
                .monospacedDigit()
        }
        .help(help)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(help)
    }

    private var weeklyQuotaWindow: MainQuotaWindow {
        snapshot.mainQuotaWindows.first(where: { if case .weekly = $0.kind { return true }; return false })
            ?? snapshot.mainQuotaWindows.first
            ?? MainQuotaWindow(id: "weekly", fallbackKind: .weekly, remainingPercent: nil, resetsAt: nil, windowMinutes: 10_080)
    }

    private var sevenDayTokenText: String {
        HUDTokenFormatter.compact(snapshot.costUsage.sevenDays.tokenCount ?? snapshot.usage7d)
            + (snapshot.costUsage.sevenDays.tokenCount == nil && snapshot.periodUsageQuality.usage7dPartial ? "*" : "")
    }

    private var thirtyDayTokenText: String {
        HUDTokenFormatter.compact(snapshot.costUsage.thirtyDays.tokenCount ?? snapshot.usage30d)
            + (snapshot.costUsage.thirtyDays.tokenCount == nil && snapshot.periodUsageQuality.usage30dPartial ? "*" : "")
    }

    private var todayTokenHelp: String {
        let today = todayUsageDisplay
        let exact = today.tokenCount.map { "\($0) Token" } ?? "不可用"
        return "今日精确值 \(exact)。\(today.helpText(label: "今日") ?? "本机已发布 Token 总量；任务归因是否对齐见列表说明。")"
    }

    private func periodTokenHelp(isSevenDays: Bool) -> String {
        let window = isSevenDays ? snapshot.costUsage.sevenDays : snapshot.costUsage.thirtyDays
        let tokens = window.tokenCount ?? (isSevenDays ? snapshot.usage7d : snapshot.usage30d)
        let partial = window.tokenCount == nil && (isSevenDays ? snapshot.periodUsageQuality.usage7dPartial : snapshot.periodUsageQuality.usage30dPartial)
        let missing = isSevenDays ? snapshot.periodUsageQuality.missing7dBaselines : snapshot.periodUsageQuality.missing30dBaselines
        return "精确值 \(tokens) Token。\(Formatters.partialUsageHelp(label: isSevenDays ? "7天" : "30天", isPartial: partial, missingBaselineSessions: missing) ?? "本机本地自然日统计。")"
    }

    private var quotaSummaryAccessibilityText: String {
        let windows = snapshot.mainQuotaWindows.map(quotaHelp).joined(separator: "；")
        let periods = settings.showPeriodUsage ? "；近7天 \(periodTokenHelp(isSevenDays: true))；近30天 \(periodTokenHelp(isSevenDays: false))" : "；周期统计未启用"
        return "\(windows)；\(todayTokenHelp)\(periods)"
    }

    private func quotaHelp(for window: MainQuotaWindow) -> String {
        let value = window.remainingPercent.map { "剩余\($0)%" } ?? "剩余未知"
        let reset = quotaMetaText(for: window) ?? "重置时间未知"
        return "\(window.accessibilityLabel)：\(value)；\(reset)；来源 \(quotaSourceLabel)。"
    }

    private var costDisclosure: some View {
        DisclosureGroup {
            HStack(spacing: 0) {
                LocalCostCell(label: "今日", value: Formatters.apiEquivalentCost(snapshot.costUsage.today), helpText: Formatters.apiEquivalentCostHelp(label: "今日费用", window: snapshot.costUsage.today, summary: snapshot.costUsage))
                localPeriodDivider
                LocalCostCell(label: "近 7 天", value: Formatters.apiEquivalentCost(snapshot.costUsage.sevenDays), helpText: Formatters.apiEquivalentCostHelp(label: "近7天费用", window: snapshot.costUsage.sevenDays, summary: snapshot.costUsage))
                localPeriodDivider
                LocalCostCell(label: "近 30 天", value: Formatters.apiEquivalentCost(snapshot.costUsage.thirtyDays), helpText: Formatters.apiEquivalentCostHelp(label: "近30天费用", window: snapshot.costUsage.thirtyDays, summary: snapshot.costUsage))
            }
            .padding(.top, MonitorTheme.Spacing.compact)
        } label: {
            HStack(spacing: MonitorTheme.Spacing.inline) {
                Text("费用估算")
                    .font(MonitorTheme.Typography.periodLabel.weight(.semibold))
                    .foregroundStyle(MonitorTheme.accentBlue)
                Text("API 等值，非订阅账单")
                    .font(MonitorTheme.Typography.periodLabel)
                    .foregroundStyle(MonitorTheme.textSecondary)
                Spacer(minLength: 0)
            }
        }
        .disclosureGroupStyle(FlatDisclosureGroupStyle())
        .help(costDisclosureHelp)
        .accessibilityLabel("费用估算，API 等值，非订阅账单")
        .accessibilityHint(costDisclosureHelp)
    }

    private var costDisclosureHelp: String {
        "费用估算仅为 OpenAI API 标准单价等值，不是 ChatGPT 或 Codex 订阅账单。\(Formatters.apiEquivalentCostHelp(label: "今日费用", window: snapshot.costUsage.today, summary: snapshot.costUsage))"
    }

    private var localDataProvenance: some View {
        HStack(spacing: MonitorTheme.Spacing.compact) {
            Circle()
                .fill(quotaFreshnessColor)
                .frame(width: 5, height: 5)
                .accessibilityHidden(true)
            Text(quotaSourceLabel)
                .font(MonitorTheme.Typography.quotaMeta)
                .foregroundStyle(MonitorTheme.textSecondary)
                .lineLimit(1)
            Text("· \(quotaFreshnessLabel)")
                .font(MonitorTheme.Typography.quotaMeta)
                .foregroundStyle(quotaFreshnessColor)
                .lineLimit(1)
            Spacer(minLength: MonitorTheme.Spacing.row)
            if let resetCreditCount = snapshot.resetCreditCount {
                let expiryText = snapshot.resetCreditExpiryNotice.flatMap {
                    Formatters.resetCreditExpiryText($0.earliestExpiresAt)
                }
                let resetCreditHelp = Formatters.resetCreditHelp(
                    availableCount: resetCreditCount,
                    notice: snapshot.resetCreditExpiryNotice,
                    expiryText: expiryText
                )
                Text(expiryText.map { "重置 \(resetCreditCount)次 · \($0)" } ?? "重置 \(resetCreditCount)次")
                    .font(MonitorTheme.Typography.quotaMeta)
                    .foregroundStyle(expiryText == nil ? MonitorTheme.textSecondary : MonitorTheme.warning)
                    .lineLimit(1)
                    .minimumScaleFactor(0.68)
                    .help(resetCreditHelp)
                    .accessibilityLabel(resetCreditHelp)
            }
            if let capturedAt = snapshot.rateLimitCapturedAt {
                Text("\(Formatters.relativeAge(capturedAt))前更新")
                    .font(MonitorTheme.Typography.quotaMeta)
                    .foregroundStyle(MonitorTheme.textTertiary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, MonitorTheme.Spacing.inline)
        .frame(height: IslandMetrics.detailProvenanceHeight)
        .accessibilityElement(children: .combine)
    }

    private var sparkQuotaStrip: some View {
        HStack(spacing: MonitorTheme.Spacing.row) {
            Text("Spark")
                .font(MonitorTheme.Typography.sparkLabel)
                .foregroundStyle(MonitorTheme.textPrimary)
                .lineLimit(1)

            if snapshot.sparkQuotaWindows.isEmpty {
                Text("--")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(MonitorTheme.textTertiary)
            } else {
                ForEach(snapshot.sparkQuotaWindows) { window in
                    SparkQuotaChip(window: window)
                }
            }

            SparkMetricChip(label: "Sessions", value: "\(displayedTasks.count)")
            SparkMetricChip(label: "Subagents", value: "\(activeSubagentTotal)")

            Spacer(minLength: 0)
        }
        .padding(.horizontal, MonitorTheme.Spacing.panel)
        .frame(height: IslandMetrics.detailSparkHeight)
        .background(MonitorTheme.sectionFill, in: RoundedRectangle(cornerRadius: MonitorTheme.Radius.row, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: MonitorTheme.Radius.row, style: .continuous)
                .stroke(MonitorTheme.hairline, lineWidth: MonitorTheme.Stroke.hairline)
        )
    }

    private var antigravityQuotaStrip: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: MonitorTheme.Spacing.inline) {
                Text("AGY")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(MonitorTheme.textPrimary)
                Text("剩余额度")
                    .font(MonitorTheme.Typography.quotaLabel)
                    .foregroundStyle(MonitorTheme.textSecondary)
                Text(antigravityQuotaViewModel.snapshot.freshnessLabel)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(antigravityQuotaColor)
                    .lineLimit(1)
                Spacer(minLength: MonitorTheme.Spacing.row)
                HStack(spacing: MonitorTheme.Spacing.compact) {
                    Image(systemName: agySidecarIndicatorSymbol)
                        .font(.system(size: 15, weight: .semibold))
                    Text("旁路 \(agySidecarHealthViewModel.indicatorLabel)")
                        .font(MonitorTheme.Typography.detailStatus)
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                }
                .foregroundStyle(agySidecarIndicatorColor)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("旁路状态")
                .accessibilityValue(agySidecarHealthViewModel.accessibilitySummary)
            }
            .frame(height: 30)

            Rectangle()
                .fill(MonitorTheme.separator)
                .frame(height: MonitorTheme.Stroke.hairline)

            AntigravityQuotaRow(
                pool: .primary,
                fiveHour: antigravityQuotaViewModel.snapshot.primaryFiveHour,
                sevenDay: antigravityQuotaViewModel.snapshot.primarySevenDay
            )
            AntigravityQuotaRow(
                pool: .secondary,
                fiveHour: antigravityQuotaViewModel.snapshot.secondaryFiveHour,
                sevenDay: antigravityQuotaViewModel.snapshot.secondarySevenDay
            )
            if let message = antigravityQuotaViewModel.snapshot.message,
               antigravityQuotaViewModel.snapshot.primaryFiveHour == nil {
                Text(message)
                    .font(MonitorTheme.Typography.quotaMeta)
                    .foregroundStyle(MonitorTheme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, MonitorTheme.Spacing.compact)
            }
        }
        .padding(.horizontal, MonitorTheme.Spacing.panel)
        .padding(.vertical, MonitorTheme.Spacing.compact)
        .frame(minHeight: IslandMetrics.detailAntigravityQuotaHeight)
        .background(MonitorTheme.detailBackground)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(MonitorTheme.separator)
                .frame(height: MonitorTheme.Stroke.hairline)
        }
        .help(antigravityQuotaHelp)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(antigravityQuotaHelp)
    }

    private var antigravityQuotaColor: Color {
        switch antigravityQuotaViewModel.snapshot.availability {
        case .fresh:
            MonitorTheme.healthy
        case .stale:
            MonitorTheme.warning
        case .hidden, .loading, .unavailable:
            MonitorTheme.textTertiary
        }
    }

    private var agySidecarIndicatorColor: Color {
        if agySidecarHealthViewModel.isDoctorChecking || agySidecarHealthViewModel.isCanaryRunning {
            return MonitorTheme.radarBaseline
        }
        if agySidecarHealthViewModel.e2eSnapshot.status == .broken
            || agySidecarHealthViewModel.doctorSnapshot.status == .broken {
            return MonitorTheme.critical
        }
        if agySidecarHealthViewModel.doctorSnapshot.status == .unavailable {
            return MonitorTheme.textTertiary
        }
        if agySidecarHealthViewModel.doctorSnapshot.status == .compatibilityWarning {
            return MonitorTheme.warning
        }
        switch agySidecarHealthViewModel.e2eSnapshot.status {
        case .complete:
            return MonitorTheme.healthy
        case .partial:
            return MonitorTheme.warning
        case .broken:
            return MonitorTheme.critical
        case .unavailable:
            return MonitorTheme.textTertiary
        case .neverRun:
            switch agySidecarHealthViewModel.doctorSnapshot.status {
            case .ready: return MonitorTheme.healthy
            case .compatibilityWarning: return MonitorTheme.warning
            case .broken: return MonitorTheme.critical
            case .unavailable, .neverRun: return MonitorTheme.textTertiary
            }
        }
    }

    private var agySidecarIndicatorSymbol: String {
        switch agySidecarHealthViewModel.indicatorLabel {
        case "COMPLETE", "自检通过":
            return "checkmark.circle.fill"
        case "验收中", "自检中":
            return "arrow.triangle.2.circlepath"
        case "BROKEN", "PARTIAL", "兼容待确认", "自检不可用", "验收不可用":
            return "exclamationmark.triangle.fill"
        default:
            return "questionmark.circle"
        }
    }

    private var antigravityQuotaHelp: String {
        let snapshot = antigravityQuotaViewModel.snapshot
        let windows: [(AntigravityQuotaPool, AntigravityQuotaPeriod, AntigravityQuotaWindow?)] = [
            (.primary, .fiveHour, snapshot.primaryFiveHour),
            (.primary, .sevenDay, snapshot.primarySevenDay),
            (.secondary, .fiveHour, snapshot.secondaryFiveHour),
            (.secondary, .sevenDay, snapshot.secondarySevenDay)
        ]
        let descriptions = windows.map { pool, period, window in
            let percent = window?.remainingPercent.map { "\($0)%" } ?? "暂无"
            let reset = window.flatMap { Formatters.quotaResetText($0.resetsAt, style: .time) }
                .map { "，重置 \($0)" } ?? ""
            return "\(pool.label) \(period.label) 剩余 \(percent)\(reset)"
        }
        let timestamp = (snapshot.sourceUpdatedAt ?? snapshot.receivedAt)
            .map { "数据时间：\(Formatters.relativeAge($0))前" }
        let status = [snapshot.freshnessLabel, snapshot.message, timestamp].compactMap { value in
            guard let value, !value.isEmpty else { return nil }
            return value
        }.joined(separator: "，")
        let statusText = status.isEmpty ? "状态暂无" : "状态：\(status)"
        return "AGY 配额：\(descriptions.joined(separator: "；"))。\(statusText)。仅通过本轮 AGY 本地会话的 127.0.0.1 探测读取；不读取或保存账号、身份、令牌或原始输出。\(agySidecarHealthViewModel.accessibilitySummary)"
    }

    private var localTaskTable: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("任务")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(MonitorTheme.textPrimary)
                Spacer(minLength: MonitorTheme.Spacing.row)
                Text(taskCountSummary)
                    .font(MonitorTheme.Typography.tableHeader)
                    .foregroundStyle(MonitorTheme.textSecondary)
                    .monospacedDigit()
            }
            .padding(.horizontal, MonitorTheme.Spacing.panel)
            .frame(height: 34)

            TaskTableHeader(
                showContextMetrics: settings.showContextMetrics,
                usesPublishedTodayLedger: snapshot.costUsage.hasReconciledTodayLedger
            )
            Rectangle()
                .fill(MonitorTheme.separator)
                .frame(height: MonitorTheme.Stroke.hairline)

            if displayedTasks.isEmpty {
                emptyState
                    .padding(.top, 8)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(displayedTasks) { task in
                        TaskTableRow(
                            task: task,
                            todayTotalTokens: taskTodayDenominator,
                            showContextMetrics: settings.showContextMetrics
                        )
                    }
                    if showsResidualLocalRecord, let residualLocalTokenCount {
                        OtherLocalRecordRow(
                            tokenCount: residualLocalTokenCount,
                            todayTotalTokens: taskTodayDenominator,
                            showContextMetrics: settings.showContextMetrics
                        )
                    }
                }
                .frame(height: showsAllTaskRoots
                    ? CGFloat(displayedTasks.count) * IslandMetrics.detailTaskRowHeight
                        + (showsResidualLocalRecord ? IslandMetrics.detailTaskRowHeight : 0)
                    : IslandMetrics.visibleTaskRowsHeight,
                    alignment: .top)
            }

            if HUDTaskPresentation.canExpand(rootCount: totalRootCount, residualTokens: residualLocalTokenCount) {
                Button {
                    showsAllTaskRoots.toggle()
                } label: {
                    HStack(spacing: MonitorTheme.Spacing.compact) {
                        Text(showsAllTaskRoots ? "收起" : "查看全部")
                            .font(.system(size: 12, weight: .medium))
                        Image(systemName: showsAllTaskRoots ? "chevron.up" : "chevron.right")
                            .font(.system(size: 10, weight: .bold))
                    }
                    .foregroundStyle(MonitorTheme.accentBlue)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.horizontal, MonitorTheme.Spacing.panel)
                    .frame(height: 32)
                }
                .buttonStyle(.plain)
                .focusable()
                .accessibilityLabel(showsAllTaskRoots ? "收起任务根列表" : "查看全部任务根")
                .accessibilityValue("当前显示 \(displayedTasks.count) / \(totalRootCount) 个根任务")
                .accessibilityHint("只展开当前已发布快照中的根任务，不启动新的扫描")
            }

            Text(HUDTaskPresentation.todayCaption(isReconciled: snapshot.costUsage.hasReconciledTodayLedger))
                .font(MonitorTheme.Typography.quotaMeta)
                .foregroundStyle(MonitorTheme.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, MonitorTheme.Spacing.panel)
                .frame(minHeight: 26, alignment: .center)
                .help(taskTodayHelp)
                .accessibilityLabel(taskTodayHelp)

            Spacer(minLength: 0)
        }
        .frame(minHeight: IslandMetrics.taskTableHeight(taskRows: IslandMetrics.visibleTaskRows))
        .background(MonitorTheme.detailBackground)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(MonitorTheme.separator)
                .frame(height: MonitorTheme.Stroke.hairline)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("任务列表")
        .accessibilityValue(taskTodayHelp)
    }

    private var taskTodayHelp: String {
        var text = HUDTaskPresentation.todayCaption(isReconciled: snapshot.costUsage.hasReconciledTodayLedger)
        if snapshot.costUsage.hasReconciledTodayLedger {
            text += "；当前显示 \(displayedTasks.count) / \(totalRootCount) 个可用根任务。"
            if showsResidualLocalRecord {
                text += "其他本地记录汇总行不计入任务个数。"
            }
        } else {
            text += "；当前为现有本地日快照暂估值，尚未与完整发布账本对齐。"
        }
        return text
    }

    private var runningTaskCount: Int {
        displayedTasks.filter { $0.status == .running }.count
    }

    private var activeSubagentTotal: Int {
        displayedTasks.reduce(0) { $0 + $1.activeSubagentCount }
    }

    private var currentContextTask: CodexTask? {
        displayedTasks.first { $0.contextInputTokens != nil && $0.contextWindowTokens != nil }
    }

    private var currentContextPercentText: String {
        Formatters.percent(currentContextTask?.contextPercent)
    }

    private var currentContextTokenRatioText: String {
        Formatters.compactTokenRatio(
            currentContextTask?.contextInputTokens,
            currentContextTask?.contextWindowTokens
        )
    }

    private func quotaColor(for percent: Int?) -> Color {
        MonitorTheme.quotaColor(for: percent)
    }

    private func quotaResetText(
        for resetAt: Int?,
        percent: Int?,
        style: Formatters.QuotaResetDisplayStyle
    ) -> String? {
        guard percent != nil else {
            return nil
        }
        return Formatters.quotaResetText(resetAt, style: style)
    }

    private func quotaMetaText(for window: MainQuotaWindow, now: Date = Date()) -> String? {
        let resetText = quotaResetText(
            for: window.resetsAt,
            percent: window.remainingPercent,
            style: window.usesDateResetStyle ? .date : .time
        )
        let paceText: String?
        if let pace = QuotaPace.calculate(
            remainingPercent: window.remainingPercent,
            resetsAt: window.resetsAt,
            windowMinutes: window.effectiveWindowMinutes,
            now: now
        ) {
            switch pace.outcome {
            case .sustainable:
                paceText = "按当前速度可用到恢复"
            case let .exhaustsBeforeReset(date):
                paceText = "预计\(Formatters.compactDuration(until: date, now: now))后耗尽"
            }
        } else {
            paceText = nil
        }
        let parts = [resetText, paceText].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var quotaSourceLabel: String {
        switch snapshot.monitorStats.lastRateLimitSource {
        case "app-server-fresh", "app-server-stale":
            "额度：Codex app-server"
        case "local-jsonl":
            "额度：本地 JSONL"
        default:
            "额度来源不可用"
        }
    }

    private var quotaFreshness: RefreshFreshness {
        switch snapshot.monitorStats.lastRateLimitSource {
        case "app-server-stale":
            return .stale
        case "app-server-fresh":
            return AdaptiveRefreshPolicy.freshness(
                lastSuccessfulAt: snapshot.rateLimitCapturedAt,
                maximumAge: 5 * 60
            )
        case "local-jsonl":
            return AdaptiveRefreshPolicy.freshness(
                lastSuccessfulAt: snapshot.rateLimitCapturedAt,
                maximumAge: 15 * 60
            )
        default:
            return .unavailable
        }
    }

    private var quotaFreshnessLabel: String {
        switch quotaFreshness {
        case .fresh:
            "新鲜"
        case .stale:
            "缓存"
        case .expired:
            "可能过期"
        case .unavailable:
            "不可用"
        }
    }

    private var quotaFreshnessColor: Color {
        switch quotaFreshness {
        case .fresh:
            MonitorTheme.healthy
        case .stale:
            MonitorTheme.warning
        case .expired:
            MonitorTheme.critical
        case .unavailable:
            MonitorTheme.textTertiary
        }
    }

    private var codexRadarHeaderStatus: String {
        switch codexRadarViewModel.snapshot.panelState {
        case .disabled:
            "Off"
        case .loading:
            "Loading"
        case .ready:
            "Updated"
        case .stale:
            "Stale"
        case .error:
            "Error"
        }
    }

    private var codexRadarHeaderStatusColor: Color {
        switch codexRadarViewModel.snapshot.panelState {
        case .disabled, .loading:
            MonitorTheme.textTertiary
        case .ready:
            MonitorTheme.healthy
        case .stale:
            MonitorTheme.warning
        case .error:
            MonitorTheme.critical
        }
    }

    private var codexRadarContent: some View {
        CodexRadarPanelView(radar: codexRadarViewModel.snapshot)
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

    private func balanceContent(_ balanceViewModel: BalanceMonitorViewModel) -> some View {
        VStack(spacing: 8) {
            balanceSummary(balanceViewModel.snapshot)

            Group {
                if balanceViewModel.snapshot.accounts.isEmpty {
                    balanceMessage(balanceViewModel.snapshot)
                } else {
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(spacing: 7) {
                            if let message = balanceViewModel.snapshot.message {
                                inlineWarningMessage(message)
                            }
                            ForEach(balanceViewModel.snapshot.accounts) { account in
                                BalanceAccountRow(account: account)
                            }
                        }
                    }
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)

            balanceTotals(balanceViewModel.snapshot)
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
                .foregroundStyle(MonitorTheme.textSecondary)
                .lineLimit(2)
            Spacer()
        }
        .padding(.horizontal, 10)
        .frame(minHeight: 50)
        .background(MonitorTheme.rowFill, in: RoundedRectangle(cornerRadius: MonitorTheme.Radius.row, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: MonitorTheme.Radius.row, style: .continuous)
                .stroke(MonitorTheme.hairline, lineWidth: MonitorTheme.Stroke.hairline)
        )
    }

    @ViewBuilder
    private var cpaUsageSummary: some View {
        if remoteViewModel.snapshot.usageUnavailableForSource {
            HStack(spacing: 8) {
                PeriodUsageCell(label: "来源", value: "CLIProxyAPI")
                PeriodUsageCell(label: "账号", value: "\(remoteViewModel.snapshot.accounts.count)")
                PeriodUsageCell(label: "用量", value: "未提供")
            }
        } else {
            HStack(spacing: 8) {
                PeriodUsageCell(label: "24小时", value: HUDTokenFormatter.compact(remoteViewModel.snapshot.usage24h))
                PeriodUsageCell(label: "7天", value: HUDTokenFormatter.compact(remoteViewModel.snapshot.usage7d))
                PeriodUsageCell(label: "30天", value: HUDTokenFormatter.compact(remoteViewModel.snapshot.usage30d))
            }
        }
    }

    private func balanceSummary(_ snapshot: BalanceMonitorSnapshot) -> some View {
        HStack(spacing: 8) {
            RemoteSummaryCell(label: "正常", value: "\(snapshot.healthyCount)")
            RemoteSummaryCell(label: "提醒", value: "\(snapshot.warningCount)")
            RemoteSummaryCell(label: "异常", value: "\(snapshot.errorCount)")
        }
    }

    private func balanceTotals(_ snapshot: BalanceMonitorSnapshot) -> some View {
        HStack(spacing: 8) {
            PeriodUsageCell(label: "账户", value: "\(snapshot.accounts.count)")
            PeriodUsageCell(label: "余额", value: snapshot.totalAmountText)
            PeriodUsageCell(label: "提醒", value: "\(snapshot.warningCount + snapshot.errorCount)")
        }
    }

    private func balanceMessage(_ snapshot: BalanceMonitorSnapshot) -> some View {
        HStack {
            Text(snapshot.message ?? "暂无账户")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(MonitorTheme.textSecondary)
                .lineLimit(2)
            Spacer()
        }
        .padding(.horizontal, 10)
        .frame(minHeight: 50)
        .background(MonitorTheme.rowFill, in: RoundedRectangle(cornerRadius: MonitorTheme.Radius.row, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: MonitorTheme.Radius.row, style: .continuous)
                .stroke(MonitorTheme.hairline, lineWidth: MonitorTheme.Stroke.hairline)
        )
    }

    private func inlineWarningMessage(_ message: String) -> some View {
        HStack {
            Text(message)
                .font(.system(size: 9.6, weight: .semibold))
                .foregroundStyle(MonitorTheme.warning)
                .lineLimit(2)
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(MonitorTheme.warning.opacity(0.08), in: RoundedRectangle(cornerRadius: MonitorTheme.Radius.row, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: MonitorTheme.Radius.row, style: .continuous)
                .stroke(MonitorTheme.warning.opacity(0.16), lineWidth: MonitorTheme.Stroke.hairline)
        )
    }

    private func balanceHeaderStatus(_ snapshot: BalanceMonitorSnapshot) -> String {
        switch snapshot.panelState {
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

    private func balanceStatusColor(_ snapshot: BalanceMonitorSnapshot) -> Color {
        switch snapshot.panelSeverity {
        case .none:
            MonitorTheme.healthy
        case .warning:
            MonitorTheme.warning
        case .error:
            MonitorTheme.critical
        }
    }

    private var emptyState: some View {
        HStack {
            Text(snapshot.errorMessage ?? "暂无 Codex 活动")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(MonitorTheme.textSecondary)
                .lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, 10)
        .frame(height: 36)
        .background(MonitorTheme.rowFill, in: RoundedRectangle(cornerRadius: MonitorTheme.Radius.row, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: MonitorTheme.Radius.row, style: .continuous)
                .stroke(MonitorTheme.hairline, lineWidth: MonitorTheme.Stroke.hairline)
        )
    }

    private var periodUsage: some View {
        let todayUsage = HUDTodayUsageDisplay.resolve(snapshot: snapshot)
        return HStack(spacing: 0) {
            LocalPeriodUsageCell(
                label: "今日",
                value: todayUsage.tokenCount.map {
                    Formatters.compactTokens($0, isPartial: todayUsage.isPartial)
                } ?? (todayUsage.isBackfilling ? "回填中" : "--"),
                helpText: todayUsage.helpText(label: "今日"),
                costValue: Formatters.apiEquivalentCost(snapshot.costUsage.today),
                costHelpText: Formatters.apiEquivalentCostHelp(
                    label: "今日费用",
                    window: snapshot.costUsage.today,
                    summary: snapshot.costUsage
                )
            )
            localPeriodDivider
            LocalPeriodUsageCell(
                label: "7天",
                value: Formatters.compactTokens(
                    snapshot.costUsage.sevenDays.tokenCount ?? snapshot.usage7d,
                    isPartial: snapshot.costUsage.sevenDays.tokenCount == nil
                        && snapshot.periodUsageQuality.usage7dPartial
                ),
                helpText: Formatters.partialUsageHelp(
                    label: "7天",
                    isPartial: snapshot.costUsage.sevenDays.tokenCount == nil
                        && snapshot.periodUsageQuality.usage7dPartial,
                    missingBaselineSessions: snapshot.periodUsageQuality.missing7dBaselines
                ),
                costValue: Formatters.apiEquivalentCost(snapshot.costUsage.sevenDays),
                costHelpText: Formatters.apiEquivalentCostHelp(
                    label: "近 7 天费用",
                    window: snapshot.costUsage.sevenDays,
                    summary: snapshot.costUsage
                )
            )
            localPeriodDivider
            LocalPeriodUsageCell(
                label: "30天",
                value: Formatters.compactTokens(
                    snapshot.costUsage.thirtyDays.tokenCount ?? snapshot.usage30d,
                    isPartial: snapshot.costUsage.thirtyDays.tokenCount == nil
                        && snapshot.periodUsageQuality.usage30dPartial
                ),
                helpText: Formatters.partialUsageHelp(
                    label: "30天",
                    isPartial: snapshot.costUsage.thirtyDays.tokenCount == nil
                        && snapshot.periodUsageQuality.usage30dPartial,
                    missingBaselineSessions: snapshot.periodUsageQuality.missing30dBaselines
                ),
                costValue: Formatters.apiEquivalentCost(snapshot.costUsage.thirtyDays),
                costHelpText: Formatters.apiEquivalentCostHelp(
                    label: "近 30 天费用",
                    window: snapshot.costUsage.thirtyDays,
                    summary: snapshot.costUsage
                )
            )
        }
        .frame(height: IslandMetrics.detailPeriodFooterHeight)
        .background(MonitorTheme.sectionFill, in: RoundedRectangle(cornerRadius: MonitorTheme.Radius.section, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: MonitorTheme.Radius.section, style: .continuous)
                .stroke(MonitorTheme.hairline, lineWidth: MonitorTheme.Stroke.hairline)
        )
        .padding(.top, MonitorTheme.Spacing.compact)
    }

    private var localPeriodDivider: some View {
        Rectangle()
            .fill(MonitorTheme.separator)
            .frame(width: MonitorTheme.Stroke.hairline)
            .padding(.vertical, MonitorTheme.Spacing.row)
    }
}

private struct PageSwitcherButton: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                RoundedRectangle(cornerRadius: MonitorTheme.Radius.segment, style: .continuous)
                    .fill(isSelected ? MonitorTheme.controlSelectedFill : Color.clear)

                Text(title)
                    .font(isSelected ? MonitorTheme.Typography.detailTabSelected : MonitorTheme.Typography.detailTab)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }
            .frame(maxWidth: .infinity)
            .frame(height: IslandMetrics.detailPageSwitcherHeight - 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .foregroundStyle(isSelected ? MonitorTheme.accentBlue : MonitorTheme.textSecondary)
    }
}

private struct FlatDisclosureGroupStyle: DisclosureGroupStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                configuration.isExpanded.toggle()
            } label: {
                HStack(spacing: MonitorTheme.Spacing.inline) {
                    configuration.label
                    Spacer(minLength: MonitorTheme.Spacing.row)
                    Image(systemName: configuration.isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(MonitorTheme.accentBlue)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusable()
            .accessibilityValue(configuration.isExpanded ? "已展开" : "已折叠")

            if configuration.isExpanded {
                configuration.content
            }
        }
    }
}

private struct LocalCostCell: View {
    let label: String
    let value: String
    let helpText: String

    var body: some View {
        VStack(alignment: .leading, spacing: MonitorTheme.Spacing.micro) {
            Text(label)
                .font(MonitorTheme.Typography.quotaMeta)
                .foregroundStyle(MonitorTheme.textSecondary)
            Text(value)
                .font(MonitorTheme.Typography.periodValue)
                .foregroundStyle(MonitorTheme.textPrimary)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(helpText)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label)费用")
        .accessibilityValue("\(value)。\(helpText)")
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
                    .stroke(MonitorTheme.Pill.running.opacity(0.18), lineWidth: 3)
                    .frame(width: 8, height: 8)
                    .scaleEffect(pulse ? 1.34 : 0.95)
                    .opacity(pulse ? 0.12 : 0.34)
                    .animation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true), value: pulse)
            }

            Circle()
                .fill(isRunning ? MonitorTheme.Pill.running : MonitorTheme.Pill.neutral)
                .frame(width: 8, height: 8)
                .shadow(
                    color: isRunning ? MonitorTheme.Pill.running.opacity(0.34) : .white.opacity(0.06),
                    radius: isRunning ? 4 : 1,
                    x: 0,
                    y: 0
                )
        }
        .frame(width: 12, height: 12)
    }
}

private struct SeverityDot: View {
    let severity: RemoteAlertSeverity
    let pulse: Bool
    let enablePulse: Bool

    var body: some View {
        ZStack {
            if severity != .none && enablePulse {
                Circle()
                    .stroke(color.opacity(0.20), lineWidth: 3)
                    .frame(width: 8, height: 8)
                    .scaleEffect(pulse ? 1.34 : 0.95)
                    .opacity(pulse ? 0.14 : 0.34)
                    .animation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true), value: pulse)
            }

            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
                .shadow(color: color.opacity(severity == .none ? 0.08 : 0.42), radius: severity == .none ? 1 : 4, x: 0, y: 0)
        }
        .frame(width: 12, height: 12)
    }

    private var color: Color {
        switch severity {
        case .none:
            MonitorTheme.Pill.neutral
        case .warning:
            MonitorTheme.Pill.warning
        case .error:
            MonitorTheme.Pill.critical
        }
    }
}

private struct IconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(configuration.isPressed ? MonitorTheme.textPrimary : MonitorTheme.textSecondary)
            .frame(width: 22, height: 22)
            .background(
                configuration.isPressed ? MonitorTheme.controlFill : Color.clear,
                in: RoundedRectangle(cornerRadius: MonitorTheme.Radius.chip, style: .continuous)
            )
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
                        .foregroundStyle(MonitorTheme.textPrimary)
                }
            } else {
                icon
            }
        }
    }

    private var icon: some View {
        Image(systemName: "arrow.clockwise")
            .font(.system(size: 12, weight: .semibold))
    }

    private func rotationAngle(at date: Date) -> Double {
        let cycle = 0.85
        let progress = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: cycle) / cycle
        return progress * 360
    }
}

private struct QuotaBarCell: View {
    let label: String
    let value: String
    let percent: Int?
    let metaText: String?
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: MonitorTheme.Spacing.compact) {
            HStack(alignment: .firstTextBaseline, spacing: MonitorTheme.Spacing.inline) {
                Text(label)
                    .font(MonitorTheme.Typography.quotaLabel)
                    .foregroundStyle(MonitorTheme.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
                    .allowsTightening(true)
                    .layoutPriority(0.8)
                Spacer(minLength: MonitorTheme.Spacing.compact)
                Text(value)
                    .font(MonitorTheme.Typography.quotaValue)
                    .foregroundStyle(color)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .allowsTightening(true)
                    .layoutPriority(2)
            }

            CapsuleQuotaBar(value: percent, color: color)

            Text(metaText ?? " ")
                .font(MonitorTheme.Typography.quotaMeta)
                .foregroundStyle(MonitorTheme.textTertiary)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
                .allowsTightening(true)
                .truncationMode(.tail)
                .opacity(metaText == nil ? 0 : 1)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .accessibilityHidden(metaText == nil)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct AntigravityQuotaRow: View {
    let pool: AntigravityQuotaPool
    let fiveHour: AntigravityQuotaWindow?
    let sevenDay: AntigravityQuotaWindow?

    var body: some View {
        HStack(spacing: MonitorTheme.Spacing.inline) {
            Text(pool.label)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(MonitorTheme.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.68)
                .frame(width: 160, alignment: .leading)
            AntigravityQuotaCell(period: .fiveHour, window: fiveHour)
            AntigravityQuotaCell(period: .sevenDay, window: sevenDay)
        }
        .frame(height: 24)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct AntigravityQuotaCell: View {
    let period: AntigravityQuotaPeriod
    let window: AntigravityQuotaWindow?

    var body: some View {
        HStack(spacing: MonitorTheme.Spacing.compact) {
            Text(period.label)
                .font(MonitorTheme.Typography.quotaMeta)
                .foregroundStyle(MonitorTheme.textSecondary)
            Text(Formatters.percent(window?.remainingPercent))
                .font(MonitorTheme.Typography.quotaMeta.weight(.semibold))
                .foregroundStyle(MonitorTheme.quotaColor(for: window?.remainingPercent))
                .monospacedDigit()
        }
        .frame(minWidth: 82, alignment: .leading)
    }
}

private struct SparkQuotaChip: View {
    let window: SparkQuotaWindow

    var body: some View {
        HStack(spacing: MonitorTheme.Spacing.compact) {
            Text(window.label)
                .font(MonitorTheme.Typography.sparkMeta)
                .foregroundStyle(MonitorTheme.textTertiary)
                .lineLimit(1)

            Text(window.remainingText)
                .font(MonitorTheme.Typography.sparkMeta.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(MonitorTheme.quotaColor(for: window.remainingPercent))
                .lineLimit(1)
                .minimumScaleFactor(0.78)
                .allowsTightening(true)
        }
        .padding(.horizontal, MonitorTheme.Spacing.inline)
        .padding(.vertical, 3)
        .background(
            MonitorTheme.controlFill,
            in: RoundedRectangle(cornerRadius: MonitorTheme.Radius.chip, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: MonitorTheme.Radius.chip, style: .continuous)
                .stroke(MonitorTheme.hairline, lineWidth: MonitorTheme.Stroke.hairline)
        )
        .help(helpText)
    }

    private var helpText: String {
        var parts = ["GPT-5.3-Codex-Spark \(window.label)"]
        if let resetText = window.resetText {
            parts.append(resetText)
        } else if let resetText = Formatters.quotaResetText(window.resetAt) {
            parts.append(resetText)
        }
        return parts.joined(separator: " · ")
    }
}

private struct SparkMetricChip: View {
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: MonitorTheme.Spacing.compact) {
            Text(label)
                .font(MonitorTheme.Typography.sparkMeta)
                .foregroundStyle(MonitorTheme.textTertiary)
                .lineLimit(1)
                .minimumScaleFactor(0.78)
                .allowsTightening(true)

            Text(value)
                .font(MonitorTheme.Typography.sparkMeta.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(MonitorTheme.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.78)
                .allowsTightening(true)
        }
        .padding(.horizontal, MonitorTheme.Spacing.inline)
        .padding(.vertical, 3)
        .background(
            MonitorTheme.controlFill,
            in: RoundedRectangle(cornerRadius: MonitorTheme.Radius.chip, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: MonitorTheme.Radius.chip, style: .continuous)
                .stroke(MonitorTheme.hairline, lineWidth: MonitorTheme.Stroke.hairline)
        )
    }
}

private struct CapsuleQuotaBar: View {
    let value: Int?
    let color: Color

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(MonitorTheme.progressTrack)
                Capsule(style: .continuous)
                    .fill(color.opacity(0.92))
                    .frame(width: proxy.size.width * progress)
            }
        }
        .frame(height: 4)
    }

    private var progress: CGFloat {
        guard let value else {
            return 0
        }
        return CGFloat(max(0, min(100, value))) / 100
    }
}

private struct CompactStatusCell: View {
    let label: String
    let value: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: MonitorTheme.Spacing.compact) {
            HStack(alignment: .firstTextBaseline, spacing: MonitorTheme.Spacing.inline) {
                Text(label)
                    .font(MonitorTheme.Typography.quotaLabel)
                    .foregroundStyle(MonitorTheme.textPrimary)
                Spacer(minLength: MonitorTheme.Spacing.compact)
                Text(value)
                    .font(MonitorTheme.Typography.quotaValue)
                    .foregroundStyle(MonitorTheme.textPrimary)
                    .monospacedDigit()
            }

            Color.clear
                .frame(height: 4)

            Text(detail)
                .font(MonitorTheme.Typography.quotaMeta)
                .foregroundStyle(MonitorTheme.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.74)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct TaskTableHeader: View {
    let showContextMetrics: Bool
    let usesPublishedTodayLedger: Bool

    var body: some View {
        HStack(spacing: 0) {
            tableHeaderText("任务")
                .frame(maxWidth: .infinity, alignment: .leading)
            tableHeaderText("今日 Token")
                .frame(width: 106, alignment: .trailing)
                .help(usesPublishedTodayLedger
                    ? "今日 Token 含已归因子代理；百分比按本机当天全部 Token 计算。"
                    : "今日 Token 为本机根任务快照的暂估值；尚未与子代理及当天总量完整对齐。")
            if showContextMetrics {
                tableHeaderText("Ctx")
                    .frame(width: 56, alignment: .trailing)
            }
            tableHeaderText("累计 Token")
                .frame(width: 88, alignment: .trailing)
        }
        .padding(.horizontal, MonitorTheme.Spacing.panel)
        .frame(height: IslandMetrics.detailTaskHeaderHeight)
    }

    private func tableHeaderText(_ text: String) -> some View {
        Text(text)
            .font(MonitorTheme.Typography.tableHeader)
            .foregroundStyle(MonitorTheme.textSecondary)
    }
}

private struct TaskTableRow: View {
    let task: CodexTask
    let todayTotalTokens: Int?
    let showContextMetrics: Bool

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: MonitorTheme.Spacing.inline) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 7, height: 7)

                    Text(task.title)
                        .font(MonitorTheme.Typography.tableBody)
                        .foregroundStyle(MonitorTheme.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    if let badgeText = TaskBadgeFormatter.subagentBadgeText(for: task.activeSubagentCount) {
                        Text(badgeText)
                            .font(.system(size: 8.4, weight: .semibold))
                            .foregroundStyle(MonitorTheme.running)
                            .lineLimit(1)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                    }
                }
                HStack(spacing: MonitorTheme.Spacing.compact) {
                    Text(task.status.label)
                        .font(MonitorTheme.Typography.tableStatus)
                        .foregroundStyle(task.status == .running ? MonitorTheme.running : MonitorTheme.textSecondary)
                }
                .padding(.leading, 14)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .trailing, spacing: 0) {
                Text(HUDTokenFormatter.compact(task.todayTokens))
                    .font(MonitorTheme.Typography.tableValue)
                    .foregroundStyle(todayColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.56)
                    .monospacedDigit()
                Text(HUDTokenFormatter.sharePercent(tokens: task.todayTokens, total: todayTotalTokens))
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(MonitorTheme.textSecondary)
                    .lineLimit(1)
                    .monospacedDigit()
            }
            .frame(width: 106, alignment: .trailing)
            .help(todayUsageHelp)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("今日 Token")
            .accessibilityValue(todayAccessibilityLabel)

            if showContextMetrics {
                Text(Formatters.percent(task.contextPercent))
                    .font(.system(size: 10.2, weight: .semibold))
                    .foregroundStyle(task.contextPercent == nil ? MonitorTheme.textTertiary : MonitorTheme.textPrimary)
                    .frame(width: 56, alignment: .trailing)
                    .lineLimit(1)
                    .minimumScaleFactor(0.62)
                    .monospacedDigit()
                    .help("上下文使用率 \(Formatters.percent(task.contextPercent))；输入 \(HUDTokenFormatter.compact(task.contextInputTokens)) / 窗口 \(HUDTokenFormatter.compact(task.contextWindowTokens))；精确原始值：输入 \(task.contextInputTokens.map(String.init) ?? "不可用") / 窗口 \(task.contextWindowTokens.map(String.init) ?? "不可用")")
            }

            Text(HUDTokenFormatter.compact(task.tokenCount))
                .font(MonitorTheme.Typography.tableValue)
                .foregroundStyle(MonitorTheme.textPrimary)
                .frame(width: 88, alignment: .trailing)
                .lineLimit(1)
                .minimumScaleFactor(0.62)
                .monospacedDigit()
                .help("累计 Token 为现有快照中的根任务值，不包含子代理；精确原始值：\(task.tokenCount)。")
                .accessibilityLabel("累计 Token")
                .accessibilityValue("\(HUDTokenFormatter.compact(task.tokenCount))，精确原始值 \(task.tokenCount)，根任务快照")
        }
        .padding(.horizontal, MonitorTheme.Spacing.panel)
        .frame(height: IslandMetrics.detailTaskRowHeight)
        .background(Color.clear)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(MonitorTheme.separator)
                .frame(height: MonitorTheme.Stroke.hairline)
        }
        .accessibilityElement(children: .contain)
    }

    private var isRunning: Bool {
        task.status == .running
    }

    private var statusColor: Color {
        switch task.status {
        case .running:
            MonitorTheme.running
        case .recent, .idle:
            MonitorTheme.neutral
        }
    }

    private var todayColor: Color {
        guard let tokens = task.todayTokens else {
            return MonitorTheme.textTertiary
        }
        return tokens > 0 ? MonitorTheme.textPrimary : MonitorTheme.textSecondary
    }

    private var todayAccessibilityLabel: String {
        let tokens = task.todayTokens.map(HUDTokenFormatter.compact) ?? "不可用"
        let exactTokens = task.todayTokens.map(String.init) ?? "不可用"
        let share = HUDTokenFormatter.sharePercent(tokens: task.todayTokens, total: todayTotalTokens)
        if task.todayUsageIsReconciled {
            return "今日 Token \(tokens)，\(share == "--" ? "暂无占比" : "占当天 \(share)")，精确原始值 \(exactTokens)，包含已归因子代理"
        }
        return "今日 Token \(tokens)，\(share == "--" ? "暂无占比" : "占当天 \(share)")，精确原始值 \(exactTokens)，为根任务本机快照暂估；不含未对齐的子代理"
    }

    private var todayUsageHelp: String {
        task.todayUsageIsReconciled
            ? "今日 Token 已包含归属于此任务的子代理；百分比按本机当天全部 Token 计算。精确原始值：\(task.todayTokens.map(String.init) ?? "不可用")。"
            : "今日 Token 为根任务本机快照的暂估值；尚未与子代理及当天总量完整对齐。精确原始值：\(task.todayTokens.map(String.init) ?? "不可用")。"
    }
}

private struct OtherLocalRecordRow: View {
    let tokenCount: Int
    let todayTotalTokens: Int?
    let showContextMetrics: Bool

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: MonitorTheme.Spacing.inline) {
                Circle()
                    .fill(MonitorTheme.textTertiary)
                    .frame(width: 7, height: 7)
                VStack(alignment: .leading, spacing: 0) {
                    Text("其他本地记录")
                        .font(MonitorTheme.Typography.tableBody)
                        .foregroundStyle(MonitorTheme.textPrimary)
                    Text("仅今日汇总 · 不计入根任务")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(MonitorTheme.textSecondary)
                        .padding(.leading, 14)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .trailing, spacing: 0) {
                Text(HUDTokenFormatter.compact(tokenCount))
                    .font(MonitorTheme.Typography.tableValue)
                    .foregroundStyle(MonitorTheme.textPrimary)
                    .monospacedDigit()
                Text(HUDTokenFormatter.sharePercent(tokens: tokenCount, total: todayTotalTokens))
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(MonitorTheme.textSecondary)
                    .monospacedDigit()
            }
            .frame(width: 106, alignment: .trailing)
            .help("其他本地记录，今日精确 Token \(tokenCount)，\(HUDTokenFormatter.shareAccessibility(tokens: tokenCount, total: todayTotalTokens))；累计不可用。")

            if showContextMetrics {
                Spacer(minLength: 56)
            }
            Text("--")
                .font(MonitorTheme.Typography.tableValue)
                .foregroundStyle(MonitorTheme.textTertiary)
                .frame(width: 88, alignment: .trailing)
                .accessibilityLabel("累计 Token")
                .accessibilityValue("不可用")
        }
        .padding(.horizontal, MonitorTheme.Spacing.panel)
        .frame(height: IslandMetrics.detailTaskRowHeight)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(MonitorTheme.separator)
                .frame(height: MonitorTheme.Stroke.hairline)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("其他本地记录")
        .accessibilityValue("今日 \(tokenCount) Token，\(HUDTokenFormatter.shareAccessibility(tokens: tokenCount, total: todayTotalTokens))，累计不可用，不计入根任务")
    }
}

private struct StatusPill: View {
    let status: TaskStatus

    var body: some View {
        Text(status.hudLabel)
            .font(MonitorTheme.Typography.tableStatus)
            .foregroundStyle(color)
            .lineLimit(1)
            .minimumScaleFactor(0.72)
            .padding(.horizontal, 6)
            .frame(height: 16)
            .background(
                color.opacity(0.13),
                in: RoundedRectangle(cornerRadius: MonitorTheme.Radius.chip, style: .continuous)
            )
    }

    private var color: Color {
        switch status {
        case .running:
            MonitorTheme.running
        case .recent, .idle:
            MonitorTheme.textTertiary
        }
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

                Text(task.status.hudLabel)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(statusColor)
            }

            HStack(spacing: 6) {
                Text(task.detail)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(MonitorTheme.textSecondary)
                    .lineLimit(1)

                Spacer(minLength: 8)

                if let badgeText = TaskBadgeFormatter.subagentBadgeText(for: task.activeSubagentCount) {
                    Text(badgeText)
                        .font(.system(size: 9, weight: .semibold, design: .rounded))
                        .foregroundStyle(MonitorTheme.healthy)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .layoutPriority(2)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(
                            MonitorTheme.healthy.opacity(0.11),
                            in: RoundedRectangle(cornerRadius: 4, style: .continuous)
                        )
                }

                Text(Formatters.compactTokens(task.tokenCount))
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(MonitorTheme.textSecondary)
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(MonitorTheme.rowFill, in: RoundedRectangle(cornerRadius: MonitorTheme.Radius.row, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: MonitorTheme.Radius.row, style: .continuous)
                .stroke(MonitorTheme.hairline, lineWidth: MonitorTheme.Stroke.hairline)
        )
    }

    private var statusColor: Color {
        switch task.status {
        case .running:
            MonitorTheme.healthy
        case .recent, .idle:
            MonitorTheme.textTertiary
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
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(MonitorTheme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                HStack(spacing: 5) {
                    if let planLabel = account.planLabel {
                        Text(planLabel)
                            .font(.system(size: 8.5, weight: .semibold, design: .rounded))
                            .foregroundStyle(MonitorTheme.textSecondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(MonitorTheme.controlFill, in: RoundedRectangle(cornerRadius: MonitorTheme.Radius.chip, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: MonitorTheme.Radius.chip, style: .continuous)
                                    .stroke(MonitorTheme.hairline, lineWidth: MonitorTheme.Stroke.hairline)
                            )
                    }

                    Text(account.detailText)
                        .font(.system(size: 9.3, weight: .medium))
                        .foregroundStyle(MonitorTheme.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 4) {
                Text(account.stateReasonText)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(account.state.color)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)

                quotaGrid
            }
            .frame(width: 148, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(minHeight: quotaWindows.count > 2 ? 74 : 62)
        .background(MonitorTheme.rowFill, in: RoundedRectangle(cornerRadius: MonitorTheme.Radius.row, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: MonitorTheme.Radius.row, style: .continuous)
                .stroke(MonitorTheme.hairline, lineWidth: MonitorTheme.Stroke.hairline)
        )
    }

    private var quotaWindows: [RemoteQuotaWindow] {
        account.displayQuotaWindows
    }

    @ViewBuilder
    private var quotaGrid: some View {
        if quotaWindows.isEmpty {
            Text(account.quotaSummaryText)
                .font(.system(size: 9.3, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(quotaColor)
                .lineLimit(1)
        } else {
            LazyVGrid(
                columns: [
                    GridItem(.flexible(minimum: 58), spacing: 4, alignment: .trailing),
                    GridItem(.flexible(minimum: 58), spacing: 4, alignment: .trailing)
                ],
                alignment: .trailing,
                spacing: 3
            ) {
                ForEach(quotaWindows) { window in
                    Text("\(window.shortLabel) \(window.remainingText)")
                        .font(.system(size: 8.4, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(window.reachesThreshold ? MonitorTheme.warning : MonitorTheme.textSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.64)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
        }
    }

    private var quotaColor: Color {
        if account.quotaError != nil {
            return MonitorTheme.warning
        }
        if account.displayQuotaWindows.contains(where: \.reachesThreshold) {
            return MonitorTheme.warning
        }
        return MonitorTheme.textSecondary
    }
}

private struct BalanceAccountRow: View {
    let account: BalanceAccount

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(account.state.color)
                .frame(width: 8, height: 8)
                .shadow(color: account.state.color.opacity(0.45), radius: 4, x: 0, y: 0)

            VStack(alignment: .leading, spacing: 4) {
                Text(account.displayName)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(MonitorTheme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Text(account.detailText)
                    .font(.system(size: 9.3, weight: .medium))
                    .foregroundStyle(MonitorTheme.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 4) {
                Text(account.stateText)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(account.state.color)
                    .lineLimit(1)
                    .minimumScaleFactor(0.68)
                Text(account.amountText)
                    .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(MonitorTheme.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }
            .frame(width: 104, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(height: 62)
        .background(MonitorTheme.rowFill, in: RoundedRectangle(cornerRadius: MonitorTheme.Radius.row, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: MonitorTheme.Radius.row, style: .continuous)
                .stroke(MonitorTheme.hairline, lineWidth: MonitorTheme.Stroke.hairline)
        )
    }
}

private struct RemoteSummaryCell: View {
    let label: String
    let value: String

    var body: some View {
        VStack(spacing: 2) {
            Text(label)
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(MonitorTheme.textSecondary)
            Text(value)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(MonitorTheme.textPrimary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 7)
        .background(MonitorTheme.rowFill, in: RoundedRectangle(cornerRadius: MonitorTheme.Radius.row, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: MonitorTheme.Radius.row, style: .continuous)
                .stroke(MonitorTheme.hairline, lineWidth: MonitorTheme.Stroke.hairline)
        )
    }
}

private struct LocalPeriodUsageCell: View {
    let label: String
    let value: String
    var helpText: String? = nil
    let costValue: String
    let costHelpText: String

    @ViewBuilder
    var body: some View {
        cell
            .help(combinedHelpText)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(label)，Token \(value)，API 标准单价等值费用 \(costValue)")
            .accessibilityHint(combinedHelpText)
    }

    private var cell: some View {
        VStack(spacing: 0) {
            Text(label)
                .font(MonitorTheme.Typography.periodLabel)
                .foregroundStyle(MonitorTheme.textSecondary)
            Text(value)
                .font(MonitorTheme.Typography.periodValue)
                .foregroundStyle(MonitorTheme.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
                .monospacedDigit()
            Text(costValue)
                .font(MonitorTheme.Typography.periodCost)
                .foregroundStyle(MonitorTheme.textTertiary)
                .lineLimit(1)
                .minimumScaleFactor(0.58)
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var combinedHelpText: String {
        [helpText, costHelpText].compactMap { $0 }.joined(separator: " ")
    }
}

private struct PeriodUsageCell: View {
    let label: String
    let value: String
    var helpText: String? = nil

    @ViewBuilder
    var body: some View {
        if let helpText {
            cell
                .help(helpText)
                .accessibilityHint(helpText)
        } else {
            cell
        }
    }

    private var cell: some View {
        VStack(spacing: MonitorTheme.Spacing.compact) {
            Text(label)
                .font(.system(size: 9.6, weight: .semibold))
                .foregroundStyle(MonitorTheme.textSecondary)
            Text(value)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(MonitorTheme.textPrimary)
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 7)
        .background(MonitorTheme.rowFill, in: RoundedRectangle(cornerRadius: MonitorTheme.Radius.row, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: MonitorTheme.Radius.row, style: .continuous)
                .stroke(MonitorTheme.hairline, lineWidth: MonitorTheme.Stroke.hairline)
        )
    }
}
