import Darwin
import XCTest
import dnssd
@testable import MateBridgeCore

/// T-111: the control connection on a kernel socket. Real loopback sockets, the real `SessionMachine` and a blocking
/// client socket playing the tablet. `ControlHost` routes bytes and actions the way `SessionServer` does for
/// `MATEBRIDGE_CONTROL_SOCKET=bsd` (`acceptControl`, `receiveControlBytes`, `sendControlBytes`, `closeControl`,
/// `transportClosed`); the Host target itself is not reachable from this test target.
final class ControlSocketTests: XCTestCase {
    private static let device = DeviceID(bytes: [UInt8](repeating: 1, count: 16))!
    private static let pairKey = SecretBytes([UInt8](repeating: 7, count: 32))
    private static let config = StreamConfig(configID: 1, codec: .hevc, widthPx: 2800, heightPx: 1840, widthPt: 1400,
                                             heightPt: 920, fps: 60, bitrateKbps: 40_000, colorPrimaries: 1,
                                             transfer: 1, matrix: 1, fullRange: true)

    /// What `SessionServer.controlSocketOptions` sets (low-water mark of 9 sealed audio packets), with user-space
    /// bounds large enough for these tests to fill the kernel.
    static let controlOptions = BsdTcpOptions(notSentLowatBytes: 9 * 1969, maxPendingRecords: 1 << 16,
                                              maxPendingBytes: 64 << 20)

    // MARK: Harness: host side

    /// The `SessionServer` control path in miniature, confined to `queue`.
    private final class ControlHost: @unchecked Sendable {
        let queue = DispatchQueue(label: "test.control.session")
        var listener: BsdTcpListener!
        private var machine: SessionMachine
        private var connections: [ConnectionID: BsdTcpConnection] = [:]
        private var inbounds: [ConnectionID: ControlInbound] = [:]
        private var sealers: [ConnectionID: RecordSealer] = [:]
        private var nextID: UInt64 = 0
        private var delivered: [Message] = []
        private var releases: [ReleaseCause] = []
        private var peers: [String?] = []
        private var flushed = 0

        init(bind: BsdTcpListener.BindAddress = .loopbackV6) throws {
            machine = SessionMachine(configuration: .init(hostName: "Mac", makeStreamConfig: { _ in ControlSocketTests.config },
                                                          makeSessionID: { 42 },
                                                          pairKeys: InMemoryPairKeyStore(keys: [
                                                              ControlSocketTests.device: ControlSocketTests.pairKey])),
                                     approvedDevices: [ControlSocketTests.device])
            machine.videoPort = 5555
            listener = try BsdTcpListener(port: 0, bind: bind,
                                          options: ControlSocketTests.controlOptions, queue: queue)
            listener.start { [self] event in
                guard case .accepted(let c) = event else { return }
                accept(c)
            }
        }

        var port: UInt16 { listener.port }

        /// Reads the host state on its queue.
        func inspect<T>(_ body: (ControlHost) -> T) -> T { queue.sync { body(self) } }
        var deliveredMessages: [Message] { inspect { $0.delivered } }
        var releaseCauses: [ReleaseCause] { inspect { $0.releases } }
        var openConnections: Int { inspect { $0.connections.count } }
        var peerHosts: [String?] { inspect { $0.peers } }
        var flushCount: Int { inspect { $0.flushed } }
        var status: SessionStatus { inspect { $0.machine.status } }

        /// "Host shuts down": BYE(SHUTTING_DOWN) to every peer, release, graceful close.
        func shutdown() { queue.sync { apply(machine.shutdown()) } }

        private func now() -> UInt64 { HostClockForTests.nowUs() }

        private func accept(_ c: BsdTcpConnection) {
            nextID += 1
            let id = ConnectionID(nextID)
            peers.append(c.peerHost)
            c.start(queue: queue, onBytes: { [self] bytes in
                guard connections[id] != nil else { return true }
                if receive(id, bytes) { return true }
                return connections[id] == nil
            }, onClosed: { [self] in transportClosed(id) })
            connections[id] = c
            inbounds[id] = ControlInbound()
            apply(machine.connectionOpened(id, now: now()))
        }

        private func receive(_ id: ConnectionID, _ bytes: [UInt8]) -> Bool {
            guard inbounds[id] != nil else { return false }
            inbounds[id]!.append(bytes)
            do {
                while let m = try inbounds[id]?.nextMessage() {
                    apply(machine.received(id, m, now: now()))
                    if inbounds[id] == nil { return false }
                }
            } catch is CryptoError {
                apply(machine.recordAuthFailed(id, counter: inbounds[id]?.recordCounter ?? 0))
                return false
            } catch {
                apply(machine.protocolError(id))
                return false
            }
            return true
        }

        private func transportClosed(_ id: ConnectionID) {
            guard let c = connections.removeValue(forKey: id) else { return }
            c.cancel()
            inbounds[id] = nil
            sealers[id] = nil
            apply(machine.connectionClosed(id))
        }

        private func apply(_ actions: [SessionAction]) {
            for action in actions {
                switch action {
                case .send(let id, let message):
                    guard let c = connections[id] else { continue }
                    let bytes = sealers[id] != nil ? try! message.sealed(using: &sealers[id]!) : try! message.encode()
                    if !c.write(bytes, completion: { _ in }) { transportClosed(id) }
                case .startEncryption(let id, let keys):
                    sealers[id] = RecordSealer(key: keys.h2c, maxPayload: ProtocolConstants.maxControlPayload)
                    try! inbounds[id]?.enableEncryption(key: keys.c2h)
                case .close(let id):
                    guard let c = connections.removeValue(forKey: id) else { continue }
                    inbounds[id] = nil
                    sealers[id] = nil
                    c.finish(timeout: .seconds(2)) { [self] in queue.async { self.flushed += 1 } }
                case .releaseInput(_, let cause):
                    releases.append(cause)
                case .deliver(_, let message):
                    delivered.append(message)
                default:
                    break
                }
            }
        }
    }

    // MARK: Harness: tablet side

    private enum Family { case v6, v4 }

    private static func connectClient(port: UInt16, family: Family = .v6, receiveBuffer: Int32? = nil) -> Int32 {
        let fd = socket(family == .v4 ? AF_INET : AF_INET6, SOCK_STREAM, IPPROTO_TCP)
        precondition(fd >= 0)
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var tv = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        if var rcv = receiveBuffer {
            setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &rcv, socklen_t(MemoryLayout<Int32>.size))
        }
        let rc: Int32
        switch family {
        case .v4:
            var a = sockaddr_in()
            a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            a.sin_family = sa_family_t(AF_INET)
            a.sin_port = port.bigEndian
            a.sin_addr.s_addr = inet_addr("127.0.0.1")
            rc = withUnsafePointer(to: &a) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        case .v6:
            var a = sockaddr_in6()
            a.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            a.sin6_family = sa_family_t(AF_INET6)
            a.sin6_port = port.bigEndian
            a.sin6_addr = in6addr_loopback
            rc = withUnsafePointer(to: &a) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
                }
            }
        }
        precondition(rc == 0, "connect errno \(errno)")
        return fd
    }

    private static func writeAll(_ fd: Int32, _ bytes: [UInt8]) {
        var off = 0
        while off < bytes.count {
            let n = bytes[off...].withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
            guard n > 0 else { return XCTFail("client write errno \(errno)") }
            off += n
        }
    }

    /// The tablet: plain HELLO, plain HELLO_ACK, then records both ways.
    private struct Tablet {
        let fd: Int32
        var client = TestClient()
        var pending: [UInt8] = []
        var received: [Message] = []
        var sawEOF = false

        init(port: UInt16, family: Family = .v6) {
            fd = ControlSocketTests.connectClient(port: port, family: family)
        }

        /// One blocking read (5 s timeout). False on timeout, error or end of stream.
        mutating func readSome() -> Bool {
            var buf = [UInt8](repeating: 0, count: 65_536)
            let n = buf.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if n == 0 { sawEOF = true }
            guard n > 0 else { return false }
            pending += buf[..<n]
            return true
        }

        /// HELLO out, HELLO_ACK (plain) in; on ACCEPTED the proof PING goes out first, as the client sends it (the
        /// host activates the session only on that first authenticated record, T-152), and its PONG is awaited so
        /// the session is active on return. Returns the ack status.
        mutating func handshake() throws -> HelloStatus? {
            ControlSocketTests.writeAll(fd, try client.message.encode())
            while true {
                if pending.count >= ProtocolConstants.headerSize {
                    let l = (0..<4).reduce(0) { $0 | Int(pending[1 + $1]) << (8 * $1) }
                    let total = ProtocolConstants.headerSize + l
                    if pending.count >= total {
                        var d = FrameDecoder(connection: .control)
                        d.append(Array(pending[..<total]))
                        guard case .helloAck(let ack)? = try d.nextMessage() else { return nil }
                        pending.removeFirst(total)
                        if ack.status == .accepted {
                            try client.receiveFirstAck(ack, pairKey: ControlSocketTests.pairKey)
                            try send(.ping(Ping(seq: 0, senderTimeUs: 0)))
                            try openPending()
                            try read { $0.contains { if case .pong = $0 { true } else { false } } }
                        }
                        try openPending()
                        return ack.status
                    }
                }
                guard readSome() else { return nil }
            }
        }

        mutating func openPending() throws {
            guard !pending.isEmpty else { return }
            received += try client.open(pending)
            pending.removeAll()
        }

        /// Reads until `done` holds, end of stream or timeout.
        mutating func read(until done: ([Message]) -> Bool) throws {
            while !done(received) {
                guard readSome() else { return }
                try openPending()
            }
        }

        mutating func send(_ m: Message) throws { ControlSocketTests.writeAll(fd, try client.seal(m)) }

        /// Reads until end of stream (true) or timeout/error (false).
        mutating func readToEnd() throws -> Bool {
            while readSome() { try openPending() }
            return sawEOF
        }
    }

    private func waitUntil(_ timeout: Double = 5, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            usleep(5_000)
        }
        return condition()
    }

    private static let keyDown = Message.key(KeyEvent(timeUs: 1, scanCode: 30, androidKeyCode: 29, action: .down,
                                                      capsLockOn: false))

    // MARK: Session over a real socket

    private enum Disconnect { case close, halfClose, reset }

    /// HELLO -> ACCEPTED (+ STREAM_CONFIG, encrypted) -> encrypted input delivered -> the tablet goes -> release-all.
    private func runSession(_ disconnect: Disconnect, family: Family = .v6,
                            bind: BsdTcpListener.BindAddress = .loopbackV6) throws {
        let host = try ControlHost(bind: bind)
        var tablet = Tablet(port: host.port, family: family)
        defer { close(tablet.fd) }

        XCTAssertEqual(try tablet.handshake(), .accepted)
        try tablet.read { $0.contains(.streamConfig(Self.config)) }
        XCTAssertTrue(tablet.received.contains(.streamConfig(Self.config)))
        XCTAssertEqual(host.status, .active(deviceName: "Pad", sessionID: 42))

        try tablet.send(Self.keyDown)
        XCTAssertTrue(waitUntil { host.deliveredMessages.contains(Self.keyDown) }, "input not delivered")
        XCTAssertTrue(host.releaseCauses.isEmpty)

        switch disconnect {
        case .close:
            close(tablet.fd)
        case .halfClose:
            shutdown(tablet.fd, SHUT_WR)
        case .reset:
            var linger = Darwin.linger(l_onoff: 1, l_linger: 0)
            setsockopt(tablet.fd, SOL_SOCKET, SO_LINGER, &linger, socklen_t(MemoryLayout<Darwin.linger>.size))
            close(tablet.fd)
        }
        XCTAssertTrue(waitUntil { host.releaseCauses.contains(.disconnected) }, "no release-all after \(disconnect)")
        XCTAssertTrue(waitUntil { host.openConnections == 0 })
        XCTAssertEqual(host.status, .idle)
        if disconnect == .halfClose {
            XCTAssertTrue(try tablet.readToEnd(), "host did not close after the tablet's half close")
        }
        host.listener.cancel()
    }

    func testPeerCloseReleasesAllInput() throws { try runSession(.close) }

    func testPeerHalfCloseReleasesAllInput() throws { try runSession(.halfClose) }

    func testPeerResetReleasesAllInput() throws { try runSession(.reset) }

    /// USB: `adb reverse` connects over IPv4 loopback; the dual-stack socket sees `::ffff:127.0.0.1` -> `usb`.
    func testIPv4LoopbackSessionIsClassifiedUsb() throws {
        let host = try ControlHost(bind: .loopbackV4Mapped)
        var tablet = Tablet(port: host.port, family: .v4)
        defer { close(tablet.fd) }
        XCTAssertEqual(try tablet.handshake(), .accepted)
        let peers = host.peerHosts
        XCTAssertEqual(peers.count, 1)
        XCTAssertEqual(SessionTransport.classify(peerHost: peers.first ?? nil), .usb, "\(peers)")
        host.listener.cancel()
    }

    /// Host shutdown: BYE(SHUTTING_DOWN) reaches the tablet before end of stream, input is released, the graceful
    /// close completes.
    func testHostShutdownFlushesByeThenEndOfStream() throws {
        let host = try ControlHost()
        var tablet = Tablet(port: host.port)
        defer { close(tablet.fd) }
        XCTAssertEqual(try tablet.handshake(), .accepted)
        host.shutdown()
        XCTAssertTrue(try tablet.readToEnd())  // the host's FIN
        XCTAssertEqual(tablet.received.last, .bye(.shuttingDown))
        XCTAssertEqual(host.releaseCauses, [.shutdown])
        // The host keeps its side open (reading) until the tablet closes its own, as the client does after BYE.
        XCTAssertEqual(host.flushCount, 0)
        shutdown(tablet.fd, SHUT_WR)
        XCTAssertTrue(waitUntil { host.flushCount == 1 })
        host.listener.cancel()
    }

    /// A bad record from the tablet: no BYE (untrusted channel), input released, connection closed.
    func testForgedRecordReleasesAndCloses() throws {
        let host = try ControlHost()
        var tablet = Tablet(port: host.port)
        defer { close(tablet.fd) }
        XCTAssertEqual(try tablet.handshake(), .accepted)
        var forged = try tablet.client.seal(Self.keyDown)
        forged[forged.count - 1] ^= 0xff  // breaks the tag
        Self.writeAll(tablet.fd, forged)
        XCTAssertTrue(waitUntil { host.releaseCauses.contains(.protocolError) })
        XCTAssertTrue(try tablet.readToEnd())
        XCTAssertFalse(host.deliveredMessages.contains(Self.keyDown))
        host.listener.cancel()
    }

    // MARK: Ordering and the audio gate

    /// A 60 KB record between small ones, to a slow reader with a tiny receive buffer: partial writes never mix
    /// records, every record arrives whole and in order.
    func testLargeAndSmallRecordsKeepOrder() throws {
        let queue = DispatchQueue(label: "test.control.order")
        let listener = try BsdTcpListener(port: 0, bind: .loopbackV6, options: Self.controlOptions,
                                          queue: queue)
        let accepted = DispatchSemaphore(value: 0)
        let box = Box<BsdTcpConnection>()
        listener.start { event in
            guard case .accepted(let c) = event else { return }
            c.start(queue: queue, onBytes: { _ in true }, onClosed: {})
            box.value = c
            accepted.signal()
        }
        let fd = Self.connectClient(port: listener.port, receiveBuffer: 4096)
        defer { close(fd) }
        XCTAssertEqual(accepted.wait(timeout: .now() + 5), .success)
        let connection = try XCTUnwrap(box.value)

        let key = SecretBytes([UInt8](repeating: 0x33, count: 32))
        var sealer = RecordSealer(key: key, maxPayload: ProtocolConstants.maxControlPayload)
        var expected: [Message] = []
        func audio(_ seq: UInt32) -> Message {
            .audioFrame(AudioFrame(streamID: 1, seq: seq, sampleIndex: UInt64(seq) * 480, captureTimeUs: 0,
                                   frameCount: 480, data: [UInt8](repeating: UInt8(truncatingIfNeeded: seq), count: 1920)))
        }
        let clipboardText = (0..<ProtocolConstants.clipboardMaxBytes).map { UInt8(65 + $0 % 26) }
        let completions = Counter()
        func send(_ m: Message) throws {
            expected.append(m)
            XCTAssertTrue(connection.write(try m.sealed(using: &sealer)) { ok in if ok { completions.increment() } })
        }
        // Small, large, small... until the kernel is full and records wait in user space (partial writes happen).
        var seq: UInt32 = 0
        for cycle in 0..<400 where connection.pendingBytes == 0 {
            for _ in 0..<5 { try send(audio(seq)); seq += 1 }
            try send(.clipboard(Clipboard(seq: UInt32(cycle), kind: Clipboard.kindTextUTF8, data: clipboardText)))
        }
        for _ in 0..<20 { try send(audio(seq)); seq += 1 }
        try send(.bye(.shuttingDown))
        XCTAssertGreaterThan(connection.pendingBytes, 0, "the slow reader should leave records in user space")
        let flushed = DispatchSemaphore(value: 0)
        connection.finish(timeout: .seconds(5)) { flushed.signal() }

        var decoder = RecordDecoder(key: key, connection: .control)
        var got: [Message] = []
        var buf = [UInt8](repeating: 0, count: 4096)
        while true {
            usleep(20)  // a slow reader
            let n = buf.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            guard n > 0 else { break }
            decoder.append(Array(buf[..<n]))
            while let m = try decoder.nextMessage() { got.append(m) }
        }
        XCTAssertEqual(got.count, expected.count)
        XCTAssertTrue(got == expected, "records out of order or damaged")
        shutdown(fd, SHUT_WR)  // the tablet saw the BYE and closes its side
        XCTAssertEqual(flushed.wait(timeout: .now() + 5), .success)
        XCTAssertTrue(waitUntil { completions.value == expected.count })
        listener.cancel()
    }

    /// The audio gate: with the peer not reading, the socket stops reading as writable once the kernel holds the
    /// low-water mark of unsent bytes (audio is then dropped), but writes are still taken (BYE never waits). Once
    /// the peer reads, the gate opens again.
    func testNotSentLowatGatesWithoutBlockingWrites() throws {
        let queue = DispatchQueue(label: "test.control.gate")
        let listener = try BsdTcpListener(port: 0, bind: .loopbackV6, options: Self.controlOptions,
                                          queue: queue)
        let accepted = DispatchSemaphore(value: 0)
        let box = Box<BsdTcpConnection>()
        listener.start { event in
            guard case .accepted(let c) = event else { return }
            c.start(queue: queue, onBytes: { _ in true }, onClosed: {})
            box.value = c
            accepted.signal()
        }
        let fd = Self.connectClient(port: listener.port, receiveBuffer: 4096)
        defer { close(fd) }
        XCTAssertEqual(accepted.wait(timeout: .now() + 5), .success)
        let connection = try XCTUnwrap(box.value)

        XCTAssertTrue(connection.isWritableForNewRecord)
        let record = [UInt8](repeating: 0x5a, count: 1969)  // one sealed 10 ms audio packet
        var written = 0
        while connection.isWritableForNewRecord, written < 1000 {
            XCTAssertTrue(connection.write(record) { _ in })
            written += 1
        }
        // Loopback receive buffers absorb a few hundred KB first; after that bytes stay unsent and the gate closes.
        XCTAssertFalse(connection.isWritableForNewRecord, "gate never closed")
        // A control message still goes out while audio is gated.
        XCTAssertTrue(connection.write([1, 2, 3]) { _ in })

        // The tablet reads everything: the gate reopens.
        let total = written * record.count + 3
        var read = 0
        var buf = [UInt8](repeating: 0, count: 65_536)
        while read < total {
            let n = buf.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            guard n > 0 else { break }
            read += n
        }
        XCTAssertEqual(read, total)
        XCTAssertTrue(waitUntil { connection.isWritableForNewRecord }, "gate did not reopen")
        connection.cancel()
        listener.cancel()
    }

    // MARK: Graceful close

    func testFinishRefusesNewWritesAndCompletesOnce() throws {
        let queue = DispatchQueue(label: "test.control.finish")
        let listener = try BsdTcpListener(port: 0, bind: .loopbackV6, options: BsdTcpOptions(), queue: queue)
        let accepted = DispatchSemaphore(value: 0)
        let closed = Counter()
        let read = Counter()
        let box = Box<BsdTcpConnection>()
        listener.start { event in
            guard case .accepted(let c) = event else { return }
            c.start(queue: queue, onBytes: { b in read.add(b.count); return true }, onClosed: { closed.increment() })
            box.value = c
            accepted.signal()
        }
        let fd = Self.connectClient(port: listener.port, receiveBuffer: 4096)
        defer { close(fd) }
        XCTAssertEqual(accepted.wait(timeout: .now() + 5), .success)
        let connection = try XCTUnwrap(box.value)

        let big = [UInt8](repeating: 0x11, count: 1 << 20)
        XCTAssertTrue(connection.write(big) { _ in })
        XCTAssertGreaterThan(connection.pendingBytes, 0)
        let finished = Counter()
        connection.finish(timeout: .seconds(5)) { finished.increment() }
        connection.finish(timeout: .seconds(5)) { finished.increment() }  // a second call also completes, once
        let refused = DispatchSemaphore(value: 0)
        XCTAssertFalse(connection.write([9]) { ok in if !ok { refused.signal() } })
        XCTAssertEqual(refused.wait(timeout: .now() + 2), .success)

        // Bytes from the tablet while finishing are discarded.
        Self.writeAll(fd, [1, 2, 3, 4])
        var total = 0
        var buf = [UInt8](repeating: 0, count: 65_536)
        while true {
            let n = buf.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            guard n > 0 else { XCTAssertEqual(n, 0, "expected end of stream, errno \(errno)"); break }
            total += n
        }
        XCTAssertEqual(total, big.count, "every queued byte arrives before the FIN")
        // Our FIN went out, but the host still reads until the tablet closes its side.
        usleep(50_000)
        XCTAssertEqual(finished.value, 0)
        XCTAssertEqual(closed.value, 0)
        shutdown(fd, SHUT_WR)
        XCTAssertTrue(waitUntil { finished.value == 2 && closed.value == 1 })
        XCTAssertEqual(read.value, 0)
        usleep(50_000)
        XCTAssertEqual(finished.value, 2)
        XCTAssertEqual(closed.value, 1)
        // After close: completes right away.
        let late = DispatchSemaphore(value: 0)
        connection.finish(timeout: .seconds(1)) { late.signal() }
        XCTAssertEqual(late.wait(timeout: .now() + 2), .success)
        listener.cancel()
    }

    /// The tablet keeps sending (pen, PING) while the host closes, and reads slowly: input the host has not read yet
    /// when it closes must not turn the close into a reset that drops the BYE still unsent in the kernel. The host
    /// keeps reading (and discarding) after its FIN until the tablet's end of stream.
    func testFinishDeliversByeWhileTabletKeepsSending() throws {
        let queue = DispatchQueue(label: "test.control.finish.inbound")
        let listener = try BsdTcpListener(port: 0, bind: .loopbackV6, options: Self.controlOptions, queue: queue)
        let accepted = DispatchSemaphore(value: 0)
        let closed = DispatchSemaphore(value: 0)
        let box = Box<BsdTcpConnection>()
        listener.start { event in
            guard case .accepted(let c) = event else { return }
            c.start(queue: queue, onBytes: { _ in true }, onClosed: { closed.signal() })
            box.value = c
            accepted.signal()
        }
        let fd = Self.connectClient(port: listener.port, receiveBuffer: 4096)
        defer { close(fd) }
        XCTAssertEqual(accepted.wait(timeout: .now() + 5), .success)
        let connection = try XCTUnwrap(box.value)

        // The tablet's input stream: a small write every 0.5 ms (pen samples), on its own thread, until it saw the BYE.
        let senderDone = DispatchSemaphore(value: 0)
        let stopSending = Counter()
        Thread.detachNewThread {
            let chunk = [UInt8](repeating: 0x77, count: 256)
            while stopSending.value == 0 {
                let n = chunk.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
                if n <= 0 { break }
                usleep(500)
            }
            senderDone.signal()
        }
        usleep(20_000)  // input is flowing

        // The host's last messages: a backlog the slow reader holds unsent in the kernel, then the BYE marker.
        let backlog = [UInt8](repeating: 0x42, count: 4 << 20)
        let bye: [UInt8] = [0x04, 0x01, 0x00, 0x00, 0x00, 0x05]  // stands in for a sealed BYE
        XCTAssertTrue(connection.write(backlog) { _ in })
        XCTAssertTrue(connection.write(bye) { _ in })
        let finished = DispatchSemaphore(value: 0)
        connection.finish(timeout: .seconds(5)) { finished.signal() }

        var got: [UInt8] = []
        var buf = [UInt8](repeating: 0, count: 4096)
        while got.count < backlog.count + bye.count {
            usleep(100)  // a slow reader
            let n = buf.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            guard n > 0 else { break }
            got += buf[..<n]
        }
        XCTAssertEqual(got.count, backlog.count + bye.count, "the stream ended early (errno \(errno))")
        XCTAssertEqual(Array(got.suffix(bye.count)), bye, "BYE lost or damaged")

        // The tablet saw the BYE: it stops sending and closes its side; then the host closes.
        stopSending.increment()
        XCTAssertEqual(senderDone.wait(timeout: .now() + 5), .success)
        shutdown(fd, SHUT_WR)
        XCTAssertEqual(finished.wait(timeout: .now() + 3), .success)
        XCTAssertEqual(closed.wait(timeout: .now() + 2), .success)
        let n = buf.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
        XCTAssertEqual(n, 0, "expected end of stream")
        listener.cancel()
    }

    /// A tablet that reads everything but never closes its side: the host closes at the deadline.
    func testFinishClosesAtDeadlineWhenPeerKeepsItsSideOpen() throws {
        let queue = DispatchQueue(label: "test.control.finish.linger")
        let listener = try BsdTcpListener(port: 0, bind: .loopbackV6, options: BsdTcpOptions(), queue: queue)
        let accepted = DispatchSemaphore(value: 0)
        let closed = DispatchSemaphore(value: 0)
        let box = Box<BsdTcpConnection>()
        listener.start { event in
            guard case .accepted(let c) = event else { return }
            c.start(queue: queue, onBytes: { _ in true }, onClosed: { closed.signal() })
            box.value = c
            accepted.signal()
        }
        let fd = Self.connectClient(port: listener.port)
        defer { close(fd) }
        XCTAssertEqual(accepted.wait(timeout: .now() + 5), .success)
        let connection = try XCTUnwrap(box.value)

        let delivered = DispatchSemaphore(value: 0)
        XCTAssertTrue(connection.write([7, 7, 7]) { ok in if ok { delivered.signal() } })
        let finished = DispatchSemaphore(value: 0)
        let start = Date()
        connection.finish(timeout: .milliseconds(300)) { finished.signal() }
        var buf = [UInt8](repeating: 0, count: 16)
        XCTAssertEqual(buf.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }, 3)
        XCTAssertEqual(buf.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }, 0, "no FIN")
        XCTAssertEqual(delivered.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(finished.wait(timeout: .now() + 5), .success)
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(start), 0.25)
        XCTAssertEqual(closed.wait(timeout: .now() + 2), .success)
        listener.cancel()
    }

    /// A tablet that never reads: the graceful close gives up after its timeout, the unwritten record fails.
    func testFinishTimesOutWhenPeerDoesNotRead() throws {
        let queue = DispatchQueue(label: "test.control.finish.timeout")
        let listener = try BsdTcpListener(port: 0, bind: .loopbackV6, options: BsdTcpOptions(), queue: queue)
        let accepted = DispatchSemaphore(value: 0)
        let closed = DispatchSemaphore(value: 0)
        let box = Box<BsdTcpConnection>()
        listener.start { event in
            guard case .accepted(let c) = event else { return }
            c.start(queue: queue, onBytes: { _ in true }, onClosed: { closed.signal() })
            box.value = c
            accepted.signal()
        }
        let fd = Self.connectClient(port: listener.port, receiveBuffer: 4096)
        defer { close(fd) }
        XCTAssertEqual(accepted.wait(timeout: .now() + 5), .success)
        let connection = try XCTUnwrap(box.value)

        let failed = DispatchSemaphore(value: 0)
        XCTAssertTrue(connection.write([UInt8](repeating: 0x22, count: 8 << 20)) { ok in if !ok { failed.signal() } })
        let finished = DispatchSemaphore(value: 0)
        let start = Date()
        connection.finish(timeout: .milliseconds(300)) { finished.signal() }
        XCTAssertEqual(finished.wait(timeout: .now() + 5), .success)
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(start), 0.25)
        XCTAssertEqual(failed.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(closed.wait(timeout: .now() + 2), .success)
        listener.cancel()
    }

    // MARK: Bonjour

    func testBonjourNameAndTxtRecord() {
        XCTAssertEqual(BonjourAdvertiser.instanceName("Mac mini"), "Mac mini")
        XCTAssertEqual(BonjourAdvertiser.instanceName(""), "Mac")
        let long = String(repeating: "ü", count: 40)  // 80 UTF-8 bytes
        let cut = BonjourAdvertiser.instanceName(long)
        XCTAssertEqual(cut.utf8.count, 62)  // 31 whole characters, never half of one
        XCTAssertEqual(cut, String(repeating: "ü", count: 31))
        XCTAssertEqual(BonjourAdvertiser.instanceName(String(repeating: "a", count: 63)).utf8.count, 63)

        XCTAssertEqual(BonjourAdvertiser.txtRecord([("v", "1")]), [3, 0x76, 0x3d, 0x31])
        XCTAssertEqual(BonjourAdvertiser.txtRecord([]), [0])
        XCTAssertEqual(BonjourAdvertiser.txtRecord([("k", String(repeating: "x", count: 300)), ("v", "1")]),
                       [3, 0x76, 0x3d, 0x31])
    }

    /// Registers on this Mac only (never on the network) under a test type and finds it with a browse.
    func testBonjourRegistersLocally() throws {
        let queue = DispatchQueue(label: "test.bonjour")
        let type = "_mbt\(String(UInt32.random(in: 0..<0xffffff), radix: 16))._tcp"
        let registered = DispatchSemaphore(value: 0)
        let advertiser: BonjourAdvertiser
        do {
            advertiser = try BonjourAdvertiser(name: "MateBridge Test", type: type, port: 40_123, txt: [("v", "1")],
                                               scope: .localOnly, queue: queue) { event in
                if event == .registered { registered.signal() }
            }
        } catch let error as BonjourError where error.code == kDNSServiceErr_ServiceNotRunning {
            throw XCTSkip("mDNSResponder not reachable")
        }
        XCTAssertEqual(registered.wait(timeout: .now() + 5), .success, "no registration callback")

        let found = BrowseResult()
        var browseRef: DNSServiceRef?
        let context = Unmanaged.passRetained(found)
        let err = DNSServiceBrowse(&browseRef, 0, kDNSServiceInterfaceIndexLocalOnly, type, nil, { _, flags, _, error, name, _, _, ctx in
            guard error == kDNSServiceErr_NoError, Int(flags) & Int(kDNSServiceFlagsAdd) != 0, let name, let ctx else { return }
            Unmanaged<BrowseResult>.fromOpaque(ctx).takeUnretainedValue().found(String(cString: name))
        }, context.toOpaque())
        XCTAssertEqual(Int(err), Int(kDNSServiceErr_NoError))
        let ref = try XCTUnwrap(browseRef)
        XCTAssertEqual(Int(DNSServiceSetDispatchQueue(ref, queue)), Int(kDNSServiceErr_NoError))
        XCTAssertEqual(found.signal.wait(timeout: .now() + 5), .success, "service not found by browsing")
        XCTAssertEqual(found.names.first, "MateBridge Test")
        queue.sync {
            DNSServiceRefDeallocate(ref)
            context.release()
        }
        advertiser.cancel()
        advertiser.cancel()  // idempotent
        queue.sync {}
    }
}

// MARK: Small helpers

private enum HostClockForTests {
    static func nowUs() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) / 1000 }
}

private final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T?
    var value: T? {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func increment() { add(1) }
    func add(_ k: Int) { lock.withLock { n += k } }
    var value: Int { lock.withLock { n } }
}

private final class BrowseResult: @unchecked Sendable {
    private let lock = NSLock()
    private var _names: [String] = []
    let signal = DispatchSemaphore(value: 0)
    func found(_ name: String) {
        lock.withLock { _names.append(name) }
        signal.signal()
    }
    var names: [String] { lock.withLock { _names } }
}
