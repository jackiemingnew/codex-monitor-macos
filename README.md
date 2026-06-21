# codex监测

codex监测 is a small native macOS overlay that sits around the MacBook notch like a compact dynamic island.

It shows:

- A left-side Codex activity indicator.
- 5h and 7d Codex rate-limit window percentages on the right.
- An expandable activity panel with current/recent Codex tasks.
- 24h, 7d, and 30d local token usage totals.

The app reads local Codex Desktop data from `~/.codex/state_5.sqlite`, `~/.codex/logs_2.sqlite`, and recent rollout JSONL files. It does not call any network API.

## Run

```bash
swift run CodexNotch
```

Click the island to expand or collapse it. Right-click it to refresh or quit.

## Build A Double-Clickable App

```bash
./scripts/build-app.sh
./scripts/install-user-app.sh
```

The bundled app is an accessory app (`LSUIElement=true`), so it does not show a Dock icon.
The install script copies the app to `~/Applications/codex监测.app`, so local updates do not require an administrator password.
