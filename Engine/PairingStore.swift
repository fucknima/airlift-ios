import Foundation
import UniformTypeIdentifiers

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

    func importRecord(from source: URL) throws {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: source)
        guard !data.isEmpty,
              (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) != nil else {
            throw StoreError.invalidRecord
        }
        try data.write(to: url, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
    }

    func remove() throws {
        if exists { try fm.removeItem(at: url) }
    }
}

enum StoreError: LocalizedError {
    case invalidRecord

    var errorDescription: String? {
        switch self {
        case .invalidRecord: return "not an RPPairing plist"
        }
    }
}
