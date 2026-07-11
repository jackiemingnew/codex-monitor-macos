#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="codex监测"
PACKAGE_NAME="codex-monitor"
APP_VERSION="$(tr -d '[:space:]' < "$ROOT_DIR/VERSION")"
APP_BUILD_NUMBER="${APP_BUILD_NUMBER:-1}"
BUNDLE_ID="com.alight.codexnotch"
CODE_SIGN_IDENTITY="${CODE_SIGN_IDENTITY:--}"
DIST_DIR="$ROOT_DIR/dist"
APP_DIR="$DIST_DIR/$APP_NAME.app"
DMG_STAGE_DIR="$DIST_DIR/dmg-stage"
PACKAGE_STAGE_DIR="$DIST_DIR/package-stage"
ICON_BUILD_DIR="$DIST_DIR/icon-build"
ICON_PATH="$ICON_BUILD_DIR/AppIcon.icns"

if [[ ! "$APP_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "VERSION must contain a semantic version such as 0.2.0" >&2
  exit 1
fi
if [[ ! "$APP_BUILD_NUMBER" =~ ^[1-9][0-9]*$ ]]; then
  echo "APP_BUILD_NUMBER must be a positive integer" >&2
  exit 1
fi

cd "$ROOT_DIR"
mkdir -p "$DIST_DIR"
swift "$ROOT_DIR/scripts/generate-app-icon.swift" "$ICON_BUILD_DIR"
find "$DIST_DIR" -maxdepth 1 -type f \( -name "$APP_NAME.dmg" -o -name "$APP_NAME-*.dmg" -o -name "$PACKAGE_NAME-*.dmg" \) -delete
rm -rf "$DMG_STAGE_DIR" "$PACKAGE_STAGE_DIR"

create_app_bundle() {
  local binary_path="$1"
  local app_dir="$2"
  local contents_dir="$app_dir/Contents"
  local macos_dir="$contents_dir/MacOS"
  local resources_dir="$contents_dir/Resources"

  rm -rf "$app_dir"
  mkdir -p "$macos_dir" "$resources_dir"
  cp "$binary_path" "$macos_dir/CodexNotch"
  cp "$ICON_PATH" "$resources_dir/AppIcon.icns"

  cat > "$contents_dir/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>CodexNotch</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundleName</key>
  <string>$APP_NAME</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>$APP_VERSION</string>
  <key>CFBundleVersion</key>
  <string>$APP_BUILD_NUMBER</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
PLIST

  if [[ "$CODE_SIGN_IDENTITY" == "-" ]]; then
    codesign --force --sign - "$macos_dir/CodexNotch"
    codesign --force --sign - "$app_dir"
  else
    codesign --force --options runtime --timestamp --sign "$CODE_SIGN_IDENTITY" "$macos_dir/CodexNotch"
    codesign --force --options runtime --timestamp --sign "$CODE_SIGN_IDENTITY" "$app_dir"
  fi
  codesign --verify --deep --strict "$app_dir"
}

build_arch() {
  local swift_arch="$1"
  local dmg_arch="$2"
  local build_dir="$ROOT_DIR/.build/$swift_arch-apple-macosx/release"
  local staged_app="$PACKAGE_STAGE_DIR/$dmg_arch/$APP_NAME.app"
  local dmg_path="$DIST_DIR/$PACKAGE_NAME-$APP_VERSION-$dmg_arch.dmg"

  swift build -c release --arch "$swift_arch"
  create_app_bundle "$build_dir/CodexNotch" "$staged_app"

  rm -rf "$DMG_STAGE_DIR"
  mkdir -p "$DMG_STAGE_DIR"
  ditto "$staged_app" "$DMG_STAGE_DIR/$APP_NAME.app"
  hdiutil create -volname "$APP_NAME" -srcfolder "$DMG_STAGE_DIR" -ov -format UDZO "$dmg_path"
  echo "Built $dmg_path"
}

build_arch "arm64" "arm64"
build_arch "x86_64" "amd64"

case "$(uname -m)" in
  x86_64) create_app_bundle "$ROOT_DIR/.build/x86_64-apple-macosx/release/CodexNotch" "$APP_DIR" ;;
  *) create_app_bundle "$ROOT_DIR/.build/arm64-apple-macosx/release/CodexNotch" "$APP_DIR" ;;
esac

rm -rf "$DMG_STAGE_DIR" "$PACKAGE_STAGE_DIR" "$ICON_BUILD_DIR"
echo "Built $APP_DIR"
