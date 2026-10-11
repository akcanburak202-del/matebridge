import Testing
@testable import MateBridgeCore

// T-338 / decision 0038 section 5: which peers may start a new pairing.

private func iface(_ name: String, _ address: String, _ prefix: Int, up: Bool = true) -> LocalInterface {
    LocalInterface(name: name, isUp: up, address: address, prefixLength: prefix)
}

/// A typical Mac: Wi-Fi on a /24, a Tailscale tunnel, loopback.
private let mac: [LocalInterface] = [
    iface("lo0", "127.0.0.1", 8), iface("lo0", "::1", 128),
    iface("en0", "192.168.1.10", 24), iface("en0", "fe80::1c2b:3d4e:5f60:7182", 64),
    iface("en0", "2001:db8:1:2::10", 64),
    iface("utun3", "100.64.0.9", 32), iface("utun3", "192.168.7.1", 24), iface("utun3", "fe80::aaaa", 64),
    iface("utun3", "fd7a:115c:a1e0::9", 48),
]

private func classify(_ peer: String?, _ interfaces: [LocalInterface] = mac) -> PeerLocality {
    PeerClassifier.classify(peerHost: peer, interfaces: interfaces)
}

@Suite struct PeerClassifierTests {
    @Test func loopbackIsLocalInEveryForm() {
        #expect(classify("127.0.0.1") == .local)
        #expect(classify("127.5.6.7") == .local)
        #expect(classify("::1") == .local)
        #expect(classify("::ffff:127.0.0.1") == .local)
        #expect(classify("127.0.0.1", []) == .local)
        #expect(classify("::1", []) == .local)
    }

    @Test func directlyConnectedEnSubnetIsLocal() {
        #expect(classify("192.168.1.20") == .local)
        #expect(classify("::ffff:192.168.1.20") == .local)
        #expect(classify("192.168.1.255") == .local)
    }

    @Test func otherSubnetIsRemote() {
        #expect(classify("192.168.2.20") == .remote)
        #expect(classify("8.8.8.8") == .remote)
        #expect(classify("::ffff:192.168.2.20") == .remote)
    }

    @Test func cgnatRangeIsAlwaysRemote() {
        #expect(classify("100.101.102.103") == .remote)
        #expect(classify("100.64.0.1") == .remote)
        #expect(classify("100.127.255.254") == .remote)
        #expect(classify("::ffff:100.101.102.103") == .remote)
        // Even when a physical en* interface itself sits in that range.
        #expect(classify("100.100.1.5", [iface("en0", "100.100.1.2", 24)]) == .remote)
        // Just outside the range is an ordinary address.
        #expect(classify("100.128.0.1", [iface("en0", "100.128.0.2", 24)]) == .local)
    }

    @Test func subnetOfATunnelInterfaceIsRemote() {
        #expect(classify("192.168.7.5") == .remote)  // utun3 192.168.7.0/24
        #expect(classify("fd7a:115c:a1e0::1234") == .remote)
    }

    @Test func downInterfaceDoesNotCount() {
        #expect(classify("192.168.1.20", [iface("en0", "192.168.1.10", 24, up: false)]) == .remote)
        #expect(classify("fe80::1%en0", [iface("en0", "fe80::2", 64, up: false)]) == .remote)
    }

    @Test func nonEnInterfaceDoesNotCount() {
        #expect(classify("172.16.0.5", [iface("bridge100", "172.16.0.1", 24)]) == .remote)
        #expect(classify("172.16.0.5", [iface("awdl0", "172.16.0.1", 24)]) == .remote)
        #expect(classify("172.16.0.5", [iface("ten0", "172.16.0.1", 24)]) == .remote)
    }

    @Test func linkLocalNeedsAnEnScope() {
        #expect(classify("fe80::1%en0") == .local)
        #expect(classify("fe80::1%utun3") == .remote)
        #expect(classify("fe80::1") == .remote)  // no scope: undeterminable
        #expect(classify("fe80::1%") == .remote)
        #expect(classify("fe80::1%en9") == .remote)  // not an interface of this Mac
        #expect(classify("fe80::1%4") == .remote)  // unresolved numeric scope
    }

    @Test func kameEmbeddedScopeIsIgnored() {
        #expect(classify("fe80:4::1%en0") == .local)
        #expect(classify("fe80:4::1%utun3") == .remote)
    }

    @Test func globalIPv6UsesThePrefixOfAnEnInterface() {
        #expect(classify("2001:db8:1:2::77") == .local)
        #expect(classify("2001:db8:1:3::77") == .remote)
        #expect(classify("2606:4700::1") == .remote)
    }

    @Test func emptyInterfaceListMakesOnlyLoopbackLocal() {
        #expect(classify("192.168.1.20", []) == .remote)
        #expect(classify("fe80::1%en0", []) == .remote)
        #expect(classify("2001:db8:1:2::77", []) == .remote)
        #expect(classify("127.0.0.1", []) == .local)
    }

    @Test func undeterminableIsRemote() {
        #expect(classify(nil) == .remote)
        #expect(classify("") == .remote)
        #expect(classify("not an address") == .remote)
        #expect(classify("192.168.1.20.5") == .remote)
        #expect(classify("localhost") == .remote)
        #expect(classify("::") == .remote)
        #expect(classify("0.0.0.0") == .remote)
        #expect(classify("ff02::1") == .remote)
    }

    @Test func implausiblePrefixesAreIgnored() {
        #expect(classify("8.8.8.8", [iface("en0", "192.168.1.10", 0)]) == .remote)
        #expect(classify("2606:4700::1", [iface("en0", "2001:db8::1", 0)]) == .remote)
        #expect(classify("192.168.1.20", [iface("en0", "192.168.1.10", 40)]) == .remote)
        #expect(classify("192.168.1.20", [iface("en0", "garbage", 24)]) == .remote)
    }

    @Test func prefixLengthsAreHonoured() {
        let wide = [iface("en0", "10.0.0.5", 8)]
        #expect(classify("10.200.1.1", wide) == .local)
        let narrow = [iface("en0", "192.168.1.10", 28)]
        #expect(classify("192.168.1.14", narrow) == .local)
        #expect(classify("192.168.1.17", narrow) == .remote)
        let host = [iface("en0", "192.168.1.10", 32)]
        #expect(classify("192.168.1.10", host) == .local)
        #expect(classify("192.168.1.11", host) == .remote)
        let odd = [iface("en0", "2001:db8:1:2::10", 61)]
        #expect(classify("2001:db8:1:7::1", odd) == .local)
        #expect(classify("2001:db8:1:8::1", odd) == .remote)
    }
}
