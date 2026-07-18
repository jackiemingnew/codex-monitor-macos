# ADR 0002: CodexBar-aligned API-equivalent cost snapshots

- Status: Accepted (supersedes the initial partial-publication design; budgeted generation completion is refined by [ADR 0003](0003-frozen-cost-scan-generations.md))
- Date: 2026-07-14

## Context

Codex Monitor already aggregates local token usage and persists rolling token baselines in `usage-deltas.sqlite`. Users also need a compact monetary reference, but Codex session history can span gigabytes.

CodexBar demonstrates the desired accounting semantics: cumulative-token reconciliation, model-switch and fork handling, per-file incremental caching, cached-input pricing, a serial utility executor, and publication of a report only after the selected corpus has been scanned. Publishing Monitor's budgeted subtotal after every slice made a 1%-covered scan look like a complete 7-day or 30-day estimate, so values such as `$61.72*` could not correspond to CodexBar's complete-corpus total.

## Decision

Codex Monitor independently implements CodexBar's accounting and publication semantics while retaining low-energy execution controls:

- Reconcile `last_token_usage` with cumulative `total_token_usage`; cached input remains a subset of input and is never double billed.
- Track model changes, cumulative counter rollback, fork inheritance, and interleaved lineages with numeric-only checkpoint state. Like CodexBar, the first `session_meta` identity is authoritative even when exported fork files embed later ancestor metadata.
- Deduplicate repeated usage rows across exported/fork files with CodexBar-equivalent row identity fields (`session`, `turn`, event index, day, model, and token delta). Persist only a SHA-256 digest plus the derived numeric contribution; raw turn identifiers are not retained.
- Run one cancellable cost job at a time on a dedicated serial utility queue. A job enumerates the complete 31-day session inventory but processes exactly one budgeted slice; it is not blocked merely because Codex is running.
- Bound that checkpoint slice to 8 MiB logical input, 50 ms process CPU, or 250 ms wall time, then stop. A later coordinated refresh resumes from the checkpoint. New automatic generations remain at least five minutes apart; [ADR 0003](0003-frozen-cost-scan-generations.md) permits one five-second yielded continuation at a time only while a finite generation remains budget-limited. Checkpoints advance only through complete JSONL rows. For rows above 256 KiB, retain only the bounded prefix long enough to recover a `turn_context` model; oversized token or session-metadata rows keep the report unpublished rather than silently undercounting.
- Keep working checkpoints/buckets separate from the published bucket snapshot. Only a complete scan replaces the published snapshot, in one SQLite transaction. A first incomplete scan displays `回填中`; a later incomplete incremental scan leaves the previous complete amount visible.
- Store both working and published derived data in the existing `usage-deltas.sqlite`. No path, prompt, response, reasoning, tool payload, account identifier, or credential is persisted.
- New automatic generations remain at least five minutes apart. Active-generation continuations pause in Low Power Mode or serious/critical thermal pressure and keep using the same coordinator. Detail presentation never starts a scan. File events and manual refreshes use that coordinator; manual replacement cancels the older work.
- A caught-up, unchanged refresh performs zero JSONL reads and zero derived-data writes.
- The UI shows deterministic local-calendar totals for Today, 7 days, and 30 days. `*` is reserved for a complete corpus containing unknown-model tokens; unknown models are never assigned a guessed price.
- After publication, the three footer Token values use the same input-plus-output buckets as the adjacent costs. This aligns visible Token lineage with CodexBar without changing existing CLI, Node, JSON, Delta, or stored Token contracts.
- Pricing follows CodexBar's effective standard-tier semantics for the models present in the local corpus. GPT-5.3-Codex-Spark uses the GPT-5.3-Codex tuple as a disclosed proxy, matching the referenced CodexBar runtime catalog/cache behavior.
- The metric is labelled “API 标准单价等值估算，不是 ChatGPT/Codex 订阅账单”. Priority processing, regional uplift, tool-call charges, and subscription credits are excluded.

Reset-credit availability is decoded from the existing `account/rateLimits/read` response and travels with the existing app-server cache. It does not create another request or timer, and it disappears when the 15-minute stale grace expires.

## CodexBar parity boundary

| Area | Aligned behavior | Intentional Monitor boundary |
| --- | --- | --- |
| Corpus | Current and archived Codex JSONL for the complete local 30-day window; removed files subtract cached contributions | File discovery reuses Monitor's local session locator instead of CodexBar's provider registry |
| Parsing | Context-model precedence, truncated-context model recovery, cached-input subset semantics, cumulative rollback containment, first-metadata fork identity, interleaved lineage handling, and cross-file usage-row de-duplication | No project path, prompt, response, tool payload, raw turn identifier, or trace body is retained |
| Publication | A window becomes visible only after the whole selected corpus is caught up | Working and published tables live in the existing SQLite store instead of a separate JSON cache |
| Execution | One cancellable serial utility job; unchanged files resume from full-line offsets | Monitor stops after one strict byte/CPU/wall slice per coordinated refresh; CodexBar's current scanner completes an uncapped pass |
| Pricing | Standard-tier cached/uncached input, output, and long-context formulas match | Offline fixed prices only; no models.dev refresh, Priority trace pricing, regional uplift, or tool pricing |
| UI/API | Footer Token is input plus output from the same daily buckets as cost | No chart, project/model ranking, subscription-cost claim, or CLI/Node/JSON contract change |

Parity was checked against CodexBar `b41715f3` on the same 282-file local corpus. For every closed natural day from 2026-06-15 through 2026-07-13, daily Token and daily standard-tier cost matched exactly. The live current day is excluded from equality claims because files continued changing between scans.

## Alternatives considered

### Publish every budgeted slice

Rejected because a partial subtotal is not a window estimate. A marker cannot repair the numerical mismatch or make it comparable with CodexBar.

### One uninterruptible full-history pass

Rejected because first-run work scales with multi-gigabyte history and would remove cancellation, yielding, row limits, and checkpoint recovery. Monitor instead completes the same corpus through one bounded slice per coordinated refresh on a serial utility queue.

### Price service or remotely refreshed catalog

Rejected because it adds network work, failure modes, and mutable pricing semantics to a secondary local estimate.

### Separate history database and periodic scanner

Rejected because the app already owns an appropriate derived SQLite store and coordinated usage-refresh path. ADR 0003's one-shot continuation timer is merely a yielded continuation of one active finite generation, not an independent periodic scanner.

### Cost charts, project rankings, and model breakdowns

Rejected for this change. They add UI density and more persisted dimensions without improving the two requested indicators.

## Consequences

- First-run values remain hidden as `回填中` until the selected corpus is complete; there is no misleading early subtotal.
- Complete estimates can still differ from real bills because service tier, regional processing, tools, and subscription accounting are intentionally excluded.
- Static prices require an explicit code update when supported model pricing changes.
- Cross-file row identity adds a compact derived occurrence table to the existing database. It stores a 32-byte digest and numeric deltas only, and a warm unchanged refresh neither reads JSONL nor writes this table.
- The fixed HUD size and existing public Token, Quota, Context, Delta, CLI, Node, and JSON contracts remain unchanged.
