import Foundation
import idevice
import UIKit

/// Fixed host identity presented to the device during pairing.
enum HostIdentity {
    static let name = "Airlift"
    static let model = "Mac17,7"
}

/// Runs the idevice pairable-host responder on a worker thread.
///
/// The current idevice FFI advertises `_remotepairing-pairable-host._tcp` from
/// the Rust side and blocks until the device completes pair-setup or the token
/// is cancelled. The PIN is generated there and typed into the device sheet.
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
    private var cancelToken: OpaquePointer?
    private let box = CallbackBox()

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

        let token = pairable_host_cancel_new()
        cancelToken = token

        let output = store.path
        let box = self.box
        worker = Thread {
            Self.accept(outputPath: output, box: box, cancel: token)
        }
        worker?.name = "airlift.pairable-host"
        worker?.qualityOfService = .userInitiated
        worker?.start()
    }

    func reset() {
        if let cancelToken {
            pairable_host_cancel_signal(cancelToken)
            pairable_host_cancel_free(cancelToken)
            self.cancelToken = nil
        }
        audio.stop()
        releaseAwake()
        phase = .idle
        pin = nil
    }

    fileprivate func received(pin value: String) {
        pin = value
        phase = .awaitingPIN(value)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    fileprivate func finished() {
        releaseCancel()
        pin = nil
        phase = .paired
        audio.stop()
        releaseAwake()
    }

    fileprivate func failed(_ message: String) {
        releaseCancel()
        pin = nil
        phase = .failed(message)
        audio.stop()
        releaseAwake()
    }

    private func releaseCancel() {
        if let cancelToken {
            pairable_host_cancel_free(cancelToken)
            self.cancelToken = nil
        }
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

    nonisolated private static func accept(outputPath: String, box: CallbackBox, cancel: OpaquePointer?) {
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
                    cancel,
                    &altIRK,
                    nil,
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
