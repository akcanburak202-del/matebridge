import Darwin

/// Whether the peer of a control connection is on the Mac's own link or reached it from further away (decision 0038,
/// PROTOCOL.md section 3 step 3, "Uzaktan eşleşme yok"). Only a `local` peer may start a new pairing.
public enum PeerLocality: Equatable, Sendable {
    case local
    case remote

    /// `locality=` log value. The address itself is never logged.
    public var logName: String { self == .local ? "local" : "remote" }
}

/// One address of one Mac network interface, as `getifaddrs` reports it (the host turns the netmask into a prefix
/// length). `address` is text (`192.168.1.20`, `fe80::1`, `2001:db8::5`); an unparsable entry never matches.
public struct LocalInterface: Equatable, Sendable {
    public var name: String
    /// `IFF_UP`.
    public var isUp: Bool
    public var address: String
    public var prefixLength: Int

    public init(name: String, isUp: Bool, address: String, prefixLength: Int) {
        self.name = name
        self.isUp = isUp
        self.address = address
        self.prefixLength = prefixLength
    }
}

/// Pure peer classification. Rules (decision 0038 addendum item 1):
/// - loopback (`127.0.0.0/8`, `::1`, IPv4-mapped forms included) is local (the USB path, `adb reverse`);
/// - `100.64.0.0/10` (Tailscale/CGNAT) is always remote, whatever interface owns it;
/// - otherwise the peer is local only inside the directly connected subnet of an up interface named `en*`
///   (IPv4 `address & mask`, IPv6 prefix); link-local `fe80::/10` only when its scope interface is such an `en*`;
/// - anything that cannot be determined is remote.
public enum PeerClassifier {
    /// Interfaces with a prefix shorter than this are not trusted to describe a LAN (a broken `/0` would make the
    /// whole internet local).
    static let minimumPrefix = 8

    /// `peerHost` is the peer address text, with an optional `%scope` suffix naming the interface for link-local
    /// addresses (`fe80::1%en0`).
    public static func classify(peerHost: String?, interfaces: [LocalInterface]) -> PeerLocality {
        guard let peerHost, !peerHost.isEmpty, let peer = parsePeer(peerHost) else { return .remote }
        switch peer.address {
        case .v4(let v4):
            return classifyV4(v4, interfaces: interfaces)
        case .v6(let bytes):
            return classifyV6(bytes, scope: peer.scope, interfaces: interfaces)
        }
    }

    // MARK: Address model

    private enum IP {
        case v4(UInt32)
        case v6([UInt8])
    }

    private struct Peer {
        var address: IP
        var scope: String?
    }

    private static func parsePeer(_ text: String) -> Peer? {
        var host = Substring(text)
        var scope: String?
        if let pct = host.firstIndex(of: "%") {
            let s = String(host[host.index(after: pct)...])
            scope = s.isEmpty ? nil : s
            host = host[..<pct]
        }
        guard let ip = parseAddress(String(host)) else { return nil }
        if case .v6(let bytes) = ip, let mapped = mappedV4(bytes) { return Peer(address: .v4(mapped), scope: nil) }
        return Peer(address: ip, scope: scope)
    }

    private static func parseAddress(_ text: String) -> IP? {
        var v4 = in_addr()
        if inet_pton(AF_INET, text, &v4) == 1 { return .v4(UInt32(bigEndian: v4.s_addr)) }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, text, &v6) == 1 {
            var bytes = withUnsafeBytes(of: &v6) { Array($0) }
            // KAME embeds the scope id in bytes 2-3 of link-local addresses (fe80:4::1); it is not part of the address.
            if bytes[0] == 0xfe, bytes[1] & 0xc0 == 0x80 {
                bytes[2] = 0
                bytes[3] = 0
            }
            return .v6(bytes)
        }
        return nil
    }

    private static func mappedV4(_ b: [UInt8]) -> UInt32? {
        guard b.count == 16, b[0..<10].allSatisfy({ $0 == 0 }), b[10] == 0xff, b[11] == 0xff else { return nil }
        return b[12...].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
    }

    private static func isEthernetLike(_ i: LocalInterface) -> Bool { i.isUp && i.name.hasPrefix("en") }

    private static func isLinkLocal(_ b: [UInt8]) -> Bool { b[0] == 0xfe && b[1] & 0xc0 == 0x80 }

    // MARK: IPv4

    private static func classifyV4(_ peer: UInt32, interfaces: [LocalInterface]) -> PeerLocality {
        if peer >> 24 == 127 { return .local }
        if peer & 0xffc0_0000 == 0x6440_0000 { return .remote }  // 100.64.0.0/10
        for i in interfaces where isEthernetLike(i) {
            guard case .v4(let addr)? = parseAddress(i.address),
                  (Self.minimumPrefix...32).contains(i.prefixLength) else { continue }
            let mask: UInt32 = i.prefixLength == 32 ? .max : ~(.max >> UInt32(i.prefixLength))
            if peer & mask == addr & mask { return .local }
        }
        return .remote
    }

    // MARK: IPv6

    private static func classifyV6(_ peer: [UInt8], scope: String?, interfaces: [LocalInterface]) -> PeerLocality {
        if peer == [UInt8](repeating: 0, count: 15) + [1] { return .local }  // ::1
        if isLinkLocal(peer) {
            guard let scope, scope.hasPrefix("en") else { return .remote }
            return interfaces.contains { $0.name == scope && isEthernetLike($0) } ? .local : .remote
        }
        for i in interfaces where isEthernetLike(i) {
            guard case .v6(let addr)? = parseAddress(i.address), !isLinkLocal(addr),
                  (Self.minimumPrefix...128).contains(i.prefixLength) else { continue }
            if prefixMatches(peer, addr, bits: i.prefixLength) { return .local }
        }
        return .remote
    }

    private static func prefixMatches(_ a: [UInt8], _ b: [UInt8], bits: Int) -> Bool {
        let whole = bits / 8
        if a[..<whole] != b[..<whole] { return false }
        let rest = bits % 8
        guard rest > 0 else { return true }
        let mask = UInt8(truncatingIfNeeded: 0xff << (8 - rest))
        return a[whole] & mask == b[whole] & mask
    }
}
