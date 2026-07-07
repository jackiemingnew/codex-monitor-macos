# Codex Token Metric Definitions

This file is the source of truth for local Codex token metrics. Any change that
adds, removes, renames, or changes the formula for a usage metric in
`CodexUsageStore`, `SnapshotOutputFormatter`, the Codex UI, or local
`codex-usage*` surfaces must update this document in the same change.

## Metric Registry

| Metric ID | Display Meaning | Source | Formula | Default Scope |
| --- | --- | --- | --- | --- |
| `cumulative.active_tokens` | Default Total / 累计 Token 数 | `state_*.sqlite` | `sum(threads.tokens_used) where archived = 0` | active sessions only |
| `cumulative.archived_tokens` | Archived sessions cumulative tokens | `state_*.sqlite` | `sum(threads.tokens_used) where archived = 1` | archived sessions only |
| `cumulative.all_tokens` | Explicit all-session cumulative tokens | `state_*.sqlite` | `cumulative.active_tokens + cumulative.archived_tokens` | active + archived |
| `recent.usage_20d_active_tokens` | Rolling 20 day active-session state total | `state_*.sqlite` | `sum(threads.tokens_used) where archived = 0 and recency >= now - 20d` | active sessions |
| `recent.usage_20d_archived_tokens` | Rolling 20 day archived-session state total | `state_*.sqlite` | `sum(threads.tokens_used) where archived = 1 and recency >= now - 20d` | archived sessions |
| `recent.usage_20d_all_tokens` | Rolling 20 day all-session state total | `state_*.sqlite` | `recent.usage_20d_active_tokens + recent.usage_20d_archived_tokens` | active + archived |
| `daily.usage_today_tokens` | Local natural-day token consumption | Swift delta cache + `state_*.sqlite` current totals | `sum(current parent tokens_used - baseline parent tokens_used at or before local 00:00)` | parent active + archived |
| `period.usage_24h` | Rolling 24 hour token consumption | Swift delta cache + `state_*.sqlite` current totals | `sum(current parent tokens_used - baseline parent tokens_used at or before now - 24h)` | parent active + archived |
| `period.usage_7d` | Rolling 7 day token consumption | Swift delta cache + `state_*.sqlite` current totals | `sum(current parent tokens_used - baseline parent tokens_used at or before now - 7d)` | parent active + archived |
| `period.usage_30d` | Rolling 30 day token consumption | Swift delta cache + `state_*.sqlite` current totals | `sum(current parent tokens_used - baseline parent tokens_used at or before now - 30d)` | parent active + archived |
| `delta.1h` | Primary visible per-task token increase since the latest baseline older than 1 hour | Swift delta cache | `current parent tokens_used - baseline parent tokens_used` | tracked parent task rows |
| `delta.10m` | Legacy/internal token increase since the latest baseline older than 10 minutes | Swift delta cache | `current parent tokens_used - baseline parent tokens_used` | compatibility export fields only |
| `delta.24h` | Per-task token increase since the latest baseline older than 24 hours | Swift delta cache | `current parent tokens_used - baseline parent tokens_used` | tracked parent task rows |
| `task.total_tokens` | Single task row token total | state DB + parent session JSONL enrichment | `CodexTask.tokenCount` for that parent row | visible parent task only |
| `quota.5h` | Main Codex 5 hour remaining quota | app-server or local JSONL rate limits | main `limit_id = codex`, remaining percent | main Codex only |
| `quota.7d` | Main Codex 7 day remaining quota | app-server or local JSONL rate limits | main `limit_id = codex`, remaining percent | main Codex only |
| `quota.spark.5h` | GPT-5.3-Codex-Spark 5 hour remaining quota | app-server Spark limit, local JSONL fallback | Spark `limit_id = codex_bengalfox` or `limit_name` containing Spark, remaining percent | Spark only |
| `quota.spark.7d` | GPT-5.3-Codex-Spark 7 day remaining quota | app-server Spark limit, local JSONL fallback | Spark `limit_id = codex_bengalfox` or `limit_name` containing Spark, remaining percent | Spark only |

## Rules

- The default app/dashboard **Total Tokens** value is `cumulative.active_tokens`.
- `period.usage_24h`, `period.usage_7d`, and `period.usage_30d` are rolling
  consumption deltas. The current value comes from readonly `state_*.sqlite`
  parent thread totals, while the window baseline comes from the Swift-owned
  delta cache. They include both active and archived parent sessions by default
  and must not be displayed or exported as all-time cumulative totals.
- `daily.usage_today_tokens` is the local natural-day consumption value. Its
  cutoff is local 00:00, not `now - 24h`; folded/collapsed UI labels named
  `Today` must use this metric.
- If a parent thread predates a window but has no Swift cache baseline at or
  before the cutoff, `period.*` and `daily.*` must mark the result partial and
  omit that thread from the delta instead of treating the full cumulative total
  as window consumption.
- Threads created inside the requested window and lacking a baseline start from
  zero. This fallback requires a real `created_at` value or a session that is not
  yet present in `state_*.sqlite`; file modification time alone is not a thread
  creation time.
- `recent.usage_20d_*` metrics are state DB rolling-window totals based on
  `coalesce(recency_at, updated_at, created_at)`. They intentionally include
  archived sessions in the `all` variant and must not be replaced by
  `period.usage_30d`.
- `task.total_tokens` is a row-level value. Summing the visible task rows is not
  the global total because the visible list is limited. It must remain
  parent-only; subagent token totals must not be folded into a parent task row.
- `delta.*` values depend on the Swift-owned cache under Application Support.
  They are useful for recent movement, not for all-time totals.
- `delta.*` cache rows must be recorded from stable parent task token totals.
  Active subagent counts may decorate the parent row, but subagent token totals
  must use a future independent metric if they become visible.
- `period.*`, `daily.*`, `delta.*`, and `task.total_tokens` are parent-only.
  Subagent tokens must not be folded into a parent task or period delta.
- `delta.1h` is the default user-visible task table movement metric.
  `delta.10m` remains available only for compatibility exports and internal
  calculations; it must not be used as the details table movement column.
- `quota.5h` and `quota.7d` describe rate-limit windows, not token usage.
- Spark or subagent quota windows must stay separate from `quota.5h` and
  `quota.7d`.
- `quota.spark.5h` and `quota.spark.7d` prefer app-server
  `rateLimitsByLimitId.codex_bengalfox` / `GPT-5.3-Codex-Spark`. Local JSONL
  Spark windows are fallback only.
- Expired or stale local Spark quota windows must be hidden or exported as
  unavailable. They must never be converted into a precise `100%` remaining
  value.

## Output Contract

- Compact Swift JSON exposes cumulative totals as `cumulative_usage`.
- Compact Swift JSON exposes recent rolling 20 day state totals as
  `recent_usage`.
- Compact Swift JSON exposes local natural-day consumption as `daily_usage`.
- Node-compatible JSON exposes cumulative totals as `cumulativeUsage`.
- Node-compatible JSON exposes recent rolling 20 day state totals as
  `recentUsage`.
- Node-compatible JSON exposes local natural-day consumption as `dailyUsage`.
- Compact Swift JSON exposes Spark quota windows as `spark_quota_windows`.
- Node-compatible JSON exposes Spark quota windows as `sparkQuotaWindows`.
- Human snapshot output prints `cumulative active=... archived=... all=...`.
- Human snapshot output prints `recent20d active=... archived=... all=...`.
- Dashboard and CLI cards that say `Total Tokens` must use
  `cumulative.active_tokens` when the Swift snapshot provides it.
