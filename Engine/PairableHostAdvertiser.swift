import Foundation
import Network

/// Advertises `_remotepairing-pairable-host._tcp` and relays the inbound
/// developer-mode connection to the Rust listener on 127.0.0.1.
/// Adapted from Locus (MIT).
final class PairableHostAdvertiser {
    private var listener: NWListener?
    private var relay: RelayPipe?
    private var loopbackPort: UInt16 = 0

    func publish(
        port: UInt16,
        serviceIdentifier: String,
        name: String,
        model: String,
        authTag: String,
        ver: String,
        minVer: String
    ) {
        stop()
        loopbackPort = port

        var txt = NWTXTRecord()
        txt["name"] = name
        txt["identifier"] = serviceIdentifier
        txt["authTag"] = authTag
        txt["model"] = model
        txt["flags"] = "1"
        txt["ver"] = ver
        txt["minVer"] = minVer

        do {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            parameters.includePeerToPeer = true

            let listener = try NWListener(using: parameters)
            listener.service = NWListener.Service(
                name: serviceIdentifier,
                type: "_remotepairing-pairable-host._tcp",
                domain: "local",
                txtRecord: txt
            )
            listener.stateUpdateHandler = { state in
                if case .ready = state {
                    NSLog("[airlift] pairable host advertised on %u", listener.port?.rawValue ?? 0)
                }
                if case .failed(let error) = state {
                    NSLog("[airlift] listener failed: %@", String(describing: error))
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                NSLog("[airlift] pairing connection from %@", String(describing: connection.endpoint))
                self?.connectRelay(connection)
            }
            listener.start(queue: .global(qos: .userInitiated))
            self.listener = listener
        } catch {
            NSLog("[airlift] listener start failed: %@", error.localizedDescription)
        }
    }

    func stop() {
        relay?.cancel()
        relay = nil
        listener?.cancel()
        listener = nil
    }

    private func connectRelay(_ inbound: NWConnection) {
        relay?.cancel()
        guard loopbackPort > 0, let port = NWEndpoint.Port(rawValue: loopbackPort) else {
            inbound.cancel()
            return
        }
        let outbound = NWConnection(host: .init("127.0.0.1"), port: port, using: .tcp)
        let pipe = RelayPipe(inbound: inbound, outbound: outbound)
        relay = pipe
        pipe.start()
    }
}

private final class RelayPipe {
    private let inbound: NWConnection
    private let outbound: NWConnection
    private let queue = DispatchQueue(label: "airlift.pairable.relay")

    init(inbound: NWConnection, outbound: NWConnection) {
        self.inbound = inbound
        self.outbound = outbound
    }

    func start() {
        inbound.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.cancel()
            default: break
            }
        }
        outbound.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.pump(from: self.inbound, to: self.outbound)
                self.pump(from: self.outbound, to: self.inbound)
            case .failed, .cancelled:
                self.cancel()
            default:
                break
            }
        }
        inbound.start(queue: queue)
        outbound.start(queue: queue)
    }

    func cancel() {
        inbound.cancel()
        outbound.cancel()
    }

    private func pump(from source: NWConnection, to sink: NWConnection) {
        source.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, complete, error in
            guard let self else { return }
            if error != nil { self.cancel(); return }
            guard let data, !data.isEmpty else {
                if complete { self.cancel() }
                else { self.pump(from: source, to: sink) }
                return
            }
            sink.send(content: data, completion: .contentProcessed { sendError in
                if sendError != nil || complete { self.cancel() }
                else { self.pump(from: source, to: sink) }
            })
        }
    }
}
