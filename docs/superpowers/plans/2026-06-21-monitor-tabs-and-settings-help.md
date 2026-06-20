# Multi-Source Monitoring Tabs And Settings Help

## Goal

Turn the detail panel into a multi-tab monitor while keeping the local Codex view stable. Merge CLIProxyAPI and CPA Manager Plus into one remote Codex monitor with a selectable data source, add NewAPI/SubAPI balance tabs, let the user choose which source is shown in the collapsed notch, and add help popovers to settings labels.

## Design

- Keep the existing Codex tab as the local task and quota monitor.
- Rename the remote Codex concept to a single monitor with two data sources:
  - CLIProxyAPI: reads enabled Codex accounts directly from the panel.
  - CPA Manager Plus: reads server-side inspection and usage totals when available.
- Add NewAPI and SubAPI monitors as NewAPI-compatible balance sources. Each monitor can be enabled independently and stores its token in its own Keychain service.
- Add a collapsed-notch display source setting: automatic, Codex, remote Codex, NewAPI, or SubAPI. Disabled or unavailable sources fall back to Codex.
- Keep each detail tab with a consistent header/switcher height, a scrollable middle list, and bottom summary cards pinned to the bottom.
- Add a small `?` help button beside each meaningful setting label and show a compact popover with the detailed explanation.

## Implementation Checklist

- [ ] Add source/display enums and balance-monitor models.
- [ ] Add failing regression coverage for source persistence, remote data-source selection, and NewAPI-compatible balance decoding.
- [ ] Extend settings storage, Keychain handling, and the settings draft/save flow.
- [ ] Split remote Codex fetch behavior by data source while preserving existing CPA Manager Plus inspection behavior.
- [ ] Add NewAPI/SubAPI balance client and view models.
- [ ] Update collapsed notch and detail panel to support multi-tab content and manual display source selection.
- [ ] Add setting help popovers.
- [ ] Run six focused code-review subagents, verify findings, fix confirmed issues.
- [ ] Run regression/build/package verification, commit, and update the installed app.
