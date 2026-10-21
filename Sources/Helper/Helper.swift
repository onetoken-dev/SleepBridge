import Darwin
import Foundation
import IOKit
import IOKit.pwr_mgt

// IOMessage.h function-like macros are not imported into Swift.
let kIOMessageCanSystemSleep: UInt32 = 0xe0000270
let kIOMessageSystemWillSleep: UInt32 = 0xe0000280
let kIOMessageSystemHasPoweredOn: UInt32 = 0xe0000300

func record(_ text: String) {
    let stamp = ISO8601DateFormatter().string(from: Date())
    let line = "\(stamp)  \(text)\n"
    if let old = FileManager.default.contents(atPath: logPath), old.count > 300_000 {
        try? Data(old.suffix(150_000)).write(to: URL(fileURLWithPath: logPath), options: .atomic)
    }
    if !FileManager.default.fileExists(atPath: logPath) {
        FileManager.default.createFile(
            atPath: logPath, contents: nil, attributes: [.posixPermissions: 0o644])
    }
    if let handle = FileHandle(forWritingAtPath: logPath) {
        defer { try? handle.close() }; _ = try? handle.seekToEnd();
        try? handle.write(contentsOf: Data(line.utf8))
    }
}
func checkedPM(_ args: [String]) throws {
    #if SLEEPBRIDGE_TESTING
        TestPowerEffects.commands.append(args)
    #else
        let result = runHelperCommand("/usr/bin/pmset", args, timeout: 2)
        if result.code != 0 {
            throw NSError(
                domain: "SleepBridge", code: Int(result.code),
                userInfo: [NSLocalizedDescriptionKey: result.output])
        }
    #endif
}
func locked<T>(_ action: () throws -> T) rethrows -> T {
    let fd = open(supportPath + "/operation.lock", O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard fd >= 0 else { fatalError("无法取得服务锁") }
    flock(fd, LOCK_EX); defer { flock(fd, LOCK_UN); close(fd) }
    return try action()
}
/// Main-loop handlers skip busy CLI locks instead of blocking power notifications.
@discardableResult func serviceLocked(_ action: () -> Void) -> Bool {
    let fd = open(supportPath + "/operation.lock", O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard fd >= 0 else { return false }
    defer { close(fd) }
    guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { return false }
    defer { flock(fd, LOCK_UN) }
    action()
    return true
}
func cancelWake(_ status: inout ServiceStatus) {
    if let date = status.scheduledWake {
        let result = cancelScheduledWake(date)
        record(result == kIOReturnSuccess ? "已取消本工具的定时唤醒" : "定时事件已触发或取消返回 \(result)")
    }
    status.scheduledWake = nil; status.sleepStart = nil
}
func applyRAM(_ config: Configuration) throws {
    try checkedPM([config.scope == "all" ? "-a" : "-b", "hibernatemode", "3"])
    if config.scope == "battery", let ac = config.original["ac"] {
        try checkedPM(["-c", "hibernatemode", String(ac)])
    }
}
func restore(_ config: Configuration) throws {
    for (key, value) in config.original.sorted(by: { $0.key < $1.key }) {
        try checkedPM([key == "battery" ? "-b" : "-c", "hibernatemode", String(value)])
    }
}
final class Supervisor {
    var config = Configuration()
    var status = ServiceStatus()
    var root: io_connect_t = 0
    var port: IONotificationPortRef?
    var notifier: io_object_t = 0
    var generation = 0
    var controlFD: Int32 = -1
    var lastHeartbeat = Date.distantPast
    var sleepPID: pid_t = 0
    let wakeReader = OperationQueue()
    var wakeCheckDelay: TimeInterval = 25
    init() {
        wakeReader.maxConcurrentOperationCount = 1; wakeReader.qualityOfService = .userInitiated
    }
    func readWakeLog() -> CommandResult {
        #if SLEEPBRIDGE_TESTING
            return TestPowerEffects.readWakeLog()
        #else
            return runHelperCommand("/usr/bin/pmset", ["-g", "log"], timeout: 10)
        #endif
    }
    func checkWake(start: Date, token: Int, diagnostic: Bool = false) {
        guard diagnostic || generation == token else { return }
        wakeReader.addOperation { [weak self] in
            guard let self else { return }
            let result = self.readWakeLog()
            let evidence =
                result.code == 0 ? latestWakeEvidence(result.output, notBefore: start) : nil
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if diagnostic {
                    record(result.code == 0 ? "唤醒日志诊断完成，后台保持响应；未发起睡眠" : "日志诊断失败：" + result.output)
                    return
                }
                self.completeWakeCheck(start: start, token: token, evidence: evidence)
            }
        }
    }
    func completeWakeCheck(start: Date, token: Int, evidence: WakeEvidence?) {
        guard config.enabled, generation == token else { return }
        let acquired = serviceLocked {
            synchronizeConfig()
            guard config.enabled, generation == token else { return }
            let result: String
            if evidence == nil {
                result = "unknown-wake"
            } else if evidence!.userInitiated {
                result = "user-wake"
            } else {
                result = decision(
                    elapsed: Date().timeIntervalSince(start), delay: Double(config.minutes * 60),
                    idle: idleSeconds(), battery: onBattery(), scope: config.scope)
            }
            cancelWake(&status)
            if result == "hibernate" {
                beginHibernate()
            } else {
                save("策略已就绪", "检测到用户活动、电源变化或无法确认空闲，跳过转换")
                record("为避免打断使用，跳过转换：\(result)")
            }
        }
        if !acquired {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                self?.completeWakeCheck(start: start, token: token, evidence: evidence)
            }
        }
    }
    func save(_ phase: String, _ detail: String = "") {
        status.phase = phase; status.detail = detail; status.updated = Date(); status.pid = getpid()
        try? writeJSON(status, to: statusPath)
    }
    func reload() {
        serviceLocked {
            guard var next = readJSON(configPath, as: Configuration.self) else { return }
            if next.revision != config.revision {
                generation += 1
                // CLI has already applied or restored the settings. Never restore stale values here.
                cancelWake(&status); status.deepCycle = false; config = next
                save(config.enabled ? "策略已就绪" : "已停用", config.enabled ? "等待下一次系统睡眠" : "原休眠模式已恢复")
            }
            if next.request == "hibernate" && next.enabled {
                next.request = ""; try? writeJSON(next, to: configPath); config = next
                beginHibernate()
            }
        }
    }
    func synchronizeConfig() {
        if let latest = readJSON(configPath, as: Configuration.self),
            latest.revision != config.revision
        {
            generation += 1; cancelWake(&status); status.deepCycle = false; config = latest
        }
    }
    func willSleep() {
        // Already on the IOKit main loop: never acquire an operation lock here.
        synchronizeConfig()
        guard config.enabled else { return }
        generation += 1
        if status.deepCycle { save("已请求硬盘休眠", "等待系统确认；实际模式请查看系统日志"); return }
        if config.scope == "battery" && !onBattery() { save("接电源，跳过策略"); return }
        cancelWake(&status)
        let start = Date(), date = Date(timeIntervalSinceNow: Double(config.minutes * 60))
        do {
            let result = scheduleWake(date)
            guard result == kIOReturnSuccess else {
                throw NSError(
                    domain: "IOKit", code: Int(result),
                    userInfo: [NSLocalizedDescriptionKey: "安排定时唤醒失败：\(result)"])
            }
            status.sleepStart = start; status.scheduledWake = date
            save("内存睡眠计时中", "计划在 \(pmDate(date)) 唤醒并尝试硬盘休眠")
            record("进入睡眠；已安排 \(config.minutes) 分钟后的转换唤醒")
        } catch {
            save("定时唤醒失败", error.localizedDescription); record("安排失败：\(error.localizedDescription)")
        }
    }
    func didWake() {
        serviceLocked {
            synchronizeConfig()
            guard config.enabled else { return }
            generation += 1
            let token = generation
            if status.deepCycle {
                status.deepCycle = false; cancelWake(&status)
                do { try applyRAM(config); save("策略已就绪", "已从休眠唤醒，恢复下一次内存睡眠") } catch {
                    save("恢复失败", error.localizedDescription)
                }
                record("休眠请求后收到唤醒；已恢复内存睡眠模式")
                return
            }
            guard let start = status.sleepStart else { return }
            let elapsed = Date().timeIntervalSince(start)
            if elapsed + 2 < Double(config.minutes * 60)
                || (config.scope == "battery" && !onBattery())
            {
                cancelWake(&status); save("策略已就绪", "提前唤醒或已接电源，本轮计时结束");
                record("提前唤醒／电源范围变化，取消本轮转换"); return
            }
            save("唤醒后检查中", "等待 25 秒，检测键盘与鼠标活动")
            DispatchQueue.main.asyncAfter(deadline: .now() + wakeCheckDelay) { [weak self] in
                self?.checkWake(start: start, token: token)
            }
        }
    }
    func beginHibernate() {
        guard config.scope == "all" || onBattery() else { save("接电源，跳过策略"); return }
        cancelWake(&status)
        do {
            try checkedPM([config.scope == "all" ? "-a" : "-b", "hibernatemode", "25"])
            status.deepCycle = true
            save("正在请求硬盘休眠", "pmset 请求不等于硬件已完成；请在唤醒后核对系统日志")
            record("设置 hibernatemode 25 并请求 sleepnow")
            #if SLEEPBRIDGE_TESTING
                sleepPID = try TestPowerEffects.spawnSleepRequest()
            #else
                sleepPID = try spawnSleepRequest()
            #endif
            record("异步休眠进程已启动 PID \(sleepPID)；主循环继续处理通知")
            // A rejected/blocked sleep must not leave the computer permanently in mode 25.
            let token = generation
            DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in
                guard let self = self, self.generation == token, self.status.deepCycle else {
                    return
                }
                serviceLocked {
                    self.status.deepCycle = false
                    do {
                        try applyRAM(self.config); self.save("休眠请求未确认", "已恢复模式 3；请检查阻止睡眠的进程")
                    } catch { self.save("恢复失败", error.localizedDescription) }
                    record("60 秒内没有收到睡眠事件，恢复模式 3")
                }
            }
        } catch {
            status.deepCycle = false; try? applyRAM(config)
            save("硬盘休眠请求失败", error.localizedDescription);
            record("请求失败：\(error.localizedDescription)")
        }
    }
    func startControlServer() {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { record("本地控制连接创建失败"); return }
        unlink(controlSocket)
        var address = socketAddress(controlSocket)
        let result = withUnsafePointer(to: &address) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0, chmod(controlSocket, 0o666) == 0, listen(fd, 4) == 0 else {
            close(fd); record("本地控制连接监听失败"); return
        }
        controlFD = fd
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        record("本地控制监听已就绪（主运行循环）")
    }
    func pollControl() {
        if sleepPID > 0 {
            var exitStatus: Int32 = 0
            let reaped = waitpid(sleepPID, &exitStatus, WNOHANG)
            if reaped > 0 { record("休眠命令进程退出，状态 \(exitStatus)"); sleepPID = 0 }
        }
        guard controlFD >= 0 else { return }
        for _ in 0..<4 {
            let peer = accept(controlFD, nil, nil)
            guard peer >= 0 else { break }
            var uid: uid_t = 0, gid: gid_t = 0
            var timeout = timeval(tv_sec: 1, tv_usec: 0)
            setsockopt(
                peer, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            var noSignal: Int32 = 1
            setsockopt(
                peer, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
            let authenticated = getpeereid(peer, &uid, &gid) == 0
            var bytes = [UInt8](repeating: 0, count: 64)
            let count = read(peer, &bytes, bytes.count)
            let command = count > 0 ? String(decoding: bytes.prefix(count), as: UTF8.self) : ""
            var response = "ERR 服务正忙，请稍后重试"
            serviceLocked {
                response = "ERR 未授权的本机用户"
                if authenticated, var current = readJSON(configPath, as: Configuration.self),
                    current.authorizedUID == uid
                {
                    if command == "ping" {
                        response = helperGreeting
                    } else if command == "hibernate" && current.enabled {
                        if current.scope == "battery" && !onBattery() {
                            response = "ERR 当前策略仅适用于电池供电"
                        } else {
                            current.request = "hibernate";
                            do {
                                try writeJSON(current, to: configPath); response = "OK 请求已交给后台服务"
                            } catch { response = "ERR " + error.localizedDescription }
                        }
                    } else if command == "diagnose" {
                        checkWake(
                            start: Date().addingTimeInterval(-86400), token: generation,
                            diagnostic: true)
                        response = "OK 唤醒日志诊断已启动；不会触发休眠"
                    } else {
                        response = "ERR 策略未启用或请求无效"
                    }
                }
            }
            let data = Data(response.utf8)
            _ = data.withUnsafeBytes { write(peer, $0.baseAddress, $0.count) }
            close(peer)
        }
        if Date().timeIntervalSince(lastHeartbeat) >= 15 {
            serviceLocked {
                status.updated = Date(); status.pid = getpid();
                try? writeJSON(status, to: statusPath)
            }
            lastHeartbeat = Date()
        }
    }
    /// IOKit delivery must return promptly, including when pmset has initiated sleep.
    func handlePowerMessage(_ message: UInt32, argument: UnsafeMutableRawPointer?) {
        if message == kIOMessageCanSystemSleep || message == kIOMessageSystemWillSleep {
            if message == kIOMessageSystemWillSleep { willSleep() }
            #if SLEEPBRIDGE_TESTING
                TestPowerEffects.acknowledgments.append(message)
            #else
                IOAllowPowerChange(root, Int(bitPattern: argument))
            #endif
        } else if message == kIOMessageSystemHasPoweredOn {
            DispatchQueue.main.async { self.didWake() }
        }
    }
    func start() {
        config = readJSON(configPath, as: Configuration.self) ?? Configuration()
        status = readJSON(statusPath, as: ServiceStatus.self) ?? ServiceStatus()
        serviceLocked {
            cancelWake(&status); status.deepCycle = false
            if config.enabled {
                do { try applyRAM(config) } catch {
                    save("设置失败", error.localizedDescription); record(error.localizedDescription)
                }
            }
            save(config.enabled ? "策略已就绪" : "已停用", "后台服务已启动")
        }
        #if !SLEEPBRIDGE_TESTING
            let context = Unmanaged.passUnretained(self).toOpaque()
            root = IORegisterForSystemPower(
                context, &port,
                { ref, _, message, argument in
                    guard let ref = ref else { return }
                    let supervisor = Unmanaged<Supervisor>.fromOpaque(ref).takeUnretainedValue()
                    supervisor.handlePowerMessage(message, argument: argument)
                }, &notifier)
            guard root != 0, let port = port else {
                record("IOKit 电源通知注册失败"); save("监控启动失败"); exit(1)
            }
            CFRunLoopAddSource(
                CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(port).takeUnretainedValue(),
                .commonModes)
        #endif
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.pollControl(); self?.reload()
        }
        startControlServer()
        record("后台监控已启动，PID \(getpid())")
        CFRunLoopRun()
    }
}
#if !SLEEPBRIDGE_TESTING
    @main struct HelperMain {
        static func main() {
            let args = Array(CommandLine.arguments.dropFirst())
            if args == ["--self-test"] {
                let sample = "Battery Power:\n hibernatemode 25\nAC Power:\n hibernatemode 3\n"
                precondition(modes(from: sample) == ["battery": 25, "ac": 3])
                precondition(
                    decision(elapsed: 50, delay: 60, idle: 100, battery: true, scope: "battery")
                        == "early")
                precondition(
                    decision(elapsed: 65, delay: 60, idle: 2, battery: true, scope: "battery")
                        == "active")
                precondition(
                    decision(elapsed: 65, delay: 60, idle: nil, battery: true, scope: "battery")
                        == "active")
                precondition(
                    decision(elapsed: 65, delay: 60, idle: 100, battery: false, scope: "battery")
                        == "scope")
                precondition(
                    decision(elapsed: 65, delay: 60, idle: 100, battery: true, scope: "battery")
                        == "hibernate")
                precondition(
                    decision(elapsed: 65, delay: 60, idle: 100, battery: false, scope: "all")
                        == "hibernate")
                let config = Configuration(enabled: true, minutes: 60)
                precondition(
                    (try! JSONDecoder().decode(
                        Configuration.self, from: JSONEncoder().encode(config))).minutes == 60)
                print(
                    "PASS: 8 checks (mode parsing, early wake, user activity, unknown activity, power scope, transition, AC scope, configuration roundtrip)"
                )
                return
            }
            if args == ["--probe"] {
                var p: IONotificationPortRef?; var n: io_object_t = 0
                let root = IORegisterForSystemPower(nil, &p, { _, _, _, _ in }, &n)
                print(
                    "IOKit registration: \(root != 0 ? "OK" : "FAILED"); battery: \(onBattery()); HID idle: \(idleSeconds().map { String(format: "%.1f s", $0) } ?? "unknown")"
                )
                if root != 0 { IODeregisterForSystemPower(&n); IOServiceClose(root) };
                if let p = p { IONotificationPortDestroy(p) }
                return
            }
            if args.count == 2, args[0] == "--control",
                ["ping", "hibernate", "diagnose"].contains(args[1])
            {
                let result = connectControl(args[1]); print(result.output); exit(result.code)
            }
            guard getuid() == 0 else { fputs("需要管理员权限\n", stderr); exit(1) }
            if args == ["--daemon"] { Supervisor().start(); return }
            do {
                try locked {
                    var config = readJSON(configPath, as: Configuration.self) ?? Configuration()
                    var status = readJSON(statusPath, as: ServiceStatus.self) ?? ServiceStatus()
                    if args.count == 4, args[0] == "--configure", let minutes = Int(args[1]),
                        (1...1440).contains(minutes), ["battery", "all"].contains(args[2]),
                        let authorized = UInt32(args[3]), authorized > 0
                    {
                        if config.original.isEmpty {
                            config.original = modes(
                                from: runHelperCommand("/usr/bin/pmset", ["-g", "custom"]).output)
                            guard config.original["battery"] != nil, config.original["ac"] != nil
                            else {
                                throw NSError(
                                    domain: "SleepBridge", code: 1,
                                    userInfo: [NSLocalizedDescriptionKey: "无法读取原休眠模式；未修改设置"])
                            }
                            // Persist the backup before the first power-setting mutation.
                            try writeJSON(config, to: configPath)
                        }
                        cancelWake(&status)
                        config.authorizedUID = authorized; config.enabled = true;
                        config.minutes = minutes; config.scope = args[2]; config.request = "";
                        config.revision = UUID().uuidString
                        do { try applyRAM(config); try writeJSON(config, to: configPath) } catch {
                            try? restore(config); throw error
                        }
                        status.phase = "策略已应用"; status.detail = "等待后台服务确认"; status.updated = Date();
                        try writeJSON(status, to: statusPath)
                        record("启用策略：\(minutes) 分钟，范围 \(config.scope)")
                    } else if args == ["--disable"] {
                        cancelWake(&status); try restore(config)
                        config.enabled = false; config.original = [:]; config.request = "";
                        config.revision = UUID().uuidString
                        try writeJSON(config, to: configPath)
                        status = ServiceStatus(); status.detail = "已恢复启用前的休眠模式";
                        try writeJSON(status, to: statusPath); record("已停用并恢复原休眠模式")
                    } else if args == ["--hibernate-now"] && config.enabled {
                        config.request = "hibernate"; try writeJSON(config, to: configPath)
                    } else {
                        throw NSError(
                            domain: "SleepBridge", code: 2,
                            userInfo: [NSLocalizedDescriptionKey: "参数无效或策略未启用"])
                    }
                }
            } catch { fputs(error.localizedDescription + "\n", stderr); exit(1) }
        }
    }

#endif
