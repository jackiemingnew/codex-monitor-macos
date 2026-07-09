# UI Visual Review

Date: 2026-07-09

Review baseline: `DESIGN.md` and `MonitorTheme`.

Scope:

- Static review: `NotchIslandView.swift`, `SettingsView.swift`, `MonitorTheme.swift`.
- Visual review: current collapsed notch capsule from the installed app.
- Visual review: expanded detail panel opened via low-level CGEvent, with screenshots of the `Codex Radar` and `Codex` tabs.
- Settings visual coverage is based on source review in this pass; the settings window was not separately screenshot-reviewed.

No P0 issues were found. The current UI remains usable and information-dense.

## First-Round Fixes

These P1 issues were resolved in `be10f92`:

- Expanded detail panel readability: `detailTint` is darker while the collapsed capsule tint remains unchanged.
- Codex Radar model cards: card shells use neutral `rowFill` + hairline, with status color limited to the dot, score, and narrow accent rail.
- Codex Radar quota rows: ordinary high values now use primary/secondary text; threshold values use semantic quota color.
- About mark: the multi-accent logo mark was simplified into a neutral HUD mark with a status dot and hairline.

## Second-Round Fixes

These P2 issues were resolved after the first-round pass:

- Settings helper/error/status typography now uses `MonitorTheme.Typography` and semantic settings colors.
- Settings account list borders use the settings hairline stroke instead of a heavier `1px` outline.
- Remaining HUD row/control/section radii and hairline widths were migrated to `MonitorTheme.Radius.*` and `MonitorTheme.Stroke.*`.
- Remote account plan metadata now uses a neutral control chip instead of a bright decorative yellow badge.

No open P0/P1/P2 issues remain from this review. Future visual work should be treated as P3 polish unless a new screenshot or runtime state shows a readability, layout, or semantic-color regression.

## Spacing Audit

The primary Codex spacing pass standardizes the high-visibility metric areas around `MonitorTheme.Spacing`:

- Collapsed capsule: `RUN/IDLE` to metrics uses `inline`; metric-to-metric uses `inline`; metric label/value uses `compact`.
- Collapsed metric widths: `5h` and `7d` use `13/34`; `Today` uses `28/50`, preserving space for `100%`, `99.9M`, and `100M`.
- Detail quota strip: the main `5h Quota`, `7d Quota`, and `Running` groups use `wide`; `QuotaBarCell` internal title/value and bar/reset spacing use `inline`.
- Spark strip: strip contents use `row`; chip label/value spacing uses `compact`.
- Period usage cards: `今日 / 7天 / 30天` card spacing uses `row`; each card label/value vertical rhythm uses `compact`.

Acceptance target: metrics should read as compact pairs without `100% 7d` or `Today 99.9M` visually sticking together, and detail cards should keep equal rhythm without loosening the HUD density.

| Surface | Element | Issue | DESIGN.md Rule | Severity | Recommendation | File/Line |
|---|---|---|---|---|---|---|
| Settings | Empty-state icon size | The account-list empty state still uses a direct SF Symbol font size. This is acceptable because it is icon sizing rather than text hierarchy, but it can be tokenized if more empty states appear. | Settings should share radius, typography, and hierarchy tokens with the HUD where practical. | P3 | Leave as-is for now. Introduce an icon-size token only if additional Settings empty states need the same treatment. | `Sources/CodexNotch/SettingsView.swift:811` |

## Recommended Fix Order

1. Keep future changes routed through `MonitorTheme` first.
2. Screenshot Settings, account editor, remote tabs, Codex tab, and Codex Radar tab after any new visual change.
3. Treat new P0/P1/P2 findings as regressions and fix them before release.
4. For spacing changes in metric areas, reuse `MonitorTheme.Spacing` and preserve fixed-width columns for changing values.

## Verification For Follow-Up Changes

- `scripts/run-regression-tests.sh`
- `swift build -c release --arch arm64`
- Visual check: collapsed capsule, Codex tab, Codex Radar tab, remote/balance tab, Settings sidebar, account list, account editor, About mark.
