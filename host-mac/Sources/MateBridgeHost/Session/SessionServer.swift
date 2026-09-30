import Foundation
import MateBridgeCore
import Network

/// A validated video connection handed to the video pipeline (PROTOCOL.md section 3.5).
/// Every frame is one encrypted record under this connection's key (PROTOCOL.md section 9).
///
/// Send contract (PROTOCOL.md section 5, newest frame wins): at most `maxInFlight` (2) sends may be
/// outstanding. `send` returns false and transmits nothing when the limit is reached; the caller must then
/// drop or replace the frame and request a keyframe. `canSend` and `onReady` expose the same backpressure:
/// `onReady` fires (on the network queue) whenever an outstanding send completes.
/// `cancel()` closes just this connection.
public final class VideoLink: @unchecked Sendable {
    public static let maxInFlight = 2

    public let sessionID: UInt32
    public let configID: UInt16
    private let connection: NWConnection
    private let lock = NSLock()
    private let logger: SessionLogger
    private var inFlight = 0
    private var readyHandler: (@Sendable () -> Void)?
    private var sealer: RecordSealer

    fileprivate init(sessionID: UInt32, configID: UInt16, connection: NWConnection, logger: SessionLogger,
                     sealer: RecordSealer) {
        self.sealer = sealer
        self.logger = logger
        self.sessionID = sessionID
        self.configID = configID
        self.connection = connection
    }

    public var canSend: Bool {
        lock.lock()
        defer { lock.unlock() }
        return inFlight < Self.maxInFlight
    }

    public var onReady: (@Sendable () -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return readyHandler }
        set { lock.lock(); readyHandler = newValue; lock.unlock() }
    }

    /// Encodes and sends one frame. Returns false (nothing sent) while `maxInFlight` sends are outstanding
    /// or when the frame is not a valid single-fragment VIDEO_FRAME within the 16 MiB payload limit
    /// (logged). `completion(true)` means written.
    @discardableResult
    public func send(_ frame: VideoFrame, completion: @escaping @Sendable (Bool) -> Void = { _ in }) -> Bool {
        let message = Message.videoFrame(frame)
        // Sealing and the write happen under one lock: record counters must reach the wire in counter order.
        lock.lock()
        guard inFlight < Self.maxInFlight else { lock.unlock(); return false }
        let bytes: [UInt8]
        do {
            bytes = try message.sealed(using: &sealer)
        } catch let error as CryptoError {
            lock.unlock()
            logger.log(.error, "video_seal_failed", sessionID: sessionID, generation: configID,
                       fields: "reason=\(error == .counterExhausted ? "counter" : "crypto")")
            connection.cancel()  // the counter is exhausted: this connection cannot continue
            return false
        } catch {
            lock.unlock()
            logger.log(.warning, "video_frame_refused", sessionID: sessionID, generation: configID,
                       fields: "reason=invalid_or_oversized")
            return false
        }
        inFlight += 1
        connection.send(content: Data(bytes), completion: .contentProcessed { [self] error in
            lock.lock()
            inFlight -= 1
            let ready = readyHandler
            lock.unlock()
            completion(error == nil)
            ready?()
        })
        lock.unlock()
        return true
    }

    public func cancel() { connection.cancel() }
}

public enum SessionServerState: Equatable, Sendable {
    case stopped
    case starting
    case listening
    case awaitingApproval(deviceName: String)
    case connected(deviceName: String, transport: SessionTransport)
    case failed(String)
}

public struct ApprovalRequest: Sendable {
    /// Identifies the connection being asked about; pass it back to `resolveApproval`.
    public let id: UInt64
    public let deviceName: String
    /// The six-digit pairing code both screens show; the user compares them. Never log it.
    public let code: String
}

/// TCP control and video listeners plus Bonjour, driving a `SessionMachine`.
/// All state is confined to `queue`; handlers are invoked on that queue (hop to the main actor yourself).
public final class SessionServer: @unchecked Sendable {
    public struct Handlers: Sendable {
        public var stateChanged: @Sendable (SessionServerState) -> Void = { _ in }
        public var approvalRequested: @Sendable (ApprovalRequest) -> Void = { _ in }
        /// The request with this id is void (connection gone or superseded).
        public var approvalCancelled: @Sendable (_ id: UInt64) -> Void = { _ in }
        /// Input, STATS and KEYFRAME_REQUEST from the approved session.
        public var deliver: @Sendable (Message) -> Void = { _ in }
        /// Release every held key, button and pen contact. Idempotent; must be safe to call any time.
        public var releaseInput: @Sendable (ReleaseCause) -> Void = { _ in }
        public var sessionStarted: @Sendable (_ sessionID: UInt32, _ configID: UInt16) -> Void = { _, _ in }
        public var sessionEnded: @Sendable () -> Void = {}
        public var videoAttached: @Sendable (VideoLink) -> Void = { _ in }
        public init() {}
    }

    public static let bonjourType = "_matebridge._tcp"

    private let queue = DispatchQueue(label: "dev.matebridge.session")
    private let queueKey = DispatchSpecificKey<Bool>()
    private let handlers: Handlers
    private let store: ApprovedDeviceStore
    private let pairKeys: PairKeyStore
    private let requestedControlPort: UInt16
    private let requestedVideoPort: UInt16
    private let logger = SessionLogger()

    private var machine: SessionMachine
    private var knownDevices: [DeviceID: String]
    private var state: SessionServerState = .stopped
    private var controlListener: NWListener?
    private var videoListener: NWListener?
    private var nextID: UInt64 = 0
    private var controlConnections: [ConnectionID: NWConnection] = [:]
    /// Inbound decoder and outbound sealer of each control connection. Plain until the first HELLO_ACK went out.
    private var inbounds: [ConnectionID: ControlInbound] = [:]
    private var sealers: [ConnectionID: RecordSealer] = [:]
    private var videoConnections: [ConnectionID: NWConnection] = [:]
    private var pendingApproval: ConnectionID?
    private var tickTimer: DispatchSourceTimer?
    private var currentSessionID: UInt32 = 0
    private var currentConfigID: UInt16 = 0
    private var stopped = false
    private var activeTransport: SessionTransport = .network
    private var restartAttempts = 0
    private var restartScheduled = false
    private var inflightBytes: [ConnectionID: Int] = [:]
    private var videoBuffers: [ConnectionID: [UInt8]] = [:]
    private var videoHelloSeen: Set<ConnectionID> = []
    private var videoLinks: [ConnectionID: VideoLink] = [:]
    private let flushGroup = DispatchGroup()

    static let maxInflightBytes = 256 * 1024
    static let maxUnauthenticated = 4
    static let maxVideoHandshakePayload = 1024

    /// - Parameters:
    ///   - controlPort: preferred control port (default 47001, for `adb reverse`); falls back to a system-assigned
    ///     port when taken. 0 means system-assigned only.
    ///   - videoPort: same for the video listener (default 47002).
    ///   - makeStreamConfig: placeholder until the video pipeline (T-011) supplies the real configuration.
    public init(handlers: Handlers, store: ApprovedDeviceStore = ApprovedDeviceStore(directory: ApprovedDeviceStore.defaultDirectory()),
                pairKeys: PairKeyStore = KeychainPairKeyStore(),
                hostID: [UInt8] = HostIdentityStore(directory: ApprovedDeviceStore.defaultDirectory()).loadOrCreate(),
                hostName: String = Host.current().localizedName ?? "Mac", controlPort: UInt16 = DefaultPorts.control,
                videoPort: UInt16 = DefaultPorts.video,
                makeStreamConfig: @escaping @Sendable (Hello) -> StreamConfig = SessionServer.defaultStreamConfig) {
        self.handlers = handlers
        queue.setSpecific(key: queueKey, value: true)
        self.store = store
        self.pairKeys = pairKeys
        self.requestedControlPort = controlPort
        self.requestedVideoPort = videoPort
        let known = store.load()
        self.knownDevices = known
        self.machine = SessionMachine(configuration: .init(hostName: hostName, makeStreamConfig: makeStreamConfig,
                                                           hostID: hostID, pairKeys: pairKeys),
                                      approvedDevices: Set(known.keys))
    }

    /// Native-resolution H.264 config (HiDPI 2x points). T-011 replaces this with the real virtual display values.
    public static let defaultStreamConfig: @Sendable (Hello) -> StreamConfig = { hello in
        StreamConfig(configID: 1, codec: .h264, widthPx: hello.screenWidthPx, heightPx: hello.screenHeightPx,
                     widthPt: hello.screenWidthPx / 2, heightPt: hello.screenHeightPx / 2,
                     fps: min(hello.maxRefreshHz, 60), bitrateKbps: 40_000,
                     colorPrimaries: 1, transfer: 1, matrix: 1, fullRange: true)
    }

    // MARK: Lifecycle

    public func start() {
        queue.async { [self] in
            guard tickTimer == nil else { return }
            stopped = false
            setState(.starting)
            startListeners()
            startTicking()
        }
    }

    private func startListeners() {
        guard !stopped else { return }
        startVideoListener(plan: ListenerPortPlan(preferred: requestedVideoPort))
    }

    /// Tries the preferred video port, then a system-assigned one (logged).
    private func startVideoListener(plan: ListenerPortPlan) {
        guard !stopped else { return }
        var plan = plan
        guard let port = plan.nextPort() else { return listenersFailed("video_listener_create") }
        let fixed = plan.lastWasPreferred
        let nextPlan = plan
        do {
            let video = try NWListener(using: Self.tcpParameters(), on: Self.endpointPort(port))
            video.newConnectionHandler = { [weak self] c in self?.accept(c, video: true) }
            video.stateUpdateHandler = { [weak self, weak video] s in
                guard let self, let video, video === videoListener else { return }
                if case .failed = s, fixed {
                    logger.log(.warning, "port_fallback", sessionID: 0, generation: 0,
                               fields: "listener=video wanted=\(port)")
                    video.cancel()
                    videoListener = nil
                    return startVideoListener(plan: nextPlan)
                }
                videoListenerState(s)
            }
            videoListener = video
            video.start(queue: queue)
        } catch {
            if fixed {
                logger.log(.warning, "port_fallback", sessionID: 0, generation: 0,
                           fields: "listener=video wanted=\(port)")
                startVideoListener(plan: nextPlan)
            } else {
                listenersFailed("video_listener_create")
            }
        }
    }

    private func logFallback(_ listener: String, _ wanted: UInt16) {
        logger.log(.warning, "port_fallback", sessionID: 0, generation: 0,
                   fields: "listener=\(listener) wanted=\(wanted)")
    }

    private static func endpointPort(_ port: UInt16) -> NWEndpoint.Port {
        port == 0 ? .any : (NWEndpoint.Port(rawValue: port) ?? .any)
    }

    /// Cancels both listeners and retries with exponential backoff (1 s ... 30 s).
    /// Established sessions keep running; only new connections are affected meanwhile.
    private func listenersFailed(_ what: String) {
        fail(what)
        // A restart changes the video port that live clients hold, so end every session first
        // (release input, BYE SHUTTING_DOWN, close). Clients reconnect and learn the new port.
        apply(machine.shutdown())
        controlListener?.cancel()
        videoListener?.cancel()
        controlListener = nil
        videoListener = nil
        guard !stopped, !restartScheduled else { return }
        restartScheduled = true
        let delay = min(30.0, pow(2.0, Double(restartAttempts)))
        restartAttempts += 1
        queue.asyncAfter(deadline: .now() + delay) { [self] in
            restartScheduled = false
            guard !stopped else { return }
            logger.log(.info, "listener_restart", sessionID: currentSessionID, generation: currentConfigID,
                       fields: "attempt=\(restartAttempts)")
            startListeners()
        }
    }

    /// Releases input and sends BYE(SHUTTING_DOWN) to every peer. Delivery of the BYE is best effort:
    /// waits up to 200 ms for the sends to be processed, then returns regardless.
    /// Safe to call from any thread, including a handler running on the session queue: there it runs
    /// inline and does not wait for the BYE flush (nothing could complete while blocked on the queue).
    public func stop() {
        let onQueue = DispatchQueue.getSpecific(key: queueKey) == true
        let body = { [self] in
            stopped = true
            apply(machine.shutdown())
            tickTimer?.cancel()
            tickTimer = nil
            controlListener?.cancel()
            videoListener?.cancel()
            controlListener = nil
            videoListener = nil
            setState(.stopped)
        }
        if onQueue {
            body()
        } else {
            queue.sync(execute: body)
            _ = flushGroup.wait(timeout: .now() + .milliseconds(200))  // completions run on `queue`, so wait outside it
        }
    }

    /// Ends every session (release input, BYE SHUTTING_DOWN, close) but keeps listening, so clients reconnect.
    /// Used when the host cannot keep up with its own events.
    public func endSessions() {
        queue.async { [self] in
            guard !stopped else { return }
            logger.log(.warning, "sessions_ended_by_host", sessionID: currentSessionID, generation: currentConfigID)
            apply(machine.shutdown())
        }
    }

    /// Answers the approval request `id`. Ignored unless it is still the pending one.
    public func resolveApproval(id: UInt64, approved: Bool) {
        queue.async { [self] in
            guard let pending = pendingApproval, pending.raw == id else {
                logger.log(.info, "approval_stale_ignored", sessionID: currentSessionID,
                           generation: currentConfigID, fields: "conn=\(id)")
                return
            }
            pendingApproval = nil
            if approved {
                logger.log(.info, "approval_approved", sessionID: currentSessionID,
                           generation: currentConfigID, fields: "conn=\(id)")
            }
            apply(machine.approvalDecided(pending, approved: approved, now: nowUs()))
        }
    }

    /// Menu item "Onaylı cihazları unut": next connection asks for approval again.
    public func forgetApprovedDevices() {
        queue.async { [self] in
            machine.forgetApprovedDevices()
            knownDevices.removeAll()
            try? store.save(knownDevices)
            do { try pairKeys.removeAll() } catch {
                logger.log(.error, "pair_keys_remove_failed", sessionID: currentSessionID, generation: currentConfigID,
                           fields: "error=\(error)")
            }
            logger.log(.info, "devices_forgotten", sessionID: currentSessionID, generation: currentConfigID)
        }
    }

    // MARK: Listeners

    private static func tcpParameters() -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        return NWParameters(tls: nil, tcp: tcp)
    }

    private func videoListenerState(_ s: NWListener.State) {
        switch s {
        case .ready:
            guard let port = videoListener?.port?.rawValue else { return fail("video_port_missing") }
            machine.videoPort = port
            startControlListener(videoPort: port)
        case .failed:
            listenersFailed("video_listener_failed")
        default: break
        }
    }

    private func startControlListener(videoPort: UInt16) {
        guard controlListener == nil else { return }
        startControlListener(videoPort: videoPort, plan: ListenerPortPlan(preferred: requestedControlPort))
    }

    /// Tries the preferred control port, then a system-assigned one (logged).
    private func startControlListener(videoPort: UInt16, plan: ListenerPortPlan) {
        guard !stopped else { return }
        var plan = plan
        guard let port = plan.nextPort() else { return listenersFailed("control_listener_create") }
        let fixed = plan.lastWasPreferred
        let nextPlan = plan
        do {
            let listener = try NWListener(using: Self.tcpParameters(), on: Self.endpointPort(port))
            listener.service = NWListener.Service(name: machine.configuration.hostName, type: Self.bonjourType,
                                                  domain: nil, txtRecord: NWTXTRecord(["v": "1"]))
            listener.newConnectionHandler = { [weak self] c in self?.accept(c, video: false) }
            listener.stateUpdateHandler = { [weak self, weak listener] s in
                guard let self, let listener, listener === controlListener else { return }
                switch s {
                case .ready:
                    restartAttempts = 0
                    logger.log(.info, "listening", sessionID: 0, generation: 0,
                               fields: "control_port=\(listener.port?.rawValue ?? 0) video_port=\(videoPort)")
                    if case .starting = state { setState(.listening) }
                case .failed:
                    if fixed {
                        logFallback("control", port)
                        listener.cancel()
                        controlListener = nil
                        startControlListener(videoPort: videoPort, plan: nextPlan)
                    } else {
                        listenersFailed("control_listener_failed")
                    }
                default: break
                }
            }
            controlListener = listener
            listener.start(queue: queue)
        } catch {
            if fixed {
                logFallback("control", port)
                startControlListener(videoPort: videoPort, plan: nextPlan)
            } else {
                listenersFailed("control_listener_create")
            }
        }
    }

    private func fail(_ what: String) {
        logger.log(.error, what, sessionID: 0, generation: 0)
        setState(.failed(what))
    }

    // MARK: Connections

    private func accept(_ connection: NWConnection, video: Bool) {
        // Bounded: refuse new connections while too many have not yet authenticated (HELLO / VIDEO_HELLO).
        let unauthenticated = video ? machine.pendingVideoCount : machine.awaitingHelloCount
        guard unauthenticated < Self.maxUnauthenticated else {
            logger.log(.warning, "connection_refused", sessionID: currentSessionID, generation: currentConfigID,
                       fields: "video=\(video) reason=too_many_unauthenticated")
            connection.cancel()
            return
        }
        nextID += 1
        let id = ConnectionID(nextID)
        connection.stateUpdateHandler = { [weak self] s in
            switch s {
            case .failed, .cancelled: self?.transportClosed(id, video: video)
            default: break
            }
        }
        connection.start(queue: queue)
        if video {
            videoConnections[id] = connection
            apply(machine.videoOpened(id, now: nowUs()))
        } else {
            controlConnections[id] = connection
            inbounds[id] = ControlInbound()
            apply(machine.connectionOpened(id, now: nowUs()))
        }
        receiveLoop(id, connection, video: video)
    }

    private func receiveLoop(_ id: ConnectionID, _ connection: NWConnection, video: Bool) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: FrameDecoder.maxReadChunk) {
            [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                if video {
                    guard receiveVideoBytes(id, [UInt8](data)) else { return }
                } else {
                    guard receiveControlBytes(id, [UInt8](data)) else { return }
                }
            }
            let stillOpen = video ? videoConnections[id] != nil : controlConnections[id] != nil
            if isComplete || error != nil || !stillOpen {
                transportClosed(id, video: video)
            } else {
                receiveLoop(id, connection, video: video)
            }
        }
    }

    /// Control connection input: plain frames until the handshake answer went out, encrypted records afterwards.
    /// Returns false when the connection was closed.
    private func receiveControlBytes(_ id: ConnectionID, _ bytes: [UInt8]) -> Bool {
        guard inbounds[id] != nil else { return false }
        inbounds[id]!.append(bytes)
        do {
            while let message = try inbounds[id]?.nextMessage() {
                if case .hello = message, inbounds[id]?.bufferedPlaintextCount != 0 {
                    // Bytes behind HELLO would be read as plaintext: a client sends nothing before HELLO_ACK.
                    throw ProtocolError.invalidField("bytes after HELLO")
                }
                apply(machine.received(id, message, now: nowUs()))
                if inbounds[id] == nil { return false }  // the message ended this connection
            }
        } catch let error as CryptoError {
            let counter = inbounds[id]?.recordCounter ?? 0
            // Failed authentication or an invalid record length: no BYE, but the release-all path is the same.
            logger.log(.warning, "record_auth_failed", sessionID: currentSessionID, generation: currentConfigID,
                       fields: "conn=\(id.raw) reason=\(Self.describe(error))")
            apply(machine.recordAuthFailed(id, counter: counter))
            return false
        } catch {
            logger.log(.warning, "decode_error", sessionID: currentSessionID,
                       generation: currentConfigID, fields: "video=false")
            apply(machine.protocolError(id))
            return false
        }
        return true
    }

    private static func describe(_ error: CryptoError) -> String {
        switch error {
        case .authenticationFailed: "tag"
        case .invalidRecordLength: "length"
        case .counterExhausted: "counter"
        default: "other"
        }
    }

    /// Video connection input: only one VIDEO_HELLO (type 0x40, payload at most 1 KiB) is valid C->H.
    /// Hand-parsed so an unauthenticated peer can never make us buffer the 16 MiB video payload limit.
    /// Returns false when the connection was closed.
    private func receiveVideoBytes(_ id: ConnectionID, _ bytes: [UInt8]) -> Bool {
        func reject() -> Bool {
            logger.log(.warning, "video_hello_invalid", sessionID: currentSessionID, generation: currentConfigID)
            closeVideo(id)
            return false
        }
        guard !videoHelloSeen.contains(id) else { return reject() }
        var buffer = videoBuffers[id, default: []]
        buffer += bytes
        var length = 0
        if buffer.count >= ProtocolConstants.headerSize {
            guard buffer[0] == MessageType.videoHello.rawValue else { return reject() }
            let l = (0..<4).reduce(UInt32(0)) { $0 | UInt32(buffer[1 + $1]) << (8 * UInt32($1)) }
            guard l <= UInt32(Self.maxVideoHandshakePayload) else { return reject() }
            length = Int(l)
            let total = ProtocolConstants.headerSize + length
            if buffer.count >= total {
                guard buffer.count == total else { return reject() }
                var d = FrameDecoder(connection: .video)
                d.append(buffer)
                guard case .videoHello(let hello)? = try? d.nextMessage() else { return reject() }
                videoBuffers[id] = nil
                videoHelloSeen.insert(id)
                apply(machine.videoHello(id, hello, now: nowUs()))
                return true
            }
        }
        videoBuffers[id] = buffer
        return true
    }

    /// The transport is gone (peer closed, error, or we cancelled it). Idempotent; always cancels the socket.
    private func transportClosed(_ id: ConnectionID, video: Bool) {
        if video {
            guard let c = videoConnections.removeValue(forKey: id) else { return }
            c.cancel()
            videoLinks[id] = nil
            videoBuffers[id] = nil
            videoHelloSeen.remove(id)
            apply(machine.videoClosed(id))
        } else {
            guard let c = controlConnections.removeValue(forKey: id) else { return }
            c.cancel()
            inflightBytes[id] = nil
            inbounds[id] = nil
            sealers[id] = nil
            apply(machine.connectionClosed(id))
        }
    }

    private func closeVideo(_ id: ConnectionID) {
        transportClosed(id, video: true)
    }

    private func closeControl(_ id: ConnectionID) {
        guard let c = controlConnections.removeValue(forKey: id) else { return }
        inflightBytes[id] = nil
        inbounds[id] = nil
        sealers[id] = nil
        // Queued sends (BYE, REJECTED) are flushed before the FIN, then the socket is cancelled.
        flushGroup.enter()
        c.send(content: nil, contentContext: .finalMessage, isComplete: true,
               completion: .contentProcessed { [flushGroup] _ in
                   c.cancel()
                   flushGroup.leave()
               })
    }

    /// Encodes plain before the handshake answer, as a sealed record after it.
    private func sendControl(_ id: ConnectionID, _ message: Message) {
        guard controlConnections[id] != nil else { return }
        let bytes: [UInt8]
        do {
            if sealers[id] != nil {
                bytes = try message.sealed(using: &sealers[id]!)
            } else {
                bytes = try message.encode()
            }
        } catch {
            if case CryptoError.counterExhausted = error {
                logger.log(.warning, "counter_exhausted", sessionID: currentSessionID, generation: currentConfigID)
                transportClosed(id, video: false)
            }
            return
        }
        sendControlBytes(id, bytes)
    }

    private func sendControlBytes(_ id: ConnectionID, _ bytes: [UInt8]) {
        guard let c = controlConnections[id] else { return }
        let pending = inflightBytes[id, default: 0] + bytes.count
        guard pending <= Self.maxInflightBytes else {
            // The peer is not reading. Drop the connection: input is released via connectionClosed.
            logger.log(.warning, "send_backlog", sessionID: currentSessionID, generation: currentConfigID)
            transportClosed(id, video: false)
            return
        }
        inflightBytes[id] = pending
        c.send(content: Data(bytes), completion: .contentProcessed { [weak self] _ in
            guard let self, let n = inflightBytes[id] else { return }
            inflightBytes[id] = max(0, n - bytes.count)
        })
    }

    // MARK: Applying machine actions

    private func apply(_ actions: [SessionAction]) {
        // Safety net: if switching a connection to encrypted records fails (plaintext left behind HELLO, which
        // `receiveControlBytes` already rules out), nothing more is announced for it and it is closed after the loop.
        var brokenHandshake: ConnectionID?
        defer { if let id = brokenHandshake { apply(machine.protocolError(id)) } }
        for action in actions {
            if let broken = brokenHandshake {
                switch action {
                case .sessionStarted(broken, _, _, _), .send(broken, _), .startEncryption(broken, _): continue
                default: break
                }
            }
            switch action {
            case .send(let id, let message):
                sendControl(id, message)
            case .startEncryption(let id, let keys):
                sealers[id] = RecordSealer(key: keys.h2c, maxPayload: ProtocolConstants.maxControlPayload)
                do { try inbounds[id]?.enableEncryption(key: keys.c2h) } catch {
                    logger.log(.warning, "decode_error", sessionID: currentSessionID, generation: currentConfigID,
                               fields: "video=false reason=plaintext_after_hello")
                    brokenHandshake = id
                }
            case .close(let id):
                closeControl(id)
            case .closeVideo(let id):
                closeVideo(id)
            case .releaseInput(_, let cause):
                handlers.releaseInput(cause)
            case .deliver(_, let message):
                handlers.deliver(message)
            case .requestApproval(let id, _, let name, let code):
                pendingApproval = id
                handlers.approvalRequested(ApprovalRequest(id: id.raw, deviceName: name, code: code.digits))
            case .cancelApproval(let id):
                if pendingApproval == id {
                    pendingApproval = nil
                    handlers.approvalCancelled(id.raw)
                }
            case .persistPairing(let conn, let device, let name, let key):
                // Key first (Keychain), then the device list; ACCEPTED goes out only when both are stored.
                var stored = true
                do { try pairKeys.save(key, for: device) } catch {
                    stored = false
                    logger.log(.error, "pair_key_save_failed", sessionID: currentSessionID,
                               generation: currentConfigID, fields: "error=\(error)")
                }
                if stored {
                    knownDevices[device] = name
                    do { try store.save(knownDevices) } catch {
                        stored = false
                        knownDevices[device] = nil
                        try? pairKeys.remove(device)
                        logger.log(.error, "store_save_failed", sessionID: currentSessionID,
                                   generation: currentConfigID)
                    }
                }
                apply(machine.pairingPersisted(conn, stored: stored, now: nowUs()))
            case .sessionStarted(let id, let sid, let configID, _):
                activeTransport = Self.transport(of: controlConnections[id])
                currentSessionID = sid
                currentConfigID = configID
                handlers.sessionStarted(sid, configID)
            case .sessionEnded:
                currentSessionID = 0
                currentConfigID = 0
                handlers.sessionEnded()
            case .videoAttached(let vid, _, let sid, let configID, let keys):
                if let c = videoConnections[vid] {
                    let sealer = RecordSealer(key: keys.h2c, maxPayload: ProtocolConstants.maxVideoPayload)
                    let link = VideoLink(sessionID: sid, configID: configID, connection: c, logger: logger,
                                         sealer: sealer)
                    videoLinks[vid] = link
                    handlers.videoAttached(link)
                }
            case .log(let level, let ev, let conn, let fields):
                let extra = conn.map { "conn=\($0.raw)" } ?? ""
                logger.log(level, ev, sessionID: currentSessionID, generation: currentConfigID,
                           fields: [extra, fields].filter { !$0.isEmpty }.joined(separator: " "))
            }
        }
        refreshState()
    }

    /// Loopback peer means the tablet came through `adb reverse` (USB mode).
    private static func transport(of connection: NWConnection?) -> SessionTransport {
        guard let connection, case .hostPort(let host, _) = connection.endpoint else { return .network }
        return SessionTransport.classify(peerHost: "\(host)")
    }

    private func refreshState() {
        switch machine.status {
        case .idle:
            switch state {
            case .awaitingApproval, .connected: setState(.listening)
            default: break
            }
        case .pending(let name): setState(.awaitingApproval(deviceName: name))
        case .active(let name, _): setState(.connected(deviceName: name, transport: activeTransport))
        }
    }

    private func setState(_ new: SessionServerState) {
        guard new != state else { return }
        state = new
        handlers.stateChanged(new)
    }

    // MARK: Time

    /// Host clock shared with `VIDEO_FRAME.capture_time_us` (PROTOCOL.md section 6).
    private func nowUs() -> UInt64 { HostClock.nowUs() }

    private func startTicking() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .milliseconds(100), repeating: .milliseconds(100))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            apply(machine.tick(now: nowUs()))
        }
        timer.resume()
        tickTimer = timer
    }
}

extension VideoLink: VideoTransport {
    public func setReadyHandler(_ handler: (@Sendable () -> Void)?) { onReady = handler }
}
