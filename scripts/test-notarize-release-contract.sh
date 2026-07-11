#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/codex-monitor-notary-contract.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT

mkdir -p "$TEST_DIR/scripts"
cp "$ROOT_DIR/VERSION" "$TEST_DIR/VERSION"
cp "$ROOT_DIR/scripts/notarize-release.sh" "$TEST_DIR/scripts/notarize-release.sh"

api_key_path="$TEST_DIR/AuthKey_TESTKEY.p8"
stderr_path="$TEST_DIR/stderr.log"
: > "$api_key_path"

set +e
APPLE_API_PRIVATE_KEY_PATH="$api_key_path" \
APPLE_API_KEY_ID="TESTKEY" \
APPLE_API_ISSUER_ID="" \
  bash "$TEST_DIR/scripts/notarize-release.sh" > /dev/null 2> "$stderr_path"
status=$?
set -e

if [[ "$status" -eq 0 ]]; then
  echo "Expected notarize-release.sh to reject a missing APPLE_API_ISSUER_ID" >&2
  exit 1
fi

expected_error="APPLE_API_ISSUER_ID is required for a Team API Key"
if ! grep -Fxq "$expected_error" "$stderr_path"; then
  echo "Expected missing-Issuer error, received:" >&2
  cat "$stderr_path" >&2
  exit 1
fi

echo "Notarization credential contract tests passed"
