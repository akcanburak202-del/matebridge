import XCTest
@testable import MateBridgeCore

final class UsbTunnelPlannerTests: XCTestCase {
    private let ready = AdbDevice(serial: "ABC123", state: "device")

    func testNoAdb() {
        var p = UsbTunnelPlanner()
        let d = p.decide(UsbSnapshot(adbFound: false, serverUp: false))
        XCTAssertEqual(d.state, .noAdb)
        XCTAssertNil(d.action)
        XCTAssertEqual(d.stateChange, .noAdb)
        XCTAssertEqual(p.nextDelay, UsbTunnelPlanner.noAdbDelay)
    }

    func testServerDownStartsServer() {
        var p = UsbTunnelPlanner()
        let d = p.decide(UsbSnapshot(adbFound: true, serverUp: false))
        XCTAssertEqual(d.state, .down)
        XCTAssertEqual(d.action, .startServer)
    }

    func testNoDeviceAndUnauthorizedDeviceDoNothing() {
        var p = UsbTunnelPlanner()
        XCTAssertNil(p.decide(UsbSnapshot(adbFound: true, serverUp: true)).action)
        let d = p.decide(UsbSnapshot(adbFound: true, serverUp: true,
                                     devices: [AdbDevice(serial: "X", state: "unauthorized")]))
        XCTAssertEqual(d.state, .noDevice)
        XCTAssertNil(d.action)
    }

    func testMissingTunnelsAreInstalled() {
        var p = UsbTunnelPlanner()
        let d = p.decide(UsbSnapshot(adbFound: true, serverUp: true, devices: [ready], presentTunnels: [47001]))
        XCTAssertEqual(d.state, .down)
        XCTAssertEqual(d.action, .installTunnels([47002]))
        let all = p.decide(UsbSnapshot(adbFound: true, serverUp: true, devices: [ready]))
        XCTAssertEqual(all.action, .installTunnels([47001, 47002]))
    }

    func testAllTunnelsPresentIsUpWithNoAction() {
        var p = UsbTunnelPlanner()
        let d = p.decide(UsbSnapshot(adbFound: true, serverUp: true, devices: [ready], presentTunnels: [47001, 47002, 9]))
        XCTAssertEqual(d.state, .up)
        XCTAssertNil(d.action)
    }

    func testStateChangeReportedOnlyOnTransition() {
        var p = UsbTunnelPlanner()
        let up = UsbSnapshot(adbFound: true, serverUp: true, devices: [ready], presentTunnels: [47001, 47002])
        XCTAssertEqual(p.decide(up).stateChange, .up)
        XCTAssertNil(p.decide(up).stateChange)
        XCTAssertEqual(p.decide(UsbSnapshot(adbFound: true, serverUp: true)).stateChange, .noDevice)  // cable pulled
        XCTAssertEqual(p.decide(UsbSnapshot(adbFound: true, serverUp: true, devices: [ready])).stateChange, .down)
        XCTAssertEqual(p.decide(up).stateChange, .up)
        p.reset()
        XCTAssertEqual(p.decide(up).stateChange, .up)
    }

    func testBackoffDoublesAndCapsThenResets() {
        var p = UsbTunnelPlanner()
        _ = p.decide(UsbSnapshot(adbFound: true, serverUp: false))
        XCTAssertEqual(p.nextDelay, 2)
        var seen: [Double] = []
        for _ in 0..<7 {
            p.actionFinished(success: false)
            seen.append(p.nextDelay)
        }
        XCTAssertEqual(seen, [4, 8, 16, 30, 30, 30, 30])
        p.actionFinished(success: true)
        XCTAssertEqual(p.nextDelay, 2)
    }

    func testHealthyProbeEndsBackoff() {
        var p = UsbTunnelPlanner()
        _ = p.decide(UsbSnapshot(adbFound: true, serverUp: false))
        p.actionFinished(success: false)
        _ = p.decide(UsbSnapshot(adbFound: true, serverUp: true, devices: [AdbDevice(serial: "ABC", state: "unauthorized")]))
        XCTAssertEqual(p.nextDelay, 2)
    }

    func testIdleDelayDependsOnUsbEvents() {
        var p = UsbTunnelPlanner()
        _ = p.decide(UsbSnapshot(adbFound: true, serverUp: true))
        XCTAssertEqual(p.nextDelay, UsbTunnelPlanner.idlePollingDelay)
        p.usbEventsAvailable = true
        XCTAssertEqual(p.nextDelay, UsbTunnelPlanner.idleEventDrivenDelay)
    }

    func testNetworkOnlyDeviceIsStillIdle() {
        var p = UsbTunnelPlanner()
        p.usbEventsAvailable = true
        _ = p.decide(UsbSnapshot(adbFound: true, serverUp: true, devices: [AdbDevice(serial: "10.0.0.2:5555", state: "device")]))
        XCTAssertEqual(p.nextDelay, UsbTunnelPlanner.idleEventDrivenDelay)
    }

    func testUnauthorizedDeviceKeepsBaseRate() {
        var p = UsbTunnelPlanner()
        p.usbEventsAvailable = true
        _ = p.decide(UsbSnapshot(adbFound: true, serverUp: true, devices: [AdbDevice(serial: "ABC", state: "unauthorized")]))
        XCTAssertEqual(p.nextDelay, UsbTunnelPlanner.baseDelay)
    }

    func testCableAttachedKeepsBaseRate() {
        var p = UsbTunnelPlanner()
        p.usbEventsAvailable = true
        let up = UsbSnapshot(adbFound: true, serverUp: true, devices: [AdbDevice(serial: "ABC", state: "device")],
                             presentTunnels: [DefaultPorts.control, DefaultPorts.video])
        _ = p.decide(up)
        XCTAssertEqual(p.nextDelay, UsbTunnelPlanner.baseDelay)
    }

    func testUsbEventBurstThenBackToIdle() {
        var p = UsbTunnelPlanner()
        p.usbEventsAvailable = true
        let idle = UsbSnapshot(adbFound: true, serverUp: true)
        _ = p.decide(idle)
        p.noteUsbEvent()
        for _ in 0..<(UsbTunnelPlanner.burstProbes - 1) {
            _ = p.decide(idle)
            XCTAssertEqual(p.nextDelay, UsbTunnelPlanner.baseDelay)
        }
        _ = p.decide(idle)
        XCTAssertEqual(p.nextDelay, UsbTunnelPlanner.idleEventDrivenDelay)
    }

    func testTransportClassification() {
        XCTAssertEqual(SessionTransport.classify(peerHost: "127.0.0.1"), .usb)
        XCTAssertEqual(SessionTransport.classify(peerHost: "::1"), .usb)
        XCTAssertEqual(SessionTransport.classify(peerHost: "::ffff:127.0.0.1"), .usb)
        XCTAssertEqual(SessionTransport.classify(peerHost: "fe80::1%en0"), .network)
        XCTAssertEqual(SessionTransport.classify(peerHost: "192.168.1.20"), .network)
        XCTAssertEqual(SessionTransport.classify(peerHost: nil), .network)
    }
}

final class UsbTunnelPlannerStartTests: XCTestCase {
    func testStartWithDevicePresentFirstProbeEmptyFollowsUpAtBaseRate() {
        var p = UsbTunnelPlanner()
        p.reset()
        p.usbEventsAvailable = true
        p.noteUsbEvent()  // watcher start seeds the burst
        // The burst counts the first probe too: it is followed by burstProbes - 1 probes at the base rate.
        for _ in 0..<(UsbTunnelPlanner.burstProbes - 1) {
            _ = p.decide(UsbSnapshot(adbFound: true, serverUp: true))  // adb has not enumerated the tablet yet
            XCTAssertEqual(p.nextDelay, UsbTunnelPlanner.baseDelay)
        }
        _ = p.decide(UsbSnapshot(adbFound: true, serverUp: true))
        XCTAssertEqual(p.nextDelay, UsbTunnelPlanner.idleEventDrivenDelay)
    }
}

final class UsbEventCoalescerTests: XCTestCase {
    func testEventBurstEvery100msStillProbes() {
        var c = UsbEventCoalescer()
        var due: TimeInterval?
        var probes = 0
        var t: TimeInterval = 0
        while t < 5.0 {
            if let d = due, d <= t + 1e-9 { c.probeStarted(); due = nil; probes += 1 }
            if let delay = c.noteEvent() { due = t + delay }
            t += 0.1
        }
        XCTAssertGreaterThanOrEqual(probes, 10)
    }

    func testSecondEventDoesNotPostponePending() {
        var c = UsbEventCoalescer()
        XCTAssertEqual(c.noteEvent(), UsbEventCoalescer.settleDelay)
        XCTAssertNil(c.noteEvent())
        c.probeStarted()
        XCTAssertNotNil(c.noteEvent())
    }

    func testResetOnToggleLetsNewEventSchedule() {
        var c = UsbEventCoalescer()
        XCTAssertNotNil(c.noteEvent())  // probe pending
        c.reset()                       // disable/enable transition
        XCTAssertEqual(c.noteEvent(), UsbEventCoalescer.settleDelay)  // attach after re-enable schedules
    }
}
