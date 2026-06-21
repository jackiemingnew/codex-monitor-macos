# Secret Storage Vault Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Store all remote/API secrets through a single vault so Keychain prompts happen at most once, and add an optional local database storage mode.

**Architecture:** Introduce a `SecretVault` value object and `SecretStore` protocol. Keychain mode stores the encoded vault in one Keychain item and migrates legacy per-account items into that vault; database mode stores the same vault JSON in a local app-support SQLite database. `CodexNotchSettings` reads one vault during initialization, writes through the selected store, and exposes a settings picker for storage mode.

**Tech Stack:** Swift, Security.framework Keychain APIs, `/usr/bin/sqlite3` via the existing `Shell.run`, SwiftUI settings view, regression harness in `Tests/CodexNotchRegressionTests/main.swift`.

---

### Task 1: Secret Vault Model And Store Tests

**Files:**
- Create: `Sources/CodexNotch/SecretStore.swift`
- Modify: `Tests/CodexNotchRegressionTests/main.swift`

- [ ] Add regression checks that `SecretVault` can store CLIProxyAPI, NewAPI, Sub2API, and account-scoped secrets under stable keys.
- [ ] Add regression checks that an in-memory secret store persists and reloads one complete vault.
- [ ] Run `./scripts/run-regression-tests.sh` and verify it fails because `SecretVault` does not exist yet.

### Task 2: Implement Secret Stores

**Files:**
- Create: `Sources/CodexNotch/SecretStore.swift`
- Modify: `Sources/CodexNotch/KeychainStore.swift`
- Modify: `scripts/run-regression-tests.sh`

- [ ] Implement `SecretStorageMode`, `SecretKey`, `SecretVault`, `SecretStore`, `KeychainSecretStore`, `DatabaseSecretStore`, and `MemorySecretStore`.
- [ ] Keep Keychain mode to one item: service `com.alight.codexnotch.secret-vault`, account `default`.
- [ ] Store database vault JSON in an SQLite table `secret_vault(id TEXT PRIMARY KEY, payload TEXT NOT NULL, updated_at REAL NOT NULL)`.
- [ ] Add `SecretStore.swift` to the regression harness file list.
- [ ] Run `./scripts/run-regression-tests.sh` and verify the new vault tests pass.

### Task 3: Settings Integration And Legacy Migration

**Files:**
- Modify: `Sources/CodexNotch/CodexNotchSettings.swift`
- Modify: `Tests/CodexNotchRegressionTests/main.swift`

- [ ] Add `secretStorageMode` to persisted settings, defaulting to `.keychain`.
- [ ] Load one vault from the selected store during initialization.
- [ ] If the new Keychain vault is empty, read legacy per-service/per-account Keychain items once and write them into the vault.
- [ ] Replace per-account Keychain reads with vault lookups.
- [ ] Replace per-account Keychain writes with vault updates.
- [ ] Add tests for mode persistence, database store loading, and preserving secrets when saving accounts.

### Task 4: Settings UI

**Files:**
- Modify: `Sources/CodexNotch/SettingsView.swift`

- [ ] Add `secretStorageMode` to `SettingsDraft`.
- [ ] Add a picker in `启动与外观` labelled `密钥存储`.
- [ ] Use text `钥匙串` for Keychain mode and `本机数据库` for database mode.
- [ ] Add help copy explaining database mode avoids Keychain authorization prompts but is less protected than Keychain.
- [ ] Ensure switching modes only takes effect after clicking `保存`.

### Task 5: Verify, Install, Commit

**Files:**
- Modify as above.

- [ ] Run `./scripts/run-regression-tests.sh`.
- [ ] Run `./scripts/build-app.sh`.
- [ ] Run `codesign --verify --deep --strict --verbose=2 dist/codex监测.app`.
- [ ] Run `hdiutil verify dist/codex监测.dmg`.
- [ ] Run `./scripts/install-user-app.sh`.
- [ ] Confirm the running app path is `~/Applications/codex监测.app`.
- [ ] Commit all changes.
