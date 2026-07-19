#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/codex-notch-refresh-energy.XXXXXX")"
ROUNDS="${ROUNDS:-3}"
WARMUP_SECONDS="${WARMUP_SECONDS:-30}"
MEASUREMENT_SECONDS="${MEASUREMENT_SECONDS:-600}"
FIXTURE_ROWS="${FIXTURE_ROWS:-5000}"
BENCHMARK_PROFILE="${BENCHMARK_PROFILE:-refresh}"
RESULTS_FILE="$BUILD_DIR/results.jsonl"
trap 'rm -rf "$BUILD_DIR"' EXIT

if [[ ! "$ROUNDS" =~ ^[1-9][0-9]*$ ]] \
  || [[ ! "$WARMUP_SECONDS" =~ ^[0-9]+([.][0-9]+)?$ ]] \
  || [[ ! "$MEASUREMENT_SECONDS" =~ ^[0-9]+([.][0-9]+)?$ ]] \
  || [[ ! "$FIXTURE_ROWS" =~ ^[1-9][0-9]*$ ]]; then
  echo "ROUNDS, WARMUP_SECONDS, MEASUREMENT_SECONDS, and FIXTURE_ROWS must be positive numbers" >&2
  exit 64
fi

case "$BENCHMARK_PROFILE" in
  refresh)
    CONTROL_MODE="fixed"
    CANDIDATE_MODE="adaptive"
    ;;
  cost)
    CONTROL_MODE="cost-off"
    CANDIDATE_MODE="cost-on"
    ;;
  *)
    echo "BENCHMARK_PROFILE must be refresh or cost" >&2
    exit 64
    ;;
esac

swiftc \
  -O \
  -parse-as-library \
  -swift-version 6 \
  "$ROOT_DIR/Sources/CodexNotch/RefreshInfrastructure.swift" \
  "$ROOT_DIR/Sources/CodexNotch/LocalTokenAnalyticsModels.swift" \
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
  "$ROOT_DIR/Sources/CodexNotch/CostUsageEstimator.swift" \
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
COST_SESSION_ID="11111111-1111-4111-8111-111111111111"
COST_SESSION_PATH="$TEMPLATE_DIR/sessions/rollout-$COST_SESSION_ID.jsonl"

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
insert into threads(id, title, tokens_used, model, reasoning_effort, rollout_path, created_at, updated_at, archived)
values(
  '$COST_SESSION_ID',
  'Synthetic cost fixture',
  150000,
  'gpt-5.6-sol',
  'medium',
  '$COST_SESSION_PATH',
  $((NOW_EPOCH - 2)),
  $((NOW_EPOCH - 1)),
  1
);
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

printf '%s\n' \
  "{\"timestamp\":$((NOW_EPOCH - 2)),\"type\":\"turn_context\",\"payload\":{\"model\":\"gpt-5.6-sol\"}}" \
  "{\"timestamp\":$((NOW_EPOCH - 1)),\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":{\"last_token_usage\":{\"input_tokens\":100000,\"cached_input_tokens\":40000,\"output_tokens\":10000},\"total_token_usage\":{\"input_tokens\":100000,\"cached_input_tokens\":40000,\"output_tokens\":10000}}}}" \
  >"$COST_SESSION_PATH"

echo "$BENCHMARK_PROFILE energy A/B: $ROUNDS paired rounds, ${WARMUP_SECONDS}s warm-up + ${MEASUREMENT_SECONDS}s measurement"

for ((round = 1; round <= ROUNDS; round += 1)); do
  control_fixture="$BUILD_DIR/round-$round-control"
  candidate_fixture="$BUILD_DIR/round-$round-candidate"
  cp -R "$TEMPLATE_DIR" "$control_fixture"
  cp -R "$TEMPLATE_DIR" "$candidate_fixture"

  "$BUILD_DIR/RefreshEnergyWorker" \
    "$CONTROL_MODE" "$control_fixture" "$WARMUP_SECONDS" "$MEASUREMENT_SECONDS" "round-$round-control" \
    >"$BUILD_DIR/round-$round-control.json" \
    2>"$BUILD_DIR/round-$round-control.err" &
  control_pid=$!
  "$BUILD_DIR/RefreshEnergyWorker" \
    "$CANDIDATE_MODE" "$candidate_fixture" "$WARMUP_SECONDS" "$MEASUREMENT_SECONDS" "round-$round-candidate" \
    >"$BUILD_DIR/round-$round-candidate.json" \
    2>"$BUILD_DIR/round-$round-candidate.err" &
  candidate_pid=$!

  elapsed=0
  while kill -0 "$control_pid" 2>/dev/null || kill -0 "$candidate_pid" 2>/dev/null; do
    sleep 30
    elapsed=$((elapsed + 30))
    echo "round $round/$ROUNDS: ${elapsed}s elapsed"
  done

  control_status=0
  candidate_status=0
  wait "$control_pid" || control_status=$?
  wait "$candidate_pid" || candidate_status=$?
  if ((control_status != 0 || candidate_status != 0)); then
    cat "$BUILD_DIR/round-$round-control.err" >&2
    cat "$BUILD_DIR/round-$round-candidate.err" >&2
    exit 1
  fi

  jq -e . "$BUILD_DIR/round-$round-control.json" >/dev/null
  jq -e . "$BUILD_DIR/round-$round-candidate.json" >/dev/null
  jq -c . "$BUILD_DIR/round-$round-control.json" | tee -a "$RESULTS_FILE"
  jq -c . "$BUILD_DIR/round-$round-candidate.json" | tee -a "$RESULTS_FILE"
done

jq -s --arg profile "$BENCHMARK_PROFILE" --arg control "$CONTROL_MODE" --arg candidate "$CANDIDATE_MODE" '
  def median:
    sort as $values
    | ($values | length) as $count
    | if $count == 0 then null
      elif ($count % 2) == 1 then $values[($count / 2 | floor)]
      else (($values[$count / 2 - 1] + $values[$count / 2]) / 2)
      end;
  {
    profile: $profile,
    control_mode: $control,
    candidate_mode: $candidate,
    control_average_cpu_median: ([.[] | select(.mode == $control) | .average_cpu_percent] | median),
    candidate_average_cpu_median: ([.[] | select(.mode == $candidate) | .average_cpu_percent] | median),
    control_p95_cpu_median: ([.[] | select(.mode == $control) | .p95_cpu_percent] | median),
    candidate_p95_cpu_median: ([.[] | select(.mode == $candidate) | .p95_cpu_percent] | median),
    control_peak_resident_median: ([.[] | select(.mode == $control) | .peak_resident_bytes] | median),
    candidate_peak_resident_median: ([.[] | select(.mode == $candidate) | .peak_resident_bytes] | median),
    control_request_count_median: ([.[] | select(.mode == $control) | .request_count] | median),
    candidate_request_count_median: ([.[] | select(.mode == $candidate) | .request_count] | median),
    all_idle: all(.[]; (.is_running | not) and (.is_refreshing | not)),
    no_context_jsonl_rescan: all(.[]; .rate_limit_scan_delta == 0 and .activity_scan_delta == 0 and .jsonl_context_scans == 0),
    no_cost_jsonl_rescan: all(.[]; .cost_jsonl_bytes_read == 0 and .cost_files_advanced == 0 and .cost_database_writes == 0),
    no_derived_cost_growth: all(.[]; .derived_cost_row_delta == 0)
  }
  | .average_cpu_change = (.candidate_average_cpu_median - .control_average_cpu_median)
  | .request_reduction = (if .control_request_count_median > 0 then 1 - .candidate_request_count_median / .control_request_count_median else 0 end)
  | .average_cpu_gate = if $profile == "refresh"
      then (.control_average_cpu_median > 0 and .candidate_average_cpu_median <= .control_average_cpu_median * 0.80)
      else (.candidate_average_cpu_median <= .control_average_cpu_median * 1.05 and .average_cpu_change <= 0.05)
    end
  | .p95_cpu_gate = if $profile == "refresh"
      then (.candidate_p95_cpu_median <= .control_p95_cpu_median * 1.15 + 0.05)
      else (.candidate_p95_cpu_median <= 10)
    end
  | .peak_memory_gate = if $profile == "refresh"
      then (.candidate_peak_resident_median <= .control_peak_resident_median * 1.10 + 4194304)
      else (.candidate_peak_resident_median <= .control_peak_resident_median + 5242880)
    end
  | .passed = (.average_cpu_gate and .p95_cpu_gate and .peak_memory_gate and .all_idle and .no_context_jsonl_rescan and .no_cost_jsonl_rescan and .no_derived_cost_growth)
' "$RESULTS_FILE" | tee "$BUILD_DIR/summary.json"

jq -e '.passed == true' "$BUILD_DIR/summary.json" >/dev/null
