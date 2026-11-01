import Foundation
import UniformTypeIdentifiers
import UIKit

/// The RPPairing record lives in Application Support, mode 0600.
final class PairingStore: @unchecked Sendable {
    static let fileName = "rp_pairing_file.plist"

    private let fm = FileManager.default
    private let directory: URL

    init() {
        directory = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Pairing", isDirectory: true)
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    var url: URL { directory.appendingPathComponent(Self.fileName) }
    var path: String { url.path }
    var exists: Bool { fm.fileExists(atPath: path) }
    var size: Int { (try? fm.attributesOfItem(atPath: path)[.size] as? Int) ?? 0 }

    func importRecord(from source: URL) throws {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: source)
        try install(data)
    }

    /// Pairing records are often copied as text because the picker cannot see
    /// them, or because the file came out of a chat app.
    func importRecord(from text: String) throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw StoreError.empty }
        if let data = trimmed.data(using: .utf8), (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) != nil {
            try install(data)
            return
        }
        if let data = Data(base64Encoded: trimmed, options: [.ignoreUnknownCharacters]) {
            try install(data)
            return
        }
        throw StoreError.invalidRecord
    }

    /// Key names and sizes only, so the log proves the record type without
    /// dumping key material.
    func describe() -> String {
        guard let data = try? Data(contentsOf: url),
              let plist = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any] else {
            return "无法解析"
        }
        return plist.keys.sorted().map { key in
            if let value = plist[key] as? Data { return "\(key)=\(value.count)B" }
            if let value = plist[key] as? String { return "\(key)=\(value.prefix(10))" }
            return key
        }.joined(separator: " ")
    }

    func remove() throws {
        if exists { try fm.removeItem(at: url) }
    }

    private func install(_ data: Data) throws {
        guard !data.isEmpty,
              (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) != nil else {
            throw StoreError.invalidRecord
        }
        try data.write(to: url, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
    }
}

enum StoreError: LocalizedError {
    case empty
    case invalidRecord

    var errorDescription: String? {
        switch self {
        case .empty: return "剪贴板是空的"
        case .invalidRecord: return "内容不是 plist，也不是 base64 的 plist"
        }
    }
}
