import AppKit
import SwiftUI

final class TestRunner {
    private(set) var failures = 0

    func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            failures += 1
            FileHandle.standardError.write(Data("FAILED: \(message)\n".utf8))
            return
        }
    }
}

private struct RGBA: Equatable {
    let red: CGFloat
    let green: CGFloat
    let blue: CGFloat
    let alpha: CGFloat
}

private func resolvedRGBA(_ color: NSColor, for appearance: NSAppearance) -> RGBA? {
    var result: RGBA?
    appearance.performAsCurrentDrawingAppearance {
        guard let resolved = color.usingColorSpace(.sRGB) else {
            return
        }
        result = RGBA(
            red: resolved.redComponent,
            green: resolved.greenComponent,
            blue: resolved.blueComponent,
            alpha: resolved.alphaComponent
        )
    }
    return result
}

private func resolvedRGBA(_ color: Color, for appearance: NSAppearance) -> RGBA? {
    resolvedRGBA(NSColor(color), for: appearance)
}

private func close(_ lhs: CGFloat, _ rhs: CGFloat, tolerance: CGFloat = 0.002) -> Bool {
    abs(lhs - rhs) <= tolerance
}

private func checkRGBA(
    _ runner: TestRunner,
    _ color: NSColor,
    appearance: NSAppearance,
    expected: RGBA,
    _ message: String
) {
    guard let actual = resolvedRGBA(color, for: appearance) else {
        runner.check(false, "\(message) should resolve into device RGB")
        return
    }
    runner.check(
        close(actual.red, expected.red)
            && close(actual.green, expected.green)
            && close(actual.blue, expected.blue)
            && close(actual.alpha, expected.alpha),
        "\(message) resolved to \(actual), expected \(expected)"
    )
}

private func checkRGBA(
    _ runner: TestRunner,
    _ color: Color,
    appearance: NSAppearance,
    expected: RGBA,
    _ message: String
) {
    checkRGBA(runner, NSColor(color), appearance: appearance, expected: expected, message)
}

private func relativeLuminance(_ component: CGFloat) -> CGFloat {
    component <= 0.03928
        ? component / 12.92
        : pow((component + 0.055) / 1.055, 2.4)
}

private func contrastRatio(_ foreground: RGBA, _ background: RGBA) -> CGFloat {
    let foregroundLuminance = 0.2126 * relativeLuminance(foreground.red)
        + 0.7152 * relativeLuminance(foreground.green)
        + 0.0722 * relativeLuminance(foreground.blue)
    let backgroundLuminance = 0.2126 * relativeLuminance(background.red)
        + 0.7152 * relativeLuminance(background.green)
        + 0.0722 * relativeLuminance(background.blue)
    let lighter = max(foregroundLuminance, backgroundLuminance)
    let darker = min(foregroundLuminance, backgroundLuminance)
    return (lighter + 0.05) / (darker + 0.05)
}

private func checkContrast(
    _ runner: TestRunner,
    foreground: Color,
    background: Color,
    appearance: NSAppearance,
    _ message: String
) {
    guard let foreground = resolvedRGBA(foreground, for: appearance),
          let background = resolvedRGBA(background, for: appearance) else {
        runner.check(false, "\(message) should resolve both colors")
        return
    }
    runner.check(
        contrastRatio(foreground, background) >= 4.5,
        "\(message) should maintain WCAG AA contrast; actual \(contrastRatio(foreground, background))"
    )
}

let runner = TestRunner()
let aqua = NSAppearance(named: .aqua)!
let darkAqua = NSAppearance(named: .darkAqua)!
let highContrastAqua = NSAppearance(named: .accessibilityHighContrastAqua)!
let highContrastDarkAqua = NSAppearance(named: .accessibilityHighContrastDarkAqua)!

private let lightBackground = RGBA(red: 248 / 255, green: 249 / 255, blue: 247 / 255, alpha: 1)
private let darkBackground = RGBA(red: 30 / 255, green: 32 / 255, blue: 36 / 255, alpha: 1)
let dynamicBackground = MonitorTheme.detailBackground
let dynamicBackgroundNSColor = NSColor(dynamicBackground)
checkRGBA(runner, dynamicBackgroundNSColor, appearance: aqua, expected: lightBackground, "light detail background")
checkRGBA(runner, dynamicBackgroundNSColor, appearance: darkAqua, expected: darkBackground, "dark detail background")
checkRGBA(runner, dynamicBackgroundNSColor, appearance: aqua, expected: lightBackground, "light detail background after dark resolution")
checkRGBA(runner, dynamicBackgroundNSColor, appearance: highContrastAqua, expected: lightBackground, "high-contrast light detail background")
checkRGBA(runner, dynamicBackgroundNSColor, appearance: highContrastDarkAqua, expected: darkBackground, "high-contrast dark detail background")

checkRGBA(runner, MonitorTheme.sectionFill, appearance: aqua, expected: RGBA(red: 252 / 255, green: 253 / 255, blue: 252 / 255, alpha: 1), "light raised surface")
checkRGBA(runner, MonitorTheme.sectionFill, appearance: darkAqua, expected: RGBA(red: 37 / 255, green: 40 / 255, blue: 45 / 255, alpha: 1), "dark raised surface")
checkRGBA(runner, MonitorTheme.controlFill, appearance: darkAqua, expected: RGBA(red: 43 / 255, green: 48 / 255, blue: 55 / 255, alpha: 1), "dark control surface")
checkRGBA(runner, MonitorTheme.controlSelectedFill, appearance: darkAqua, expected: RGBA(red: 38 / 255, green: 56 / 255, blue: 83 / 255, alpha: 1), "dark selected surface")
checkRGBA(runner, MonitorTheme.textPrimary, appearance: darkAqua, expected: RGBA(red: 231 / 255, green: 234 / 255, blue: 240 / 255, alpha: 1), "dark primary text")
checkRGBA(runner, MonitorTheme.textSecondary, appearance: highContrastDarkAqua, expected: RGBA(red: 168 / 255, green: 176 / 255, blue: 188 / 255, alpha: 1), "high-contrast dark secondary text")
checkRGBA(runner, MonitorTheme.accentBlue, appearance: darkAqua, expected: RGBA(red: 138 / 255, green: 172 / 255, blue: 255 / 255, alpha: 1), "dark accent blue")
checkRGBA(runner, MonitorTheme.healthy, appearance: darkAqua, expected: RGBA(red: 120 / 255, green: 201 / 255, blue: 154 / 255, alpha: 1), "dark healthy status")
checkRGBA(runner, MonitorTheme.warning, appearance: darkAqua, expected: RGBA(red: 233 / 255, green: 184 / 255, blue: 106 / 255, alpha: 1), "dark warning status")
checkRGBA(runner, MonitorTheme.critical, appearance: highContrastDarkAqua, expected: RGBA(red: 241 / 255, green: 138 / 255, blue: 138 / 255, alpha: 1), "high-contrast dark critical status")
checkRGBA(runner, MonitorTheme.routingTooltipSurface, appearance: darkAqua, expected: RGBA(red: 37 / 255, green: 40 / 255, blue: 45 / 255, alpha: 1), "dark tooltip raised surface")

for appearance in [aqua, highContrastAqua] {
    checkContrast(runner, foreground: MonitorTheme.textPrimary, background: MonitorTheme.detailBackground, appearance: appearance, "light primary text")
    checkContrast(runner, foreground: MonitorTheme.textSecondary, background: MonitorTheme.detailBackground, appearance: appearance, "light secondary text")
    checkContrast(runner, foreground: MonitorTheme.textTertiary, background: MonitorTheme.detailBackground, appearance: appearance, "light tertiary text")
    checkContrast(runner, foreground: MonitorTheme.warning, background: MonitorTheme.sectionFill, appearance: appearance, "light warning on raised surface")
    checkContrast(runner, foreground: MonitorTheme.accentBlue, background: MonitorTheme.controlSelectedFill, appearance: appearance, "light accent on selected control")
}
for appearance in [darkAqua, highContrastDarkAqua] {
    checkContrast(runner, foreground: MonitorTheme.textPrimary, background: MonitorTheme.detailBackground, appearance: appearance, "dark primary text")
    checkContrast(runner, foreground: MonitorTheme.textSecondary, background: MonitorTheme.detailBackground, appearance: appearance, "dark secondary text")
    checkContrast(runner, foreground: MonitorTheme.textTertiary, background: MonitorTheme.detailBackground, appearance: appearance, "dark tertiary text")
    checkContrast(runner, foreground: MonitorTheme.accentBlue, background: MonitorTheme.controlSelectedFill, appearance: appearance, "dark accent on selected control")
    checkContrast(runner, foreground: MonitorTheme.healthy, background: MonitorTheme.detailBackground, appearance: appearance, "dark healthy on background")
    checkContrast(runner, foreground: MonitorTheme.warning, background: MonitorTheme.detailBackground, appearance: appearance, "dark warning on background")
    checkContrast(runner, foreground: MonitorTheme.critical, background: MonitorTheme.detailBackground, appearance: appearance, "dark critical on background")
}

checkRGBA(runner, MonitorTheme.Pill.tint, appearance: darkAqua, expected: RGBA(red: 0, green: 0, blue: 0, alpha: 0.48), "collapsed pill tint")
checkRGBA(runner, MonitorTheme.Pill.tint, appearance: aqua, expected: RGBA(red: 0, green: 0, blue: 0, alpha: 0.48), "collapsed pill tint in light appearance")

runner.check(MonitorTheme.analyticsTurnsPalette.count == 7, "turns palette should preserve its existing series count")
runner.check(MonitorTheme.analyticsSkillsPalette.count == 9, "skills palette should preserve its existing series count")
for (index, color) in MonitorTheme.analyticsTurnsPalette.enumerated() {
    checkContrast(runner, foreground: color, background: MonitorTheme.detailBackground, appearance: darkAqua, "dark turns palette series \(index)")
}
for (index, color) in MonitorTheme.analyticsSkillsPalette.enumerated() {
    checkContrast(runner, foreground: color, background: MonitorTheme.detailBackground, appearance: darkAqua, "dark skills palette series \(index)")
}

if runner.failures > 0 {
    exit(1)
}
print("DetailAppearanceTests passed")
