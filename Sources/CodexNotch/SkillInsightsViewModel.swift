import AppKit
import Combine
import Foundation

@MainActor
final class SkillInsightsViewModel: ObservableObject {
    @Published private(set) var snapshot: SkillInsightsSnapshot
    @Published private(set) var isAnalyzing = false
    @Published private(set) var exportMessage: String?

    private let service: SkillInsightsService
    private var weeklyTimer: Timer?
    private var analysisTask: Task<SkillInsightsSnapshot, Never>?
    private var refreshTask: Task<SkillInsightsSnapshot, Never>?
    private var snapshotGeneration = 0

    init(service: SkillInsightsService = SkillInsightsService()) {
        self.service = service
        snapshot = .empty
        runAutomaticCheck()
        scheduleNextWeeklyCheck()
    }

    deinit {
        analysisTask?.cancel()
        refreshTask?.cancel()
    }

    func refreshWhenPresented() {
        guard !isAnalyzing else {
            return
        }
        snapshotGeneration += 1
        let generation = snapshotGeneration
        refreshTask?.cancel()
        let task = Task.detached(priority: .utility) { [service] in
            service.currentSnapshot()
        }
        refreshTask = task
        Task { @MainActor [weak self] in
            let next = await task.value
            guard let self,
                  !self.isAnalyzing,
                  self.snapshotGeneration == generation else {
                return
            }
            self.refreshTask = nil
            self.snapshot = next
        }
    }

    func analyzeRecentWeek() {
        runAnalysis(automatic: false)
    }

    func shutdown() {
        weeklyTimer?.invalidate()
        weeklyTimer = nil
        analysisTask?.cancel()
        analysisTask = nil
        refreshTask?.cancel()
        refreshTask = nil
        isAnalyzing = false
    }

    func export(_ format: SkillInsightExportFormat) {
        do {
            let data = try service.export(snapshot, format: format)
            let panel = NSSavePanel()
            let stamp = Self.fileDateFormatter.string(from: Date())
            switch format {
            case .markdown:
                panel.nameFieldStringValue = "codex-skill-insights-\(stamp).md"
            case .json:
                panel.nameFieldStringValue = "codex-skill-insights-\(stamp).json"
            }
            panel.canCreateDirectories = true
            panel.isExtensionHidden = false
            guard panel.runModal() == .OK, let url = panel.url else {
                return
            }
            try data.write(to: url, options: .atomic)
            exportMessage = "已导出 \(url.lastPathComponent)"
        } catch {
            exportMessage = "导出失败"
        }
    }

    private func runAutomaticCheck() {
        runAnalysis(automatic: true)
    }

    private func runAnalysis(automatic: Bool) {
        guard !isAnalyzing else {
            return
        }
        snapshotGeneration += 1
        let generation = snapshotGeneration
        isAnalyzing = true
        exportMessage = nil
        let priority: TaskPriority = automatic ? .background : .utility
        let task = Task.detached(priority: priority) { [service] in
            service.analyzeRecentWeek(
                force: false,
                automatic: automatic,
                shouldCancel: { Task.isCancelled }
            )
        }
        analysisTask = task
        Task { @MainActor [weak self] in
            let next = await task.value
            guard let self else { return }
            guard self.snapshotGeneration == generation else { return }
            self.analysisTask = nil
            self.snapshot = next
            self.isAnalyzing = false
            self.scheduleNextWeeklyCheck()
        }
    }

    private func scheduleNextWeeklyCheck() {
        weeklyTimer?.invalidate()
        let now = Date()
        let nextStart = service.nextAutomaticRunDate(now: now)
        let delay = max(60, nextStart.timeIntervalSince(now))
        let timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.runAutomaticCheck()
            }
        }
        timer.tolerance = 60 * 60
        weeklyTimer = timer
    }

    private static let fileDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}

@MainActor
final class SkillInsightsFeatureCoordinator: ObservableObject {
    private let serviceFactory: @MainActor () -> SkillInsightsViewModel
    private var featureCancellable: AnyCancellable?
    private var viewModelCancellable: AnyCancellable?
    private var viewModel: SkillInsightsViewModel?

    init(
        settings: CodexNotchSettings,
        serviceFactory: @escaping @MainActor () -> SkillInsightsViewModel = { SkillInsightsViewModel() }
    ) {
        self.serviceFactory = serviceFactory
        featureCancellable = settings.$skillInsightsEnabled
            .removeDuplicates()
            .sink { [weak self] enabled in
                self?.setEnabled(enabled)
            }
    }

    var snapshot: SkillInsightsSnapshot { viewModel?.snapshot ?? .empty }
    var isAnalyzing: Bool { viewModel?.isAnalyzing ?? false }
    var exportMessage: String? { viewModel?.exportMessage }
    var isEnabled: Bool { viewModel != nil }

    func refreshWhenPresented() {
        viewModel?.refreshWhenPresented()
    }

    func analyzeRecentWeek() {
        viewModel?.analyzeRecentWeek()
    }

    func export(_ format: SkillInsightExportFormat) {
        viewModel?.export(format)
    }

    private func setEnabled(_ enabled: Bool) {
        if enabled {
            guard viewModel == nil else { return }
            let next = serviceFactory()
            viewModel = next
            viewModelCancellable = next.objectWillChange.sink { [weak self] _ in
                self?.objectWillChange.send()
            }
        } else {
            viewModel?.shutdown()
            viewModel = nil
            viewModelCancellable = nil
        }
        objectWillChange.send()
    }
}
