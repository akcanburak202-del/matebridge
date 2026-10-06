import Darwin
import Dispatch
import Foundation
import MateBridgeCore

// Raw non-blocking TCP sockets of the Wi-Fi file path (decision 0035, T-268). `BsdTcpConnection` cannot be used here:
// the proxy has to pause reading (back pressure, rate cap), set `SO_SNDBUF` and the background service type, and close
// "bytes first". Everything in this file is confined to the serial queue it is given.

/// Socket options of one file-path socket.
struct FilesSocketOptions: Sendable {
    var noDelay = true
    var keepAlive = false
    /// `SO_SNDBUF` (best effort).
    var sendBufferBytes: Int?
    /// `TCP_NOTSENT_LOWAT` (best effort).
    var notSentLowatBytes: Int?
    /// `SO_NET_SERVICE_TYPE = NET_SERVICE_TYPE_BK` (best effort): bulk files never compete with the video.
    var backgroundService = false
}

enum FilesSockets {
    @discardableResult
    static func setInt(_ fd: Int32, _ level: Int32, _ name: Int32, _ value: Int32) -> Bool {
        var v = value
        return setsockopt(fd, level, name, &v, socklen_t(MemoryLayout<Int32>.size)) == 0
    }

    /// Non-blocking, close-on-exec, no SIGPIPE, the options. False (the caller closes the descriptor) when a required
    /// step fails; buffer sizes, keepalive timers and the service type are best effort.
    /// `gaps` collects the names of best-effort options the kernel refused (for one warning, never per connection).
    static func configure(_ fd: Int32, _ options: FilesSocketOptions, gaps: inout [String]) -> Bool {
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0, fcntl(fd, F_SETFD, FD_CLOEXEC) == 0,
              setInt(fd, SOL_SOCKET, SO_NOSIGPIPE, 1),
              setInt(fd, IPPROTO_TCP, TCP_NODELAY, options.noDelay ? 1 : 0) else { return false }
        func best(_ name: String, _ ok: Bool) { if !ok { gaps.append(name) } }
        if options.keepAlive {
            best("keepalive", setInt(fd, SOL_SOCKET, SO_KEEPALIVE, 1))
            best("keepalive_idle", setInt(fd, IPPROTO_TCP, TCP_KEEPALIVE, 30))  // idle seconds before the first probe
            best("keepalive_interval", setInt(fd, IPPROTO_TCP, TCP_KEEPINTVL, 10))
            best("keepalive_count", setInt(fd, IPPROTO_TCP, TCP_KEEPCNT, 3))
        }
        if let bytes = options.sendBufferBytes { best("sndbuf", setInt(fd, SOL_SOCKET, SO_SNDBUF, Int32(clamping: bytes))) }
        if let bytes = options.notSentLowatBytes {
            best("notsent_lowat", setInt(fd, IPPROTO_TCP, TCP_NOTSENT_LOWAT, Int32(clamping: bytes)))
        }
        if options.backgroundService {
            best("service_type_bk", setInt(fd, SOL_SOCKET, SO_NET_SERVICE_TYPE, NET_SERVICE_TYPE_BK))
        }
        return true
    }

    static func localPort(_ fd: Int32) -> UInt16? { address(fd, getsockname)?.port }
    static func peerHost(_ fd: Int32) -> String? { address(fd, getpeername)?.host }

    private static func address(
        _ fd: Int32, _ call: (Int32, UnsafeMutablePointer<sockaddr>, UnsafeMutablePointer<socklen_t>) -> Int32
    ) -> (host: String, port: UInt16)? {
        var storage = sockaddr_storage()
        var len = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let rc = withUnsafeMutablePointer(to: &storage) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { call(fd, $0, &len) }
        }
        guard rc == 0 else { return nil }
        return withUnsafePointer(to: &storage) { p -> (String, UInt16)? in
            var text = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            func string() -> String {
                String(decoding: text.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            }
            switch Int32(p.pointee.ss_family) {
            case AF_INET:
                return p.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { a in
                    var addr = a.pointee.sin_addr
                    guard inet_ntop(AF_INET, &addr, &text, socklen_t(text.count)) != nil else { return nil }
                    return (string(), UInt16(bigEndian: a.pointee.sin_port))
                }
            case AF_INET6:
                return p.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { a in
                    var addr = a.pointee.sin6_addr
                    guard inet_ntop(AF_INET6, &addr, &text, socklen_t(text.count)) != nil else { return nil }
                    return (string(), UInt16(bigEndian: a.pointee.sin6_port))
                }
            default:
                return nil
            }
        }
    }
}

// MARK: - Connection

/// A connected non-blocking TCP socket with a pausable reader and an unbounded-by-itself write buffer: the owner
/// bounds it by watching `pendingBytes` and pausing its source (`notifyWhenPendingBelow`). Every method, and every
/// callback, runs on the socket's queue.
///
/// Closing: `closeNow()` drops what is still queued. `closeAfterFlush(timeout:)` writes the queue out, shuts the write
/// side down (FIN) and reads (and discards) until the peer closes or `timeout` passes: closing a socket with unread
/// input would make the kernel reset the connection and lose bytes the peer has not read yet.
final class FilesSocket: @unchecked Sendable {
    private enum Phase { case open, draining, closed }

    let peerHost: String?
    private let fd: Int32
    private let queue: DispatchQueue
    private let readChunk: Int
    private var phase = Phase.open
    private var started = false
    private var readSource: DispatchSourceRead?
    private var writeSource: DispatchSourceWrite?
    private var readSuspended = false
    private var writeSuspended = false
    private var cancelHandlersLeft = 0
    private var outbound: [UInt8] = []
    private var outboundStart = 0
    private var waiter: (below: Int, run: @Sendable () -> Void)?

    /// Bytes read. Never called after `closeAfterFlush`, `closeNow` or the peer's end of stream.
    var onData: (([UInt8]) -> Void)?
    /// Once, after the socket closed for any reason (also one the owner closed itself).
    var onClosed: (@Sendable () -> Void)?

    init(fd: Int32, queue: DispatchQueue, readChunk: Int) {
        self.fd = fd
        self.queue = queue
        self.readChunk = readChunk
        peerHost = FilesSockets.peerHost(fd)
    }

    deinit {
        if !started, phase != .closed { close(fd) }  // a started socket closes through its sources
    }

    var isClosed: Bool { phase == .closed }

    /// Bytes queued in user space and not yet taken by the kernel.
    var pendingBytes: Int { outbound.count - outboundStart }

    func start(readingPaused: Bool) {
        guard !started, phase == .open else { return }
        started = true
        let rs = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        rs.setEventHandler { [self] in readReady() }
        rs.setCancelHandler { [self] in sourceCancelled() }
        let ws = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: queue)
        ws.setEventHandler { [self] in flush() }
        ws.setCancelHandler { [self] in sourceCancelled() }
        cancelHandlersLeft = 2
        readSource = rs
        writeSource = ws
        rs.activate()
        ws.activate()
        ws.suspend()  // armed only while the kernel did not take everything
        writeSuspended = true
        if readingPaused {
            rs.suspend()
            readSuspended = true
        }
    }

    func pauseReading() {
        guard phase == .open, started, !readSuspended, let rs = readSource else { return }
        rs.suspend()
        readSuspended = true
    }

    func resumeReading() {
        guard phase != .closed, readSuspended, let rs = readSource else { return }
        rs.resume()
        readSuspended = false
    }

    /// Queues `bytes` and writes what the kernel takes right away. False when the socket is not open any more.
    @discardableResult
    func write(_ bytes: [UInt8]) -> Bool {
        guard phase == .open, !bytes.isEmpty else { return phase == .open }
        outbound.append(contentsOf: bytes)
        flush()
        return phase == .open
    }

    /// Runs `run` (on the queue, never inside this call) once `pendingBytes <= below`. One waiter at most: a later call
    /// replaces an earlier one.
    func notifyWhenPendingBelow(_ below: Int, _ run: @escaping @Sendable () -> Void) {
        if pendingBytes <= below {
            queue.async(execute: run)
        } else {
            waiter = (below, run)
        }
    }

    func closeAfterFlush(timeout: TimeInterval) {
        guard phase == .open else { return }
        guard started else { return closeNow() }
        phase = .draining
        onData = nil
        waiter = nil
        resumeReading()  // reads and discards until the peer's end of stream
        queue.asyncAfter(deadline: .now() + timeout) { [self] in closeNow() }
        if pendingBytes == 0 { shutdownWrite() }
    }

    func closeNow() {
        guard phase != .closed else { return }
        phase = .closed
        waiter = nil
        outbound.removeAll()
        outboundStart = 0
        onData = nil
        let callback = onClosed
        onClosed = nil
        if started {
            readSource?.cancel()
            if readSuspended { readSource?.resume(); readSuspended = false }  // a suspended source never cancels
            writeSource?.cancel()
            if writeSuspended { writeSource?.resume(); writeSuspended = false }
        } else {
            close(fd)
        }
        if let callback { queue.async(execute: callback) }
    }

    // MARK: Internals

    private func readReady() {
        guard phase != .closed else { return }
        var n = 0
        var err: Int32 = 0
        let chunk = readChunk
        let descriptor = fd
        let bytes = [UInt8](unsafeUninitializedCapacity: chunk) { buffer, count in
            n = Darwin.read(descriptor, buffer.baseAddress, chunk)
            if n < 0 { err = errno }
            count = max(n, 0)
        }
        if n > 0 {
            if phase == .draining { return }
            onData?(bytes)
        } else if n == 0 {
            closeNow()  // end of stream
        } else if err != EAGAIN, err != EWOULDBLOCK, err != EINTR {
            closeNow()
        }
    }

    private func flush() {
        guard phase != .closed else { return }
        while outboundStart < outbound.count {
            var err: Int32 = 0
            let start = outboundStart
            let total = outbound.count
            let descriptor = fd
            let n = outbound.withUnsafeBytes { raw -> Int in
                let r = Darwin.write(descriptor, raw.baseAddress! + start, total - start)
                if r < 0 { err = errno }
                return r
            }
            if n > 0 {
                outboundStart += n
            } else if n < 0, err == EAGAIN || err == EWOULDBLOCK {
                if writeSuspended, let ws = writeSource {
                    ws.resume()
                    writeSuspended = false
                }
                compact()
                checkWaiter()
                return
            } else if n < 0, err == EINTR {
                continue
            } else {
                closeNow()
                return
            }
        }
        outbound.removeAll(keepingCapacity: outbound.capacity <= 256 * 1024)
        outboundStart = 0
        if !writeSuspended, let ws = writeSource {
            ws.suspend()
            writeSuspended = true
        }
        if phase == .draining { shutdownWrite() }
        checkWaiter()
    }

    private func compact() {
        if outboundStart > 64 * 1024, outboundStart * 2 > outbound.count {
            outbound.removeFirst(outboundStart)
            outboundStart = 0
        }
    }

    private func checkWaiter() {
        guard let w = waiter, pendingBytes <= w.below else { return }
        waiter = nil
        queue.async(execute: w.run)
    }

    private func shutdownWrite() {
        _ = Darwin.shutdown(fd, SHUT_WR)
    }

    private func sourceCancelled() {
        cancelHandlersLeft -= 1
        if cancelHandlersLeft == 0 { close(fd) }
    }
}

// MARK: - Listener

/// A TCP listening socket whose accepted descriptors go to `onAccept` (on `queue`; the callee owns them). The file
/// listener is dual-stack (`[::]`, IPv4 as v4-mapped); the proxy listener is `127.0.0.1` only.
final class FilesListener: @unchecked Sendable {
    let port: UInt16
    private let fd: Int32
    private let queue: DispatchQueue
    private let onAccept: @Sendable (Int32) -> Void
    private var source: DispatchSourceRead?
    private var cancelled = false
    private var suspended = false

    /// Binds and listens; `port` 0 takes any port. Throws `BsdSocketError` (nothing stays open then).
    init(port: UInt16, loopbackOnly: Bool, queue: DispatchQueue, onAccept: @escaping @Sendable (Int32) -> Void) throws {
        let fd = socket(loopbackOnly ? AF_INET : AF_INET6, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { throw BsdSocketError("socket", errno) }
        do {
            var gaps: [String] = []
            guard FilesSockets.configure(fd, FilesSocketOptions(noDelay: false), gaps: &gaps) else {
                throw BsdSocketError("configure", errno)
            }
            guard FilesSockets.setInt(fd, SOL_SOCKET, SO_REUSEADDR, 1) else { throw BsdSocketError("SO_REUSEADDR", errno) }
            let bound: Int32
            if loopbackOnly {
                var addr = sockaddr_in()
                addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
                addr.sin_family = sa_family_t(AF_INET)
                addr.sin_port = port.bigEndian
                addr.sin_addr = in_addr(s_addr: UInt32(0x7F00_0001).bigEndian)
                bound = withUnsafePointer(to: &addr) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            } else {
                guard FilesSockets.setInt(fd, IPPROTO_IPV6, IPV6_V6ONLY, 0) else { throw BsdSocketError("IPV6_V6ONLY", errno) }
                var addr = sockaddr_in6()
                addr.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
                addr.sin6_family = sa_family_t(AF_INET6)
                addr.sin6_port = port.bigEndian
                addr.sin6_addr = in6addr_any
                bound = withUnsafePointer(to: &addr) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
                    }
                }
            }
            guard bound == 0 else { throw BsdSocketError("bind", errno) }
            guard listen(fd, 32) == 0 else { throw BsdSocketError("listen", errno) }
            guard let actual = FilesSockets.localPort(fd) else { throw BsdSocketError("getsockname", errno) }
            self.port = actual
        } catch {
            close(fd)
            throw error
        }
        self.fd = fd
        self.queue = queue
        self.onAccept = onAccept
    }

    deinit {
        if source == nil, !cancelled { close(fd) }
    }

    func start() {
        guard !cancelled, source == nil else { return }
        let s = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        s.setEventHandler { [self] in acceptReady() }
        s.setCancelHandler { [fd] in close(fd) }
        source = s
        s.activate()
    }

    /// Idempotent. The descriptor closes when the source is gone.
    func cancel() {
        guard !cancelled else { return }
        cancelled = true
        guard let s = source else {
            close(fd)
            return
        }
        s.cancel()
        if suspended {
            suspended = false
            s.resume()
        }
    }

    private func acceptReady() {
        for _ in 0..<16 {
            guard !cancelled, !suspended else { return }
            let client = Darwin.accept(fd, nil, nil)
            if client >= 0 {
                onAccept(client)
                continue
            }
            switch errno {
            case EAGAIN, EWOULDBLOCK, EINTR, ECONNABORTED:
                return
            case EMFILE, ENFILE, ENOBUFS, ENOMEM:
                // Level-triggered: a connection we cannot accept would spin the source, so accepting waits a second.
                guard let s = source else { return }
                suspended = true
                s.suspend()
                queue.asyncAfter(deadline: .now() + 1) { [self] in
                    guard suspended, !cancelled else { return }
                    suspended = false
                    s.resume()
                }
                return
            default:
                return
            }
        }
    }
}
