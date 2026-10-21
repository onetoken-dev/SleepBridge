import Foundation

@main struct CommandRunnerTests {
    static func main() {
        let text = runHelperCommand("/bin/sh", ["-c", "printf out; printf err >&2; exit 7"])
        precondition(text.code == 7 && text.output.contains("out") && text.output.contains("err"))
        precondition(runHelperCommand("/does-not-exist", []).code == -1)
        let started = Date()
        let timed = runHelperCommand("/bin/sleep", ["2"], timeout: 0.08)
        precondition(timed.code == 124 && Date().timeIntervalSince(started) < 1)
        var reentered = false
        let timer = Timer.scheduledTimer(withTimeInterval: 0.01, repeats: false) { _ in
            reentered = true
        }
        precondition(runHelperCommand("/bin/sleep", ["0.08"]).code == 0)
        precondition(!reentered, "Waiting for a helper child must not pump the caller's run loop")
        RunLoop.current.run(until: Date().addingTimeInterval(0.03))
        precondition(reentered); timer.invalidate()
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        let start = formatter.date(from: "2024-01-01 10:00:00 +0800")!
        let old = "2024-01-01 09:59:59 +0800 Wake Wake from Deep Idle : due to lid Using BATT"
        let dark =
            "2024-01-01 10:00:10 +0800 DarkWake DarkWake from Deep Idle : due to rtc/Maintenance Using BATT"
        let user =
            "2024-01-01 10:00:11 +0800 Wake Wake from Deep Idle : due to smc.sysState.Wake lid SMC.Outbox/HID Activity Using BATT"
        precondition(latestWakeEvidence(old, notBefore: start) == nil)
        precondition(
            latestWakeEvidence(old + "\n" + dark, notBefore: start)?.userInitiated == false)
        precondition(
            latestWakeEvidence(dark + "\n" + user, notBefore: start)?.userInitiated == true)
        precondition(
            latestWakeEvidence("2024-01-01 10:00:10 +0800 Wake Requests rtc", notBefore: start)
                == nil)
        print(
            "PASS: bounded child capture/timeout, no run-loop reentry, fresh full/dark wake evidence, user wake and stale log rejection"
        )
    }
}
