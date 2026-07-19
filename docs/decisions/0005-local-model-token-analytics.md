# ADR 0005: Local model Token Analytics from published cost buckets

- Status: Accepted
- Date: 2026-07-18
- Supersedes: the model-breakdown UI boundary in [ADR 0002](0002-budgeted-api-equivalent-cost-estimates.md)

## Context

ADR 0002 deliberately limited its first UI slice to three compact Token and
API-equivalent cost values. It rejected model charts and rankings at that time,
even though the completed scanner already publishes numeric daily buckets by
local day and normalized model in `cost_usage_published_buckets`.

Local task scheduling now uses materially different parent and child-agent
models. A total Token value cannot show whether Sol, Terra, Luna, Auto-review,
or another model produced the work. Re-scanning JSONL, adding another database,
or retaining task lineage solely for a chart would duplicate the accounting and
privacy work already established by ADRs 0002 and 0003.

## Decision

Add an internal local model Token report and a native Analytics view with these
boundaries:

1. Read only the complete frozen-generation rows already published in
   `cost_usage_published_buckets`. Do not add a table, migration, history
   backfill, network request, WebKit operation, or independent timer.
2. Return the published daily model buckets in the internal cost summary. For
   every bucket, total Token is `input_tokens + output_tokens`.
   `cached_input_tokens` remains a subset of input and is never added again.
   The detailed composition is uncached input (`input - cached`), cached input,
   and output.
3. Aggregate all current and archived local Codex JSONL selected by the existing
   scanner, including parent tasks and subagents. Do not reconstruct a parent / child
   split, project ranking, task drilldown, or raw session identity from the
   deduplicated published rows.
4. Keep official personal web Analytics as the default Analytics mode. Add an
   explicit `官方轮次 / 本地 Token` switch. Local mode defaults to seven local
   natural days and supports Today, 7 days, and 30 days.
5. Render Today as a single-day composition bar. Render 7 and 30 days as daily
   stacked trends, including explicit zero days. A trend has at most six visible
   series: retain Sol, Terra, Luna, and Auto-review when present, fill remaining
   explicit capacity by Token rank, and merge the rest into `其他`. The ranking
   retains every model.
6. Show Token and period share as the primary model values. Tooltip, Help, and
   accessibility text expose exact total, uncached input, cached input, output,
   and optional API-equivalent cost.
7. Token completeness and pricing completeness are independent. A complete
   published model snapshot is Token `COMPLETE` even when one or more models are
   unpriced. Unpriced models still contribute Token and share; their cost is
   `未定价`, never `$0`. Spark continues to disclose its GPT-5.3-Codex proxy price.
8. Opening or selecting local mode performs a read-only published-summary load.
   Manual local refresh reuses the existing cost-scan coordinator. If the
   existing `显示 今日 / 7天 / 30天` setting is off, show an enablement prompt and
   do not initiate a scan.
9. Keep the official Analytics provider, parser, normalized chart model, and
   refresh behavior unchanged. Local refresh routing cannot call the web
   provider; official refresh routing cannot be replaced by the local scanner.
10. Keep CLI, Node, JSON, snapshot export, and other public output contracts
    unchanged. The new model report remains an internal UI contract.

## Relationship to ADR 0002

This ADR supersedes only ADR 0002's intentional decision not to expose a model
breakdown or cost chart in the UI. ADR 0002 remains authoritative for parsing,
deduplication, fork handling, publication atomicity, bounded scanning, privacy,
pricing formulas, and warm-refresh behavior. ADR 0003 remains authoritative for
frozen scan generations and yielded continuation scheduling.

No project dimension is added. The previously published `session_id` is still
the deduplicated sentinel, so the local view cannot and must not claim task-level
or parent/subagent attribution.

## Alternatives considered

### Scan JSONL on demand from the Analytics page

Rejected. It would create a second accounting path, bypass the existing energy
budget and publication gate, and make a visual selection perform hidden I/O.

### Add a task/model history table

Rejected. The requested result is an aggregate model view. Persisting task
identity would add privacy and migration cost without supporting the approved
UI.

### Estimate model shares from official Turns

Rejected. Turns are not Token and the official personal page covers surfaces
that are not equivalent to this Mac's local JSONL corpus.

### Treat unknown-model cost as zero

Rejected. Zero is a priced monetary result. An absent price must remain
`未定价` while its Token stays included.

## Consequences

- Users can see whether local scheduled work is dominated by Sol, Terra, Luna,
  Auto-review, or other models without changing the scanner or public APIs.
- Local Token totals can differ from official Analytics because their corpus and
  unit differ: local JSONL Token versus cross-surface official Turns.
- A complete Token report can coexist with a partial pricing report. The UI must
  preserve both states instead of collapsing them into one badge.
- Model names and fixed offline prices still require ordinary code updates as
  the upstream runtime evolves.
