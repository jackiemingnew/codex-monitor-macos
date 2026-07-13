# Codex Monitor Metric Definitions

This file is the source of truth for local Codex usage and Skill Insights
metrics. Any change that adds, removes, renames, or changes a formula in
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
| `delta.1h` | Retained one-hour token increase since the latest baseline older than 1 hour | Swift delta cache | `current parent tokens_used - baseline parent tokens_used` | compatibility exports and internal calculations |
| `delta.10m` | Legacy/internal token increase since the latest baseline older than 10 minutes | Swift delta cache | `current parent tokens_used - baseline parent tokens_used` | compatibility export fields only |
| `delta.24h` | Per-task token increase since the latest baseline older than 24 hours | Swift delta cache | `current parent tokens_used - baseline parent tokens_used` | tracked parent task rows |
| `context.usage_percent` | Optional context-window usage display | rollout JSONL `token_count` tail scan | `last_token_usage.input_tokens / model_context_window` | visible task rows when enabled |
| `task.total_tokens` | Single task row token total | state DB + parent session JSONL enrichment | `CodexTask.tokenCount` for that parent row | visible parent task only |
| `quota.5h` | Main Codex 5 hour remaining quota | app-server or local JSONL rate limits | main `limit_id = codex`, remaining percent | main Codex only |
| `quota.7d` | Main Codex 7 day remaining quota | app-server or local JSONL rate limits | main `limit_id = codex`, remaining percent | main Codex only |
| `quota.spark.5h` | GPT-5.3-Codex-Spark 5 hour remaining quota | app-server Spark limit, local JSONL fallback | Spark `limit_id = codex_bengalfox` or `limit_name` containing Spark, remaining percent | Spark only |
| `quota.spark.7d` | GPT-5.3-Codex-Spark 7 day remaining quota | app-server Spark limit, local JSONL fallback | Spark `limit_id = codex_bengalfox` or `limit_name` containing Spark, remaining percent | Spark only |
| `skill.catalog.enabled_count` | Currently enabled Skill count | local Codex app-server `skills/list`; `PARTIAL` frontmatter fallback | `count(distinct stable_path_id) where enabled = true` | current catalog |
| `skill.catalog.disabled_count` | Currently disabled Skill count | local Codex app-server `skills/list`; `PARTIAL` frontmatter fallback | `count(distinct stable_path_id) where enabled = false` | current catalog |
| `skill.catalog.context_token_estimate` | Enabled catalog/context cost | enabled Skill `name` + `description` metadata from `skills/list` | `sum(ceil((name.characters + description.characters) / 4))` | current enabled catalog |
| `skill.evidence.direct_7d` | Explicit Skill-use evidence | recent rollout JSONL derived observations | count of `DIRECT + confirmed_use` observations | rolling 7 days |
| `skill.evidence.strong_7d` | Corroborated Skill-use evidence | recent rollout JSONL derived observations | count of turns with relevant task + matching Skill declaration + matching `SKILL.md` read | rolling 7 days |
| `skill.evidence.inferred_7d` | Unconfirmed possible Skill use | recent rollout JSONL derived observations | count of `INFERRED + inferred_use` observations | rolling 7 days |
| `skill.evidence.shadow_7d` | Disabled Skill demand signal | recent rollout JSONL + current catalog state | count of relevant tasks matching a disabled Skill | rolling 7 days |
| `skill.suspected_miss_7d` | Enabled Skill possibly not triggered | recent rollout JSONL derived observations | count of relevant enabled-Skill tasks without DIRECT, STRONG, or INFERRED use evidence | rolling 7 days |
| `skill.suspected_misfire_7d` | Skill possibly used on an unrelated task | recent rollout JSONL derived observations | count of declared/read Skill evidence not matched to the current task | rolling 7 days |
| `skill.related_session_tokens_7d` | Related Session Token reference | `state_*.sqlite` / rollout token reference + derived observations | for each Skill, sum the maximum total of each distinct related Session | rolling 7 days; reference only |
| `skill.per_skill_tokens` | Tokens attributable to one Skill | unavailable | `UNAVAILABLE` | never inferred in P0 |
| `skill.report.quality` | Skill report data completeness | catalog loader + catalog/analyzer fingerprint + file checkpoints + analyzer runs | `UNAVAILABLE` without a usable catalog/run; `PARTIAL` if the catalog changed or any catalog/file scan is incomplete; otherwise `COMPLETE` | latest run |
| `skill.scan.logical_bytes` | JSONL bytes delivered by the chunk reader | incremental rollout reads | sum of bytes read after the persisted offset; boundary probes reported separately | latest run |
| `skill.scan.pending_files` | Clean files with unread suffixes | candidates + complete-line checkpoints | distinct candidate paths stopped by byte, CPU, wall-time, or cancellation bounds | latest run |
| `skill.scan.partial_files` | Files with actual analysis loss or ambiguity | malformed/oversized rows and file errors | distinct affected paths; excludes budget-only pending work | latest run |
| `skill.scan.cpu_ms` | Process CPU used during analyzer execution | process CPU clock delta | end minus start; conservative when other app work overlaps | latest run |
| `skill.scan.disk_read_bytes` | Physical/process read-I/O reference | macOS process resource counters | process counter delta; may be lower than logical reads due to page cache | latest run |
| `skill.scan.database_ms` | Derived-store time | persistent Skill SQLite connection | elapsed time in per-file observation/checkpoint transactions | latest run |

## Rules

- The default app/dashboard **Total Tokens** value is `cumulative.active_tokens`.
- `period.usage_24h`, `period.usage_7d`, and `period.usage_30d` are rolling
  consumption deltas. The current value comes from readonly `state_*.sqlite`
  parent thread totals, while the window baseline comes from the Swift-owned
  delta cache. They include both active and archived parent sessions by default
  and must not be displayed or exported as all-time cumulative totals.
- `daily.usage_today_tokens` is the local natural-day consumption value. Its
  cutoff is local 00:00, not `now - 24h`; folded/collapsed UI labels named
  `Today` and local detail cards labeled `今日` must use this metric.
- `period.usage_24h` remains a rolling 24 hour export/internal metric. The local
  Codex detail page does not display it as the first bottom card; that card uses
  `daily.usage_today_tokens` so visible UI matches the natural-day Today metric.
- If a parent thread predates a window but has no Swift cache baseline at or
  before the cutoff, `period.*` and `daily.*` must mark the result partial and
  omit that thread from the delta instead of treating the full cumulative total
  as window consumption.
- Visible partial `daily.*` and `period.*` values must use a `≥` prefix because
  omitted sessions make the computed value a confirmed lower bound. JSON/CLI
  numeric fields remain unchanged and expose completeness through their quality
  metadata.
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
- `delta.1h` remains available for compatibility exports and internal
  calculations, but is not shown in the folded top pill by default.
  `delta.10m` remains available only for compatibility exports and internal
  calculations; it must not be used as the details table movement column.
- `context.usage_percent` is disabled by default. When enabled, the app may read
  the tail of visible session JSONL files to find `token_count`; when disabled,
  details-page Ctx UI stays hidden and task context fields remain unavailable.
- Context-window usage is not a compaction count. If compaction becomes a
  first-class metric, prefer strong-evidence log events such as `run_auto_compact` and
  report confirmed counts separately from token-sequence estimates.
- `quota.5h` and `quota.7d` describe rate-limit windows, not token usage.
- Quota windows preserve the exact upstream remaining percentage, including
  `0%`, `99%`, and `100%`. A reset timestamp is a refresh hint, not proof that
  quota has replenished; only a new source value may change the percentage.
- Concurrent JSONL sessions can report different quota cohorts. Recent local
  candidates are grouped by their 5h / 7d reset pair. A generation that has
  actually crossed reset outranks expired generations; otherwise the cohort
  with more recent-session support wins. Ties retain the earlier stable reset
  until it expires or the later cohort gains more support.
- A fresh app-server value is authoritative for main Codex 5h / 7d quota. Its
  last-known-good value remains authoritative for up to 15 minutes after a
  failure, including across a reset boundary; local JSONL is used only after
  that protection expires or when no official value exists.
- An app-server response that raises either remaining percentage by 10 points
  or more is staged for 30 seconds. It is published only after another response
  confirms the same 5h / 7d reset generation. This prevents a single transient
  `99% / 100%` response from replacing a confirmed exhausted window while still
  allowing a real reset after confirmation.
- A reached reset schedules an early app-server recheck. It never rewrites the
  displayed percentage or grants a local cohort immediate authority.
- The app-server executable is resolved from the current `com.openai.codex`
  application bundle with ChatGPT/Codex application-path fallbacks. Local JSONL
  remains the fallback source when app-server is unavailable.
- `gpt-5.6-sol` currently reports the main `limit_id = codex` and therefore uses
  `quota.5h` / `quota.7d`; it does not create a separate model quota strip.
- Spark or subagent quota windows must stay separate from `quota.5h` and
  `quota.7d`.
- `quota.spark.5h` and `quota.spark.7d` prefer app-server
  `rateLimitsByLimitId.codex_bengalfox` / `GPT-5.3-Codex-Spark`. Local JSONL
  Spark windows are fallback only.
- Spark is the only model-specific quota exposed in the current UI and JSON
  contract. New model-specific quota families must be added through the internal
  model-quota descriptor path instead of another hard-coded parser branch.
- Expired or stale local Spark quota windows must be hidden or exported as
  unavailable. They must never be converted into a precise `100%` remaining
  value.

### Skill Insights Rules

- The default observation window is the rolling interval
  `[now - 7 days, now]`, inclusive at both boundaries.
- Catalog entries are keyed by canonical Skill path, not name. Same-name Skills
  from a plugin and a local directory remain separate rows.
- The local Codex app-server `skills/list` result is authoritative for catalog
  membership and enabled state because it applies Codex configuration, plugin,
  scope, and path-precedence rules. The request uses local stdio and does not
  include Session content. If that source is unavailable, direct `SKILL.md`
  frontmatter discovery is retained only as a visibly `PARTIAL` fallback.
- Catalog metadata is limited to `name`, `description`, path, scope, and enabled
  state. The context estimate is a fixed approximation of enabled
  `name + description`, not measured model input and not actual billed Token
  usage.
- `DIRECT` means an explicit `$skill-name` reference or exact structured Skill
  call. `STRONG` requires all three deterministic signals in one task: a
  relevant user request, a matching Skill declaration, and a read of that
  Skill's `SKILL.md` path.
- `INFERRED` does not count as confirmed use. `SHADOW`, suspected miss,
  suspected misfire, and replacement observations are conservative heuristics
  and must remain visibly unverified.
- A plain mention of a Skill name is relevance evidence only. Reading a generic
  file, or even reading `SKILL.md` without task relevance and another activation
  signal, must not count as confirmed use.
- `skill.related_session_tokens_7d` deduplicates by Skill and Session, but the
  whole Session total is only contextual reference. It must never be labeled or
  exported as Token consumed by that Skill.
- `skill.per_skill_tokens` is always `UNAVAILABLE` in P0. No Session total may
  be divided, apportioned, or otherwise attributed to individual Skills.
- `skill.report.quality` describes data completeness only. Evidence certainty is
  reported separately per Skill. Heuristic evidence does not by itself make a
  fully scanned report `PARTIAL`.
- `COMPLETE` means the catalog loaded without diagnostics, all candidate files
  reached complete checkpoints, the current catalog/analyzer fingerprint
  matches the derived observations, and the latest analyzer run completed.
  `PARTIAL` means evidence may be missing because the authoritative catalog was
  unavailable, a filesystem fallback was used, configuration or path errors
  occurred, rows were malformed or relevant/unknown oversized, a run-bound
  continuation was required, file replacement was ambiguous, a catalog change is pending
  reanalysis, or another scan problem was reported. `UNAVAILABLE` means no
  usable catalog or completed analyzer run exists.
- One week with zero evidence means only `暂无证据`; it is not evidence that a
  Skill has no value. Safety, migration, recovery, and release Skills must not
  be downgraded solely because they are rarely used.
- Skill analysis runs outside the fast Token snapshot and file-watcher paths.
  While its independent setting is off, no Skill loader, scanner, database
  connection, or timer is created. While enabled, automatic analysis runs at
  most once per rolling seven days; manual analysis resumes persisted offsets.
  Enabled-state changes reclassify neutral relevance/replacement evidence and
  do not invalidate file checkpoints. It performs no model or embedding calls;
  catalog lookup is a local Codex app-server stdio request.
- JSONL rows are fully decoded only up to 256 KiB. Deterministically irrelevant
  oversized rows are counted as filtered; relevant or unknown oversized rows
  increment the oversized/partial metrics and therefore prevent `COMPLETE`.

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
- Skill Insights is not added to the existing snapshot or Node-compatible JSON
  contract. Its detail page exports a separate Markdown weekly report or a
  schema-versioned JSON `SkillInsightsSnapshot`.
