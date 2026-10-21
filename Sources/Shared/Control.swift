import Darwin
import Foundation

let controlSocket = supportPath + "/control.sock"
func socketAddress(_ path: String) -> sockaddr_un {
    var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    withUnsafeMutableBytes(of: &address.sun_path) { buffer in
        buffer.initializeMemory(as: UInt8.self, repeating: 0)
        let bytes = Array(path.utf8) + [0]
        precondition(bytes.count <= buffer.count)
        buffer.copyBytes(from: bytes)
    }
    return address
}
func connectControl(_ command: String, path: String = controlSocket) -> CommandResult {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return CommandResult(code: 1, output: "无法创建本地连接") }
    defer { close(fd) }
    var timeout = timeval(tv_sec: 5, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    var noSignal: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
    var address = socketAddress(path)
    let connected = withUnsafePointer(to: &address) { ptr in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard connected == 0 else {
        return CommandResult(code: 2, output: "无法连接后台控制接口。服务可能未运行、未就绪或连接队列阻塞；这并不表示升级未完成。请查看后台服务状态。")
    }
    let data = Data(command.utf8)
    let sent = data.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
    guard sent == data.count else { return CommandResult(code: 3, output: "本地请求发送失败") }
    var bytes = [UInt8](repeating: 0, count: 512)
    let count = read(fd, &bytes, bytes.count)
    guard count > 0 else {
        return CommandResult(code: 4, output: "后台控制接口响应超时；这不是管理员密码错误。请查看后台服务状态和诊断日志。")
    }
    let response = String(decoding: bytes.prefix(count), as: UTF8.self)
    return CommandResult(code: response.hasPrefix("OK") ? 0 : 5, output: response)
}
