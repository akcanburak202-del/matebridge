import Testing
@testable import MateBridgeCore

// PIPE-S-*: every release-all trigger of PROTOCOL.md section 7, driven through the real `SessionMachine` and applied
// to the input pipeline the way the Host wires it (`SessionServer` handlers -> `InputController`):
//   .deliver -> handle, .releaseInput -> release, .sessionStarted -> sessionStarted, .sessionEnded -> sessionEnded.
// Each trigger is run with the display present, the display gone and the permission missing, with a pen contact, a
// right button and an open scroll held. Afterwards the Mac model must be idle. What this cannot cover is the Host's
// own mapping (main.swift closures, the InputController queue and timers); that mapping is one line per handler and is
// listed in the T-023 handoff for the live check.

private let A = ConnectionID(1)
private let B = ConnectionID(2)
private let sec: UInt64 = 1_000_000

private func deviceID(_ n: UInt8) -> DeviceID { DeviceID(bytes: [UInt8](repeating: n, count: 16))! }

private func helloMessage(_ n: UInt8 = 1) -> Message {
    .hello(Hello(deviceID: deviceID(n), screenWidthPx: 2800, screenHeightPx: 1840, densityDpi: 360, maxRefreshHz: 144,
                 capabilities: [.pen, .touch], deviceName: "Pad"))
}

private let wiringConfig = StreamConfig(configID: 1, codec: .hevc, widthPx: 2800, heightPx: 1840, widthPt: 1400,
                                        heightPt: 920, fps: 60, bitrateKbps: 40_000, colorPrimaries: 1, transfer: 13,
                                        matrix: 1, fullRange: true)

/// A `SessionMachine` and an `InputPipeline` joined by the same mapping the Host uses.
private struct WiredSession {
    var session = SessionMachine(configuration: .init(hostName: "Mac", makeStreamConfig: { _ in wiringConfig },
                                                      makeSessionID: { 42 }), approvedDevices: [deviceID(1)])
    var pipe = InputPipeline()
    var model = MacEventModel()
    var now: UInt64 = 10 * sec
    var env = openEnv
    /// Release causes that reached the pipeline, in order.
    var causes: [ReleaseCause] = []

    /// What the Mac receives: events posted while the permission is there. Without it macOS drops them, and the
    /// controller reports the closing ones back as owed.
    mutating func deliver(_ events: [MacEvent]) {
        if events.contains(where: \.isClosing), !env.canInject {
            pipe.postFailed(events, now: now, permitted: false)
        } else if env.canInject {
            model.apply(events)
        }
    }

    mutating func apply(_ actions: [SessionAction]) {
        for action in actions {
            switch action {
            case .releaseInput(_, let cause):
                causes.append(cause)
                deliver(pipe.release(cause, now: now, environment: env))
            case .deliver(_, let message):
                deliver(pipe.handle(message, now: now, environment: env))
            case .sessionStarted:
                deliver(pipe.sessionStarted(now: now, environment: env))
            case .sessionEnded:
                deliver(pipe.sessionEnded(now: now, environment: env))
            default: break
            }
        }
    }

    /// HELLO from a pre-approved device: the session starts.
    mutating func connect(_ id: ConnectionID = A, device: UInt8 = 1) {
        apply(session.connectionOpened(id, now: now))
        apply(session.received(id, helloMessage(device), now: now))
    }

    mutating func receive(_ message: Message, on id: ConnectionID = A, after: UInt64 = 1_000) {
        now += after
        apply(session.received(id, message, now: now))
    }

    /// Pen touching + right button + an open scroll gesture, all delivered by the session.
    mutating func holdEverything() {
        receive(penMsg(.pen, penSample(1000, 2000, hoverFlags)))
        receive(penMsg(.pen, penSample(1010, 2010, startFlags, pressure: 500)))
        receive(relMsg(0, 0, .right))
        receive(scrollMsg(.began, 0, 3))
        precondition(model.penContact && model.buttons == [.right] && model.scrollOpen)
    }
}

private enum Trigger: CaseIterable, CustomStringConvertible, Sendable {
    case releaseAllMessage, byeReceived, connectionLost, protocolError, heartbeatSilence, heartbeatTimeout, takeover, shutdown

    var description: String {
        switch self {
        case .releaseAllMessage: "RELEASE_ALL message"
        case .byeReceived: "BYE received"
        case .connectionLost: "connection lost"
        case .protocolError: "protocol error"
        case .heartbeatSilence: "1.5 s heartbeat silence"
        case .heartbeatTimeout: "5 s heartbeat timeout"
        case .takeover: "session takeover"
        case .shutdown: "app shutdown"
        }
    }

    /// The cause the session machine must hand to `releaseInput`.
    var expectedCause: ReleaseCause {
        switch self {
        case .releaseAllMessage: .clientRequest(.background)
        case .byeReceived: .bye
        case .connectionLost: .disconnected
        case .protocolError: .protocolError
        case .heartbeatSilence: .silence
        case .heartbeatTimeout: .timeout
        case .takeover: .superseded
        case .shutdown: .shutdown
        }
    }
}

private enum Gate: CaseIterable, CustomStringConvertible, Sendable {
    case open, displayGone, permissionMissing

    var description: String {
        switch self {
        case .open: "gate open"
        case .displayGone: "virtual display gone"
        case .permissionMissing: "Accessibility permission missing"
        }
    }

    var environment: InjectionEnvironment {
        switch self {
        case .open: openEnv
        case .displayGone: noDisplayEnv
        case .permissionMissing: noPermissionEnv
        }
    }
}

@Suite("PIPE-S: release-all triggers through the session machine")
struct SessionInputWiringTests {
    @Test("PIPE-S-1 every trigger releases everything held, whatever the gate is doing at that moment",
          arguments: Trigger.allCases, Gate.allCases)
    fileprivate func pipeS1_everyTrigger(_ trigger: Trigger, _ gate: Gate) {
        var w = WiredSession()
        w.connect()
        w.holdEverything()
        w.env = gate.environment
        switch trigger {
        case .releaseAllMessage: w.receive(.releaseAll(.background))
        case .byeReceived: w.receive(.bye(.normal))
        case .connectionLost: w.apply(w.session.connectionClosed(A))
        case .protocolError: w.apply(w.session.protocolError(A))
        case .heartbeatSilence:
            w.now += 1_500_000
            w.apply(w.session.tick(now: w.now))
        case .heartbeatTimeout:
            w.now += 5 * sec
            w.apply(w.session.tick(now: w.now))
        case .takeover:
            w.apply(w.session.connectionOpened(B, now: w.now))
            w.receive(helloMessage(1), on: B)
        case .shutdown: w.apply(w.session.shutdown())
        }
        #expect(w.causes.first == trigger.expectedCause, "\(trigger) reached the pipeline as \(String(describing: w.causes.first))")
        #expect(!w.pipe.planner.isHoldingInput)
        if gate == .permissionMissing {
            // Without the permission nothing can reach the Mac; the release is owed and goes out when it is back.
            #expect(!w.model.isIdle && w.pipe.owed.count == 4, "\(trigger): owed \(w.pipe.owed.count)")
            w.env = openEnv
            w.now += 1_000
            w.deliver(w.pipe.tick(now: w.now, environment: w.env))
        }
        #expect(w.model.isIdle, "\(trigger) / \(gate): the Mac still holds input")
        #expect(w.model.violations.isEmpty && w.pipe.owed.isEmpty)
    }

    @Test("PIPE-S-2 takeover: the new session starts with a fresh machine, so a stale mid-stroke sample is no stroke")
    func pipeS2_takeoverFresh() {
        var w = WiredSession()
        w.connect()
        w.holdEverything()
        w.apply(w.session.connectionOpened(B, now: w.now))
        w.receive(helloMessage(1), on: B)
        #expect(w.causes == [.superseded])
        #expect(w.model.isIdle && w.pipe.hasSession)
        // The tablet's old stroke is still going on when the new connection is up.
        w.receive(penMsg(.pen, penSample(1020, 2020, touchFlags, pressure: 500)), on: B)
        #expect(w.model.violations.isEmpty)
        #expect(!w.model.penContact)
        // The old connection's late traffic is ignored by the session machine and cannot reach the pipeline.
        w.receive(penMsg(.pen, penSample(1030, 2030, startFlags, pressure: 500)), on: A)
        #expect(!w.model.penContact)
        w.receive(penMsg(.pen, penSample(1040, 2040, startFlags, pressure: 500)), on: B)
        #expect(w.model.penContact)
    }

    @Test("PIPE-S-3 a session that ends and one that follows leave nothing behind between them")
    func pipeS3_reconnect() {
        var w = WiredSession()
        for round in 0..<3 {
            w.connect(A, device: 1)
            w.holdEverything()
            w.apply(w.session.connectionClosed(A))
            #expect(w.model.isIdle, "round \(round)")
            #expect(!w.pipe.hasSession)
        }
        #expect(w.causes == [.disconnected, .disconnected, .disconnected])
    }

    @Test("PIPE-S-4 input before ACCEPTED never reaches the pipeline (PROTOCOL.md section 3)")
    func pipeS4_beforeAccepted() {
        var w = WiredSession()
        w.apply(w.session.connectionOpened(A, now: w.now))
        w.receive(penMsg(.pen, penSample(1, 1, hoverFlags)))
        #expect(w.model.isIdle && !w.pipe.hasSession)
    }
}
