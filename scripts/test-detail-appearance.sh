#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$(mktemp -d "$ROOT_DIR/.build/detail-appearance.XXXXXX")"
trap 'rm -rf "$BUILD_DIR"' EXIT

swiftc \
  -swift-version 6 \
  -framework AppKit \
  -framework SwiftUI \
  "$ROOT_DIR/Sources/CodexNotch/MonitorTheme.swift" \
  "$ROOT_DIR/Tests/DetailAppearanceTests/main.swift" \
  -o "$BUILD_DIR/DetailAppearanceTests"

"$BUILD_DIR/DetailAppearanceTests"

assert_contains() {
    local needle="$1"
    local path="$2"
    if ! rg -Fq "$needle" "$path"; then
        echo "FAILED: expected '$needle' in $path" >&2
        exit 1
    fi
}

APP_DELEGATE="$ROOT_DIR/Sources/CodexNotch/AppDelegate.swift"
assert_contains "settings.\$detailAppearance" "$APP_DELEGATE"
assert_contains "panel.appearance" "$APP_DELEGATE"
assert_contains "NSAppearance(named: .aqua)" "$APP_DELEGATE"
assert_contains "NSAppearance(named: .darkAqua)" "$APP_DELEGATE"
if rg -q 'NSApp\.appearance|window\.appearance' "$APP_DELEGATE"; then
    echo "FAILED: detail appearance must not override NSApp or the collapsed window" >&2
    exit 1
fi

echo "detail appearance integration assertions passed"
