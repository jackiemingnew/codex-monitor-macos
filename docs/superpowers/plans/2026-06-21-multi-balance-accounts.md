# Multi Balance Accounts Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add multi-account NewAPI/Sub2API balance monitoring with default and per-account thresholds, tabbed settings, richer balance details, and CLIProxyAPI quota wrapping.

**Architecture:** Replace the single NewAPI/Sub2API credential fields with account arrays stored in UserDefaults plus one Keychain password per account. `BalanceMonitorViewModel` will refresh all enabled accounts for a source and aggregate severities; UI rows will keep per-account balance, used balance, and token usage separate so mixed currencies are not incorrectly summed.

**Tech Stack:** Swift Package, SwiftUI/AppKit, UserDefaults, macOS Keychain, existing shell regression harness.

---

### Task 1: Regression Coverage

**Files:**
- Modify: `Tests/CodexNotchRegressionTests/main.swift`

- [ ] Add tests for balance threshold classification: below alert is `.error`, below warning is `.warning`, normal is `.healthy`.
- [ ] Add tests that multi-currency total text groups balances instead of summing incompatible units.
- [ ] Add tests that legacy single-account NewAPI/Sub2API settings migrate into account arrays.
- [ ] Add tests that CLIProxyAPI quota summaries can include four windows without truncating the model-level data.
- [ ] Run `./scripts/run-regression-tests.sh` and confirm the new tests fail before implementation.

### Task 2: Balance Account Model And Migration

**Files:**
- Modify: `Sources/CodexNotch/BalanceMonitorModels.swift`
- Modify: `Sources/CodexNotch/CodexNotchSettings.swift`
- Modify: `Sources/CodexNotch/BalanceAPIClient.swift`
- Modify: `Sources/CodexNotch/BalanceMonitorViewModel.swift`

- [ ] Add `BalanceAccountConfiguration` with id, source, enabled, label, panel URL, username, allow insecure TLS, timeout, threshold mode, warning threshold, and alert threshold.
- [ ] Add `BalanceThresholdConfiguration` with default thresholds and account override support.
- [ ] Store NewAPI/Sub2API account arrays as JSON in UserDefaults.
- [ ] Store passwords in Keychain using service names scoped by source and account id.
- [ ] Migrate existing single-account fields into one account per source when no account array exists.
- [ ] Refresh all enabled accounts concurrently with bounded timeout; produce one `BalanceAccount` row per account plus optional platform quota child rows for Sub2API.
- [ ] Preserve partial successful rows when one account fails.

### Task 3: Thresholds And Mixed Currency Display

**Files:**
- Modify: `Sources/CodexNotch/BalanceMonitorModels.swift`
- Modify: `Sources/CodexNotch/BalanceAPIClient.swift`
- Modify: `Sources/CodexNotch/NotchIslandView.swift`

- [ ] Track numeric balance amount and display unit alongside `amountText`.
- [ ] Apply account-specific thresholds first; fall back to source defaults.
- [ ] Compute source severity from worst account state.
- [ ] Make total balance text sum only compatible units; otherwise show grouped values or `多币种 N 类`.
- [ ] Show used balance and used token/token-equivalent data when available; show `--` only when the API does not expose it.

### Task 4: Tabbed Settings And Account Management

**Files:**
- Modify: `Sources/CodexNotch/SettingsView.swift`

- [ ] Add tabs: `Codex`, `远程 Codex`, `NewAPI`, `Sub2API`, `启动与外观`.
- [ ] Move existing sections into the relevant tab without changing their saved behavior.
- [ ] Replace NewAPI/Sub2API single forms with account lists.
- [ ] Add account editor state for add/edit, with save/cancel behavior that updates only the settings draft.
- [ ] Account list rows show enabled state, label, host, username/email, current status, and threshold source.
- [ ] Delete account with confirmation copy indicating that the password is removed from Keychain on save.

### Task 5: CLIProxyAPI Quota Layout

**Files:**
- Modify: `Sources/CodexNotch/RemoteMonitorModels.swift`
- Modify: `Sources/CodexNotch/NotchIslandView.swift`

- [ ] Keep all quota windows in `quotaSummaryText` data.
- [ ] Render remote account quota windows as chips that wrap to a second line.
- [ ] Adjust remote account row height to remain stable when two quota lines are present.
- [ ] Collapsed notch state continues to show aggregate healthy/problem counts only.

### Task 6: Verification And Release

**Files:**
- Modify as needed from previous tasks.

- [ ] Run `./scripts/run-regression-tests.sh`.
- [ ] Run `./scripts/build-app.sh`.
- [ ] Replace `/Applications/Codex Notch.app` with `dist/Codex Notch.app`.
- [ ] Verify with `codesign --verify --deep --strict --verbose=2 /Applications/Codex\ Notch.app`.
- [ ] Verify DMG with `hdiutil verify dist/Codex\ Notch.dmg`.
- [ ] Launch the updated app.
- [ ] Commit the implementation.

