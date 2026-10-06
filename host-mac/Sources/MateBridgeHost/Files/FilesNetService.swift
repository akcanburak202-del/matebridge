import Darwin
import Dispatch
import Foundation
import MateBridgeCore

/// The Mac end of the Wi-Fi tablet files (decision 0035, T-268, docs/PROTOCOL.md section 4 "Dosya bağlantısı"):
///
/// - a file listener the tablet's encrypted file connections come to (preferred port 47003, else a system port;
///   only the peer address of the session's control connection is served, `FILES_HELLO` and the first authenticated
///   PING within 5 s, at most 2 connections that have not proven themselves),
/// - the loopback proxy (127.0.0.1, preferred port 47012) Finder's NetFS connects to: every Finder connection is
///   paired 1:1 with an idle proven file connection and its bytes travel as `FILES_DATA`,
/// - the pure `FilesConnectionMachine` of the Core decides everything about connection state; this class only does
///   sockets, records, timers and the byte pumps.
///
/// Back pressure and no loss: the pump of each direction reads from its source only while the destination buffer is
/// below 64 KiB; a chunk waiting for the rate cap is held (never dropped). Finder to tablet (H to C) goes through
/// `FilesRateLimiter` (the video-derived file budget); the tablet limits its own direction. A close is 1:1 and
/// carries no message: the end that closed first lets the other finish its pending bytes, then closes too.
///
/// Logging: counters and states only. Never file or HTTP content, tokens, keys, nonces or paths.
///
/// All state is confined to one serial queue; the public methods are safe from any thread (`start` and `stop*` wait).
public final class FilesNetService: @unchecked Sendable {
    public struct Ports: Equatable, Sendable {
        /// Loopback proxy Finder mounts through (`http://127.0.0.1:<proxy>/MatePad/`).
        public var proxy: UInt16
        /// TCP port of the file listener, the `port` of `FILES_NET(OPEN)`.
        public var files: UInt16
    }

    /// `FilesKeys` of a connection from the active session `sessionID` and the two nonces, nil when that session is gone.
    public typealias KeyProvider = @Sendable (_ sessionID: UInt32, _ clientNonce: [UInt8], _ hostNonce: [UInt8]) -> FilesKeys?

    public static let preferredFilesPort: UInt16 = 47003

    /// Per direction and connection: the pumps stop reading from the source above `highWater`, resume below `lowWater`.
    static let highWater = 64 * 1024
    static let lowWater = 32 * 1024
    /// Record framing and tag on top of a `FILES_DATA` chunk, as counted by the buffer check.
    static let recordSlack = 64
    /// One `FILES_DATA` of the Finder to tablet direction (PROTOCOL.md section 4: on Wi-Fi at most 16 KiB).
    static let dataChunk = 16 * 1024
    /// A closing socket gets this long to deliver what it still owes.
    static let closeFlushSeconds: TimeInterval = 3

    private let queue = DispatchQueue(label: "dev.matebridge.files.net", qos: .utility)
    private let logger = SessionLogger(component: "files")

    // Everything below is confined to `queue`.

    private final class FileConn: @unchecked Sendable {
        let id: FilesConnID
        let socket: FilesSocket
        /// Plain bytes of `FILES_HELLO` until the keys exist.
        var helloBuffer: [UInt8] = []
        var decoder: RecordDecoder?
        var sealer: RecordSealer?
        var local: LocalConnID?
        var hostSentData = false

        init(id: FilesConnID, socket: FilesSocket) {
            self.id = id
            self.socket = socket
        }
    }

    private final class LocalConn: @unchecked Sendable {
        let id: LocalConnID
        let socket: FilesSocket
        var file: FilesConnID?
        var lane = FilesRateLane()
        /// A chunk read from Finder and not yet sent (rate wait or a full file connection buffer). Reading is paused.
        var held: [UInt8]?
        /// The tablet answered since Finder's last chunk: Finder's next chunk starts a new exchange (new lane budget).
        var sawInbound = false

        init(id: LocalConnID, socket: FilesSocket) {
            self.id = id
            self.socket = socket
        }
    }

    private struct Window {
        var toTablet = 0
        var fromTablet = 0
        var throttledNs: UInt64 = 0
        var accepted = 0
        var closed = 0
        var isQuiet: Bool { toTablet == 0 && fromTablet == 0 && throttledNs == 0 && accepted == 0 && closed == 0 }
    }

    private var machine = FilesConnectionMachine()
    private var fileListener: FilesListener?
    private var proxyListener: FilesListener?
    private var sessionID: UInt32 = 0
    private var keyProvider: KeyProvider?
    private var files: [FilesConnID: FileConn] = [:]
    private var locals: [LocalConnID: LocalConn] = [:]
    /// File connections the machine told us to close and whose socket is still flushing or not yet closed. Only the
    /// socket's real closure reports `machine.fileClosed` (the machine keeps counting them until then).
    private var closingFiles: [FilesConnID: FileConn] = [:]
    private var nextFileID: UInt64 = 0
    private var nextLocalID: UInt64 = 0
    private var limiter = FilesRateLimiter(videoKbps: 0, now: 0)
    private var videoKbps: UInt32 = 0
    private var timer: DispatchSourceTimer?
    private var window = Window()
    private var windowTicks = 0
    private var running = false
    private var loggedSocketGaps = false
    /// Largest user-space write buffers seen since `start` (diagnostics for the selftest, never logged per byte).
    private var peakFilePending = 0
    private var peakLocalPending = 0

    private let fileOptions = FilesSocketOptions(noDelay: true, keepAlive: true, sendBufferBytes: 128 * 1024,
                                                 notSentLowatBytes: 16 * 1024, backgroundService: true)
    private let localOptions = FilesSocketOptions(noDelay: true)

    public init() {}

    public var isRunning: Bool { queue.sync { running } }

    /// Largest write buffers (bytes) of the Finder to tablet direction (file connection) and the tablet to Finder
    /// direction (Finder connection) since `start`. The relay limit is 64 KiB per connection and direction; the second
    /// may exceed it by the one record that was being decoded.
    public var peakBuffers: (toTablet: Int, toFinder: Int) { queue.sync { (peakFilePending, peakLocalPending) } }

    // MARK: - Control (any thread)

    /// Opens the file listener and the loopback proxy for the active session `sessionID` whose control connection came
    /// from `controlPeer`, and opens the connection machine. Replaces a previous run. nil when a listener could not be
    /// bound (nothing stays open). `videoKbps` is the current `STREAM_CONFIG.bitrate_kbps` (0 unknown).
    public func start(sessionID: UInt32, controlPeer: String, videoKbps: UInt32, keys: @escaping KeyProvider) -> Ports? {
        queue.sync {
            if running { stopLocked(reason: "restart") }
            var fallbacks = 0
            let filesListener: FilesListener
            let proxy: FilesListener
            do {
                filesListener = try bind(preferred: Self.preferredFilesPort, loopbackOnly: false, fallbacks: &fallbacks) {
                    [weak self] fd in
                    if let self { fileAccepted(fd) } else { close(fd) }
                }
            } catch {
                logger.log(.error, "files_net", sessionID: sessionID, generation: 0,
                           fields: "state=failed stage=file_listener error=\(error)")
                return nil
            }
            do {
                proxy = try bind(preferred: WebDavMount.proxyPreferredLocalPort, loopbackOnly: true, fallbacks: &fallbacks) {
                    [weak self] fd in
                    if let self { localAccepted(fd) } else { close(fd) }
                }
            } catch {
                filesListener.cancel()
                logger.log(.error, "files_net", sessionID: sessionID, generation: 0,
                           fields: "state=failed stage=proxy_listener error=\(error)")
                return nil
            }
            self.sessionID = sessionID
            keyProvider = keys
            fileListener = filesListener
            proxyListener = proxy
            self.videoKbps = videoKbps
            limiter = FilesRateLimiter(videoKbps: videoKbps, now: Self.nowNs())
            machine = FilesConnectionMachine()
            window = Window()
            windowTicks = 0
            running = true
            loggedSocketGaps = false
            peakFilePending = 0
            peakLocalPending = 0
            filesListener.start()
            proxy.start()
            logger.log(.info, "files_net", sessionID: sessionID, generation: 0,
                       fields: "state=listening files_port=\(filesListener.port) proxy_port=\(proxy.port) fallback=\(fallbacks)")
            run(machine.open(sessionID: sessionID, controlPeer: controlPeer, max: Int(TabletFilesPlanner.netMax),
                             pool: Int(TabletFilesPlanner.netPool), now: Self.nowUs()))
            startTimer()
            return Ports(proxy: proxy.port, files: filesListener.port)
        }
    }

    /// Closes the proxy and every file connection if `proxyPort` is the running proxy (no `FILES_NET` message: the
    /// caller decides whether the tablet is told).
    public func stop(proxyPort: UInt16) {
        queue.sync {
            guard running, proxyListener?.port == proxyPort else { return }
            stopLocked(reason: "stop")
        }
    }

    /// Closes everything that is open. Idempotent.
    public func stopAll() {
        queue.sync { if running { stopLocked(reason: "stop") } }
    }

    /// The session ended: no new file connection is accepted from now on (the ones in use close with `stopAll`, which
    /// comes after the volume was detached).
    public func sessionEnded() {
        queue.async { [self] in
            guard running else { return }
            fileListener?.cancel()
            fileListener = nil
        }
    }

    /// `STREAM_CONFIG.bitrate_kbps` of the live session changed: the file budget follows at once.
    public func setVideoKbps(_ kbps: UInt32) {
        queue.async { [self] in
            videoKbps = kbps
            if running { limiter.setVideoKbps(kbps, now: Self.nowNs()) }
        }
    }

    // MARK: - Lifecycle (on queue)

    /// The preferred port first, then a system-assigned one (counted in `fallbacks`, logged with the ports).
    private func bind(preferred: UInt16, loopbackOnly: Bool, fallbacks: inout Int,
                      onAccept: @escaping @Sendable (Int32) -> Void) throws -> FilesListener {
        do {
            return try FilesListener(port: preferred, loopbackOnly: loopbackOnly, queue: queue, onAccept: onAccept)
        } catch {
            fallbacks += 1
            return try FilesListener(port: 0, loopbackOnly: loopbackOnly, queue: queue, onAccept: onAccept)
        }
    }

    private func stopLocked(reason: String) {
        run(machine.close(.sessionEnded, now: Self.nowUs()))
        fileListener?.cancel()
        proxyListener?.cancel()
        fileListener = nil
        proxyListener = nil
        timer?.cancel()
        timer = nil
        keyProvider = nil
        // Anything the machine did not know (a file connection before its first byte) still goes.
        for conn in Array(files.values) { conn.socket.closeNow() }
        for conn in Array(locals.values) { conn.socket.closeNow() }
        // Sockets still flushing a close are cut as well: nothing of this run may keep transmitting, nor outlive it.
        for conn in Array(closingFiles.values) { conn.socket.closeNow() }
        files.removeAll()
        locals.removeAll()
        closingFiles.removeAll()
        running = false
        logger.log(.info, "files_net", sessionID: sessionID, generation: 0, fields: "state=stopped reason=\(reason)")
        sessionID = 0
    }

    private func startTimer() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + .milliseconds(200), repeating: .milliseconds(200))
        t.setEventHandler { [self] in tick() }
        timer = t
        t.activate()
    }

    private func tick() {
        guard running else { return }
        run(machine.tick(now: Self.nowUs()))
        windowTicks += 1
        guard windowTicks >= 5 else { return }
        windowTicks = 0
        let w = window
        window = Window()
        let c = machine.counts
        if !w.isQuiet {
            logger.log(.info, "files_stats", sessionID: sessionID, generation: 0,
                       fields: "total=\(c.total) idle=\(c.idle) bound=\(c.bound) unproven=\(c.unproven) waiting=\(c.waitingLocal) closing=\(c.closing)"
                           + " accepted=\(w.accepted) closed=\(w.closed) to_tablet_bytes=\(w.toTablet)"
                           + " from_tablet_bytes=\(w.fromTablet) throttled_ms=\(w.throttledNs / 1_000_000)"
                           + " cap_bps=\(limiter.mainBytesPerSec)")
        }
    }

    // MARK: - Accept (on queue)

    private func fileAccepted(_ fd: Int32) {
        var gaps: [String] = []
        guard running, FilesSockets.configure(fd, fileOptions, gaps: &gaps) else {
            close(fd)
            return
        }
        if !gaps.isEmpty, !loggedSocketGaps {
            loggedSocketGaps = true  // once per run: the file path works without them, only less politely
            logger.log(.warning, "files_net", sessionID: sessionID, generation: 0,
                       fields: "state=socket_options_refused options=\(gaps.joined(separator: ","))")
        }
        let socket = FilesSocket(fd: fd, queue: queue, readChunk: 32 * 1024)
        nextFileID += 1
        let id = FilesConnID(nextFileID)
        let conn = FileConn(id: id, socket: socket)
        files[id] = conn
        socket.onData = { [weak self] bytes in self?.fileData(id, bytes) }
        socket.onClosed = { [weak self] in self?.fileSocketClosed(id) }
        socket.start(readingPaused: false)
        window.accepted += 1
        run(machine.accepted(id, peer: socket.peerHost ?? "", now: Self.nowUs()))
    }

    private func localAccepted(_ fd: Int32) {
        var gaps: [String] = []
        guard running, FilesSockets.configure(fd, localOptions, gaps: &gaps) else {
            close(fd)
            return
        }
        let socket = FilesSocket(fd: fd, queue: queue, readChunk: Self.dataChunk)
        nextLocalID += 1
        let id = LocalConnID(nextLocalID)
        let conn = LocalConn(id: id, socket: socket)
        locals[id] = conn
        socket.onData = { [weak self] bytes in self?.localData(id, bytes) }
        socket.onClosed = { [weak self] in self?.localSocketClosed(id) }
        socket.start(readingPaused: true)  // nothing is read until a file connection is bound to it
        run(machine.localOpened(id, now: Self.nowUs()))
    }

    // MARK: - File connection input (on queue)

    private func fileData(_ id: FilesConnID, _ bytes: [UInt8]) {
        guard running, let conn = files[id] else { return }
        if conn.decoder == nil {
            helloBytes(conn, bytes)
        } else {
            recordBytes(conn, bytes)
        }
    }

    /// Plain phase: exactly one `FILES_HELLO` is valid (type 0x50; trailing extension bytes are allowed up to the
    /// 65 536 byte payload limit of PROTOCOL.md section 2, so the 22 byte minimum and any longer one both pass). The
    /// memory a peer that has not proven itself can pin is bounded by the limit of 2 such connections. Bytes behind
    /// the frame are records.
    private func helloBytes(_ conn: FileConn, _ bytes: [UInt8]) {
        let id = conn.id
        conn.helloBuffer += bytes
        let header = ProtocolConstants.headerSize
        guard conn.helloBuffer.count >= header else { return }
        guard conn.helloBuffer[0] == MessageType.filesHello.rawValue else { return run(machine.protocolError(id, now: Self.nowUs())) }
        let length = (0..<4).reduce(UInt32(0)) { $0 | UInt32(conn.helloBuffer[1 + $1]) << (8 * UInt32($1)) }
        guard length <= UInt32(ProtocolConstants.maxControlPayload) else { return run(machine.protocolError(id, now: Self.nowUs())) }
        let total = header + Int(length)
        guard conn.helloBuffer.count >= total else { return }
        var decoder = FrameDecoder(connection: .files)
        var offset = 0
        while offset < total {  // `FrameDecoder` takes at most `maxReadChunk` bytes per call
            let end = min(total, offset + FrameDecoder.maxReadChunk)
            decoder.append(Array(conn.helloBuffer[offset..<end]))
            offset = end
        }
        let rest = Array(conn.helloBuffer[total...])
        conn.helloBuffer = []
        guard let message = try? decoder.nextMessage(), case .filesHello(let hello) = message else {
            return run(machine.protocolError(id, now: Self.nowUs()))
        }
        run(machine.hello(id, hello, now: Self.nowUs()))
        if !rest.isEmpty, files[id]?.decoder != nil { recordBytes(conn, rest) }
    }

    /// Record phase: `PING` (proof, keep-alive) and `FILES_DATA` are the only valid messages; the machine decides.
    private func recordBytes(_ conn: FileConn, _ bytes: [UInt8]) {
        conn.decoder?.append(bytes)
        pumpRecords(conn)
    }

    /// Pulls records out of the decoder. While the paired Finder connection has a full write buffer (64 KiB) no further
    /// record is taken and the file socket is not read: at most that buffer plus the one record being decoded is held
    /// per connection and direction (PROTOCOL.md section 5). Reading and decoding resume below 32 KiB.
    private func pumpRecords(_ conn: FileConn) {
        let id = conn.id
        while running, files[id] === conn, conn.decoder != nil {
            if let lid = conn.local, let local = locals[lid], local.socket.pendingBytes >= Self.highWater {
                conn.socket.pauseReading()
                local.socket.notifyWhenPendingBelow(Self.lowWater) { [weak self, weak conn] in
                    guard let self, let conn else { return }
                    conn.socket.resumeReading()
                    pumpRecords(conn)
                }
                return
            }
            let message: Message?
            do {
                message = try conn.decoder!.nextMessage()
            } catch is CryptoError {
                return run(machine.recordAuthFailed(id, now: Self.nowUs()))
            } catch {
                return run(machine.protocolError(id, now: Self.nowUs()))
            }
            guard let message else { return }
            let payload: [UInt8]? = if case .filesData(let d) = message { d.data } else { nil }
            run(machine.record(id, message, now: Self.nowUs()), payload: payload)
        }
    }

    private func fileSocketClosed(_ id: FilesConnID) {
        guard running else { return }
        if closingFiles.removeValue(forKey: id) != nil {  // we closed it: now it is really gone (after its flush)
            run(machine.fileClosed(id))
            return
        }
        guard files.removeValue(forKey: id) != nil else { return }
        window.closed += 1
        run(machine.fileClosed(id))
    }

    // MARK: - Finder (local) connection input (on queue)

    private func localData(_ lid: LocalConnID, _ bytes: [UInt8]) {
        guard running, let local = locals[lid], let fid = local.file, let file = files[fid] else { return }
        if local.sawInbound {  // the tablet answered: this is the start of the next request
            local.lane.reset()
            local.sawInbound = false
        }
        let wait = limiter.reserve(bytes.count, lane: &local.lane, now: Self.nowNs())
        window.toTablet += bytes.count
        if wait == 0, hasRoom(for: bytes.count, on: file) {
            send(bytes, on: file)
            return
        }
        // Rate cap or a full buffer: hold this chunk, stop reading, send when allowed. Never dropped.
        local.held = bytes
        local.socket.pauseReading()
        if wait > 0 {
            window.throttledNs += wait
            queue.asyncAfter(deadline: .now() + .nanoseconds(Int(min(wait, UInt64(Int.max))))) { [weak self] in
                self?.releaseHeld(lid)
            }
        } else {
            releaseHeld(lid)
        }
    }

    private func releaseHeld(_ lid: LocalConnID) {
        guard running, let local = locals[lid], let held = local.held, let fid = local.file, let file = files[fid] else { return }
        guard hasRoom(for: held.count, on: file) else {
            file.socket.notifyWhenPendingBelow(Self.lowWater) { [weak self] in self?.releaseHeld(lid) }
            return
        }
        local.held = nil
        send(held, on: file)
        local.socket.resumeReading()
    }

    /// The 64 KiB relay buffer of the Finder to tablet direction has room for this chunk (checked before it is
    /// enqueued, so the buffer never exceeds the limit). `lowWater` plus the largest chunk always fits.
    private func hasRoom(for chunk: Int, on file: FileConn) -> Bool {
        file.socket.pendingBytes + chunk + Self.recordSlack <= Self.highWater
    }

    /// Seals `bytes` (one `FILES_DATA`, 1...16 KiB) and queues it on the file connection.
    private func send(_ bytes: [UInt8], on file: FileConn) {
        guard file.sealer != nil else { return }
        let sealed: [UInt8]
        do {
            sealed = try Message.filesData(FilesData(data: bytes)).sealed(using: &file.sealer!)
        } catch {
            // Only a counter at its limit lands here: this connection is finished.
            logger.log(.warning, "files_conn", sessionID: sessionID, generation: 0,
                       fields: "conn=\(file.id.raw) state=closed reason=seal_failed")
            files[file.id] = nil
            closingFiles[file.id] = file
            window.closed += 1
            file.socket.closeNow()  // `fileSocketClosed` reports it to the machine once the socket is closed
            return
        }
        file.socket.write(sealed)
        peakFilePending = max(peakFilePending, file.socket.pendingBytes)
        if !file.hostSentData {
            file.hostSentData = true
            machine.hostSentData(file.id)  // the first FILES_DATA is the host's; the tablet may answer from now on
        }
    }

    private func localSocketClosed(_ lid: LocalConnID) {
        guard running, let local = locals.removeValue(forKey: lid) else { return }  // one we closed ourselves is gone
        // Bytes Finder sent before it closed go to the tablet first (the cap does not delay a closing connection).
        if let held = local.held, let fid = local.file, let file = files[fid] {
            local.held = nil
            send(held, on: file)
        }
        run(machine.localClosed(lid, now: Self.nowUs()))
    }

    // MARK: - Machine actions (on queue)

    private func run(_ actions: [FilesAction], payload: [UInt8]? = nil) {
        for action in actions {
            switch action {
            case .sendAck(let id, let ack):
                if let conn = files[id], let bytes = try? Message.filesHelloAck(ack).encode() { conn.socket.write(bytes) }
            case .startRecords(let id, let clientNonce, let hostNonce):
                guard let conn = files[id] else { continue }
                guard let keys = keyProvider?(sessionID, clientNonce, hostNonce) else {
                    run(machine.keysUnavailable(id, now: Self.nowUs()))
                    continue
                }
                conn.decoder = RecordDecoder(key: keys.c2h, connection: .files)
                conn.sealer = RecordSealer(key: keys.h2c, maxPayload: ProtocolConstants.maxControlPayload)
            case .close(let id, let reason):
                guard let conn = files.removeValue(forKey: id) else { continue }
                closingFiles[id] = conn
                window.closed += 1
                if let lid = conn.local, let local = locals[lid], local.file == id { local.file = nil }
                switch reason {
                case .rejected, .localClosed:  // the ACK / the bytes Finder sent still go out first
                    conn.socket.closeAfterFlush(timeout: Self.closeFlushSeconds)
                default:
                    conn.socket.closeNow()
                }
            case .abort(let id):
                // The flush of a close did not finish in time: drop what is queued; the socket's `onClosed` reports it.
                if let conn = closingFiles[id] { conn.socket.closeNow() }
            case .bind(let fid, let lid):
                guard let file = files[fid], let local = locals[lid] else { continue }
                file.local = lid
                local.file = fid
                local.sawInbound = false
                local.lane.reset()
                local.socket.resumeReading()
            case .closeLocal(let lid, let reason):
                guard let local = locals.removeValue(forKey: lid) else { continue }
                if let fid = local.file, let file = files[fid], file.local == lid { file.local = nil }
                if reason == .fileClosed {  // what the tablet already sent still reaches Finder
                    local.socket.closeAfterFlush(timeout: Self.closeFlushSeconds)
                } else {
                    local.socket.closeNow()
                }
            case .dataToLocal(let fid, let lid):
                guard let payload, let local = locals[lid], files[fid] != nil else { continue }
                local.sawInbound = true
                window.fromTablet += payload.count
                local.socket.write(payload)  // `pumpRecords` takes no further record while this buffer is full
                peakLocalPending = max(peakLocalPending, local.socket.pendingBytes)
            case .log(let level, let ev, let conn, let fields):
                let id = conn.map { "conn=\($0.raw) " } ?? ""
                logger.log(level, ev, sessionID: sessionID, generation: 0, fields: id + fields)
            }
        }
    }

    // MARK: - Clocks

    private static func nowUs() -> UInt64 { HostClock.nowUs() }
    private static func nowNs() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
}
