import Foundation
import idevice
import UIKit

enum HostIdentity {
    static let name = "Airlift"
    static let model = "Mac17,7"
}

/// Pairable host with caller-owned Bonjour, the AltStore/wloc shape:
/// `pairable_host_prepare` gives the identity and TXT records, we publish
/// `_remotepairing-pairable-host._tcp`, accept the device connection, and hand
/// the fd to `pairable_host_accept_fd`.
@MainActor
final class PairingHost: ObservableObject {
    enum Phase: Equatable {
        case idle
        case advertising
        case awaitingPIN(String)
        case paired
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var pin: String?

    private let audio = AudioKeepAlive()
    private var worker: Thread?
    private var task: UIBackgroundTaskIdentifier = .invalid
    private var listener: Int32 = -1
    private var service: NetService?
    private var host: OpaquePointer?
    private let box = CallbackBox()
    var onEvent: ((String) -> Void)?

    var busy: Bool {
        switch phase {
        case .advertising, .awaitingPIN: return true
        default: return false
        }
    }

    func start(store: PairingStore) {
        guard !busy else { return }
        phase = .advertising
        pin = nil
        box.owner = self
        audio.start()
        keepAwake()
        onEvent?("生成 host 身份")

        var handle: OpaquePointer?
        var serviceID: UnsafeMutablePointer<CChar>?
        var txt: UnsafeMutablePointer<UInt8>?
        var txtLength = 0
        var altIRK = [UInt8](repeating: 0, count: 16)

        let error: UnsafeMutablePointer<IdeviceFfiError>? = HostIdentity.name.withCString { name in
            HostIdentity.model.withCString { model in
                pairable_host_prepare(
                    name,
                    model,
                    false,
                    &handle,
                    &serviceID,
                    &txt,
                    &txtLength,
                    &altIRK
                )
            }
        }
        if let error {
            failed(FFI.message(error, "prepare") ?? "prepare 失败")
            return
        }
        guard let handle, let serviceID else {
            failed("prepare 没有返回句柄")
            return
        }
        host = handle
        let instance = String(cString: serviceID)
        idevice_string_free(serviceID)

        var records: [String: String] = [:]
        if let txt {
            let data = Data(bytes: txt, count: txtLength)
            idevice_data_free(txt, txtLength)
            records = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: String] ?? [:]
        }
        onEvent?("服务实例 \(instance)")
        onEvent?("TXT \(records.keys.sorted().joined(separator: ","))")

        guard let fd = Self.listenSocket() else {
            failed("监听 socket 失败 errno=\(errno)")
            return
        }
        listener = fd
        guard let port = Self.port(of: fd) else {
            failed("取端口失败")
            return
        }
        onEvent?("监听端口 \(port)")

        let netService = NetService(
            domain: "local.",
            type: "_remotepairing-pairable-host._tcp.",
            name: instance,
            port: Int(port)
        )
        netService.setTXTRecord(NetService.data(fromTXTRecord: records.mapValues { Data($0.utf8) }))
        netService.publish()
        service = netService
        onEvent?("已发布 Bonjour，去开发者设置里发起配对")

        let output = store.path
        let box = self.box
        worker = Thread {
            Self.acceptLoop(fd: fd, host: handle, outputPath: output, box: box)
        }
        worker?.name = "airlift.pairable-host"
        worker?.qualityOfService = .userInitiated
        worker?.start()
    }

    func reset() {
        teardown()
        phase = .idle
        pin = nil
    }

    fileprivate func received(pin value: String) {
        onEvent?("设备要配对码了")
        pin = value
        phase = .awaitingPIN(value)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    fileprivate func connected() {
        onEvent?("设备已连上监听端口，开始 pair-setup")
    }

    fileprivate func finished() {
        teardown()
        pin = nil
        phase = .paired
        onEvent?("配对完成，记录已写入")
    }

    fileprivate func failed(_ message: String) {
        teardown()
        pin = nil
        phase = .failed(message)
        onEvent?("配对失败: \(message)")
    }

    private func teardown() {
        service?.stop()
        service = nil
        if listener >= 0 {
            close(listener)
            listener = -1
        }
        audio.stop()
        releaseAwake()
    }

    private func keepAwake() {
        UIApplication.shared.isIdleTimerDisabled = true
        guard task == .invalid else { return }
        task = UIApplication.shared.beginBackgroundTask(withName: "airlift.pairing") { [weak self] in
            self?.releaseAwake()
        }
    }

    private func releaseAwake() {
        UIApplication.shared.isIdleTimerDisabled = false
        guard task != .invalid else { return }
        UIApplication.shared.endBackgroundTask(task)
        task = .invalid
    }

    nonisolated private static func listenSocket() -> Int32? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = 0

        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                bind(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(fd, 1) == 0 else {
            close(fd)
            return nil
        }
        return fd
    }

    nonisolated private static func port(of fd: Int32) -> UInt16? {
        var address = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let result = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                getsockname(fd, sockaddrPointer, &length)
            }
        }
        guard result == 0 else { return nil }
        return UInt16(bigEndian: address.sin_port)
    }

    nonisolated private static func acceptLoop(fd: Int32, host: OpaquePointer, outputPath: String, box: CallbackBox) {
        let client = accept(fd, nil, nil)
        close(fd)
        guard client >= 0 else {
            DispatchQueue.main.async { box.owner?.failed("accept 失败 errno=\(errno)") }
            pairable_host_free(host)
            return
        }
        DispatchQueue.main.async { box.owner?.connected() }

        var outFile: OpaquePointer?
        let error = pairable_host_accept_fd(
            host,
            client,
            pinTrampoline,
            Unmanaged.passUnretained(box).toOpaque(),
            nil,
            &outFile
        )
        close(client)
        pairable_host_free(host)

        if let error {
            let text = error.pointee.message.map { String(cString: $0) } ?? "code \(error.pointee.code)"
            idevice_error_free(error)
            DispatchQueue.main.async { box.owner?.failed(text) }
            return
        }
        guard let outFile else {
            DispatchQueue.main.async { box.owner?.failed("握手结束但没有记录") }
            return
        }
        defer { rp_pairing_file_free(outFile) }

        try? FileManager.default.createDirectory(
            atPath: (outputPath as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        if let writeError = outputPath.withCString({ rp_pairing_file_write(outFile, $0) }) {
            let text = writeError.pointee.message.map { String(cString: $0) } ?? "写入失败"
            idevice_error_free(writeError)
            DispatchQueue.main.async { box.owner?.failed(text) }
            return
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: outputPath)
        DispatchQueue.main.async { box.owner?.finished() }
    }
}

final class CallbackBox: @unchecked Sendable {
    weak var owner: PairingHost?
}

private func pinTrampoline(_ pin: UnsafePointer<CChar>?, _ context: UnsafeMutableRawPointer?) {
    guard let pin, let context else { return }
    let value = String(cString: pin)
    let box = Unmanaged<CallbackBox>.fromOpaque(context).takeUnretainedValue()
    DispatchQueue.main.async { box.owner?.received(pin: value) }
}
