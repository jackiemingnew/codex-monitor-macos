#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CHECK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/codex-monitor-package-check.XXXXXX")"
MOUNT_POINTS=()

cleanup() {
  local mount_point
  for mount_point in "${MOUNT_POINTS[@]}"; do
    hdiutil detach "$mount_point" >/dev/null 2>&1 || true
  done
  rm -rf "$CHECK_DIR"
}
trap cleanup EXIT

cd "$ROOT_DIR"

if [[ -n "$(git status --porcelain --untracked-files=no)" ]]; then
  echo "Tracked source files must be clean before clean-package verification" >&2
  git status --short --untracked-files=no >&2
  exit 1
fi

forbidden_paths="$(
  git grep -n -I -E '(/Users/[^/[:space:]]+/|/private/tmp/)' -- . \
    ':(exclude)scripts/run-clean-package-checks.sh' || true
)"
if [[ -n "$forbidden_paths" ]]; then
  echo "Tracked files contain developer-machine absolute paths:" >&2
  printf '%s\n' "$forbidden_paths" >&2
  exit 1
fi

swift_version="$(swift --version 2>&1)"
printf '%s\n' "$swift_version"
if ! grep -Eq 'Swift version 6\.' <<<"$swift_version"; then
  echo "Swift 6 is required for clean-package verification" >&2
  exit 1
fi
xcodebuild -version

unset CODEXRADAR_API_TOKEN
"$ROOT_DIR/scripts/run-regression-tests.sh"
"$ROOT_DIR/scripts/build-app.sh"

expected_version="$(sed -n 's/^APP_VERSION="\([^"]*\)"/\1/p' "$ROOT_DIR/scripts/build-app.sh")"
expected_bundle_id="$(sed -n 's/^BUNDLE_ID="\([^"]*\)"/\1/p' "$ROOT_DIR/scripts/build-app.sh")"
if [[ -z "$expected_version" || -z "$expected_bundle_id" ]]; then
  echo "Unable to read package metadata from scripts/build-app.sh" >&2
  exit 1
fi

validate_dmg() {
  local dmg_path="$1"
  local expected_arch="$2"
  local label="$3"
  local mount_point="$CHECK_DIR/mount-$label"
  local app_path="$mount_point/codex监测.app"
  local plist_path="$app_path/Contents/Info.plist"
  local binary_path="$app_path/Contents/MacOS/CodexNotch"
  local actual_arch
  local actual_version
  local actual_bundle_id

  mkdir -p "$mount_point"
  MOUNT_POINTS+=("$mount_point")
  hdiutil verify "$dmg_path"
  hdiutil attach -readonly -nobrowse -mountpoint "$mount_point" "$dmg_path" >/dev/null

  [[ -x "$binary_path" ]] || { echo "Missing packaged executable in $dmg_path" >&2; exit 1; }
  plutil -lint "$plist_path"
  codesign --verify --deep --strict "$app_path"

  actual_arch="$(lipo -archs "$binary_path")"
  [[ "$actual_arch" == "$expected_arch" ]] || {
    echo "$dmg_path contains $actual_arch, expected $expected_arch" >&2
    exit 1
  }

  actual_version="$(plutil -extract CFBundleShortVersionString raw -o - "$plist_path")"
  actual_bundle_id="$(plutil -extract CFBundleIdentifier raw -o - "$plist_path")"
  [[ "$actual_version" == "$expected_version" ]] || {
    echo "$dmg_path has version $actual_version, expected $expected_version" >&2
    exit 1
  }
  [[ "$actual_bundle_id" == "$expected_bundle_id" ]] || {
    echo "$dmg_path has bundle ID $actual_bundle_id, expected $expected_bundle_id" >&2
    exit 1
  }

  hdiutil detach "$mount_point" >/dev/null
}

shopt -s nullglob
arm64_dmgs=("$ROOT_DIR"/dist/codex-monitor-*-arm64.dmg)
amd64_dmgs=("$ROOT_DIR"/dist/codex-monitor-*-amd64.dmg)
shopt -u nullglob

[[ "${#arm64_dmgs[@]}" -eq 1 ]] || { echo "Expected exactly one arm64 DMG" >&2; exit 1; }
[[ "${#amd64_dmgs[@]}" -eq 1 ]] || { echo "Expected exactly one amd64 DMG" >&2; exit 1; }

validate_dmg "${arm64_dmgs[0]}" "arm64" "arm64"
validate_dmg "${amd64_dmgs[0]}" "x86_64" "amd64"

host_app="$ROOT_DIR/dist/codex监测.app"
host_binary="$host_app/Contents/MacOS/CodexNotch"
host_plist="$host_app/Contents/Info.plist"
[[ -x "$host_binary" ]] || { echo "Missing host app executable" >&2; exit 1; }
plutil -lint "$host_plist"
codesign --verify --deep --strict "$host_app"

fixture_home="$CHECK_DIR/empty Codex home"
mkdir -p "$fixture_home"
/usr/bin/sqlite3 "$fixture_home/state_5.sqlite" \
  'create table threads(id text,title text,tokens_used integer,model text,reasoning_effort text,rollout_path text,created_at integer,updated_at integer,archived integer default 0);'
/usr/bin/sqlite3 "$fixture_home/logs_2.sqlite" \
  'create table logs(thread_id text,ts integer,target text,feedback_log_body text);'

snapshot_path="$CHECK_DIR/snapshot.json"
"$host_binary" \
  --print-snapshot-json \
  --no-app-server \
  --codex-home "$fixture_home" > "$snapshot_path"

python3 - "$snapshot_path" <<'PY'
import json
import pathlib
import sys

snapshot = json.loads(pathlib.Path(sys.argv[1]).read_text())
assert snapshot["running"] is False
assert snapshot["tasks"] == []
assert "error" not in snapshot
PY

(
  cd "$ROOT_DIR/dist"
  shasum -a 256 codex-monitor-*.dmg > SHA256SUMS
  shasum -a 256 -c SHA256SUMS
)

git diff --exit-code
if [[ -n "$(git status --porcelain --untracked-files=no)" ]]; then
  echo "Clean-package verification modified tracked files" >&2
  git status --short --untracked-files=no >&2
  exit 1
fi

echo "Clean-package verification passed"
printf 'Artifacts:\n  %s\n  %s\n  %s\n' \
  "${arm64_dmgs[0]}" \
  "${amd64_dmgs[0]}" \
  "$ROOT_DIR/dist/SHA256SUMS"
