#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/codex-notch-agy.XXXXXX")"
trap 'rm -rf "${BUILD_DIR}"' EXIT
export AGY_TEST_TMPDIR="$BUILD_DIR"

swiftc \
  -swift-version 6 \
  "$ROOT_DIR/Sources/CodexNotch/AntigravityQuotaModels.swift" \
  "$ROOT_DIR/Sources/CodexNotch/AntigravityQuotaParser.swift" \
  "$ROOT_DIR/Sources/CodexNotch/AntigravityQuotaPolicy.swift" \
  "$ROOT_DIR/Sources/CodexNotch/AntigravityQuotaCache.swift" \
  "$ROOT_DIR/Sources/CodexNotch/AntigravityQuotaClient.swift" \
  "$ROOT_DIR/Sources/CodexNotch/AntigravityLocalSession.swift" \
  "$ROOT_DIR/Sources/CodexNotch/AntigravityLocalProbe.swift" \
  "$ROOT_DIR/Tests/AntigravityQuotaTests/main.swift" \
  -lsqlite3 \
  -o "$BUILD_DIR/AntigravityQuotaTests"

"$BUILD_DIR/AntigravityQuotaTests"
