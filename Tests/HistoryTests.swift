import Foundation

@main struct HistoryTests {
    static func main() {
        let lines = [
            "2024-01-01 10:00:00 +0800 Wake Wake from Hibernate Using BATT (Charge:90%)",
            "2024-01-01 10:05:00 +0800 Sleep Entering Sleep state due to 'Clamshell Sleep': Using Batt (Charge:88%)",
            "2024-01-01 10:15:00 +0800 Wake Wake from Deep Idle Using BATT (Charge:87%)",
            "2024-01-01 10:15:00 +0800 HibernateStats hibmode=3 standbydelaylow=0",
            "2024-01-01 10:16:00 +0800 Sleep Entering Sleep state due to 'Software Sleep pid=123': Using Batt (Charge:87%)",
            "2024-01-01 12:00:00 +0800 Wake Wake from Hibernate Using BATT (Charge:84%)",
            "2024-01-01 12:00:00 +0800 HibernateStats hibmode=25 standbydelaylow=0",
            "2024-01-01 12:10:00 +0800 Sleep Entering Sleep state due to 'Idle Sleep': Using AC (Charge:85%)",
            "2024-01-01 12:20:00 +0800 Wake Wake from Deep Idle Using AC (Charge:88%)",
            "2024-01-01 12:20:00 +0800 HibernateStats hibmode=3",
            "2024-01-01 12:30:00 +0800 Shutdown Shutting down",
            "2024-01-01 13:00:00 +0800 Wake Wake from Normal Sleep Using BATT (Charge:88%)",
        ]
        let f = historyFormatter();
        func date(_ time: String) -> Date { f.date(from: "2024-01-01 " + time + " +0800")! }
        let events = parsePowerEvents(
            (lines + [
                lines[1], "2024-01-01 10:05:02 +0800 Wake Requests request=UserWake",
                "2024-01-01 10:05:03 +0800 Kernel Client Acks Sleep notifications",
            ]).reversed())
        precondition(events.count == lines.count, "Deduplicate and sort imported events")
        let result = buildHistory(
            events: events, samples: [], now: date("13:05:00"), requests: [date("10:15:55")])
        let ram = result.intervals.first { $0.state == .ram }!
        precondition(ram.duration == 600 && ram.discharge == 1)
        let disk = result.intervals.first { $0.state == .disk }!
        precondition(disk.duration == 6240 && disk.discharge == 3 && !disk.inferred)
        let ambiguous = buildHistory(events: events, samples: [], now: date("13:05:00")).intervals
            .first { $0.state == .disk }!
        precondition(
            ambiguous.inferred, "Historic disk recovery cannot invent a transition boundary")
        let clipped = disk.clipped(to: date("11:00:00")...date("12:10:00"))!
        precondition(
            clipped.duration == 3600 && clipped.startBattery == nil && clipped.discharge == nil,
            "Never prorate battery data at range boundaries")
        precondition(
            !result.intervals.contains { $0.start < date("12:30:00") && $0.end > date("13:00:00") },
            "No invented reboot interval")
        precondition(
            result.intervals.filter { $0.source == "电源" }.allSatisfy { $0.discharge == nil })
        let acPoint = BatteryPoint(
            date: date("10:10:00"), percent: 88, source: "电源", origin: "实时采样")
        let changed = buildHistory(
            events: events, samples: [acPoint], now: date("13:05:00"), requests: []
        ).intervals.first { $0.state == .ram }!
        precondition(changed.source == "供电变化" && changed.discharge == nil)
        let unknown = buildHistory(
            events: parsePowerEvents([lines[1]]), samples: [], now: date("10:07:00"))
        precondition(unknown.intervals.first?.state == .unknown)
        print(
            "PASS: 9 history scenarios: deduplication/order, RAM pairing, controlled disk boundary, historical ambiguity, clipped battery endpoints, reboot gaps, charging exclusion, mixed power exclusion, unfinished sleep."
        )
    }
}
