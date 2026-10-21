#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
DEST="${1:-$ROOT/build}"
mkdir -p "$DEST"
DEST="$(cd "$DEST" && pwd)"
APP="$DEST/SleepBridge.app"
SLEEPBRIDGE_ARCH="${SLEEPBRIDGE_ARCH:-$(uname -m)}"
COMMON=(-swift-version 5 -target "${SLEEPBRIDGE_ARCH}-apple-macos14.0" -O)
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$DEST/assets"
xcrun swiftc "${COMMON[@]}" Sources/Shared/{Shared,Control,Spawn}.swift Sources/Helper/{CommandRunner,ScheduledWake,Helper}.swift -o "$APP/Contents/Resources/SleepBridgeHelper" -framework IOKit
xcrun swiftc "${COMMON[@]}" Sources/Shared/{Shared,Control}.swift Sources/History/History.swift Sources/App/{HistoryView,App}.swift -o "$APP/Contents/MacOS/SleepBridge" -framework SwiftUI -framework AppKit -framework IOKit -framework Charts
xcrun swift Scripts/GenerateIcon.swift "$DEST/assets/SleepBridge.iconset"
iconutil -c icns "$DEST/assets/SleepBridge.iconset" -o "$APP/Contents/Resources/SleepBridge.icns"
cp Resources/Info.plist "$APP/Contents/"
cp Resources/local.sleepbridge.helper.plist LICENSE "$APP/Contents/Resources/"
plutil -lint "$APP/Contents/Info.plist" "$APP/Contents/Resources/local.sleepbridge.helper.plist"
codesign --force --sign - "$APP/Contents/Resources/SleepBridgeHelper"
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"
printf 'Built: %s\n' "$APP"
