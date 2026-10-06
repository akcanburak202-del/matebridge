import Darwin
import Foundation
import MateBridgeCore
import MateBridgeHost

/// `--files-net-selftest` (T-268): the Wi-Fi file path end to end on loopback, command line only. No window, no
/// Finder, no mount, no tablet and no running host: `FilesNetService` gets real sockets, a fake tablet speaks the real
/// protocol (plain `FILES_HELLO`, ACK, AES-GCM records with keys from a test session) and an echo server stands in for
/// the tablet's WebDAV server. Exit code 0 only when every check passed.
enum FilesNetSelfTest {
    static func runIfRequested() {
        let args = CommandLine.arguments
        if args.contains("--files-net-selftest") {
            DispatchQueue.global().async { exit(FilesNetSelfTestRunner().run()) }
            dispatchMain()
        }
        // `--files-net-hold <upstream port> <seconds>`: the host half plus a fake tablet in front of an HTTP/WebDAV
        // server of your own on 127.0.0.1:<upstream port>. Prints `proxy=<port>`; for command-line mount tests
        // (`mount_webdav`), never touches Finder.
        if let i = args.firstIndex(of: "--files-net-hold"), args.count > i + 2,
           let upstream = UInt16(args[i + 1]), let seconds = Double(args[i + 2]) {
            DispatchQueue.global().async { exit(FilesNetSelfTestRunner().hold(upstreamPort: upstream, seconds: seconds)) }
            dispatchMain()
        }
    }
}

// MARK: - Blocking socket helpers (test side only)

private enum TestNet {
    static func listen() -> (fd: Int32, port: UInt16)? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, 4)
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, 4)
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr = in_addr(s_addr: UInt32(0x7F00_0001).bigEndian)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, Darwin.listen(fd, 16) == 0 else { close(fd); return nil }
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let rc = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
        }
        guard rc == 0 else { close(fd); return nil }
        return (fd, UInt16(bigEndian: addr.sin_port))
    }

    static func connect(port: UInt16) -> Int32? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, 4)
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, 4)
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr = in_addr(s_addr: UInt32(0x7F00_0001).bigEndian)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard rc == 0 else { close(fd); return nil }
        return fd
    }

    /// Blocks for up to `maxCount` bytes; empty on end of stream or error.
    static func readSome(_ fd: Int32, _ maxCount: Int = 64 * 1024) -> [UInt8] {
        var buffer = [UInt8](repeating: 0, count: maxCount)
        let n = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, maxCount) }
        return n > 0 ? Array(buffer[..<n]) : []
    }

    static func readExact(_ fd: Int32, _ count: Int) -> [UInt8]? {
        var out: [UInt8] = []
        out.reserveCapacity(count)
        while out.count < count {
            let chunk = readSome(fd, min(64 * 1024, count - out.count))
            if chunk.isEmpty { return nil }
            out += chunk
        }
        return out
    }

    @discardableResult
    static func writeAll(_ fd: Int32, _ bytes: [UInt8]) -> Bool {
        var offset = 0
        while offset < bytes.count {
            let n = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress! + offset, bytes.count - offset) }
            if n <= 0 { return false }
            offset += n
        }
        return true
    }

    /// True when the peer closed (read returns 0 or fails) within `seconds`; readable data is discarded meanwhile.
    static func waitForEnd(_ fd: Int32, seconds: Double) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let remaining = Int32(max(1, deadline.timeIntervalSinceNow * 1000))
            if poll(&p, 1, min(remaining, 200)) > 0 {
                if readSome(fd).isEmpty { return true }
            }
        }
        return false
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func add(_ n: Int = 1) { lock.withLock { value += n } }
    var current: Int { lock.withLock { value } }
}

/// Stands in for the tablet's WebDAV server: every connection echoes what it reads.
private final class EchoServer: @unchecked Sendable {
    let port: UInt16
    private let listenFD: Int32
    private let lock = NSLock()
    private var fds: [Int32] = []
    let accepted = Counter()
    let endsSeen = Counter()

    init?() {
        guard let l = TestNet.listen() else { return nil }
        listenFD = l.fd
        port = l.port
        Thread.detachNewThread { [self] in acceptLoop() }
    }

    private func acceptLoop() {
        while true {
            let fd = accept(listenFD, nil, nil)
            if fd < 0 { return }
            var one: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, 4)
            lock.withLock { fds.append(fd) }
            accepted.add()
            Thread.detachNewThread { [self] in
                serve(fd)
                lock.withLock { fds.removeAll { $0 == fd } }  // before close: a reused descriptor must never be shut down
                endsSeen.add()
                close(fd)
            }
        }
    }

    /// Plain echo, unless the first byte is `bulkMarker`: then `marker, u64 BE length, bytes` is one request and the
    /// reply (the same bytes) starts only after the whole request was read, like an HTTP server answering a PUT.
    static let bulkMarker: UInt8 = 0xB1

    private func serve(_ fd: Int32) {
        var acc: [UInt8] = []
        var bulk: Bool?
        while true {
            if acc.isEmpty {
                acc = TestNet.readSome(fd)
                if acc.isEmpty { return }
            }
            if bulk == nil { bulk = acc[0] == Self.bulkMarker }
            if bulk == false {
                if !TestNet.writeAll(fd, acc) { return }
                acc = []
                continue
            }
            while acc.count < 9 {
                let more = TestNet.readSome(fd)
                if more.isEmpty { return }
                acc += more
            }
            let length = acc[1..<9].reduce(0) { $0 << 8 | Int($1) }
            while acc.count < 9 + length {
                let more = TestNet.readSome(fd)
                if more.isEmpty { return }
                acc += more
            }
            if !TestNet.writeAll(fd, Array(acc[9..<(9 + length)])) { return }
            acc = Array(acc[(9 + length)...])
        }
    }

    /// Closes every connection from the server side (the tablet's server dropping its connections).
    func dropAll() {
        let all = lock.withLock { () -> [Int32] in defer { fds = [] }; return fds }
        for fd in all { shutdown(fd, SHUT_RDWR) }
    }
}

/// The tablet end of the file connections: the real wire protocol, a tunnel to the echo server per bound connection.
private final class FakeTablet: @unchecked Sendable {
    private let filesPort: UInt16
    private let sessionID: UInt32
    private let upstreamPort: UInt16
    private let schedule: SessionKeySchedule
    private let lock = NSLock()
    private var stopped = false
    private var fds: [Int32] = []
    private var stallUntil = Date.distantPast
    let bound = Counter()

    init(filesPort: UInt16, sessionID: UInt32, upstreamPort: UInt16, schedule: SessionKeySchedule) {
        self.filesPort = filesPort
        self.sessionID = sessionID
        self.upstreamPort = upstreamPort
        self.schedule = schedule
    }

    func open(_ count: Int) {
        for _ in 0..<count { Thread.detachNewThread { [self] in connection() } }
    }

    /// The tablet stops reading its file connections for `seconds` after the next bytes arrive (a slow tablet).
    func stall(seconds: Double) {
        lock.withLock { stallUntil = Date().addingTimeInterval(seconds) }
    }

    private func stallIfNeeded() {
        while true {
            let until = lock.withLock { stallUntil }
            if Date() >= until { return }
            Thread.sleep(forTimeInterval: 0.05)
        }
    }

    func stop() {
        let all = lock.withLock { () -> [Int32] in
            stopped = true
            return fds
        }
        for fd in all { shutdown(fd, SHUT_RDWR) }
    }

    private var isStopped: Bool { lock.withLock { stopped } }

    private func connection() {
        guard !isStopped, let fd = TestNet.connect(port: filesPort) else { return }
        lock.withLock { fds.append(fd) }
        defer { close(fd) }
        let clientNonce = (0..<16).map { _ in UInt8.random(in: 0...255) }
        guard let hello = try? Message.filesHello(FilesHello(sessionID: sessionID, clientNonce: clientNonce)).encode(),
              TestNet.writeAll(fd, hello) else { return }
        var plain = FrameDecoder(connection: .files)
        var hostNonce: [UInt8]?
        while hostNonce == nil {
            let bytes = TestNet.readSome(fd)
            if bytes.isEmpty { return }
            plain.append(bytes)
            if let message = try? plain.nextMessage() {
                guard case .filesHelloAck(let ack) = message, ack.isOK else { return }
                hostNonce = ack.hostNonce
            }
        }
        guard let hostNonce, let keys = schedule.filesKeys(clientNonce: clientNonce, hostNonce: hostNonce) else { return }
        var sealer = RecordSealer(key: keys.c2h, maxPayload: ProtocolConstants.maxControlPayload)
        var decoder = RecordDecoder(key: keys.h2c, connection: .files)
        guard let ping = try? Message.ping(Ping(seq: 1, senderTimeUs: 0)).sealed(using: &sealer),
              TestNet.writeAll(fd, ping) else { return }
        let writeLock = NSLock()
        var upstream: Int32?
        while true {
            let bytes = TestNet.readSome(fd)
            if bytes.isEmpty { break }
            stallIfNeeded()
            decoder.append(bytes)
            while let message = try? decoder.nextMessage() {
                guard case .filesData(let data) = message else { continue }
                if upstream == nil {
                    // First FILES_DATA: this connection is paired. Connect to the "tablet server", replace this slot.
                    guard let up = TestNet.connect(port: upstreamPort) else { return }
                    upstream = up
                    bound.add()
                    open(1)
                    let sealerBox = SealerBox(sealer)
                    Thread.detachNewThread { [self] in
                        pump(from: up, to: fd, sealer: sealerBox, lock: writeLock)
                    }
                }
                if !TestNet.writeAll(upstream!, data.data) { break }
            }
        }
        if let upstream { close(upstream) }
    }

    private final class SealerBox: @unchecked Sendable {
        var sealer: RecordSealer
        init(_ s: RecordSealer) { sealer = s }
    }

    private func pump(from upstream: Int32, to file: Int32, sealer: SealerBox, lock: NSLock) {
        while true {
            let bytes = TestNet.readSome(upstream, 16 * 1024)
            if bytes.isEmpty { break }
            guard let record = try? Message.filesData(FilesData(data: bytes)).sealed(using: &sealer.sealer) else { break }
            lock.lock()
            let ok = TestNet.writeAll(file, record)
            lock.unlock()
            if !ok { break }
        }
        shutdown(file, SHUT_RDWR)  // the tablet closed: the file connection ends
    }
}

// MARK: - Runner

private final class FilesNetSelfTestRunner: @unchecked Sendable {
    private var failures = 0

    private func check(_ ok: Bool, _ name: String, _ detail: String = "") {
        print((ok ? "  ok: " : "FAIL: ") + name + (detail.isEmpty ? "" : " (\(detail))"))
        if !ok { failures += 1 }
    }

    private func randomBytes(_ n: Int) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: n)
        for i in 0..<n { out[i] = UInt8.random(in: 0...255) }
        return out
    }

    /// One bulk request through the proxy to the "tablet server" and its reply back; written on a second thread (the
    /// host's pumps stop reading a full direction, so one thread writing everything first could deadlock by design).
    private func roundTrip(proxyPort: UInt16, payload: [UInt8], readDelay: Double = 0) -> (ok: Bool, seconds: Double) {
        guard let fd = TestNet.connect(port: proxyPort) else { return (false, 0) }
        defer { close(fd) }
        let start = Date()
        var request: [UInt8] = [EchoServer.bulkMarker]
        for shift in stride(from: 56, through: 0, by: -8) { request.append(UInt8((payload.count >> shift) & 0xFF)) }
        request += payload
        let writer = Thread { _ = TestNet.writeAll(fd, request) }
        writer.start()
        if readDelay > 0 { Thread.sleep(forTimeInterval: readDelay) }  // a Finder that is slow to read
        let back = TestNet.readExact(fd, payload.count)
        return (back == payload, Date().timeIntervalSince(start))
    }

    func hold(upstreamPort: UInt16, seconds: Double) -> Int32 {
        guard let schedule = try? SessionKeySchedule.derive(ecdh: [UInt8](repeating: 7, count: 32), pairKey: nil,
                                                            helloPayload: [1, 2, 3], ackPayload: [4, 5, 6]) else { return 1 }
        let sessionID: UInt32 = 7
        let service = FilesNetService()
        guard let ports = service.start(sessionID: sessionID, controlPeer: "127.0.0.1", videoKbps: 0, keys: { sid, cn, hn in
            sid == sessionID ? schedule.filesKeys(clientNonce: cn, hostNonce: hn) : nil
        }) else { return 1 }
        let tablet = FakeTablet(filesPort: ports.files, sessionID: sessionID, upstreamPort: upstreamPort, schedule: schedule)
        tablet.open(2)
        print("proxy=\(ports.proxy) files=\(ports.files)")
        fflush(stdout)
        Thread.sleep(forTimeInterval: seconds)
        service.stopAll()
        tablet.stop()
        return 0
    }

    func run() -> Int32 {
        print("files-net selftest: loopback, no GUI, no mount")
        guard let echo = EchoServer() else { print("FAIL: echo server"); return 1 }
        let schedule: SessionKeySchedule
        do {
            schedule = try SessionKeySchedule.derive(ecdh: [UInt8](repeating: 7, count: 32), pairKey: nil,
                                                     helloPayload: [1, 2, 3], ackPayload: [4, 5, 6])
        } catch {
            print("FAIL: key schedule \(error)")
            return 1
        }
        let sessionID: UInt32 = 7
        let service = FilesNetService()
        guard let ports = service.start(sessionID: sessionID, controlPeer: "::ffff:127.0.0.1", videoKbps: 0,
                                        keys: { sid, cn, hn in
                                            sid == sessionID ? schedule.filesKeys(clientNonce: cn, hostNonce: hn) : nil
                                        }) else {
            print("FAIL: service did not start")
            return 1
        }
        check(ports.files != ports.proxy && ports.files != 0 && ports.proxy != 0, "two listeners",
              "files=\(ports.files) proxy=\(ports.proxy)")
        let tablet = FakeTablet(filesPort: ports.files, sessionID: sessionID, upstreamPort: echo.port, schedule: schedule)
        tablet.open(2)
        Thread.sleep(forTimeInterval: 0.6)

        // 1. A megabyte of random bytes through proxy, file connection and echo server, both directions.
        let big = randomBytes(1_000_000)
        let r1 = roundTrip(proxyPort: ports.proxy, payload: big)
        check(r1.ok, "1 MB round trip is byte-identical", String(format: "%.2f s", r1.seconds))

        // 2. Three Finder connections at once (pool of 2 plus replacements the tablet opens after pairing).
        Thread.sleep(forTimeInterval: 0.5)
        let results = Counter()
        let group = DispatchGroup()
        for _ in 0..<3 {
            group.enter()
            Thread.detachNewThread { [self] in
                if roundTrip(proxyPort: ports.proxy, payload: randomBytes(300_000)).ok { results.add() }
                group.leave()
            }
        }
        check(group.wait(timeout: .now() + 20) == .success && results.current == 3, "3 concurrent connections",
              "ok=\(results.current)")

        // 3. 1:1 close without messages, Finder side first.
        Thread.sleep(forTimeInterval: 0.5)
        let endsBefore = echo.endsSeen.current
        if let fd = TestNet.connect(port: ports.proxy) {
            TestNet.writeAll(fd, [1, 2, 3, 4, 5])
            check(TestNet.readExact(fd, 5) == [1, 2, 3, 4, 5], "small echo")
            close(fd)
            var seen = false
            for _ in 0..<30 where !seen {
                Thread.sleep(forTimeInterval: 0.1)
                seen = echo.endsSeen.current > endsBefore
            }
            check(seen, "Finder close reaches the tablet server")
        } else {
            check(false, "connect to proxy")
        }

        // 3b. 1:1 close, tablet side first.
        Thread.sleep(forTimeInterval: 0.5)
        if let fd = TestNet.connect(port: ports.proxy) {
            TestNet.writeAll(fd, [9, 9])
            check(TestNet.readExact(fd, 2) == [9, 9], "small echo before the server drops")
            echo.dropAll()
            check(TestNet.waitForEnd(fd, seconds: 3), "tablet close reaches Finder")
            close(fd)
        } else {
            check(false, "connect to proxy (3b)")
        }
        Thread.sleep(forTimeInterval: 0.8)

        // 4. The file budget: the lowest cap (0.5 MB/s, video at 47 Mbps) holds 1 MB back; 0 kbps (2 MB/s) does not.
        service.setVideoKbps(47_000)
        Thread.sleep(forTimeInterval: 0.2)
        let slow = roundTrip(proxyPort: ports.proxy, payload: big)
        check(slow.ok && slow.seconds > 1.3 && slow.seconds < 8, "rate cap holds 1 MB back at 0.5 MB/s",
              String(format: "%.2f s", slow.seconds))
        service.setVideoKbps(0)
        Thread.sleep(forTimeInterval: 0.2)
        let fast = roundTrip(proxyPort: ports.proxy, payload: big)
        check(fast.ok && fast.seconds < slow.seconds, "cap follows the video target", String(format: "%.2f s", fast.seconds))

        // 4b. Back pressure: a Finder that reads late and a tablet that reads late. The relay buffers stay within
        //     64 KiB per connection and direction (the Finder side plus the one record being decoded), nothing is lost.
        let bulk = randomBytes(4_000_000)
        let lateReader = roundTrip(proxyPort: ports.proxy, payload: bulk, readDelay: 2)
        check(lateReader.ok, "4 MB with a Finder that starts reading after 2 s is byte-identical")
        tablet.stall(seconds: 2)
        let slowTablet = roundTrip(proxyPort: ports.proxy, payload: bulk)
        check(slowTablet.ok, "4 MB with a tablet that stalls for 2 s is byte-identical")
        let peaks = service.peakBuffers
        check(peaks.toTablet <= 64 * 1024, "Finder to tablet relay buffer never exceeds 64 KiB", "peak=\(peaks.toTablet)")
        check(peaks.toFinder <= 64 * 1024 + ProtocolConstants.filesDataMax,
              "tablet to Finder relay buffer stays within 64 KiB + one record", "peak=\(peaks.toFinder)")

        // 4c. A FILES_HELLO with trailing extension bytes (65 byte payload) is valid (PROTOCOL.md section 2).
        if let fd = TestNet.connect(port: ports.files) {
            let nonce = (0..<16).map { _ in UInt8.random(in: 0...255) }
            if var hello = try? Message.filesHello(FilesHello(sessionID: sessionID, clientNonce: nonce)).encode() {
                hello[1] = 65  // payload length 22 + 43 extension bytes (little-endian u32, high bytes are 0)
                hello += [UInt8](repeating: 0xAB, count: 43)
                TestNet.writeAll(fd, hello)
                var plain = FrameDecoder(connection: .files)
                plain.append(TestNet.readSome(fd))
                var ok = false
                if let message = try? plain.nextMessage(), case .filesHelloAck(let ack) = message { ok = ack.isOK }
                check(ok, "a FILES_HELLO with extension bytes is accepted")
            }
            close(fd)
        }
        Thread.sleep(forTimeInterval: 0.3)

        // 5. Admission: a wrong session id is REJECTED, three silent connections leave the third closed at once, and
        //    a silent connection is closed after the 5 s proof window.
        if let fd = TestNet.connect(port: ports.files) {
            let nonce = (0..<16).map { _ in UInt8.random(in: 0...255) }
            let hello = try? Message.filesHello(FilesHello(sessionID: 99, clientNonce: nonce)).encode()
            TestNet.writeAll(fd, hello ?? [])
            var plain = FrameDecoder(connection: .files)
            let reply = TestNet.readSome(fd)
            plain.append(reply)
            var rejected = false
            if let message = try? plain.nextMessage(), case .filesHelloAck(let ack) = message { rejected = !ack.isOK }
            check(rejected, "wrong session id is answered REJECTED")
            check(TestNet.waitForEnd(fd, seconds: 3), "rejected connection is closed")
            close(fd)
        }
        let silentA = TestNet.connect(port: ports.files)
        let silentB = TestNet.connect(port: ports.files)
        let silentC = TestNet.connect(port: ports.files)
        if let silentC {
            check(TestNet.waitForEnd(silentC, seconds: 2), "third unproven connection is closed at once")
            close(silentC)
        }
        let started = Date()
        if let silentA {
            check(TestNet.waitForEnd(silentA, seconds: 7), "silent connection is closed by the 5 s window",
                  String(format: "%.1f s", Date().timeIntervalSince(started)))
            close(silentA)
        }
        if let silentB { close(silentB) }

        // 6. A valid HELLO but a garbage proof closes the connection (record authentication fails).
        if let fd = TestNet.connect(port: ports.files) {
            let nonce = (0..<16).map { _ in UInt8.random(in: 0...255) }
            if let hello = try? Message.filesHello(FilesHello(sessionID: sessionID, clientNonce: nonce)).encode() {
                TestNet.writeAll(fd, hello)
                _ = TestNet.readSome(fd)  // the ACK
                var garbage = [UInt8](repeating: 0, count: 40)
                garbage[0] = 36  // plausible record length (type + tag + payload)
                for i in 4..<40 { garbage[i] = UInt8.random(in: 0...255) }
                TestNet.writeAll(fd, garbage)
                check(TestNet.waitForEnd(fd, seconds: 3), "a record that fails authentication closes the connection")
            }
            close(fd)
        }

        // 7. No idle file connection: a Finder connection is closed after at most 5 s, nothing sent.
        tablet.stop()
        Thread.sleep(forTimeInterval: 0.8)
        if let fd = TestNet.connect(port: ports.proxy) {
            let t0 = Date()
            let closed = TestNet.waitForEnd(fd, seconds: 7)
            let waited = Date().timeIntervalSince(t0)
            check(closed && waited > 3.5 && waited < 6.8, "no idle connection: closed after ~5 s",
                  String(format: "%.1f s", waited))
            close(fd)
        }

        // 8. A new tablet pool, then the service stops: Finder connections end, both listeners close.
        let tablet2 = FakeTablet(filesPort: ports.files, sessionID: sessionID, upstreamPort: echo.port, schedule: schedule)
        tablet2.open(2)
        Thread.sleep(forTimeInterval: 0.6)
        let live = TestNet.connect(port: ports.proxy)
        if let live {
            TestNet.writeAll(live, [1])
            check(TestNet.readExact(live, 1) == [1], "echo after the pool came back")
        }
        service.stopAll()
        if let live {
            check(TestNet.waitForEnd(live, seconds: 3), "stopAll ends bound Finder connections")
            close(live)
        }
        Thread.sleep(forTimeInterval: 0.3)
        check(TestNet.connect(port: ports.proxy) == nil && TestNet.connect(port: ports.files) == nil,
              "stopAll closes both listeners")
        tablet2.stop()

        // 9. Another peer than the control connection's is closed without an answer.
        let other = FilesNetService()
        if let p2 = other.start(sessionID: sessionID, controlPeer: "192.0.2.1", videoKbps: 0, keys: { _, _, _ in nil }) {
            if let fd = TestNet.connect(port: p2.files) {
                let nonce = (0..<16).map { _ in UInt8.random(in: 0...255) }
                if let hello = try? Message.filesHello(FilesHello(sessionID: sessionID, clientNonce: nonce)).encode() {
                    TestNet.writeAll(fd, hello)
                }
                check(TestNet.readSome(fd).isEmpty, "foreign peer address: closed without a reply")
                close(fd)
            }
            other.stopAll()
        } else {
            check(false, "second service did not start")
        }

        print(failures == 0 ? "files-net selftest: ALL OK" : "files-net selftest: \(failures) FAILED")
        return failures == 0 ? 0 : 1
    }
}
