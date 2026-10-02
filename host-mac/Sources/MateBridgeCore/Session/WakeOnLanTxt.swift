/// One `getifaddrs` entry, reduced to what the TXT `wol` value needs (T-128). The host's wrapper produces these.
public struct InterfaceAddressEntry: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        /// AF_LINK: the interface's hardware address (may be empty).
        case link([UInt8])
        /// AF_INET: the interface has an IPv4 address.
        case ipv4
        /// Any other family (IPv6, ...).
        case other
    }

    public var name: String
    /// `IFF_UP`.
    public var isUp: Bool
    public var kind: Kind

    public init(name: String, isUp: Bool, kind: Kind) {
        self.name = name
        self.isUp = isUp
        self.kind = kind
    }
}

/// The Bonjour TXT record of `_matebridge._tcp` and its `wol` key (PROTOCOL.md section 3, item 1).
///
/// `wol=aa:bb:cc:dd:ee:ff,…`: lower-case, colon-separated 6-byte addresses, comma-separated, at most 4; only `en*`
/// interfaces that are up and have an IPv4 address. Ordered by interface number (en0, en1, …, en10) so the value is
/// stable and a re-publish happens only on a real change. No suitable interface: no `wol` key at all.
public enum WakeOnLanTxt {
    public static let key = "wol"
    public static let maxAddresses = 4

    /// TXT entries in record order: `v=1`, then `wol` when there is a value.
    public static func entries(wol: String?) -> [(key: String, value: String)] {
        var out: [(key: String, value: String)] = [("v", "1")]
        if let wol { out.append((key, wol)) }
        return out
    }

    /// The same record as a dictionary (`NWTXTRecord`).
    public static func dictionary(wol: String?) -> [String: String] {
        var out = ["v": "1"]
        if let wol { out[key] = wol }
        return out
    }

    /// The `wol` value for these `getifaddrs` entries, or nil when no interface qualifies.
    public static func value(for entries: [InterfaceAddressEntry]) -> String? {
        struct Interface {
            var up = false
            var ipv4 = false
            var mac: [UInt8]?
        }
        var byName: [String: Interface] = [:]
        for e in entries {
            guard interfaceNumber(e.name) != nil else { continue }
            var i = byName[e.name, default: Interface()]
            i.up = i.up || e.isUp
            switch e.kind {
            case .link(let bytes): if isUsableMac(bytes) { i.mac = bytes }
            case .ipv4: i.ipv4 = true
            case .other: break
            }
            byName[e.name] = i
        }
        let ordered = byName.compactMap { name, i -> (Int, String, [UInt8])? in
            guard i.up, i.ipv4, let mac = i.mac, let n = interfaceNumber(name) else { return nil }
            return (n, name, mac)
        }.sorted { ($0.0, $0.1) < ($1.0, $1.1) }
        var seen: [[UInt8]] = []
        for (_, _, mac) in ordered where !seen.contains(mac) {
            seen.append(mac)
            if seen.count == maxAddresses { break }
        }
        return seen.isEmpty ? nil : seen.map(format).joined(separator: ",")
    }

    /// Number of an `en<digits>` interface name; nil for anything else (`lo0`, `bridge0`, `utun3`, `en`, `enx`).
    public static func interfaceNumber(_ name: String) -> Int? {
        guard name.hasPrefix("en") else { return nil }
        let digits = name.dropFirst(2)
        guard !digits.isEmpty, digits.count <= 6, digits.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return Int(digits)
    }

    /// A 6-byte unicast address that is not all zero (a magic packet for it could wake something).
    public static func isUsableMac(_ bytes: [UInt8]) -> Bool {
        bytes.count == 6 && bytes.contains { $0 != 0 } && bytes[0] & 0x01 == 0
    }

    /// `aa:bb:cc:dd:ee:ff`.
    public static func format(_ mac: [UInt8]) -> String {
        mac.map { b in
            let s = String(b, radix: 16)
            return s.count == 1 ? "0" + s : s
        }.joined(separator: ":")
    }

    /// The hardware address in a `struct sockaddr_dl` (net/if_dl.h): `sdl_len`(1) `sdl_family`(1) `sdl_index`(2)
    /// `sdl_type`(1) `sdl_nlen`(1) `sdl_alen`(1) `sdl_slen`(1), then `sdl_data` = name (`nlen` bytes) + address
    /// (`alen` bytes). `bytes` is the whole structure (`sdl_len` bytes). nil when it does not fit.
    public static func linkAddress(sockaddrDL bytes: [UInt8]) -> [UInt8]? {
        let header = 8
        guard bytes.count >= header else { return nil }
        let length = min(Int(bytes[0]), bytes.count)
        let nlen = Int(bytes[5]), alen = Int(bytes[6])
        let start = header + nlen
        guard length >= header, start + alen <= length else { return nil }
        return Array(bytes[start..<start + alen])
    }
}
