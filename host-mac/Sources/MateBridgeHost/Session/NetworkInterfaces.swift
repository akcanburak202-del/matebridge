import Darwin
import MateBridgeCore

/// The Mac's network interface addresses, from `getifaddrs` (T-128). Thin wrapper: `WakeOnLanTxt` filters, orders
/// and formats. Never logged (hardware addresses are only published in the TXT record).
enum NetworkInterfaces {
    static func entries() -> [InterfaceAddressEntry] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        var out: [InterfaceAddressEntry] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let ifa = cursor {
            defer { cursor = ifa.pointee.ifa_next }
            guard let cName = ifa.pointee.ifa_name, let addr = ifa.pointee.ifa_addr else { continue }
            let name = String(cString: cName)
            let up = ifa.pointee.ifa_flags & UInt32(IFF_UP) != 0
            let kind: InterfaceAddressEntry.Kind
            switch Int32(addr.pointee.sa_family) {
            case AF_LINK:
                let length = Int(addr.pointee.sa_len)
                let bytes = Array(UnsafeRawBufferPointer(start: UnsafeRawPointer(addr), count: length))
                kind = .link(WakeOnLanTxt.linkAddress(sockaddrDL: bytes) ?? [])
            case AF_INET:
                kind = .ipv4
            default:
                kind = .other
            }
            out.append(InterfaceAddressEntry(name: name, isUp: up, kind: kind))
        }
        return out
    }

    /// The TXT `wol` value for the interfaces as they are now (nil: no key).
    static func wakeOnLanValue() -> String? { WakeOnLanTxt.value(for: entries()) }

    /// Interface addresses (IPv4 and IPv6) with their prefix lengths, for the peer classification (T-338). Entries whose
    /// netmask is missing or not contiguous are left out, so they can never make a peer local. Never logged.
    static func localInterfaces() -> [LocalInterface] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        var out: [LocalInterface] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let ifa = cursor {
            defer { cursor = ifa.pointee.ifa_next }
            guard let cName = ifa.pointee.ifa_name, let addr = ifa.pointee.ifa_addr,
                  let mask = ifa.pointee.ifa_netmask else { continue }
            let family = Int32(addr.pointee.sa_family)
            guard family == AF_INET || family == AF_INET6,
                  let address = text(addr), let prefix = prefixLength(mask, family: family) else { continue }
            out.append(LocalInterface(name: String(validatingCString: cName) ?? "", isUp: ifa.pointee.ifa_flags & UInt32(IFF_UP) != 0,
                                      address: address, prefixLength: prefix))
        }
        return out
    }

    /// The peer address text for `PeerClassifier`: `inet_ntop` form plus `%<interface>` when the IPv6 peer has a scope
    /// id that names an interface.
    static func peerText(host: String?, scopeID: UInt32) -> String? {
        guard let host else { return nil }
        guard scopeID != 0 else { return host }
        var name = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
        guard if_indextoname(scopeID, &name) != nil else { return host }
        return host + "%" + string(name)
    }

    private static func string(_ c: [CChar]) -> String {
        String(decoding: c.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    private static func text(_ sa: UnsafeMutablePointer<sockaddr>) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        switch Int32(sa.pointee.sa_family) {
        case AF_INET:
            return sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { p in
                var a = p.pointee.sin_addr
                return inet_ntop(AF_INET, &a, &buffer, socklen_t(buffer.count)) != nil ? string(buffer) : nil
            }
        case AF_INET6:
            return sa.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { p in
                var a = p.pointee.sin6_addr
                return inet_ntop(AF_INET6, &a, &buffer, socklen_t(buffer.count)) != nil ? string(buffer) : nil
            }
        default:
            return nil
        }
    }

    /// Number of leading one bits of a contiguous netmask; nil for a non-contiguous or unreadable one.
    private static func prefixLength(_ sa: UnsafeMutablePointer<sockaddr>, family: Int32) -> Int? {
        var bytes: [UInt8]
        if family == AF_INET {
            bytes = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { p in
                withUnsafeBytes(of: p.pointee.sin_addr) { Array($0) }
            }
        } else {
            bytes = sa.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { p in
                withUnsafeBytes(of: p.pointee.sin6_addr) { Array($0) }
            }
        }
        var bits = 0
        var seenZero = false
        for byte in bytes {
            for shift in stride(from: 7, through: 0, by: -1) {
                if byte >> UInt8(shift) & 1 == 1 {
                    if seenZero { return nil }
                    bits += 1
                } else {
                    seenZero = true
                }
            }
        }
        return bits
    }
}
