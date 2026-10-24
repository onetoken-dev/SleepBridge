import Darwin
import Foundation

// These hooks are referenced only by code compiled with SLEEPBRIDGE_TESTING.
// The fake sleep command is /bin/sleep, never pmset.
enum TestPowerEffects {
    static var commands: [[String]] = []
    static var acknowledgments: [UInt32] = []
    static var scheduled: [Date] = []
    static var power = PowerSnapshot(capabilities: 31, lidClosed: false)
    static var battery = true
    static var sleepRequests = 0
    static func readWakeLog() -> CommandResult {
        runHelperCommand("/bin/sleep", ["1.4"], timeout: 3)
    }
    static func spawnSleepRequest() throws -> pid_t {
        sleepRequests += 1
        return try spawnDetached("/bin/sleep", arguments: ["2"])
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
        let automaticProbes = ProbeResults()

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
            // This used to deadlock when a timer reentered reload() under an existing flock.
            locked {
                let started = Date()
                precondition(!serviceLocked {})
                precondition(Date().timeIntervalSince(started) < 0.1)
            }
            supervisor.config.minutes = 1
            try! writeJSON(supervisor.config, to: configPath)
            supervisor.wakeCheckDelay = 0.05
            supervisor.status.sleepStart = Date().addingTimeInterval(-70)
            supervisor.didWake()
            precondition(supervisor.status.phase == "唤醒后检查中")
            Thread.detachNewThread {
                Thread.sleep(forTimeInterval: 0.2)
                let reply = connectControl("ping")
                automaticProbes.set(reply.code == 0 && reply.output == helperGreeting)
            }
        }
        Timer.scheduledTimer(withTimeInterval: 7.2, repeats: false) { _ in
            precondition(
                automaticProbes.get(), "IPC must remain responsive during delayed wake-log reads")
            precondition(supervisor.status.phase == "策略已就绪")
            precondition(supervisor.status.sleepStart == nil)
            precondition(
                TestPowerEffects.commands.filter { $0.last == "25" }.count == 1,
                "Unknown wake must not trigger an automatic sleep")
            supervisor.status.sleepStart = Date().addingTimeInterval(-70)
            supervisor.didWake()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                supervisor.handlePowerMessage(kIOMessageSystemWillSleep, argument: nil)
            }
        }
        Timer.scheduledTimer(withTimeInterval: 10, repeats: false) { _ in
            precondition(
                supervisor.status.phase == "内存睡眠计时中",
                "A stale log result must not overwrite a new sleep cycle")
            precondition(supervisor.status.scheduledWake != nil)
            checkDarkWake(supervisor)
            try! Data("PASS\n".utf8).write(to: URL(fileURLWithPath: directory + "/passed.txt"))
            print(
                "PASS: manual and delayed wake paths, responsive IPC, busy locks, ACKs, stale-result cancellation; dark-only wake without full-wake notification, scope/lid/unknown/early guards, no forced sleep, idempotence and mode restore"
            )
            CFRunLoopStop(CFRunLoopGetMain())
        }
        Timer.scheduledTimer(withTimeInterval: 15, repeats: false) { _ in
            fputs("FAIL: regression test timed out\n", stderr)
            exit(1)
        }
        supervisor.start()
    }

    static func checkDarkWake(_ supervisor: Supervisor) {
        let requests = TestPowerEffects.sleepRequests
        let commands = TestPowerEffects.commands.count
        supervisor.config.minutes = 1
        supervisor.config.scope = "battery"
        try! writeJSON(supervisor.config, to: configPath)
        supervisor.status.sleepStart = Date().addingTimeInterval(-30)
        TestPowerEffects.power = PowerSnapshot(capabilities: 25, lidClosed: true)
        supervisor.pollPowerState()
        precondition(TestPowerEffects.commands.count == commands, "Early dark wake must wait")
        supervisor.status.sleepStart = Date().addingTimeInterval(-70)
        TestPowerEffects.power = PowerSnapshot(capabilities: nil, lidClosed: true)
        supervisor.pollPowerState()
        TestPowerEffects.power = PowerSnapshot(capabilities: 25, lidClosed: nil)
        supervisor.pollPowerState()
        TestPowerEffects.power = PowerSnapshot(capabilities: 25, lidClosed: false)
        supervisor.pollPowerState()
        TestPowerEffects.power = PowerSnapshot(capabilities: 25, lidClosed: true)
        TestPowerEffects.battery = false
        supervisor.pollPowerState()
        precondition(TestPowerEffects.commands.count == commands, "Unknown/open-lid/AC must skip")
        TestPowerEffects.battery = true
        locked { supervisor.pollPowerState() }
        precondition(!supervisor.status.deepCycle, "A busy lock must leave the cycle for retry")

        // Crucially, NO kIOMessageSystemHasPoweredOn is delivered. The production
        // dynamic-store callback/timer entry must work inside an eight-second wake.
        let start = Date()
        supervisor.pollPowerState()
        precondition(Date().timeIntervalSince(start) < 1)
        precondition(supervisor.status.deepCycle)
        precondition(supervisor.status.sleepStart == nil)
        precondition(TestPowerEffects.commands.last == ["-b", "hibernatemode", "25"])
        precondition(
            TestPowerEffects.sleepRequests == requests, "Dark wake must not force sleepnow")
        supervisor.pollPowerState()
        precondition(
            TestPowerEffects.commands.count == commands + 1, "Repeated dark ticks are idempotent")
        TestPowerEffects.power = PowerSnapshot(capabilities: 0, lidClosed: true)
        supervisor.pollPowerState()
        precondition(supervisor.status.deepCycle, "Natural return to sleep must retain mode 25")
        precondition(!supervisor.darkWakeRequested)
        TestPowerEffects.power = PowerSnapshot(capabilities: 31, lidClosed: false)
        locked { supervisor.pollPowerState() }
        precondition(supervisor.status.deepCycle, "A busy wake lock must retry restoration")
        supervisor.pollPowerState()
        precondition(!supervisor.status.deepCycle)
        precondition(TestPowerEffects.commands.last == ["-b", "hibernatemode", "3"])
        precondition(TestPowerEffects.sleepRequests == requests)
    }
}

final class ProbeResults: @unchecked Sendable {
    private let lock = NSLock()
    private var responded = false
    func set(_ value: Bool) { lock.lock(); defer { lock.unlock() }; responded = value }
    func get() -> Bool { lock.lock(); defer { lock.unlock() }; return responded }
}
