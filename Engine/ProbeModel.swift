import Foundation
import SwiftUI

@MainActor
final class ProbeModel: ObservableObject {
    @Published var lines: [String] = []
    @Published var busy = false
    @Published var services: [RSDService] = []
    @Published var afc: AFCReport?
    @Published var hasRecord = false
    @Published var recordSize = 0
    @Published var showPicker = false
    @Published var error: String?
    @Published var host = Endpoint.load().host
    @Published var portText = String(Endpoint.load().port)
    @Published var candidates: [String] = []

    let pairing = PairingHost()
    let store = PairingStore()
    private let link = TunnelLink()
    private var started = false

    var endpoint: Endpoint {
        let port = UInt16(portText.trimmingCharacters(in: .whitespaces)) ?? Endpoint.fallback.port
        return Endpoint(host: host.trimmingCharacters(in: .whitespaces), port: port)
    }

    func start() {
        guard !started else { return }
        started = true
        candidates = EndpointProbe.candidates()
        pairing.onEvent = { [weak self] text in self?.log(text) }
        refresh()
    }

    func refresh() {
        hasRecord = store.exists
        recordSize = store.size
    }

    func saveEndpoint() {
        endpoint.save()
    }

    func log(_ text: String) {
        let stamp = Self.formatter.string(from: Date())
        lines.append("[\(stamp)] \(text)")
        if lines.count > 500 { lines.removeFirst(lines.count - 500) }
        NSLog("[airlift] %@", text)
    }

    func pair() {
        refresh()
        log("开始本机配对，等待系统配对面板")
        pairing.start(store: store)
    }

    func resetPairing() {
        pairing.reset()
        log("配对已取消")
    }

    func probe() {
        let endpoint = endpoint
        saveEndpoint()
        guard !busy else { return }
        busy = true
        log("TCP 探测 \(endpoint.label)")
        Task.detached {
            let result = EndpointProbe.tcp(endpoint)
            await MainActor.run {
                self.log("探测结果: \(result)")
                self.busy = false
            }
        }
    }

    func connect() {
        guard !busy else { return }
        refresh()
        let endpoint = endpoint
        saveEndpoint()

        guard store.exists else {
            error = "没有配对记录，先在本机配对，或导入配对文件"
            log("连接中止: 没有配对记录")
            return
        }

        busy = true
        error = nil
        log("隧道目标 \(endpoint.label)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
            guard let self, self.busy else { return }
            self.log("20 秒仍未完成握手，这个端口可能不是 RPPairing 服务")
        }
        Task.detached { [link, store] in
            let probe = EndpointProbe.tcp(endpoint)
            await MainActor.run { self.log("探测结果: \(probe)") }
            guard probe == "TCP 已连通" else {
                await MainActor.run {
                    self.error = "端口不通: \(probe)"
                    self.busy = false
                }
                return
            }

            do {
                await MainActor.run { self.log("TCP 通了，开始 RPPairing 握手") }
                let list = try link.connect(store: store, host: endpoint.host, port: endpoint.port)
                await MainActor.run {
                    self.services = list
                    self.log("rsd: \(list.count) 个服务")
                    for service in list where service.name.contains("shim") || service.name.contains("afc") || service.name.contains("fileservice") {
                        self.log("  \(service.name) port=\(service.port)\(service.remoteXPC ? " xpc" : "")")
                    }
                    self.busy = false
                    self.refresh()
                }
            } catch {
                await MainActor.run {
                    self.error = error.localizedDescription
                    self.log("连接失败: \(error.localizedDescription)")
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
                    self.log("afc 失败: \(error.localizedDescription)")
                    self.busy = false
                }
            }
        }
    }

    func probeZip() {
        guard !busy else { return }
        busy = true
        log("探测 shim: RSDCheckin + StartService")
        Task.detached { [link] in
            do {
                let service = "com.apple.streaming_zip_conduit.shim.remote"
                guard let port = try link.port(of: service) else {
                    throw LinkError.shim("服务列表里没有 zip shim")
                }
                let result = try link.withAdapter { adapter -> String in
                    let stream = try ShimStream(adapter: adapter, port: port)
                    defer { stream.close() }
                    let label = UUID().uuidString
                    let base: [String: Any] = ["Label": label, "ProtocolVersion": 2]
                    var checkin = base
                    checkin["Request"] = "RSDCheckin"
                    try stream.send(try PlistFrame.encode(checkin))
                    let ack = try stream.recvFrame()
                    guard let ackObject = PlistFrame.decode(ack) else {
                        return "checkin hex=\(Hex.dump(ack))"
                    }

                    var start = base
                    start["Request"] = "StartService"
                    start["Service"] = service
                    try stream.send(try PlistFrame.encode(start))
                    let reply = try stream.recvFrame()
                    guard let object = PlistFrame.decode(reply) as? [String: Any] else {
                        return "checkin=\(ackObject) start hex=\(Hex.dump(reply))"
                    }
                    if let rawPort = object["Port"] as? Int, rawPort > 0, rawPort < 65536 {
                        let next = try ShimStream(adapter: adapter, port: UInt16(rawPort))
                        defer { next.close() }
                        try next.send(try PlistFrame.encode(["MediaSubdir": "airlift-probe"]))
                        let body = try next.recvFrame()
                        let text = PlistFrame.decode(body).map { "\($0)" } ?? Hex.dump(body)
                        return "start=\(object) port=\(rawPort) zip=\(text)"
                    }
                    try stream.send(try PlistFrame.encode(["MediaSubdir": "airlift-probe"]))
                    let body = try stream.recvFrame()
                    let text = PlistFrame.decode(body).map { "\($0)" } ?? Hex.dump(body)
                    return "start=\(object) samePort zip=\(text)"
                }
                await MainActor.run {
                    self.log("shim 探测: \(result)")
                    self.busy = false
                }
            } catch {
                await MainActor.run {
                    self.log("shim 探测失败: \(error.localizedDescription)")
                    self.busy = false
                }
            }
        }
    }

    func importRecord(_ url: URL) {
        do {
            try store.importRecord(from: url)
            refresh()
            pairing.reset()
            log("配对记录已导入，\(recordSize) 字节")
            log("记录字段: \(store.describe())")
            connect()
        } catch {
            self.error = error.localizedDescription
            log("导入失败: \(error.localizedDescription)")
        }
    }

    func importClipboard() {
        let text = UIPasteboard.general.string ?? ""
        do {
            try store.importRecord(from: text)
            refresh()
            pairing.reset()
            log("配对记录已从剪贴板导入，\(recordSize) 字节")
            log("记录字段: \(store.describe())")
            connect()
        } catch {
            self.error = error.localizedDescription
            log("剪贴板导入失败: \(error.localizedDescription)")
        }
    }

    func removeRecord() {
        do {
            try store.remove()
            link.close()
            services = []
            afc = nil
            refresh()
            log("配对记录已删除")
        } catch {
            self.error = error.localizedDescription
        }
    }

    func clearLog() { lines.removeAll() }

    var logText: String { lines.joined(separator: "\n") }
    var recordText: String { hasRecord ? "已保存 \(recordSize) 字节" : "没有" }

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}
