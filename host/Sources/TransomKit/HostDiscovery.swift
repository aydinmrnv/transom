import Darwin
import Foundation

/// DNS-SD metadata. See docs/protocol.md §1: discovery never changes the
/// private-address bind restriction or constitutes authentication.
public enum HostDiscovery {
    public static let serviceType = "_transom._tcp"

    public static let identity: String = {
        let defaults = UserDefaults.standard
        if let id = defaults.string(forKey: "transom.discovery.identity") { return id }
        let id = UUID().uuidString.lowercased()
        defaults.set(id, forKey: "transom.discovery.identity")
        return id
    }()

    public static var computerName: String {
        Host.current().localizedName ?? ProcessInfo.processInfo.hostName
    }

    public static func txtRecord(address: String, videoPort: UInt16?) -> Data {
        var data = Data()
        let fields = [
            "v=1", "id=\(identity)", "name=\(computerName)",
            "addr=\(address)", "video=\(videoPort ?? 0)",
        ]
        for field in fields {
            // DNS-SD strings have a one-byte length. Preserve valid UTF-8 when
            // a user has given the Mac an unusually long Unicode name.
            var value = field
            while value.utf8.count > 255 { value.removeLast() }
            let bytes = Data(value.utf8)
            data.append(UInt8(bytes.count))
            data.append(bytes)
        }
        return data
    }

    /// Prefer active hardware LAN interfaces over tunnels; never wildcard-bind.
    /// Re-evaluated at Start so DHCP changes do not leave a stale saved address.
    public static func localAddresses() -> [String] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { return [] }
        defer { freeifaddrs(head) }
        var entries: [(String, String)] = []
        var cursor = head
        while let item = cursor {
            defer { cursor = item.pointee.ifa_next }
            let flags = Int32(item.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_RUNNING != 0,
                flags & IFF_LOOPBACK == 0, let address = item.pointee.ifa_addr,
                address.pointee.sa_family == UInt8(AF_INET)
            else { continue }
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(
                address, socklen_t(address.pointee.sa_len), &buffer,
                socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0
            else { continue }
            let ip = String(cString: buffer)
            if PrivateAddress.isPrivateIPv4(ip) {
                entries.append((String(cString: item.pointee.ifa_name), ip))
            }
        }
        return entries.sorted {
            let left = $0.0.hasPrefix("en") ? 0 : 1
            let right = $1.0.hasPrefix("en") ? 0 : 1
            return left == right ? $0.0 < $1.0 : left < right
        }.map { $0.1 }
    }
}
