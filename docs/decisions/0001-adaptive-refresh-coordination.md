# ADR-0001: Coordinate refreshes and adopt evidence-backed adaptive cadence

## Status

Accepted

## Date

2026-07-14

## Context

Local usage, CLIProxyAPI, NewAPI, and Sub2API previously implemented their own
timer, pending-request, cancellation, and generation state. Opening a detail
page could also force work even when its last successful result was still
fresh. The duplicated state made stale publication and unnecessary background
work harder to reason about.

The monitor must remain responsive while preserving its low-energy boundary:
file events and explicit actions should stay immediate, but hidden and idle
sources do not need the same polling cadence as visible running data. Existing
Token, Quota, Context, Delta, CLI, and SQLite contracts must not change.

## Decision

- Use one internal generation-based refresh coordinator for local usage,
  CLIProxyAPI, NewAPI, and Sub2API lanes.
- Coalesce ordinary requests, enqueue file-event follow-ups, and replace work
  only for explicit manual or settings changes. A result may publish only while
  its generation is current.
- Classify presentation data as fresh, stale, expired, or unavailable. Opening
  a detail tab does not refresh fresh data.
- Offer adaptive refresh as an independent setting. It uses visibility, Codex
  activity, Low Power Mode, and serious/critical thermal pressure. File events,
  manual refresh, and app-server reset scheduling remain independent. It was
  initially evaluated with the fixed cadence active, then enabled by default
  only for new installations after the runtime gates passed.
- Define visibility as the corresponding expanded detail tab being selected.
  The always-present collapsed capsule and menu-bar item display cached state
  and do not opt a source into the foreground cadence.
- Apply bounded exponential retry delays of 30 seconds, 1, 2, 5, 10, and 30
  minutes to failed remote reads.
- Keep anonymous process-local shadow counters for fixed-versus-adaptive
  schedule decisions. They contain counts and intervals only and are not
  persisted or sent elsewhere.
- Derive quota pace from the current window without history. Do not add a cost
  database, price lookup, hidden WebView, or notification prediction.

## Alternatives Considered

### Keep independent view-model timers

Rejected because cancellation and stale-publication rules would remain
duplicated, and detail-page freshness could not be enforced consistently.

### Enable adaptive refresh by default immediately

Rejected until paired runtime measurements demonstrate lower refresh activity
without violating visible-data freshness. The first release persists an
explicit opt-in default so a later release can change only the new-install
default.

### Adopt CodexBar's full provider registry and cost scanner

Rejected as disproportionate for the monitor's small provider set and
low-energy objective. The implementation borrows coordination concepts only
and does not copy CodexBar source.

## Consequences

- Fresh detail presentation creates no new network request or child process.
- Hidden remote sources can run at a slower cadence when adaptive mode is on.
  Visible sources retain their configured interval unless Low Power Mode or
  serious/critical thermal pressure activates the 30-minute safety cadence.
- A running local source in the collapsed capsule uses the 30-second hidden
  cadence; opening its detail tab uses the 15-second foreground cadence.
- File-event monitoring watches Codex-owned state, logs, session index, and
  recent rollout paths. It intentionally excludes the monitor-owned delta
  database so a refresh cannot trigger itself through its own SQLite write.
- Synchronous local store work may continue briefly after cancellation, but its
  obsolete generation cannot publish.
- Adaptive mode is now the default for new installations after replay,
  regression, and paired runtime energy gates passed. Existing explicit
  choices remain unchanged; an older installation without a recorded choice
  stays on the conservative fixed cadence.

## Validation status

- The deterministic 24-hour hidden/idle replay reduces scheduled local
  refreshes from a 180-second fixed cadence to 300 seconds, exactly 40%.
- An early 60-second comparison incorrectly classified the always-present
  collapsed HUD as presentation-visible and therefore selected the 15-second
  foreground cadence. Visibility now means the selected expanded detail tab;
  that invalid smoke result is retained here as the reason for the correction.
- Three paired 10-minute hidden/idle runs on 2026-07-14 used the production
  view model, coordinator, and usage store against isolated 5,000-row fixtures.
  Median average CPU fell from 0.556% to 0.391% (29.7%), median requests fell
  from 8 to 6 (25%), median P95 CPU fell from 0.0151% to 0.0133%, and median
  peak memory changed from 52,297,728 to 52,658,176 bytes (+0.7%). All runs
  stayed idle, ended without in-flight work, and performed zero JSONL scans.
- The benchmark also exposed and removed a self-trigger loop caused by watching
  the monitor-owned delta database. The final three-run result was collected
  only after that fix and its regression guard passed.
