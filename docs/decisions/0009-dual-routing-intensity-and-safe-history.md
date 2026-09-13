# ADR 0009: Preserve generalized and Ultra routing intensity separately

- Status: Accepted
- Date: 2026-08-05
- Supersedes: ADR 0008 statements that limited future presentation to the generalized metric

## Context

Routing can originate from Medium, High, Max, Ultra, and other root efforts. The
generalized metric therefore remains the primary answer to “how much of routed
work is delegated.” Ultra still needs a separate answer because its operating
contract and denominator are narrower, and three complete Ultra daily aggregate
points were already published before the generalized metric existed.

The source database stores current cumulative thread Token values and parent
edges. It does not retain a trustworthy historical topology, historical root
Effort, or per-day cumulative baseline for every routed participant. Replaying
today's topology against old counters would create plausible-looking but false
history. A secondary snapshot database is parent-only and cannot reconstruct
strict child attribution. Neither source is a safe generalized backfill.

## Decision

The UI, accessibility text, Tooltip, and report present two distinct metrics:

- **All routing**: strict attributed child daily Token divided by the daily
  Token increase of roots that actually dispatched and their attributed
  descendants, regardless of root model or Effort.
- **Ultra**: strict attributed child daily Token divided by the daily Token
  increase of exact `gpt-5.6-sol` Ultra roots and their attributed descendants.
  Max and all other Efforts stay outside this denominator.

Existing published Ultra aggregate points remain valid and are reused as-is.
Missing dates and generalized history are displayed as gaps and are never
derived from cumulative values. This is a safe reuse of already-published
aggregates, not a raw-history rescan or reconstruction.

Future scans maintain both metrics in the existing `routing_baselines` rows.
`strict_class` stores generalized `root`/`child`/`other`; nullable
`ultra_class` independently stores the Ultra classification. The table is
migrated in place. Both daily aggregates are merged independently so failure or
class drift in one evidence stream does not erase valid same-day increments in
the other.

Both metrics retain the same fail-closed checks for missing class evidence,
rollback, and stale participants. Topology ambiguity still removes both strict
partitions. The 20–35% band remains a local operating guide, not an official
health standard.

## Consequences

- Existing complete Ultra history is visible immediately, while generalized
  guidance naturally accumulates after its baseline is established.
- One existing SQLite read and one lightweight derived write path collect both
  metrics. No second scan, timer, JSONL read, network request, raw thread ID in a
  daily payload, or new history table is introduced.
- The interface must identify the two series with independent semantic colors
  and report both evidence states. A missing value is `--`, never zero.
- Exact historical generalized backfill remains `UNVERIFIED` and intentionally
  unsupported unless a future source provides complete historical counters,
  topology, root identity, and Effort.
