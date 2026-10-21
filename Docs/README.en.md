# SleepBridge

SleepBridge is a local SwiftUI utility for macOS sleep policy, sleep/wake inspection, and battery history.

GUI version: **1.4**. Helper protocol: **1.3**. License: **MIT**.

[Repository](https://github.com/onetoken-dev/SleepBridge) · [Experimental releases](https://github.com/onetoken-dev/SleepBridge/releases)

## Build

On macOS with Xcode or Command Line Tools and a Swift 6 toolchain:

```bash
./build.sh
open build/SleepBridge.app
make test
```

The source is compiled in Swift 5 language mode, with a macOS 14.0 deployment target. Builds use the current host architecture and ad-hoc signing. There are no third-party package dependencies. Building never installs the helper or changes power settings.

## Behavior

After explicit administrator authorization in the GUI, a root-owned launchd helper manages the chosen power-source policy. It uses hibernatemode 3 for initial sleep, schedules a wake, checks input activity after waking, and may request mode 25 followed by an asynchronous sleep request. Earlier wakes cancel the cycle. Disabling restores the saved modes.

The timeline shows awake, inferred RAM sleep, disk-related sleep, battery endpoints, and net percentage-point change. Tool-controlled disk sleep boundaries correlate the request with a system sleep event and subsequent disk restoration. Historical disk restoration alone does not establish the precise earlier RAM-to-disk transition time.

## Limits

This is an experimental utility. One manual hibernate/wake/restore cycle was verified on an M1 MacBook Air running macOS 27.0.1. A complete lid-closed timed transition has **not** been verified. A deployment target does not establish hardware or OS compatibility. Scheduled wake may be delayed, ignored, or briefly illuminate the display.

No notarized distribution is provided. Automated tests never issue real power-management commands. The optional `make test-launchd` regression requires a logged-in GUI session and uses isolated fake power effects.

The application has no networking or telemetry. Battery samples collected every minute require the application to remain running; system sleep/wake events can be imported after reopening it. History stays local for 90 days.

See the [main README](../README.md), [architecture](ARCHITECTURE.md), [history semantics](HISTORY.md), [testing](TESTING.md), and [security boundaries](../SECURITY.md) for details. UI text is currently Chinese.
