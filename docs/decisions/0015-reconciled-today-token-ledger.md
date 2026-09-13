# ADR 0015: Reconcile Today Token by root Codex task

- Status: Accepted
- Date: 2026-08-12
- Supersedes: the no-task-attribution boundary in [ADR 0005](0005-local-model-token-analytics.md)

## Context

The task table previously sourced each visible row's Today value from the fast
`state_5.sqlite` task snapshot. That snapshot represents the root task only and
does not include Token consumed by directly or transitively spawned subagents.
The footer's Today value uses the deduplicated published cost ledger and already
includes both root and child sessions. The row numerators and footer denominator
therefore described different corpora and could not be reconciled.

The existing cost scanner already performs bounded JSONL discovery, cumulative
Token delta extraction, fork-history subtraction, row-level deduplication, and
atomic publication. A second UI scanner or a query over live JSONL would repeat
that work, increase foreground I/O, and allow the table to mix generations.

## Decision

Extend the existing frozen publication with an internal per-session ledger and
root-task lineage:

1. Record only the normalized session ID and optional parent session ID while an
   already-selected rollout is scanned. Parent evidence comes from the existing
   fork metadata or Codex `parent_thread_id` / `source.subagent.thread_spawn`
   metadata. No prompt, response, title, path, or arbitrary role name is added.
2. During the same atomic publication transaction, apply the existing `row_key`
   deduplication rule, then publish each unique row under its leaf session and
   resolved root session. Follow at most 16 parent edges and stop on a cycle.
3. Define a root task's Today Token as the sum of `input_tokens + output_tokens`
   for that root and all descendants on the current local natural day. Cached
   input remains a subset of input and is not added again.
4. Use the same published Today total as the percentage denominator. Expose the
   task ledger only when the sum of all root buckets equals that denominator
   exactly. Any mismatch fails closed to the previous task-snapshot display;
   generations are never mixed.
5. A root task absent from a complete, reconciled Today ledger displays zero.
   An unmatched local session remains its own root bucket so its Token is not
   silently dropped. Rows not currently visible in the task list still remain in
   the denominator.
6. Opening the HUD only reads the published SQLite snapshot. No timer, network
   request, WebKit work, second JSONL pass, CLI/JSON output, or public export is
   added. Schema version 6 causes the existing bounded scanner to rebuild the
   derived ledger before it is marked complete.

The UI keeps one compact Today value. Help and accessibility text disclose that
the value includes attributed subagents and that its share is of all local Token
for the day. Own and subagent Token remain separate in the internal bucket so a
later drilldown can be added without another accounting migration.

## Relationship to earlier decisions

ADR 0005 remains authoritative for model analytics, Token composition, pricing
completeness, refresh routing, and the official/local Analytics separation. This
decision supersedes only its statement that the deduplicated publication cannot
support task or parent/subagent attribution. ADRs 0002 and 0003 continue to own
row deduplication, fork correction, bounded scanning, publication atomicity, and
yielded continuation scheduling.

## Alternatives considered

### Add child Token to the state snapshot

Rejected. The state snapshot and the cost ledger have different extraction and
deduplication contracts. Combining them would still leave the displayed rows and
footer on different accounting paths.

### Read and join rollout JSONL whenever the HUD opens

Rejected. It would put history I/O on the render path, duplicate the existing
scanner, and regress warm-refresh energy behavior.

### Persist complete rollout or task metadata

Rejected. Stable session lineage is sufficient for reconciliation. Persisting
titles, prompts, diffs, paths, or raw agent metadata would enlarge the privacy
and migration surface without improving the accounting invariant.

## Consequences

- A parent task's Today value now includes attributed subagent Token and uses the
  exact same local-day denominator as the footer.
- The full root ledger always sums to the published Today total when shown;
  visible task rows need not sum to 100% because archived or hidden roots remain
  part of that total.
- First run after schema migration may temporarily show the previous snapshot
  values while the bounded backfill completes. Warm refresh continues to perform
  zero JSONL reads and zero derived writes.
- Parent evidence that is absent or malformed cannot be guessed. Such a session
  remains independently accounted for rather than being assigned to a nearby
  task.
