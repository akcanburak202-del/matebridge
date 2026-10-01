import Darwin
import Dispatch
import Foundation

/// A failed socket call: the call's name and `errno`.
public struct BsdSocketError: Error, Equatable, Sendable, CustomStringConvertible {
    public var call: String
    public var errno: Int32
    public init(_ call: String, _ errno: Int32) {
        self.call = call
        self.errno = errno
    }

    public var description: String { "\(call):\(errno)" }
}

/// Socket options of an accepted connection (T-091). The defaults match the Network.framework listeners: Nagle off,
/// keepalive off (`NWProtocolTCP.Options.enableKeepalive` defaults to false), no service type.
public struct BsdTcpOptions: Equatable, Sendable {
    public var noDelay = true
    public var keepAlive = false
    /// `TCP_NOTSENT_LOWAT` in bytes: the socket reads as writable only while fewer unsent bytes are queued. nil: unset.
    public var notSentLowatBytes: Int?
    /// `SO_NET_SERVICE_TYPE` (best effort, like `NWParameters.serviceClass`). nil: unset.
    public var serviceClass: TrafficClass?

    public init(noDelay: Bool = true, keepAlive: Bool = false, notSentLowatBytes: Int? = nil,
                serviceClass: TrafficClass? = nil) {
        self.noDelay = noDelay
        self.keepAlive = keepAlive
        self.notSentLowatBytes = notSentLowatBytes
        self.serviceClass = serviceClass
    }

    /// The `NET_SERVICE_TYPE_*` value of a traffic class (the same classes `NWParameters.ServiceClass` names).
    public static func netServiceType(_ c: TrafficClass) -> Int32 {
        switch c {
        case .interactiveVideo: return NET_SERVICE_TYPE_VI
        case .interactiveVoice: return NET_SERVICE_TYPE_VO
        case .responsiveData: return NET_SERVICE_TYPE_RD
        }
    }
}

private func setOption(_ fd: Int32, _ level: Int32, _ name: Int32, _ value: Int32, _ call: String) throws {
    var v = value
    guard setsockopt(fd, level, name, &v, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
        throw BsdSocketError(call, errno)
    }
}

private func setNonBlockingCloExec(_ fd: Int32) throws {
    let flags = fcntl(fd, F_GETFL)
    guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else { throw BsdSocketError("O_NONBLOCK", errno) }
    guard fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 else { throw BsdSocketError("FD_CLOEXEC", errno) }
}

// MARK: - Listener

/// A kernel TCP listening socket (T-091). Binds `[::]:port` with `IPV6_V6ONLY` off, so it accepts IPv4 (as
/// v4-mapped) and IPv6 like the Network.framework listener (`tcp6 *.port`). Accepts on `queue`.
///
/// Every accepted socket is configured with `options` and handed over as a `BsdTcpConnection`; the receiver owns it
/// and must `start` or `cancel` it. Thread-safe.
public final class BsdTcpListener: @unchecked Sendable {
    public enum Event: Sendable {
        case accepted(BsdTcpConnection)
        /// One accepted socket could not be configured; it was closed. Listening goes on.
        case acceptConfigureFailed(BsdSocketError)
        /// Out of descriptors or buffers: accepting pauses for `pauseInterval`, then resumes.
        case acceptPaused(errno: Int32)
        /// The listening socket broke; the listener is cancelled. Reported once.
        case failed(errno: Int32)
    }

    /// Where to bind. `.any` is production; the loopback cases keep tests off the network interfaces.
    public enum BindAddress: Sendable {
        /// `::`, dual-stack.
        case any
        /// `::1` (IPv6 loopback only).
        case loopbackV6
        /// `::ffff:127.0.0.1` (IPv4 loopback through the same dual-stack socket configuration).
        case loopbackV4Mapped
    }

    public static let pauseInterval: DispatchTimeInterval = .seconds(1)
    /// Connections accepted per readiness event before yielding the queue.
    static let acceptBatch = 16

    /// The bound port (the system-assigned one when 0 was asked for).
    public let port: UInt16
    private let fd: Int32
    private let queue: DispatchQueue
    private let options: BsdTcpOptions
    private let lock = NSLock()
    private var source: DispatchSourceRead?
    private var suspended = false
    private var cancelled = false
    private var fdClosed = false
    private var handler: (@Sendable (Event) -> Void)?

    /// Creates, binds and listens. Throws `BsdSocketError` (e.g. `bind` with `EADDRINUSE`); nothing stays open then.
    public init(port: UInt16, bind address: BindAddress = .any, backlog: Int32 = 16, options: BsdTcpOptions,
                queue: DispatchQueue) throws {
        let fd = socket(AF_INET6, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { throw BsdSocketError("socket", errno) }
        do {
            try setNonBlockingCloExec(fd)
            try setOption(fd, IPPROTO_IPV6, IPV6_V6ONLY, 0, "IPV6_V6ONLY")
            try setOption(fd, SOL_SOCKET, SO_REUSEADDR, 1, "SO_REUSEADDR")
            try setOption(fd, SOL_SOCKET, SO_NOSIGPIPE, 1, "SO_NOSIGPIPE")
            var addr = sockaddr_in6()
            addr.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            addr.sin6_family = sa_family_t(AF_INET6)
            addr.sin6_port = port.bigEndian
            switch address {
            case .any: addr.sin6_addr = in6addr_any
            case .loopbackV6: addr.sin6_addr = in6addr_loopback
            case .loopbackV4Mapped:
                guard inet_pton(AF_INET6, "::ffff:127.0.0.1", &addr.sin6_addr) == 1 else {
                    throw BsdSocketError("inet_pton", EINVAL)
                }
            }
            let bound = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
                }
            }
            guard bound == 0 else { throw BsdSocketError("bind", errno) }
            guard listen(fd, backlog) == 0 else { throw BsdSocketError("listen", errno) }
            guard let actual = BsdTcpConnection.localPort(fd) else { throw BsdSocketError("getsockname", errno) }
            self.port = actual
        } catch {
            close(fd)
            throw error
        }
        self.fd = fd
        self.options = options
        self.queue = queue
    }

    deinit {
        // Only reachable without `start` (a started source retains the listener until it is cancelled).
        if !fdClosed { close(fd) }
    }

    /// Starts accepting. `handler` runs on `queue`. Ignored after `cancel()` or a second call.
    public func start(_ handler: @escaping @Sendable (Event) -> Void) {
        lock.withLock {
            guard !cancelled, source == nil else { return }
            self.handler = handler
            let s = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            s.setEventHandler { [self] in acceptReady() }
            s.setCancelHandler { [self] in
                lock.withLock {
                    if !fdClosed { close(fd); fdClosed = true }
                    self.handler = nil
                    source = nil
                }
            }
            source = s
            s.activate()
        }
    }

    /// Stops listening and closes the socket (once the source is gone). Idempotent, any thread.
    public func cancel() {
        lock.withLock {
            guard !cancelled else { return }
            cancelled = true
            guard let source else {
                if !fdClosed { close(fd); fdClosed = true }
                return
            }
            source.cancel()
            if suspended { suspended = false; source.resume() }  // a suspended source never runs its cancel handler
        }
    }

    private func acceptReady() {
        for _ in 0..<Self.acceptBatch {
            let (client, err): (Int32, Int32) = lock.withLock {
                guard !cancelled, !suspended else { return (-1, EAGAIN) }
                let c = Darwin.accept(fd, nil, nil)
                return (c, c < 0 ? errno : 0)
            }
            let h = lock.withLock { handler }
            if client >= 0 {
                switch BsdTcpConnection.adopt(client, options: options) {
                case .success(let c): h?(.accepted(c))
                case .failure(let e): h?(.acceptConfigureFailed(e))
                }
                continue
            }
            switch err {
            case EAGAIN, EWOULDBLOCK, EINTR, ECONNABORTED:
                return
            case EMFILE, ENFILE, ENOBUFS, ENOMEM:
                pause()
                h?(.acceptPaused(errno: err))
                return
            default:
                cancel()
                h?(.failed(errno: err))
                return
            }
        }
    }

    /// The source is level-triggered: a pending connection we cannot accept would spin it, so it waits.
    private func pause() {
        lock.withLock {
            guard !cancelled, !suspended, let source else { return }
            suspended = true
            source.suspend()
        }
        queue.asyncAfter(deadline: .now() + Self.pauseInterval) { [self] in
            lock.withLock {
                guard !cancelled, suspended, let source else { return }
                suspended = false
                source.resume()
            }
        }
    }
}

// MARK: - Connection

/// One connected, non-blocking kernel TCP socket (T-091): reads on the owner's queue, buffered writes with
/// partial-write handling, `TCP_NOTSENT_LOWAT`-aware writability, idempotent close. Not video-specific, so the
/// control connection can use it later.
///
/// - Reading: a `DispatchSourceRead` on the owner's queue reads at most `readChunk` bytes per event and passes them to
///   `onBytes`. End of stream or a read error closes the connection.
/// - Writing: `write` queues one record and writes as much as the kernel takes right away; the rest is written from a
///   `DispatchSourceWrite` on a private serial queue (armed only while needed). A record is completed (`true`) when
///   its last byte was accepted by the kernel, or failed (`false`) when the connection closed first. Completions run
///   on the private queue, in order, never inside `write`.
/// - Closing (`cancel`, end of stream, error): both sources are cancelled and the descriptor is closed exactly once,
///   after both cancel handlers ran. `onClosed` runs once, on the owner's queue.
///
/// Thread-safe. The lock is never held while calling out.
public final class BsdTcpConnection: @unchecked Sendable {
    public typealias Completion = @Sendable (Bool) -> Void

    /// Bytes read per readiness event.
    public static let readChunk = FrameDecoder.maxReadChunk

    /// Peer address in text form (`::ffff:192.168.1.20`, `::1`), for transport classification; nil if unknown.
    public let peerHost: String?
    public let localPort: UInt16?
    public let remotePort: UInt16?

    private let lock = NSLock()
    private let fd: Int32
    private var fdClosed = false
    private var cancelled = false
    private var started = false
    private var readSource: DispatchSourceRead?
    private var writeSource: DispatchSourceWrite?
    /// The write source is resumed (true) or suspended / not yet activated (false).
    private var writeArmed = false
    private var pendingCancelHandlers = 0
    private var outbound = SocketWriteBuffer<Completion>()
    /// Someone saw the socket above its low-water mark and waits for `writableHandler`.
    private var wantWritable = false
    private var writableHandler: (@Sendable () -> Void)?
    private var ownerQueue: DispatchQueue?
    private var closedHandler: (@Sendable () -> Void)?
    private let writeQueue = DispatchQueue(label: "dev.matebridge.socket.write")

    /// Configures an accepted socket and wraps it. On failure the descriptor is closed.
    public static func adopt(_ fd: Int32, options: BsdTcpOptions) -> Result<BsdTcpConnection, BsdSocketError> {
        do {
            try setNonBlockingCloExec(fd)
            try setOption(fd, SOL_SOCKET, SO_NOSIGPIPE, 1, "SO_NOSIGPIPE")
            try setOption(fd, IPPROTO_TCP, TCP_NODELAY, options.noDelay ? 1 : 0, "TCP_NODELAY")
            try setOption(fd, SOL_SOCKET, SO_KEEPALIVE, options.keepAlive ? 1 : 0, "SO_KEEPALIVE")
            if let lowat = options.notSentLowatBytes {
                try setOption(fd, IPPROTO_TCP, TCP_NOTSENT_LOWAT, Int32(clamping: lowat), "TCP_NOTSENT_LOWAT")
            }
            if let c = options.serviceClass {  // best effort, as with NWParameters.serviceClass
                try? setOption(fd, SOL_SOCKET, SO_NET_SERVICE_TYPE, BsdTcpOptions.netServiceType(c),
                               "SO_NET_SERVICE_TYPE")
            }
        } catch let e as BsdSocketError {
            close(fd)
            return .failure(e)
        } catch {
            close(fd)
            return .failure(BsdSocketError("adopt", EINVAL))
        }
        return .success(BsdTcpConnection(fd: fd))
    }

    private init(fd: Int32) {
        self.fd = fd
        let peer = Self.address(fd, getpeername)
        peerHost = peer?.host
        remotePort = peer?.port
        localPort = Self.localPort(fd)
    }

    deinit {
        // Only reachable without `start` (started sources retain the connection until they are cancelled).
        if !fdClosed { close(fd) }
    }

    /// Starts reading. `onBytes` runs on `queue` with each chunk read; it returns false when it closed (or wants to
    /// close) the connection. `onClosed` runs once on `queue` after the connection closed for any reason, including
    /// `cancel()` before or during `start`. A second call is ignored.
    public func start(queue: DispatchQueue, onBytes: @escaping @Sendable ([UInt8]) -> Bool,
                      onClosed: @escaping @Sendable () -> Void) {
        let alreadyClosed: Bool = lock.withLock {
            guard !started else { return false }
            started = true
            ownerQueue = queue
            if cancelled { return true }
            closedHandler = onClosed
            let rs = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            rs.setEventHandler { [self] in readReady(onBytes) }
            rs.setCancelHandler { [self] in sourceCancelled() }
            let ws = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: writeQueue)
            ws.setEventHandler { [self] in writeReady() }
            ws.setCancelHandler { [self] in sourceCancelled() }
            readSource = rs
            writeSource = ws
            pendingCancelHandlers = 2
            rs.activate()
            if !outbound.isEmpty || wantWritable { armWriteLocked() }  // a write before start left bytes behind
            return false
        }
        if alreadyClosed { queue.async { onClosed() } }
    }

    /// Called whenever the socket became writable after `isWritableForNewRecord` said no (and when the connection
    /// closes, so a waiting writer wakes up). Runs on the private write queue. nil clears it.
    public func setWritableHandler(_ handler: (@Sendable () -> Void)?) {
        lock.withLock { writableHandler = handler }
    }

    /// True when a new record can be queued without building a backlog: nothing of ours is waiting in user space and
    /// the kernel reports the socket writable (with `TCP_NOTSENT_LOWAT`: fewer unsent bytes than the mark). When it
    /// returns false the writable handler fires once that changes. True after the connection closed, so a writer
    /// finds out through its write's completion (`false`) instead of waiting.
    public var isWritableForNewRecord: Bool {
        lock.withLock {
            if cancelled { return true }
            let writable = outbound.isEmpty && Self.pollWritable(fd)
            if !writable {
                wantWritable = true
                armWriteLocked()
            }
            return writable
        }
    }

    /// Queues one record. `completion(true)` once all of it was accepted by the kernel, `completion(false)` if the
    /// connection closed first (including when it is already closed). Called exactly once, on the write queue.
    public func write(_ bytes: [UInt8], completion: @escaping Completion) {
        var done: [Completion] = []
        var failure: Int32?
        let accepted: Bool = lock.withLock {
            guard !cancelled else { return false }
            outbound.append(bytes, token: completion)
            let (outcome, completed) = drainLocked()
            done = completed
            switch outcome {
            case .drained: break
            case .wouldBlock: armWriteLocked()
            case .failed(let e): failure = e
            }
            return true
        }
        guard accepted else {
            writeQueue.async { completion(false) }
            return
        }
        complete(done, true)
        if failure != nil { cancel() }
    }

    /// Bytes queued in user space and not yet handed to the kernel.
    public var pendingBytes: Int { lock.withLock { outbound.pendingBytes } }

    /// `getsockopt(TCP_CONNECTION_INFO)` while the descriptor is open; nil after close or on failure.
    public func connectionInfo() -> tcp_connection_info? {
        lock.withLock {
            guard !fdClosed else { return nil }
            var info = tcp_connection_info()
            var len = socklen_t(MemoryLayout<tcp_connection_info>.size)
            guard getsockopt(fd, IPPROTO_TCP, TCP_CONNECTION_INFO, &info, &len) == 0 else { return nil }
            return info
        }
    }

    /// Closes the connection: unwritten records fail, reading and writing stop, the descriptor closes once both
    /// sources are gone. The peer sees end of stream. Idempotent, any thread.
    public func cancel() {
        var failed: [Completion] = []
        var closed: (DispatchQueue, @Sendable () -> Void)?
        var wake: (@Sendable () -> Void)?
        lock.withLock {
            guard !cancelled else { return }
            cancelled = true
            failed = outbound.removeAll()
            wake = wantWritable ? writableHandler : nil
            wantWritable = false
            if let ownerQueue, let closedHandler { closed = (ownerQueue, closedHandler) }
            closedHandler = nil
            if readSource == nil, writeSource == nil {
                if !fdClosed { close(fd); fdClosed = true }
            } else {
                readSource?.cancel()
                if let ws = writeSource {
                    ws.cancel()
                    if !writeArmed { writeArmed = true; ws.resume() }  // a suspended source never runs its cancel handler
                }
            }
        }
        complete(failed, false)
        if let wake { writeQueue.async { wake() } }
        if let (queue, handler) = closed { queue.async { handler() } }
    }

    // MARK: Internals

    private func complete(_ completions: [Completion], _ ok: Bool) {
        guard !completions.isEmpty else { return }
        writeQueue.async { for c in completions { c(ok) } }
    }

    /// Caller holds `lock`.
    private func drainLocked() -> (SocketWriteBuffer<Completion>.DrainOutcome, completed: [Completion]) {
        outbound.drain { chunk in
            let n = Darwin.write(fd, chunk.baseAddress, chunk.count)
            return .from(returnValue: n, errno: n < 0 ? errno : 0)
        }
    }

    /// Caller holds `lock`. Before `start` there is no source yet; `start` arms it then.
    private func armWriteLocked() {
        guard !cancelled, let ws = writeSource, !writeArmed else { return }
        writeArmed = true
        ws.resume()
    }

    private func writeReady() {
        var done: [Completion] = []
        var failure: Int32?
        var wake: (@Sendable () -> Void)?
        lock.withLock {
            guard !cancelled else { return }
            if !outbound.isEmpty {
                let (outcome, completed) = drainLocked()
                done = completed
                switch outcome {
                case .drained: break
                case .wouldBlock: return  // stay armed
                case .failed(let e): failure = e; return
                }
            }
            // Nothing of ours is left. The source fired, so the kernel is below the mark: wake a waiting writer.
            if wantWritable {
                wantWritable = false
                wake = writableHandler
            }
            if writeArmed, let ws = writeSource {
                writeArmed = false
                ws.suspend()  // level-triggered: it would fire continuously while writable
            }
        }
        complete(done, true)
        if failure != nil { cancel(); return }
        if let wake { writeQueue.async { wake() } }
    }

    private func readReady(_ onBytes: @Sendable ([UInt8]) -> Bool) {
        var buffer = [UInt8](repeating: 0, count: Self.readChunk)
        let (n, err): (Int, Int32) = lock.withLock {
            guard !cancelled else { return (-1, EAGAIN) }
            let n = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            return (n, n < 0 ? errno : 0)
        }
        if n > 0 {
            if !onBytes(Array(buffer[..<n])) { cancel() }
        } else if n == 0 {
            cancel()  // end of stream
        } else if err != EAGAIN, err != EWOULDBLOCK, err != EINTR {
            cancel()
        }
    }

    private func sourceCancelled() {
        lock.withLock {
            pendingCancelHandlers -= 1
            guard pendingCancelHandlers == 0 else { return }
            if !fdClosed { close(fd); fdClosed = true }
            readSource = nil
            writeSource = nil
            writableHandler = nil
        }
    }

    private static func pollWritable(_ fd: Int32) -> Bool {
        var p = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        guard poll(&p, 1, 0) == 1 else { return false }
        // Errors and hang-ups count as writable: the next write fails and closes the connection.
        return p.revents & Int16(POLLOUT | POLLERR | POLLHUP | POLLNVAL) != 0
    }

    static func localPort(_ fd: Int32) -> UInt16? { address(fd, getsockname)?.port }

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
