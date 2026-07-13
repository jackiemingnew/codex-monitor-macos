# Codex Monitor Visual System

## Intent

Codex Monitor is a compact macOS HUD for people who keep Codex running all day. The visual system should feel like a native command palette attached to the MacBook notch: dark, calm, precise, and easy to scan while work is in progress.

The product is not a marketing site. Do not use oversized hero typography, decorative gradient backgrounds, brand mascots, or landing-page card stacks inside the app.

## Reference Direction

This project uses public `DESIGN.md` systems from `VoltAgent/awesome-design-md` as reference material only.

- Primary reference: Raycast-style command-palette dark chrome.
- Constraint reference: Linear-style software density, hairline borders, and restrained accent usage.
- Do not copy Raycast or Linear brand identity, proprietary marks, red brand stripes, lavender brand treatment, marketing CTAs, or website-specific layout patterns.

## Atmosphere

- Native macOS utility, not web app chrome.
- HUD first: translucent near-black panels, compact tables, small status chips, and restrained depth.
- The floating HUD is the default identity. The optional menu-bar mode removes the pill surface, uses a high-contrast custom monitor mark, and prioritizes the remaining 5-hour quota; full metrics remain available in the detail panel.
- Developer tool: values, quota windows, task rows, and error states must be more legible than decorative.
- Quiet polish: surface hierarchy should come from opacity, hairline borders, and spacing, not from colorful decoration.

## Color Roles

### HUD Surfaces

- `hud.pill`: near-black translucent surface for the collapsed notch capsule.
- `hud.detail`: near-black translucent surface for the expanded panel.
- `hud.section`: subtle white overlay for grouped areas.
- `hud.row`: subtle white overlay for rows and compact cards.
- `hud.rowSelected`: stronger white overlay for selected rows.
- `hud.control`: compact controls, pills, and filters.
- `hud.controlSelected`: active segmented control or selected pill.
- `hud.hairline`: low-contrast white border.
- `hud.separator`: low-contrast separator line.

### Text

- `text.primary`: high-contrast white for labels and important values.
- `text.secondary`: muted white for table headers and secondary metadata.
- `text.tertiary`: faint white for helper text and disabled values.

### Status

- `status.healthy`: quota available, idle OK, successful remote account.
- `status.running`: active work, token activity, informational positive state.
- `status.warning`: quota approaching threshold or stale data.
- `status.critical`: error, exhausted quota, invalid credentials.
- `status.neutral`: inactive, unknown, or disabled.

Use status color only where it communicates state. Avoid broad colored backgrounds.

## Typography

Use system fonts. The app should inherit macOS sharpness and rendering.

- HUD title: 16px, semibold.
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

- Treat it as a command-palette panel with tabs.
- Use subtle section backgrounds and hairline borders.
- Keep `Codex`, `Skills`, `Codex Radar`, `CLIProxyAPI`, `NewAPI`, and `Sub2API` visually related.
- Keep Skill Insights in the expanded detail panel; never add its weekly metrics
  to the collapsed capsule or menu-bar item.
- Present catalog cost, evidence counts, completeness, and recommendations as a
  compact operational table. Keep heuristic evidence visibly distinct from
  confirmed use and label per-Skill Token as unavailable.
- Treat the local Codex `skills/list` result as the catalog authority. A direct
  frontmatter scan is a `PARTIAL` fallback and must not present inactive plugin
  cache entries as complete current state.
- Keep Skill Insights behind its own setting. When disabled, remove the tab and
  do not instantiate its catalog loader, scanner, database connection, or timer;
  the realtime Codex monitor remains an independent capability.
- Do not nest decorative cards inside cards.

### Quota And Usage

- Quota bars should be quiet until thresholds matter.
- Healthy quota is green; warning and critical states take over only at thresholds.
- `Today`, 5h, 7d, and 30d values should scan as numbers first, explanations second.

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
