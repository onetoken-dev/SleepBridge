#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
BIN="$ROOT/.build/tests"
mkdir -p "$BIN"
COMMON=(-swift-version 5 -target "$(uname -m)-apple-macos14.0")
xcrun swiftc "${COMMON[@]}" Sources/Shared/{Shared,Control,Spawn}.swift Sources/Helper/{CommandRunner,ScheduledWake,PowerMonitor,Helper}.swift -o "$BIN/Helper" -framework IOKit -framework SystemConfiguration
"$BIN/Helper" --self-test
xcrun swiftc "${COMMON[@]}" Sources/Shared/{Shared,Control}.swift Tests/ControlTests.swift -o "$BIN/ControlTests" -framework IOKit -framework SystemConfiguration
"$BIN/ControlTests"
xcrun swiftc "${COMMON[@]}" Sources/Shared/Shared.swift Sources/History/History.swift Tests/HistoryTests.swift -o "$BIN/HistoryTests" -framework IOKit -framework SystemConfiguration
"$BIN/HistoryTests"
xcrun swiftc "${COMMON[@]}" Sources/Shared/Shared.swift Sources/Helper/CommandRunner.swift Tests/CommandRunnerTests.swift -o "$BIN/CommandRunnerTests" -framework IOKit -framework SystemConfiguration
"$BIN/CommandRunnerTests"
xcrun swiftc "${COMMON[@]}" Sources/Helper/PowerMonitor.swift Tests/PowerMonitorTests.swift -o "$BIN/PowerMonitorTests" -framework IOKit -framework SystemConfiguration
"$BIN/PowerMonitorTests"
xcrun swiftc "${COMMON[@]}" -D SLEEPBRIDGE_TESTING Sources/Shared/{Shared,Control,Spawn}.swift Sources/Helper/{CommandRunner,ScheduledWake,PowerMonitor,Helper}.swift Tests/HelperRegressionTests.swift -o "$BIN/HelperRegressionTests" -framework IOKit -framework SystemConfiguration
TEST_DIR="$(mktemp -d /tmp/sleepbridge-tests-XXXXXXXX)"
trap 'rm -rf "$TEST_DIR"' EXIT
"$BIN/HelperRegressionTests" "$TEST_DIR"
test -f "$TEST_DIR/passed.txt"
printf 'All automated tests passed; no production power settings were changed.\n'
