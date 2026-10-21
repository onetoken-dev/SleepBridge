import Darwin
import Foundation

// Fire-and-forget power request: never wait for sleep completion on the IOKit run loop.
func spawnSleepRequest() throws -> pid_t {
    try spawnDetached("/usr/bin/pmset", arguments: ["sleepnow"])
}

/// Only compile-time test doubles choose a different executable; no runtime override is exposed.
func spawnDetached(_ executable: String, arguments: [String]) throws -> pid_t {
    var actions: posix_spawn_file_actions_t? = nil
    posix_spawn_file_actions_init(&actions); defer { posix_spawn_file_actions_destroy(&actions) }
    posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, "/dev/null", O_WRONLY, 0)
    posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0)
    let args: [UnsafeMutablePointer<CChar>?] = ([executable] + arguments).map { value in
        value.withCString { strdup($0) }
    }
    defer { args.forEach { free($0) } }
    var argv = args + [nil]
    var environment: [UnsafeMutablePointer<CChar>?] = [nil]
    var pid: pid_t = 0
    let result = argv.withUnsafeMutableBufferPointer { arguments in
        environment.withUnsafeMutableBufferPointer { env in
            posix_spawn(&pid, executable, &actions, nil, arguments.baseAddress!, env.baseAddress!)
        }
    }
    guard result == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(result)) }
    return pid
}
