# Codex Monitor Diagnostics

Codex Monitor records quota-resolution decisions so a percentage jump can be
explained without reading task content or inspecting raw rollout files.

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

## Privacy Boundary

Diagnostics never include task titles, prompts, rollout paths, account IDs,
emails, credentials, cookies, or API tokens. Only quota values, timestamps,
candidate counts, source names, and selection reasons are allowlisted.

The last successful app-server quota is cached at:

```text
~/Library/Application Support/CodexNotch/app-server-rate-limits.json
```

The cache contains only quota percentages, reset times, Spark windows, and the
capture timestamp. Its file mode is `0600` and its directory mode is `0700`.

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
