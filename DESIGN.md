# Codex Monitor Visual System

## Intent

Codex Monitor is a compact macOS HUD for people who keep Codex running all day. The collapsed capsule stays dark for desktop contrast; the expanded 520pt detail panel is opaque, light, calm, and precise. This separation is intentional, not a system-appearance toggle.

The product is not a marketing site. Do not use oversized hero typography, decorative gradient backgrounds, brand mascots, or landing-page card stacks inside the app.

## Reference Direction

This project uses public `DESIGN.md` systems from `VoltAgent/awesome-design-md` as reference material only.

- Primary reference: Linear-style software density, hairline separators, and restrained accent usage, adapted to native macOS rather than its website or dark palette.
- Capsule reference: Raycast-style command-palette dark chrome, confined to the collapsed HUD.
- Do not copy Raycast or Linear brand identity, proprietary marks, red brand stripes, lavender brand treatment, marketing CTAs, or website-specific layout patterns.

## Atmosphere

- Native macOS utility, not web app chrome.
- HUD first: a translucent near-black collapsed capsule and an opaque warm-white detail panel; compact tables and restrained depth.
- The floating HUD is the default identity. The optional menu-bar mode removes the pill surface, uses a high-contrast custom monitor mark, and prioritizes the remaining 5-hour quota; full metrics remain available in the detail panel.
- Developer tool: values, quota windows, task rows, and error states must be more legible than decorative.
- Quiet polish: detail hierarchy comes from spacing, typography and separators, not translucent grey layers or decorative gradients.

## Color Roles

### HUD Surfaces

- `hud.pill`: near-black translucent surface for the collapsed notch capsule.
- `hud.detail`: opaque `#F8F9F7`, with no visual-effect material behind detail content.
- `hud.section` / `hud.row`: quiet, nearly white neutral surfaces; prefer separators to nested cards.
- `hud.rowSelected`: pale neutral hover/selection, never a full green running row.
- `hud.control`: neutral compact controls.
- `hud.controlSelected`: pale blue `#EAF0FF` with blue `#365DC7` labels.
- `hud.hairline` / `hud.separator`: subtle neutral-grey boundaries.
- Collapsed-only tokens must preserve their original white-on-dark contrast independently of these detail tokens.

### Text

- `text.primary`: `#252A31` for labels and important values.
- `text.secondary`: `#616B76` for table headers and secondary metadata.
- `text.tertiary`: sufficiently contrasting neutral grey; do not fade meaningful metadata below readable contrast.

### Status

- `status.healthy`: quota available, idle OK, successful remote account.
- `status.running`: restrained blue, represented with a dot plus text, not a broad tinted row.
- `status.warning`: quota approaching threshold or stale data.
- `status.critical`: error, exhausted quota, invalid credentials.
- `status.neutral`: inactive, unknown, or disabled.

Use status color only where it communicates state. Avoid broad colored backgrounds.

## Typography

Use system fonts. The app should inherit macOS sharpness and rendering.

- Detail title: 20pt, semibold; main quota/Today values: 34pt, medium.
- Task title/value: 13pt; metadata: 11pt. Keep monospaced digits and aligned numeric columns.
- HUD labels: 10-11px, semibold.
- HUD values: 10-17px, semibold, rounded design for numbers where useful.
- Settings title: 18px, bold.
- Settings labels: 11-12px, semibold.
- Settings helper text: 10.5-11px, medium.

Do not scale font size with viewport width. Do not use negative letter spacing.

## Shape And Depth

- HUD capsule radius: 15px.
- Expanded notch bottom radius: 22px.
- Compact row/card radius: 8px.
- Larger grouped controls: 9-10px.
- Status chips: capsule or 4px rounded rectangles depending on density.
- Use 0.5-0.8px hairline strokes for HUD controls and rows.
- Shadows should be low and functional; do not add glow unless it indicates running state.

## Layout Principles

- Preserve information density. This is a monitoring tool, not a dashboard landing page.
- Keep the first viewport useful: collapsed capsule should show status and key metrics; expanded detail should show task state without scrolling whenever possible.
- Prefer tables and compact rows over large cards for repeated operational data.
- Keep controls stable in size. Hover, refresh, status, and changing values must not resize the layout.
- Make tab labels and metric labels short. Let exact definitions live in docs, not in the HUD.

## Component Rules

### Collapsed Capsule

- Must remain readable over both light and dark desktop backgrounds.
- Show only the highest-value metrics.
- Status dot and `RUN` / `IDLE` are primary signals.
- Avoid adding decorative icons or long text.

### Detail Panel

- Treat it as a native light utility panel with tabs. Apply a light color scheme only to the expanded panel; settings remain semantic and the collapsed capsule remains dark.
- Use separators and whitespace before adding section backgrounds or borders.
- Keep `Codex`, `Skills`, `Codex Radar`, `CLIProxyAPI`, `NewAPI`, and `Sub2API` visually related.
- Keep Skill Insights in the expanded detail panel; never add its weekly metrics
  to the collapsed capsule or menu-bar item.
- Treat a source as presentation-visible only while its expanded detail tab is
  selected. The collapsed capsule and menu-bar item render cached state without
  selecting the foreground refresh cadence.
- Present catalog cost, evidence counts, completeness, and recommendations as a
  compact operational table. Keep heuristic evidence visibly distinct from
  confirmed use and label per-Skill Token as unavailable.
- Treat the local Codex `skills/list` result as the catalog authority. A direct
  frontmatter scan is a `PARTIAL` fallback and must not present inactive plugin
  cache entries as complete current state.
- Keep Skill Insights behind its own setting. When disabled, remove the tab and
  do not instantiate its catalog loader, scanner, database connection, or timer;
  the realtime Codex monitor remains an independent capability.
- Keep performance diagnostics in a compact operational table with current CPU,
  resident memory, 30-second CPU peak, and process identity. The first finding
  may use a restrained warning surface; do not turn the page into a card grid.
- Label WindowServer as compositor pressure rather than FPS, and label the
  hottest WebKit process as an unverified owner candidate. Never imply tab-level
  attribution that the source cannot prove.
- Background performance monitoring is controlled by an explicit setting that
  defaults off. The Performance tab remains available for a manual snapshot;
  the setting governs sampling while the detail panel is closed.
- Do not nest decorative cards inside cards.

### Quota And Usage

- Quota bars should be quiet until thresholds matter.
- Healthy quota is green; warning and critical states take over only at thresholds.
- `Today`, 5h, 7d, and 30d values should scan as numbers first, explanations second.
- Keep reset-credit availability in the existing provenance row as tertiary text; do not add a new quota card or increase panel height.
- Place weekly quota and Today Token side by side at the top; subordinate 7d/30d totals below Today. Keep API-equivalent costs in an accessible disclosure labeled `API 等值，非订阅账单`.
- Show `回填中` instead of a monetary subtotal until the complete local history snapshot is ready. Preserve the last complete amount during later incremental scans; append `*` only when a complete snapshot contains unpriced models. Explain the fact that this is not a subscription bill through help and accessibility text rather than permanent chrome.
- Once that complete snapshot exists, use its Today/7d/30d token buckets, so Token and cost figures retain their existing lineage accounting. Keep CLI/Node/JSON token contracts unchanged.
- Keep pace language deterministic and compact: either the current rate lasts
  until reset or it has a projected exhaustion time. Hide pace when inputs are
  insufficient rather than implying precision.
- Show quota source and freshness as secondary provenance. Never expose paths,
  account identifiers, credentials, prompts, or tool payloads.

### Task Table And Evidence

- Default to five roots in the existing Store order. `查看全部` only expands the roots already in the snapshot; it must not trigger a new scan or imply that query-limited history is exhaustive.
- Use two-line rows: task title with status metadata; Today Token with one-decimal whole-day share; lifetime Token in its own column. Remove green left stripes and full-row running tints.
- Published Today includes attributed child agents only when `hasReconciledTodayLedger` is true. Otherwise visibly label the existing local estimate. Never present the fallback as a reconciled ledger.
- Lifetime is the existing thread cumulative counter, not a new root-plus-child sum. Explain that distinction in help and VoiceOver; do not alter or inflate the data to make Today smaller than lifetime.
- If a reconciled ledger contains Token outside the available root list, an expanded `其他本地记录` summary may show the exact remainder. It is not another task and has no lifetime total. Never label known omitted roots as un-attributed.
- Unknown Token is `--`, real zero is `0`, and zero/unknown share denominators show `--` with `暂无占比`. Display one decimal for 万/亿, preserving one decimal for 亿 and handling rounding carry with integer arithmetic. Existing public compact formatters remain unchanged.
- Exact integer Token counts and the real scope must remain available in help and accessibility text.
- AGY quota availability and Sidecar health remain independent. Existing cache timestamps, unavailable states and official-login failures must not be converted into healthy values by presentation.
- This redesign adds no provider calls, timers, scanners, permissions, notifications or model invocations.

### Settings

- Settings may use macOS semantic colors so the window remains native in light and dark mode.
- Settings should share radius, typography, and hierarchy tokens with the HUD where practical.
- Sidebar selection should be subtle and precise, not a bright brand block.

## Do

- Use compact spacing, 8px radius, and hairline borders.
- Make state changes visually obvious but not loud.
- Keep model/quota/task data readable at a glance.
- Prefer semantic status colors over decorative palettes.
- Add new UI through shared theme tokens first.

## Do Not

- Do not copy another brand's full visual identity.
- Do not introduce landing-page hero patterns inside the app.
- Do not add decorative orbs, bokeh, or large gradients.
- Do not make the app a one-hue purple/blue theme.
- Do not hide or reduce operational data to make the interface look cleaner.
