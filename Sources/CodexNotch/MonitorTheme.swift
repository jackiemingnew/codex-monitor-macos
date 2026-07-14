import SwiftUI

enum MonitorTheme {
    enum Radius {
        static let chip: CGFloat = 4
        static let segment: CGFloat = 6
        static let row: CGFloat = 8
        static let control: CGFloat = 9
        static let section: CGFloat = 10
        static let collapsedPill: CGFloat = 15
        static let detailBottom: CGFloat = 22
    }

    enum Stroke {
        static let hairline: CGFloat = 0.6
        static let panel: CGFloat = 0.8
        static let settingsHairline: CGFloat = 0.6
    }

    enum Spacing {
        static let micro: CGFloat = 3
        static let compact: CGFloat = 4
        static let inline: CGFloat = 6
        static let row: CGFloat = 8
        static let section: CGFloat = 10
        static let panel: CGFloat = 12
        static let wide: CGFloat = 14
    }

    enum Typography {
        static let detailTitle = Font.system(size: 16, weight: .semibold)
        static let detailStatus = Font.system(size: 11, weight: .semibold)
        static let detailTab = Font.system(size: 12, weight: .medium)
        static let detailTabSelected = Font.system(size: 12, weight: .semibold)
        static let quotaLabel = Font.system(size: 11, weight: .semibold)
        static let quotaValue = Font.system(size: 13, weight: .semibold)
        static let quotaMeta = Font.system(size: 10.5, weight: .medium)
        static let sparkLabel = Font.system(size: 11, weight: .semibold)
        static let sparkMeta = Font.system(size: 10.5, weight: .medium)
        static let tableHeader = Font.system(size: 10.5, weight: .semibold)
        static let tableBody = Font.system(size: 12, weight: .medium)
        static let tableValue = Font.system(size: 11, weight: .medium)
        static let tableStatus = Font.system(size: 9, weight: .semibold, design: .rounded)
        static let periodLabel = Font.system(size: 11, weight: .medium)
        static let periodValue = Font.system(size: 13, weight: .semibold)
        static let periodCost = Font.system(size: 8.5, weight: .medium, design: .rounded)
        static let settingsTitle = Font.system(size: 18, weight: .bold)
        static let settingsSubtitle = Font.system(size: 12, weight: .medium)
        static let settingsSidebarLabel = Font.system(size: 12, weight: .bold)
        static let settingsSidebarItem = Font.system(size: 12, weight: .semibold)
        static let settingsCaption = Font.system(size: 10.5, weight: .medium)
        static let settingsHelper = Font.system(size: 11, weight: .medium)
        static let settingsStatus = Font.system(size: 11, weight: .semibold)
        static let settingsControl = Font.system(size: 12, weight: .semibold)
        static let settingsAccountTitle = Font.system(size: 11.5, weight: .semibold)
        static let settingsAccountMeta = Font.system(size: 11, weight: .medium)
        static let settingsSectionTitle = Font.system(size: 12, weight: .bold)
    }

    static let pillTint = Color.black.opacity(0.48)
    static let detailTint = Color.black.opacity(0.68)
    static let panelStroke = Color.white.opacity(0.16)
    static let hairline = Color.white.opacity(0.075)
    static let sectionFill = Color.white.opacity(0.055)
    static let rowFill = Color.white.opacity(0.038)
    static let rowSelectedFill = Color.white.opacity(0.092)
    static let controlFill = Color.white.opacity(0.052)
    static let controlSelectedFill = Color.white.opacity(0.115)
    static let separator = Color.white.opacity(0.070)
    static let progressTrack = Color.white.opacity(0.115)
    static let textPrimary = Color.white.opacity(0.92)
    static let textSecondary = Color.white.opacity(0.62)
    static let textTertiary = Color.white.opacity(0.44)
    static let healthy = Color(red: 0.45, green: 0.78, blue: 0.53)
    static let running = healthy
    static let radarBaseline = Color(red: 0.35, green: 0.72, blue: 0.82)
    static let warning = Color(red: 0.92, green: 0.68, blue: 0.42)
    static let critical = Color(red: 0.88, green: 0.45, blue: 0.45)
    static let neutral = Color.white.opacity(0.34)

    static let settingsSidebarFill = Color.secondary.opacity(0.055)
    static let settingsSurfaceFill = Color.secondary.opacity(0.045)
    static let settingsSurfaceElevatedFill = Color.secondary.opacity(0.08)
    static let settingsSelectedFill = Color.primary.opacity(0.10)
    static let settingsControlFill = Color.secondary.opacity(0.10)
    static let settingsControlSelectedFill = Color.primary.opacity(0.14)
    static let settingsHairline = Color.secondary.opacity(0.12)
    static let settingsTextPrimary = Color.primary
    static let settingsTextSecondary = Color.secondary
    static let settingsError = Color.red.opacity(0.85)
    static let settingsWarning = Color.orange.opacity(0.88)
    static let settingsSuccess = Color.green.opacity(0.82)

    static func quotaColor(for percent: Int?) -> Color {
        guard let percent else {
            return textTertiary
        }
        if percent <= 20 {
            return critical
        }
        if percent <= 40 {
            return warning
        }
        return healthy
    }
}
