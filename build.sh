#!/bin/bash
# Builds "FSAPI Radio Controller.app" with plain swiftc (Xcode command line tools are enough),
# installs it to ~/Applications and launches it. Use --no-install to only build.
set -e
cd "$(dirname "$0")"

APP_NAME="FSAPI Radio Controller"
EXECUTABLE="FSAPIRadioController"
BUNDLE_ID="io.github.pandawidkur.fsapi-radio-controller"
VERSION="2.0"

APP_DIR="build/$APP_NAME.app"
MACOS_DIR="$APP_DIR/Contents/MacOS"
RESOURCES_DIR="$APP_DIR/Contents/Resources"

echo "=== Building $APP_NAME $VERSION ==="
rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

SDK_PATH=$(xcrun --show-sdk-path)
CACHE_DIR="${TMPDIR:-/tmp}/clang-module-cache"
mkdir -p "$CACHE_DIR"

ARCH=$(uname -m)
swiftc -O \
  -sdk "$SDK_PATH" \
  -target "$ARCH-apple-macosx12.0" \
  -module-cache-path "$CACHE_DIR" \
  Sources/*.swift \
  Sources/Guides/*.swift \
  -o "$MACOS_DIR/$EXECUTABLE"

# Translations (en is the source language, pl translated).
cp -R Resources/*.lproj "$RESOURCES_DIR/"

cat <<PLIST > "$APP_DIR/Contents/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>$EXECUTABLE</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>
    <string>$APP_NAME</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>$VERSION</string>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleLocalizations</key>
    <array><string>en</string><string>pl</string></array>
    <key>LSMinimumSystemVersion</key>
    <string>12.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSLocalNetworkUsageDescription</key>
    <string>Finds and controls your internet radio on the local network.</string>
</dict>
</plist>
PLIST

# Ad-hoc signature so macOS keeps permissions (local network) between launches.
codesign --force --deep -s - "$APP_DIR" >/dev/null 2>&1 || true
echo "Built: $APP_DIR"

[ "$1" = "--no-install" ] && exit 0

TARGET="$HOME/Applications/$APP_NAME.app"
killall "$EXECUTABLE" 2>/dev/null || true
mkdir -p "$HOME/Applications"
rm -rf "$TARGET"
cp -R "$APP_DIR" "$TARGET"
echo "Installed to $TARGET"
open "$TARGET"
