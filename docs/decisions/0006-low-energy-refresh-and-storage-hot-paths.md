# ADR 0006: Separate hot refreshes and shed idle heavyweight resources

- Status: Accepted
- Date: 2026-07-19
- Refines: [ADR 0001](0001-adaptive-refresh-coordination.md),
  [ADR 0003](0003-frozen-cost-scan-generations.md), and
  [ADR 0004](0004-personal-pro-web-analytics-source.md)

## Context

A read-only profile of the installed monitor showed a low idle floor but a
large refresh burst. The dominant stack was not the new Local Token chart: a
fast local snapshot entered the month-wide thread query, parsed the same JSONL
prefix separately for session metadata, runtime model, and title, and updated
the Delta cache. The app also constructed a `WKWebView` at launch and an opted-in
performance monitor spawned `ps` every five seconds while its page was hidden.

CodexBar's documented refresh loop and Codex provider design reinforce the
same boundary: quota presentation, local cost scanning, and optional WebKit
enrichment have different costs and should not share one hot cadence. Codex
Monitor keeps its own accounting and UI; it does not copy CodexBar source or
adopt its provider registry.

## Decision

1. Split local refreshes into a fast snapshot lane and a history lane. The fast
   lane reads recent/running tasks, quota, activity, and task Delta only. It
   reuses the last published period/daily values and never loads the month
   corpus or records a Delta snapshot. The history lane loads the month thread
   set once, records one Delta snapshot, and derives both rolling period and
   natural-day usage from that same set.
2. Parse the bounded session prefix in one pass. Cache file identity, scanned
   offset, facts, and an incomplete tail. Strict appends read only new bytes;
   truncation, inode replacement, or same-size rewrite resets the cache. A
   missing field is a valid negative result up to the 1 MiB bound. A
   syntactically valid unterminated line at current EOF is a complete JSONL
   record; an incomplete live-write tail is retained until an append finishes
   it.
3. Keep the Analytics provider lightweight until explicit official use.
   Provider construction, Codex detail presentation, Local Token mode, and
   settings refresh do not construct WebKit. Official Analytics or the visible
   sign-in window materializes one `WKWebView` backed by the existing persistent
   `WKWebsiteDataStore`. Leaving official surfaces schedules a 30-minute idle
   release. Release cancels readiness work and drops the view without clearing
   website data; a mounted browser view is never released.
4. Sample performance at five seconds only while the Performance page is
   visible. Hidden sampling requires the existing opt-in and uses 60 seconds.
   Low Power Mode or serious/critical thermal pressure uses 300 seconds for any
   allowed sampling. Timers receive bounded tolerance, manual sampling remains
   immediate, and only one capture may run at a time.
5. Check the cost-scan cadence before recursively enumerating rollout files.
   Active frozen generations reuse in-memory candidates; a process without an
   inventory enumerates safely. Cache the state thread schema using the main,
   WAL, and SHM file signatures, and cache `session_index.jsonl` names using its
   file signature, including a missing-file negative cache.
6. Update `token_snapshots` only when `tokens_used` changes. Token rollback
   still deletes invalid high-water snapshots/history before inserting the
   lower value, and retention metadata remains on its 24-hour maintenance
   cadence. New or zero-byte Delta databases enable incremental auto-vacuum
   before tables are created. Existing databases are never switched or given an
   automatic full `VACUUM`; reclaiming an existing large free-page pool remains
   an explicit maintenance operation.

## Privacy and compatibility

- No new network request, timer, public API, CLI/JSON field, database table, raw
  transcript persistence, cookie access, or credential path is introduced.
- Website data remains in the same app-owned store. Releasing WebKit is not the
  destructive “Clear Sign-in” action.
- Local Token Analytics continues to read only complete published cost buckets.
  Its presentation opens an existing cache read-only, never creates or migrates
  a schema, and never activates the official provider or scanner.

## Alternatives considered

### Keep one snapshot path and rely only on a slower timer

Rejected because file events and visible running state still need a responsive
fast lane; lowering the timer would hide the repeated month query rather than
remove it.

### Keep a retained WebView after first use

Rejected because persisted website data, not a permanently retained renderer,
is the login contract. A new view can reuse the same app-owned session.

### Run full VACUUM automatically

Rejected because an existing large database can require comparable temporary
disk space and a long exclusive rewrite. The monitor must not impose that risk
from an ordinary refresh.

### Replace `ps` with a new low-level sampler in this change

Deferred. The cadence reduction removes most hidden process launches with a
small, testable change. A future `libproc` sampler needs its own compatibility
and attribution evidence and must preserve the current `UNVERIFIED` WebKit
ownership boundary.

## Consequences

- A normal fast refresh no longer pays the 30-day history or Delta-write cost.
- Hidden opted-in performance sampling schedules one twelfth as many captures
  as the prior five-second loop before power/thermal throttling.
- App launch and local-only use do not create WebKit renderer/GPU processes.
- The history and cost views may be stale up to their documented cadence, while
  recent task and quota state remain responsive.
- Existing databases retain their current file size until a separately approved
  maintenance workflow is executed; this ADR makes no live compaction claim.

## Validation

- Regression guards cover the fast/history boundary, strict prefix append and
  replacement behavior, valid no-newline EOF, partial-write completion,
  read-only published loads, cost cadence before inventory,
  active-generation reuse, unchanged Delta observation time, rollback/prune,
  new-versus-existing auto-vacuum, WebKit materialize/release/recreate, and the
  5/60/300-second performance cadence matrix.
- The full regression suite and Release build are required before distribution.
  Installed-app CPU/memory A/B and existing-database compaction remain separate
  runtime evidence gates.
