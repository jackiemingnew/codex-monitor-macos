#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="$(tr -d '[:space:]' < "$ROOT_DIR/VERSION")"
DIST_DIR="$ROOT_DIR/dist"
API_KEY_PATH="${APPLE_API_PRIVATE_KEY_PATH:-}"
API_KEY_ID="${APPLE_API_KEY_ID:-}"
API_ISSUER_ID="${APPLE_API_ISSUER_ID:-}"
CHECK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/codex-monitor-notarize.XXXXXX")"
MOUNT_POINTS=()

cleanup() {
  local mount_point
  set +u
  for mount_point in "${MOUNT_POINTS[@]}"; do
    hdiutil detach "$mount_point" >/dev/null 2>&1 || true
  done
  rm -rf "$CHECK_DIR"
}
trap cleanup EXIT

if [[ -z "$API_KEY_PATH" || -z "$API_KEY_ID" ]]; then
  echo "APPLE_API_PRIVATE_KEY_PATH and APPLE_API_KEY_ID are required" >&2
  exit 1
fi
if [[ ! -f "$API_KEY_PATH" ]]; then
  echo "APPLE_API_PRIVATE_KEY_PATH does not exist" >&2
  exit 1
fi

shopt -s nullglob
dmgs=("$DIST_DIR"/codex-monitor-"$VERSION"-*.dmg)
shopt -u nullglob
if [[ "${#dmgs[@]}" -ne 2 ]]; then
  echo "Expected arm64 and amd64 DMGs for version $VERSION" >&2
  exit 1
fi

notary_auth=(--key "$API_KEY_PATH" --key-id "$API_KEY_ID")
if [[ -n "$API_ISSUER_ID" ]]; then
  notary_auth+=(--issuer "$API_ISSUER_ID")
fi

for dmg_path in "${dmgs[@]}"; do
  result_path="$CHECK_DIR/$(basename "$dmg_path").json"
  xcrun notarytool submit "$dmg_path" \
    "${notary_auth[@]}" \
    --wait \
    --timeout 30m \
    --no-progress \
    --output-format json > "$result_path"

  python3 - "$result_path" <<'PY'
import json
import pathlib
import sys

result = json.loads(pathlib.Path(sys.argv[1]).read_text())
if result.get("status") != "Accepted":
    raise SystemExit(f"Notarization failed with status: {result.get('status', 'unknown')}")
PY

  xcrun stapler staple "$dmg_path"
  xcrun stapler validate "$dmg_path"
  hdiutil verify "$dmg_path"

  mount_point="$CHECK_DIR/mount-$(basename "$dmg_path" .dmg)"
  mkdir -p "$mount_point"
  MOUNT_POINTS+=("$mount_point")
  hdiutil attach -readonly -nobrowse -mountpoint "$mount_point" "$dmg_path" >/dev/null
  app_path="$mount_point/codex监测.app"
  codesign --verify --deep --strict --verbose=2 "$app_path"
  spctl --assess --type execute --verbose=2 "$app_path"
  hdiutil detach "$mount_point" >/dev/null
done

(
  cd "$DIST_DIR"
  shasum -a 256 codex-monitor-"$VERSION"-*.dmg > SHA256SUMS
  shasum -a 256 -c SHA256SUMS
)

echo "Notarized release artifacts for v$VERSION"
