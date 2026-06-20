# CLIProxyAPI Remote Monitor Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add optional remote monitoring for enabled Codex accounts in a CLIProxyAPI management panel without changing the local Codex notch display.

**Architecture:** Keep the existing local `UsageViewModel` path intact. Add a separate `RemoteMonitorViewModel` backed by `CLIProxyAPIClient`, store the management key in Keychain, and surface remote health only as a small collapsed badge plus a separate detail tab.

**Tech Stack:** Swift 6, SwiftUI, AppKit panels, URLSession, Security framework Keychain APIs, CLIProxyAPI `/v0/management/auth-files`.

---

### Task 1: Settings And Secure Secret Storage

**Files:**
- Modify: `Sources/CodexNotch/CodexNotchSettings.swift`
- Create: `Sources/CodexNotch/KeychainStore.swift`

- [x] Add remote monitoring settings: enabled flag, panel URL, refresh interval, timeout, TLS override, and Keychain-backed management key.
- [x] Use `com.alight.codexnotch.cliproxy.management-key` as the Keychain service and `default` as the account.
- [x] Keep the management key out of UserDefaults and source files.

### Task 2: CLIProxyAPI Client And Models

**Files:**
- Create: `Sources/CodexNotch/RemoteMonitorModels.swift`
- Create: `Sources/CodexNotch/CLIProxyAPIClient.swift`

- [x] Normalize either a panel URL like `/management.html` or an API URL to `<origin>/v0/management`.
- [x] Request `GET /auth-files` with `Authorization: Bearer <key>`.
- [x] Filter enabled Codex accounts and classify states as healthy, quota exhausted, account abnormal, or connection error.
- [x] Support optional insecure TLS only when the setting is enabled.

### Task 3: Remote Monitor ViewModel

**Files:**
- Create: `Sources/CodexNotch/RemoteMonitorViewModel.swift`
- Modify: `Sources/CodexNotch/AppDelegate.swift`

- [x] Refresh remote status on a separate timer from local Codex usage.
- [x] Add backoff after connection failures and refresh immediately when remote settings change.
- [x] Inject the remote view model into the collapsed island and detail panel.

### Task 4: Collapsed Badge And Detail Tabs

**Files:**
- Modify: `Sources/CodexNotch/NotchIslandView.swift`
- Modify: `Sources/CodexNotch/IslandMetrics.swift`

- [x] Add a tiny remote alert badge that appears only for remote warnings/errors.
- [x] Add a `本机 / 远程` segmented control inside the expanded panel.
- [x] Keep the current local details unchanged on the `本机` tab.
- [x] Add compact remote account rows on the `远程` tab.

### Task 5: Settings UI

**Files:**
- Modify: `Sources/CodexNotch/SettingsView.swift`

- [x] Add a `远程监测` section with enable toggle, panel URL, management key, refresh interval, timeout, insecure TLS option, and manual refresh.
- [x] Use `SecureField` for the key and persist it through `CodexNotchSettings`.

### Task 6: Verification And Packaging

**Files:**
- No source files.

- [x] Run `swift build`.
- [x] Run `./scripts/build-app.sh`.
- [x] Install `/Applications/Codex Notch.app`.
- [x] Verify `--print-fast-snapshot` still works.
- [x] Verify the remote monitor can fetch status or reports a clear connection/auth error.
- [x] Rebuild and verify `dist/Codex Notch.dmg`.
