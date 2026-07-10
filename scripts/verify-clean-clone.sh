#!/usr/bin/env bash
set -euo pipefail

REPOSITORY_URL="${1:-https://github.com/jackiemingnew/codex-monitor-macos.git}"
REF="${2:-main}"
OUTPUT_ROOT="${CLEAN_PACKAGE_OUTPUT_DIR:-$PWD/clean-package-artifacts}"
CLONE_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/Codex Monitor clean clone.XXXXXX")"
CHECKOUT_DIR="$CLONE_ROOT/Codex Monitor clean checkout"

cleanup() {
  if [[ "${KEEP_CLEAN_CLONE:-0}" == "1" ]]; then
    echo "Retained clean checkout: $CHECKOUT_DIR"
  else
    rm -rf "$CLONE_ROOT"
  fi
}
trap cleanup EXIT

echo "Cloning $REPOSITORY_URL at $REF"
git clone --depth 1 --branch "$REF" "$REPOSITORY_URL" "$CHECKOUT_DIR"

"$CHECKOUT_DIR/scripts/run-clean-package-checks.sh"

commit="$(git -C "$CHECKOUT_DIR" rev-parse --short=12 HEAD)"
output_dir="$OUTPUT_ROOT/$commit"
mkdir -p "$output_dir"
cp "$CHECKOUT_DIR"/dist/codex-monitor-*.dmg "$output_dir/"
cp "$CHECKOUT_DIR/dist/SHA256SUMS" "$output_dir/"

echo "Clean clone verified at commit $commit"
echo "Copied artifacts to $output_dir"
