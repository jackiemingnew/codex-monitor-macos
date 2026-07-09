# UI Visual Review

Date: 2026-07-09

Review baseline: `DESIGN.md` and `MonitorTheme`.

Scope:

- Static review: `NotchIslandView.swift`, `SettingsView.swift`, `MonitorTheme.swift`.
- Visual review: current collapsed notch capsule from the installed app.
- Visual review: expanded detail panel opened via low-level CGEvent, with screenshots of the `Codex Radar` and `Codex` tabs.
- Settings visual coverage is based on source review in this pass; the settings window was not separately screenshot-reviewed.

No P0 issues were found. The current UI remains usable and information-dense. The main gaps are token adoption, status-color restraint, and a few elements that are visually richer than the new system allows.

| Surface | Element | Issue | DESIGN.md Rule | Severity | Recommendation | File/Line |
|---|---|---|---|---|---|---|
| Expanded detail panel | Panel translucency over bright/text-heavy backgrounds | In real expanded screenshots, the detail panel remains usable but the desktop/app content behind it shows through strongly. On a white text-heavy background, small table text and secondary metadata lose contrast. | HUD first: translucent near-black panels, compact tables, small status chips, and restrained depth. Values and rows must be more legible than decorative. | P1 | Increase `detailTint` opacity or add a subtle readability scrim behind the expanded panel while keeping the collapsed capsule unchanged. Verify over both bright text windows and dark desktop backgrounds. | `Sources/CodexNotch/MonitorTheme.swift:26` |
| Codex Radar tab | Model score cards | The full card background and border are tinted with `statusColor`. This makes status color act as a broad decorative surface instead of a state marker. | Use status color only where it communicates state. Avoid broad colored backgrounds. | P1 | Use `MonitorTheme.rowFill` plus `MonitorTheme.hairline` for the card shell. Keep status color on the dot, score text, or a narrow accent rail only. | `Sources/CodexNotch/NotchIslandView.swift:1948` |
| Codex Radar tab | Quota radar rows | `5h` values are always `running` blue and `7d` values are always `healthy` green, regardless of threshold or state. This can make ordinary numeric columns look semantically evaluated. | Status colors must express state, not column identity. Values should scan as numbers first. | P1 | Render quota numbers with primary/secondary text by default. Apply `quotaColor` only when a percent/threshold state exists. | `Sources/CodexNotch/NotchIslandView.swift:1995` |
| About / app mark | AppLogoMark | The mark combines a dark gradient, green glow, blue waveform, and cyan underline. As a one-off decorative island, it is louder than the surrounding native utility UI. | Quiet polish should come from opacity, hairline borders, and spacing, not colorful decoration. Do not introduce decorative gradients. | P1 | Simplify to a tokenized notch/pill mark: neutral dark surface, one status dot, one hairline stroke, no glow, no multi-accent waveform. | `Sources/CodexNotch/SettingsView.swift:1745` |
| Expanded HUD | Radii and hairlines | The view now has shared radius/stroke tokens, but many HUD surfaces still hardcode `6`, `8`, `9`, `10`, `15`, `0.6`, `0.7`, and `0.8`. This weakens the new visual system as the source of truth. | Add new UI through shared theme tokens first. Use 8px row/card radius and 0.5-0.8px hairlines. | P2 | Replace hardcoded HUD radii/strokes with `MonitorTheme.Radius.*` and `MonitorTheme.Stroke.*` in a focused mechanical pass. | `Sources/CodexNotch/NotchIslandView.swift:116` |
| Settings | Helper/error/status typography | Settings still contains many direct `.font(.system(...))`, `.secondary`, `.red`, `.orange`, and `Color.green` usages. The first token pass only covers sidebar and a few grouped surfaces. | Settings should share radius, typography, and hierarchy tokens with the HUD where practical. | P2 | Add settings tokens for helper, status, error, warning, and small-label typography; migrate repeated direct usages in sections, footer, status rows, and account rows. | `Sources/CodexNotch/SettingsView.swift:486` |
| Settings | Account list surface | Account list uses shared colors/radius, but the stroke remains `lineWidth: 1`, heavier than the HUD hairline range and visually stronger than other compact rows. | Use 0.5-0.8px hairline strokes for controls and rows. | P2 | Use `MonitorTheme.Stroke.hairline` or introduce `settingsHairlineWidth` so Settings surfaces keep native feel without becoming heavier than HUD rows. | `Sources/CodexNotch/SettingsView.swift:846` |
| Collapsed capsule | Capsule shell | The collapsed capsule visually reads well in the captured desktop screenshot, but its radius and panel stroke are still hardcoded instead of using the new tokens. | Collapsed capsule radius: 15px. Add new UI through shared theme tokens first. | P2 | Replace hardcoded `15` and `0.7` with `MonitorTheme.Radius.collapsedPill` and `MonitorTheme.Stroke.panel`. | `Sources/CodexNotch/NotchIslandView.swift:116` |
| Settings | Account enabled state | Account rows use `Color.green` directly for enabled state. It is semantically correct, but not routed through the shared status palette. | Prefer semantic status colors over decorative palettes. | P2 | Use a settings status token or `MonitorTheme.healthy`, depending on whether the row should feel native or HUD-like. | `Sources/CodexNotch/SettingsView.swift:887` |

## Recommended Fix Order

1. Improve expanded detail panel readability over bright/text-heavy backgrounds.
2. Fix P1 status-color overuse in Codex Radar cards and quota rows.
3. Simplify `AppLogoMark` so About does not become the only decorative island.
4. Run a mechanical token adoption pass for HUD radii/strokes.
5. Expand settings typography/color tokens and migrate repeated helper/error/status labels.

## Verification For Follow-Up Changes

- `scripts/run-regression-tests.sh`
- `swift build -c release --arch arm64`
- Visual check: collapsed capsule, Codex tab, Codex Radar tab, remote/balance tab, Settings sidebar, account list, account editor, About mark.
