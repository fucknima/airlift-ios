import Darwin
import Foundation
import UIKit

/// LocalDevVPN is a loopback utun. It puts the device's own developer
/// services on 10.7.0.x, which is how an app can reach them without a Mac.
enum LocalDevVPN {
    static let appStoreURL = URL(string: "https://apps.apple.com/us/app/localdevvpn/id6755608044")!
    static let detectURL = URL(string: "localdevvpn://")!
    static let enableURL = URL(string: "localdevvpn://enable?scheme=airlift")!

    static var isInstalled: Bool {
        UIApplication.shared.canOpenURL(detectURL)
    }

    static var isConnected: Bool {
        let addresses = ipv4Addresses()
        if addresses.contains(TunnelEndpoint.host) { return true }
        let parts = TunnelEndpoint.host.split(separator: ".")
        guard parts.count == 4 else { return false }
        let prefix = parts.dropLast().joined(separator: ".") + "."
        return addresses.contains { $0.hasPrefix(prefix) }
    }

    static func openOrInstall() {
        UIApplication.shared.open(isInstalled ? enableURL : appStoreURL)
    }

    private static func ipv4Addresses() -> [String] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }

        var result: [String] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let current = cursor {
            let interface = current.pointee
            if let address = interface.ifa_addr, address.pointee.sa_family == UInt8(AF_INET) {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(address, socklen_t(MemoryLayout<sockaddr_in>.size),
                               &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                    result.append(String(cString: host))
                }
            }
            cursor = interface.ifa_next
        }
        return result
    }
}

enum TunnelEndpoint {
    static let host = "10.7.0.1"
    static let port: UInt16 = 49152
}
