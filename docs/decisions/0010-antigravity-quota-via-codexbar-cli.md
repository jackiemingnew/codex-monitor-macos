# 0010: Antigravity quota via the optional CodexBar CLI adapter

- Status: Superseded by ADR-0011
- Date: 2026-08-06

## Context

The local Codex app-server exposes Codex and Spark limits, but not the quota
owned by the installed Antigravity `agy` CLI. CodexBar already normalizes that
local CLI source into the two pools documented by its public provider notes:
`Gemini` and `Claude + GPT`. Reimplementing CodexBar's PTY lifecycle, loopback
HTTPS probing, and fallback protocol would add a large, unstable maintenance
surface. Using CodexBar's `auto` or OAuth paths would also cross the monitor's
account and credential boundary.

Reference: [CodexBar Antigravity provider notes](https://github.com/steipete/CodexBar/blob/main/docs/antigravity.md).

## Decision

Codex Monitor may display an independent Antigravity (AGY) quota strip when a
local `agy` executable is present. The adapter invokes the installed
CodexBarCLI helper only with:

```text
usage --provider antigravity --source cli --format json --json-only
```

The adapter accepts `source=cli` only and maps the two returned pools to the
fixed labels `Gemini` and `Claude + GPT`. It persists only the source,
receipt/source-update timestamps, and those two pools' remaining percentages
and reset timestamps. Account email, identity, login method, tertiary pools,
raw command output, and error text are never persisted or exposed in the
Codex snapshot/CLI JSON contracts.

## Freshness and availability

The cache is fresh for 15 minutes and may be shown as stale for a further
30-minute grace period after a failed refresh. Once that grace period expires,
the strip reports unavailable rather than displaying zero. There is no fixed
periodic timer: startup, Codex detail presentation, and an explicit local
refresh are the only refresh triggers, and a single in-flight request is
allowed. A missing `agy` executable with no cache hides the strip; an existing
AGY executable with a missing helper or failed read shows a short unavailable
state.

## Rejected alternatives

- No OAuth, account lookup, browser/IDE integration, or automatic source
  selection (`auto`/`app`) is used.
- AGY data does not enter `UsageSnapshot`, `CodexUsageStore`,
  `SnapshotOutputFormatter`, or any Node/CLI JSON schema.
- No settings switch, new detail page, background polling timer, or raw-output
  cache is added.

## Consequences

- AGY monitoring is optional and depends on both a local `agy` executable and
  the installed CodexBarCLI helper. Missing components degrade to hidden or
  unavailable UI without affecting Codex monitoring.
- A helper invocation may take several seconds, but it runs on a utility task,
  is bounded to 12 seconds, is coalesced, and never blocks the Codex refresh
  lane.
- Reset timestamps are source-provided. The monitor does not invent a fixed
  five-hour or weekly period when the normalized helper output does not expose
  that distinction.
- The small 0600 cache contains quota percentages and reset timestamps, but no
  account identifiers, credentials, raw payload, or raw error text.
