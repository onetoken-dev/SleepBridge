import Foundation
import IOKit
import SystemConfiguration

/// Apple's powerd publishes this dynamic-store key before sleep, full wake and
/// maintenance wake. These are IOPMCapability bits, NOT the registry's differently
/// defined "System Capabilities" bits. An absent key is unknown, never dark wake.
let powerCapabilitiesKey = "State:/IOKit/SystemPowerCapabilities"
struct PowerSnapshot {
    var capabilities: UInt32?
    var lidClosed: Bool?
    var dark: Bool {
        guard let bits = capabilities else { return false }
        return bits & 1 != 0 && bits & 2 == 0
    }
    var full: Bool {
        guard let bits = capabilities else { return false }
        return bits & 3 == 3
    }
}

func powerSnapshot() -> PowerSnapshot {
    #if SLEEPBRIDGE_TESTING
        return TestPowerEffects.power
    #else
        let bits = (SCDynamicStoreCopyValue(nil, powerCapabilitiesKey as CFString) as? NSNumber)?
            .uint32Value
        let root = IOServiceGetMatchingService(
            kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard root != 0 else { return PowerSnapshot(capabilities: bits) }
        defer { IOObjectRelease(root) }
        let lid =
            IORegistryEntryCreateCFProperty(
                root, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue()
            as? NSNumber
        return PowerSnapshot(capabilities: bits, lidClosed: lid?.boolValue)
    #endif
}

/// Dynamic-store notifications do not require sleep acknowledgments or private
/// IOPMConnection entry points. Keep the legacy notifier for full sleep/wake ACKs.
final class PowerMonitor {
    private var store: SCDynamicStore?
    private var source: CFRunLoopSource?
    private let key: String
    let changed: () -> Void
    init(key: String = powerCapabilitiesKey, changed: @escaping () -> Void) {
        self.key = key; self.changed = changed
    }
    func start() -> Bool {
        var context = SCDynamicStoreContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil)
        store = SCDynamicStoreCreate(
            kCFAllocatorDefault, "SleepBridge power capabilities" as CFString,
            { _, _, info in
                guard let info else { return }
                Unmanaged<PowerMonitor>.fromOpaque(info).takeUnretainedValue().changed()
            }, &context)
        guard let store,
            SCDynamicStoreSetNotificationKeys(store, [key] as CFArray, nil),
            let source = SCDynamicStoreCreateRunLoopSource(kCFAllocatorDefault, store, 0)
        else { return false }
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        return true
    }
    deinit {
        if let source { CFRunLoopSourceInvalidate(source) }
    }
}
