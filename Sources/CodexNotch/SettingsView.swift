import SwiftUI

private enum RefreshPreset: String, CaseIterable, Identifiable {
    case realtime
    case balanced
    case economy

    var id: String { rawValue }

    var title: String {
        switch self {
        case .realtime:
            "实时"
        case .balanced:
            "均衡"
        case .economy:
            "低功耗"
        }
    }

    var values: (active: TimeInterval, idle: TimeInterval, usage: TimeInterval, watcher: TimeInterval, gap: TimeInterval) {
        switch self {
        case .realtime:
            (active: 2, idle: 4, usage: 20, watcher: 8, gap: 1)
        case .balanced:
            (active: 3, idle: 6, usage: 30, watcher: 12, gap: 3)
        case .economy:
            (active: 8, idle: 20, usage: 90, watcher: 30, gap: 8)
        }
    }

    func matches(_ draft: SettingsDraft) -> Bool {
        let values = values
        return draft.activeRefreshInterval == values.active
            && draft.idleRefreshInterval == values.idle
            && draft.usageRefreshInterval == values.usage
            && draft.watcherRefreshInterval == values.watcher
            && draft.fileChangeRefreshMinimumGap == values.gap
    }

    static func matching(_ draft: SettingsDraft) -> RefreshPreset {
        allCases.first { $0.matches(draft) } ?? .balanced
    }
}

private struct SettingsDraft: Equatable {
    var activeRefreshInterval: TimeInterval = 3
    var idleRefreshInterval: TimeInterval = 6
    var usageRefreshInterval: TimeInterval = 30
    var watcherRefreshInterval: TimeInterval = 12
    var fileChangeRefreshMinimumGap: TimeInterval = 3
    var rateLimitSource: RateLimitSourcePreference = .appServerFirst
    var showPeriodUsage = true
    var taskHistoryRange: TaskHistoryRange = .threeDays
    var remoteMonitorEnabled = false
    var cliproxyPanelURL = ""
    var cliproxyManagementKey = ""
    var cliproxyRefreshInterval: TimeInterval = 60
    var cliproxyRequestTimeout: TimeInterval = 6
    var cliproxyAllowInsecureTLS = false
    var launchAtLoginEnabled = false
    var enablePulse = true

    @MainActor
    init(settings: CodexNotchSettings) {
        activeRefreshInterval = settings.activeRefreshInterval
        idleRefreshInterval = settings.idleRefreshInterval
        usageRefreshInterval = settings.usageRefreshInterval
        watcherRefreshInterval = settings.watcherRefreshInterval
        fileChangeRefreshMinimumGap = settings.fileChangeRefreshMinimumGap
        rateLimitSource = settings.rateLimitSource
        showPeriodUsage = settings.showPeriodUsage
        taskHistoryRange = settings.taskHistoryRange
        remoteMonitorEnabled = settings.remoteMonitorEnabled
        cliproxyPanelURL = settings.cliproxyPanelURL
        cliproxyManagementKey = settings.cliproxyManagementKey
        cliproxyRefreshInterval = settings.cliproxyRefreshInterval
        cliproxyRequestTimeout = settings.cliproxyRequestTimeout
        cliproxyAllowInsecureTLS = settings.cliproxyAllowInsecureTLS
        launchAtLoginEnabled = settings.launchAtLoginEnabled
        enablePulse = settings.enablePulse
    }

    init() {}

    mutating func applyPreset(_ preset: RefreshPreset) {
        let values = preset.values
        activeRefreshInterval = values.active
        idleRefreshInterval = values.idle
        usageRefreshInterval = values.usage
        watcherRefreshInterval = values.watcher
        fileChangeRefreshMinimumGap = values.gap
    }

    mutating func resetRefreshDefaults() {
        applyPreset(.balanced)
    }
}

struct SettingsView: View {
    @ObservedObject var settings: CodexNotchSettings
    @ObservedObject var remoteViewModel: RemoteMonitorViewModel
    let onRefresh: () -> Void

    @State private var draft = SettingsDraft()
    @State private var selectedPreset: RefreshPreset = .balanced

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header

            Form {
                Section("刷新") {
                    presetControls
                    intervalStepper("运行中", value: $draft.activeRefreshInterval, range: 2...30)
                    intervalStepper("空闲", value: $draft.idleRefreshInterval, range: 4...120)
                    intervalStepper("历史用量", value: $draft.usageRefreshInterval, range: 15...300)
                    intervalStepper("文件监听", value: $draft.watcherRefreshInterval, range: 8...120)
                    intervalStepper("补刷节流", value: $draft.fileChangeRefreshMinimumGap, range: 1...30)
                }

                Section("数据") {
                    Picker("额度来源", selection: $draft.rateLimitSource) {
                        ForEach(RateLimitSourcePreference.allCases) { source in
                            Text(source.label).tag(source)
                        }
                    }
                    .pickerStyle(.segmented)

                    Toggle("显示 24小时 / 7天 / 30天", isOn: $draft.showPeriodUsage)
                    Picker("任务范围", selection: $draft.taskHistoryRange) {
                        ForEach(TaskHistoryRange.allCases) { range in
                            Text(range.label).tag(range)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Section("远程监测") {
                    Toggle("启用 CPA-Manager-Plus 监测", isOn: $draft.remoteMonitorEnabled)

                    TextField("CPA-Manager-Plus 地址", text: $draft.cliproxyPanelURL)
                        .textFieldStyle(.roundedBorder)
                        .disabled(!draft.remoteMonitorEnabled)

                    SecureField("管理密码", text: $draft.cliproxyManagementKey)
                        .textFieldStyle(.roundedBorder)
                        .disabled(!draft.remoteMonitorEnabled)

                    Text("地址、密码和巡检刷新配置仅在点击保存后生效。")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)

                    intervalStepper("巡检结果", value: $draft.cliproxyRefreshInterval, range: 60...3_600)
                        .disabled(!draft.remoteMonitorEnabled)
                    intervalStepper("请求超时", value: $draft.cliproxyRequestTimeout, range: 3...30)
                        .disabled(!draft.remoteMonitorEnabled)

                    Toggle("允许不安全 TLS", isOn: $draft.cliproxyAllowInsecureTLS)
                        .disabled(!draft.remoteMonitorEnabled)

                    remoteStatusRow

                    if let error = settings.cliproxyKeychainError {
                        Text("管理密码保存失败：\(error)")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.red.opacity(0.85))
                    }
                }

                Section("启动与外观") {
                    Toggle("开机自启", isOn: $draft.launchAtLoginEnabled)
                    Toggle("运行指示灯动画", isOn: $draft.enablePulse)

                    if let error = settings.launchAtLoginError {
                        Text("开机自启设置失败：\(error)")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.red.opacity(0.85))
                    }
                }
            }
            .formStyle(.grouped)

            footer
        }
        .padding(20)
        .frame(width: 500)
        .onAppear {
            reloadDraft()
        }
    }

    private var currentDraft: SettingsDraft {
        SettingsDraft(settings: settings)
    }

    private var hasChanges: Bool {
        draft != currentDraft
    }

    private var hasRemoteChanges: Bool {
        let current = currentDraft
        return draft.remoteMonitorEnabled != current.remoteMonitorEnabled
            || draft.cliproxyPanelURL != current.cliproxyPanelURL
            || draft.cliproxyManagementKey != current.cliproxyManagementKey
            || draft.cliproxyRefreshInterval != current.cliproxyRefreshInterval
            || draft.cliproxyRequestTimeout != current.cliproxyRequestTimeout
            || draft.cliproxyAllowInsecureTLS != current.cliproxyAllowInsecureTLS
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Codex 刘海设置")
                    .font(.system(size: 18, weight: .bold))
                Text("调整刷新、数据来源和启动行为")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
    }

    private var presetControls: some View {
        HStack(spacing: 8) {
            ForEach(RefreshPreset.allCases) { preset in
                Button {
                    selectedPreset = preset
                    draft.applyPreset(preset)
                } label: {
                    Text(preset.title)
                        .font(.system(size: 12, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(
                            (selectedPreset == preset ? Color.primary.opacity(0.14) : Color.secondary.opacity(0.10)),
                            in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func intervalStepper(_ title: String, value: Binding<TimeInterval>, range: ClosedRange<TimeInterval>) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(intervalText(value.wrappedValue))
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 58, alignment: .trailing)
            Stepper("", value: value, in: range, step: 1)
                .labelsHidden()
        }
    }

    private func minuteStepper(_ title: String, value: Binding<TimeInterval>, range: ClosedRange<TimeInterval>) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(minuteText(value.wrappedValue))
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 72, alignment: .trailing)
            Stepper("", value: value, in: range, step: 1)
                .labelsHidden()
        }
    }

    private func integerStepper(
        _ title: String,
        value: Binding<Int>,
        range: ClosedRange<Int>,
        suffix: String
    ) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text("\(value.wrappedValue) \(suffix)")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 72, alignment: .trailing)
            Stepper("", value: value, in: range, step: 1)
                .labelsHidden()
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button("恢复默认刷新") {
                draft.resetRefreshDefaults()
                selectedPreset = .balanced
            }

            if hasChanges {
                Text("有未保存更改")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.orange)
            }

            Spacer()

            Button("立即刷新") {
                onRefresh()
            }
            .keyboardShortcut("r", modifiers: .command)

            Button("取消更改") {
                reloadDraft()
            }
            .disabled(!hasChanges)

            Button("保存") {
                saveDraft()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!hasChanges)
        }
    }

    private var remoteStatusRow: some View {
        HStack {
            Text("远程状态")
            Spacer()
            Text(hasRemoteChanges ? "保存后生效" : remoteStatusText)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(hasRemoteChanges ? .orange : remoteStatusColor)
                .lineLimit(1)
            Button("刷新远程") {
                remoteViewModel.refreshNow()
            }
            .disabled(!settings.remoteMonitorEnabled || hasRemoteChanges)
        }
    }

    private var remoteStatusText: String {
        switch remoteViewModel.snapshot.panelState {
        case .disabled:
            "未启用"
        case .notConfigured:
            "待配置"
        case .loading:
            "读取中"
        case .healthy:
            remoteViewModel.snapshot.summaryText
        case .warning:
            remoteViewModel.snapshot.summaryText
        case .error:
            remoteViewModel.snapshot.message ?? "异常"
        }
    }

    private var remoteStatusColor: Color {
        switch remoteViewModel.snapshot.panelSeverity {
        case .none:
            .secondary
        case .warning:
            .orange
        case .error:
            .red
        }
    }

    private func reloadDraft() {
        let nextDraft = currentDraft
        draft = nextDraft
        selectedPreset = .matching(nextDraft)
    }

    private func saveDraft() {
        let next = draft
        let current = currentDraft
        let managementKeyForSave = CodexNotchSettings.managementKeyForSave(
            draftKey: next.cliproxyManagementKey,
            oldPanelURL: current.cliproxyPanelURL,
            newPanelURL: next.cliproxyPanelURL,
            oldAllowsInsecureTLS: current.cliproxyAllowInsecureTLS,
            newAllowsInsecureTLS: next.cliproxyAllowInsecureTLS,
            remoteEnabled: next.remoteMonitorEnabled
        )
        if !next.remoteMonitorEnabled {
            settings.remoteMonitorEnabled = false
        }

        settings.activeRefreshInterval = next.activeRefreshInterval
        settings.idleRefreshInterval = next.idleRefreshInterval
        settings.usageRefreshInterval = next.usageRefreshInterval
        settings.watcherRefreshInterval = next.watcherRefreshInterval
        settings.fileChangeRefreshMinimumGap = next.fileChangeRefreshMinimumGap
        settings.rateLimitSource = next.rateLimitSource
        settings.showPeriodUsage = next.showPeriodUsage
        settings.taskHistoryRange = next.taskHistoryRange

        settings.cliproxyPanelURL = next.cliproxyPanelURL
        settings.cliproxyRefreshInterval = next.cliproxyRefreshInterval
        settings.cliproxyRequestTimeout = next.cliproxyRequestTimeout
        settings.cliproxyAllowInsecureTLS = next.cliproxyAllowInsecureTLS
        settings.cliproxyManagementKey = managementKeyForSave
        if next.remoteMonitorEnabled {
            settings.remoteMonitorEnabled = true
        }

        settings.setLaunchAtLoginEnabled(next.launchAtLoginEnabled)
        settings.enablePulse = next.enablePulse

        selectedPreset = .matching(next)
        reloadDraft()
    }

    private func intervalText(_ value: TimeInterval) -> String {
        "\(Int(value)) 秒"
    }

    private func minuteText(_ value: TimeInterval) -> String {
        "\(Int(value)) 分钟"
    }
}
