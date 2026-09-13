#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$ROOT_DIR/.build"
BUILD_DIR="$(mktemp -d "$ROOT_DIR/.build/light-detail-presentation.XXXXXX")"
trap 'rm -rf "$BUILD_DIR"' EXIT

swiftc \
  -swift-version 6 \
  "$ROOT_DIR/Sources/CodexNotch/RefreshInfrastructure.swift" \
  "$ROOT_DIR/Sources/CodexNotch/Models.swift" \
  "$ROOT_DIR/Sources/CodexNotch/LocalTokenAnalyticsModels.swift" \
  "$ROOT_DIR/Sources/CodexNotch/HUDDisplayModel.swift" \
  "$ROOT_DIR/Tests/LightDetailPresentationTests/main.swift" \
  -o "$BUILD_DIR/LightDetailPresentationTests"

"$BUILD_DIR/LightDetailPresentationTests"

assert_contains() {
    local needle="$1"
    local path="$2"
    if ! /usr/bin/grep -Fq -- "$needle" "$path"; then
        echo "FAILED: expected '$needle' in $path" >&2
        exit 1
    fi
}

THEME="$ROOT_DIR/Sources/CodexNotch/MonitorTheme.swift"
NOTCH="$ROOT_DIR/Sources/CodexNotch/NotchIslandView.swift"
CHART="$ROOT_DIR/Sources/CodexNotch/CodexWebAnalyticsChartView.swift"
LOCAL="$ROOT_DIR/Sources/CodexNotch/LocalTokenAnalyticsView.swift"
ROUTING="$ROOT_DIR/Sources/CodexNotch/RoutingTelemetryView.swift"

assert_contains "enum Pill" "$THEME"
assert_contains "MonitorTheme.Pill.running" "$ROOT_DIR/Sources/CodexNotch/MenuBarStatusView.swift"
assert_contains "MonitorTheme.Pill.warning" "$ROOT_DIR/Sources/CodexNotch/MenuBarStatusView.swift"
assert_contains "MonitorTheme.Pill.critical" "$ROOT_DIR/Sources/CodexNotch/MenuBarStatusView.swift"
assert_contains "static let tint = Color.black.opacity(0.48)" "$THEME"
assert_contains "private static func adaptiveColor" "$THEME"
assert_contains "static let detailBackground = adaptiveColor(light: rgb(248, 249, 247), dark: rgb(30, 32, 36))" "$THEME"
assert_contains "static let textPrimary = adaptiveColor(light: rgb(37, 42, 49), dark: rgb(231, 234, 240))" "$THEME"
assert_contains "static let accentBlue = adaptiveColor(light: rgb(54, 93, 199), dark: rgb(138, 172, 255))" "$THEME"
assert_contains "static let controlSelectedFill = adaptiveColor(light: rgb(234, 240, 255), dark: rgb(38, 56, 83))" "$THEME"
assert_contains "static let healthy = adaptiveColor(light: rgb(40, 121, 79), dark: rgb(120, 201, 154))" "$THEME"
assert_contains "static let heroValue" "$THEME"
assert_contains "static let quotaValue = Font.system(size: 13" "$THEME"
assert_contains "查看全部" "$NOTCH"
assert_contains "其他本地记录" "$NOTCH"
assert_contains "API 等值，非订阅账单" "$NOTCH"
assert_contains "含已归因子代理" "$NOTCH"
assert_contains "HUDVisualEffectView(material: .hudWindow)" "$NOTCH"
assert_contains "额度：Codex app-server" "$NOTCH"
assert_contains "本机 JSONL · 已发布快照" "$LOCAL"
assert_contains "state_*.sqlite · 每点为最近7日滚动快照" "$ROUTING"
assert_contains "MonitorTheme.routingTooltipSurface" "$CHART"
assert_contains "MonitorTheme.routingTooltipSurface" "$LOCAL"
assert_contains "官网数据 · 最近 7 天" "$ROOT_DIR/Sources/CodexNotch/CodexWebAnalyticsPanelView.swift"
assert_contains "snapshot.freshnessLabel" "$NOTCH"
assert_contains "snapshot.sourceUpdatedAt ?? snapshot.receivedAt" "$NOTCH"
assert_contains "HUDTaskPresentation.todayDenominator" "$NOTCH"
assert_contains "snapshot.periodUsageQuality.usage7dPartial" "$NOTCH"
assert_contains "snapshot.periodUsageQuality.usage30dPartial" "$NOTCH"
assert_contains "周期统计未启用" "$NOTCH"

if /usr/bin/grep -Eq '\.colorScheme\(\.dark\)' "$NOTCH" "$LOCAL" "$ROUTING"; then
    echo "FAILED: detail pages still force a dark color scheme" >&2
    exit 1
fi
if /usr/bin/grep -Fq '.environment(\.colorScheme' "$NOTCH"; then
    echo "FAILED: detail pages must inherit the detail panel appearance" >&2
    exit 1
fi
if /usr/bin/grep -Fq 'ultraThinMaterial' "$CHART" "$LOCAL" "$ROUTING"; then
    echo "FAILED: detail chart tooltip still uses material" >&2
    exit 1
fi

echo "light detail presentation assertions passed"
