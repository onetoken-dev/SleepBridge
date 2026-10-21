import Darwin
import Foundation

// These hooks are referenced only by code compiled with SLEEPBRIDGE_TESTING.
// The fake sleep command is /bin/sleep, never pmset.
enum TestPowerEffects {
    static var commands: [[String]] = []
    static var acknowledgments: [UInt32] = []
    static var scheduled: [Date] = []
    static func spawnSleepRequest() throws -> pid_t {
        try spawnDetached("/bin/sleep", arguments: ["2"])
    }
}

@main struct HelperRegressionTests {
    static func main() throws {
        let directory = supportPath
        let config = Configuration(
            enabled: true, minutes: 60, scope: "all", authorizedUID: getuid())
        try writeJSON(config, to: configPath)
        let supervisor = Supervisor()
        let probes = ProbeResults()

        Timer.scheduledTimer(withTimeInterval: 0.1, repeats: false) { _ in
            let start = Date()
            locked { supervisor.beginHibernate() }
            precondition(
                Date().timeIntervalSince(start) < 1, "Sleep requests must not wait for completion")
            // Exercise the SAME notification router used by IOKit in production.
            supervisor.handlePowerMessage(kIOMessageCanSystemSleep, argument: nil)
            supervisor.handlePowerMessage(kIOMessageSystemWillSleep, argument: nil)
            precondition(TestPowerEffects.acknowledgments.count == 2)
            precondition(supervisor.status.deepCycle)
            Thread.detachNewThread {
                let reply = connectControl("ping")
                probes.set(reply.code == 0 && reply.output == helperGreeting)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.3) {
                supervisor.handlePowerMessage(kIOMessageSystemHasPoweredOn, argument: nil)
            }
        }
        Timer.scheduledTimer(withTimeInterval: 4.5, repeats: false) { _ in
            precondition(probes.get(), "IPC must respond while a sleep request is alive")
            precondition(!supervisor.status.deepCycle, "Wake must restore the next RAM cycle")
            precondition(TestPowerEffects.commands.contains(["-a", "hibernatemode", "25"]))
            precondition(TestPowerEffects.commands.last == ["-a", "hibernatemode", "3"])
            precondition(supervisor.sleepPID == 0, "Detached children must be reaped")
            precondition(
                TestPowerEffects.scheduled.isEmpty,
                "No second wake should be scheduled during disk sleep")
            try! Data("PASS\n".utf8).write(to: URL(fileURLWithPath: directory + "/passed.txt"))
            print(
                "PASS: nonblocking sleep request, notification acknowledgments, IPC response, wake restoration, child reaping"
            )
            CFRunLoopStop(CFRunLoopGetMain())
        }
        Timer.scheduledTimer(withTimeInterval: 10, repeats: false) { _ in
            fputs("FAIL: regression test timed out\n", stderr)
            exit(1)
        }
        supervisor.start()
    }
}

final class ProbeResults: @unchecked Sendable {
    private let lock = NSLock()
    private var responded = false
    func set(_ value: Bool) { lock.lock(); defer { lock.unlock() }; responded = value }
    func get() -> Bool { lock.lock(); defer { lock.unlock() }; return responded }
}
