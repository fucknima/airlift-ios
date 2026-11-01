import Foundation
import idevice

/// A shim service stream over the tunnel adapter.
final class ShimStream {
    private var handle: OpaquePointer?

    init(adapter: OpaquePointer, port: UInt16) throws {
        var out: OpaquePointer?
        if let error = adapter_connect_stream(adapter, port, &out) {
            throw LinkError.shim(FFI.message(error, "connect") ?? "connect failed")
        }
        guard let out else { throw LinkError.shim("no stream") }
        handle = out
    }

    deinit { close() }

    func close() {
        if let handle {
            _ = adapter_stream_close(handle)
            self.handle = nil
        }
    }

    func send(_ data: Data) throws {
        guard let handle else { throw LinkError.shim("closed") }
        let error = data.withUnsafeBytes { raw in
            adapter_send(handle, raw.bindMemory(to: UInt8.self).baseAddress, UInt(data.count))
        }
        if let error { throw LinkError.shim(FFI.message(error, "send") ?? "send failed") }
    }

    func recv(max: Int = 8192) throws -> Data {
        guard let handle else { throw LinkError.shim("closed") }
        var buffer = [UInt8](repeating: 0, count: max)
        var length: UInt = 0
        let error = buffer.withUnsafeMutableBufferPointer { raw in
            adapter_recv(handle, raw.baseAddress, &length, UInt(max))
        }
        if let error { throw LinkError.shim(FFI.message(error, "recv") ?? "recv failed") }
        return Data(buffer.prefix(Int(length)))
    }
}

enum PlistFrame {
    /// 4-byte big-endian length + binary plist body, the shape host.m gets
    /// from `AMDServiceConnectionSendMessage`.
    static func encode(_ object: Any) throws -> Data {
        let body = try PropertyListSerialization.data(fromPropertyList: object, format: .binary, options: 0)
        var length = UInt32(body.count).bigEndian
        var frame = Data(bytes: &length, count: MemoryLayout<UInt32>.size)
        frame.append(body)
        return frame
    }

    static func decode(_ data: Data) -> Any? {
        guard data.count > 4 else { return nil }
        let length = data.prefix(4).withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
        guard data.count >= 4 + Int(length) else { return nil }
        let body = data.subdata(in: 4..<(4 + Int(length)))
        return try? PropertyListSerialization.propertyList(from: body, options: [], format: nil)
    }
}

enum Hex {
    static func dump(_ data: Data, limit: Int = 96) -> String {
        data.prefix(limit).map { String(format: "%02x", $0) }.joined()
    }
}
