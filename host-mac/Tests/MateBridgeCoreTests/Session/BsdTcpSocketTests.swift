import Darwin
import XCTest
@testable import MateBridgeCore

/// T-091: real kernel sockets on loopback. `BsdTcpListener` + `BsdTcpConnection` + `SocketVideoTransport` against a
/// plain blocking client socket playing the tablet: VIDEO_HELLO in, sealed VIDEO_FRAME records out, close.
final class BsdTcpSocketTests: XCTestCase {
    private let key = SecretBytes([UInt8](repeating: 0x42, count: 32))

    // MARK: Harness

    /// Server side: the accepted connection, bytes it read, and how often it closed.
    private final class Server: @unchecked Sendable {
        let queue = DispatchQueue(label: "test.bsd.session")
        private let lock = NSLock()
        private var _connection: BsdTcpConnection?
        private var _received: [UInt8] = []
        private var _closed = 0
        let accepted = DispatchSemaphore(value: 0)
        let receivedSome = DispatchSemaphore(value: 0)
        let closedSignal = DispatchSemaphore(value: 0)
        var listener: BsdTcpListener!

        var connection: BsdTcpConnection? { lock.withLock { _connection } }
        var received: [UInt8] { lock.withLock { _received } }
        var closedCount: Int { lock.withLock { _closed } }

        init(bind: BsdTcpListener.BindAddress = .loopbackV6, options: BsdTcpOptions) throws {
            listener = try BsdTcpListener(port: 0, bind: bind, options: options, queue: queue)
            listener.start { [self] event in
                guard case .accepted(let c) = event else { return }
                lock.withLock { _connection = c }
                c.start(queue: queue, onBytes: { [self] bytes in
                    lock.withLock { _received += bytes }
                    receivedSome.signal()
                    return true
                }, onClosed: { [self] in
                    lock.withLock { _closed += 1 }
                    closedSignal.signal()
                })
                accepted.signal()
            }
        }

        func waitAccepted() -> BsdTcpConnection? {
            accepted.wait(timeout: .now() + 5) == .success ? connection : nil
        }
    }

    private func connectClient(port: UInt16, v4: Bool = false, receiveBuffer: Int32? = nil) -> Int32 {
        let fd = socket(v4 ? AF_INET : AF_INET6, SOCK_STREAM, IPPROTO_TCP)
        XCTAssertGreaterThanOrEqual(fd, 0)
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var tv = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        if var rcv = receiveBuffer {
            setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &rcv, socklen_t(MemoryLayout<Int32>.size))
        }
        let rc: Int32
        if v4 {
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
        } else {
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
        XCTAssertEqual(rc, 0, "connect errno \(errno)")
        return fd
    }

    private func writeAll(_ fd: Int32, _ bytes: [UInt8]) {
        var off = 0
        while off < bytes.count {
            let n = bytes[off...].withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
            guard n > 0 else { return XCTFail("client write errno \(errno)") }
            off += n
        }
    }

    /// Reads until end of stream (or error / 5 s timeout) on a background thread.
    private final class Reader: @unchecked Sendable {
        private let lock = NSLock()
        private var bytes: [UInt8] = []
        private var eof = false
        let done = DispatchSemaphore(value: 0)

        init(fd: Int32) {
            Thread.detachNewThread { [self] in
                var buf = [UInt8](repeating: 0, count: 65_536)
                while true {
                    let n = buf.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
                    if n > 0 { lock.withLock { bytes += buf[..<n] }; continue }
                    lock.withLock { eof = n == 0 }
                    break
                }
                done.signal()
            }
        }

        var result: (bytes: [UInt8], eof: Bool) { lock.withLock { (bytes, eof) } }
    }

    private func frame(_ seq: UInt32, size: Int) -> VideoFrame {
        VideoFrame(frameSeq: seq, captureTimeUs: UInt64(seq) * 1000, flags: seq == 0 ? .keyframe : [],
                   data: (0..<size).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ Int(seq)) })
    }

    /// Waits until the transport takes a frame, driven by its ready handler (as `VideoSender` does).
    private func waitCanSend(_ t: SocketVideoTransport, timeout: Double = 5) -> Bool {
        let ready = DispatchSemaphore(value: 0)
        t.setReadyHandler { ready.signal() }
        defer { t.setReadyHandler(nil) }
        let deadline = DispatchTime.now() + timeout
        while !t.canSend {
            if ready.wait(timeout: deadline) == .timedOut { return t.canSend }
        }
        return true
    }

    // MARK: Tests

    func testVideoHelloSealedFramesAndClose() throws {
        let server = try Server(options: BsdTcpOptions(notSentLowatBytes: 128 * 1024))
        XCTAssertNotEqual(server.listener.port, 0)
        let client = connectClient(port: server.listener.port, receiveBuffer: 64 * 1024)
        defer { close(client) }
        let c = try XCTUnwrap(server.waitAccepted())

        // VIDEO_HELLO, client to host, plain (PROTOCOL.md 3.5).
        let hello = VideoHello(configID: 3, sessionID: 77, videoNonce: [UInt8](repeating: 9, count: 16))
        writeAll(client, try Message.videoHello(hello).encode())
        var decoder = FrameDecoder(connection: .video)
        var parsed: Message?
        let deadline = Date().addingTimeInterval(5)
        while parsed == nil, Date() < deadline {
            _ = server.receivedSome.wait(timeout: .now() + 1)
            decoder = FrameDecoder(connection: .video)
            decoder.append(server.received)
            parsed = try decoder.nextMessage()
        }
        XCTAssertEqual(parsed, .videoHello(hello))

        // Three sealed frames; the big one cannot fit the kernel buffers while the client is not reading.
        let t = SocketVideoTransport(connection: c, sealer: RecordSealer(key: key,
                                                                           maxPayload: ProtocolConstants.maxVideoPayload))
        let frames = [frame(0, size: 4 * 1024 * 1024), frame(1, size: 1000), frame(2, size: 70_000)]
        let completions = DispatchSemaphore(value: 0)
        let results = LockedResults()
        XCTAssertTrue(t.canSend)
        XCTAssertEqual(t.sendFrame(frames[0]) { ok in results.add(ok); completions.signal() }, .sent)
        XCTAssertGreaterThan(c.pendingBytes, 0, "partial write: the rest waits in user space")
        XCTAssertFalse(t.canSend, "a record still in user space blocks the next one")
        XCTAssertEqual(t.sendFrame(frames[1]), .busy, "nothing is sent past the gate")

        let reader = Reader(fd: client)  // the tablet starts reading
        XCTAssertEqual(completions.wait(timeout: .now() + 5), .success)
        for f in frames.dropFirst() {
            XCTAssertTrue(waitCanSend(t))
            XCTAssertEqual(t.sendFrame(f) { ok in results.add(ok); completions.signal() }, .sent)
            XCTAssertEqual(completions.wait(timeout: .now() + 5), .success)
        }
        XCTAssertEqual(results.values, [true, true, true])

        // Close: the client sees end of stream after every byte; onClosed runs once.
        c.cancel()
        XCTAssertEqual(reader.done.wait(timeout: .now() + 5), .success)
        let (bytes, eof) = reader.result
        XCTAssertTrue(eof)
        XCTAssertEqual(try decodeFrames(bytes), frames, "every record decrypts in counter order, nothing interleaved")
        XCTAssertEqual(server.closedSignal.wait(timeout: .now() + 5), .success)

        // After close: a write fails (asynchronously), canSend lets a writer find out, close is not reported again.
        let late = DispatchSemaphore(value: 0)
        let lateResult = LockedResults()
        c.write([1, 2, 3]) { ok in lateResult.add(ok); late.signal() }
        XCTAssertEqual(late.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(lateResult.values, [false])
        XCTAssertTrue(c.isWritableForNewRecord)
        c.cancel()
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertEqual(server.closedCount, 1)
        XCTAssertNil(c.connectionInfo(), "the descriptor is closed")
        server.listener.cancel()
    }

    /// `TCP_NOTSENT_LOWAT` closes the gate while the kernel would still take bytes; reading opens it again and the
    /// ready handler fires (without spinning).
    func testNotSentLowatGatesBeforeTheSendBufferIsFull() throws {
        let server = try Server(options: BsdTcpOptions(notSentLowatBytes: 16 * 1024))
        let client = connectClient(port: server.listener.port, receiveBuffer: 16 * 1024)
        defer { close(client) }
        let c = try XCTUnwrap(server.waitAccepted())
        let t = SocketVideoTransport(connection: c, sealer: RecordSealer(key: key,
                                                                           maxPayload: ProtocolConstants.maxVideoPayload))
        let done = DispatchSemaphore(value: 0)
        var sent = 0
        while t.canSend, sent < 2000 {
            XCTAssertEqual(t.sendFrame(frame(UInt32(sent), size: 8 * 1024)) { _ in done.signal() }, .sent)
            XCTAssertEqual(done.wait(timeout: .now() + 5), .success)
            sent += 1
        }
        XCTAssertFalse(t.canSend, "the gate closed (sent \(sent) frames)")
        XCTAssertEqual(c.pendingBytes, 0, "closed by the kernel's unsent bytes, not by our own buffer")
        // The send buffer itself still has room: a small write is accepted right away.
        let probe = DispatchSemaphore(value: 0)
        let probeResult = LockedResults()
        c.write([0]) { ok in probeResult.add(ok); probe.signal() }
        XCTAssertEqual(probe.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(probeResult.values, [true])
        XCTAssertEqual(c.pendingBytes, 0)

        let wakes = Counter()
        let ready = DispatchSemaphore(value: 0)
        t.setReadyHandler { wakes.increment(); ready.signal() }
        XCTAssertFalse(t.canSend)  // arms the writable notification
        let reader = Reader(fd: client)
        XCTAssertEqual(ready.wait(timeout: .now() + 5), .success, "writable again once the tablet reads")
        XCTAssertTrue(t.canSend)
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertLessThanOrEqual(wakes.value, 3, "the write source is suspended again, not spinning")
        c.cancel()
        _ = reader.done.wait(timeout: .now() + 5)
        server.listener.cancel()
    }

    /// `sendFrame` enforces the same gate as `canSend` (review P2-1): above the mark it refuses before sealing, so no
    /// record counter is used up and the stream stays decodable.
    func testSendFrameEnforcesTheGateWithoutUsingACounter() throws {
        let server = try Server(options: BsdTcpOptions(notSentLowatBytes: 16 * 1024))
        let client = connectClient(port: server.listener.port, receiveBuffer: 16 * 1024)
        defer { close(client) }
        let c = try XCTUnwrap(server.waitAccepted())
        let t = SocketVideoTransport(connection: c, sealer: RecordSealer(key: key,
                                                                           maxPayload: ProtocolConstants.maxVideoPayload))
        let done = DispatchSemaphore(value: 0)
        var sent: [VideoFrame] = []
        while t.canSend, sent.count < 2000 {
            let f = frame(UInt32(sent.count), size: 8 * 1024)
            XCTAssertEqual(t.sendFrame(f) { _ in done.signal() }, .sent)
            XCTAssertEqual(done.wait(timeout: .now() + 5), .success)
            sent.append(f)
        }
        XCTAssertEqual(c.pendingBytes, 0, "the kernel gate is closed, not our own buffer")
        let refused = LockedResults()
        XCTAssertEqual(t.sendFrame(frame(9999, size: 8 * 1024)) { ok in refused.add(ok) }, .busy,
                       "above TCP_NOTSENT_LOWAT nothing is sent, even without asking canSend first")
        XCTAssertFalse(t.send(frame(9998, size: 100), completion: { ok in refused.add(ok) }))

        let reader = Reader(fd: client)
        XCTAssertTrue(waitCanSend(t))
        let last = frame(UInt32(sent.count), size: 500)
        XCTAssertEqual(t.sendFrame(last) { _ in done.signal() }, .sent)
        XCTAssertEqual(done.wait(timeout: .now() + 5), .success)
        sent.append(last)
        c.cancel()
        XCTAssertEqual(reader.done.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(try decodeFrames(reader.result.bytes), sent, "no counter gap: every record decrypts")
        XCTAssertEqual(refused.values, [], "a refused frame has no completion")
        server.listener.cancel()
    }

    /// The write queue is bounded (review P2-2): a record beyond the byte or record limit is refused whole, its
    /// completion reports false, and the connection stays usable.
    func testWriteQueueIsBounded() throws {
        let server = try Server(options: BsdTcpOptions(maxPendingRecords: 2, maxPendingBytes: 8 * 1024 * 1024))
        let client = connectClient(port: server.listener.port, receiveBuffer: 16 * 1024)
        defer { close(client) }
        let c = try XCTUnwrap(server.waitAccepted())
        let results = LockedResults()
        let completions = DispatchSemaphore(value: 0)
        func write(_ n: Int, _ fill: UInt8) -> Bool {
            c.write([UInt8](repeating: fill, count: n)) { ok in results.add(ok); completions.signal() }
        }
        XCTAssertTrue(write(4 * 1024 * 1024, 1))
        XCTAssertGreaterThan(c.pendingBytes, 0, "the client is not reading: most of it waits in user space")
        XCTAssertFalse(write(8 * 1024 * 1024, 2), "byte limit")
        XCTAssertEqual(completions.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(results.values, [false])
        XCTAssertTrue(write(1024, 3))
        XCTAssertFalse(write(1, 4), "record limit")
        XCTAssertEqual(completions.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(results.values, [false, false])

        let reader = Reader(fd: client)
        for _ in 0..<2 { XCTAssertEqual(completions.wait(timeout: .now() + 5), .success) }
        XCTAssertEqual(results.values, [false, false, true, true], "the accepted records still complete")
        c.cancel()
        XCTAssertEqual(reader.done.wait(timeout: .now() + 5), .success)
        let bytes = reader.result.bytes
        XCTAssertEqual(bytes.count, 4 * 1024 * 1024 + 1024, "refused records left no bytes on the wire")
        XCTAssertEqual(Set(bytes), [1, 3])
        server.listener.cancel()
    }

    /// Newest frame wins over the kernel socket: while the gate is closed the sender does not wait with a frame, the
    /// 2-frame queue drops the oldest delta and asks for a keyframe (the same path as the `nw` in-flight limit).
    func testSenderDropsAndRequestsKeyframeWhileGateIsClosed() async throws {
        let server = try Server(options: BsdTcpOptions(notSentLowatBytes: 16 * 1024))
        let client = connectClient(port: server.listener.port, receiveBuffer: 16 * 1024)
        defer { close(client) }
        let c = try XCTUnwrap(server.waitAccepted())
        let t = SocketVideoTransport(connection: c, sealer: RecordSealer(key: key,
                                                                           maxPayload: ProtocolConstants.maxVideoPayload))
        let keyframeRequests = Counter()
        let queue = VideoFrameQueue(keyframeNeeded: { keyframeRequests.increment() })
        let sender = VideoSender(transport: t, frames: queue, requestKeyframe: {})
        sender.start()
        let payload = [UInt8](repeating: 7, count: 64 * 1024)
        queue.push(EncodedVideoFrame(flags: .keyframe, captureTimeUs: 1, data: payload))
        for i in 0..<40 {
            queue.push(EncodedVideoFrame(flags: [], captureTimeUs: UInt64(i + 2), data: payload))
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertGreaterThan(keyframeRequests.value, 0, "a dropped delta asked for a keyframe")
        let sent = sender.currentCounters.framesSent
        XCTAssertGreaterThan(sent, 0)
        XCTAssertLessThan(sent, 41, "frames were dropped, not queued without bound")
        XCTAssertEqual(sender.currentCounters.framesRejected, 0, "the sender waited at the gate, nothing refused")
        let reader = Reader(fd: client)
        await sender.stop()
        c.cancel()
        _ = blockingWait(reader.done, seconds: 5)
        server.listener.cancel()
    }

    func testIPv4ConnectsThroughTheDualStackSocket() throws {
        let server = try Server(bind: .loopbackV4Mapped, options: BsdTcpOptions())
        let client = connectClient(port: server.listener.port, v4: true)
        defer { close(client) }
        let c = try XCTUnwrap(server.waitAccepted())
        XCTAssertEqual(c.peerHost, "::ffff:127.0.0.1")
        XCTAssertEqual(SessionTransport.classify(peerHost: c.peerHost), .usb)
        XCTAssertEqual(c.localPort, server.listener.port)
        XCTAssertNotNil(c.remotePort)
        let info = try XCTUnwrap(c.connectionInfo(), "TCP_CONNECTION_INFO straight from the descriptor")
        XCTAssertEqual(info.tcpi_txretransmitpackets, 0)
        c.cancel()
        server.listener.cancel()
    }

    func testAcceptedSocketOptions() throws {
        let server = try Server(options: BsdTcpOptions(notSentLowatBytes: 64 * 1024, serviceClass: .interactiveVideo))
        let client = connectClient(port: server.listener.port)
        defer { close(client) }
        let c = try XCTUnwrap(server.waitAccepted())
        // Read the options back through a duplicate of the descriptor found by port (test only).
        let fd = try XCTUnwrap(findSocket(localPort: server.listener.port, remotePort: c.remotePort ?? 0))
        XCTAssertEqual(intOption(fd, IPPROTO_TCP, TCP_NODELAY) != 0, true)
        XCTAssertEqual(intOption(fd, SOL_SOCKET, SO_NOSIGPIPE) != 0, true)
        XCTAssertEqual(intOption(fd, SOL_SOCKET, SO_KEEPALIVE), 0)
        XCTAssertEqual(intOption(fd, IPPROTO_TCP, TCP_NOTSENT_LOWAT), 64 * 1024)
        XCTAssertEqual(intOption(fd, SOL_SOCKET, SO_NET_SERVICE_TYPE), NET_SERVICE_TYPE_VI)
        XCTAssertNotEqual(fcntl(fd, F_GETFL) & O_NONBLOCK, 0)
        c.cancel()
        server.listener.cancel()
    }

    /// T-124: the default knob (`signaling`) really sets the voice service type on an accepted control socket and the
    /// video type on a video socket; `off` leaves the kernel default (best effort).
    func testDefaultServiceClassIsAppliedToAcceptedSockets() throws {
        let knob = ServiceClassKnob.parse([:])
        let cases: [(TrafficClass?, Int32)] = [(knob.controlClass, NET_SERVICE_TYPE_VO),
                                               (knob.videoClass, NET_SERVICE_TYPE_VI),
                                               (ServiceClassKnob.off.controlClass, NET_SERVICE_TYPE_BE)]
        for (serviceClass, expected) in cases {
            let server = try Server(options: BsdTcpOptions(serviceClass: serviceClass))
            let client = connectClient(port: server.listener.port)
            let c = try XCTUnwrap(server.waitAccepted())
            let fd = try XCTUnwrap(findSocket(localPort: server.listener.port, remotePort: c.remotePort ?? 0))
            XCTAssertEqual(intOption(fd, SOL_SOCKET, SO_NET_SERVICE_TYPE), expected, "\(String(describing: serviceClass))")
            c.cancel()
            server.listener.cancel()
            close(client)
        }
    }

    /// T-326: the explicit TOS is applied to accepted sockets (IPv4 and IPv6 peers of the dual-stack listener). On an
    /// `AF_INET6` socket `IP_TOS` is `EINVAL` (macOS 27), so the value is read back through `IPV6_TCLASS`. It coexists
    /// with `SO_NET_SERVICE_TYPE` in either order: neither call changes the other's value.
    func testExplicitIpTosIsAppliedAlongsideServiceType() throws {
        let cases: [(TrafficClass?, UInt8?, Int32)] = [(.interactiveVoice, 0xB8, NET_SERVICE_TYPE_VO),
                                                       (.interactiveVideo, 0x88, NET_SERVICE_TYPE_VI),
                                                       (nil, 0xC0, NET_SERVICE_TYPE_BE),
                                                       (.interactiveVoice, nil, NET_SERVICE_TYPE_VO),
                                                       (nil, nil, NET_SERVICE_TYPE_BE)]
        for v4 in [false, true] {
            for (serviceClass, tos, serviceType) in cases {
                let server = try Server(bind: v4 ? .loopbackV4Mapped : .loopbackV6,
                                        options: BsdTcpOptions(serviceClass: serviceClass, ipTos: tos))
                let client = connectClient(port: server.listener.port, v4: v4)
                let c = try XCTUnwrap(server.waitAccepted())
                let label = "v4=\(v4) class=\(String(describing: serviceClass)) tos=\(String(describing: tos))"
                XCTAssertNil(c.ipTosFailure, label)
                let fd = try XCTUnwrap(findSocket(localPort: server.listener.port, remotePort: c.remotePort ?? 0))
                XCTAssertEqual(intOption(fd, IPPROTO_IPV6, IPV6_TCLASS), Int32(tos ?? 0), label)
                XCTAssertEqual(intOption(fd, SOL_SOCKET, SO_NET_SERVICE_TYPE), serviceType, label)
                // Setting the service type again afterwards (the other order) leaves the TOS alone.
                var again = NET_SERVICE_TYPE_VO
                XCTAssertEqual(setsockopt(fd, SOL_SOCKET, SO_NET_SERVICE_TYPE, &again, 4), 0, label)
                XCTAssertEqual(intOption(fd, IPPROTO_IPV6, IPV6_TCLASS), Int32(tos ?? 0), label)
                c.cancel()
                server.listener.cancel()
                close(client)
            }
        }
    }

    func testPeerCloseFailsPendingWriteAndClosesOnce() throws {
        let server = try Server(options: BsdTcpOptions(notSentLowatBytes: 128 * 1024))
        let client = connectClient(port: server.listener.port, receiveBuffer: 16 * 1024)
        let c = try XCTUnwrap(server.waitAccepted())
        let done = DispatchSemaphore(value: 0)
        let result = LockedResults()
        c.write([UInt8](repeating: 1, count: 8 * 1024 * 1024)) { ok in result.add(ok); done.signal() }
        XCTAssertGreaterThan(c.pendingBytes, 0)
        close(client)  // unread data: the peer resets
        XCTAssertEqual(done.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(result.values, [false], "a record that never fully reached the kernel fails")
        XCTAssertEqual(server.closedSignal.wait(timeout: .now() + 5), .success)
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertEqual(server.closedCount, 1)
        server.listener.cancel()
    }

    func testCancelBeforeStartStillReportsCloseOnce() throws {
        let queue = DispatchQueue(label: "test.bsd.accept")
        let got = DispatchSemaphore(value: 0)
        let box = LockedBox<BsdTcpConnection>()
        let listener = try BsdTcpListener(port: 0, bind: .loopbackV6, options: BsdTcpOptions(), queue: queue)
        listener.start { event in
            if case .accepted(let c) = event { box.value = c; got.signal() }
        }
        let client = connectClient(port: listener.port)
        defer { close(client) }
        XCTAssertEqual(got.wait(timeout: .now() + 5), .success)
        let c = try XCTUnwrap(box.value)
        c.cancel()
        let closed = Counter()
        let signal = DispatchSemaphore(value: 0)
        c.start(queue: queue, onBytes: { _ in XCTFail("no reads after cancel"); return false },
                onClosed: { closed.increment(); signal.signal() })
        XCTAssertEqual(signal.wait(timeout: .now() + 5), .success)
        c.cancel()
        Thread.sleep(forTimeInterval: 0.1)
        XCTAssertEqual(closed.value, 1)
        var byte: UInt8 = 0
        XCTAssertEqual(read(client, &byte, 1), 0, "the peer sees end of stream")
        listener.cancel()
    }

    func testBusyPortThrowsForFallbackAndCancelledListenerRefuses() throws {
        let queue = DispatchQueue(label: "test.bsd.listen")
        let first = try BsdTcpListener(port: 0, bind: .loopbackV6, options: BsdTcpOptions(), queue: queue)
        first.start { _ in }
        XCTAssertThrowsError(try BsdTcpListener(port: first.port, bind: .loopbackV6, options: BsdTcpOptions(),
                                                queue: queue)) { error in
            XCTAssertEqual(error as? BsdSocketError, BsdSocketError("bind", EADDRINUSE))
        }
        first.cancel()
        queue.sync {}  // the cancel handler (which closes the descriptor) has run
        // The port is free again: a new listener binds it.
        let again = try BsdTcpListener(port: first.port, bind: .loopbackV6, options: BsdTcpOptions(), queue: queue)
        again.cancel()
    }

    // MARK: Helpers

    /// Decrypts a received video stream like the tablet: one read chunk per append, records in counter order.
    /// Trailing bytes that do not form a whole record fail the test.
    private func decodeFrames(_ bytes: [UInt8]) throws -> [VideoFrame] {
        var records = RecordDecoder(key: key, connection: .video)
        var got: [VideoFrame] = []
        var offset = 0
        while offset < bytes.count {
            let end = min(bytes.count, offset + FrameDecoder.maxReadChunk)
            records.append(Array(bytes[offset..<end]))
            offset = end
            while let m = try records.nextMessage() {
                guard case .videoFrame(let f) = m else {
                    XCTFail("unexpected \(m)")
                    return got
                }
                got.append(f)
            }
        }
        XCTAssertEqual(records.bufferedCount, 0, "no partial record left")
        return got
    }

    private func blockingWait(_ s: DispatchSemaphore, seconds: Double) -> DispatchTimeoutResult {
        s.wait(timeout: .now() + seconds)
    }

    private func intOption(_ fd: Int32, _ level: Int32, _ name: Int32) -> Int32 {
        var v: Int32 = -1
        var len = socklen_t(MemoryLayout<Int32>.size)
        XCTAssertEqual(getsockopt(fd, level, name, &v, &len), 0)
        return v
    }

    private func findSocket(localPort: UInt16, remotePort: UInt16) -> Int32? {
        for fd in Int32(0)..<Int32(1024) {
            var storage = sockaddr_storage()
            var len = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let ok = withUnsafeMutablePointer(to: &storage) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
            }
            guard ok == 0, Int32(storage.ss_family) == AF_INET6 else { continue }
            let local = withUnsafePointer(to: &storage) {
                $0.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { UInt16(bigEndian: $0.pointee.sin6_port) }
            }
            var peer = sockaddr_storage()
            var plen = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let pok = withUnsafeMutablePointer(to: &peer) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getpeername(fd, $0, &plen) }
            }
            guard pok == 0 else { continue }
            let remote = withUnsafePointer(to: &peer) {
                $0.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { UInt16(bigEndian: $0.pointee.sin6_port) }
            }
            if local == localPort, remote == remotePort { return fd }
        }
        return nil
    }
}

private final class LockedResults: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [Bool] = []
    func add(_ v: Bool) { lock.withLock { items.append(v) } }
    var values: [Bool] { lock.withLock { items } }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func increment() { lock.withLock { n += 1 } }
    var value: Int { lock.withLock { n } }
}

private final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var item: T?
    var value: T? {
        get { lock.withLock { item } }
        set { lock.withLock { item = newValue } }
    }
}
