import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct ProbeView: View {
    @StateObject private var model = ProbeModel()

    var body: some View {
        NavigationStack {
            Form {
                Section("pairing") {
                    HStack {
                        Text("record")
                        Spacer()
                        Text(model.recordExists ? "present" : "missing")
                            .foregroundStyle(model.recordExists ? .green : .secondary)
                    }
                    switch model.pairing.phase {
                    case .idle:
                        Button("Pair on this iPhone") { model.pair() }
                    case .advertising:
                        Label("waiting for the pairing sheet", systemImage: "dot.radiowaves.left.and.right")
                    case .deviceConnected:
                        Label("device connected", systemImage: "link")
                    case .awaitingPIN(let pin):
                        VStack(alignment: .leading, spacing: 6) {
                            Text("enter this PIN on the iPhone")
                            Text(pin).font(.system(.largeTitle, design: .monospaced))
                        }
                    case .paired:
                        Label("paired", systemImage: "checkmark.seal")
                        Button("Pair again") { model.pair() }
                    case .failed(let message):
                        Label(message, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                        Button("Retry") { model.pair() }
                    }
                    Button("Import pairing file") { model.showImporter = true }
                    if model.recordExists {
                        Button("Remove pairing", role: .destructive) { model.removeRecord() }
                    }
                }

                Section("tunnel") {
                    HStack {
                        Text("LocalDevVPN")
                        Spacer()
                        Text(model.vpnConnected ? "connected" : "off")
                            .foregroundStyle(model.vpnConnected ? .green : .secondary)
                    }
                    Button("Open LocalDevVPN") { model.openVPN() }
                    Button("Connect and list services") { model.connect() }
                        .disabled(model.busy || !model.recordExists)
                    Button("AFC device info") { model.runAFC() }
                        .disabled(model.busy || model.services.isEmpty)
                }

                if !model.services.isEmpty {
                    Section("rsd services (\(model.services.count))") {
                        ForEach(model.services) { service in
                            HStack {
                                Text(service.name).font(.system(.caption, design: .monospaced))
                                Spacer()
                                Text("\(service.port)")
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                if let report = model.afc {
                    Section("afc") {
                        LabeledContent("model", value: report.model)
                        LabeledContent("free", value: ByteCountFormatter.string(fromByteCount: Int64(report.freeBytes), countStyle: .file))
                    }
                }

                Section("log") {
                    Text(model.logText.isEmpty ? "no output yet" : model.logText)
                        .font(.system(.caption2, design: .monospaced))
                        .textSelection(.enabled)
                    HStack {
                        Button("Copy") { UIPasteboard.general.string = model.logText }
                        Button("Clear") { model.clearLog() }
                    }
                }
            }
            .navigationTitle("airlift probe")
            .onAppear { model.start() }
            .fileImporter(
                isPresented: $model.showImporter,
                allowedContentTypes: [.data, .propertyList, .item],
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls): if let url = urls.first { model.importRecord(url) }
                case .failure(let error): model.error = error.localizedDescription
                }
            }
            .alert("airlift", isPresented: Binding(
                get: { model.error != nil },
                set: { if !$0 { model.error = nil } }
            )) {
                Button("OK") { model.error = nil }
            } message: {
                Text(model.error ?? "")
            }
        }
    }
}
