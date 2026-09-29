import Foundation
import MateBridgeCore
import Network

/// A validated video connection handed to the video pipeline (PROTOCOL.md section 3.5).
/// Send-only from the host's point of view; `cancel()` closes just this connection.
public final class VideoLink: @unchecked Sendable {
    public let sessionID: UInt32
    public let configID: UInt16
    private let connection: NWConnection

    fileprivate init(sessionID: UInt32, configID: UInt16, connection: NWConnection) {
        self.sessionID = sessionID
        self.configID = configID
        self.connection = connection
    }

    public func send(_ bytes: [UInt8], completion: @escaping @Sendable (Bool) -> Void = { _ in }) {
        connection.send(content: Data(bytes), completion: .contentProcessed { completion($0 == nil) })
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
    public let deviceName: String
}

/// TCP control and video listeners plus Bonjour, driving a `SessionMachine`.
/// All state is confined to `queue`; handlers are invoked on that queue (hop to the main actor yourself).
public final class SessionServer: @unchecked Sendable {
    public struct Handlers: Sendable {
        public var stateChanged: @Sendable (SessionServerState) -> Void = { _ in }
        public var approvalRequested: @Sendable (ApprovalRequest) -> Void = { _ in }
        public var approvalCancelled: @Sendable () -> Void = {}
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

    /// - Parameters:
    ///   - controlPort: 0 lets the system pick (found via Bonjour). A fixed port is needed for `adb reverse`.
    ///   - makeStreamConfig: placeholder until the video pipeline (T-011) supplies the real configuration.
    public init(handlers: Handlers, store: ApprovedDeviceStore = ApprovedDeviceStore(directory: ApprovedDeviceStore.defaultDirectory()),
                hostName: String = Host.current().localizedName ?? "Mac", controlPort: UInt16 = 0,
                makeStreamConfig: @escaping @Sendable (Hello) -> StreamConfig = SessionServer.defaultStreamConfig) {
        self.handlers = handlers
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
            guard controlListener == nil else { return }
            setState(.starting)
            do {
                let video = try NWListener(using: Self.tcpParameters())
                video.newConnectionHandler = { [weak self] c in self?.accept(c, video: true) }
                video.stateUpdateHandler = { [weak self] s in self?.videoListenerState(s) }
                videoListener = video
                video.start(queue: queue)
            } catch {
                fail("video_listener_create")
            }
            startTicking()
        }
    }

    /// Blocks until input is released and every peer got BYE(SHUTTING_DOWN).
    public func stop() {
        queue.sync {
            apply(machine.shutdown())
            tickTimer?.cancel()
            tickTimer = nil
            controlListener?.cancel()
            videoListener?.cancel()
            controlListener = nil
            videoListener = nil
            setState(.stopped)
        }
    }

    public func resolveApproval(approved: Bool) {
        queue.async { [self] in
            guard let id = pendingApproval else { return }
            pendingApproval = nil
            apply(machine.approvalDecided(id, approved: approved, now: nowUs()))
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
            fail("video_listener_failed")
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
            listener.stateUpdateHandler = { [weak self] s in
                guard let self else { return }
                switch s {
                case .ready:
                    logger.log(.info, "listening", sessionID: 0, generation: 0,
                               fields: "control_port=\(listener.port?.rawValue ?? 0) video_port=\(videoPort)")
                    if case .starting = state { setState(.listening) }
                case .failed: fail("control_listener_failed")
                default: break
                }
            }
            controlListener = listener
            listener.start(queue: queue)
        } catch {
            fail("control_listener_create")
        }
    }

    private func fail(_ what: String) {
        logger.log(.error, what, sessionID: 0, generation: 0)
        setState(.failed(what))
    }

    // MARK: Connections

    private func accept(_ connection: NWConnection, video: Bool) {
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
                decoder.append([UInt8](data))
                do {
                    while let message = try decoder.nextMessage() {
                        if video { handleVideo(id, message) } else {
                            apply(machine.received(id, message, now: nowUs()))
                        }
                    }
                } catch {
                    logger.log(.warning, "decode_error", sessionID: currentSessionID, generation: currentConfigID,
                               fields: "video=\(video)")
                    if video { closeVideo(id) } else { apply(machine.protocolError(id)) }
                    return
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

    private func handleVideo(_ id: ConnectionID, _ message: Message) {
        // Only VIDEO_HELLO is valid C->H on the video connection; a second one or anything else is an error.
        if case .videoHello(let hello) = message, videoLinks[id] == nil {
            apply(machine.videoHello(id, hello, now: nowUs()))
        } else {
            closeVideo(id)
        }
    }

    private var videoLinks: [ConnectionID: VideoLink] = [:]

    /// The transport is gone (peer closed, error, or we cancelled it). Idempotent.
    private func transportClosed(_ id: ConnectionID, video: Bool) {
        if video {
            guard videoConnections.removeValue(forKey: id) != nil else { return }
            videoLinks[id] = nil
            apply(machine.videoClosed(id))
        } else {
            guard controlConnections.removeValue(forKey: id) != nil else { return }
            apply(machine.connectionClosed(id))
        }
    }

    private func closeVideo(_ id: ConnectionID) {
        guard let c = videoConnections[id] else { return }
        c.cancel()  // stateUpdateHandler(.cancelled) -> transportClosed
    }

    private func closeControl(_ id: ConnectionID) {
        guard let c = controlConnections.removeValue(forKey: id) else { return }
        // Queued sends (BYE, REJECTED) are flushed before the FIN, then the socket is cancelled.
        c.send(content: nil, contentContext: .finalMessage, isComplete: true,
               completion: .contentProcessed { _ in c.cancel() })
    }

    // MARK: Applying machine actions

    private func apply(_ actions: [SessionAction]) {
        for action in actions {
            switch action {
            case .send(let id, let message):
                guard let c = controlConnections[id], let bytes = try? message.encode() else { break }
                c.send(content: Data(bytes), completion: .contentProcessed { _ in })
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
                handlers.approvalRequested(ApprovalRequest(deviceName: name))
            case .cancelApproval(let id):
                if pendingApproval == id {
                    pendingApproval = nil
                    handlers.approvalCancelled()
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
                    let link = VideoLink(sessionID: sid, configID: configID, connection: c)
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
