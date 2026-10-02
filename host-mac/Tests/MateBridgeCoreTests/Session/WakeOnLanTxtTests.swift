import dnssd
import XCTest
@testable import MateBridgeCore

final class WakeOnLanTxtTests: XCTestCase {
    // Documentation-style addresses (locally administered, never real hardware).
    private let a: [UInt8] = [0x02, 0x00, 0x00, 0xaa, 0xbb, 0x01]
    private let b: [UInt8] = [0x02, 0x00, 0x00, 0xaa, 0xbb, 0x02]
    private let c: [UInt8] = [0x02, 0x00, 0x00, 0xaa, 0xbb, 0x03]
    private let d: [UInt8] = [0x02, 0x00, 0x00, 0xaa, 0xbb, 0x04]
    private let e: [UInt8] = [0x02, 0x00, 0x00, 0xaa, 0xbb, 0x05]

    /// The `getifaddrs` entries of one interface: its link address, and an IPv4 address when `ipv4`.
    private func iface(_ name: String, _ mac: [UInt8], up: Bool = true, ipv4: Bool = true,
                       ipv6: Bool = false) -> [InterfaceAddressEntry] {
        var out = [InterfaceAddressEntry(name: name, isUp: up, kind: .link(mac))]
        if ipv6 { out.append(InterfaceAddressEntry(name: name, isUp: up, kind: .other)) }
        if ipv4 { out.append(InterfaceAddressEntry(name: name, isUp: up, kind: .ipv4)) }
        return out
    }

    func testFormat() {
        XCTAssertEqual(WakeOnLanTxt.format([0x02, 0x00, 0x0a, 0xAB, 0xcd, 0xff]), "02:00:0a:ab:cd:ff")
    }

    func testProtocolExample() {
        // PROTOCOL.md section 3 item 1: wol=02:00:00:aa:bb:01,02:00:00:aa:bb:02
        XCTAssertEqual(WakeOnLanTxt.value(for: iface("en0", a) + iface("en1", b)),
                       "02:00:00:aa:bb:01,02:00:00:aa:bb:02")
    }

    func testFiltersDownNoIPv4AndNonEnInterfaces() {
        let entries = iface("en0", a, up: false)        // down
            + iface("en1", b, ipv4: false, ipv6: true)  // no IPv4
            + iface("bridge0", c)                       // not en*
            + iface("lo0", d)
            + iface("utun3", d)
            + iface("enx", d)
            + iface("en2", e)
        XCTAssertEqual(WakeOnLanTxt.value(for: entries), "02:00:00:aa:bb:05")
    }

    func testNoSuitableInterfaceMeansNoKey() {
        XCTAssertNil(WakeOnLanTxt.value(for: []))
        XCTAssertNil(WakeOnLanTxt.value(for: iface("en0", a, ipv4: false)))
        XCTAssertNil(WakeOnLanTxt.value(for: iface("en0", [])))                                  // no address
        XCTAssertNil(WakeOnLanTxt.value(for: iface("en0", [0, 0, 0, 0, 0, 0])))                  // all zero
        XCTAssertNil(WakeOnLanTxt.value(for: iface("en0", [0x01, 0x00, 0x5e, 0x00, 0x00, 0x01]))) // multicast
        XCTAssertNil(WakeOnLanTxt.value(for: iface("en0", [0x02, 0x00, 0x00, 0xaa])))              // not 6 bytes
        XCTAssertEqual(WakeOnLanTxt.entries(wol: nil).map(\.key), ["v"])
        XCTAssertEqual(WakeOnLanTxt.dictionary(wol: nil), ["v": "1"])
    }

    func testStableNumericOrderRegardlessOfInputOrder() {
        let forward = iface("en0", a) + iface("en2", b) + iface("en10", c)
        let shuffled = iface("en10", c) + iface("en0", a) + iface("en2", b)
        let expected = "02:00:00:aa:bb:01,02:00:00:aa:bb:02,02:00:00:aa:bb:03"
        XCTAssertEqual(WakeOnLanTxt.value(for: forward), expected)
        XCTAssertEqual(WakeOnLanTxt.value(for: shuffled), expected, "en10 sorts after en2")
    }

    func testAtMostFourAddresses() {
        let entries = iface("en4", e) + iface("en3", d) + iface("en2", c) + iface("en1", b) + iface("en0", a)
        let value = WakeOnLanTxt.value(for: entries)
        XCTAssertEqual(value, "02:00:00:aa:bb:01,02:00:00:aa:bb:02,02:00:00:aa:bb:03,02:00:00:aa:bb:04")
        XCTAssertEqual(value?.split(separator: ",").count, WakeOnLanTxt.maxAddresses)
    }

    func testDuplicateAddressesAppearOnce() {
        XCTAssertEqual(WakeOnLanTxt.value(for: iface("en0", a) + iface("en1", a) + iface("en2", b)),
                       "02:00:00:aa:bb:01,02:00:00:aa:bb:02")
    }

    func testAddressFamilyOrderWithinAnInterfaceDoesNotMatter() {
        let entries = [InterfaceAddressEntry(name: "en0", isUp: true, kind: .ipv4),
                       InterfaceAddressEntry(name: "en0", isUp: true, kind: .other),
                       InterfaceAddressEntry(name: "en0", isUp: true, kind: .link(a))]
        XCTAssertEqual(WakeOnLanTxt.value(for: entries), "02:00:00:aa:bb:01")
    }

    func testInterfaceNumber() {
        XCTAssertEqual(WakeOnLanTxt.interfaceNumber("en0"), 0)
        XCTAssertEqual(WakeOnLanTxt.interfaceNumber("en12"), 12)
        XCTAssertNil(WakeOnLanTxt.interfaceNumber("en"))
        XCTAssertNil(WakeOnLanTxt.interfaceNumber("en0a"))
        XCTAssertNil(WakeOnLanTxt.interfaceNumber("ben0"))
        XCTAssertNil(WakeOnLanTxt.interfaceNumber("awdl0"))
        XCTAssertNil(WakeOnLanTxt.interfaceNumber("en٣"))  // non-ASCII digit
    }

    func testTxtEntriesAndRecordBytes() {
        let wol = "02:00:00:aa:bb:01,02:00:00:aa:bb:02"
        let entries = WakeOnLanTxt.entries(wol: wol)
        XCTAssertEqual(entries.map(\.key), ["v", "wol"])
        XCTAssertEqual(entries.map(\.value), ["1", wol])
        XCTAssertEqual(WakeOnLanTxt.dictionary(wol: wol), ["v": "1", "wol": wol])
        let record = BonjourAdvertiser.txtRecord(entries)
        XCTAssertEqual(record, [3] + Array("v=1".utf8) + [UInt8(4 + wol.utf8.count)] + Array("wol=\(wol)".utf8))
        // Four addresses fit easily in one 255-byte TXT entry.
        let four = Array(repeating: "02:00:00:aa:bb:01", count: 4).joined(separator: ",")
        XCTAssertLessThan("wol=\(four)".utf8.count, BonjourAdvertiser.maxTxtEntryBytes)
    }

    func testSockaddrDLParsing() {
        // sdl_len, family AF_LINK(18), index 4 (2 bytes), type 6, nlen 3 ("en0"), alen 6, slen 0, data...
        var bytes: [UInt8] = [20, 18, 4, 0, 6, 3, 6, 0] + Array("en0".utf8) + a
        bytes.append(contentsOf: [0, 0, 0])  // padding up to sdl_len
        XCTAssertEqual(WakeOnLanTxt.linkAddress(sockaddrDL: bytes), a)
        // No hardware address (alen 0), e.g. lo0.
        XCTAssertEqual(WakeOnLanTxt.linkAddress(sockaddrDL: [20, 18, 1, 0, 24, 3, 0, 0] + Array("lo0".utf8)
                                                    + Array(repeating: 0, count: 9)), [])
        // Truncated: address runs past sdl_len.
        XCTAssertNil(WakeOnLanTxt.linkAddress(sockaddrDL: [12, 18, 4, 0, 6, 3, 6, 0] + Array("en0".utf8) + [0x02]))
        XCTAssertNil(WakeOnLanTxt.linkAddress(sockaddrDL: [8, 18, 4]))
    }

    /// Registers on this Mac only, replaces the TXT record and resolves the service to see the new record.
    func testBonjourTxtUpdateLocally() throws {
        let queue = DispatchQueue(label: "test.bonjour.txt")
        let type = "_mbt\(String(UInt32.random(in: 0..<0xffffff), radix: 16))._tcp"
        let registered = DispatchSemaphore(value: 0)
        let advertiser: BonjourAdvertiser
        do {
            advertiser = try BonjourAdvertiser(name: "MateBridge TXT Test", type: type, port: 40_124,
                                               txt: WakeOnLanTxt.entries(wol: nil), scope: .localOnly,
                                               queue: queue) { event in
                if event == .registered { registered.signal() }
            }
        } catch let error as BonjourError where error.code == kDNSServiceErr_ServiceNotRunning {
            throw XCTSkip("mDNSResponder not reachable")
        }
        XCTAssertEqual(registered.wait(timeout: .now() + 5), .success, "no registration callback")

        let wol = "02:00:00:aa:bb:01"
        let expected = BonjourAdvertiser.txtRecord(WakeOnLanTxt.entries(wol: wol))
        try queue.sync { try advertiser.updateTXT(WakeOnLanTxt.entries(wol: wol)) }

        let result = ResolveResult(expected: expected)
        var resolveRef: DNSServiceRef?
        let context = Unmanaged.passRetained(result)
        let err = DNSServiceResolve(&resolveRef, 0, kDNSServiceInterfaceIndexLocalOnly, "MateBridge TXT Test", type,
                                    "local.", { _, _, _, error, _, _, _, txtLen, txt, ctx in
            guard error == kDNSServiceErr_NoError, let ctx, let txt else { return }
            let bytes = Array(UnsafeBufferPointer(start: txt, count: Int(txtLen)))
            Unmanaged<ResolveResult>.fromOpaque(ctx).takeUnretainedValue().saw(bytes)
        }, context.toOpaque())
        XCTAssertEqual(Int(err), Int(kDNSServiceErr_NoError))
        let ref = try XCTUnwrap(resolveRef)
        XCTAssertEqual(Int(DNSServiceSetDispatchQueue(ref, queue)), Int(kDNSServiceErr_NoError))
        XCTAssertEqual(result.signal.wait(timeout: .now() + 5), .success, "updated TXT record not resolved")
        queue.sync {
            DNSServiceRefDeallocate(ref)
            context.release()
        }
        advertiser.cancel()
        queue.sync {}
        XCTAssertThrowsError(try queue.sync { try advertiser.updateTXT(WakeOnLanTxt.entries(wol: nil)) },
                             "no update after cancel")
    }
}

private final class ResolveResult: @unchecked Sendable {
    let signal = DispatchSemaphore(value: 0)
    private let expected: [UInt8]
    private var matched = false

    init(expected: [UInt8]) { self.expected = expected }

    func saw(_ txt: [UInt8]) {
        guard !matched, txt == expected else { return }
        matched = true
        signal.signal()
    }
}
