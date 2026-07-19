# Codex Monitor Diagnostics

Codex Monitor records quota-resolution decisions and a small set of operational
status events so behavior can be explained without reading task content or
inspecting raw rollout files.

## Log Location

Structured JSONL is written to:

```text
~/Library/Logs/CodexMonitor/quota-diagnostics.jsonl
```

The file is limited to 2 MB with one rotated backup at
`quota-diagnostics.jsonl.1`. Both files use current-user-only permissions
(`0600`), and the containing directory uses `0700`. The same safe events are
also sent to macOS Unified Logging under:

```text
subsystem: com.alight.codexnotch
category: quota
```

## Read Recent Decisions

```bash
~/Applications/codex监测.app/Contents/MacOS/CodexNotch \
  --print-diagnostics --limit 200
```

Each `quota_resolution` event includes:

- app-server, local JSONL, and published percentages;
- 5h / 7d reset timestamps;
- app-server cache freshness, age, consecutive failures, and next retry time;
- local candidate, reset-generation, and selected-cohort support counts;
- the selected source and a stable decision reason;
- a correlation ID for that resolution pass.

Common decision reasons:

- `app_server_fresh`: a current app-server value is authoritative.
- `app_server_stale`: the last successful app-server value is retained during
  the 15-minute failure grace period.
- `app_server_fresh_pending_reset_refresh` / `app_server_stale_pending_reset_refresh`:
  the recorded reset has passed, so another official read is scheduled while
  the last confirmed percentage remains visible.
- `local_jsonl_only`: no usable official value remains, so local JSONL is the
  fallback.

Each `app_server_refresh` event includes the refresh outcome, safe failure kind,
duration, consecutive failure count, last-success age, and next retry time.
Failures retry after 30, 60, 120, then at most 300 seconds. Command output is
never written to diagnostics.

An `outcome` of `staged_rebound` means one app-server response increased a main
quota by at least 10 points. The candidate is not published; it is rechecked
after 30 seconds and accepted only when a second response reports the same reset
generation. `app_server_pending_rebound` exposes this state on subsequent quota
resolution events.

Local cohort selection is reported separately in `local_selection_reason`:

- `single_generation`: recent local candidates agree.
- `post_reset_generation`: one cohort has actually crossed into a new window.
- `majority_future_generation`: conflicting future cohorts exist and the cohort
  with more recent-session support wins.
- `tie_earlier_reset`: support is tied, so the earlier stable reset wins until
  it expires or a later cohort gains more support.

Unchanged decisions are deduplicated, so normal refreshes do not flood the log.

Each `global_hot_key` event contains only the fixed shortcut identifier and a
`registered`, `registration_failed`, or `triggered` status. It never records
arbitrary keys or input text.

## Local Snapshot Degradation Boundary

RUN / IDLE is derived from the recent display-thread set plus rollout activity;
historical Token aggregation is a separate, non-authoritative input. A history
query failure must not clear active tasks or force the global state to IDLE.
Instead, Today / 24h / 7d / 30d usage stays on the available fallback and is
marked partial.

Database titles are bounded to 512 characters at the display-query boundary.
The month-wide aggregation query does not select titles, models, or reasoning
effort because those fields are not used for Token deltas. This keeps malformed
or transcript-sized titles from exhausting the generic command-output bound.

When the month-wide thread query fails for another reason, the safe diagnostic
event `usage_delta_thread_load` records only `outcome=partial`, a fixed reason,
and the requested range. It does not include titles, task content, database
paths, or raw SQLite output.

## Opt-in Performance History

The **Background performance monitoring** setting defaults off. When enabled,
the app samples every 60 seconds while the HUD detail panel is closed and writes
a separate bounded history to:

```text
~/Library/Logs/CodexMonitor/performance-samples.jsonl
```

The file is capped at 4 MiB with one rotated backup, uses `0600`, and lives in a
`0700` directory. Turning the setting off stops new sampling without deleting
the existing evidence. The visible Performance detail samples every five
seconds even when background history is disabled. Low Power Mode or
serious/critical thermal pressure slows either allowed cadence to five minutes.

Read a live one-shot snapshot:

```bash
~/Applications/codex监测.app/Contents/MacOS/CodexNotch \
  --print-performance-snapshot
```

Read the latest 200 persisted samples:

```bash
~/Applications/codex监测.app/Contents/MacOS/CodexNotch \
  --print-performance-history --limit 200
```

Each JSONL row contains only a timestamp, CPU percentage, RSS bytes, process
count, selected PID, and system memory free percentage for these scopes:

- Codex / ChatGPT desktop process tree;
- Safari host process tree;
- the hottest cross-application WebKit WebContent candidate;
- WindowServer compositor pressure.

WebKit XPC processes are commonly reparented to PID 1, so the lightweight
sampler cannot map them to a specific Safari tab. The hottest WebKit PID is an
`UNVERIFIED` owner candidate. Use a controlled change such as refreshing or
closing one suspected tab and compare whether that PID disappears and resource
use falls.

WindowServer CPU is a compositor-pressure proxy, not measured FPS. macOS does
not expose lightweight real FPS for arbitrary applications, and this monitor
does not request Screen Recording or Accessibility permission to manufacture
one.

## Privacy Boundary

Diagnostics never include task titles, prompts, rollout paths, account IDs,
emails, credentials, cookies, or API tokens. Only quota values, timestamps,
candidate counts, source names, selection reasons, and fixed operational status
identifiers are allowlisted.

Performance history also excludes executable paths, command arguments, URLs,
window titles, and page content. Executable paths from `ps` are used only in
memory to classify process groups and are discarded before persistence.

The last successful app-server quota is cached at:

```text
~/Library/Application Support/CodexNotch/app-server-rate-limits.json
```

The cache contains only quota percentages, reset times, Spark windows, reset
credit quantity/status/expiry, and the capture timestamp. Its file mode is
`0600` and its directory mode is `0700`.

## API-equivalent cost cache

Cost estimation adds internal checkpoint, frozen scan-generation targets,
lineage, working Session/day/model buckets, hashed usage-row occurrences, and
an atomically published bucket snapshot to the existing Swift-owned database:

```text
~/Library/Application Support/CodexNotch/usage-deltas.sqlite
```

It does not create a separate database, subprocess, periodic scanner, or
price-network service. The tables store Session IDs, file identity/offset checkpoints, frozen
target sizes and ordering, local day keys, normalized model names, aggregate
input/cache-read/output tokens, SHA-256 row identities, and derived cost. They
never store rollout paths, raw turn identifiers, prompts, responses, reasoning,
tool parameters, account data, or credentials. The three visible values are
standard API-price equivalents, not the ChatGPT/Codex subscription bill.

The scanner uses a dedicated serial utility executor coordinated by the existing
refresh infrastructure. Detail-page presentation does not invoke it. A new
automatic generation starts only while the system is unconstrained and at least
five minutes after the previous job; Codex activity does not starve it. Each job
stops and checkpoints after one 8 MiB logical input, 50ms process CPU, or 250ms
wall-time slice. If that finite generation remains budget- or fork-limited, one
five-second one-shot continuation reuses the current inventory and resumes the
persisted round-robin cursor. Continuations pause under Low Power Mode or thermal
pressure and stop scheduling when work is caught up, cancelled, unavailable, or
non-progressing. Bytes appended beyond the frozen targets wait for the next
generation. Once all frozen targets complete, their working buckets are
published and the targets are cleared in one transaction. Incomplete working
data is never published as money: first run shows `回填中`, while later scans
retain the last complete snapshot. Warm, caught-up jobs read no JSONL and write
no derived rows.

## Skill Insights Diagnostics

Skill Insights is a separate low-frequency pipeline. It is not invoked by the
file watcher, JSONL extend events, or the fast Token snapshot. Its setting is a
hard feature boundary: while disabled, the app does not instantiate the catalog
loader, scanner, derived database connection, or timer, and the `Skills` tab is
absent. The App checks the schedule once at startup, automatically analyzes at
most once per rolling seven days, and also supports an explicit **Analyze recent
7 days** action from the `Skills` detail tab. Automatic work runs at background
priority and manual work at utility priority. Neither path performs model,
embedding, or telemetry calls.
Catalog lookup sends only an initialize handshake plus `skills/list` over local
stdio to the installed Codex executable; it does not send Session content,
prompts, Skill bodies, or evidence to an external service.

The `skills/list` result is authoritative for membership and enabled state. It
already applies Codex configuration, plugin activation, scope, and path
precedence. If the local executable or protocol is unavailable, the app falls
back to direct frontmatter discovery, emits the diagnostic
`filesystem fallback may include inactive plugin cache entries`, and marks the
catalog `PARTIAL`. A fallback count must not be interpreted as exact current
enablement.

Derived state is stored at:

```text
~/Library/Application Support/CodexNotch/skill-observations.sqlite
```

The directory is restricted to `0700` and the database to `0600`. The store has
a 30-day retention policy and contains only catalog identifiers, current enabled
state snapshots, evidence categories, timestamps, stable project hashes,
Session IDs, Session-level Token references, source offsets, checkpoints, and
run statistics. It does not store complete prompts, assistant responses,
reasoning, secrets, or complete tool inputs/outputs. It never writes to Codex's
own state databases or `~/.codex/config.toml`.

Each file checkpoint records canonical path, inode, size, nanosecond mtime,
processed byte offset, last analysis time, status, oversized-row continuation,
and a derived cursor containing only stable Skill IDs and non-sensitive Session
references. An unchanged signature is skipped. Truncation, replacement, or
inode change removes that file's old derived observations before a complete
rescan. A fingerprint over Skill ID, name, description, path, and analyzer
version invalidates derived evidence when matching rules change. Enabled state
is deliberately excluded: neutral relevance/replacement evidence is classified
as suspected miss or SHADOW against the current catalog at report time. A
partial trailing JSONL line is retried from its start after a later append;
malformed rows and relevant/unknown oversized rows are skipped and reported as
`PARTIAL` instead of failing the file. Deterministically irrelevant reasoning or
tool-output rows can be filtered before full decoding, including oversized rows,
without degrading evidence completeness. The full-decoding cap is 256 KiB per
JSONL row; lowering this bound limits transient memory without silently treating
unknown or relevant data as complete. A run reads at most 2 GiB of logical
JSONL bytes, uses at most 15 seconds of process CPU, or runs for 30 wall-clock
seconds. It resumes remaining work from complete-line checkpoints. Low Power
Mode and serious/critical thermal state defer the scheduled run for that week
without adding retries; manual analysis remains available.

The latest run exposes these performance fields in the UI export:

- `candidateFiles`, `analyzedFiles`, `unchangedFiles`, and `pendingFiles`;
- `analyzedLines`, `parsedRows`, `filteredRows`, and `malformedLines`;
- `skippedOversizedRows` and `skippedIrrelevantOversizedRows`;
- `partialFiles`, `analyzedBytes`, and `boundaryProbeBytes`;
- `cpuMilliseconds`, process `diskReadBytes` / `diskWriteBytes`, observed peak
  physical footprint, and `databaseDurationMilliseconds`;
- `durationMilliseconds`, `lastCompletedAt`, and `wasDeferred`;
- `analyzerVersion` and the invariant `modelTokens = 0`.

`analyzedBytes` is logical JSONL data delivered by the reader and excludes
boundary probes. Disk fields are process I/O counter deltas and may be lower
than logical reads when macOS serves cached pages. `pendingFiles` means clean
work remains because a run bound was reached; `partialFiles` counts actual
malformed, oversized-relevant, unavailable, or otherwise incomplete files.

Interpret report status as follows:

- `COMPLETE`: the catalog loaded and every candidate file reached a complete
  checkpoint in the latest run.
- `PARTIAL`: authoritative catalog failure, filesystem fallback, configuration,
  file diagnostics, or pending budget work means some evidence may be missing.
  Per-Skill heuristic evidence can be partial without changing a fully scanned
  report's completeness.
- `UNAVAILABLE`: there is no usable catalog or completed analyzer run.

For a read-only local inspection, use SQLite's immutable/read-only URI mode and
never edit the derived database:

```bash
sqlite3 'file:'"$HOME"'/Library/Application Support/CodexNotch/skill-observations.sqlite?mode=ro' \
  'select completed_at_ms, quality, analyzed_files, unchanged_files, analyzed_lines, partial_files, duration_ms, model_tokens from skill_scan_runs order by id desc limit 5;'
```

Deleting the derived database is not part of normal diagnosis. If it is absent,
the app recreates it on the next manual or scheduled analysis; Codex-owned data
is unaffected.

## 中文说明

当顶部额度发生跳变时，先运行上面的 `--print-diagnostics` 命令。重点查看
`local_recent_generation_count`、两组 reset 时间和 `primary_decision` /
`secondary_decision`。`local_generation_count` 是全部候选中的历史周期数，
`local_recent_generation_count` 是最近十分钟仍在冲突的周期数，
`local_selected_generation_support` 是最终本地 cohort 的支持数。app-server
数据新鲜时始终以官方值为准；短暂失败或刚跨 reset 时保留最近一次官方值
15 分钟。reset 只触发官方复核，不会自动回满，也不会让本地单样本立即接管。
多个本地未来周期支持数相同时选择 reset 更早的稳定周期。若
`app_server_refresh.outcome = staged_rebound`，表示一次大幅回升正在等待第二次
同代次响应确认，尚未发布到 UI。

Skill Insights 使用独立的低频链路，不进入实时 Token 刷新。设置中关闭后不会
创建目录加载器、扫描器、数据库连接或定时器，Token / Quota / Delta 继续独立
运行。启用时启动后检查、滚动每 7 天最多自动分析一次，也可在详情页 `Skills`
手动增量分析最近 7 天。派生库位于
`~/Library/Application Support/CodexNotch/skill-observations.sqlite`，只保存
证据类别、时间、稳定标识、Session Token 参考值、文件检查点和性能统计；不保存
完整 Prompt、回答、reasoning 或工具输入输出，也不会修改 Codex 配置与数据库。
目录数量和启用状态以本机 Codex `skills/list` 为准；该请求只走本机 stdio，不发送
Session 内容。接口不可用时才回退读取 frontmatter，并明确标记 `PARTIAL`，因为回退
可能包含未激活的插件缓存。完整度只表示目录和文件是否扫描完整；逐条启发式证据
仍会单独标记质量。单次扫描受 2GiB 逻辑读取、15 秒进程 CPU 和 30 秒墙钟限制；
`pendingFiles` 表示预算后待续扫，`partialFiles` 只表示真实异常或证据缺失。
