import SwiftUI

enum MonitorTheme {
    /// Tokens used by the collapsed capsule only.  The detail panel has a
    /// deliberately independent, opaque light palette below; keeping these
    /// values namespaced prevents a light-panel change from reducing HUD
    /// contrast on a mixed desktop background.
    enum Pill {
        static let tint = Color.black.opacity(0.48)
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
        static let warning = Color(red: 0.92, green: 0.68, blue: 0.42)
        static let critical = Color(red: 0.88, green: 0.45, blue: 0.45)
        static let neutral = Color.white.opacity(0.34)
    }

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
        static let detailTitle = Font.system(size: 20, weight: .semibold)
        static let detailStatus = Font.system(size: 11.5, weight: .medium)
        static let detailTab = Font.system(size: 12, weight: .medium)
        static let detailTabSelected = Font.system(size: 12, weight: .semibold)
        static let quotaLabel = Font.system(size: 12, weight: .medium)
        static let quotaValue = Font.system(size: 13, weight: .semibold)
        static let heroValue = Font.system(size: 34, weight: .medium, design: .rounded)
        static let quotaMeta = Font.system(size: 11, weight: .medium)
        static let sparkLabel = Font.system(size: 11, weight: .semibold)
        static let sparkMeta = Font.system(size: 10.5, weight: .medium)
        static let tableHeader = Font.system(size: 12, weight: .medium)
        static let tableBody = Font.system(size: 13, weight: .medium)
        static let tableValue = Font.system(size: 13, weight: .semibold)
        static let tableStatus = Font.system(size: 11.5, weight: .medium)
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

    // Detail surfaces are opaque by design.  Do not replace these with a
    // material: the panel must remain readable over any desktop wallpaper.
    static let detailBackground = Color(red: 248 / 255, green: 249 / 255, blue: 247 / 255)
    static let detailTint = detailBackground
    static let panelStroke = Color(red: 225 / 255, green: 229 / 255, blue: 233 / 255)
    static let hairline = panelStroke
    static let sectionFill = Color(red: 252 / 255, green: 253 / 255, blue: 252 / 255)
    static let rowFill = detailBackground
    static let rowSelectedFill = Color(red: 248 / 255, green: 249 / 255, blue: 247 / 255)
    static let controlFill = Color(red: 241 / 255, green: 243 / 255, blue: 245 / 255)
    static let controlSelectedFill = Color(red: 234 / 255, green: 240 / 255, blue: 255 / 255)
    static let separator = Color(red: 225 / 255, green: 229 / 255, blue: 233 / 255)
    static let progressTrack = Color(red: 225 / 255, green: 229 / 255, blue: 233 / 255)
    static let textPrimary = Color(red: 37 / 255, green: 42 / 255, blue: 49 / 255)
    static let textSecondary = Color(red: 97 / 255, green: 107 / 255, blue: 118 / 255)
    static let textTertiary = Color(red: 97 / 255, green: 107 / 255, blue: 118 / 255)
    static let accentBlue = Color(red: 54 / 255, green: 93 / 255, blue: 199 / 255)
    static let paleBlue = Color(red: 234 / 255, green: 240 / 255, blue: 255 / 255)
    static let healthy = Color(red: 40 / 255, green: 121 / 255, blue: 79 / 255)
    static let running = accentBlue
    static let radarBaseline = accentBlue
    static let warning = Color(red: 166 / 255, green: 95 / 255, blue: 0 / 255)
    static let critical = Color(red: 180 / 255, green: 35 / 255, blue: 24 / 255)
    static let neutral = textSecondary

    // Compatibility aliases for code that still belongs to the collapsed
    // capsule. New detail code should use the light tokens above.
    static let pillTint = Pill.tint

    // Routing telemetry uses a restrained blue/teal primary trend, an amber
    // Ultra comparison trend, and a separate green guidance role. Amber here
    // identifies a series; it must not be interpreted as warning status.
    static let routingTrend = accentBlue
    static let routingTrendPoint = Color(red: 85 / 255, green: 123 / 255, blue: 219 / 255)
    static let routingUltraTrend = Color(red: 161 / 255, green: 92 / 255, blue: 0 / 255)
    static let routingUltraTrendPoint = Color(red: 200 / 255, green: 128 / 255, blue: 24 / 255)
    static let routingGuidance = healthy
    static let routingGuidanceFill = routingGuidance.opacity(0.12)
    static let routingGuidanceBandFill = routingGuidance.opacity(0.42)
    static let routingGuidanceBoundary = routingGuidance.opacity(0.72)
    static let routingCardHairline = separator
    static let routingTooltipSurface = Color.white
    static let routingTooltipStroke = separator
    static let analyticsTurnsPalette = [
        Color(red: 149 / 255, green: 176 / 255, blue: 230 / 255),
        accentBlue,
        Color(red: 45 / 255, green: 76 / 255, blue: 145 / 255),
        Color(red: 129 / 255, green: 93 / 255, blue: 173 / 255),
        Color(red: 91 / 255, green: 56 / 255, blue: 151 / 255),
        Color(red: 64 / 255, green: 48 / 255, blue: 118 / 255),
        textTertiary
    ]
    static let analyticsSkillsPalette = [
        Color(red: 152 / 255, green: 178 / 255, blue: 228 / 255),
        Color(red: 80 / 255, green: 126 / 255, blue: 203 / 255),
        accentBlue,
        Color(red: 49 / 255, green: 86 / 255, blue: 157 / 255),
        Color(red: 127 / 255, green: 100 / 255, blue: 179 / 255),
        Color(red: 101 / 255, green: 64 / 255, blue: 156 / 255),
        Color(red: 180 / 255, green: 73 / 255, blue: 117 / 255),
        Color(red: 175 / 255, green: 102 / 255, blue: 26 / 255),
        Color(red: 161 / 255, green: 125 / 255, blue: 22 / 255)
    ]

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

    static func pillQuotaColor(for percent: Int?) -> Color {
        guard let percent else {
            return Pill.textTertiary
        }
        if percent <= 20 {
            return Pill.critical
        }
        if percent <= 40 {
            return Pill.warning
        }
        return Pill.healthy
    }
}
