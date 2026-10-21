import AppKit
import Charts
import SwiftUI

@MainActor final class HistoryModel: ObservableObject {
    @Published var result = HistoryResult(intervals: [], points: [], earliest: nil, warning: "")
    @Published var loading = false
    @Published var rangeChoice = "24 小时"
    @Published var startDate = Date().addingTimeInterval(-86400)
    @Published var endDate = Date()
    @Published var selected: String?
    @Published var lastUpdate = Date()
    @Published var exportMessage = ""
    private var timer: Timer?
    init() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }
    var range: ClosedRange<Date> {
        let end = rangeChoice == "自定义" ? min(endDate, lastUpdate) : lastUpdate
        let start =
            rangeChoice == "自定义"
            ? min(startDate, end.addingTimeInterval(-1))
            : end.addingTimeInterval(
                rangeChoice == "1 小时"
                    ? -3600
                    : rangeChoice == "7 天"
                        ? -7 * 86400 : rangeChoice == "30 天" ? -30 * 86400 : -86400)
        return start...end
    }
    var invalidRange: Bool { rangeChoice == "自定义" && startDate >= endDate }
    var rows: [PowerInterval] { result.intervals.compactMap { $0.clipped(to: range) } }
    var points: [BatteryPoint] {
        var byTime: [Int: BatteryPoint] = [:]
        // Prefer the system's boundary sample when it shares a second with a live sample.
        for p in result.points where range.contains(p.date) {
            let key = Int(p.date.timeIntervalSince1970);
            if byTime[key] == nil || p.origin == "系统事件" { byTime[key] = p }
        }
        return byTime.values.sorted { $0.date < $1.date }
    }
    func refresh() {
        guard !loading else { return }; loading = true
        Task {
            let fetched = await Task.detached(priority: .utility) { updateHistoryArchive() }.value
            result = fetched; lastUpdate = Date(); loading = false
        }
    }
    func total(_ state: PowerState) -> TimeInterval {
        rows.filter { $0.state == state }.reduce(0) { $0 + $1.duration }
    }
    func drop(_ state: PowerState) -> String {
        let values = rows.filter { $0.state == state }.compactMap(\.discharge)
        return values.isEmpty ? "电量数据不足" : String(format: "净下降 %.0f 个百分点", values.reduce(0, +))
    }
    func export() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "SleepBridge-时间统计.csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        func cell(_ s: String) -> String {
            "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        let f = ISO8601DateFormatter(); f.timeZone = .current
        var lines = ["开始时间,结束时间,状态,时长秒,开始电量%,结束电量%,净下降百分点,供电方式,区间推断,仍在进行,依据"]
        lines += rows.map { row in
            [
                f.string(from: row.start), f.string(from: row.end), row.state.rawValue,
                String(Int(row.duration)), row.startBattery.map { String($0) } ?? "",
                row.endBattery.map { String($0) } ?? "", row.discharge.map { String($0) } ?? "",
                row.source, row.inferred ? "是" : "否", row.ongoing ? "是" : "否", row.evidence,
            ].map(cell).joined(separator: ",")
        }
        do {
            try ("\u{FEFF}" + lines.joined(separator: "\r\n")).write(
                to: url, atomically: true, encoding: .utf8);
            exportMessage = "已导出 \(rows.count) 个区间。"
        } catch { exportMessage = error.localizedDescription }
    }
}
func stateColor(_ state: PowerState) -> Color {
    switch state {
    case .awake: return .orange;
    case .ram: return .teal;
    case .disk: return .indigo;
    case .unknown: return .gray
    }
}
struct BatteryChartPoint: Identifiable {
    var point: BatteryPoint
    var group: Int
    var id: String { point.id }
}
struct HistoryView: View {
    @ObservedObject var history: HistoryModel
    var plotted: [BatteryChartPoint] {
        var group = 0
        let values = history.points
        return values.enumerated().map { index, point in
            if index > 0,
                point.date.timeIntervalSince(values[index - 1].date) > 120
                    || point.source != values[index - 1].source
            {
                group += 1
            }
            return BatteryChartPoint(point: point, group: group)
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Picker("时间范围", selection: $history.rangeChoice) {
                    ForEach(["1 小时", "24 小时", "7 天", "30 天", "自定义"], id: \.self) { Text($0) }
                }.pickerStyle(.segmented).frame(maxWidth: 380)
                Spacer()
                if history.loading { ProgressView().controlSize(.small) }
                Button("刷新统计") { history.refresh() }.disabled(history.loading)
                Button("导出 CSV") { history.export() }.disabled(
                    history.rows.isEmpty || history.invalidRange)
            }
            if history.rangeChoice == "自定义" {
                HStack {
                    DatePicker(
                        "开始", selection: $history.startDate,
                        displayedComponents: [.date, .hourAndMinute]);
                    DatePicker(
                        "结束", selection: $history.endDate,
                        displayedComponents: [.date, .hourAndMinute])
                }
                if history.invalidRange {
                    Text("结束时间需要晚于开始时间。").font(.caption).foregroundStyle(.red)
                }
            }
            if !history.result.warning.isEmpty {
                Text(history.result.warning).font(.callout).foregroundStyle(.orange)
            }
            HStack(alignment: .top, spacing: 12) {
                summary(.awake, title: "唤醒时间")
                summary(.ram, title: "RAM 睡眠区间")
                summary(.disk, title: "磁盘相关区间")
            }
            Panel(title: "状态时间线") {
                if history.rows.isEmpty {
                    ContentUnavailableView(
                        "暂无可用区间", systemImage: "clock.badge.questionmark",
                        description: Text("调整时间范围或等待系统产生睡眠／唤醒记录。未观察到的时间不会补成唤醒状态。"))
                } else {
                    Chart(history.rows) { row in
                        RectangleMark(
                            xStart: .value("开始", row.start), xEnd: .value("结束", row.end),
                            y: .value("状态", row.state.lane), height: .ratio(0.58)
                        )
                        .foregroundStyle(stateColor(row.state).opacity(row.inferred ? 0.45 : 0.86))
                        .annotation(position: .overlay) {
                            if row.duration > history.range.upperBound.timeIntervalSince(
                                history.range.lowerBound) * 0.12
                            {
                                Text(row.inferred ? "推断区间" : row.state.rawValue).font(.caption2)
                                    .foregroundStyle(.white).lineLimit(1)
                            }
                        }
                        .accessibilityLabel(
                            "\(row.state.rawValue)，\(row.start.formatted()) 至 \(row.end.formatted())，\(row.evidence)"
                        )
                    }
                    .chartXScale(domain: history.range)
                    .chartYScale(domain: PowerState.allCases.map(\.lane))
                    .chartXAxis {
                        AxisMarks(values: .automatic(desiredCount: 5)) { value in
                            AxisGridLine(); AxisTick();
                            AxisValueLabel(
                                format: .dateTime.month(.twoDigits).day().hour().minute())
                        }
                    }
                    .frame(height: 190)
                    HStack(spacing: 16) {
                        ForEach(PowerState.allCases, id: \.self) { state in
                            Label {
                                Text(state.rawValue)
                            } icon: {
                                Circle().fill(stateColor(state)).frame(width: 7, height: 7)
                            }
                        }
                    }.font(.caption)
                }
                Text(
                    "实色磁盘段：工具请求模式 25 ＋ 系统进入睡眠 ＋ 从磁盘恢复。浅色段：依据恢复方式归类，具体转换边界未记录。空白表示没有足够记录；后台维护唤醒归入唤醒。点击下方区间查看依据。"
                ).font(.caption).foregroundStyle(.secondary)
            }
            Panel(title: "电量轨迹 · 对应同一时间范围") {
                if history.points.isEmpty {
                    Text("该时段没有电量记录。").foregroundStyle(.secondary)
                } else {
                    Chart(plotted) { item in
                        LineMark(
                            x: .value("时间", item.point.date), y: .value("电量", item.point.percent),
                            series: .value("连续采样段", item.group)
                        )
                        .foregroundStyle(.teal).lineStyle(StrokeStyle(lineWidth: 1.5))
                        PointMark(
                            x: .value("时间", item.point.date), y: .value("电量", item.point.percent)
                        ).symbolSize(item.point.origin == "系统事件" ? 25 : 9)
                            .foregroundStyle(item.point.source == "电源" ? Color.orange : Color.teal)
                            .accessibilityLabel(
                                "\(item.point.date.formatted())，\(percentLabel(item.point.percent))，\(item.point.source)，\(item.point.origin)"
                            )
                    }.chartXScale(domain: history.range).chartYScale(domain: 0...100)
                        .chartXAxis {
                            AxisMarks(values: .automatic(desiredCount: 5)) { _ in
                                AxisGridLine(); AxisTick();
                                AxisValueLabel(
                                    format: .dateTime.month(.twoDigits).day().hour().minute())
                            }
                        }
                        .chartYAxis {
                            AxisMarks(values: [0, 25, 50, 75, 100]) { v in
                                AxisGridLine(); AxisValueLabel { Text("\(v.as(Int.self) ?? 0)%") }
                            }
                        }.frame(height: 150)
                }
                Text(
                    "大点为系统睡眠／唤醒时的电量，小点为界面运行时每分钟采样；橙色表示接电源。仅连接间隔两分钟以内的采样，休眠中的耗电不伪造连续曲线。电量为系统整数百分比，0 个百分点不代表绝对零耗电。"
                ).font(.caption).foregroundStyle(.secondary)
            }
            Panel(title: "区间明细 · \(history.rows.count) 段") {
                HStack {
                    Text("状态 / 起止时间").frame(maxWidth: .infinity, alignment: .leading);
                    Text("时长").frame(width: 95, alignment: .leading);
                    Text("起 → 止电量").frame(width: 105, alignment: .leading);
                    Text("电量变化").frame(width: 115, alignment: .leading)
                }.font(.caption).foregroundStyle(.secondary)
                Divider()
                ForEach(Array(history.rows.reversed().prefix(300))) { row in
                    Button {
                        history.selected = history.selected == row.id ? nil : row.id
                    } label: {
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 6) {
                                    Circle().fill(stateColor(row.state)).frame(width: 7, height: 7);
                                    Text(row.state.rawValue).font(.callout.bold());
                                    if row.inferred {
                                        Text("推断").font(.caption2).foregroundStyle(.secondary)
                                    };
                                    if row.ongoing {
                                        Text("进行中").font(.caption2).foregroundStyle(.teal)
                                    }
                                }
                                Text("\(timeLabel(row.start)) → \(timeLabel(row.end))").font(
                                    .caption.monospacedDigit()
                                ).foregroundStyle(.secondary)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                            Text(formatDuration(row.duration)).frame(width: 95, alignment: .leading)
                            Text(
                                "\(percentLabel(row.startBattery)) → \(percentLabel(row.endBattery))"
                            ).monospacedDigit().frame(width: 105, alignment: .leading)
                            Text(changeLabel(row)).foregroundStyle(
                                row.source == "电池" ? .primary : .secondary
                            ).frame(width: 115, alignment: .leading)
                        }.font(.caption).padding(.vertical, 5).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                    if history.selected == row.id {
                        Text("供电：\(row.source)\n\(row.evidence)").font(.caption).foregroundStyle(
                            .secondary
                        ).textSelection(.enabled).padding(10).frame(
                            maxWidth: .infinity, alignment: .leading
                        ).background(
                            stateColor(row.state).opacity(0.07),
                            in: RoundedRectangle(cornerRadius: 8))
                    }
                    Divider()
                }
                if history.rows.count > 300 {
                    Text("界面展示最近 300 段；CSV 导出包含当前范围全部区间。").font(.caption).foregroundStyle(
                        .secondary)
                }
                Text("范围截断处不按比例估算电量，缺失值显示 —；接电源、供电变化、电量上升及缺测区间不计入放电合计。").font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let first = history.result.earliest {
                Text(
                    "最早记录：\(first.formatted(date: .abbreviated,time: .shortened)) · 本机时区 · 历史保留 90 天 · 电量采样需界面运行；关闭后仍可补读系统事件"
                ).font(.caption).foregroundStyle(.secondary)
            }
            if !history.exportMessage.isEmpty {
                Text(history.exportMessage).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    func summary(_ state: PowerState, title: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(
                title,
                systemImage: state == .awake
                    ? "sun.max" : state == .ram ? "memorychip" : "internaldrive"
            ).font(.caption).foregroundStyle(stateColor(state));
            Text(formatDuration(history.total(state))).font(
                .system(size: 22, weight: .semibold, design: .rounded));
            Text(history.drop(state)).font(.caption).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(16).background(
            stateColor(state).opacity(0.07), in: RoundedRectangle(cornerRadius: 14))
    }
    func timeLabel(_ date: Date) -> String {
        date.formatted(.dateTime.month(.twoDigits).day(.twoDigits).hour().minute().second())
    }
    func changeLabel(_ row: PowerInterval) -> String {
        guard let a = row.startBattery, let b = row.endBattery else { return "缺少端点电量" }
        if row.source != "电池" {
            return b > a
                ? String(format: "充入 %.0f 点", b - a)
                : "\(row.source) · 净变\(String(format:"%+.0f",b-a))点"
        }
        return b <= a ? String(format: "下降 %.0f 点", a - b) : String(format: "上升 %.0f 点", b - a)
    }
}
