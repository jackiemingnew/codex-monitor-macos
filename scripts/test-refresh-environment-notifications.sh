#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/codex-notch-refresh-environment.XXXXXX")"
trap 'rm -rf "${BUILD_DIR}"' EXIT

swiftc \
  -swift-version 6 \
  -parse-as-library \
  "$ROOT_DIR/Sources/CodexNotch/RefreshInfrastructure.swift" \
  "$ROOT_DIR/Tests/RefreshEnvironmentNotificationTests/main.swift" \
  -o "$BUILD_DIR/RefreshEnvironmentNotificationTests"

"$BUILD_DIR/RefreshEnvironmentNotificationTests"
