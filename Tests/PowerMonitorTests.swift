import Darwin
import Foundation
import SystemConfiguration

@main struct PowerMonitorTests {
    static func main() {
        precondition(PowerSnapshot(capabilities: 25, lidClosed: true).dark)
        precondition(!PowerSnapshot(capabilities: nil, lidClosed: true).dark)
        precondition(!PowerSnapshot(capabilities: 0, lidClosed: true).dark)
        precondition(PowerSnapshot(capabilities: 31, lidClosed: false).full)
        // Exercise actual SCDynamicStore callback delivery on a unique test key.
        // Never write powerd's key or issue power commands.
        let key = "State:/SleepBridgeTests/" + UUID().uuidString
        let store = SCDynamicStoreCreate(nil, "SleepBridge monitor test" as CFString, nil, nil)!
        defer { SCDynamicStoreRemoveValue(store, key as CFString) }
        var delivered = false
        let monitor = PowerMonitor(key: key) { delivered = true }
        precondition(monitor.start())
        guard getuid() == 0 else {
            print(
                "PASS: capability bits, unknown-state guard and monitor registration; SKIP callback delivery (configd requires root to write the isolated test key)"
            )
            return
        }
        precondition(SCDynamicStoreSetValue(store, key as CFString, NSNumber(value: 25)))
        let deadline = Date().addingTimeInterval(2)
        while !delivered && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        precondition(delivered, "Power monitor dynamic-store callback was not delivered")
        withExtendedLifetime(monitor) {}
        print(
            "PASS: capability bits, unknown-state guard and real dynamic-store notification delivery"
        )
    }
}
