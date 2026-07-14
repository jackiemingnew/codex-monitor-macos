#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/codex-notch-refresh-energy.XXXXXX")"
ROUNDS="${ROUNDS:-3}"
WARMUP_SECONDS="${WARMUP_SECONDS:-30}"
MEASUREMENT_SECONDS="${MEASUREMENT_SECONDS:-600}"
FIXTURE_ROWS="${FIXTURE_ROWS:-5000}"
RESULTS_FILE="$BUILD_DIR/results.jsonl"
trap 'rm -rf "$BUILD_DIR"' EXIT

if [[ ! "$ROUNDS" =~ ^[1-9][0-9]*$ ]] \
  || [[ ! "$WARMUP_SECONDS" =~ ^[0-9]+([.][0-9]+)?$ ]] \
  || [[ ! "$MEASUREMENT_SECONDS" =~ ^[0-9]+([.][0-9]+)?$ ]] \
  || [[ ! "$FIXTURE_ROWS" =~ ^[1-9][0-9]*$ ]]; then
  echo "ROUNDS, WARMUP_SECONDS, MEASUREMENT_SECONDS, and FIXTURE_ROWS must be positive numbers" >&2
  exit 64
fi

swiftc \
  -O \
  -parse-as-library \
  -swift-version 6 \
  "$ROOT_DIR/Sources/CodexNotch/RefreshInfrastructure.swift" \
  "$ROOT_DIR/Sources/CodexNotch/Models.swift" \
  "$ROOT_DIR/Sources/CodexNotch/AppInfo.swift" \
  "$ROOT_DIR/Sources/CodexNotch/Formatters.swift" \
  "$ROOT_DIR/Sources/CodexNotch/SnapshotOutputFormatter.swift" \
  "$ROOT_DIR/Sources/CodexNotch/DisplayRedactor.swift" \
  "$ROOT_DIR/Sources/CodexNotch/NetworkSecurityPolicy.swift" \
  "$ROOT_DIR/Sources/CodexNotch/IslandMetrics.swift" \
  "$ROOT_DIR/Sources/CodexNotch/HUDDisplayModel.swift" \
  "$ROOT_DIR/Sources/CodexNotch/Shell.swift" \
  "$ROOT_DIR/Sources/CodexNotch/CodexRuntimeLocator.swift" \
  "$ROOT_DIR/Sources/CodexNotch/KeychainStore.swift" \
  "$ROOT_DIR/Sources/CodexNotch/SecretStore.swift" \
  "$ROOT_DIR/Sources/CodexNotch/MonitorDiagnostics.swift" \
  "$ROOT_DIR/Sources/CodexNotch/CodexRadarModels.swift" \
  "$ROOT_DIR/Sources/CodexNotch/CodexRadarClient.swift" \
  "$ROOT_DIR/Sources/CodexNotch/CodexRadarViewModel.swift" \
  "$ROOT_DIR/Sources/CodexNotch/CodexNotchSettings.swift" \
  "$ROOT_DIR/Sources/CodexNotch/CodexSessionFileLocator.swift" \
  "$ROOT_DIR/Sources/CodexNotch/SkillInsightsModels.swift" \
  "$ROOT_DIR/Sources/CodexNotch/CodexSkillsAppServerClient.swift" \
  "$ROOT_DIR/Sources/CodexNotch/SkillCatalogLoader.swift" \
  "$ROOT_DIR/Sources/CodexNotch/SkillProcessMetrics.swift" \
  "$ROOT_DIR/Sources/CodexNotch/SkillJSONLReader.swift" \
  "$ROOT_DIR/Sources/CodexNotch/SkillObservationStore.swift" \
  "$ROOT_DIR/Sources/CodexNotch/SkillSessionAnalyzer.swift" \
  "$ROOT_DIR/Sources/CodexNotch/SkillInsightsService.swift" \
  "$ROOT_DIR/Sources/CodexNotch/SkillInsightsViewModel.swift" \
  "$ROOT_DIR/Sources/CodexNotch/CodexUsageStore.swift" \
  "$ROOT_DIR/Sources/CodexNotch/BalanceMonitorModels.swift" \
  "$ROOT_DIR/Sources/CodexNotch/BalanceAPIClient.swift" \
  "$ROOT_DIR/Sources/CodexNotch/RemoteMonitorModels.swift" \
  "$ROOT_DIR/Sources/CodexNotch/CLIProxyAPIClient.swift" \
  "$ROOT_DIR/Sources/CodexNotch/CodexFileWatcher.swift" \
  "$ROOT_DIR/Sources/CodexNotch/UsageViewModel.swift" \
  "$ROOT_DIR/Tests/RefreshEnergyWorker/main.swift" \
  -o "$BUILD_DIR/RefreshEnergyWorker"

TEMPLATE_DIR="$BUILD_DIR/template"
mkdir -p "$TEMPLATE_DIR/sessions"
NOW_EPOCH="$(date +%s)"
OLDEST_EPOCH="$((NOW_EPOCH - 4 * 24 * 60 * 60))"

/usr/bin/sqlite3 "$TEMPLATE_DIR/state_5.sqlite" <<SQL
create table threads(
  id text,
  title text,
  tokens_used integer,
  model text,
  reasoning_effort text,
  rollout_path text,
  created_at integer,
  updated_at integer,
  archived integer default 0
);
create index threads_updated_at on threads(updated_at);
with recursive sequence(value) as (
  select 1
  union all
  select value + 1 from sequence where value < $FIXTURE_ROWS
)
insert into threads(id, title, tokens_used, model, reasoning_effort, rollout_path, created_at, updated_at, archived)
select
  printf('synthetic-%06d', value),
  printf('Synthetic idle task %d', value),
  value * 10,
  'synthetic-model',
  'medium',
  '',
  $OLDEST_EPOCH - value,
  $OLDEST_EPOCH - value,
  1
from sequence;
SQL

/usr/bin/sqlite3 "$TEMPLATE_DIR/logs_2.sqlite" <<'SQL'
create table logs(
  thread_id text,
  ts integer,
  target text,
  feedback_log_body text
);
create index logs_thread_ts on logs(thread_id, ts);
SQL

echo "Refresh energy A/B: $ROUNDS paired rounds, ${WARMUP_SECONDS}s warm-up + ${MEASUREMENT_SECONDS}s measurement"

for ((round = 1; round <= ROUNDS; round += 1)); do
  fixed_fixture="$BUILD_DIR/round-$round-fixed"
  adaptive_fixture="$BUILD_DIR/round-$round-adaptive"
  cp -R "$TEMPLATE_DIR" "$fixed_fixture"
  cp -R "$TEMPLATE_DIR" "$adaptive_fixture"

  "$BUILD_DIR/RefreshEnergyWorker" \
    fixed "$fixed_fixture" "$WARMUP_SECONDS" "$MEASUREMENT_SECONDS" "round-$round-fixed" \
    >"$BUILD_DIR/round-$round-fixed.json" \
    2>"$BUILD_DIR/round-$round-fixed.err" &
  fixed_pid=$!
  "$BUILD_DIR/RefreshEnergyWorker" \
    adaptive "$adaptive_fixture" "$WARMUP_SECONDS" "$MEASUREMENT_SECONDS" "round-$round-adaptive" \
    >"$BUILD_DIR/round-$round-adaptive.json" \
    2>"$BUILD_DIR/round-$round-adaptive.err" &
  adaptive_pid=$!

  elapsed=0
  while kill -0 "$fixed_pid" 2>/dev/null || kill -0 "$adaptive_pid" 2>/dev/null; do
    sleep 30
    elapsed=$((elapsed + 30))
    echo "round $round/$ROUNDS: ${elapsed}s elapsed"
  done

  fixed_status=0
  adaptive_status=0
  wait "$fixed_pid" || fixed_status=$?
  wait "$adaptive_pid" || adaptive_status=$?
  if ((fixed_status != 0 || adaptive_status != 0)); then
    cat "$BUILD_DIR/round-$round-fixed.err" >&2
    cat "$BUILD_DIR/round-$round-adaptive.err" >&2
    exit 1
  fi

  jq -e . "$BUILD_DIR/round-$round-fixed.json" >/dev/null
  jq -e . "$BUILD_DIR/round-$round-adaptive.json" >/dev/null
  jq -c . "$BUILD_DIR/round-$round-fixed.json" | tee -a "$RESULTS_FILE"
  jq -c . "$BUILD_DIR/round-$round-adaptive.json" | tee -a "$RESULTS_FILE"
done

jq -s '
  def median:
    sort as $values
    | ($values | length) as $count
    | if $count == 0 then null
      elif ($count % 2) == 1 then $values[($count / 2 | floor)]
      else (($values[$count / 2 - 1] + $values[$count / 2]) / 2)
      end;
  {
    fixed_average_cpu_median: ([.[] | select(.mode == "fixed") | .average_cpu_percent] | median),
    adaptive_average_cpu_median: ([.[] | select(.mode == "adaptive") | .average_cpu_percent] | median),
    fixed_p95_cpu_median: ([.[] | select(.mode == "fixed") | .p95_cpu_percent] | median),
    adaptive_p95_cpu_median: ([.[] | select(.mode == "adaptive") | .p95_cpu_percent] | median),
    fixed_peak_resident_median: ([.[] | select(.mode == "fixed") | .peak_resident_bytes] | median),
    adaptive_peak_resident_median: ([.[] | select(.mode == "adaptive") | .peak_resident_bytes] | median),
    fixed_request_count_median: ([.[] | select(.mode == "fixed") | .request_count] | median),
    adaptive_request_count_median: ([.[] | select(.mode == "adaptive") | .request_count] | median),
    all_idle: all(.[]; (.is_running | not) and (.is_refreshing | not)),
    no_jsonl_rescan: all(.[]; .prefix_scan_delta == 0 and .rate_limit_scan_delta == 0 and .activity_scan_delta == 0 and .jsonl_context_scans == 0)
  }
  | .average_cpu_reduction = (if .fixed_average_cpu_median > 0 then 1 - .adaptive_average_cpu_median / .fixed_average_cpu_median else 0 end)
  | .request_reduction = (if .fixed_request_count_median > 0 then 1 - .adaptive_request_count_median / .fixed_request_count_median else 0 end)
  | .average_cpu_gate = (.fixed_average_cpu_median > 0 and .adaptive_average_cpu_median <= .fixed_average_cpu_median * 0.80)
  | .p95_cpu_gate = (.adaptive_p95_cpu_median <= .fixed_p95_cpu_median * 1.15 + 0.05)
  | .peak_memory_gate = (.adaptive_peak_resident_median <= .fixed_peak_resident_median * 1.10 + 4194304)
  | .passed = (.average_cpu_gate and .p95_cpu_gate and .peak_memory_gate and .all_idle and .no_jsonl_rescan)
' "$RESULTS_FILE" | tee "$BUILD_DIR/summary.json"

jq -e '.passed == true' "$BUILD_DIR/summary.json" >/dev/null
