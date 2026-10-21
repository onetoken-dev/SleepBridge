import Foundation
import IOKit.ps

struct BatteryPoint: Codable, Identifiable {
    var date: Date
    var percent: Double
    var source: String
    var origin: String
    var id: String { "\(date.timeIntervalSince1970)-\(origin)" }
}
struct PowerEvent {
    var date: Date
    var domain: String
    var text: String
    var battery: Double?
    var source: String
}
enum PowerState: String, Codable, CaseIterable {
    case awake = "唤醒"
    case ram = "RAM 睡眠"
    case disk = "磁盘休眠"
    case unknown = "未确认睡眠"
    var lane: String { rawValue }
}
struct PowerInterval: Identifiable {
    var start: Date
    var end: Date
    var state: PowerState
    var startBattery: Double?
    var endBattery: Double?
    var source: String
    var evidence: String
    var inferred = false
    var ongoing = false
    var id: String { "\(start.timeIntervalSince1970)-\(state.rawValue)" }
    var duration: TimeInterval { max(0, end.timeIntervalSince(start)) }
    var discharge: Double? {
        guard source == "电池", let a = startBattery, let b = endBattery, b <= a else { return nil }
        return a - b
    }
    func clipped(to range: ClosedRange<Date>) -> PowerInterval? {
        guard end > range.lowerBound, start < range.upperBound else { return nil }
        var copy = self
        copy.start = max(start, range.lowerBound); copy.end = min(end, range.upperBound)
        if copy.start != start { copy.startBattery = nil }
        if copy.end != end { copy.endBattery = nil }
        return copy
    }
}
struct HistoryArchive: Codable {
    var version = 1
    var logLines: [String] = []
    var samples: [BatteryPoint] = []
    var serviceLines: [String]?
}
struct HistoryResult {
    var intervals: [PowerInterval]
    var points: [BatteryPoint]
    var earliest: Date?
    var warning: String
}
func historyFormatter() -> DateFormatter {
    let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX");
    f.dateFormat = "yyyy-MM-dd HH:mm:ss Z"; return f
}
func captureBattery(_ now: Date = Date()) -> BatteryPoint? {
    guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
        let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
    else { return nil }
    for source in list {
        guard
            let d = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue()
                as? [String: Any],
            let capacity = d[kIOPSCurrentCapacityKey] as? NSNumber,
            let maximum = d[kIOPSMaxCapacityKey] as? NSNumber, maximum.doubleValue > 0
        else { continue }
        let state = (d[kIOPSPowerSourceStateKey] as? String) == kIOPSBatteryPowerValue ? "电池" : "电源"
        return BatteryPoint(
            date: now, percent: min(100, max(0, capacity.doubleValue / maximum.doubleValue * 100)),
            source: state, origin: "实时采样")
    }
    return nil
}
func parsePowerEvents(_ lines: [String]) -> [PowerEvent] {
    let regex = try! NSRegularExpression(
        pattern:
            #"^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2} [+-]\d{4})\s+(Sleep|Wake|DarkWake|HibernateStats|Shutdown|Start)\s+(.*)$"#
    )
    let charge = try! NSRegularExpression(pattern: #"Charge:\s*(\d+)%"#)
    let f = historyFormatter()
    return Array(Set(lines)).compactMap { line -> PowerEvent? in
        let n = line as NSString
        guard let m = regex.firstMatch(in: line, range: NSRange(location: 0, length: n.length)),
            let date = f.date(from: n.substring(with: m.range(at: 1)))
        else { return nil }
        let text = n.substring(with: m.range(at: 3))
        let domain = n.substring(with: m.range(at: 2))
        if domain == "Sleep" && !text.hasPrefix("Entering Sleep") { return nil }
        if domain == "Wake" && !text.hasPrefix("Wake from")
            && !text.hasPrefix("DarkWake to FullWake")
        {
            return nil
        }
        if domain == "DarkWake" && !text.hasPrefix("DarkWake from") { return nil }
        var battery: Double?
        if let match = charge.firstMatch(
            in: text, range: NSRange(location: 0, length: (text as NSString).length))
        {
            battery = Double((text as NSString).substring(with: match.range(at: 1)))
        }
        return PowerEvent(
            date: date, domain: n.substring(with: m.range(at: 2)), text: text, battery: battery,
            source: text.range(of: "Using Batt", options: .caseInsensitive) != nil
                ? "电池" : text.range(of: "Using AC", options: .caseInsensitive) != nil ? "电源" : "未知")
    }.sorted { a, b in a.date == b.date ? a.domain < b.domain : a.date < b.date }
}
func buildHistory(events: [PowerEvent], samples: [BatteryPoint], now: Date, requests: [Date] = [])
    -> HistoryResult
{
    let stats = events.filter { $0.domain == "HibernateStats" }
    let transitions = events.filter {
        ["Sleep", "Wake", "DarkWake", "Shutdown", "Start"].contains($0.domain)
    }
    var rows: [PowerInterval] = []
    var stateStart: PowerEvent?
    var sleeping = false
    for event in transitions where event.date <= now {
        if event.domain == "Sleep" {
            guard event.text.contains("Entering Sleep") else { continue }
            if let prior = stateStart, !sleeping, event.date > prior.date {
                rows.append(
                    PowerInterval(
                        start: prior.date, end: event.date, state: .awake,
                        startBattery: prior.battery, endBattery: event.battery,
                        source: prior.source == event.source ? event.source : "供电变化",
                        evidence: prior.domain == "DarkWake" ? "系统后台唤醒 → 睡眠；包括维护活动" : "系统唤醒 → 睡眠"))
            }
            // Duplicate sleep records must not erase the beginning of a pending sleep interval.
            if !sleeping { stateStart = event; sleeping = true }
        } else if event.domain == "Wake" || event.domain == "DarkWake" {
            if let prior = stateStart, sleeping, event.date > prior.date {
                let stat = stats.first { abs($0.date.timeIntervalSince(event.date)) <= 3 }
                let fromDisk = event.text.contains("from Hibernate")
                let ramMode =
                    stat?.text.range(of: #"hibmode=3(?:\s|$)"#, options: .regularExpression) != nil
                let ramWake =
                    event.text.contains("from Deep Idle")
                    || event.text.contains("from Normal Sleep") || event.text.contains("from Sleep")
                let state: PowerState = fromDisk ? .disk : (ramMode && ramWake ? .ram : .unknown)
                let controlled =
                    fromDisk
                    ? requests.last { $0 <= prior.date && prior.date.timeIntervalSince($0) < 90 }
                    : nil
                var evidence =
                    fromDisk
                    ? "系统确认从磁盘恢复；此前整个睡眠段以浅色归类，RAM→磁盘的确切时刻未记录"
                    : state == .ram
                        ? "Wake from Deep Idle/Sleep ＋ hibmode=3，推断为 RAM 睡眠段"
                        : "系统确认睡眠，但缺少足够证据区分 RAM／磁盘"
                if let request = controlled {
                    evidence =
                        "工具 \(request.formatted(date: .omitted, time: .standard)) 发起模式 25；系统 \(prior.date.formatted(date: .omitted, time: .standard)) 进入睡眠；唤醒确认从磁盘恢复。边界为系统睡眠事件，不代表 SSD 写入完成时刻。"
                }
                rows.append(
                    PowerInterval(
                        start: prior.date, end: event.date, state: state,
                        startBattery: prior.battery, endBattery: event.battery,
                        source: prior.source == event.source ? event.source : "供电变化",
                        evidence: evidence,
                        inferred: state == .ram || (state == .disk && controlled == nil)))
            }
            stateStart = event; sleeping = false
        } else {
            // Never turn an unobserved shutdown/reboot gap into awake or sleep time.
            stateStart = nil; sleeping = false
        }
    }
    if let prior = stateStart, prior.date < now {
        let latest = samples.last {
            $0.date >= prior.date && $0.date <= now && now.timeIntervalSince($0.date) < 120
        }
        rows.append(
            PowerInterval(
                start: prior.date, end: now, state: sleeping ? .unknown : .awake,
                startBattery: prior.battery, endBattery: latest?.percent,
                source: latest.map { $0.source == prior.source ? prior.source : "供电变化" }
                    ?? prior.source,
                evidence: sleeping ? "睡眠尚未结束，暂不能确认最终恢复方式" : "最近系统唤醒至当前；GUI 每分钟记录电量", ongoing: true))
    }
    var points = samples
    points += events.compactMap { event in
        event.battery.map {
            BatteryPoint(date: event.date, percent: $0, source: event.source, origin: "系统事件")
        }
    }
    points.sort { $0.date < $1.date }
    // A source change inside an interval means its net change is not pure discharge.
    for index in rows.indices {
        let sources = Set(
            points.filter { $0.date >= rows[index].start && $0.date <= rows[index].end }.map(
                \.source
            ).filter { $0 != "未知" })
        if sources.count > 1 { rows[index].source = "供电变化" }
    }
    return HistoryResult(
        intervals: rows, points: points, earliest: events.first?.date ?? samples.first?.date,
        warning: events.isEmpty ? "系统历史暂不可用，仅显示本次电量采样。" : "")
}
func historyPath() throws -> URL {
    let root = try FileManager.default.url(
        for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
    ).appendingPathComponent("SleepBridgeHistory", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root.appendingPathComponent("history.json")
}
func updateHistoryArchive(now: Date = Date()) -> HistoryResult {
    do {
        let path = try historyPath()
        var archive =
            (try? JSONDecoder().decode(HistoryArchive.self, from: Data(contentsOf: path)))
            ?? HistoryArchive()
        let result = run("/usr/bin/pmset", ["-g", "log"], timeout: 20)
        let lines = result.output.components(separatedBy: .newlines).filter {
            $0.range(
                of:
                    #"^\d{4}-\d{2}-\d{2} .*\s(Sleep|Wake|DarkWake|HibernateStats|Shutdown|Start)\s"#,
                options: .regularExpression) != nil
        }
        let parsed = parsePowerEvents(archive.logLines + lines)
        let serviceText = (try? String(contentsOfFile: logPath, encoding: .utf8)) ?? ""
        archive.serviceLines = Array(
            Set(
                (archive.serviceLines ?? [])
                    + serviceText.components(separatedBy: .newlines).filter {
                        $0.contains("设置 hibernatemode 25")
                    })
        ).sorted()
        let iso = ISO8601DateFormatter()
        let requests = (archive.serviceLines ?? []).compactMap {
            iso.date(from: String($0.prefix(20)))
        }.sorted()
        let cutoff = now.addingTimeInterval(-90 * 86400)
        let f = historyFormatter()
        archive.logLines = parsed.filter { $0.date >= cutoff }.map {
            "\(f.string(from: $0.date)) \($0.domain) \($0.text)"
        }
        archive.samples = archive.samples.filter { $0.date >= cutoff }
        if let point = captureBattery(now),
            archive.samples.last.map({ now.timeIntervalSince($0.date) >= 45 }) ?? true
        {
            archive.samples.append(point)
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(archive).write(to: path, options: .atomic)
        var built = buildHistory(
            events: parsed.filter { $0.date >= cutoff }, samples: archive.samples, now: now,
            requests: requests)
        if result.code != 0 { built.warning = "系统历史读取失败，显示已保存的记录；" + result.output.prefix(150) }
        return built
    } catch {
        return HistoryResult(
            intervals: [], points: [], earliest: nil,
            warning: "统计保存失败：" + error.localizedDescription)
    }
}
func formatDuration(_ seconds: TimeInterval) -> String {
    let minutes = max(0, Int(seconds) / 60)
    return minutes >= 60 ? "\(minutes / 60) 小时 \(minutes % 60) 分" : "\(minutes) 分钟"
}
func percentLabel(_ value: Double?) -> String { value.map { String(format: "%.0f%%", $0) } ?? "—" }
