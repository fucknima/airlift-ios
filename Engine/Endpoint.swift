import Darwin
import Foundation

/// Where the loopback tool exposes the device's own developer services.
struct Endpoint: Equatable {
    var host: String
    var port: UInt16

    static let fallback = Endpoint(host: "10.7.0.1", port: 49152)

    var label: String { "\(host):\(port)" }

    static func load() -> Endpoint {
        let defaults = UserDefaults.standard
        let host = defaults.string(forKey: "airlift.endpoint.host") ?? fallback.host
        let port = defaults.object(forKey: "airlift.endpoint.port") as? Int ?? Int(fallback.port)
        return Endpoint(host: host, port: UInt16(clamping: port))
    }

    func save() {
        let defaults = UserDefaults.standard
        defaults.set(host, forKey: "airlift.endpoint.host")
        defaults.set(Int(port), forKey: "airlift.endpoint.port")
    }
}

/// A TCP preflight so a wrong endpoint fails in seconds instead of hanging
/// inside the RPPairing handshake.
enum EndpointProbe {
    static func tcp(_ endpoint: Endpoint, timeoutMilliseconds: Int32 = 2500) -> String {
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = endpoint.port.bigEndian
        guard inet_pton(AF_INET, endpoint.host, &address.sin_addr) == 1 else {
            return "地址无效: \(endpoint.host)"
        }

        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return "socket 失败 errno=\(errno)" }
        defer { close(fd) }

        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

        let result = withUnsafePointer(to: &address) { pointer -> Int32 in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                connect(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if result == 0 { return "TCP 已连通" }
        guard errno == EINPROGRESS else { return "connect 失败 errno=\(errno)" }

        var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        let ready = poll(&descriptor, 1, timeoutMilliseconds)
        if ready == 0 { return "连接超时 \(timeoutMilliseconds)ms" }
        if ready < 0 { return "poll 失败 errno=\(errno)" }

        var socketError: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(fd, SOL_SOCKET, SO_ERROR, &socketError, &length)
        return socketError == 0 ? "TCP 已连通" : "connect 失败 errno=\(socketError)"
    }

    /// Candidate addresses worth trying with the loopback tool.
    static func candidates() -> [String] {
        var values = ["10.7.0.1", "127.0.0.1"]
        for address in localIPv4Addresses() where !values.contains(address) {
            values.append(address)
        }
        return values
    }

    static func localIPv4Addresses() -> [String] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }

        var result: [String] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let current = cursor {
            let interface = current.pointee
            if let address = interface.ifa_addr, address.pointee.sa_family == UInt8(AF_INET) {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(address, socklen_t(MemoryLayout<sockaddr_in>.size),
                               &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                    let value = String(cString: host)
                    if value != "0.0.0.0" { result.append(value) }
                }
            }
            cursor = interface.ifa_next
        }
        return result
    }
}
