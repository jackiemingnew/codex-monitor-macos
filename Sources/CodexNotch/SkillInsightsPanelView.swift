import SwiftUI

struct SkillInsightsPanelView: View {
    @ObservedObject var viewModel: SkillInsightsFeatureCoordinator

    private var snapshot: SkillInsightsSnapshot { viewModel.snapshot }

    var body: some View {
        VStack(spacing: MonitorTheme.Spacing.row) {
            summary
            skillTable
            footer
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var summary: some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: MonitorTheme.Spacing.row), count: 4),
            spacing: MonitorTheme.Spacing.row
        ) {
            SkillInsightMetric(label: "启用", value: "\(snapshot.enabledSkillCount)")
            SkillInsightMetric(label: "关闭", value: "\(snapshot.disabledSkillCount)")
            SkillInsightMetric(label: "目录成本", value: "~\(snapshot.enabledCatalogTokenEstimate)")
            SkillInsightMetric(label: "确认使用", value: "\(snapshot.confirmedUseCount)")
            SkillInsightMetric(label: "疑似漏触发", value: "\(snapshot.suspectedMissCount)")
            SkillInsightMetric(label: "SHADOW", value: "\(snapshot.shadowHitCount)")
            SkillInsightMetric(label: "建议复测", value: "\(snapshot.retestCount)")
            SkillInsightMetric(
                label: "完整度",
                value: snapshot.quality.rawValue,
                color: qualityColor(snapshot.quality)
            )
        }
        .padding(MonitorTheme.Spacing.section)
        .background(MonitorTheme.sectionFill, in: RoundedRectangle(cornerRadius: MonitorTheme.Radius.section, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: MonitorTheme.Radius.section, style: .continuous)
                .stroke(MonitorTheme.hairline, lineWidth: MonitorTheme.Stroke.hairline)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Skill Insights summary")
    }

    private var skillTable: some View {
        VStack(spacing: 0) {
            SkillInsightTableHeader()
            Rectangle()
                .fill(MonitorTheme.separator)
                .frame(height: MonitorTheme.Stroke.hairline)

            if snapshot.rows.isEmpty {
                VStack(spacing: 6) {
                    Text(snapshot.quality == .unavailable ? "尚未完成 Skill 分析" : "最近 7 天暂无 Skill 证据")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(MonitorTheme.textSecondary)
                    Text("点击“分析最近 7 天”生成只读周报。")
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(MonitorTheme.textTertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.vertical, showsIndicators: true) {
                    LazyVStack(spacing: 0) {
                        ForEach(snapshot.rows) { row in
                            SkillInsightTableRow(row: row)
                        }
                    }
                }
            }
        }
        .frame(maxHeight: .infinity)
        .background(MonitorTheme.sectionFill, in: RoundedRectangle(cornerRadius: MonitorTheme.Radius.section, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: MonitorTheme.Radius.section, style: .continuous)
                .stroke(MonitorTheme.hairline, lineWidth: MonitorTheme.Stroke.hairline)
        )
    }

    private var footer: some View {
        HStack(spacing: MonitorTheme.Spacing.row) {
            VStack(alignment: .leading, spacing: 2) {
                Text(lastAnalysisText)
                    .font(.system(size: 9.4, weight: .semibold))
                    .foregroundStyle(MonitorTheme.textSecondary)
                    .lineLimit(1)
                Text(viewModel.exportMessage ?? performanceText)
                    .font(.system(size: 8.8, weight: .medium))
                    .foregroundStyle(MonitorTheme.textTertiary)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            Button("Markdown") { viewModel.export(.markdown) }
                .buttonStyle(SkillInsightButtonStyle())
                .disabled(snapshot.lastAnalyzedAt == nil)
                .help("导出 Markdown 周报")
            Button("JSON") { viewModel.export(.json) }
                .buttonStyle(SkillInsightButtonStyle())
                .disabled(snapshot.lastAnalyzedAt == nil)
                .help("导出机器可读 JSON")
            Button(viewModel.isAnalyzing ? "分析中…" : "分析最近 7 天") {
                viewModel.analyzeRecentWeek()
            }
            .buttonStyle(SkillInsightPrimaryButtonStyle())
            .disabled(viewModel.isAnalyzing)
            .help("低优先级重新分析最近 7 天；不会调用模型或修改 Skill 配置")
        }
        .frame(height: 34)
        .accessibilityElement(children: .contain)
    }

    private var lastAnalysisText: String {
        guard let date = snapshot.lastAnalyzedAt else {
            return "最后分析：UNAVAILABLE"
        }
        return "最后分析：\(Formatters.relativeAge(date))前 · 逐 Skill Token：UNAVAILABLE"
    }

    private var performanceText: String {
        let stats = snapshot.performance
        let logicalRead = ByteCountFormatter.string(
            fromByteCount: Int64(clamping: stats.analyzedBytes),
            countStyle: .file
        )
        return "files \(stats.analyzedFiles)/\(stats.candidateFiles) · pending \(stats.pendingFiles) · partial \(stats.partialFiles) · read \(logicalRead) · CPU \(stats.cpuMilliseconds)ms · DB \(stats.databaseDurationMilliseconds)ms"
    }

    private func qualityColor(_ quality: SkillInsightsQuality) -> Color {
        switch quality {
        case .complete:
            MonitorTheme.healthy
        case .partial:
            MonitorTheme.warning
        case .unavailable:
            MonitorTheme.textTertiary
        }
    }
}

private struct SkillInsightMetric: View {
    let label: String
    let value: String
    var color: Color = MonitorTheme.textPrimary

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 8.8, weight: .semibold))
                .foregroundStyle(MonitorTheme.textTertiary)
                .lineLimit(1)
            Text(value)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .frame(height: 38)
        .background(MonitorTheme.rowFill, in: RoundedRectangle(cornerRadius: MonitorTheme.Radius.row, style: .continuous))
    }
}

private struct SkillInsightTableHeader: View {
    var body: some View {
        HStack(spacing: 6) {
            Text("Skill").frame(width: 148, alignment: .leading)
            Text("状态").frame(width: 42)
            Text("D").frame(width: 24)
            Text("S").frame(width: 24)
            Text("I").frame(width: 24)
            Text("H").frame(width: 24)
            Text("成本").frame(width: 44)
            Text("建议").frame(maxWidth: .infinity, alignment: .trailing)
        }
        .font(.system(size: 9.2, weight: .semibold))
        .foregroundStyle(MonitorTheme.textSecondary)
        .padding(.horizontal, 10)
        .frame(height: 26)
        .help("D=DIRECT，S=STRONG，I=INFERRED，H=SHADOW；成本为 name + description 的近似目录 Token")
    }
}

private struct SkillInsightTableRow: View {
    let row: SkillInsightRow

    var body: some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                Text(row.skill.name)
                    .font(.system(size: 10.2, weight: .semibold))
                    .foregroundStyle(MonitorTheme.textPrimary)
                    .lineLimit(1)
                Text(sessionReference)
                    .font(.system(size: 8.2, weight: .medium))
                    .foregroundStyle(MonitorTheme.textTertiary)
                    .lineLimit(1)
            }
            .frame(width: 148, alignment: .leading)

            Text(row.skill.enabled ? "开" : "关")
                .font(.system(size: 8.8, weight: .bold))
                .foregroundStyle(row.skill.enabled ? MonitorTheme.healthy : MonitorTheme.textTertiary)
                .frame(width: 42)
            count(row.directCount, color: MonitorTheme.running)
            count(row.strongCount, color: MonitorTheme.healthy)
            count(row.inferredCount, color: MonitorTheme.textSecondary)
            count(row.shadowCount, color: MonitorTheme.warning)
            Text("~\(row.skill.catalogTokenEstimate)")
                .font(.system(size: 9, weight: .semibold, design: .rounded))
                .foregroundStyle(MonitorTheme.textSecondary)
                .frame(width: 44)
            Text(row.recommendation.rawValue)
                .font(.system(size: 8.8, weight: .semibold))
                .foregroundStyle(recommendationColor)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .frame(height: 38)
        .background(MonitorTheme.rowFill.opacity(0.34))
        .overlay(alignment: .bottom) {
            Rectangle().fill(MonitorTheme.separator).frame(height: MonitorTheme.Stroke.hairline)
        }
        .help(helpText)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    private func count(_ value: Int, color: Color) -> some View {
        Text("\(value)")
            .font(.system(size: 9.4, weight: .semibold, design: .rounded))
            .foregroundStyle(value > 0 ? color : MonitorTheme.textTertiary)
            .monospacedDigit()
            .frame(width: 24)
    }

    private var sessionReference: String {
        guard row.relatedSessionCount > 0 else {
            return row.evidenceQuality.rawValue
        }
        return "\(row.relatedSessionCount) Sessions · \(Formatters.compactTokensEnglish(row.relatedSessionTokens)) Token ref"
    }

    private var helpText: String {
        """
        \(row.skill.path)
        该 Skill 在 \(row.relatedSessionCount) 个 Session 中有证据；相关 Session 合计 \(row.relatedSessionTokens) Token，但无法精确归因到该 Skill。
        疑似漏触发 \(row.suspectedMissCount)，疑似误触发 \(row.suspectedMisfireCount)，现有能力替代 \(row.replacedByExistingCount)，证据质量 \(row.evidenceQuality.rawValue)。
        """
    }

    private var accessibilityLabel: String {
        "\(row.skill.name)，\(row.skill.enabled ? "启用" : "关闭")，DIRECT \(row.directCount)，STRONG \(row.strongCount)，INFERRED \(row.inferredCount)，SHADOW \(row.shadowCount)，建议 \(row.recommendation.rawValue)"
    }

    private var recommendationColor: Color {
        switch row.recommendation {
        case .keep:
            MonitorTheme.healthy
        case .retest, .restoreCandidate:
            MonitorTheme.warning
        case .continueObserving, .continueDisabled, .noEvidence:
            MonitorTheme.textSecondary
        }
    }
}

private struct SkillInsightButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(MonitorTheme.textSecondary)
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(MonitorTheme.controlFill, in: RoundedRectangle(cornerRadius: MonitorTheme.Radius.row, style: .continuous))
            .opacity(configuration.isPressed ? 0.72 : 1)
    }
}

private struct SkillInsightPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(MonitorTheme.textPrimary)
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(MonitorTheme.controlSelectedFill, in: RoundedRectangle(cornerRadius: MonitorTheme.Radius.row, style: .continuous))
            .opacity(configuration.isPressed ? 0.72 : 1)
    }
}
