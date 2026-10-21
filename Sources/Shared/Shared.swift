import Foundation
import IOKit
import IOKit.ps

let serviceID = "local.sleepbridge.helper"
// Test binaries cannot address the installed service or production state directory.
#if SLEEPBRIDGE_TESTING
    let supportPath: String = {
        guard CommandLine.arguments.count == 2,
            CommandLine.arguments[1].hasPrefix("/tmp/sleepbridge-tests-")
        else {
            fatalError("A private /tmp/sleepbridge-tests-* directory is required")
        }
        return CommandLine.arguments[1]
    }()
#else
    let supportPath = "/Library/Application Support/SleepBridge"
#endif
let helperProtocolVersion = "1.3"
let helperGreeting = "OK SleepBridge \(helperProtocolVersion)"
let installedHelper = supportPath + "/SleepBridgeHelper"
let configPath = supportPath + "/config.json"
let statusPath = supportPath + "/status.json"
let logPath = supportPath + "/events.log"
let wakeOwner = "local.sleepbridge.transition"

struct Configuration: Codable {
    var enabled = false
    var minutes = 60
    var scope = "battery"
    var original: [String: Int] = [:]
    var revision = UUID().uuidString
    var request = ""
    var authorizedUID: UInt32?
}
struct ServiceStatus: Codable {
    var phase = "未启用"
    var detail = ""
    var sleepStart: Date?
    var scheduledWake: Date?
    var deepCycle = false
    var updated = Date()
    var pid: Int32 = 0
}
func readJSON<T: Decodable>(_ path: String, as type: T.Type) -> T? {
    guard let data = FileManager.default.contents(atPath: path) else { return nil }
    return try? JSONDecoder().decode(type, from: data)
}
func writeJSON<T: Encodable>(_ value: T, to path: String) throws {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(value).write(to: URL(fileURLWithPath: path), options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path)
}
struct CommandResult { var code: Int32; var output: String }
@discardableResult func run(_ path: String, _ args: [String], timeout: Double? = 15)
    -> CommandResult
{
    let process = Process(), pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: path); process.arguments = args
    process.standardOutput = pipe; process.standardError = pipe
    do {
        try process.run()
        let watchdog = timeout.map { seconds -> DispatchWorkItem in
            let item = DispatchWorkItem { if process.isRunning { process.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds, execute: item)
            return item
        }
        defer { watchdog?.cancel() }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return CommandResult(
            code: process.terminationStatus, output: String(decoding: data, as: UTF8.self))
    } catch { return CommandResult(code: -1, output: error.localizedDescription) }
}
func onBattery() -> Bool {
    guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
        let source = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue()
    else { return false }
    return (source as String) == kIOPSBatteryPowerValue
}
func modes(from text: String) -> [String: Int] {
    var section = "", result: [String: Int] = [:]
    for line in text.components(separatedBy: .newlines) {
        if line.contains("Battery Power:") { section = "battery" }
        if line.contains("AC Power:") { section = "ac" }
        let parts = line.split(whereSeparator: { $0.isWhitespace })
        if parts.first == "hibernatemode", let last = parts.last, let value = Int(last),
            !section.isEmpty
        {
            result[section] = value
        }
    }
    return result
}
func pmDate(_ date: Date) -> String {
    let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = .current;
    f.dateFormat = "MM/dd/yy HH:mm:ss"
    return f.string(from: date)
}
func decision(
    elapsed: TimeInterval, delay: TimeInterval, idle: TimeInterval?, battery: Bool, scope: String
) -> String {
    if scope == "battery" && !battery { return "scope" }
    if elapsed < delay { return "early" }
    guard let idle = idle, idle >= 30 else { return "active" }
    return "hibernate"
}
func idleSeconds() -> Double? {
    let entry = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOHIDSystem"))
    guard entry != 0 else { return nil }; defer { IOObjectRelease(entry) }
    guard
        let value = IORegistryEntryCreateCFProperty(
            entry, "HIDIdleTime" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
            as? NSNumber
    else { return nil }
    return value.doubleValue / 1_000_000_000
}
