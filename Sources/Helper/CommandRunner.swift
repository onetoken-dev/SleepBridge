import Darwin
import Foundation

/// A bounded, non-reentrant subprocess wait. Foundation Process.waitUntilExit pumps
/// the caller's run loop, which can reenter reload() while it already owns flock.
func runHelperCommand(_ executable: String, _ arguments: [String], timeout: Double = 3)
    -> CommandResult
{
    var descriptors: [Int32] = [0, 0]
    guard pipe(&descriptors) == 0 else { return CommandResult(code: -1, output: "pipe failed") }
    let reader = descriptors[0], writer = descriptors[1]
    defer { close(reader) }
    _ = fcntl(reader, F_SETFL, O_NONBLOCK)
    _ = fcntl(reader, F_SETFD, FD_CLOEXEC)
    _ = fcntl(writer, F_SETFD, FD_CLOEXEC)
    var actions: posix_spawn_file_actions_t? = nil
    posix_spawn_file_actions_init(&actions)
    defer { posix_spawn_file_actions_destroy(&actions) }
    posix_spawn_file_actions_adddup2(&actions, writer, STDOUT_FILENO)
    posix_spawn_file_actions_adddup2(&actions, writer, STDERR_FILENO)
    posix_spawn_file_actions_addclose(&actions, reader)
    posix_spawn_file_actions_addclose(&actions, writer)
    var attributes: posix_spawnattr_t? = nil
    posix_spawnattr_init(&attributes)
    defer { posix_spawnattr_destroy(&attributes) }
    posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT))
    let strings = ([executable] + arguments).map { value in value.withCString { strdup($0) } }
    defer { strings.forEach { free($0) } }
    var argv = strings + [nil]
    var environment: [UnsafeMutablePointer<CChar>?] = [nil]
    var pid: pid_t = 0
    let spawned = argv.withUnsafeMutableBufferPointer { args in
        environment.withUnsafeMutableBufferPointer { env in
            posix_spawn(
                &pid, executable, &actions, &attributes, args.baseAddress!, env.baseAddress!)
        }
    }
    close(writer)
    guard spawned == 0 else { return CommandResult(code: -1, output: "spawn failed: \(spawned)") }
    let deadline = ProcessInfo.processInfo.systemUptime + timeout
    var output = Data(), status: Int32 = 0
    var finished = false, eof = false
    var buffer = [UInt8](repeating: 0, count: 8192)
    while !(finished && eof) {
        for _ in 0..<32 {
            let count = read(reader, &buffer, buffer.count)
            if count > 0 {
                output.append(contentsOf: buffer.prefix(count))
                if output.count > 4_194_304 { output = Data(output.suffix(4_194_304)) }
            } else {
                if count == 0 { eof = true }
                break
            }
        }
        if !finished { finished = waitpid(pid, &status, WNOHANG) == pid }
        if ProcessInfo.processInfo.systemUptime >= deadline {
            if !finished { kill(pid, SIGKILL); _ = waitpid(pid, &status, 0) }
            return CommandResult(code: 124, output: "Command timed out after \(timeout) s")
        }
        if !(finished && eof) {
            var descriptor = pollfd(fd: reader, events: Int16(POLLIN | POLLHUP), revents: 0)
            if eof { _ = poll(nil, 0, 10) } else { _ = poll(&descriptor, 1, 10) }
        }
    }
    let code = (status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
    return CommandResult(code: code, output: String(decoding: output, as: UTF8.self))
}

struct WakeEvidence {
    var date: Date
    var userInitiated: Bool
}
func latestWakeEvidence(_ log: String, notBefore: Date) -> WakeEvidence? {
    let pattern =
        #"^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2} [+-]\d{4})\s+(?:Wake|DarkWake)\s+((?:(?:Dark)?Wake from|DarkWake to FullWake from).*)$"#
    let regex = try! NSRegularExpression(pattern: pattern)
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
    for line in log.components(separatedBy: .newlines).reversed() {
        let text = line as NSString
        guard
            let match = regex.firstMatch(
                in: line, range: NSRange(location: 0, length: text.length)),
            let date = formatter.date(from: text.substring(with: match.range(at: 1))),
            date >= notBefore
        else { continue }
        let reason = text.substring(with: match.range(at: 2)).lowercased()
        let user = [
            " lid", "trackpad", "keyboard", "pwrbutton", "powerbutton", "hid activity",
            "useractivity",
        ].contains { reason.contains($0) }
        return WakeEvidence(date: date, userInitiated: user)
    }
    return nil
}
