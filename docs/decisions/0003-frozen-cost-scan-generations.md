# ADR 0003: Freeze cost-scan generations before budgeted continuation

- Status: Accepted (extends ADR 0002)
- Date: 2026-07-17

## Context

ADR 0002 keeps API-equivalent cost scans within one 8 MiB, 50 ms CPU, or
250 ms wall-time slice and publishes only complete history. The original
completion check compared every checkpoint with each file's latest size and
mtime at the end of every slice.

That condition is not finite when several active Codex JSONL files keep
growing. A previously completed file can change before the last file advances,
and sorting every slice by newest mtime can repeatedly spend the entire budget
on the same hot file. Working buckets continue to advance while the last
published Today value remains unchanged.

CodexBar avoids this exact starvation because one scanner invocation traverses
the discovered inventory and publishes when that pass ends. New suffixes are
left for its next refresh. Codex Monitor must preserve that finite-pass
correctness boundary without adopting an uncapped full-corpus scan.

## Decision

- When work is pending and no generation is active, capture a finite target for
  every selected Session: Session ID, inode, observed size, observed mtime, and
  a deterministic ordinal. Store these derived fields in
  `cost_usage_scan_targets`; never store rollout paths there.
- Every bounded slice reads each file only up to its captured target size.
  Bytes appended after capture, and newly discovered Sessions, belong to the
  next generation.
- If a captured target ends in the middle of a normal JSONL row, close that
  generation at the last complete-row offset and retry the whole row in the
  next generation. Oversized-row discard state remains resumable across the
  boundary.
- Persist a round-robin cursor in the same transaction as checkpoint progress.
  The next slice starts after the last advanced file so one continuously growing
  file cannot starve the other targets.
- Treat truncation, replacement, or inode change as generation invalidation.
  Rebase onto a new finite inventory and reset the affected Session through the
  existing checkpoint safety path.
- A generation captured from a truncated inventory cannot publish. It may resume
  only as partial work until a complete inventory can start a replacement
  generation.
- After every target reaches a complete-line checkpoint, atomically replace the
  published buckets and clear the generation targets. A growing live file does
  not invalidate the completed generation; its suffix is processed next time.
- A budget-, CPU-, wall-time-, or fork-limited generation schedules one yielded
  continuation after five seconds. That continuation reuses the in-memory file
  inventory, resumes the persisted cursor, and schedules another only when the
  returned metrics still identify resumable bounded work.
- Preserve ADR 0002's execution limits, five-minute cadence for starting a new
  automatic generation, Low Power Mode and thermal gates, cancellation
  behavior, privacy boundary, and zero-read / zero-write warm path. Caught-up,
  cancelled, unavailable, and otherwise non-progressing results never form a
  continuation loop.

## Alternatives considered

### Keep comparing against live EOF

Rejected because the completion target moves between slices. Multiple active
files can prevent publication indefinitely even while useful checkpoint work is
being committed.

### Copy CodexBar's uncapped pass

Rejected because a cold multi-gigabyte history scan can run for minutes and
would regress the monitor's measured background-energy boundary.

### Publish each partial working subtotal

Rejected for the same reason as ADR 0002: partial coverage is not a valid
Today/7-day/30-day estimate and is not comparable with CodexBar accounting.

### Always display the fast natural-day counter while cost scanning

Rejected as the primary fix because Token and API-equivalent cost would again
use different lineage accounting. Presentation fallback cannot repair scanner
starvation.

## Consequences

- Continuously appended files can no longer require a simultaneous quiet period
  before publication.
- Today can still lag by one completed generation. This is bounded staleness:
  suffixes written after capture intentionally appear in the next generation.
- A large generation may require several five-second yielded continuations, but
  each target is finite and every individual slice keeps the existing resource
  limits. Empty and caught-up operation remains on the normal low-frequency
  refresh path.
- `usage-deltas.sqlite` gains one derived target table and three integer metadata
  values. They contain no paths, prompts, responses, tool data, accounts, or
  credentials.
- Regression coverage uses two JSONL files, continuously appends to the newest
  one between 2 KiB slices, asserts that the second file advances on slice two,
  and requires the frozen generation to publish and clear its targets.
