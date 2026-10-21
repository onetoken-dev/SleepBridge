#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
BIN="$ROOT/.build/tests"
mkdir -p "$BIN"
COMMON=(-swift-version 5 -target "$(uname -m)-apple-macos14.0")
xcrun swiftc "${COMMON[@]}" Sources/Shared/{Shared,Control,Spawn}.swift Sources/Helper/{ScheduledWake,Helper}.swift -o "$BIN/Helper" -framework IOKit
"$BIN/Helper" --self-test
xcrun swiftc "${COMMON[@]}" Sources/Shared/{Shared,Control}.swift Tests/ControlTests.swift -o "$BIN/ControlTests" -framework IOKit
"$BIN/ControlTests"
xcrun swiftc "${COMMON[@]}" Sources/Shared/Shared.swift Sources/History/History.swift Tests/HistoryTests.swift -o "$BIN/HistoryTests" -framework IOKit
"$BIN/HistoryTests"
xcrun swiftc "${COMMON[@]}" -D SLEEPBRIDGE_TESTING Sources/Shared/{Shared,Control,Spawn}.swift Sources/Helper/{ScheduledWake,Helper}.swift Tests/HelperRegressionTests.swift -o "$BIN/HelperRegressionTests" -framework IOKit
TEST_DIR="$(mktemp -d /tmp/sleepbridge-tests-XXXXXXXX)"
trap 'rm -rf "$TEST_DIR"' EXIT
"$BIN/HelperRegressionTests" "$TEST_DIR"
test -f "$TEST_DIR/passed.txt"
printf 'All automated tests passed; no production power settings were changed.\n'
