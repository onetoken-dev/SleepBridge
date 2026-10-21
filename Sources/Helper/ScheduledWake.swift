import Foundation
import IOKit.pwr_mgt

func scheduleWake(_ date: Date) -> IOReturn {
    #if SLEEPBRIDGE_TESTING
        TestPowerEffects.scheduled.append(date)
        return kIOReturnSuccess
    #else
        return IOPMSchedulePowerEvent(
            date as CFDate, wakeOwner as CFString, kIOPMAutoWake as CFString)
    #endif
}

func cancelScheduledWake(_ date: Date) -> IOReturn {
    #if SLEEPBRIDGE_TESTING
        return kIOReturnSuccess
    #else
        return IOPMCancelScheduledPowerEvent(
            date as CFDate, wakeOwner as CFString, kIOPMAutoWake as CFString)
    #endif
}
