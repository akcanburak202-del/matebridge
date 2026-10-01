import Foundation
import MateBridgeCore
import Network

/// A validated video connection handed to the video pipeline (PROTOCOL.md section 3.5).
/// Every frame is one encrypted record under this connection's key (PROTOCOL.md section 9).
///
/// Send contract (PROTOCOL.md section 5, newest frame wins): `send` returns false and transmits nothing while the link
/// cannot take a frame; the caller must then drop or replace the frame and request a keyframe. `canSend` and
/// `onReady` expose the same backpressure: `onReady` fires whenever that may have changed.
/// - `nw` (Network.framework): at most `maxInFlight` (2) sends may be outstanding; `onReady` fires on the network queue
///   whenever an outstanding send completes.
/// - `bsd` (kernel socket, T-091): at most one record may still be in user space and the kernel must hold fewer unsent
///   bytes than `TCP_NOTSENT_LOWAT` (`SocketVideoGate`); `onReady` fires on the socket's write queue.
/// `cancel()` closes just this connection.
public final class VideoLink: @unchecked Sendable {
    public static let maxInFlight = 2

    public let sessionID: UInt32
    public let configID: UInt16
    private let wire: Wire
    private let lock = NSLock()
    private let logger: SessionLogger
    // `nw` only: the `bsd` transport keeps its own count and sealer. One sealer per connection key, never a copy:
    // two sealers on one key would reuse nonces.
    private var inFlight = 0
    private var readyHandler: (@Sendable () -> Void)?
    private var sealer: RecordSealer?
    /// Kernel send-queue sampling (T-088), only with `MATEBRIDGE_SENDQ_LOG=1` or `MATEBRIDGE_LAT_TRACE=1`.
    private let sendQueue: SendQueueSampler?

    private enum Wire {
        case network(NWConnection)
        case socket(SocketVideoTransport)
    }

    fileprivate init(sessionID: UInt32, configID: UInt16, connection: NWConnection, logger: SessionLogger,
                     sealer: RecordSealer, sampleSendQueue: Bool) {
        self.sealer = sealer
        self.sendQueue = sampleSendQueue ? SendQueueSampler(connection: connection) : nil
        self.logger = logger
        self.sessionID = sessionID
        self.configID = configID
        self.wire = .network(connection)
    }

    fileprivate init(sessionID: UInt32, configID: UInt16, socket: BsdTcpConnection, logger: SessionLogger,
                     sealer: RecordSealer, sampleSendQueue: Bool) {
        self.sealer = nil  // the transport owns this connection's sealer
        self.sendQueue = sampleSendQueue ? SendQueueSampler(socket: socket) : nil
        self.logger = logger
        self.sessionID = sessionID
        self.configID = configID
        self.wire = .socket(SocketVideoTransport(connection: socket, sealer: sealer))
    }

    public var canSend: Bool {
        switch wire {
        case .network:
            lock.lock()
            defer { lock.unlock() }
            return inFlight < Self.maxInFlight
        case .socket(let transport):
            return transport.canSend
        }
    }

    public var onReady: (@Sendable () -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return readyHandler }
        set {
            lock.lock(); readyHandler = newValue; lock.unlock()
            if case .socket(let transport) = wire { transport.setReadyHandler(newValue) }
        }
    }

    /// Encodes and sends one frame. Returns false (nothing sent) while the link cannot take a frame (see above)
    /// or when the frame is not a valid single-fragment VIDEO_FRAME within the 16 MiB payload limit
    /// (logged). `completion(true)` means written.
    @discardableResult
    public func send(_ frame: VideoFrame, completion: @escaping @Sendable (Bool) -> Void = { _ in }) -> Bool {
        switch wire {
        case .network(let connection): return send(frame, over: connection, completion: completion)
        case .socket(let transport): return send(frame, over: transport, completion: completion)
        }
    }

    private func send(_ frame: VideoFrame, over transport: SocketVideoTransport,
                      completion: @escaping @Sendable (Bool) -> Void) -> Bool {
        // The backlog this frame will queue behind (T-088); taken before the write, like the `nw` path.
        if let sendQueue, transport.canSend { sendQueue.sample() }
        switch transport.sendFrame(frame, completion: completion) {
        case .sent:
            return true
        case .busy:
            return false
        case .invalid:
            logger.log(.warning, "video_frame_refused", sessionID: sessionID, generation: configID,
                       fields: "reason=invalid_or_oversized")
            return false
        case .sealFailed(let error):
            logger.log(.error, "video_seal_failed", sessionID: sessionID, generation: configID,
                       fields: "reason=\(error == .counterExhausted ? "counter" : "crypto")")
            transport.connection.cancel()  // the counter is exhausted: this connection cannot continue
            return false
        }
    }

    private func send(_ frame: VideoFrame, over connection: NWConnection,
                      completion: @escaping @Sendable (Bool) -> Void) -> Bool {
        let message = Message.videoFrame(frame)
        // The backlog this frame will queue behind (T-088). Outside `lock`: the probe may query the NWConnection,
        // whose queue runs the send completions that take `lock`.
        if let sendQueue, canSend { sendQueue.sample() }
        // Sealing and the write happen under one lock: record counters must reach the wire in counter order.
        lock.lock()
        guard inFlight < Self.maxInFlight, sealer != nil else { lock.unlock(); return false }
        let bytes: [UInt8]
        do {
            bytes = try message.sealed(using: &sealer!)
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

    public func cancel() {
        switch wire {
        case .network(let connection): connection.cancel()
        case .socket(let transport): transport.connection.cancel()
        }
    }

    /// Closes the send-queue window (about once a second). nil when sampling is off or there is nothing to report.
    func sendQueueReport() -> SendQueueSampler.Report? { sendQueue?.take() }
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
        /// The tablet of this request left; keep the window open and say so ("Allow" then pre-approves the device).
        public var approvalOrphaned: @Sendable (_ id: UInt64) -> Void = { _ in }
        /// "Allow" could not be stored because the Keychain queue is full: show the request again with the notice
        /// "Anahtar Zinciri meşgul, tekrar dene" (the answer is still open).
        public var approvalKeychainBusy: @Sendable (ApprovalRequest) -> Void = { _ in }
        /// Input, STATS and KEYFRAME_REQUEST from the approved session.
        public var deliver: @Sendable (Message) -> Void = { _ in }
        /// Release every held key, button and pen contact. Idempotent; must be safe to call any time.
        public var releaseInput: @Sendable (ReleaseCause) -> Void = { _ in }
        /// `transport`: how the session's control connection arrived (loopback = USB via `adb reverse`, T-088).
        public var sessionStarted: @Sendable (_ sessionID: UInt32, _ configID: UInt16, _ hello: Hello,
                                              _ transport: SessionTransport) -> Void = { _, _, _, _ in }
        public var sessionEnded: @Sendable () -> Void = {}
        public var videoAttached: @Sendable (VideoLink) -> Void = { _ in }
        public init() {}
    }

    public static let bonjourType = "_matebridge._tcp"

    private let queue = DispatchQueue(label: "dev.matebridge.session")
    private let queueKey = DispatchSpecificKey<Bool>()
    private let handlers: Handlers
    private let store: ApprovedDeviceStore
    /// Every Keychain access goes through this one serial queue, asynchronously (PairKeyService).
    private let pairKeys: PairKeyService
    private let identity: HostIdentityStore.Identity
    private let requestedControlPort: UInt16
    private let requestedVideoPort: UInt16
    private let logger = SessionLogger()

    private var machine: SessionMachine
    private var knownDevices: [DeviceID: String]
    private var state: SessionServerState = .stopped
    private var controlListener: NWListener?
    private var videoListener: VideoListener?
    private var nextID: UInt64 = 0
    private var controlConnections: [ConnectionID: NWConnection] = [:]
    /// Inbound decoder and outbound sealer of each control connection. Plain until the first HELLO_ACK went out.
    private var inbounds: [ConnectionID: ControlInbound] = [:]
    private var sealers: [ConnectionID: RecordSealer] = [:]
    private var videoConnections: [ConnectionID: VideoConnection] = [:]
    private var pendingApproval: ConnectionID?
    private var pendingRequest: ApprovalRequest?
    /// Incremented by every "forget" (and identity replacement). A Keychain save that completes under an older value
    /// was revoked meanwhile: its result is discarded and the key it stored is deleted (compare-and-delete).
    private var revocationGeneration = 0
    /// Control connections whose pair-key lookup is in flight; read from the Keychain queue to skip stale jobs.
    private let liveLookups = LockedSet<ConnectionID>()
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
    /// Video connections whose VIDEO_HELLO passed and that now owe one authenticated PING (PROTOCOL.md 3.5).
    private var videoProofDecoders: [ConnectionID: RecordDecoder] = [:]
    private var videoLinks: [ConnectionID: VideoLink] = [:]
    private let flushGroup = DispatchGroup()

    static let maxInflightBytes = 256 * 1024
    static let maxUnauthenticated = 4
    static let maxVideoHandshakePayload = 1024
    /// T-088 experiment knobs, read once.
    static let serviceClass = ServiceClassKnob.parse(ProcessInfo.processInfo.environment)
    static let sampleSendQueue = SendQueueLogKnob.isEnabled(ProcessInfo.processInfo.environment)
    /// T-091: `MATEBRIDGE_VIDEO_SOCKET=nw|bsd` and `MATEBRIDGE_NOTSENT_LOWAT_KB`, read once.
    static let videoSocket = VideoSocketSettings.parse(ProcessInfo.processInfo.environment)

    /// The video listener: Network.framework, or a kernel socket with `MATEBRIDGE_VIDEO_SOCKET=bsd` (T-091).
    private enum VideoListener {
        case network(NWListener)
        case socket(BsdTcpListener)

        func cancel() {
            switch self {
            case .network(let l): l.cancel()
            case .socket(let l): l.cancel()
            }
        }
    }

    /// One video connection, on whichever stack its listener uses. Everything above the bytes is shared.
    private enum VideoConnection {
        case network(NWConnection)
        case socket(BsdTcpConnection)

        func cancel() {
            switch self {
            case .network(let c): c.cancel()
            case .socket(let c): c.cancel()
            }
        }
    }

    /// - Parameters:
    ///   - controlPort: preferred control port (default 47001, for `adb reverse`); falls back to a system-assigned
    ///     port when taken. 0 means system-assigned only.
    ///   - videoPort: same for the video listener (default 47002).
    ///   - makeStreamConfig: placeholder until the video pipeline (T-011) supplies the real configuration.
    public init(handlers: Handlers, store: ApprovedDeviceStore = ApprovedDeviceStore(directory: ApprovedDeviceStore.defaultDirectory()),
                pairKeys: PairKeyStore = KeychainPairKeyStore(),
                identity: HostIdentityStore.Identity = HostIdentityStore(directory: ApprovedDeviceStore.defaultDirectory()).resolve(),
                hostName: String = Host.current().localizedName ?? "Mac", controlPort: UInt16 = DefaultPorts.control,
                videoPort: UInt16 = DefaultPorts.video,
                makeStreamConfig: @escaping @Sendable (Hello) -> StreamConfig = SessionServer.defaultStreamConfig) {
        self.handlers = handlers
        queue.setSpecific(key: queueKey, value: true)
        self.store = store
        self.pairKeys = PairKeyService(store: pairKeys)
        self.identity = identity
        self.requestedControlPort = controlPort
        self.requestedVideoPort = videoPort
        let known = store.load()
        self.knownDevices = known
        var configuration = SessionMachine.Configuration(hostName: hostName, makeStreamConfig: makeStreamConfig,
                                                         hostID: identity.id, pairKeys: nil)
        if case .unpersisted = identity { configuration.allowPaired = false }  // a volatile host_id must not be trusted
        self.machine = SessionMachine(configuration: configuration, approvedDevices: Set(known.keys))
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
            applyIdentity()
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
        if Self.videoSocket.socket == .bsd { return startSocketVideoListener(plan: plan) }
        var plan = plan
        guard let port = plan.nextPort() else { return listenersFailed("video_listener_create") }
        let fixed = plan.lastWasPreferred
        let nextPlan = plan
        do {
            let video = try NWListener(using: Self.tcpParameters(serviceClass: Self.serviceClass.videoClass),
                                       on: Self.endpointPort(port))
            video.newConnectionHandler = { [weak self] c in self?.accept(c, video: true) }
            video.stateUpdateHandler = { [weak self, weak video] s in
                guard let self, let video, case .network(let current)? = videoListener, video === current else { return }
                if case .failed = s, fixed {
                    logger.log(.warning, "port_fallback", sessionID: 0, generation: 0,
                               fields: "listener=video wanted=\(port)")
                    video.cancel()
                    videoListener = nil
                    return startVideoListener(plan: nextPlan)
                }
                videoListenerState(s)
            }
            videoListener = .network(video)
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

    /// `MATEBRIDGE_VIDEO_SOCKET=bsd` (T-091): the same port plan on a kernel socket (dual-stack `[::]:port`). Binding is
    /// synchronous, so the listener is ready (or failed) right here.
    private func startSocketVideoListener(plan: ListenerPortPlan) {
        guard !stopped else { return }
        var plan = plan
        guard let port = plan.nextPort() else { return listenersFailed("video_listener_create") }
        let fixed = plan.lastWasPreferred
        let nextPlan = plan
        let options = BsdTcpOptions(notSentLowatBytes: Self.videoSocket.notSentLowatBytes,
                                    serviceClass: Self.serviceClass.videoClass)
        let listener: BsdTcpListener
        do {
            listener = try BsdTcpListener(port: port, options: options, queue: queue)
        } catch {
            if fixed {
                logFallback("video", port)
                return startSocketVideoListener(plan: nextPlan)
            }
            logger.log(.error, "video_listener_socket_error", sessionID: 0, generation: 0, fields: "error=\(error)")
            return listenersFailed("video_listener_create")
        }
        videoListener = .socket(listener)
        listener.start { [weak self, weak listener] event in
            guard let self, let listener, case .socket(let current)? = videoListener, current === listener else {
                if case .accepted(let c) = event { c.cancel() }  // a cancelled listener's late accept
                return
            }
            switch event {
            case .accepted(let connection):
                acceptVideo(connection)
            case .acceptConfigureFailed(let error):
                logger.log(.warning, "connection_refused", sessionID: currentSessionID, generation: currentConfigID,
                           fields: "video=true reason=socket_setup error=\(error)")
            case .acceptPaused(let errno):
                logger.log(.warning, "video_accept_paused", sessionID: currentSessionID, generation: currentConfigID,
                           fields: "errno=\(errno)")
            case .failed(let errno):
                logger.log(.error, "video_listener_socket_error", sessionID: 0, generation: 0,
                           fields: "error=accept:\(errno)")
                listenersFailed("video_listener_failed")
            }
        }
        videoListenerReady(port: listener.port)
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

    /// The stream settings of the live session changed (`STREAM_PREFS`, T-049): sends the new `STREAM_CONFIG` and closes
    /// the video connection so the tablet reopens it with the new `config_id`. Ignored for an ended session.
    public func reconfigureStream(sessionID: UInt32, config: StreamConfig) {
        queue.async { [self] in
            guard !stopped, sessionID == currentSessionID else { return }
            currentConfigID = config.configID
            apply(machine.reconfigure(sessionID: sessionID, config: config))
        }
    }

    /// Sends a host-initiated control message (CLIPBOARD) to the active session. Ignored for an ended session.
    public func sendToSession(sessionID: UInt32, _ message: Message) {
        queue.async { [self] in
            guard !stopped else { return }
            apply(machine.send(sessionID: sessionID, message))
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
            if approved, !pairKeys.hasCapacity {
                // The Keychain queue is full (stuck): refuse explicitly and keep the window, the user can retry.
                logger.log(.warning, "keychain_busy_approval_refused", sessionID: currentSessionID,
                           generation: currentConfigID, fields: "conn=\(id)")
                if let request = pendingRequest, request.id == id { handlers.approvalKeychainBusy(request) }
                return
            }
            pendingApproval = nil
            pendingRequest = nil
            if approved {
                logger.log(.info, "approval_approved", sessionID: currentSessionID,
                           generation: currentConfigID, fields: "conn=\(id)")
            }
            apply(machine.approvalDecided(pending, approved: approved, now: nowUs()))
        }
    }

    /// Menu item "Onaylı cihazları unut": the live session ends first (input released, BYE, close), then the approvals
    /// go and the next connection asks for pairing again. The Keychain work runs off the session queue: it can block
    /// on an access prompt and must never delay a release.
    public func forgetApprovedDevices() {
        queue.async { [self] in
            apply(machine.shutdown())
            dropPairing(reason: "forgotten")
        }
    }

    /// Clears the approved list and enqueues deletion of every pair key on the Keychain queue. The delete is
    /// enqueued NOW, so a pairing saved later (enqueued later) can never be deleted by it.
    private func dropPairing(reason: String) {
        revocationGeneration += 1
        machine.forgetApprovedDevices()
        knownDevices.removeAll()
        try? store.save(knownDevices)
        logger.log(.info, "devices_forgotten", sessionID: currentSessionID, generation: currentConfigID,
                   fields: "reason=\(reason)")
        pairKeys.removeAll { [weak self] failure in
            guard let failure else { return }
            self?.queue.async { [weak self] in
                guard let self else { return }
                logger.log(.error, "pair_keys_remove_failed", sessionID: currentSessionID,
                           generation: currentConfigID, fields: "error=\(failure)")
            }
        }
    }

    /// host_id handling at start (PROTOCOL.md 9): a replaced identity invalidates every old pair key and approval
    /// (tablets would reject PAIRED under a new host_id); an identity that could not be stored is never trusted.
    private func applyIdentity() {
        switch identity {
        case .loaded: break
        case .created:
            if !knownDevices.isEmpty {
                logger.log(.warning, "host_identity_replaced", sessionID: 0, generation: 0)
                dropPairing(reason: "host_identity_replaced")
            }
        case .unpersisted:
            logger.log(.error, "host_identity_unpersisted", sessionID: 0, generation: 0,
                       fields: "paired=disabled")
        }
    }

    // MARK: Listeners

    /// TCP with Nagle off. Accepted connections inherit the listener's parameters, so a service class set here applies
    /// to every connection of that listener (T-088; nil leaves the default, `.bestEffort`).
    private static func tcpParameters(serviceClass: TrafficClass?) -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let parameters = NWParameters(tls: nil, tcp: tcp)
        if let serviceClass { parameters.serviceClass = Self.networkServiceClass(serviceClass) }
        return parameters
    }

    private static func networkServiceClass(_ c: TrafficClass) -> NWParameters.ServiceClass {
        switch c {
        case .interactiveVideo: return .interactiveVideo
        case .interactiveVoice: return .interactiveVoice
        case .responsiveData: return .responsiveData
        }
    }

    private func videoListenerState(_ s: NWListener.State) {
        switch s {
        case .ready:
            guard case .network(let listener)? = videoListener, let port = listener.port?.rawValue else {
                return fail("video_port_missing")
            }
            videoListenerReady(port: port)
        case .failed:
            listenersFailed("video_listener_failed")
        default: break
        }
    }

    private func videoListenerReady(port: UInt16) {
        machine.videoPort = port
        startControlListener(videoPort: port)
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
            let listener = try NWListener(using: Self.tcpParameters(serviceClass: Self.serviceClass.controlClass),
                                          on: Self.endpointPort(port))
            listener.service = NWListener.Service(name: machine.configuration.hostName, type: Self.bonjourType,
                                                  domain: nil, txtRecord: NWTXTRecord(["v": "1"]))
            listener.newConnectionHandler = { [weak self] c in self?.accept(c, video: false) }
            listener.stateUpdateHandler = { [weak self, weak listener] s in
                guard let self, let listener, listener === controlListener else { return }
                switch s {
                case .ready:
                    restartAttempts = 0
                    logger.log(.info, "listening", sessionID: 0, generation: 0,
                               fields: "control_port=\(listener.port?.rawValue ?? 0) video_port=\(videoPort) "
                                   + Self.serviceClass.logFields + " " + Self.videoSocket.logFields)
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
            videoConnections[id] = .network(connection)
            apply(machine.videoOpened(id, now: nowUs()))
        } else {
            controlConnections[id] = connection
            inbounds[id] = ControlInbound()
            apply(machine.connectionOpened(id, now: nowUs()))
        }
        receiveLoop(id, connection, video: video)
    }

    /// A video connection from the kernel-socket listener (T-091). Same bound, ids, machine events and byte handling
    /// as `accept(_:video:)`; only the transport differs. Reads arrive on `queue`; `onClosed` arrives on `queue` once
    /// the socket closed for any reason (end of stream, error, or our own `cancel()`), like `.cancelled` above.
    private func acceptVideo(_ connection: BsdTcpConnection) {
        guard machine.pendingVideoCount < Self.maxUnauthenticated else {
            logger.log(.warning, "connection_refused", sessionID: currentSessionID, generation: currentConfigID,
                       fields: "video=true reason=too_many_unauthenticated")
            connection.cancel()
            return
        }
        nextID += 1
        let id = ConnectionID(nextID)
        connection.start(queue: queue, onBytes: { [weak self] bytes in
            // A connection already removed (closed meanwhile) gets nothing more: it is being cancelled.
            guard let self, videoConnections[id] != nil else { return false }
            return receiveVideoBytes(id, bytes)
        }, onClosed: { [weak self] in
            self?.transportClosed(id, video: true)
        })
        videoConnections[id] = .socket(connection)
        apply(machine.videoOpened(id, now: nowUs()))
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

    /// Video connection input. First one VIDEO_HELLO (type 0x40, payload at most 1 KiB), hand-parsed so an
    /// unauthenticated peer can never make us buffer the 16 MiB video payload limit. Then exactly one encrypted PING
    /// (the proof), decoded with a tiny record limit. Nothing else is valid C->H. Returns false when closed.
    private func receiveVideoBytes(_ id: ConnectionID, _ bytes: [UInt8]) -> Bool {
        func reject() -> Bool {
            logger.log(.warning, "video_hello_invalid", sessionID: currentSessionID, generation: currentConfigID)
            closeVideo(id)
            return false
        }
        if videoHelloSeen.contains(id) { return receiveVideoProof(id, bytes) }
        var buffer = videoBuffers[id, default: []]
        buffer += bytes
        if buffer.count >= ProtocolConstants.headerSize {
            guard buffer[0] == MessageType.videoHello.rawValue else { return reject() }
            let l = (0..<4).reduce(UInt32(0)) { $0 | UInt32(buffer[1 + $1]) << (8 * UInt32($1)) }
            guard l <= UInt32(Self.maxVideoHandshakePayload) else { return reject() }
            let total = ProtocolConstants.headerSize + Int(l)
            if buffer.count >= total {
                var d = FrameDecoder(connection: .video)
                d.append(Array(buffer[..<total]))
                guard case .videoHello(let hello)? = try? d.nextMessage() else { return reject() }
                let rest = Array(buffer[total...])
                videoBuffers[id] = nil
                videoHelloSeen.insert(id)
                apply(machine.videoHello(id, hello, now: nowUs()))
                guard videoConnections[id] != nil else { return false }
                return rest.isEmpty ? true : receiveVideoProof(id, rest)
            }
        }
        videoBuffers[id] = buffer
        return true
    }

    private func receiveVideoProof(_ id: ConnectionID, _ bytes: [UInt8]) -> Bool {
        func reject(_ event: String) -> Bool {
            logger.log(.warning, event, sessionID: currentSessionID, generation: currentConfigID,
                       fields: "conn=\(id.raw) video=true")
            closeVideo(id)
            return false
        }
        // No decoder: the machine refused the VIDEO_HELLO, or the proof already passed. The client sends nothing more.
        guard videoProofDecoders[id] != nil else { return reject("video_hello_invalid") }
        videoProofDecoders[id]!.append(bytes)
        do {
            guard let message = try videoProofDecoders[id]!.nextMessage() else { return true }
            guard case .ping = message, videoProofDecoders[id]!.bufferedCount == 0 else {
                return reject("video_hello_invalid")
            }
            videoProofDecoders[id] = nil
            apply(machine.videoProven(id, now: nowUs()))  // attaches, closes the old video connection, starts frames
            return videoConnections[id] != nil
        } catch {
            return reject("record_auth_failed")  // no BYE on video; the session itself is untouched
        }
    }

    /// The transport is gone (peer closed, error, or we cancelled it). Idempotent; always cancels the socket.
    private func transportClosed(_ id: ConnectionID, video: Bool) {
        if video {
            guard let c = videoConnections.removeValue(forKey: id) else { return }
            c.cancel()
            videoLinks[id] = nil
            videoBuffers[id] = nil
            videoHelloSeen.remove(id)
            videoProofDecoders[id] = nil
            apply(machine.videoClosed(id))
        } else {
            liveLookups.remove(id)
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
        liveLookups.remove(id)
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
            case .videoProve(let id, let key):
                videoProofDecoders[id] = RecordDecoder(key: key, connection: .video, maxPayload: 64)
            case .releaseInput(_, let cause):
                handlers.releaseInput(cause)
            case .deliver(_, let message):
                handlers.deliver(message)
            case .requestApproval(let id, _, let name, let code):
                pendingApproval = id
                let request = ApprovalRequest(id: id.raw, deviceName: name, code: code.digits)
                pendingRequest = request
                handlers.approvalRequested(request)
            case .approvalOrphaned(let id):
                handlers.approvalOrphaned(id.raw)  // pendingApproval stays: the window's answer is still valid
            case .cancelApproval(let id):
                if pendingApproval == id {
                    pendingApproval = nil
                    pendingRequest = nil
                    handlers.approvalCancelled(id.raw)
                }
            case .persistOrphanPairing(_, let device, let name, let key):
                // Same store path as a live approval, minus the ACCEPTED: key first, then the device list.
                let generation = revocationGeneration
                let enqueued = pairKeys.save(key, for: device) { [weak self] saved in
                    self?.queue.async { [weak self] in
                        self?.finishOrphanPairing(device: device, name: name, key: key, keySaved: saved,
                                                  generation: generation)
                    }
                }
                if !enqueued {  // the window's answer checks capacity first; this is only a safety net
                    logger.log(.error, "keychain_busy_save_refused", sessionID: currentSessionID,
                               generation: currentConfigID)
                    machine.orphanPairingPersisted(deviceID: device, stored: false)
                }
            case .lookupPairKey(let conn, let device):
                // Off the session queue: the Keychain may block. The connection sends nothing until it answers
                // (the machine closes it after 5 s).
                let deadline = nowUs() + machine.configuration.lookupTimeoutUs
                liveLookups.insert(conn)
                let accepted = pairKeys.lookup(device, isCurrent: { [liveLookups] in
                    liveLookups.contains(conn) && HostClock.nowUs() < deadline
                }) { [weak self] key in
                    self?.queue.async { [weak self] in
                        guard let self, !stopped else { return }
                        liveLookups.remove(conn)
                        apply(machine.pairKeyResolved(conn, key: key, now: nowUs()))
                    }
                }
                if !accepted {
                    // Too many lookups stuck behind the Keychain: drop this connection (it has been sent nothing).
                    logger.log(.warning, "pair_key_lookup_overloaded", sessionID: currentSessionID,
                               generation: currentConfigID, fields: "conn=\(conn.raw)")
                    liveLookups.remove(conn)
                    closeControl(conn)
                    apply(machine.connectionClosed(conn))
                }
            case .persistPairing(let conn, let device, let name, let key):
                // Key first (Keychain queue), then the device list; ACCEPTED goes out only when both are stored.
                let generation = revocationGeneration
                let enqueued = pairKeys.save(key, for: device) { [weak self] saved in
                    self?.queue.async { [weak self] in
                        self?.finishPairing(conn, device: device, name: name, key: key, keySaved: saved,
                                            generation: generation)
                    }
                }
                if !enqueued {  // safety net, see above: reject instead of accepting a key that was never stored
                    logger.log(.error, "keychain_busy_save_refused", sessionID: currentSessionID,
                               generation: currentConfigID)
                    apply(machine.pairingPersisted(conn, stored: false, now: nowUs()))
                }
            case .sessionStarted(let id, let sid, let configID, let hello):
                activeTransport = Self.transport(of: controlConnections[id])
                currentSessionID = sid
                currentConfigID = configID
                handlers.sessionStarted(sid, configID, hello, activeTransport)
            case .sessionEnded:
                currentSessionID = 0
                currentConfigID = 0
                handlers.sessionEnded()
            case .videoAttached(let vid, _, let sid, let configID, let keys):
                if let c = videoConnections[vid] {
                    let sealer = RecordSealer(key: keys.h2c, maxPayload: ProtocolConstants.maxVideoPayload)
                    let link: VideoLink
                    switch c {
                    case .network(let connection):
                        link = VideoLink(sessionID: sid, configID: configID, connection: connection, logger: logger,
                                         sealer: sealer, sampleSendQueue: Self.sampleSendQueue)
                    case .socket(let socket):
                        link = VideoLink(sessionID: sid, configID: configID, socket: socket, logger: logger,
                                         sealer: sealer, sampleSendQueue: Self.sampleSendQueue)
                    }
                    videoLinks[vid] = link
                    handlers.videoAttached(link)
                }
            case .log(let level, let ev, let conn, let fields):
                let extra = conn.map { "conn=\($0.raw)" } ?? ""
                // The machine does not know peer addresses; `.sessionStarted` (just before) set `activeTransport`.
                let transport = ev == "session_started" ? "transport=\(activeTransport.logName)" : ""
                logger.log(level, ev, sessionID: currentSessionID, generation: currentConfigID,
                           fields: [extra, fields, transport].filter { !$0.isEmpty }.joined(separator: " "))
            }
        }
        refreshState()
    }

    /// Session queue: the Keychain save finished.
    private func finishPairing(_ conn: ConnectionID, device: DeviceID, name: String, key: SecretBytes, keySaved: Bool,
                               generation: Int) {
        guard generation == revocationGeneration else {
            // "Forget" happened while the save was in flight: the approval is void, the stored key goes.
            if keySaved { pairKeys.remove(device, ifEquals: key) }
            logger.log(.info, "pairing_revoked_discarded", sessionID: currentSessionID, generation: currentConfigID)
            apply(machine.pairingPersisted(conn, stored: false, now: nowUs()))
            return
        }
        guard machine.isPendingApproval(conn) else {
            // The connection ended meanwhile (e.g. "forget" ended it): nobody will use this key. Compare-and-delete:
            // a newer key saved for the same device meanwhile must survive.
            if keySaved { pairKeys.remove(device, ifEquals: key) }
            return
        }
        var stored = keySaved
        if keySaved {
            knownDevices[device] = name
            do { try store.save(knownDevices) } catch {
                stored = false
                knownDevices[device] = nil
                pairKeys.remove(device, ifEquals: key)
                logger.log(.error, "store_save_failed", sessionID: currentSessionID, generation: currentConfigID)
            }
        } else {
            logger.log(.error, "pair_key_save_failed", sessionID: currentSessionID, generation: currentConfigID)
        }
        apply(machine.pairingPersisted(conn, stored: stored, now: nowUs()))
    }

    /// Session queue: the Keychain save of an orphaned approval finished.
    private func finishOrphanPairing(device: DeviceID, name: String, key: SecretBytes, keySaved: Bool,
                                     generation: Int) {
        guard generation == revocationGeneration else {
            if keySaved { pairKeys.remove(device, ifEquals: key) }
            machine.orphanPairingPersisted(deviceID: device, stored: false)
            logger.log(.info, "pairing_revoked_discarded", sessionID: currentSessionID, generation: currentConfigID)
            return
        }
        guard keySaved else {
            machine.orphanPairingPersisted(deviceID: device, stored: false)
            logger.log(.error, "pair_key_save_failed", sessionID: currentSessionID, generation: currentConfigID)
            return
        }
        knownDevices[device] = name
        do { try store.save(knownDevices) } catch {
            knownDevices[device] = nil
            pairKeys.remove(device, ifEquals: key)
            machine.orphanPairingPersisted(deviceID: device, stored: false)
            logger.log(.error, "store_save_failed", sessionID: currentSessionID, generation: currentConfigID)
            return
        }
        machine.orphanPairingPersisted(deviceID: device, stored: true)
        logger.log(.info, "orphan_pairing_stored", sessionID: currentSessionID, generation: currentConfigID)
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

/// Small lock-protected set, readable from the Keychain queue.
private final class LockedSet<Element: Hashable & Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: Set<Element> = []
    func insert(_ e: Element) { lock.withLock { _ = items.insert(e) } }
    func remove(_ e: Element) { lock.withLock { _ = items.remove(e) } }
    func contains(_ e: Element) -> Bool { lock.withLock { items.contains(e) } }
}
