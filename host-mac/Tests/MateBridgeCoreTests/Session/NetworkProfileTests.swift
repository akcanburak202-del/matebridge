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

    // MARK: USB tunnels follow the applied profile (Codex P2 #1)

    /// Stored "USB modu" off, USB-only applied with a live USB session, then the menu turns USB-only off: the switch is
    /// deferred and the tunnels must stay until it takes effect (a video reconnect needs them).
    func testTunnelsStayWhileASwitchAwayFromUsbOnlyIsDeferred() {
        var c = NetworkProfileController(profile: .usbOnly)
        XCTAssertEqual(c.request(.all, activity: .active(.usb), listening: true), .deferred)
        XCTAssertEqual(c.applied, .usbOnly)
        XCTAssertEqual(c.pending, .all)
        XCTAssertTrue(NetworkProfile.usbWatcherEnabled(stored: false, applied: c.applied, requested: c.requested))
        XCTAssertFalse(NetworkProfile.usbModeToggleAllowed(applied: c.applied, requested: c.requested))
        // The session ends: the switch takes effect, only now do the forced tunnels go.
        XCTAssertEqual(c.evaluate(activity: .idle, listening: true), .closeListeners)
        XCTAssertEqual(c.listenersClosed(), .startListeners(.all))
        XCTAssertFalse(NetworkProfile.usbWatcherEnabled(stored: false, applied: c.applied, requested: c.requested))
        XCTAssertTrue(NetworkProfile.usbModeToggleAllowed(applied: c.applied, requested: c.requested))
    }

    func testTunnelsComeUpAtOnceWhenEnteringUsbOnly() {
        XCTAssertTrue(NetworkProfile.usbWatcherEnabled(stored: false, applied: .all, requested: .usbOnly))
        XCTAssertFalse(NetworkProfile.usbWatcherEnabled(stored: false, applied: .all, requested: .all))
        XCTAssertTrue(NetworkProfile.usbWatcherEnabled(stored: true, applied: .all, requested: .all))
        XCTAssertFalse(NetworkProfile.usbModeToggleAllowed(applied: .all, requested: .usbOnly))
    }

    // MARK: Restart sequencing (Codex P2 #2)

    func testRestartStartsOnlyAfterTheOldListenersClosed() {
        var c = NetworkProfileController(profile: .all)
        XCTAssertEqual(c.request(.usbOnly, activity: .idle, listening: true), .closeListeners)
        XCTAssertTrue(c.restarting)
        XCTAssertEqual(c.applied, .all, "not applied before the old listeners closed")
        XCTAssertEqual(c.listenersClosed(), .startListeners(.usbOnly))
        XCTAssertFalse(c.restarting)
        XCTAssertEqual(c.applied, .usbOnly)
        XCTAssertNil(c.pending)
        XCTAssertEqual(c.listenersClosed(), .none, "a stray close callback starts nothing")
    }

    /// `.all -> .usbOnly -> .all` while the first restart's sockets are still closing: one close, one start, of the
    /// latest request; never a second close/start racing the first (which would bind the fixed ports while taken).
    func testRapidTogglesCoalesceIntoOneRestart() {
        var c = NetworkProfileController(profile: .all)
        XCTAssertEqual(c.request(.usbOnly, activity: .idle, listening: true), .closeListeners)
        // Listeners are nil while closing; the server reports not listening.
        XCTAssertEqual(c.request(.all, activity: .idle, listening: false), .none)
        XCTAssertEqual(c.request(.usbOnly, activity: .idle, listening: false), .none)
        XCTAssertEqual(c.request(.all, activity: .idle, listening: false), .none)
        XCTAssertTrue(c.restarting)
        XCTAssertEqual(c.listenersClosed(), .startListeners(.all))
        XCTAssertEqual(c.applied, .all)
        XCTAssertNil(c.pending)
        // A new toggle after the restart finished is a fresh restart.
        XCTAssertEqual(c.request(.usbOnly, activity: .idle, listening: true), .closeListeners)
        XCTAssertEqual(c.listenersClosed(), .startListeners(.usbOnly))
    }

    func testDeferredSwitchAppliesWhenTheSessionEnds() {
        var c = NetworkProfileController(profile: .all)
        XCTAssertEqual(c.request(.usbOnly, activity: .active(.network), listening: true), .deferred)
        XCTAssertEqual(c.evaluate(activity: .active(.network), listening: true), .deferred)
        XCTAssertEqual(c.pending, .usbOnly)
        // Toggled back while deferred: nothing waits any more.
        XCTAssertEqual(c.request(.all, activity: .active(.network), listening: true), .none)
        XCTAssertNil(c.pending)
        XCTAssertEqual(c.request(.usbOnly, activity: .active(.network), listening: true), .deferred)
        XCTAssertEqual(c.evaluate(activity: .idle, listening: true), .closeListeners)
        XCTAssertEqual(c.listenersClosed(), .startListeners(.usbOnly))
    }

    /// Not listening (before start, stopped, failure restart pending): stored for the next listener start.
    func testNotListeningStoresTheProfile() {
        var c = NetworkProfileController(profile: .all)
        XCTAssertEqual(c.request(.usbOnly, activity: .idle, listening: false), .none)
        XCTAssertEqual(c.applied, .usbOnly)
        XCTAssertFalse(c.restarting)
    }

    // MARK: Real sockets

    /// `cancel(onClosed:)` reports once the descriptor is closed: the same port binds again right then (a profile
    /// restart must not fall back to a system-assigned port).
    func testCancelOnClosedFreesThePortForAnImmediateRebind() throws {
        let queue = DispatchQueue(label: "test.profile.rebind")
        for round in 0..<20 {
            let first = try BsdTcpListener(port: 0, bind: .any, options: BsdTcpOptions(), queue: queue)
            first.start { _ in }
            let port = first.port
            let closed = expectation(description: "closed \(round)")
            let rebound = LockedBox<Result<BsdTcpListener, Error>?>(nil)
            first.cancel {
                rebound.set(Result { try BsdTcpListener(port: port, bind: .loopbackV4Mapped,
                                                        options: BsdTcpOptions(), queue: queue) })
                closed.fulfill()
            }
            wait(for: [closed], timeout: 5)
            let second = try XCTUnwrap(rebound.get()).get()
            XCTAssertEqual(second.port, port)
            second.cancel()
        }
    }

    func testCancelOnClosedRunsForUnstartedAndAlreadyCancelledListeners() throws {
        let queue = DispatchQueue(label: "test.profile.cancel")
        let unstarted = try BsdTcpListener(port: 0, bind: .loopbackV6, options: BsdTcpOptions(), queue: queue)
        let a = expectation(description: "unstarted")
        unstarted.cancel { a.fulfill() }
        let b = expectation(description: "again")
        unstarted.cancel { b.fulfill() }
        let started = try BsdTcpListener(port: 0, bind: .loopbackV6, options: BsdTcpOptions(), queue: queue)
        started.start { _ in }
        started.cancel()
        let c = expectation(description: "started, cancelled before")
        started.cancel { c.fulfill() }
        wait(for: [a, b, c], timeout: 5)
    }

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

private final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func get() -> Value { lock.withLock { value } }
    func set(_ v: Value) { lock.withLock { value = v } }
}
