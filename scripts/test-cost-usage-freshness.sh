#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$(mktemp -d "$ROOT_DIR/.build/codex-notch-freshness.XXXXXX")"
trap 'rm -rf "${BUILD_DIR}"' EXIT
export COST_USAGE_FRESHNESS_TMP="$BUILD_DIR"

swiftc \
  -swift-version 6 \
  "$ROOT_DIR/Sources/CodexNotch/RefreshInfrastructure.swift" \
  "$ROOT_DIR/Sources/CodexNotch/Models.swift" \
  "$ROOT_DIR/Sources/CodexNotch/LocalTokenAnalyticsModels.swift" \
  "$ROOT_DIR/Sources/CodexNotch/AppInfo.swift" \
  "$ROOT_DIR/Sources/CodexNotch/Formatters.swift" \
  "$ROOT_DIR/Sources/CodexNotch/HUDDisplayModel.swift" \
  "$ROOT_DIR/Sources/CodexNotch/SkillProcessMetrics.swift" \
  "${COST_USAGE_ESTIMATOR_SOURCE:-$ROOT_DIR/Sources/CodexNotch/CostUsageEstimator.swift}" \
  "$ROOT_DIR/Tests/CostUsageFreshnessTests/main.swift" \
  -lsqlite3 \
  -o "$BUILD_DIR/CostUsageFreshnessTests"

"$BUILD_DIR/CostUsageFreshnessTests"
