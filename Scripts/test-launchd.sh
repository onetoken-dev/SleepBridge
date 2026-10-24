#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
BIN="$ROOT/.build/tests/HelperRegressionTests"
if [[ ! -x "$BIN" ]]; then "$ROOT/Scripts/test.sh"; fi
TEST_DIR="$(mktemp -d /tmp/sleepbridge-tests-XXXXXXXX)"
# launchd must not need access to a checkout under Documents/Desktop. Run the
# isolated test executable from its private temporary directory instead.
cp "$BIN" "$TEST_DIR/HelperRegressionTests"
BIN="$TEST_DIR/HelperRegressionTests"
LABEL="local.sleepbridge.tests.$(uuidgen | tr '[:upper:]' '[:lower:]')"
DOMAIN="gui/$(id -u)"
PLIST="$TEST_DIR/test.plist"
cleanup() { launchctl bootout "$DOMAIN/$LABEL" >/dev/null 2>&1 || true; rm -rf "$TEST_DIR"; }
trap cleanup EXIT
# plutil builds the plist without interpolating paths into XML.
plutil -create xml1 "$PLIST"
plutil -insert Label -string "$LABEL" "$PLIST"
plutil -insert ProgramArguments -json '[]' "$PLIST"
plutil -insert ProgramArguments.0 -string "$BIN" "$PLIST"
plutil -insert ProgramArguments.1 -string "$TEST_DIR" "$PLIST"
plutil -insert RunAtLoad -bool true "$PLIST"
plutil -insert ProcessType -string Background "$PLIST"
plutil -insert StandardOutPath -string "$TEST_DIR/stdout.log" "$PLIST"
plutil -insert StandardErrorPath -string "$TEST_DIR/stderr.log" "$PLIST"
launchctl bootstrap "$DOMAIN" "$PLIST"
for attempt in {1..80}; do
    if [[ -f "$TEST_DIR/passed.txt" ]]; then cat "$TEST_DIR/stdout.log"; printf 'PASS: launchd Background regression\n'; exit 0; fi
    sleep 0.25
done
cat "$TEST_DIR/stdout.log" "$TEST_DIR/stderr.log" >&2 || true
launchctl print "$DOMAIN/$LABEL" >&2 || true
printf 'FAIL: launchd regression did not complete; a logged-in GUI session is required.\n' >&2
exit 1
