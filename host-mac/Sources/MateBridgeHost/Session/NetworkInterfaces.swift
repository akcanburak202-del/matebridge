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
}
