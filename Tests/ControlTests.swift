import Darwin
import Foundation

@main struct ControlTests {
    static func main() {
        let root = "/tmp/sleepbridge-tests-" + String(UUID().uuidString.prefix(12))
        try! FileManager.default.createDirectory(
            atPath: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(atPath: root) }
        let path = root + "/test.sock"
        unlink(path); defer { unlink(path) }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0); defer { close(fd) }
        var address = socketAddress(path)
        precondition(
            withUnsafePointer(to: &address) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            } == 0)
        precondition(listen(fd, 2) == 0)
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            for expected in ["ping", "hibernate"] {
                let peer = accept(fd, nil, nil); precondition(peer >= 0)
                var uid: uid_t = 0, gid: gid_t = 0
                precondition(getpeereid(peer, &uid, &gid) == 0 && uid == getuid())
                var bytes = [UInt8](repeating: 0, count: 64)
                let count = read(peer, &bytes, bytes.count)
                precondition(String(decoding: bytes.prefix(count), as: UTF8.self) == expected)
                let reply = Data((expected == "ping" ? helperGreeting : "ERR 策略未启用").utf8)
                _ = reply.withUnsafeBytes { write(peer, $0.baseAddress, $0.count) }; close(peer)
            }
            done.signal()
        }
        precondition(connectControl("ping", path: path).code == 0)
        precondition(connectControl("hibernate", path: path).code != 0)
        precondition(done.wait(timeout: .now() + 3) == .success)
        precondition(connectControl("ping", path: path + ".missing").code == 2)
        print(
            "PASS: local socket roundtrip, kernel peer UID, rejected request propagation, unavailable-service migration hint. No power commands executed."
        )
    }
}
