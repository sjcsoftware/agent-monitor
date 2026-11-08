#!/usr/bin/env bash
# Builds AgentMonitor.app (universal, release) and the release zip.
#   scripts/build.sh   -> dist/AgentMonitor.app, dist/AgentMonitor.zip (+ .sha256)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

VERSION="$(cat VERSION 2>/dev/null || echo 0.1.0)"
BUILD="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
DIST="$ROOT/dist"
APP="$DIST/AgentMonitor.app"

echo "==> Building Agent Monitor $VERSION ($BUILD)"
STAGE="$DIST/arch"
rm -rf "$STAGE"
for arch in arm64 x86_64; do
  triple="$arch-apple-macosx14.0"
  swift build -c release --triple "$triple" >/dev/null
  out="$(swift build -c release --triple "$triple" --show-bin-path)"
  mkdir -p "$STAGE/$arch"
  cp "$out/AgentMonitor" "$out/agent-monitor-hook" "$STAGE/$arch/"
done

echo "==> Assembling app bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
for exe in AgentMonitor agent-monitor-hook; do
  lipo -create "$STAGE/arm64/$exe" "$STAGE/x86_64/$exe" -output "$APP/Contents/MacOS/$exe"
done
rm -rf "$STAGE"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" Resources/Info.plist > "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
install -m 755 scripts/agent-monitor "$APP/Contents/Resources/agent-monitor"

ICONSET="$DIST/AppIcon.iconset"
rm -rf "$ICONSET"
swift scripts/make-icon.swift "$ICONSET" >/dev/null
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET"

echo "==> Signing (ad-hoc, stable requirement)"
# Pinning the designated requirement to the bundle id keeps macOS privacy grants
# (Automation, Accessibility) across updates; an ad-hoc cdhash would change every build.
codesign --force --sign - -r='designated => identifier "com.sjcsoftware.agent-monitor.hook"' \
  --identifier com.sjcsoftware.agent-monitor.hook "$APP/Contents/MacOS/agent-monitor-hook"
codesign --force --sign - -r='designated => identifier "com.sjcsoftware.agent-monitor"' "$APP"
codesign --verify --strict "$APP"

echo "==> Creating zip"
ZIP="$DIST/AgentMonitor.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
(cd "$DIST" && shasum -a 256 "$(basename "$ZIP")" > "$(basename "$ZIP").sha256")
echo "    $ZIP ($(du -h "$ZIP" | cut -f1 | xargs))"
