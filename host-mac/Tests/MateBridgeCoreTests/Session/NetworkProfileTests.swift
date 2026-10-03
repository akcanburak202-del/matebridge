import Darwin
import XCTest
@testable import MateBridgeCore

/// T-189 (decision 0027): the "Yalnız USB" network profile.
final class NetworkProfileTests: XCTestCase {
    // MARK: Preference

    func testPreferenceParsesAndRoundTrips() {
        for profile in NetworkProfile.allCases {
            XCTAssertEqual(NetworkProfile(storedValue: profile.storedValue), profile)
        }
        XCTAssertEqual(NetworkProfile.usbOnly.storedValue, "usb_only")
        XCTAssertEqual(NetworkProfile.all.storedValue, "all")
        XCTAssertEqual(NetworkProfile.defaultsKey, "networkProfile")
    }

    func testMissingOrUnknownPreferenceMeansAll() {
        XCTAssertEqual(NetworkProfile(storedValue: nil), .all)
        XCTAssertEqual(NetworkProfile(storedValue: "USB_ONLY"), .all)
        XCTAssertEqual(NetworkProfile(storedValue: "wifi"), .all)
        XCTAssertEqual(NetworkProfile(storedValue: ""), .all)
        XCTAssertEqual(NetworkProfile(storedValue: true), .all)
        XCTAssertEqual(NetworkProfile(storedValue: 1), .all)
    }

    func testLogNames() {
        XCTAssertEqual(NetworkProfile.all.logName, "all")
        XCTAssertEqual(NetworkProfile.usbOnly.logName, "usb_only")
    }

    // MARK: Surface

    func testBindAddressAndBonjourPerProfile() {
        XCTAssertEqual(NetworkProfile.all.bindAddress, .any)
        XCTAssertTrue(NetworkProfile.all.advertisesBonjour)
        XCTAssertEqual(NetworkProfile.usbOnly.bindAddress, .loopbackV4Mapped)
        XCTAssertFalse(NetworkProfile.usbOnly.advertisesBonjour)
    }

    private static let loopbackPeers = ["127.0.0.1", "::1", "::ffff:127.0.0.1", "::1%lo0", "::ffff:127.0.0.1%lo0",
                                        "127.0.0.1%1"]
    private static let lanPeers = ["192.168.1.20", "10.0.0.5", "::ffff:192.168.1.20", "fe80::1%en0",
                                   "2001:db8::1", "::ffff:10.0.0.5%en0", "127.0.0.2", "0.0.0.0", "::"]

    func testUsbOnlyAdmitsLoopbackPeersOnly() {
        for peer in Self.loopbackPeers {
            XCTAssertTrue(NetworkProfile.usbOnly.admits(peerHost: peer), peer)
        }
        for peer in Self.lanPeers {
            XCTAssertFalse(NetworkProfile.usbOnly.admits(peerHost: peer), peer)
        }
        XCTAssertFalse(NetworkProfile.usbOnly.admits(peerHost: nil), "an unknown peer is refused")
    }

    func testAllAdmitsEveryPeer() {
        for peer in Self.loopbackPeers + Self.lanPeers {
            XCTAssertTrue(NetworkProfile.all.admits(peerHost: peer), peer)
        }
        XCTAssertTrue(NetworkProfile.all.admits(peerHost: nil))
    }

    func testUsbOnlyForcesUsbModeAndLocksItsToggle() {
        XCTAssertTrue(NetworkProfile.usbOnly.effectiveUsbMode(stored: false))
        XCTAssertTrue(NetworkProfile.usbOnly.effectiveUsbMode(stored: true))
        XCTAssertFalse(NetworkProfile.usbOnly.allowsUsbModeToggle)
        XCTAssertFalse(NetworkProfile.all.effectiveUsbMode(stored: false))
        XCTAssertTrue(NetworkProfile.all.effectiveUsbMode(stored: true))
        XCTAssertTrue(NetworkProfile.all.allowsUsbModeToggle)
    }

    // MARK: Switch decision

    func testSameProfileIsUnchanged() {
        for profile in NetworkProfile.allCases {
            for activity: NetworkActivity in [.idle, .pendingApproval, .active(.usb), .active(.network)] {
                XCTAssertEqual(NetworkProfileSwitch.decide(current: profile, requested: profile, activity: activity),
                               .unchanged)
            }
        }
    }

    func testNoLiveSessionRestartsNow() {
        for (from, to) in [(NetworkProfile.all, NetworkProfile.usbOnly), (.usbOnly, .all)] {
            XCTAssertEqual(NetworkProfileSwitch.decide(current: from, requested: to, activity: .idle), .restartNow)
            XCTAssertEqual(NetworkProfileSwitch.decide(current: from, requested: to, activity: .pendingApproval),
                           .restartNow)
        }
    }

    func testLiveUsbSessionIsNeverCut() {
        for (from, to) in [(NetworkProfile.all, NetworkProfile.usbOnly), (.usbOnly, .all)] {
            XCTAssertEqual(NetworkProfileSwitch.decide(current: from, requested: to, activity: .active(.usb)),
                           .deferred)
        }
    }

    /// Decided in the card's Plan: a Wi-Fi session is deferred too (the tablet is the Mac's only screen).
    func testLiveWifiSessionDefers() {
        XCTAssertEqual(NetworkProfileSwitch.decide(current: .all, requested: .usbOnly, activity: .active(.network)),
                       .deferred)
    }

    // MARK: Real sockets

    /// The USB-only bind address takes IPv4 loopback (the `adb reverse` target) and refuses a connect to this machine's
    /// own non-loopback address, which an `.any` listener accepts.
    func testUsbOnlyListenerRefusesNonLoopbackAddress() throws {
        guard let lan = Self.nonLoopbackIPv4() else {
            throw XCTSkip("no non-loopback IPv4 address on this machine")
        }
        let queue = DispatchQueue(label: "test.profile.listener")
        let usbOnly = try BsdTcpListener(port: 0, bind: NetworkProfile.usbOnly.bindAddress, options: BsdTcpOptions(),
                                         queue: queue)
        defer { usbOnly.cancel() }
        let any = try BsdTcpListener(port: 0, bind: NetworkProfile.all.bindAddress, options: BsdTcpOptions(),
                                     queue: queue)
        defer { any.cancel() }

        XCTAssertEqual(Self.connect(to: "127.0.0.1", port: usbOnly.port), 0, "USB-only must take IPv4 loopback")
        let control = Self.connect(to: lan, port: any.port)
        guard control == 0 else {
            throw XCTSkip("this machine's own non-loopback address is not reachable (errno \(control))")
        }
        let refused = Self.connect(to: lan, port: usbOnly.port)
        XCTAssertNotEqual(refused, 0, "USB-only listener reachable on a non-loopback address")
        XCTAssertEqual(refused, ECONNREFUSED)
    }

    /// Connects a blocking IPv4 client (never accepted: the listeners are not started; the kernel completes the
    /// handshake into the backlog). Returns 0 or the `errno` of `connect`.
    private static func connect(to host: String, port: UInt16) -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { return errno }
        defer { close(fd) }
        var tv = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var a = sockaddr_in()
        a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        a.sin_family = sa_family_t(AF_INET)
        a.sin_port = port.bigEndian
        guard inet_pton(AF_INET, host, &a.sin_addr) == 1 else { return EINVAL }
        let rc = withUnsafePointer(to: &a) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return rc == 0 ? 0 : errno
    }

    /// An up, non-loopback IPv4 address of this machine (nil: none).
    private static func nonLoopbackIPv4() -> String? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(head) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let ifa = cursor {
            defer { cursor = ifa.pointee.ifa_next }
            let flags = Int32(ifa.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0, let addr = ifa.pointee.ifa_addr,
                  addr.pointee.sa_family == sa_family_t(AF_INET) else { continue }
            var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            let ok = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { sin -> Bool in
                var a = sin.pointee.sin_addr
                return inet_ntop(AF_INET, &a, &text, socklen_t(text.count)) != nil
            }
            if ok { return String(decoding: text.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self) }
        }
        return nil
    }
}
