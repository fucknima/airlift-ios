import Foundation
import SwiftUI

@MainActor
final class ProbeModel: ObservableObject {
    @Published var lines: [String] = []
    @Published var busy = false
    @Published var services: [RSDService] = []
    @Published var afc: AFCReport?
    @Published var vpnConnected = false
    @Published var hasRecord = false
    @Published var showImporter = false
    @Published var error: String?

    let pairing = PairingHost()
    let store = PairingStore()
    private let link = TunnelLink()
    private var started = false

    var recordExists: Bool { store.exists }

    func start() {
        guard !started else { return }
        started = true
        refresh()
    }

    func refresh() {
        hasRecord = store.exists
        vpnConnected = LocalDevVPN.isConnected
    }

    func log(_ text: String) {
        let stamp = Self.formatter.string(from: Date())
        lines.append("[\(stamp)] \(text)")
        if lines.count > 400 { lines.removeFirst(lines.count - 400) }
        NSLog("[airlift] %@", text)
    }

    func pair() {
        refresh()
        pairing.start(store: store)
        log("pairable host started; confirm the code on the iPhone pairing sheet")
    }

    func openVPN() {
        LocalDevVPN.openOrInstall()
        log("asked LocalDevVPN to connect")
    }

    func connect() {
        guard !busy else { return }
        refresh()
        busy = true
        error = nil
        log("tunnel → \(TunnelEndpoint.host):\(TunnelEndpoint.port)")
        Task.detached { [link, store] in
            do {
                let list = try link.connect(store: store)
                await MainActor.run {
                    self.services = list
                    self.log("rsd: \(list.count) services")
                    for service in list where service.name.contains("shim") || service.name.contains("afc") || service.name.contains("fileservice") {
                        self.log("  \(service.name) port=\(service.port)\(service.remoteXPC ? " xpc" : "")")
                    }
                    self.busy = false
                    self.refresh()
                }
            } catch {
                await MainActor.run {
                    self.error = error.localizedDescription
                    self.log("connect failed: \(error.localizedDescription)")
                    self.busy = false
                }
            }
        }
    }

    func runAFC() {
        guard !busy else { return }
        busy = true
        Task.detached { [link] in
            do {
                let report = try link.afcReport()
                await MainActor.run {
                    self.afc = report
                    self.log("afc: model=\(report.model) total=\(report.totalBytes) free=\(report.freeBytes)")
                    self.busy = false
                }
            } catch {
                await MainActor.run {
                    self.error = error.localizedDescription
                    self.log("afc failed: \(error.localizedDescription)")
                    self.busy = false
                }
            }
        }
    }

    func importRecord(_ url: URL) {
        do {
            try store.importRecord(from: url)
            refresh()
            log("pairing record imported")
        } catch {
            self.error = error.localizedDescription
            log("import failed: \(error.localizedDescription)")
        }
    }

    func removeRecord() {
        do {
            try store.remove()
            link.close()
            services = []
            afc = nil
            refresh()
            log("pairing record removed")
        } catch {
            self.error = error.localizedDescription
        }
    }

    func clearLog() { lines.removeAll() }

    var logText: String { lines.joined(separator: "\n") }

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}
