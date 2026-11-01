import Foundation
import idevice
import UIKit

/// Fixed host identity presented to the device during pairing.
enum HostIdentity {
    static let name = "Airlift"
    static let model = "Mac17,7"
}

/// Runs the idevice pairable-host responder on a worker thread.
/// The device initiates pair-setup against the advertised host, which is how
/// an iPhone ends up holding a valid host pairing record without a Mac.
@MainActor
final class PairingHost: ObservableObject {
    enum Phase: Equatable {
        case idle
        case advertising
        case deviceConnected
        case awaitingPIN(String)
        case paired
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var pin: String?

    private let advertiser = PairableHostAdvertiser()
    private let audio = AudioKeepAlive()
    private var worker: Thread?
    private var task: UIBackgroundTaskIdentifier = .invalid
    private let box = CallbackBox()

    var busy: Bool {
        switch phase {
        case .advertising, .deviceConnected, .awaitingPIN: return true
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

        let output = store.path
        let box = self.box
        worker = Thread {
            Self.accept(outputPath: output, box: box)
        }
        worker?.name = "airlift.pairable-host"
        worker?.qualityOfService = .userInitiated
        worker?.start()
    }

    func reset() {
        advertiser.stop()
        audio.stop()
        releaseAwake()
        phase = .idle
        pin = nil
    }

    fileprivate func listening(port: UInt16, identifier: String, name: String, model: String,
                               authTag: String, ver: String, minVer: String) {
        advertiser.publish(port: port, serviceIdentifier: identifier, name: name,
                           model: model, authTag: authTag, ver: ver, minVer: minVer)
    }

    fileprivate func connected() { phase = .deviceConnected }

    fileprivate func received(pin value: String) {
        pin = value
        phase = .awaitingPIN(value)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    fileprivate func finished() {
        pin = nil
        phase = .paired
        advertiser.stop()
        audio.stop()
        releaseAwake()
    }

    fileprivate func failed(_ message: String) {
        pin = nil
        phase = .failed(message)
        advertiser.stop()
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

    nonisolated private static func accept(outputPath: String, box: CallbackBox) {
        var outFile: OpaquePointer?
        var altIRK = [UInt8](repeating: 0, count: 16)

        let error: UnsafeMutablePointer<IdeviceFfiError>? = HostIdentity.name.withCString { name in
            HostIdentity.model.withCString { model in
                pairable_host_accept(
                    name,
                    model,
                    0,
                    pinTrampoline,
                    Unmanaged.passUnretained(box).toOpaque(),
                    listeningTrampoline,
                    Unmanaged.passUnretained(box).toOpaque(),
                    connectedTrampoline,
                    Unmanaged.passUnretained(box).toOpaque(),
                    &altIRK,
                    &outFile
                )
            }
        }

        if let error {
            let text = error.pointee.message.map { String(cString: $0) } ?? "code \(error.pointee.code)"
            idevice_error_free(error)
            DispatchQueue.main.async { box.owner?.failed(text) }
            return
        }
        guard let outFile else {
            DispatchQueue.main.async { box.owner?.failed("pairing finished without a record") }
            return
        }
        defer { rp_pairing_file_free(outFile) }

        try? FileManager.default.createDirectory(
            atPath: (outputPath as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        if let writeError = outputPath.withCString({ rp_pairing_file_write(outFile, $0) }) {
            let text = writeError.pointee.message.map { String(cString: $0) } ?? "write failed"
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

private func listeningTrampoline(
    _ port: UInt16,
    _ identifier: UnsafePointer<CChar>?,
    _ name: UnsafePointer<CChar>?,
    _ model: UnsafePointer<CChar>?,
    _ authTag: UnsafePointer<CChar>?,
    _ ver: UnsafePointer<CChar>?,
    _ minVer: UnsafePointer<CChar>?,
    _ context: UnsafeMutableRawPointer?
) {
    guard let context else { return }
    let box = Unmanaged<CallbackBox>.fromOpaque(context).takeUnretainedValue()
    let identifier = identifier.map { String(cString: $0) } ?? "airlift"
    let name = name.map { String(cString: $0) } ?? HostIdentity.name
    let model = model.map { String(cString: $0) } ?? HostIdentity.model
    let authTag = authTag.map { String(cString: $0) } ?? ""
    let ver = ver.map { String(cString: $0) } ?? "26"
    let minVer = minVer.map { String(cString: $0) } ?? "17"
    DispatchQueue.main.async {
        box.owner?.listening(port: port, identifier: identifier, name: name,
                             model: model, authTag: authTag, ver: ver, minVer: minVer)
    }
}

private func connectedTrampoline(_ context: UnsafeMutableRawPointer?) {
    guard let context else { return }
    let box = Unmanaged<CallbackBox>.fromOpaque(context).takeUnretainedValue()
    DispatchQueue.main.async { box.owner?.connected() }
}
