import AppKit
import SwiftUI

enum MonitorTheme {
    private static func rgb(_ red: Int, _ green: Int, _ blue: Int) -> NSColor {
        NSColor(
            srgbRed: CGFloat(red) / 255,
            green: CGFloat(green) / 255,
            blue: CGFloat(blue) / 255,
            alpha: 1
        )
    }

    private static func adaptiveColor(light: NSColor, dark: NSColor) -> Color {
        Color(
            nsColor: NSColor(name: nil) { appearance in
                appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            }
        )
    }

    /// Tokens used by the collapsed capsule only.  The detail panel has a
    /// deliberately independent, opaque adaptive palette below; keeping these
    /// values namespaced prevents a detail-panel change from reducing HUD
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
    static let detailBackground = adaptiveColor(light: rgb(248, 249, 247), dark: rgb(30, 32, 36))
    static let detailTint = detailBackground
    static let panelStroke = adaptiveColor(light: rgb(225, 229, 233), dark: rgb(59, 65, 75))
    static let hairline = panelStroke
    static let sectionFill = adaptiveColor(light: rgb(252, 253, 252), dark: rgb(37, 40, 45))
    static let rowFill = detailBackground
    static let rowSelectedFill = adaptiveColor(light: rgb(248, 249, 247), dark: rgb(38, 56, 83))
    static let controlFill = adaptiveColor(light: rgb(241, 243, 245), dark: rgb(43, 48, 55))
    static let controlSelectedFill = adaptiveColor(light: rgb(234, 240, 255), dark: rgb(38, 56, 83))
    static let separator = adaptiveColor(light: rgb(225, 229, 233), dark: rgb(59, 65, 75))
    static let progressTrack = adaptiveColor(light: rgb(225, 229, 233), dark: rgb(60, 68, 79))
    static let textPrimary = adaptiveColor(light: rgb(37, 42, 49), dark: rgb(231, 234, 240))
    static let textSecondary = adaptiveColor(light: rgb(97, 107, 118), dark: rgb(168, 176, 188))
    static let textTertiary = adaptiveColor(light: rgb(97, 107, 118), dark: rgb(160, 169, 181))
    static let accentBlue = adaptiveColor(light: rgb(54, 93, 199), dark: rgb(138, 172, 255))
    static let paleBlue = adaptiveColor(light: rgb(234, 240, 255), dark: rgb(38, 56, 83))
    static let healthy = adaptiveColor(light: rgb(40, 121, 79), dark: rgb(120, 201, 154))
    static let running = accentBlue
    static let radarBaseline = accentBlue
    static let warning = adaptiveColor(light: rgb(166, 95, 0), dark: rgb(233, 184, 106))
    static let critical = adaptiveColor(light: rgb(180, 35, 24), dark: rgb(241, 138, 138))
    static let neutral = textSecondary

    // Compatibility aliases for code that still belongs to the collapsed
    // capsule. New detail code should use the light tokens above.
    static let pillTint = Pill.tint

    // Routing telemetry uses a restrained blue/teal primary trend, an amber
    // Ultra comparison trend, and a separate green guidance role. Amber here
    // identifies a series; it must not be interpreted as warning status.
    static let routingTrend = accentBlue
    static let routingTrendPoint = adaptiveColor(light: rgb(85, 123, 219), dark: rgb(175, 200, 255))
    static let routingUltraTrend = adaptiveColor(light: rgb(161, 92, 0), dark: rgb(255, 208, 138))
    static let routingUltraTrendPoint = adaptiveColor(light: rgb(200, 128, 24), dark: rgb(255, 224, 178))
    static let routingGuidance = healthy
    static let routingGuidanceFill = routingGuidance.opacity(0.12)
    static let routingGuidanceBandFill = routingGuidance.opacity(0.42)
    static let routingGuidanceBoundary = routingGuidance.opacity(0.72)
    static let routingCardHairline = separator
    static let routingTooltipSurface = adaptiveColor(light: rgb(255, 255, 255), dark: rgb(37, 40, 45))
    static let routingTooltipStroke = separator
    static let analyticsTurnsPalette = [
        adaptiveColor(light: rgb(149, 176, 230), dark: rgb(192, 212, 255)),
        accentBlue,
        adaptiveColor(light: rgb(45, 76, 145), dark: rgb(126, 165, 255)),
        adaptiveColor(light: rgb(129, 93, 173), dark: rgb(215, 167, 255)),
        adaptiveColor(light: rgb(91, 56, 151), dark: rgb(201, 139, 255)),
        adaptiveColor(light: rgb(64, 48, 118), dark: rgb(183, 124, 255)),
        textTertiary
    ]
    static let analyticsSkillsPalette = [
        adaptiveColor(light: rgb(152, 178, 228), dark: rgb(194, 214, 255)),
        adaptiveColor(light: rgb(80, 126, 203), dark: rgb(145, 184, 255)),
        accentBlue,
        adaptiveColor(light: rgb(49, 86, 157), dark: rgb(167, 195, 255)),
        adaptiveColor(light: rgb(127, 100, 179), dark: rgb(214, 166, 255)),
        adaptiveColor(light: rgb(101, 64, 156), dark: rgb(199, 141, 255)),
        adaptiveColor(light: rgb(180, 73, 117), dark: rgb(255, 159, 197)),
        adaptiveColor(light: rgb(175, 102, 26), dark: rgb(246, 183, 121)),
        adaptiveColor(light: rgb(161, 125, 22), dark: rgb(244, 210, 126))
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
