import Foundation
import MateBridgeCore
import Network
import Synchronization

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
        case .writeRefused:  // the transport already cancelled the connection; the completion reports false
            logger.log(.warning, "video_write_refused", sessionID: sessionID, generation: configID)
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

/// TCP control and video listeners plus Bonjour, driving a `SessionMachine`. Each listener runs on Network.framework
/// or on a kernel socket (`MATEBRIDGE_VIDEO_SOCKET`, T-091; `MATEBRIDGE_CONTROL_SOCKET`, T-111; both default `bsd`).
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
        /// `AUDIO_PREFS` from the active, encrypted session (decision 0011, T-094).
        public var audioPrefs: @Sendable (_ sessionID: UInt32, AudioPrefs) -> Void = { _, _ in }
        /// Whether `openSettingsPanel()` can reach the tablet now: an ACCEPTED session whose HELLO announced
        /// `SETTINGS_PANEL` (decision 0013). Called on changes only, in order with `stateChanged`.
        public var settingsPanelAvailable: @Sendable (Bool) -> Void = { _ in }
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
    /// Last value reported through `handlers.settingsPanelAvailable`.
    private var settingsPanelAvailable = false
    private var controlListener: ControlListener?
    /// Bonjour record of a kernel-socket control listener (`NWListener.service` does this for `nw`).
    private var bonjour: BonjourAdvertiser?
    private var bonjourAttempts = 0
    private var videoListener: VideoListener?
    private var nextID: UInt64 = 0
    private var controlConnections: [ConnectionID: ControlConnection] = [:]
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
    /// Control connection of the active session (audio goes here).
    private var activeControl: ConnectionID?
    /// AUDIO_FRAMEs the server dropped (outbox full, stale, or connection backed up); read by the audio streamer.
    private let audioWireDrops = Atomic<Int>(0)
    /// Audio waiting for `queue` (newest frames win, at most one drain pass pending). Guarded by `audioLock`.
    private let audioLock = NSLock()
    private var audioOutbox = AudioOutbox()
    /// AUDIO_FRAME send timing (T-116): `component=audio ev=send` once a second, `ev=send_gap` at debug. Session queue.
    private var audioTiming = AudioSendTiming()
    /// Session of the writes in the current `audioTiming` window (its line is logged with it).
    private var audioTimingSessionID: UInt32 = 0
    private let audioLogger = SessionLogger(component: "audio")
    /// Per-second TCP state of the active session's control and video sockets (T-126, `net ev=tcp`). Session queue.
    private var tcpInfoSamplers: [ConnectionID: TcpInfoSampler] = [:]
    private var tcpInfoTicks = 0
    private let netLogger = SessionLogger(component: "net")
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
    /// Sealed size of one 10 ms AUDIO_FRAME: record length (4) + type and tag (17) + fixed part (28) + 1920 PCM bytes.
    static let sealedAudioFrameBytes = 4 + ProtocolConstants.recordOverhead + AudioFrame.fixedSize
        + Int(AudioStreamPolicy.framesPerPacket) * Int(AudioStreamPolicy.channels) * 2
    /// 100 ms of audio (PROTOCOL.md 5), about 19.2 KiB. An AUDIO_FRAME that would take the unsent control bytes above
    /// this is dropped: audio never pushes the connection to `maxInflightBytes` or queues far behind other sends.
    static let audioBacklogBytes = 10 * sealedAudioFrameBytes
    static let maxUnauthenticated = 4
    static let maxVideoHandshakePayload = 1024
    /// T-088 knobs, read once. The service class defaults to `signaling` since T-124 (control AC_VO, video AC_VI on
    /// Wi-Fi); `MATEBRIDGE_SERVICE_CLASS=off` leaves both unset.
    static let serviceClass = ServiceClassKnob.parse(ProcessInfo.processInfo.environment)
    static let sampleSendQueue = SendQueueLogKnob.isEnabled(ProcessInfo.processInfo.environment)
    /// T-126: `MATEBRIDGE_TCP_LOG=0|1`, default on for Wi-Fi sessions only.
    static let tcpInfoLog = TcpInfoLogKnob.parse(ProcessInfo.processInfo.environment)
    /// The 100 ms session tick closes an `ev=tcp` window every this many ticks (1 s).
    static let tcpInfoTickInterval = 10
    /// T-091: `MATEBRIDGE_VIDEO_SOCKET=nw|bsd` and `MATEBRIDGE_NOTSENT_LOWAT_KB`, read once.
    static let videoSocket = VideoSocketSettings.parse(ProcessInfo.processInfo.environment)
    /// T-111: `MATEBRIDGE_CONTROL_SOCKET=bsd|nw`, read once.
    static let controlSocket = ControlSocketKnob.parse(ProcessInfo.processInfo.environment)
    /// `TCP_NOTSENT_LOWAT` of a `bsd` control connection: 9 sealed audio packets. An AUDIO_FRAME is dropped while the
    /// kernel holds this many unsent bytes, so at most this plus the one packet written after the check, i.e.
    /// `audioBacklogBytes` (100 ms of audio, PROTOCOL.md 5), waits unsent in the kernel. It never blocks a write:
    /// BYE, CLIPBOARD and every other message are always queued.
    static let controlNotSentLowatBytes = audioBacklogBytes - sealedAudioFrameBytes
    /// Kernel-socket control connections: Nagle and keepalive off like `tcpParameters` (liveness is the protocol's
    /// heartbeat), kernel-default buffer sizes, the audio low-water mark above. The user-space queue is bounded by
    /// `maxInflightBytes` here (`sendControlBytes`), so the connection's own bound never binds first.
    static let controlSocketOptions = BsdTcpOptions(noDelay: true, keepAlive: false,
                                                    notSentLowatBytes: controlNotSentLowatBytes,
                                                    serviceClass: serviceClass.controlClass,
                                                    maxPendingRecords: maxInflightBytes,
                                                    maxPendingBytes: maxInflightBytes)
    /// How long a closing `bsd` control connection may take to write its last messages (BYE) before it is cut.
    static let controlFlushTimeout: DispatchTimeInterval = .seconds(2)

    /// The control listener: kernel socket (default) or Network.framework with `MATEBRIDGE_CONTROL_SOCKET=nw`.
    private enum ControlListener {
        case network(NWListener)
        case socket(BsdTcpListener)

        func cancel() {
            switch self {
            case .network(let l): l.cancel()
            case .socket(let l): l.cancel()
            }
        }
    }

    /// One control connection, on whichever stack its listener uses. Everything above the bytes is shared.
    private enum ControlConnection {
        case network(NWConnection)
        case socket(BsdTcpConnection)

        func cancel() {
            switch self {
            case .network(let c): c.cancel()
            case .socket(let c): c.cancel()
            }
        }
    }

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
        cancelListeners()
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

    private func cancelListeners() {
        controlListener?.cancel()
        videoListener?.cancel()
        bonjour?.cancel()
        controlListener = nil
        videoListener = nil
        bonjour = nil
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
            cancelListeners()
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

    /// Host menu "open settings on the tablet" (decision 0013): sends `SETTINGS_OPEN` to the active session if its
    /// client announced `SETTINGS_PANEL`; otherwise nothing is sent (`ev=settings_open_skipped`).
    public func openSettingsPanel() {
        queue.async { [self] in
            guard !stopped else { return }
            apply(machine.openSettingsPanel())
        }
    }

    /// Audio (T-094): `AUDIO_CONFIG` and `AUDIO_FRAME` to the active session's control connection, in order. Ignored
    /// for an ended session. `AUDIO_CONFIG` is always sent. `AUDIO_FRAME`s (all drops counted in
    /// `takeAudioWireDrops`):
    /// - wait in `AudioOutbox` before reaching `queue`: at most 10 (100 ms); a newer frame replaces the oldest waiting
    ///   one, and at most one drain pass is enqueued however long `queue` is busy;
    /// - are dropped when sealing would happen more than 100 ms after capture (stale after a stall);
    /// - are dropped when they would take the unsent bytes of the connection above `audioBacklogBytes`.
    /// Sealing runs on the session queue (a few microseconds per 10 ms packet); the bytes go out H->C and never hold up
    /// input, which arrives C->H.
    public func sendAudio(sessionID: UInt32, _ message: Message) {
        let pushedUs = nowUs()
        let (enqueue, dropped) = audioLock.withLock { audioOutbox.push(sessionID: sessionID, message, nowUs: pushedUs) }
        if dropped > 0 { audioWireDrops.add(dropped, ordering: .relaxed) }
        if enqueue { queue.async { [self] in drainAudio() } }
    }

    /// Session queue: sends everything waiting in the audio outbox.
    private func drainAudio() {
        let items = audioLock.withLock { audioOutbox.take() }
        let now = nowUs()
        for item in items {
            if case .audioConfig = item.message { closeAudioTimingWindow() }  // stream boundary, sent or not
            guard !stopped, item.sessionID != 0, item.sessionID == currentSessionID, let id = activeControl,
                  sealers[id] != nil else { continue }
            guard case .audioFrame(let frame) = item.message else {
                sendControl(id, item.message)
                continue
            }
            let size = 4 + ProtocolConstants.recordOverhead + AudioFrame.fixedSize + frame.data.count
            guard !AudioOutbox.isStale(frame, nowUs: now),
                  inflightBytes[id, default: 0] + size <= Self.audioBacklogBytes,
                  !kernelAudioBacklog(id) else {
                audioWireDrops.add(1, ordering: .relaxed)
                continue
            }
            let inflightBefore = inflightBytes[id, default: 0]
            let writeStart = nowUs()
            sendControl(id, item.message)
            let writeEnd = nowUs()
            recordAudioWrite(id, frame: frame, queueLagUs: now > item.pushedUs ? now - item.pushedUs : 0,
                             inflightBefore: inflightBefore, writeStart: writeStart, writeEnd: writeEnd)
        }
    }

    /// Session queue: timing of one AUDIO_FRAME write (T-116). Measurement only.
    private func recordAudioWrite(_ id: ConnectionID, frame: AudioFrame, queueLagUs: UInt64, inflightBefore: Int,
                                  writeStart: UInt64, writeEnd: UInt64) {
        // Bytes not yet handed on: `bsd` user-space queue after the write (EAGAIN / partial write); `nw` cannot tell,
        // there it is what Network.framework had not processed yet when the write was issued.
        let pending: Int
        switch controlConnections[id] {
        case .socket(let socket)?: pending = socket.pendingBytes
        case .network?: pending = inflightBefore
        case nil: pending = 0
        }
        audioTimingSessionID = currentSessionID
        let write = AudioSendTiming.Write(
            queueLagUs: queueLagUs,
            captureToWriteUs: writeEnd > frame.captureTimeUs ? writeEnd - frame.captureTimeUs : 0,
            writeCallUs: writeEnd >= writeStart ? writeEnd - writeStart : 0, pendingBytes: pending, endUs: writeEnd)
        if let gap = audioTiming.recordWrite(write) {
            audioLogger.log(.debug, "send_gap", sessionID: currentSessionID, generation: 0, fields: gap.logFields)
            logTcpInfo(id, closeWindow: false, trigger: "send_gap")
        }
        if let fields = audioTiming.takeReportIfDue(nowUs: writeEnd) {
            audioLogger.log(.info, "send", sessionID: currentSessionID, generation: 0, fields: fields)
        }
    }

    /// Session queue: logs what is left of the `ev=send` window and starts a new interval (AUDIO_CONFIG).
    private func closeAudioTimingWindow() {
        if let fields = audioTiming.flush() {
            audioLogger.log(.info, "send", sessionID: audioTimingSessionID, generation: 0, fields: fields)
        }
        audioTiming.resetInterval()
    }

    /// `bsd` control connection: the kernel holds at least `controlNotSentLowatBytes` unsent (or our own queue is not
    /// empty). `nw` cannot tell; there `inflightBytes` is the only gate, as before T-111.
    private func kernelAudioBacklog(_ id: ConnectionID) -> Bool {
        guard case .socket(let socket)? = controlConnections[id] else { return false }
        return !socket.isWritableForNewRecord
    }

    /// AUDIO_PREFS handling: the machine has already seen the message (heartbeat). It reaches the audio streamer only
    /// from the active session's encrypted control connection; anything earlier (pending, proving) is ignored.
    private func routeAudioPrefs(_ id: ConnectionID, _ prefs: AudioPrefs) {
        guard id == activeControl, sealers[id] != nil, currentSessionID != 0 else { return }
        handlers.audioPrefs(currentSessionID, prefs)
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
        if Self.controlSocket == .bsd { return startSocketControlListener(videoPort: videoPort, plan: plan) }
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
                guard let self, let listener, case .network(let current)? = controlListener, current === listener
                else { return }
                switch s {
                case .ready:
                    controlListenerReady(port: listener.port?.rawValue ?? 0, videoPort: videoPort)
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
            controlListener = .network(listener)
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

    /// `MATEBRIDGE_CONTROL_SOCKET=bsd` (T-111): the same port plan on a kernel socket (dual-stack `[::]:port`), plus a
    /// Bonjour record for the bound port. Binding is synchronous, so the listener is ready (or failed) right here.
    private func startSocketControlListener(videoPort: UInt16, plan: ListenerPortPlan) {
        guard !stopped else { return }
        var plan = plan
        guard let port = plan.nextPort() else { return listenersFailed("control_listener_create") }
        let fixed = plan.lastWasPreferred
        let nextPlan = plan
        let listener: BsdTcpListener
        do {
            listener = try BsdTcpListener(port: port, options: Self.controlSocketOptions, queue: queue)
        } catch {
            if fixed {
                logFallback("control", port)
                return startSocketControlListener(videoPort: videoPort, plan: nextPlan)
            }
            logger.log(.error, "control_listener_socket_error", sessionID: 0, generation: 0, fields: "error=\(error)")
            return listenersFailed("control_listener_create")
        }
        controlListener = .socket(listener)
        listener.start { [weak self, weak listener] event in
            guard let self, let listener, case .socket(let current)? = controlListener, current === listener else {
                if case .accepted(let c) = event { c.cancel() }  // a cancelled listener's late accept
                return
            }
            switch event {
            case .accepted(let connection):
                acceptControl(connection)
            case .acceptConfigureFailed(let error):
                logger.log(.warning, "connection_refused", sessionID: currentSessionID, generation: currentConfigID,
                           fields: "video=false reason=socket_setup error=\(error)")
            case .acceptPaused(let errno):
                logger.log(.warning, "control_accept_paused", sessionID: currentSessionID,
                           generation: currentConfigID, fields: "errno=\(errno)")
            case .failed(let errno):
                logger.log(.error, "control_listener_socket_error", sessionID: 0, generation: 0,
                           fields: "error=accept:\(errno)")
                listenersFailed("control_listener_failed")
            }
        }
        bonjourAttempts = 0
        startBonjour(for: listener)
        controlListenerReady(port: listener.port, videoPort: videoPort)
    }

    private func controlListenerReady(port: UInt16, videoPort: UInt16) {
        restartAttempts = 0
        logger.log(.info, "listening", sessionID: 0, generation: 0,
                   fields: "control_port=\(port) video_port=\(videoPort) " + Self.serviceClass.logFields + " "
                       + Self.videoSocket.logFields + " " + Self.controlSocket.logFields
                       + " tcp_log=\(Self.tcpInfoLog.rawValue)")
        if case .starting = state { setState(.listening) }
    }

    /// Registers `_matebridge._tcp` for a kernel-socket control listener: the record `NWListener.service` carries for
    /// `nw` (host name, TXT `v=1`, the bound port). A failure (also later, e.g. mDNSResponder restarting) is logged and
    /// retried with backoff (1 s ... 30 s) while this listener lives; sessions are not touched (USB and running
    /// sessions do not need discovery).
    private func startBonjour(for listener: BsdTcpListener) {
        guard !stopped, case .socket(let current)? = controlListener, current === listener else { return }
        bonjour?.cancel()
        bonjour = nil
        do {
            bonjour = try BonjourAdvertiser(name: machine.configuration.hostName, type: Self.bonjourType,
                                            port: listener.port, txt: [("v", "1")], queue: queue) {
                [weak self, weak listener] event in
                guard let self, let listener else { return }
                switch event {
                case .registered:
                    bonjourAttempts = 0
                    logger.log(.info, "bonjour_registered", sessionID: currentSessionID, generation: currentConfigID,
                               fields: "port=\(listener.port)")
                case .failed(let code):
                    bonjourFailed(code: code, listener: listener)
                }
            }
        } catch let error as BonjourError {
            bonjourFailed(code: error.code, listener: listener)
        } catch {
            bonjourFailed(code: -1, listener: listener)
        }
    }

    private func bonjourFailed(code: Int32, listener: BsdTcpListener) {
        bonjour?.cancel()
        bonjour = nil
        let delay = min(30.0, pow(2.0, Double(bonjourAttempts)))
        bonjourAttempts += 1
        logger.log(.warning, "bonjour_failed", sessionID: currentSessionID, generation: currentConfigID,
                   fields: "code=\(code) retry_s=\(Int(delay))")
        queue.asyncAfter(deadline: .now() + delay) { [weak self, weak listener] in
            guard let self, let listener else { return }
            startBonjour(for: listener)
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
            controlConnections[id] = .network(connection)
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

    /// A control connection from the kernel-socket listener (T-111). Same bound, ids, machine events and byte handling
    /// as `accept(_:video:)`; only the transport differs. Reads arrive on `queue`. `onClosed` arrives on `queue` once
    /// the socket closed for any reason (end of stream, half close, error, our own `cancel()`): `transportClosed` then
    /// tells the machine, which releases all input (PROTOCOL.md 7).
    private func acceptControl(_ connection: BsdTcpConnection) {
        guard machine.awaitingHelloCount < Self.maxUnauthenticated else {
            logger.log(.warning, "connection_refused", sessionID: currentSessionID, generation: currentConfigID,
                       fields: "video=false reason=too_many_unauthenticated")
            connection.cancel()
            return
        }
        nextID += 1
        let id = ConnectionID(nextID)
        connection.start(queue: queue, onBytes: { [weak self] bytes in
            // Not in the table: closing (its last messages are being flushed) or gone. Nothing more is read from it.
            guard let self, controlConnections[id] != nil else { return true }
            if receiveControlBytes(id, bytes) { return true }
            // The machine closed it (BYE queued): let the graceful close finish. Otherwise `nw` would just stop
            // reading; here the socket is cancelled, so `onClosed` releases input.
            return controlConnections[id] == nil
        }, onClosed: { [weak self] in
            self?.transportClosed(id, video: false)
        })
        controlConnections[id] = .socket(connection)
        inbounds[id] = ControlInbound()
        apply(machine.connectionOpened(id, now: nowUs()))
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
                let receivedUs = nowUs()
                apply(machine.received(id, message, now: receivedUs))
                // T-116: type only (never content) and handling time, for the audio `ev=send_gap` line.
                audioTiming.noteReceived(message.type, startUs: receivedUs, endUs: nowUs())
                if inbounds[id] == nil { return false }  // the message ended this connection
                if case .audioPrefs(let prefs) = message { routeAudioPrefs(id, prefs) }
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
            tcpInfoSamplers[id] = nil
            videoBuffers[id] = nil
            videoHelloSeen.remove(id)
            videoProofDecoders[id] = nil
            apply(machine.videoClosed(id))
        } else {
            liveLookups.remove(id)
            guard let c = controlConnections.removeValue(forKey: id) else { return }
            c.cancel()
            tcpInfoSamplers[id] = nil
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
        tcpInfoSamplers[id] = nil
        inflightBytes[id] = nil
        inbounds[id] = nil
        sealers[id] = nil
        // Queued sends (BYE, REJECTED) are flushed before the FIN, then the socket is cancelled.
        flushGroup.enter()
        switch c {
        case .network(let c):
            c.send(content: nil, contentContext: .finalMessage, isComplete: true,
                   completion: .contentProcessed { [flushGroup] _ in
                       c.cancel()
                       flushGroup.leave()
                   })
        case .socket(let c):
            c.finish(timeout: Self.controlFlushTimeout) { [flushGroup] in flushGroup.leave() }
        }
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
        switch c {
        case .network(let c):
            c.send(content: Data(bytes), completion: .contentProcessed { [weak self] _ in
                guard let self, let n = inflightBytes[id] else { return }
                inflightBytes[id] = max(0, n - bytes.count)
            })
        case .socket(let c):
            // The completion (record handed to the kernel) runs on the socket's write queue: account on `queue`.
            let count = bytes.count
            let queued = c.write(bytes) { [weak self] _ in
                self?.queue.async { [weak self] in
                    guard let self, let n = inflightBytes[id] else { return }
                    inflightBytes[id] = max(0, n - count)
                }
            }
            if !queued {  // closed meanwhile (onClosed is on its way) or over the bound: input is released either way
                logger.log(.warning, "send_backlog", sessionID: currentSessionID, generation: currentConfigID,
                           fields: "reason=write_refused")
                transportClosed(id, video: false)
            }
        }
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
                activeControl = id
                currentSessionID = sid
                currentConfigID = configID
                startTcpInfoSampling(id, role: .control)
                handlers.sessionStarted(sid, configID, hello, activeTransport)
            case .sessionEnded(let id):
                if activeControl == id { activeControl = nil }
                tcpInfoSamplers[id] = nil
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
                    startTcpInfoSampling(vid, role: .video)
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
    private static func transport(of connection: ControlConnection?) -> SessionTransport {
        switch connection {
        case .network(let c)?:
            guard case .hostPort(let host, _) = c.endpoint else { return .network }
            return SessionTransport.classify(peerHost: "\(host)")
        case .socket(let c)?:
            return SessionTransport.classify(peerHost: c.peerHost)
        case nil:
            return .network
        }
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
        let settingsAvailable = machine.settingsPanelAvailable
        if settingsAvailable != settingsPanelAvailable {
            settingsPanelAvailable = settingsAvailable
            handlers.settingsPanelAvailable(settingsAvailable)
        }
    }

    private func setState(_ new: SessionServerState) {
        guard new != state else { return }
        state = new
        handlers.stateChanged(new)
    }

    // MARK: TCP state (T-126)

    /// Session queue: starts the per-second `ev=tcp` lines of connection `id` when the knob allows them for the
    /// active session's transport (set by `.sessionStarted` before either call).
    private func startTcpInfoSampling(_ id: ConnectionID, role: TcpConnectionRole) {
        guard Self.tcpInfoLog.isEnabled(transport: activeTransport, sendQueueLog: Self.sampleSendQueue) else { return }
        switch role {
        case .control:
            switch controlConnections[id] {
            case .network(let c)?: tcpInfoSamplers[id] = TcpInfoSampler(role: .control, connection: c)
            case .socket(let c)?: tcpInfoSamplers[id] = TcpInfoSampler(role: .control, socket: c)
            case nil: break
            }
        case .video:
            switch videoConnections[id] {
            case .network(let c)?: tcpInfoSamplers[id] = TcpInfoSampler(role: .video, connection: c)
            case .socket(let c)?: tcpInfoSamplers[id] = TcpInfoSampler(role: .video, socket: c)
            case nil: break
            }
        }
    }

    /// Session queue, every 100 ms tick: one `getsockopt` per sampled socket every `tcpInfoTickInterval` ticks.
    private func tcpInfoTick() {
        guard !tcpInfoSamplers.isEmpty else {
            tcpInfoTicks = 0
            return
        }
        tcpInfoTicks += 1
        guard tcpInfoTicks >= Self.tcpInfoTickInterval else { return }
        tcpInfoTicks = 0
        // Control first, then video; stable order within a role.
        let ids = tcpInfoSamplers.sorted { a, b in
            a.value.role == b.value.role ? a.key.raw < b.key.raw : a.value.role == .control
        }.map(\.key)
        for id in ids { logTcpInfo(id, closeWindow: true, trigger: nil) }
    }

    /// Session queue: `I net ev=tcp` (window close) or `D net ev=tcp_snap trigger=…` (between windows) for `id`;
    /// `W net ev=tcp_unavailable` once per connection when the socket cannot be read.
    private func logTcpInfo(_ id: ConnectionID, closeWindow: Bool, trigger: String?) {
        guard let sampler = tcpInfoSamplers[id], let report = sampler.read(closeWindow: closeWindow) else { return }
        switch report {
        case .reading(let r):
            var fields = r.logFields(role: sampler.role, connectionID: id.raw)
            if closeWindow {
                fields += " transport=\(activeTransport.logName)"
                netLogger.log(.info, "tcp", sessionID: currentSessionID, generation: currentConfigID, fields: fields)
            } else {
                fields += " trigger=\(trigger ?? "na")"
                netLogger.log(.debug, "tcp_snap", sessionID: currentSessionID, generation: currentConfigID,
                              fields: fields)
            }
        case .unavailable(let reason):
            netLogger.log(.warning, "tcp_unavailable", sessionID: currentSessionID, generation: currentConfigID,
                          fields: "conn=\(sampler.role.rawValue) conn_id=\(id.raw) reason=\(reason)")
        }
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
            tcpInfoTick()
        }
        timer.resume()
        tickTimer = timer
    }
}

extension SessionServer: AudioSink {
    public func takeAudioWireDrops() -> Int { audioWireDrops.exchange(0, ordering: .relaxed) }
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
