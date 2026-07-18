#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 /path/to/CodexNotch" >&2
  exit 2
fi

BINARY="$1"
if [[ ! -x "$BINARY" ]]; then
  echo "CodexNotch binary is not executable: $BINARY" >&2
  exit 2
fi

ROOT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/codex-notch-oversized-title.XXXXXX")"
trap 'rm -rf "$ROOT_DIR"' EXIT

create_fixture() {
  local name="$1"
  local filler_mode="$2"
  local root="$ROOT_DIR/$name"
  local codex_home="$root/codex"
  local session_id="019f6bf7-22e5-70b0-bd50-37522274da88"
  local session_dir="$codex_home/sessions/2026/07/17"
  local rollout="$session_dir/rollout-2026-07-17T04-00-00-$session_id.jsonl"
  local state_db="$codex_home/state_5.sqlite"
  local logs_db="$codex_home/logs_2.sqlite"
  local now_epoch
  local timestamp
  now_epoch="$(date +%s)"
  timestamp="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"

  mkdir -p "$session_dir"
  printf '%s\n' \
    "{\"timestamp\":\"$timestamp\",\"type\":\"response_item\",\"payload\":{\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"still running\"}]}}" \
    > "$rollout"
  printf '%s\n' \
    "{\"id\":\"$session_id\",\"thread_name\":\"Oversized title active\",\"updated_at\":\"$timestamp\"}" \
    > "$codex_home/session_index.jsonl"

  /usr/bin/sqlite3 "$state_db" <<SQL
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
insert into threads(id, title, tokens_used, model, reasoning_effort, rollout_path, created_at, updated_at, archived)
values('$session_id', 'Oversized title active', 1200, 'gpt-5.6-sol', 'max', '$rollout', $now_epoch, $((now_epoch + 1)), 0);
SQL

  case "$filler_mode" in
    archived-long-titles)
      /usr/bin/sqlite3 "$state_db" <<SQL
with recursive seq(value) as (
  select 1
  union all
  select value + 1 from seq where value < 24
)
insert into threads(id, title, tokens_used, model, reasoning_effort, rollout_path, created_at, updated_at, archived)
select printf('archived-%02d', value), printf('%.*c', 50000, 'x'), value, null, null, '', $now_epoch, $now_epoch, 1
from seq;
SQL
      ;;
    visible-long-titles)
      /usr/bin/sqlite3 "$state_db" <<SQL
with recursive seq(value) as (
  select 1
  union all
  select value + 1 from seq where value < 24
)
insert into threads(id, title, tokens_used, model, reasoning_effort, rollout_path, created_at, updated_at, archived)
select printf('visible-%02d', value), printf('%.*c', 50000, 'x'), value, null, null, '', $now_epoch, $now_epoch, 0
from seq;
SQL
      ;;
    invalid-history-row)
      /usr/bin/sqlite3 "$state_db" <<SQL
insert into threads(id, title, tokens_used, model, reasoning_effort, rollout_path, created_at, updated_at, archived)
values('invalid-history', 'invalid history row', 'not-an-integer', null, null, '', $now_epoch, $now_epoch, 1);
SQL
      ;;
    *)
      echo "unknown fixture mode: $filler_mode" >&2
      exit 2
      ;;
  esac

  /usr/bin/sqlite3 "$logs_db" <<'SQL'
create table logs(
  thread_id text,
  ts integer,
  target text,
  feedback_log_body text
);
SQL

  printf '%s\n' "$codex_home" "$session_id"
}

assert_oversized_query() {
  local database="$1"
  local query="$2"
  local bytes
  bytes="$(/usr/bin/sqlite3 -readonly -json "$database" "$query" | wc -c | tr -d ' ')"
  if (( bytes <= 1048576 )); then
    echo "fixture did not cross the 1 MiB shell output boundary: $bytes bytes" >&2
    exit 1
  fi
}

run_snapshot_case() {
  local name="$1"
  local filler_mode="$2"
  local expect_partial="$3"
  local fixture
  local codex_home
  local session_id
  local output
  local stderr_file
  fixture="$(create_fixture "$name" "$filler_mode")"
  codex_home="$(printf '%s\n' "$fixture" | sed -n '1p')"
  session_id="$(printf '%s\n' "$fixture" | sed -n '2p')"
  stderr_file="$codex_home/stderr.txt"

  if [[ "$filler_mode" == "archived-long-titles" ]]; then
    assert_oversized_query "$codex_home/state_5.sqlite" \
      "select id, coalesce(title, 'unnamed') as title, coalesce(tokens_used, 0) as tokens_used, model, reasoning_effort, coalesce(rollout_path, '') as rollout_path, coalesce(updated_at, 0) as updated_at, coalesce(created_at, 0) as created_at from threads where coalesce(nullif(updated_at, 0), nullif(created_at, 0), 0) >= $(date +%s) - 2592000 order by coalesce(nullif(updated_at, 0), nullif(created_at, 0), 0) desc;"
  elif [[ "$filler_mode" == "visible-long-titles" ]]; then
    assert_oversized_query "$codex_home/state_5.sqlite" \
      "select id, coalesce(title, 'unnamed') as title, coalesce(tokens_used, 0) as tokens_used, model, reasoning_effort, coalesce(rollout_path, '') as rollout_path, coalesce(updated_at, 0) as updated_at, coalesce(created_at, 0) as created_at from threads where archived = 0 order by updated_at desc limit 80;"
  fi

  output="$("$BINARY" \
    --print-fast-snapshot-json \
    --no-app-server \
    --codex-home "$codex_home" \
    --db "$codex_home/state_5.sqlite" \
    --logs-db "$codex_home/logs_2.sqlite" \
    --delta-db "$codex_home/usage-deltas.sqlite" \
    2>"$stderr_file")"

  if ! printf '%s' "$output" | /usr/bin/jq -e \
    --arg id "$session_id" \
    --argjson expect_partial "$expect_partial" \
    '(.running == true)
      and (.error == null)
      and any(.tasks[]?; .id == $id and .status == "running")
      and (($expect_partial | not) or (
        .daily_usage.is_partial == true
        and .period_usage_quality.usage_24h_partial == true
        and .period_usage_quality.usage_7d_partial == true
        and .period_usage_quality.usage_30d_partial == true
      ))' \
    >/dev/null; then
    echo "oversized-title status regression failed: $name" >&2
    printf '%s' "$output" | /usr/bin/jq \
      '{running, error, daily_partial:.daily_usage.is_partial, period_quality:.period_usage_quality, tasks:[.tasks[]? | {id,status,title}]}' \
      >&2 || true
    if [[ -s "$stderr_file" ]]; then
      sed -n '1,40p' "$stderr_file" >&2
    fi
    exit 1
  fi
}

run_snapshot_case "history-title-projection" "archived-long-titles" false
run_snapshot_case "display-title-projection" "visible-long-titles" false
run_snapshot_case "history-failure-isolation" "invalid-history-row" true

echo "Oversized title status regression checks passed"
