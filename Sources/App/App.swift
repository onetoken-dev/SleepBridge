import AppKit
import SwiftUI

func shellQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}
func appleString(_ value: String) -> String {
    "\""
        + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(
            of: "\"", with: "\\\""
        ).replacingOccurrences(of: "\n", with: "\\n") + "\""
}

@MainActor final class Model: ObservableObject {
    @Published var minutes = 60
    @Published var scope = "battery"
    @Published var consent = false
    @Published var busy = false
    @Published var installed = false
    @Published var running = false
    @Published var controlReady = false
    @Published var controlDetail = ""
    @Published var config = Configuration()
    @Published var status = ServiceStatus()
    @Published var power = "正在读取…"
    @Published var settings = ""
    @Published var schedule = ""
    @Published var events = ""
    @Published var systemLog = "点击刷新系统记录，读取真实睡眠与唤醒事件。"
    @Published var assertions = ""
    @Published var message = "只读监测已启动。启用策略后才会更改电源设置。"
    @Published var error = false
    @Published var lastRefresh = Date()
    private var timer: Timer?
    private var refreshing = false
    init() {
        if let stored = readJSON(configPath, as: Configuration.self) {
            config = stored; minutes = stored.minutes; scope = stored.scope
        }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }
    var dirty: Bool { config.enabled && (minutes != config.minutes || scope != config.scope) }
    func refresh(logs: Bool = false) {
        guard !refreshing else { return }; refreshing = true
        Task {
            let values = await Task.detached { () -> [String] in
                let power = run("/usr/bin/pmset", ["-g", "batt"]).output
                let settings = run("/usr/bin/pmset", ["-g", "custom"]).output
                let schedule = run("/usr/bin/pmset", ["-g", "sched"]).output
                let service = run("/bin/launchctl", ["print", "system/" + serviceID]).output
                let assertions = logs ? run("/usr/bin/pmset", ["-g", "assertions"]).output : ""
                let log =
                    logs
                    ? run("/usr/bin/pmset", ["-g", "log"]).output.components(separatedBy: .newlines)
                        .filter {
                            $0.range(
                                of:
                                    #"^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2} [+-]\d{4}\s+(Sleep|Wake|DarkWake|HibernateStats)\s"#,
                                options: .regularExpression) != nil
                        }.suffix(100).joined(separator: "\n") : ""
                return [
                    power, settings, schedule, service, assertions, log,
                    connectControl("ping").output,
                ]
            }.value
            self.power = values[0]; self.settings = values[1]; self.schedule = values[2]
            self.installed = FileManager.default.fileExists(atPath: installedHelper)
            self.running = values[3].contains("state = running")
            self.controlReady = values[6] == helperGreeting
            self.controlDetail = values[6]
            if !self.controlReady && self.status.deepCycle {
                self.message = "休眠请求后后台未响应；该状态尚未确认，请查看系统日志。"
            }
            self.config = readJSON(configPath, as: Configuration.self) ?? Configuration()
            self.status = readJSON(statusPath, as: ServiceStatus.self) ?? ServiceStatus()
            self.events =
                (try? String(contentsOfFile: logPath, encoding: .utf8)) ?? "暂无服务事件。启用策略后会开始记录。"
            if logs {
                self.assertions = values[4];
                self.systemLog = values[5].isEmpty ? "未找到相关系统记录。" : values[5]
            }
            self.lastRefresh = Date(); self.refreshing = false
        }
    }
    func privileged(_ shell: String, success: String) {
        guard !busy else { return }; busy = true; error = false; message = "等待 macOS 管理员授权…"
        Task {
            let result = await Task.detached {
                run(
                    "/usr/bin/osascript",
                    [
                        "-e",
                        "do shell script " + appleString(shell) + " with administrator privileges",
                    ], timeout: nil)
            }.value
            busy = false; error = result.code != 0
            if result.code == 0 {
                message = success
            } else if result.output.contains("-60005") {
                message =
                    "macOS 未通过管理员身份验证，操作未执行。请在系统授权窗口使用具有管理员权限的账户名称和登录密码；应用不读取或保存密码。升级成功后，日常硬盘休眠不再重复要求密码。"
            } else if result.output.contains("-128") {
                message = "已取消系统授权，操作未执行。"
            } else {
                message = "操作未完成：" + result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            refresh(logs: true)
        }
    }
    func apply(repair: Bool = false) {
        guard (repair ? config.enabled : consent), (1...1440).contains(minutes),
            let resource = Bundle.main.resourcePath
        else { return }
        let delay = repair ? config.minutes : minutes
        let targetScope = repair ? config.scope : scope
        var script = "set -e\n"
        script += "/usr/bin/install -d -o root -g wheel -m 755 " + shellQuote(supportPath) + "\n"
        script +=
            "if /bin/launchctl print system/" + serviceID
            + " >/dev/null 2>&1; then /bin/launchctl bootout system/" + serviceID + "; fi\n"
        script +=
            "/usr/bin/install -o root -g wheel -m 755 "
            + shellQuote(resource + "/SleepBridgeHelper") + " " + shellQuote(installedHelper) + "\n"
        script +=
            "/usr/bin/install -o root -g wheel -m 644 "
            + shellQuote(resource + "/" + serviceID + ".plist") + " "
            + shellQuote("/Library/LaunchDaemons/" + serviceID + ".plist") + "\n"
        script +=
            "/bin/launchctl bootstrap system "
            + shellQuote("/Library/LaunchDaemons/" + serviceID + ".plist") + "\n"
        script += shellQuote(installedHelper) + " --configure \(delay) \(targetScope) \(getuid())\n"
        privileged(script, success: "后台服务和策略已更新。日常请求硬盘休眠无需重复输入管理员密码。")
    }
    func disable() {
        privileged(shellQuote(installedHelper) + " --disable", success: "已停用策略并恢复启用前的休眠模式。")
    }
    func uninstall() {
        let alert = NSAlert(); alert.messageText = "卸载后台服务？";
        alert.informativeText = "先恢复原休眠模式，再移除服务、配置和服务日志。此应用仍会保留。";
        alert.addButton(withTitle: "卸载并恢复"); alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let script =
            "set -e\n" + shellQuote(installedHelper) + " --disable\n/bin/launchctl bootout system/"
            + serviceID + "\n/bin/rm -f "
            + shellQuote("/Library/LaunchDaemons/" + serviceID + ".plist") + "\n/bin/rm -rf "
            + shellQuote(supportPath)
        privileged(script, success: "已卸载后台服务并恢复原设置。")
    }
    func sleepNow(deep: Bool) {
        let alert = NSAlert(); alert.messageText = deep ? "现在请求硬盘休眠？" : "现在让电脑睡眠？"
        alert.informativeText = "请先保存正在编辑的内容。电脑会立即进入睡眠流程。"; alert.addButton(withTitle: "立即睡眠");
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        if deep {
            busy = true
            Task {
                let result = await Task.detached { connectControl("hibernate") }.value
                busy = false; error = result.code != 0
                message = result.code == 0 ? "硬盘休眠请求已交给已授权后台服务。" : result.output
            }
        } else {
            let result = run("/usr/bin/pmset", ["sleepnow"])
            message = result.code == 0 ? "已请求系统睡眠。" : result.output
            error = result.code != 0
        }
    }
    func export() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "SleepBridge-诊断.txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let report =
            "SleepBridge 诊断\n\(Date())\n服务运行：\(running)\n策略：\(config.enabled)，\(config.minutes) 分钟，\(config.scope)\n状态：\(status.phase)\n\(status.detail)\n\n电源\n\(power)\n设置\n\(settings)\n定时事件\n\(schedule)\n服务日志\n\(events)\n系统记录（最后手动刷新）\n\(systemLog)\n阻止睡眠的进程（最后手动刷新）\n\(assertions)"
        do {
            try report.write(to: url, atomically: true, encoding: .utf8); message = "诊断已导出。"
        } catch { self.error = true; message = error.localizedDescription }
    }
}

struct Panel<Content: View>: View {
    var title: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.headline); content
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(22)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.primary.opacity(0.06)))
    }
}
@MainActor final class NavigationModel: ObservableObject {
    @Published var selection = "overview"
    @Published var logSelection = "服务事件"
}
struct ContentView: View {
    @EnvironmentObject var model: Model
    @StateObject private var navigation = NavigationModel()
    @EnvironmentObject var history: HistoryModel
    var selection: String {
        get { navigation.selection }
        nonmutating set { navigation.selection = newValue }
    }
    var logSelection: String { navigation.logSelection }
    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(spacing: 10) {
                    Image(systemName: "moon.zzz.fill").font(.system(size: 28)).foregroundStyle(
                        .teal)
                    VStack(alignment: .leading) {
                        Text("SleepBridge").font(.title3.bold());
                        Text("睡眠 · 休眠 · 监测").font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(.top, 18)
                VStack(spacing: 6) {
                    nav("overview", "状态总览", "square.grid.2x2")
                    nav("strategy", "睡眠策略", "slider.horizontal.3")
                    nav("history", "时间与电量", "chart.xyaxis.line")
                    nav("logs", "监测与日志", "waveform.path.ecg")
                    nav("service", "后台服务", "gearshape.2")
                }
                Spacer()
                Label(
                    model.running ? "后台服务运行中" : "只读监测",
                    systemImage: model.running ? "checkmark.circle.fill" : "eye"
                )
                .font(.caption).foregroundStyle(model.running ? .teal : .secondary)
                Text("Apple silicon · 实验性定时转换").font(.caption2).foregroundStyle(.secondary)
            }.padding(20).frame(minWidth: 210)
        } detail: {
            VStack(spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(title).font(.system(size: 28, weight: .bold))
                        Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if model.busy { ProgressView().controlSize(.small) }
                    Button {
                        model.refresh(logs: selection == "logs");
                        if selection == "history" { history.refresh() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }.help("刷新状态")
                }.padding(28)
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        if selection == "overview" { overview }
                        if selection == "strategy" { strategy }
                        if selection == "history" { HistoryView(history: history) }
                        if selection == "logs" { logs }
                        if selection == "service" { service }
                    }.padding(.horizontal, 28).padding(.bottom, 24)
                }
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: model.error ? "exclamationmark.circle" : "info.circle")
                    Text(model.message).textSelection(.enabled)
                    Spacer(minLength: 0)
                }.font(.caption).foregroundStyle(model.error ? .red : .secondary).padding(16)
                    .background(.bar)
            }.background(Color(nsColor: .windowBackgroundColor))
        }.frame(minWidth: 960, minHeight: 710)
            .onChange(of: selection) { _, value in
                if value == "logs" { model.refresh(logs: true) };
                if value == "history" { history.refresh() }
            }
    }
    var title: String {
        [
            "overview": "睡眠状态，一目了然", "history": "每段时间，电量去向", "strategy": "配置你的睡眠节奏",
            "logs": "从记录确认实际行为", "service": "后台服务与恢复",
        ][selection]!
    }
    var subtitle: String {
        [
            "overview": "短时间快速唤醒，长时间尝试节省更多电量。", "history": "对照系统事件与电量记录，查看唤醒、RAM 睡眠和磁盘休眠。",
            "strategy": "设置从内存睡眠转向硬盘休眠的等待时间。", "logs": "区分已发出的请求与系统实际完成的休眠。",
            "service": "关闭应用后，已启用的后台策略仍会继续运行。",
        ][selection]!
    }
    func nav(_ key: String, _ name: String, _ icon: String) -> some View {
        Button {
            selection = key
        } label: {
            Label(name, systemImage: icon).frame(maxWidth: .infinity, alignment: .leading).padding(
                11
            )
            .background(
                selection == key ? Color.teal.opacity(0.13) : .clear,
                in: RoundedRectangle(cornerRadius: 10)
            )
            .foregroundStyle(selection == key ? Color.teal : .primary)
        }.buttonStyle(.plain)
    }
    var overview: some View {
        Group {
            Panel(title: "当前策略") {
                HStack(alignment: .top, spacing: 26) {
                    Image(systemName: model.config.enabled ? "moon.stars.fill" : "moon").font(
                        .system(size: 46)
                    ).foregroundStyle(.teal)
                    VStack(alignment: .leading, spacing: 8) {
                        Text(
                            model.config.enabled
                                ? (model.running
                                    ? (model.controlReady ? model.status.phase : "后台控制无响应／等待确认")
                                    : "策略已保存，但服务未运行") : "尚未启用定时转换"
                        ).font(.title2.bold())
                        Text(
                            model.config.enabled
                                ? "内存睡眠 → \(model.config.minutes) 分钟后安排唤醒 → 尝试硬盘休眠"
                                : "当前仅监测，保留电脑现有电源设置。"
                        )
                        .foregroundStyle(.secondary)
                        if model.config.enabled {
                            Text(model.status.detail).font(.callout).foregroundStyle(.secondary)
                        }
                        if let date = model.status.scheduledWake, model.config.enabled {
                            Text("计划转换：\(date.formatted(date: .abbreviated, time: .standard))")
                                .font(.callout.monospacedDigit())
                        }
                    }
                    Spacer()
                }
                if model.config.enabled && !model.controlReady {
                    HStack {
                        Text("控制接口无响应，不能据此判断版本；请查看后台服务诊断。").font(.callout).foregroundStyle(.orange);
                        Button("升级后台服务") { model.apply(repair: true) }.disabled(model.busy)
                    }
                }
                HStack {
                    Button("配置策略") { selection = "strategy" }.buttonStyle(.borderedProminent).tint(
                        .teal)
                    Button("现在睡眠") { model.sleepNow(deep: false) }
                    Button("现在请求硬盘休眠") { model.sleepNow(deep: true) }.disabled(
                        !model.controlReady || !model.config.enabled || !model.running || model.busy
                            || (model.config.scope == "battery"
                                && !model.power.contains("'Battery Power'"))
                    )
                }
            }
            HStack(alignment: .top, spacing: 18) {
                Panel(title: "当前模式设置") {
                    let values = modes(from: model.settings)
                    modeRow("电池供电", value: values["battery"])
                    Divider()
                    modeRow("连接电源", value: values["ac"])
                }
                Panel(title: "电池与电源") {
                    Text(model.power.replacingOccurrences(of: "Now drawing from", with: "当前电源："))
                        .font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                    Text("状态每 10 秒刷新").font(.caption).foregroundStyle(.secondary)
                    Text("最近刷新 \(model.lastRefresh.formatted(date: .omitted, time: .standard))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Panel(title: "如何判断已经转入硬盘休眠？") {
                Text(
                    "后台显示“已请求”只代表命令已发出。唤醒后，在“监测与日志”中刷新系统记录，查找 Wake from Hibernate 与 HibernateStats。实际行为受 macOS、硬件和其他电源活动影响。"
                )
                .font(.callout).foregroundStyle(.secondary)
                Button("查看系统记录") { selection = "logs" }
            }
        }
    }
    func modeRow(_ label: String, value: Int?) -> some View {
        HStack {
            Text(label); Spacer();
            Text(
                value.map { "模式 \($0) · " + ($0 == 25 ? "硬盘休眠" : $0 == 3 ? "内存睡眠＋磁盘副本" : "系统自定义") }
                    ?? "未知"
            ).foregroundStyle(.secondary)
        }.font(.callout)
    }
    var strategy: some View {
        Group {
            Panel(title: "等待多久再尝试硬盘休眠？") {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    TextField("分钟", value: $model.minutes, format: .number.grouping(.never)).font(
                        .system(size: 38, weight: .semibold, design: .rounded)
                    ).frame(width: 135).textFieldStyle(.roundedBorder)
                    Text("分钟").foregroundStyle(.secondary)
                    Spacer()
                    ForEach([15, 30, 60, 120], id: \.self) { value in
                        Button("\(value) 分钟") { model.minutes = value }
                    }
                }
                Text("可设置 1–1440 分钟。计时从系统实际进入睡眠开始，而非屏幕关闭。提前唤醒会取消本轮计时。").font(.callout)
                    .foregroundStyle(.secondary)
                Divider()
                Picker("生效范围", selection: $model.scope) {
                    Text("仅电池供电").tag("battery"); Text("电池与接电源").tag("all")
                }.pickerStyle(.segmented)
                if model.scope == "battery" {
                    Text("接电源时保留启用前的休眠模式。").font(.caption).foregroundStyle(.secondary)
                }
            }
            Panel(title: "转换流程与限制") {
                HStack(spacing: 12) {
                    step("memorychip", "内存睡眠", "模式 3，保留快速恢复")
                    Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                    step("alarm", "定时唤醒", "由系统安排一次唤醒")
                    Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                    step("internaldrive", "请求硬盘休眠", "模式 25，再次睡眠")
                }
                Text(
                    "M1 未提供可验证的原生延迟参数。本工具通过定时唤醒尝试转换，可能短暂亮屏，也可能因合盖、电源限制或系统调度而延迟／不执行。唤醒后会等待 25 秒；检测到近期输入或无法确认空闲时会跳过，避免打断使用。系统自身也可能更早进入深度休眠。"
                ).font(.callout).foregroundStyle(.secondary)
                Toggle("我了解定时唤醒方式及其限制，允许启用后台策略", isOn: $model.consent).toggleStyle(.checkbox)
            }
            HStack {
                Button(model.config.enabled ? "应用更改" : "授权并启用") { model.apply() }.buttonStyle(
                    .borderedProminent
                ).tint(.teal).disabled(
                    !model.consent || !(1...1440).contains(model.minutes) || model.busy)
                if model.config.enabled {
                    Button("停用并恢复原设置") { model.disable() }.disabled(model.busy)
                }
                if model.dirty { Text("有未应用的更改").font(.caption).foregroundStyle(.orange) }
            }
        }
    }
    func step(_ icon: String, _ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: icon).font(.title2).foregroundStyle(.teal);
            Text(title).font(.headline); Text(detail).font(.caption).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    var logs: some View {
        Group {
            HStack {
                Picker("内容", selection: $navigation.logSelection) {
                    ForEach(["服务事件", "系统休眠记录", "定时唤醒", "阻止睡眠的进程", "电源设置"], id: \.self) { Text($0) }
                }.labelsHidden()
                Spacer(); Button("刷新系统记录") { model.refresh(logs: true) };
                Button("导出诊断") { model.export() }
            }
            Panel(title: logSelection) {
                let content =
                    logSelection == "服务事件"
                    ? model.events
                    : logSelection == "系统休眠记录"
                        ? model.systemLog
                        : logSelection == "定时唤醒"
                            ? model.schedule
                            : logSelection == "阻止睡眠的进程" ? model.assertions : model.settings
                ScrollView([.horizontal, .vertical]) {
                    Text(content.isEmpty ? "暂无记录" : content).font(
                        .system(size: 11, design: .monospaced)
                    ).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding(4)
                }.frame(minHeight: 370, maxHeight: 430)
            }
            Text("服务事件时间使用 UTC（Z）；系统日志使用本机时区。导出前请先刷新系统记录，诊断可能包含应用和进程名称。").font(.caption)
                .foregroundStyle(.secondary)
        }
    }
    var service: some View {
        Group {
            Panel(title: "服务状态") {
                LabeledContent("安装", value: model.installed ? "已安装" : "未安装")
                LabeledContent("运行", value: model.running ? "运行中" : "未运行")
                LabeledContent("策略", value: model.config.enabled ? "已启用" : "已停用")
                LabeledContent(
                    "免重复密码控制",
                    value: model.controlReady ? "已就绪（\(helperProtocolVersion)）" : "控制接口未就绪")
                if !model.controlReady {
                    Text(model.controlDetail).font(.caption).foregroundStyle(.orange).textSelection(
                        .enabled)
                }
                if model.installed && model.config.enabled {
                    Button("升级／修复后台服务") { model.apply(repair: true) }.disabled(model.busy)
                    Text("升级需要一次系统管理员授权；保留现有策略和启用前的备份。").font(.caption).foregroundStyle(.secondary)
                }
                Text(
                    "首次启用时，系统会要求管理员授权，将后台服务安装到 /Library。服务由 launchd 管理，关闭窗口或退出应用后仍然运行，重启后也会启动。应用本身不会自动在登录时打开。"
                ).font(.callout).foregroundStyle(.secondary)
            }
            Panel(title: "恢复与移除") {
                Text(
                    "启用前会备份电池与接电源的 hibernatemode。停用时恢复这两项，并取消本工具自己的唤醒事件；不会清除其他应用的定时事件。仅更改休眠模式，不更改 Power Nap、网络唤醒或屏幕超时。"
                ).font(.callout).foregroundStyle(.secondary)
                HStack {
                    Button("停用并恢复原设置") { model.disable() }.disabled(!model.installed || model.busy);
                    Button("卸载后台服务…", role: .destructive) { model.uninstall() }.disabled(
                        !model.installed || model.busy)
                }
            }
            Panel(title: "版本与说明") {
                Text(
                    "SleepBridge \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev") · 本机构建\n无网络连接、无账号、无遥测。日志仅保存在本机。\n手动磁盘休眠已通过实机验证，定时自动转换仍待验证。"
                )
                .font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
    }
}
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        if let url = Bundle.main.url(forResource: "SleepBridge", withExtension: "icns"),
            let icon = NSImage(contentsOf: url)
        {
            NSApplication.shared.applicationIconImage = icon
        }
    }
}
@main struct SleepBridgeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = Model()
    @StateObject private var history = HistoryModel()
    var body: some Scene {
        WindowGroup("SleepBridge") {
            ContentView().environmentObject(model).environmentObject(history).tint(.teal)
        }.defaultSize(width: 1100, height: 800)
        MenuBarExtra("SleepBridge", systemImage: "moon.zzz") {
            Text(model.config.enabled ? "策略：\(model.config.minutes) 分钟" : "策略未启用")
            Text(model.running ? model.status.phase : "后台服务未运行")
            Divider()
            Button("显示主窗口") {
                NSApp.activate(ignoringOtherApps: true);
                NSApp.windows.first { $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
            }
            Button("刷新状态") { model.refresh() }
            Button("停用并恢复原设置") { model.disable() }.disabled(!model.config.enabled || model.busy)
            Divider(); Button("退出界面（保留后台策略）") { NSApp.terminate(nil) }
        }
    }
}
