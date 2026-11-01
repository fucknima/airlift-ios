import Darwin
import Foundation
import idevice

/// Small helpers around the C surface of the idevice FFI.
enum FFI {
    /// Frees an FFI error and turns it into a log line.
    static func message(_ error: UnsafeMutablePointer<IdeviceFfiError>?, _ context: String) -> String? {
        guard let error else { return nil }
        let text: String
        if let raw = error.pointee.message {
            text = String(cString: raw)
        } else {
            text = "code \(error.pointee.code)/\(error.pointee.sub_code)"
        }
        idevice_error_free(error)
        return "\(context): \(text)"
    }

    /// Builds an IPv4 sockaddr for the tunnel entry point.
    static func makeSockaddr(_ address: String, port: UInt16) -> (sin: sockaddr_in, len: socklen_t)? {
        var sin = sockaddr_in()
        sin.sin_family = sa_family_t(AF_INET)
        sin.sin_port = port.bigEndian
        guard inet_pton(AF_INET, address, &sin.sin_addr) == 1 else { return nil }
        return (sin, socklen_t(MemoryLayout<sockaddr_in>.size))
    }

    /// Runs `body` with a sockaddr pointer valid for the duration of the call.
    static func withSockaddr<T>(
        _ address: String,
        port: UInt16,
        _ body: (UnsafePointer<sockaddr>, socklen_t) -> T
    ) -> T? {
        guard var pair = makeSockaddr(address, port: port) else { return nil }
        return withUnsafePointer(to: &pair.sin) { raw in
            body(UnsafeRawPointer(raw).assumingMemoryBound(to: sockaddr.self), pair.len)
        }
    }
}
