#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/codex-notch-agy-smoke.XXXXXX")"
trap 'rm -rf "${BUILD_DIR}"' EXIT

swiftc \
  -swift-version 6 \
  -parse-as-library \
  "$ROOT_DIR/Sources/CodexNotch/AntigravityQuotaModels.swift" \
  "$ROOT_DIR/Sources/CodexNotch/AntigravityQuotaParser.swift" \
  "$ROOT_DIR/Sources/CodexNotch/AntigravityQuotaClient.swift" \
  "$ROOT_DIR/Sources/CodexNotch/AntigravityLocalSession.swift" \
  "$ROOT_DIR/Sources/CodexNotch/AntigravityLocalProbe.swift" \
  "$ROOT_DIR/Tests/AntigravityNativeSmoke/main.swift" \
  -o "$BUILD_DIR/AntigravityNativeSmoke"

"$BUILD_DIR/AntigravityNativeSmoke"
