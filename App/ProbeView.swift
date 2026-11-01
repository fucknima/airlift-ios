import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct ProbeView: View {
    @StateObject private var model = ProbeModel()

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("配对记录", value: model.recordText)
                    switch model.pairing.phase {
                    case .idle:
                        Button("在本机配对") { model.pair() }
                    case .advertising:
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("等待系统配对面板")
                        }
                        Text("面板一般会自己弹出。30 秒没有出现，说明广播没被系统发现，把下面的日志发出来。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Button("取消配对") { model.resetPairing() }
                    case .awaitingPIN(let pin):
                        VStack(alignment: .leading, spacing: 8) {
                            Text("把这六位码输入 iPhone 的配对面板")
                                .font(.footnote)
                            Text(pin)
                                .font(.system(.largeTitle, design: .monospaced))
                                .textSelection(.enabled)
                        }
                    case .paired:
                        Label("配对完成", systemImage: "checkmark.seal")
                            .foregroundStyle(.green)
                        Button("重新配对") { model.pair() }
                    case .failed(let message):
                        Label(message, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                        Button("重试") { model.pair() }
                    }

                    Button("导入配对文件") { model.showPicker = true }
                    Button("从剪贴板导入") { model.importClipboard() }
                    if model.hasRecord {
                        Button("删除配对记录", role: .destructive) { model.removeRecord() }
                    }
                } header: {
                    Text("配对")
                } footer: {
                    Text("本机配对需要 iOS 27。其他工具导出的 RPPairing 文件也可以直接导入。")
                }

                Section {
                    TextField("主机", text: $model.host)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.numbersAndPunctuation)
                    TextField("端口", text: $model.portText)
                        .keyboardType(.numberPad)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(model.candidates, id: \.self) { address in
                                Button(address) {
                                    model.host = address
                                    model.saveEndpoint()
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                        }
                    }
                    Button("保存并检测端口") { model.probe() }
                        .disabled(model.busy)
                    Button("连接并列出服务") { model.connect() }
                        .disabled(model.busy)
                    Button("读取 AFC 设备信息") { model.runAFC() }
                        .disabled(model.busy)
                    if model.busy {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("正在执行")
                        }
                    }
                } header: {
                    Text("回环地址")
                } footer: {
                    Text("填你自己的回环工具给出的地址和端口。候选地址只是本机的 IPv4，不保证正确。")
                }

                if !model.services.isEmpty {
                    Section("RSD 服务 (\(model.services.count))") {
                        ForEach(model.services) { service in
                            HStack {
                                Text(service.name)
                                    .font(.system(.caption2, design: .monospaced))
                                Spacer()
                                Text("\(service.port)")
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                if let report = model.afc {
                    Section("AFC") {
                        LabeledContent("机型", value: report.model)
                        LabeledContent("剩余空间", value: ByteCountFormatter.string(fromByteCount: Int64(report.freeBytes), countStyle: .file))
                    }
                }

                Section("日志") {
                    if model.lines.isEmpty {
                        Text("还没有输出")
                            .foregroundStyle(.secondary)
                    } else {
                        Text(model.logText)
                            .font(.system(.caption2, design: .monospaced))
                            .textSelection(.enabled)
                    }
                    HStack {
                        Button("复制") { UIPasteboard.general.string = model.logText }
                        Button("清空") { model.clearLog() }
                    }
                }
            }
            .navigationTitle("airlift 探针")
            .onAppear { model.start() }
            .sheet(isPresented: $model.showPicker) {
                DocumentPicker { url in
                    model.showPicker = false
                    model.importRecord(url)
                }
            }
            .alert("airlift", isPresented: Binding(
                get: { model.error != nil },
                set: { if !$0 { model.error = nil } }
            )) {
                Button("好") { model.error = nil }
            } message: {
                Text(model.error ?? "")
            }
        }
    }
}
