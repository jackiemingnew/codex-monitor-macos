#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/codex-notch-agy-sidecar.XXXXXX")"
trap 'rm -rf "${BUILD_DIR}"' EXIT
export AGY_SIDECAR_TEST_TMPDIR="$BUILD_DIR"
export AGY_SIDECAR_REPO_ROOT="$ROOT_DIR"

swiftc \
  -swift-version 6 \
  -parse-as-library \
  "$ROOT_DIR/Sources/CodexNotch/AGYSidecarHealthModels.swift" \
  "$ROOT_DIR/Sources/CodexNotch/AGYSidecarReceiptParser.swift" \
  "$ROOT_DIR/Sources/CodexNotch/AGYSidecarProcessRunner.swift" \
  "$ROOT_DIR/Sources/CodexNotch/AGYSidecarHealthService.swift" \
  "$ROOT_DIR/Sources/CodexNotch/AGYSidecarHealthViewModel.swift" \
  "$ROOT_DIR/Sources/CodexNotch/MonitorDiagnostics.swift" \
  "$ROOT_DIR/Tests/AGYSidecarHealthTests/main.swift" \
  -o "$BUILD_DIR/AGYSidecarHealthTests"

"$BUILD_DIR/AGYSidecarHealthTests"
