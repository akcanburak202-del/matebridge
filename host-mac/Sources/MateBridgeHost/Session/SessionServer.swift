import Foundation
import MateBridgeCore
import Network

/// A validated video connection handed to the video pipeline (PROTOCOL.md section 3.5).
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

    fileprivate init(sessionID: UInt32, configID: UInt16, connection: NWConnection, logger: SessionLogger) {
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
        guard let bytes = try? Message.videoFrame(frame).encode() else {
            logger.log(.warning, "video_frame_refused", sessionID: sessionID, generation: configID,
                       fields: "reason=invalid_or_oversized")
            return false
        }
        lock.lock()
        guard inFlight < Self.maxInFlight else { lock.unlock(); return false }
        inFlight += 1
        lock.unlock()
        connection.send(content: Data(bytes), completion: .contentProcessed { [self] error in
            lock.lock()
            inFlight -= 1
            let ready = readyHandler
            lock.unlock()
            completion(error == nil)
            ready?()
        })
        return true
    }

    public func cancel() { connection.cancel() }
}

public enum SessionServerState: Equatable, Sendable {
    case stopped
    case starting
    case listening
    case awaitingApproval(deviceName: String)
    case connected(deviceName: String)
    case failed(String)
}

public struct ApprovalRequest: Sendable {
    /// Identifies the connection being asked about; pass it back to `resolveApproval`.
    public let id: UInt64
    public let deviceName: String
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
    private let requestedControlPort: UInt16
    private let logger = SessionLogger()

    private var machine: SessionMachine
    private var knownDevices: [DeviceID: String]
    private var state: SessionServerState = .stopped
    private var controlListener: NWListener?
    private var videoListener: NWListener?
    private var nextID: UInt64 = 0
    private var controlConnections: [ConnectionID: NWConnection] = [:]
    private var videoConnections: [ConnectionID: NWConnection] = [:]
    private var pendingApproval: ConnectionID?
    private var tickTimer: DispatchSourceTimer?
    private var currentSessionID: UInt32 = 0
    private var currentConfigID: UInt16 = 0
    private var stopped = false
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
    ///   - controlPort: 0 lets the system pick (found via Bonjour). A fixed port is needed for `adb reverse`.
    ///   - makeStreamConfig: placeholder until the video pipeline (T-011) supplies the real configuration.
    public init(handlers: Handlers, store: ApprovedDeviceStore = ApprovedDeviceStore(directory: ApprovedDeviceStore.defaultDirectory()),
                hostName: String = Host.current().localizedName ?? "Mac", controlPort: UInt16 = 0,
                makeStreamConfig: @escaping @Sendable (Hello) -> StreamConfig = SessionServer.defaultStreamConfig) {
        self.handlers = handlers
        queue.setSpecific(key: queueKey, value: true)
        self.store = store
        self.requestedControlPort = controlPort
        let known = store.load()
        self.knownDevices = known
        self.machine = SessionMachine(configuration: .init(hostName: hostName, makeStreamConfig: makeStreamConfig),
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
        do {
            let video = try NWListener(using: Self.tcpParameters())
            video.newConnectionHandler = { [weak self] c in self?.accept(c, video: true) }
            video.stateUpdateHandler = { [weak self, weak video] s in
                guard let self, let video, video === videoListener else { return }
                videoListenerState(s)
            }
            videoListener = video
            video.start(queue: queue)
        } catch {
            listenersFailed("video_listener_create")
        }
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

    /// Answers the approval request `id`. Ignored unless it is still the pending one.
    public func resolveApproval(id: UInt64, approved: Bool) {
        queue.async { [self] in
            guard let pending = pendingApproval, pending.raw == id else { return }
            pendingApproval = nil
            apply(machine.approvalDecided(pending, approved: approved, now: nowUs()))
        }
    }

    /// Menu item "Onaylı cihazları unut": next connection asks for approval again.
    public func forgetApprovedDevices() {
        queue.async { [self] in
            machine.forgetApprovedDevices()
            knownDevices.removeAll()
            try? store.save(knownDevices)
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
        do {
            let port = requestedControlPort == 0 ? NWEndpoint.Port.any : NWEndpoint.Port(rawValue: requestedControlPort)!
            let listener = try NWListener(using: Self.tcpParameters(), on: port)
            listener.service = NWListener.Service(name: machine.configuration.hostName, type: Self.bonjourType,
                                                  domain: nil, txtRecord: NWTXTRecord(["v": "0"]))
            listener.newConnectionHandler = { [weak self] c in self?.accept(c, video: false) }
            listener.stateUpdateHandler = { [weak self, weak listener] s in
                guard let self, let listener, listener === controlListener else { return }
                switch s {
                case .ready:
                    restartAttempts = 0
                    logger.log(.info, "listening", sessionID: 0, generation: 0,
                               fields: "control_port=\(listener.port?.rawValue ?? 0) video_port=\(videoPort)")
                    if case .starting = state { setState(.listening) }
                case .failed: listenersFailed("control_listener_failed")
                default: break
                }
            }
            controlListener = listener
            listener.start(queue: queue)
        } catch {
            listenersFailed("control_listener_create")
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
            apply(machine.connectionOpened(id, now: nowUs()))
        }
        receiveLoop(id, connection, decoder: FrameDecoder(connection: video ? .video : .control), video: video)
    }

    private func receiveLoop(_ id: ConnectionID, _ connection: NWConnection, decoder: FrameDecoder, video: Bool) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: FrameDecoder.maxReadChunk) {
            [weak self] data, _, isComplete, error in
            guard let self else { return }
            var decoder = decoder
            if let data, !data.isEmpty {
                if video {
                    guard receiveVideoBytes(id, [UInt8](data)) else { return }
                } else {
                    decoder.append([UInt8](data))
                    do {
                        while let message = try decoder.nextMessage() {
                            apply(machine.received(id, message, now: nowUs()))
                        }
                    } catch {
                        logger.log(.warning, "decode_error", sessionID: currentSessionID,
                                   generation: currentConfigID, fields: "video=false")
                        apply(machine.protocolError(id))
                        return
                    }
                }
            }
            let stillOpen = video ? videoConnections[id] != nil : controlConnections[id] != nil
            if isComplete || error != nil || !stillOpen {
                transportClosed(id, video: video)
            } else {
                receiveLoop(id, connection, decoder: decoder, video: video)
            }
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
            apply(machine.connectionClosed(id))
        }
    }

    private func closeVideo(_ id: ConnectionID) {
        transportClosed(id, video: true)
    }

    private func closeControl(_ id: ConnectionID) {
        guard let c = controlConnections.removeValue(forKey: id) else { return }
        inflightBytes[id] = nil
        // Queued sends (BYE, REJECTED) are flushed before the FIN, then the socket is cancelled.
        flushGroup.enter()
        c.send(content: nil, contentContext: .finalMessage, isComplete: true,
               completion: .contentProcessed { [flushGroup] _ in
                   c.cancel()
                   flushGroup.leave()
               })
    }

    private func sendControl(_ id: ConnectionID, _ bytes: [UInt8]) {
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
        for action in actions {
            switch action {
            case .send(let id, let message):
                guard let bytes = try? message.encode() else { break }
                sendControl(id, bytes)
            case .close(let id):
                closeControl(id)
            case .closeVideo(let id):
                closeVideo(id)
            case .releaseInput(_, let cause):
                handlers.releaseInput(cause)
            case .deliver(_, let message):
                handlers.deliver(message)
            case .requestApproval(let id, _, let name):
                pendingApproval = id
                handlers.approvalRequested(ApprovalRequest(id: id.raw, deviceName: name))
            case .cancelApproval(let id):
                if pendingApproval == id {
                    pendingApproval = nil
                    handlers.approvalCancelled(id.raw)
                }
            case .rememberDevice(let id, let name):
                knownDevices[id] = name
                do { try store.save(knownDevices) } catch {
                    logger.log(.error, "store_save_failed", sessionID: currentSessionID, generation: currentConfigID)
                }
            case .sessionStarted(_, let sid, let configID, _):
                currentSessionID = sid
                currentConfigID = configID
                handlers.sessionStarted(sid, configID)
            case .sessionEnded:
                currentSessionID = 0
                currentConfigID = 0
                handlers.sessionEnded()
            case .videoAttached(let vid, _, let sid, let configID):
                if let c = videoConnections[vid] {
                    let link = VideoLink(sessionID: sid, configID: configID, connection: c, logger: logger)
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

    private func refreshState() {
        switch machine.status {
        case .idle:
            switch state {
            case .awaitingApproval, .connected: setState(.listening)
            default: break
            }
        case .pending(let name): setState(.awaitingApproval(deviceName: name))
        case .active(let name, _): setState(.connected(deviceName: name))
        }
    }

    private func setState(_ new: SessionServerState) {
        guard new != state else { return }
        state = new
        handlers.stateChanged(new)
    }

    // MARK: Time

    private func nowUs() -> UInt64 { DispatchTime.now().uptimeNanoseconds / 1000 }

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
