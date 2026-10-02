import Darwin
import Foundation
import MateBridgeCore
import Network

/// Read-only view of the kernel TCP state behind a video connection (T-088): send-queue bytes, RTT, retransmits.
///
/// A `BsdTcpConnection` (T-091) owns its descriptor, so it is read directly (`source=tcp_info`, no search). For an
/// `NWConnection`:
///
/// Network.framework does not expose the socket descriptor. The probe finds it in this process's descriptor table
/// (`proc_pidinfo(PROC_PIDLISTFDS)`) by matching the connection's local and remote ports with `getsockname` and
/// `getpeername`, and then only reads it with `getsockopt(TCP_CONNECTION_INFO)`. The descriptor is never closed,
/// written or kept beyond a port check: every read re-checks both ports first, so a descriptor number that was
/// reused for another socket is detected and dropped. When no descriptor matches (or the check fails),
/// `NWProtocolTCP.Metadata.availableSendBuffer` is used instead (measured on macOS 27: it reports the same queued
/// byte count as `tcpi_snd_sbbytes`), which gives the queue only.
///
/// Not thread-safe; the owner serialises calls.
final class TcpSocketProbe {
    enum Failure: String, Error {
        /// The connection has no host/port endpoints (not ready, or not TCP over IP).
        case noEndpoints = "no_endpoints"
        /// Neither a matching descriptor nor TCP metadata.
        case unavailable
    }

    private enum Target {
        case network(NWConnection)
        case socket(BsdTcpConnection)
    }

    private let target: Target
    private var ports: (local: UInt16, remote: UInt16)?
    private var fd: Int32?
    /// Samples until the next descriptor search. A failed search is retried only every `searchInterval` samples, so a
    /// missing descriptor never costs a table walk per sample.
    private var searchCountdown = 0
    private let searchInterval: Int

    /// `searchInterval`: about once a second at the caller's sampling rate (120 for the per-frame `ev=sendq`).
    init(connection: NWConnection, searchInterval: Int = 120) {
        target = .network(connection)
        self.searchInterval = searchInterval
    }

    init(socket: BsdTcpConnection) {
        target = .socket(socket)
        searchInterval = 0
    }

    /// One sample, or why none could be taken.
    func sample() -> Result<(TcpSample, SendQueueSource), Failure> {
        switch connectionInfo() {
        case .success(let info): return .success((Self.tcpSample(info), .tcpInfo))
        case .failure(let failure):
            if case .network(let connection) = target,
               let md = connection.metadata(definition: NWProtocolTCP.definition) as? NWProtocolTCP.Metadata {
                return .success((TcpSample(sendQueueBytes: UInt64(md.availableSendBuffer)), .nwMetadata))
            }
            return .failure(failure)
        }
    }

    /// One full `getsockopt(TCP_CONNECTION_INFO)` reading (T-126), without the Network.framework metadata fallback.
    func connectionInfo() -> Result<tcp_connection_info, Failure> {
        switch target {
        case .network(let connection):
            if ports == nil { ports = Self.ports(of: connection) }
            guard let ports else { return .failure(.noEndpoints) }
            if let fd, Self.socketPorts(fd).map({ $0 == ports }) != true { self.fd = nil }
            if fd == nil {
                if searchCountdown == 0 {
                    searchCountdown = searchInterval
                    fd = Self.findDescriptor(local: ports.local, remote: ports.remote)
                } else {
                    searchCountdown -= 1
                }
            }
            guard let fd, let info = Self.connectionInfo(fd) else { return .failure(.unavailable) }
            return .success(info)
        case .socket(let socket):
            // The connection checks under its lock that the descriptor is still open.
            guard let info = socket.connectionInfo() else { return .failure(.unavailable) }
            return .success(info)
        }
    }

    /// Bytes still queued in user space: known for a kernel socket only.
    var userPendingBytes: Int? {
        if case .socket(let socket) = target { return socket.pendingBytes }
        return nil
    }

    private static func tcpSample(_ info: tcp_connection_info) -> TcpSample {
        TcpSample(sendQueueBytes: UInt64(info.tcpi_snd_sbbytes), srttMs: info.tcpi_srtt, rttVarMs: info.tcpi_rttvar,
                  retransmitPackets: info.tcpi_txretransmitpackets, congestionWindowBytes: info.tcpi_snd_cwnd,
                  sendWindowBytes: info.tcpi_snd_wnd)
    }

    // MARK: Helpers

    private static func ports(of connection: NWConnection) -> (local: UInt16, remote: UInt16)? {
        guard case .hostPort(_, let remote) = connection.endpoint,
              case .hostPort(_, let local)? = connection.currentPath?.localEndpoint else { return nil }
        return (local.rawValue, remote.rawValue)
    }

    private static func findDescriptor(local: UInt16, remote: UInt16) -> Int32? {
        let pid = getpid()
        let needed = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard needed > 0 else { return nil }
        let stride = MemoryLayout<proc_fdinfo>.stride
        // Room for descriptors opened between the two calls.
        var entries = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(needed) / stride + 32)
        let got = entries.withUnsafeMutableBytes {
            proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32(clamping: $0.count))
        }
        guard got > 0 else { return nil }
        for entry in entries.prefix(Int(got) / stride) where entry.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            if let p = socketPorts(entry.proc_fd), p.local == local, p.remote == remote, isTcp(entry.proc_fd) {
                return entry.proc_fd
            }
        }
        return nil
    }

    private static func isTcp(_ fd: Int32) -> Bool {
        var type: Int32 = 0
        var len = socklen_t(MemoryLayout<Int32>.size)
        return getsockopt(fd, SOL_SOCKET, SO_TYPE, &type, &len) == 0 && type == SOCK_STREAM
    }

    private static func socketPorts(_ fd: Int32) -> (local: UInt16, remote: UInt16)? {
        guard let local = port(fd, getsockname), let remote = port(fd, getpeername) else { return nil }
        return (local, remote)
    }

    private static func port(_ fd: Int32,
                             _ call: (Int32, UnsafeMutablePointer<sockaddr>, UnsafeMutablePointer<socklen_t>) -> Int32)
        -> UInt16? {
        var storage = sockaddr_storage()
        var len = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let rc = withUnsafeMutablePointer(to: &storage) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { call(fd, $0, &len) }
        }
        guard rc == 0 else { return nil }
        return withUnsafePointer(to: &storage) { p -> UInt16? in
            switch Int32(p.pointee.ss_family) {
            case AF_INET:
                return p.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt16(bigEndian: $0.pointee.sin_port) }
            case AF_INET6:
                return p.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { UInt16(bigEndian: $0.pointee.sin6_port) }
            default:
                return nil
            }
        }
    }

    private static func connectionInfo(_ fd: Int32) -> tcp_connection_info? {
        var info = tcp_connection_info()
        var len = socklen_t(MemoryLayout<tcp_connection_info>.size)
        guard getsockopt(fd, IPPROTO_TCP, TCP_CONNECTION_INFO, &info, &len) == 0 else { return nil }
        return info
    }
}

/// Thread-safe send-queue sampler of one video connection: a probe plus a `SendQueueMeter`.
final class SendQueueSampler: @unchecked Sendable {
    private let lock = NSLock()
    private let probe: TcpSocketProbe
    private var meter = SendQueueMeter()
    private var failure: TcpSocketProbe.Failure?
    private var failureReported = false

    init(connection: NWConnection) { probe = TcpSocketProbe(connection: connection) }
    init(socket: BsdTcpConnection) { probe = TcpSocketProbe(socket: socket) }

    /// Takes one sample (call right before a frame is written: the queue this frame waits behind).
    func sample() {
        lock.withLock {
            switch probe.sample() {
            case .success(let (s, source)):
                meter.record(s, source: source)
                failure = nil
            case .failure(let f):
                failure = f
            }
        }
    }

    enum Report {
        case window(SendQueueWindow)
        /// No sample could be taken; reported once per connection.
        case unavailable(String)
    }

    /// Closes the window (about once a second).
    func take() -> Report? {
        lock.withLock {
            if let w = meter.take() { return .window(w) }
            if let failure, !failureReported {
                failureReported = true
                return .unavailable(failure.rawValue)
            }
            return nil
        }
    }
}

/// Per-second TCP state of one control or video connection (T-126, `net ev=tcp`): a probe plus a `TcpInfoMeter`.
/// Separate from the per-frame `SendQueueSampler` (`ev=sendq`); both only read the socket. Not thread-safe: the
/// session server uses it on its queue only.
final class TcpInfoSampler {
    let role: TcpConnectionRole
    private let probe: TcpSocketProbe
    private var meter = TcpInfoMeter()
    private var failureReported = false

    /// A failed descriptor search (`nw` only) is retried every 5 samples, i.e. about every 5 s at 1 Hz.
    init(role: TcpConnectionRole, connection: NWConnection) {
        self.role = role
        probe = TcpSocketProbe(connection: connection, searchInterval: 5)
    }

    init(role: TcpConnectionRole, socket: BsdTcpConnection) {
        self.role = role
        probe = TcpSocketProbe(socket: socket)
    }

    enum Report {
        case reading(TcpInfoReport)
        /// No reading could be taken; reported once per connection.
        case unavailable(String)
    }

    /// One reading. `closeWindow`: the per-second line (moves the delta base); otherwise a snapshot between windows.
    /// nil when the reading failed and that was already reported.
    func read(closeWindow: Bool) -> Report? {
        switch probe.connectionInfo() {
        case .success(let info):
            let snapshot = TcpConnectionSnapshot(info, userPendingBytes: probe.userPendingBytes)
            return .reading(closeWindow ? meter.take(snapshot) : meter.peek(snapshot))
        case .failure(let failure):
            guard !failureReported else { return nil }
            failureReported = true
            return .unavailable(failure.rawValue)
        }
    }
}
