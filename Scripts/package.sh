#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
"$ROOT/build.sh"
mkdir -p dist
VERSION="$(plutil -extract CFBundleShortVersionString raw Resources/Info.plist)"
ARCHIVE="dist/SleepBridge-${VERSION}-$(uname -m).zip"
ditto -c -k --sequesterRsrc --keepParent build/SleepBridge.app "$ARCHIVE"
(cd dist && shasum -a 256 "$(basename "$ARCHIVE")" > "$(basename "$ARCHIVE").sha256")
printf 'Packaged: %s\n' "$ARCHIVE"
