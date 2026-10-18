import AppKit
import CoreGraphics
import Dispatch
import Foundation
import MateBridgeCore

/// What the tablet camera needs from the live session (decision 0040, T-354). `SessionServer` is the implementation.
public protocol CameraLink: AnyObject, Sendable {
    /// Peer address of the active session's control connection.
    func controlPeerHost(sessionID: UInt32) -> String?
    /// Keys of the camera connection, from the active session's `prk` and the two fresh nonces.
    func cameraKeys(sessionID: UInt32, clientNonce: [UInt8], hostNonce: [UInt8]) -> CameraKeys?
    /// A host-initiated control message (`CAMERA_CONTROL`).
    func sendToSession(sessionID: UInt32, _ message: Message)
}

extension SessionServer: CameraLink {}

/// The Mac side of the tablet camera (decision 0040): runs `CameraController` (Core) on its own serial queue and does what
/// it asks. A virtual camera (the OBS Virtual Camera) is the target; an H.264 stream from the tablet is decoded and
/// written into it while some app uses it.
///
/// With `CAMERA_PREFS` OFF, or without the `CAMERA` capability, nothing here exists: no CMIO listener, no timer, no
/// listener socket, no decoder (the controller never asks for them). Never requests camera access and opens no window.
public final class CameraBridge: @unchecked Sendable {
    /// What the menu shows: whether the manual "camera is in use" item is relevant, and its state.
    public struct MenuState: Equatable, Sendable {
        public var visible: Bool
        public var manualOn: Bool
    }

    private let queue = DispatchQueue(label: "dev.matebridge.camera", qos: .userInitiated)
    private let logger = SessionLogger(component: "camera")
    private let obs = ObsVirtualCamera()
    private let service = CameraConnectionService()
    private let idleUs: UInt64

    // Everything below is confined to `queue`.
    private weak var link: (any CameraLink)?
    private var controller = CameraController()
    private var tracker: CameraUsageTracker
    private var sessionID: UInt32 = 0
    private var usbSession = false
    private var manual = false
    private var lastPushedUsage: Bool?
    private var timer: DispatchSourceTimer?
    private var audit: CameraIdleAudit
    private var sleepObservers: [NSObjectProtocol] = []
    private var reportedMenu = MenuState(visible: false, manualOn: false)

    /// Called on the camera queue whenever the menu state changes.
    public var onMenuChange: (@Sendable (MenuState) -> Void)?

    public init() {
        idleUs = CameraKnobs.idleUs(ProcessInfo.processInfo.environment[CameraKnobs.idleVariable])
        tracker = CameraUsageTracker()
        audit = CameraIdleAudit(idleUs: idleUs)
        wire()
    }

    private func wire() {
        let obs = self.obs
        let queue = self.queue
        service.sink = { [weak self] frame in
            guard let strong = self else { return }
            obs.write(frame) { queue.async { strong.sinkStarted() } }
        }
        service.sinkCounters = { obs.takeSinkCounters() }
        service.onActive = { [weak self] active in
            guard let strong = self else { return }
            queue.async { strong.connectionActive(active) }
        }
    }

    // MARK: - Events (any thread)

    public func attach(link: any CameraLink) {
        queue.async { [self] in self.link = link }
    }

    /// A session became active. Without `HELLO` bit15 `CAMERA` the camera never does anything in it.
    public func sessionStarted(sessionID: UInt32, transport: SessionTransport, capabilities: Capabilities) {
        queue.async { [self] in
            self.sessionID = sessionID
            usbSession = transport == .usb
            if usbSession, capabilities.contains(.camera) {
                // The camera port is not part of the `adb reverse` set: the tablet could not reach it (T-354 open question).
                logger.log(.info, "camera", sessionID: sessionID, generation: 0, fields: "state=usb_not_supported")
            }
            resetTracker()
            apply(controller.sessionStarted(clientHasCamera: capabilities.contains(.camera), now: HostClock.nowUs()))
        }
    }

    /// The session ended (BYE, HOST_SLEEP, takeover, connection loss): nothing is sent, everything closes.
    public func sessionEnded() {
        queue.async { [self] in
            apply(controller.sessionEnded())
            resetTracker()
            sessionID = 0
            usbSession = false
            publishMenu()
        }
    }

    /// Every delivered message; `CAMERA_PREFS` and `STREAM_PREFS.link` matter here.
    public func deliver(_ message: Message) {
        switch message {
        case .cameraPrefs(let prefs):
            queue.async { [self] in apply(controller.prefs(prefs, now: HostClock.nowUs())) }
        case .streamPrefs(let prefs):
            let remote = prefs.isRemote
            queue.async { [self] in apply(controller.link(remote: remote, now: HostClock.nowUs())) }
        default:
            break
        }
    }

    /// The manual "camera is in use" menu item: the fallback if usage cannot be detected. Holds the usage on and turns the
    /// probes off. Only effective while the camera is AUTO.
    public func setManualUse(_ on: Bool) {
        queue.async { [self] in
            manual = on
            handle(tracker.setManual(on, now: HostClock.nowUs()))
            pushUsage()
            reschedule()
            publishMenu()
        }
    }

    /// Menu bar quit: closes everything, bounded.
    public func shutdown() {
        queue.sync {
            apply(controller.sessionEnded())
            resetTracker()
        }
    }

    // MARK: - Decisions (on queue)

    private func apply(_ actions: [CameraController.Action]) {
        for action in actions {
            switch action {
            case .openListener(let camID):
                openListener(camID: camID)
            case .closeListener:
                service.close()
                obs.stopSink()
                handle(tracker.sinkWriting(false, now: HostClock.nowUs()))
                audit.reset()
            case .send(let control):
                if sessionID != 0 { link?.sendToSession(sessionID: sessionID, .cameraControl(control)) }
            case .watchEnvironment(let on):
                if on {
                    lastPushedUsage = nil
                    obs.startMonitoring(handlerQueue: queue) { [weak self] env in self?.environment(env) }
                    observeSleep()
                } else {
                    obs.stopMonitoring()
                    stopObservingSleep()
                    lastPushedUsage = nil
                }
            case .log(let level, let ev, let fields):
                logger.log(level, ev, sessionID: sessionID, generation: controller.currentCamID ?? 0, fields: fields)
            }
        }
        reschedule()
        publishMenu()
    }

    private func openListener(camID: UInt16) {
        guard let link, sessionID != 0, let peer = link.controlPeerHost(sessionID: sessionID) else {
            apply(controller.listenerFailed(now: HostClock.nowUs()))
            return
        }
        let port = service.open(sessionID: sessionID, camID: camID, controlPeer: peer) { [weak link] sid, client, host in
            link?.cameraKeys(sessionID: sid, clientNonce: client, hostNonce: host)
        }
        if let port {
            apply(controller.listenerOpened(port: port, now: HostClock.nowUs()))
        } else {
            apply(controller.listenerFailed(now: HostClock.nowUs()))
        }
    }

    /// The watcher's view of the virtual camera: device presence and `IsRunningSomewhere`.
    private func environment(_ env: ObsVirtualCamera.Environment) {
        guard controller.isWatching else { return }
        // A USB session cannot reach the camera port: report the target as missing so the tablet shows UNAVAILABLE.
        apply(controller.deviceAvailable(env.deviceAvailable && !usbSession, now: HostClock.nowUs()))
        handle(tracker.running(env.running, now: HostClock.nowUs()))
        pushUsage()
        reschedule()
    }

    private func handle(_ actions: [CameraUsageTracker.Action]) {
        for action in actions {
            switch action {
            case .pauseSink: obs.pauseSink()
            case .resumeSink: obs.resumeSink()
            }
        }
    }

    private func pushUsage() {
        guard controller.isWatching else { return }
        let inUse = tracker.inUse
        guard lastPushedUsage != inUse else { return }
        lastPushedUsage = inUse
        apply(controller.usage(inUse, now: HostClock.nowUs()))
    }

    /// The first decoded frame (or the first after a probe pause) reached the sink: the raw property is now polluted by us.
    private func sinkStarted() {
        guard service.isRunning else { return }
        handle(tracker.sinkWriting(true, now: HostClock.nowUs()))
        pushUsage()
        reschedule()
    }

    /// The camera connection became active (true) or the active one ended (false).
    private func connectionActive(_ active: Bool) {
        guard !active, service.isRunning else { return }
        // No frames any more: stop writing so the raw property shows other clients only.
        obs.stopSink()
        handle(tracker.sinkWriting(false, now: HostClock.nowUs()))
        audit.reset()
        pushUsage()
        reschedule()
    }

    private func resetTracker() {
        obs.stopSink()
        tracker = CameraUsageTracker()
        audit.reset()
        _ = tracker.setManual(manual, now: HostClock.nowUs())
        lastPushedUsage = nil
    }

    // MARK: - Time (on queue)

    /// Seconds since the last user input of any kind on the Mac (combined session).
    private func inputIdleUs() -> UInt64 {
        let anyInput = CGEventType(rawValue: ~0)!
        let seconds = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
        return seconds.isFinite && seconds > 0 ? UInt64(seconds * 1_000_000) : 0
    }

    /// Sleep and display sleep are the moments to ask whether the camera is still used (only while the camera is on).
    private func observeSleep() {
        guard sleepObservers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification] {
            sleepObservers.append(center.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                guard let self else { return }
                self.queue.async { self.macSleeping() }
            })
        }
    }

    private func stopObservingSleep() {
        let center = NSWorkspace.shared.notificationCenter
        for o in sleepObservers { center.removeObserver(o) }
        sleepObservers = []
    }

    private func macSleeping() {
        guard controller.isWatching else { return }
        if audit.sleeping(now: HostClock.nowUs(), canProbe: tracker.canProbe) {
            logger.log(.info, "camera", sessionID: sessionID, generation: controller.currentCamID ?? 0,
                       fields: "state=probe reason=sleep")
            handle(tracker.startProbe(now: HostClock.nowUs()))
            reschedule()
        }
    }

    /// One one-shot timer for the earliest deadline of the controller (usage filter), the tracker (probe settle) and the
    /// idle audit. No deadline, no timer: with the camera off nothing wakes up.
    private func reschedule() {
        timer?.cancel()
        timer = nil
        guard controller.isWatching else { return }
        let now = HostClock.nowUs()
        let idleAt = audit.nextDeadline(now: now, canProbe: tracker.canProbe, inputIdleUs: inputIdleUs())
        let deadlines = [controller.nextDeadline, tracker.nextDeadline, idleAt].compactMap { $0 }
        guard let next = deadlines.min() else { return }
        let delay = next > now ? Int(min(next - now, 600_000_000)) : 0
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + .microseconds(delay))
        t.setEventHandler { [weak self] in self?.fire() }
        timer = t
        t.activate()
    }

    private func fire() {
        timer = nil
        let now = HostClock.nowUs()
        if tracker.isProbing {
            // The settle time ran out: read the property now instead of trusting the listener's latency.
            _ = tracker.running(obs.readRunning(), now: now)
        }
        handle(tracker.tick(now: now))
        if controller.isWatching, audit.due(now: now, canProbe: tracker.canProbe, inputIdleUs: inputIdleUs()) {
            logger.log(.info, "camera", sessionID: sessionID, generation: controller.currentCamID ?? 0,
                       fields: "state=probe reason=idle")
            handle(tracker.startProbe(now: now))
        }
        pushUsage()
        apply(controller.tick(now: now))
    }

    private func publishMenu() {
        let state = MenuState(visible: controller.isEnabled, manualOn: manual && controller.isEnabled)
        guard state != reportedMenu else { return }
        reportedMenu = state
        onMenuChange?(state)
    }
}
