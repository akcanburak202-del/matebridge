import Darwin
import Dispatch
import Foundation
import MateBridgeCore
import os

/// The Mac end of the tablet camera connection (decision 0040, T-354, docs/PROTOCOL.md section 4 "Kamera bağlantısı"):
/// a listener (preferred port 47004, else a system port) the tablet's encrypted camera connection comes to, the pure
/// `CameraConnectionMachine` of the Core deciding every state, a bounded H.264 decode path (`CameraStreamGate`:
/// at most 2 frames wait, overflow drops them and asks for a keyframe) and a hand-over of every decoded frame to `sink`.
///
/// Nothing exists while the camera is off: the service is created by `open` for one START and `close` removes the
/// listener, sockets, timer and decoder. Frame content is never logged or written, only counters.
///
/// All state is confined to one serial queue; the public methods are safe from any thread (`open` and `close` wait).
final class CameraConnectionService: @unchecked Sendable {
    /// `CameraKeys` of a connection from the active session `sessionID` and the two nonces, nil when that session is gone.
    typealias KeyProvider = @Sendable (_ sessionID: UInt32, _ clientNonce: [UInt8], _ hostNonce: [UInt8]) -> CameraKeys?

    static let preferredPort: UInt16 = 47004
    /// The 10 s summary of the PROTOCOL / LOGGING contract.
    static let summaryTicks = 50  // 50 x 200 ms
    static let closeFlushSeconds: TimeInterval = 2

    private let queue = DispatchQueue(label: "dev.matebridge.camera.net", qos: .userInitiated)
    private let decodeQueue = DispatchQueue(label: "dev.matebridge.camera.decode", qos: .userInitiated)
    private let outQueue = DispatchQueue(label: "dev.matebridge.camera.out", qos: .userInitiated)
    private let logger = SessionLogger(component: "camera")

    private final class Conn: @unchecked Sendable {
        let id: CameraConnID
        let socket: FilesSocket
        /// Plain bytes of `CAM_HELLO` until the keys exist.
        var helloBuffer: [UInt8] = []
        var decoder: RecordDecoder?
        var sealer: RecordSealer?

        init(id: CameraConnID, socket: FilesSocket) {
            self.id = id
            self.socket = socket
        }
    }

    // Everything below is confined to `queue`, except where noted.
    private var machine = CameraConnectionMachine()
    private var gate = CameraStreamGate()
    private var listener: FilesListener?
    private var sessionID: UInt32 = 0
    private var camID: UInt16 = 0
    private var keyProvider: KeyProvider?
    private var conns: [CameraConnID: Conn] = [:]
    /// Sockets the machine closed and whose real closure has not been reported yet (flushing an ACK).
    private var closing: [CameraConnID: Conn] = [:]
    private var activeID: CameraConnID?
    private var nextConnID: UInt64 = 0
    private var timer: DispatchSourceTimer?
    private var running = false
    private var decoder: H264CameraDecoder?
    private var summaryTicks = 0
    private var framesIn = 0
    private var bytesIn = 0
    private var keyframeRequests = 0
    private var windowStartedUs: UInt64 = 0

    /// Newest-epoch readable from the decode and output queues without hopping onto `queue`.
    private let epochBox = OSAllocatedUnfairLock<UInt64>(initialState: 0)
    /// Advances whenever the active connection changes or goes (T-357, Codex P2): work queued for an older connection,
    /// such as a pending `CODEC_CONFIG`, is skipped. Not the gate's epoch: an overflow voids frames but a config stays valid.
    private let connectionGeneration = OSAllocatedUnfairLock<UInt64>(initialState: 0)
    /// Frames and the newest `CODEC_CONFIG` waiting for the decoder: at most two frames, one config, one drain closure
    /// on the decode queue (T-357 r2). Every item carries its decoder, so work of an old run never touches a new decoder.
    private struct FrameWork: @unchecked Sendable {
        var data: [UInt8]
        var captureTimeUs: UInt64
        var epoch: UInt64
        var generation: UInt64
        var decoder: H264CameraDecoder
    }
    private struct ConfigWork: @unchecked Sendable {
        var data: [UInt8]
        var generation: UInt64
        var decoder: H264CameraDecoder
    }
    private let store = OSAllocatedUnfairLock<CameraDecodeStore<FrameWork, ConfigWork>>(uncheckedState: CameraDecodeStore())
    private let scaler = CameraFrameScaler(width: ObsVirtualCamera.sinkWidth, height: ObsVirtualCamera.sinkHeight)

    /// Called on `queue`: a camera connection became the active one (true) or the active one ended (false).
    var onActive: (@Sendable (Bool) -> Void)?
    /// Called on the output queue for every decoded frame at the sink size. Must not block.
    var sink: (@Sendable (CameraPixelBuffer) -> Void)?
    /// Called on `queue` with the sink counters for the 10 s summary: (written, queue full, dropped while paused).
    var sinkCounters: (@Sendable () -> (written: Int, queueFull: Int, paused: Int))?

    init() {}

    // MARK: - Control (any thread)

    /// Opens the listener for `camID` of the active session `sessionID` whose control connection came from `controlPeer`.
    /// Replaces a previous run. Returns the listener's port, nil when it could not be bound (nothing stays open).
    func open(sessionID: UInt32, camID: UInt16, controlPeer: String, keys: @escaping KeyProvider) -> UInt16? {
        queue.sync {
            if running { stopLocked(reason: "restart") }
            let bound: FilesListener
            var fallback = false
            do {
                bound = try FilesListener(port: Self.preferredPort, loopbackOnly: false, queue: queue) { [weak self] fd in
                    if let self { accepted(fd) } else { Darwin.close(fd) }
                }
            } catch {
                fallback = true
                do {
                    bound = try FilesListener(port: 0, loopbackOnly: false, queue: queue) { [weak self] fd in
                        if let self { accepted(fd) } else { Darwin.close(fd) }
                    }
                } catch {
                    logger.log(.error, "camera_listen", sessionID: sessionID, generation: camID,
                               fields: "state=failed error=\(error)")
                    return nil
                }
            }
            self.sessionID = sessionID
            self.camID = camID
            keyProvider = keys
            listener = bound
            machine = CameraConnectionMachine()
            gate = CameraStreamGate()
            epochBox.withLock { $0 = gate.epoch }
            connectionGeneration.withLock { $0 &+= 1 }
            decoder = H264CameraDecoder()
            activeID = nil
            running = true
            summaryTicks = 0
            framesIn = 0
            bytesIn = 0
            keyframeRequests = 0
            windowStartedUs = HostClock.nowUs()
            bound.start()
            logger.log(.info, "camera_listen", sessionID: sessionID, generation: camID,
                       fields: "state=listening port=\(bound.port) fallback=\(fallback ? 1 : 0)")
            run(machine.open(sessionID: sessionID, camID: camID, controlPeer: controlPeer))
            startTimer()
            return bound.port
        }
    }

    /// Closes the listener and every camera connection, the timer and the decoder. Idempotent.
    func close() {
        queue.sync { if running { stopLocked(reason: "stop") } }
    }

    var isRunning: Bool { queue.sync { running } }

    // MARK: - Lifecycle (on queue)

    private func stopLocked(reason: String) {
        run(machine.close(.sessionEnded))
        listener?.cancel()
        listener = nil
        timer?.cancel()
        timer = nil
        keyProvider = nil
        for conn in Array(conns.values) { conn.socket.closeNow() }
        for conn in Array(closing.values) { conn.socket.closeNow() }
        conns.removeAll()
        closing.removeAll()
        if activeID != nil {
            activeID = nil
            onActive?(false)
        }
        voidActiveWork()  // voids queued decode work
        let old = decoder
        decoder = nil
        decodeQueue.async { old?.invalidate() }
        running = false
        logger.log(.info, "camera_listen", sessionID: sessionID, generation: camID, fields: "state=stopped reason=\(reason)")
        sessionID = 0
        camID = 0
    }

    private func startTimer() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + .milliseconds(200), repeating: .milliseconds(200))
        t.setEventHandler { [weak self] in self?.tick() }
        timer = t
        t.activate()
    }

    private func tick() {
        guard running else { return }
        let now = HostClock.nowUs()
        run(machine.tick(now: now))
        if activeID != nil, let reason = gate.tick(now: now) { sendKeyframeRequest(reason) }
        summaryTicks += 1
        guard summaryTicks >= Self.summaryTicks else { return }
        summaryTicks = 0
        logSummary(now: now)
    }

    private func logSummary(now: UInt64) {
        let counters = gate.takeCounters()
        let sinkSide: (written: Int, queueFull: Int, paused: Int) = sinkCounters?() ?? (0, 0, 0)
        let seconds = max(0.001, Double(now &- windowStartedUs) / 1_000_000)
        windowStartedUs = now
        defer { framesIn = 0; bytesIn = 0; keyframeRequests = 0 }
        guard activeID != nil || framesIn > 0 else { return }
        let fps = String(format: "%.1f", Double(framesIn) / seconds)
        var fields = "frames_in=\(framesIn) bytes_in=\(bytesIn) decoded=\(counters.decoded) written=\(sinkSide.written)"
        fields += " dropped=\(counters.dropped) sink_full=\(sinkSide.queueFull) sink_paused=\(sinkSide.paused)"
        fields += " decode_errors=\(counters.decodeErrors) keyframe_requests=\(keyframeRequests) fps=\(fps)"
        logger.log(.info, "camera_stats", sessionID: sessionID, generation: camID, fields: fields)
    }

    // MARK: - Accept and input (on queue)

    private func accepted(_ fd: Int32) {
        var gaps: [String] = []
        let options = FilesSocketOptions(noDelay: true, keepAlive: true)
        guard running, FilesSockets.configure(fd, options, gaps: &gaps) else {
            Darwin.close(fd)
            return
        }
        let socket = FilesSocket(fd: fd, queue: queue, readChunk: 32 * 1024)
        nextConnID += 1
        let id = CameraConnID(nextConnID)
        let conn = Conn(id: id, socket: socket)
        conns[id] = conn
        socket.onData = { [weak self] bytes in self?.data(id, bytes) }
        socket.onClosed = { [weak self] in self?.socketClosed(id) }
        socket.start(readingPaused: false)
        run(machine.accepted(id, peer: socket.peerHost ?? "", now: HostClock.nowUs()))
    }

    private func data(_ id: CameraConnID, _ bytes: [UInt8]) {
        guard running, let conn = conns[id] else { return }
        if conn.decoder == nil {
            helloBytes(conn, bytes)
        } else {
            recordBytes(conn, bytes)
        }
    }

    /// Plain phase: exactly one `CAM_HELLO` (type 0x60) is valid; bytes behind the frame are records. With at most one
    /// connection that has not proven itself, the memory a peer can pin here is one payload limit.
    private func helloBytes(_ conn: Conn, _ bytes: [UInt8]) {
        let id = conn.id
        conn.helloBuffer += bytes
        let header = ProtocolConstants.headerSize
        guard conn.helloBuffer.count >= header else { return }
        guard conn.helloBuffer[0] == MessageType.camHello.rawValue else { return run(machine.protocolError(id)) }
        let length = (0..<4).reduce(UInt32(0)) { $0 | UInt32(conn.helloBuffer[1 + $1]) << (8 * UInt32($1)) }
        guard length <= UInt32(ProtocolConstants.maxControlPayload) else { return run(machine.protocolError(id)) }
        let total = header + Int(length)
        guard conn.helloBuffer.count >= total else { return }
        var plain = FrameDecoder(connection: .camera)
        var offset = 0
        while offset < total {  // `FrameDecoder` takes at most `maxReadChunk` bytes per call
            let end = min(total, offset + FrameDecoder.maxReadChunk)
            plain.append(Array(conn.helloBuffer[offset..<end]))
            offset = end
        }
        let rest = Array(conn.helloBuffer[total...])
        conn.helloBuffer = []
        guard let message = try? plain.nextMessage(), case .camHello(let hello) = message else {
            return run(machine.protocolError(id))
        }
        run(machine.hello(id, hello, now: HostClock.nowUs()))
        if !rest.isEmpty, conns[id]?.decoder != nil { recordBytes(conn, rest) }
    }

    private func recordBytes(_ conn: Conn, _ bytes: [UInt8]) {
        conn.decoder?.append(bytes)
        pumpRecords(conn)
    }

    /// Pulls records out of the decoder. A frame costs no more than the gate allows to wait (2), so reading never stops:
    /// stale frames are dropped, not buffered.
    private func pumpRecords(_ conn: Conn) {
        let id = conn.id
        while running, conns[id] === conn, conn.decoder != nil {
            let message: Message?
            do {
                message = try conn.decoder!.nextMessage()
            } catch is CryptoError {
                return run(machine.recordAuthFailed(id))
            } catch {
                return run(machine.protocolError(id))
            }
            guard let message else { return }
            var frame: CamFrame?
            if case .camFrame(let f) = message { frame = f }
            run(machine.record(id, message, now: HostClock.nowUs()), frame: frame)
        }
    }

    private func socketClosed(_ id: CameraConnID) {
        guard running else { return }
        if closing.removeValue(forKey: id) != nil { return }  // our own close finished
        guard conns.removeValue(forKey: id) != nil else { return }
        run(machine.connectionClosed(id))
        if id == activeID {
            activeID = nil
            voidActiveWork()
            onActive?(false)
        }
    }

    /// The active connection is gone or a new one starts: nothing queued for the old one may reach the decoder or the sink.
    private func voidActiveWork() {
        gate.reset()
        epochBox.withLock { $0 = gate.epoch }
        connectionGeneration.withLock { $0 &+= 1 }
        store.withLock { $0.clear() }
    }

    // MARK: - Frames (on queue)

    private func handle(_ frame: CamFrame) {
        framesIn += 1
        bytesIn += frame.data.count
        guard let decoder else { return }
        let now = HostClock.nowUs()
        let generation = connectionGeneration.withLock { $0 }
        if frame.isCodecConfig {
            _ = gate.codecConfig()  // voids the frames before it (new epoch)
            epochBox.withLock { $0 = gate.epoch }
            let work = ConfigWork(data: frame.data, generation: generation, decoder: decoder)
            if store.withLock({ $0.push(config: work) }) { scheduleDrain() }
            return
        }
        switch gate.frame(keyframe: frame.isKeyframe, now: now) {
        case .submit(let epoch):
            let work = FrameWork(data: frame.data, captureTimeUs: frame.captureTimeUs, epoch: epoch,
                                 generation: generation, decoder: decoder)
            if store.withLock({ $0.push(frame: work) }) { scheduleDrain() }
        case .dropAwaitingKeyframe:
            break
        case .overflow(let request):
            epochBox.withLock { $0 = gate.epoch }
            store.withLock { $0.clearFrames() }  // the gate voided them; free their data now
            logger.log(.debug, "camera_frame_drop", sessionID: sessionID, generation: camID, fields: "reason=queue_full")
            if let request { sendKeyframeRequest(request) }
        }
    }

    private func scheduleDrain() {
        decodeQueue.async { [weak self] in self?.drain() }
    }

    /// On `decodeQueue`: the only place the decoder is fed. Items of an older epoch or connection are skipped.
    private func drain() {
        let box = epochBox, generations = connectionGeneration, out = outQueue
        while let item = store.withLock({ $0.pop() }) {
            switch item {
            case .config(let c):
                guard generations.withLock({ $0 }) == c.generation else { continue }
                _ = c.decoder.configure(annexB: c.data)
            case .frame(let f):
                guard box.withLock({ $0 }) == f.epoch, generations.withLock({ $0 }) == f.generation else { continue }
                let epoch = f.epoch, generation = f.generation
                f.decoder.decode(annexB: f.data, captureTimeUs: f.captureTimeUs) { [weak self] result in
                    out.async { self?.decoded(result, epoch: epoch, generation: generation) }
                }
            }
        }
    }

    /// On `outQueue`: one decode result. The sink gets frames of the current epoch only.
    private func decoded(_ result: H264CameraDecoder.Result, epoch: UInt64, generation: UInt64) {
        switch result {
        case .frame(let image):
            // The generation is checked again right before the sink: scaling can outlast a STOP (T-357 r2).
            if epochBox.withLock({ $0 }) == epoch, connectionGeneration.withLock({ $0 }) == generation,
               let scaled = scaler.scaled(image.value), connectionGeneration.withLock({ $0 }) == generation {
                sink?(CameraPixelBuffer(scaled))
            }
            queue.async { [weak self] in self?.gate.finished(epoch: epoch, decoded: true) }
        case .noPicture:
            queue.async { [weak self] in self?.gate.finished(epoch: epoch, decoded: false) }
        case .failed(let status):
            queue.async { [weak self] in
                guard let self, running else { return }
                logger.log(.warning, "camera_decode_error", sessionID: sessionID, generation: camID, fields: "status=\(status)")
                let reason = gate.decodeFailed(epoch: epoch, now: HostClock.nowUs())
                epochBox.withLock { $0 = gate.epoch }
                store.withLock { $0.clearFrames() }
                if let reason { sendKeyframeRequest(reason) }
            }
        }
    }

    private func sendKeyframeRequest(_ reason: CamKeyframeReason) {
        guard let id = activeID, let conn = conns[id], conn.sealer != nil,
              let record = try? Message.camKeyframeRequest(reason).sealed(using: &conn.sealer!) else { return }
        keyframeRequests += 1
        conn.socket.write(record)
        logger.log(.debug, "camera_keyframe_request", sessionID: sessionID, generation: camID, fields: "reason=\(reason.rawValue)")
    }

    // MARK: - Machine actions (on queue)

    private func run(_ actions: [CameraAction], frame: CamFrame? = nil) {
        let activatedInBatch = actions.contains { if case .activated = $0 { true } else { false } }
        for action in actions {
            switch action {
            case .sendAck(let id, let ack):
                if let conn = conns[id], let bytes = try? Message.camHelloAck(ack).encode() { conn.socket.write(bytes) }
            case .startRecords(let id, let clientNonce, let hostNonce):
                guard let conn = conns[id] else { continue }
                guard let keys = keyProvider?(sessionID, clientNonce, hostNonce) else {
                    run(machine.keysUnavailable(id))
                    continue
                }
                conn.decoder = RecordDecoder(key: keys.c2h, connection: .camera)
                conn.sealer = RecordSealer(key: keys.h2c, maxPayload: ProtocolConstants.maxControlPayload)
            case .close(let id, let reason):
                guard let conn = conns.removeValue(forKey: id) else { continue }
                closing[id] = conn
                if id == activeID {
                    activeID = nil
                    voidActiveWork()  // same as socketClosed: no pending frame may restart the sink afterwards
                    if !activatedInBatch { onActive?(false) }
                }
                if reason == .rejected {  // the REJECTED ACK still goes out first
                    conn.socket.closeAfterFlush(timeout: Self.closeFlushSeconds)
                } else {
                    conn.socket.closeNow()
                }
            case .activated(let id):
                activeID = id
                voidActiveWork()
                onActive?(true)
                if let reason = gate.startupRequest(now: HostClock.nowUs()) { sendKeyframeRequest(reason) }
            case .frame:
                if let frame { handle(frame) }
            case .log(let level, let ev, let conn, let fields):
                let id = conn.map { "conn=\($0.raw) " } ?? ""
                logger.log(level, ev, sessionID: sessionID, generation: camID, fields: id + fields)
            }
        }
    }
}
