import Foundation
import idevice

struct RSDService: Identifiable, Hashable {
    let name: String
    let port: UInt16
    let remoteXPC: Bool
    let entitlement: String

    var id: String { name }
}

struct AFCReport {
    let model: String
    let totalBytes: UInt64
    let freeBytes: UInt64
}

enum LinkError: LocalizedError {
    case noPairing
    case record(String)
    case tunnel(String)
    case handshake(String)
    case afc(String)
    case shim(String)

    var errorDescription: String? {
        switch self {
        case .noPairing: return "no pairing record; pair on this iPhone or import one"
        case .record(let text): return "pairing record: \(text)"
        case .tunnel(let text): return "tunnel: \(text)"
        case .handshake(let text): return "rsd: \(text)"
        case .afc(let text): return "afc: \(text)"
        case .shim(let text): return "shim: \(text)"
        }
    }
}

/// Owns the RPPairing tunnel and the RSD handshake. All FFI calls go through
/// one serial queue: adapter streams are not thread safe.
final class TunnelLink: @unchecked Sendable {
    private let queue = DispatchQueue(label: "airlift.tunnel")
    private var adapter: OpaquePointer?
    private var handshake: OpaquePointer?
    private var record: OpaquePointer?

    var isConnected: Bool { queue.sync { handshake != nil } }

    /// Connects to the loopback developer tunnel and performs RSD checkin.
    func connect(store: PairingStore, host: String = Endpoint.fallback.host,
                 port: UInt16 = Endpoint.fallback.port, hostname: String = HostIdentity.name) throws -> [RSDService] {
        try queue.sync {
            closeOnQueue()
            guard store.exists else { throw LinkError.noPairing }

            var pairing: OpaquePointer?
            if let error = store.path.withCString({ rp_pairing_file_read($0, &pairing) }) {
                throw LinkError.record(FFI.message(error, "read") ?? "read failed")
            }
            guard let pairing else { throw LinkError.record("empty handle") }
            record = pairing

            var failure = "no adapter"
            for remoteXPC in [false, true] {
                var outAdapter: OpaquePointer?
                var outHandshake: OpaquePointer?
                guard let result = FFI.withSockaddr(host, port: port, { address, length in
                    hostname.withCString { name in
                        if remoteXPC {
                            return tunnel_create_remotexpc(address, length, name, pairing,
                                                           nil, nil, &outAdapter, &outHandshake)
                        }
                        return tunnel_create_rppairing(address, length, name, pairing,
                                                       nil, nil, &outAdapter, &outHandshake)
                    }
                }) else {
                    throw LinkError.tunnel("bad address \(host)")
                }

                if let error = result {
                    failure = FFI.message(error, remoteXPC ? "remotexpc" : "rppairing") ?? "create failed"
                    continue
                }
                guard let outAdapter, let outHandshake else { continue }
                adapter = outAdapter
                handshake = outHandshake

                // pair-verify can refresh the record; write it back.
                _ = store.path.withCString { rp_pairing_file_write(pairing, $0) }
                return try servicesOnQueue()
            }
            throw LinkError.tunnel(failure)
        }
    }

    func services() throws -> [RSDService] {
        try queue.sync { try servicesOnQueue() }
    }

    func afcReport() throws -> AFCReport {
        try queue.sync {
            guard let adapter, let handshake else { throw LinkError.tunnel("not connected") }
            var client: OpaquePointer?
            if let error = afc_client_connect_rsd(adapter, handshake, &client) {
                throw LinkError.afc(FFI.message(error, "connect") ?? "connect failed")
            }
            guard let client else { throw LinkError.afc("no client") }
            defer { afc_client_free(client) }

            var info = AfcDeviceInfo()
            if let error = afc_get_device_info(client, &info) {
                throw LinkError.afc(FFI.message(error, "info") ?? "info failed")
            }
            defer { afc_device_info_free(&info) }

            return AFCReport(
                model: info.model.map { String(cString: $0) } ?? "?",
                totalBytes: UInt64(info.total_bytes),
                freeBytes: UInt64(info.free_bytes)
            )
        }
    }

    func withAFC<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
        try queue.sync {
            guard let adapter, let handshake else { throw LinkError.tunnel("not connected") }
            var client: OpaquePointer?
            if let error = afc_client_connect_rsd(adapter, handshake, &client) {
                throw LinkError.afc(FFI.message(error, "connect") ?? "connect failed")
            }
            guard let client else { throw LinkError.afc("no client") }
            defer { afc_client_free(client) }
            return try body(client)
        }
    }

    /// Runs `body` on the tunnel queue, where adapter streams must live.
    func withAdapter<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
        try queue.sync {
            guard let adapter else { throw LinkError.tunnel("not connected") }
            return try body(adapter)
        }
    }

    func port(of service: String) throws -> UInt16? {
        try queue.sync { try servicesOnQueue().first { $0.name == service }?.port }
    }

    func close() {
        queue.sync { closeOnQueue() }
    }

    private func servicesOnQueue() throws -> [RSDService] {
        guard let handshake else { throw LinkError.handshake("not connected") }
        var array: UnsafeMutablePointer<CRsdServiceArray>?
        if let error = rsd_get_services(handshake, &array) {
            throw LinkError.handshake(FFI.message(error, "services") ?? "services failed")
        }
        guard let array else { return [] }
        defer { rsd_free_services(array) }

        return (0..<Int(array.pointee.count)).compactMap { index in
            guard let raw = array.pointee.services else { return nil }
            let service = raw[index]
            guard let name = service.name else { return nil }
            return RSDService(
                name: String(cString: name),
                port: service.port,
                remoteXPC: service.uses_remote_xpc,
                entitlement: service.entitlement.map { String(cString: $0) } ?? ""
            )
        }.sorted { $0.name < $1.name }
    }

    private func closeOnQueue() {
        if let handshake { rsd_handshake_free(handshake) }
        if let adapter { adapter_free(adapter) }
        if let record { rp_pairing_file_free(record) }
        handshake = nil
        adapter = nil
        record = nil
    }
}
