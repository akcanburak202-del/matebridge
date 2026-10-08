import XCTest
@testable import MateBridgeCore

private func device(_ n: UInt8) -> DeviceID { DeviceID(bytes: [UInt8](repeating: n, count: 16))! }

/// The display lease state machine (T-165, T-214; the B11 merge of the old create/grace tests into the parked ones).
final class DisplayLeaseTests: XCTestCase {
    private let sec: UInt64 = 1_000_000
    private let s = VideoSettings.tabletDefault

    func testDifferentDeviceOrSettingsReplacesDisplay() {
        var l = DisplayLease()
        _ = l.sessionStarted(device: device(1), settings: s)
        l.sessionEnded(now: 0)
        XCTAssertEqual(l.sessionStarted(device: device(2), settings: s), [.teardown(.deviceChanged), .create(s)])
        l.sessionEnded(now: 0)
        var other = s
        other.widthPx = 1920
        XCTAssertEqual(l.sessionStarted(device: device(2), settings: other), [.teardown(.sizeChanged), .create(other)])
    }

    func testTakeoverWithoutEndKeepsDisplay() {
        var l = DisplayLease()
        _ = l.sessionStarted(device: device(1), settings: s)
        XCTAssertEqual(l.sessionStarted(device: device(1), settings: s), [.reuse])
    }

    func testShutdownAndDisplayLost() {
        var l = DisplayLease()
        XCTAssertTrue(l.shutdown().isEmpty)
        _ = l.sessionStarted(device: device(1), settings: s)
        XCTAssertEqual(l.shutdown(), [.teardown(.shutdown)])
        _ = l.sessionStarted(device: device(1), settings: s)
        l.displayLost()
        XCTAssertEqual(l.sessionStarted(device: device(1), settings: s), [.create(s)], "a dead display is recreated")
    }

    // MARK: Parked display (T-165)

    func testSessionEndParksAndKeepExpiryTearsDownOnce() {
        var l = DisplayLease()
        _ = l.sessionStarted(device: device(1), settings: s)
        XCTAssertEqual(l.sessionEnded(now: 100 * sec), [.park])
        XCTAssertTrue(l.isParked)
        XCTAssertTrue(l.hasDisplay)
        XCTAssertEqual(l.sessionEnded(now: 101 * sec), [], "a second end parks nothing and keeps the deadline")
        XCTAssertTrue(l.tick(now: 110 * sec - 1).isEmpty)
        XCTAssertEqual(l.tick(now: 110 * sec), [.teardown(.keepExpired)])
        XCTAssertFalse(l.hasDisplay)
        XCTAssertTrue(l.tick(now: 111 * sec).isEmpty, "teardown happens exactly once")
        XCTAssertTrue(l.tick(now: 10_000 * sec).isEmpty)
    }

    func testSessionEndWithoutDisplayDoesNotPark() {
        var l = DisplayLease()
        XCTAssertEqual(l.sessionEnded(now: 0), [])
        _ = l.sessionStarted(device: device(1), settings: s)
        l.displayLost()
        XCTAssertEqual(l.sessionEnded(now: 0), [], "nothing to park after the pipeline died")
        XCTAssertFalse(l.isParked)
    }

    func testSameDeviceReturningToParkedDisplayReuses() {
        var l = DisplayLease()
        _ = l.sessionStarted(device: device(1), settings: s)
        l.sessionEnded(now: 0)
        XCTAssertEqual(l.sessionStarted(device: device(1), settings: s), [.reuse])
        XCTAssertFalse(l.isParked)
        XCTAssertTrue(l.tick(now: 60 * sec).isEmpty, "unparking cancelled the keep timer")
    }

    func testRefreshChangeWhileParkedReconfiguresOnTheSameDisplay() {
        var l = DisplayLease()
        var fast = s
        fast.fps = 120
        fast.displayRefreshHz = 120
        _ = l.sessionStarted(device: device(1), settings: fast)
        l.sessionEnded(now: 0)
        var slow = s
        slow.fps = 60
        slow.displayRefreshHz = 60
        XCTAssertTrue(slow.sameDisplay(as: fast))
        // The pipeline built on the parked display recreates it for the new refresh rate (VideoPipeline, T-049).
        XCTAssertEqual(l.sessionStarted(device: device(1), settings: slow), [.reconfigure(slow)])
    }

    func testOtherDeviceOrSizeReplacesParkedDisplay() {
        var l = DisplayLease()
        _ = l.sessionStarted(device: device(1), settings: s)
        l.sessionEnded(now: 0)
        XCTAssertEqual(l.sessionStarted(device: device(2), settings: s), [.teardown(.deviceChanged), .create(s)])
        l.sessionEnded(now: 0)
        var other = s
        other.widthPx = 1920
        XCTAssertEqual(l.sessionStarted(device: device(2), settings: other), [.teardown(.sizeChanged), .create(other)])
        XCTAssertFalse(l.isParked)
    }

    func testLiveSizeChangeReasonIsSizeChanged() {
        var l = DisplayLease()
        _ = l.sessionStarted(device: device(1), settings: s)
        var other = s
        other.widthPx = 1920
        XCTAssertEqual(l.reconfigure(settings: other), [.teardown(.sizeChanged), .create(other)])
    }

    func testReconfigureWhileParkedDoesNothing() {
        var l = DisplayLease()
        _ = l.sessionStarted(device: device(1), settings: s)
        l.sessionEnded(now: 0)
        var fast = s
        fast.fps = 120
        XCTAssertTrue(l.reconfigure(settings: fast).isEmpty, "no session, no stream mode")
        XCTAssertTrue(l.isParked)
    }

    func testShutdownWhileParkedTearsDown() {
        var l = DisplayLease()
        _ = l.sessionStarted(device: device(1), settings: s)
        l.sessionEnded(now: 0)
        XCTAssertEqual(l.shutdown(), [.teardown(.shutdown)])
        XCTAssertFalse(l.hasDisplay)
        XCTAssertTrue(l.tick(now: 60 * sec).isEmpty, "no second teardown after shutdown")
    }

    func testDisplayLostWhileParkedGoesIdle() {
        var l = DisplayLease()
        _ = l.sessionStarted(device: device(1), settings: s)
        l.sessionEnded(now: 0)
        l.displayLost()
        XCTAssertFalse(l.hasDisplay)
        XCTAssertFalse(l.isParked)
        XCTAssertTrue(l.tick(now: 60 * sec).isEmpty)
        XCTAssertEqual(l.sessionStarted(device: device(1), settings: s), [.create(s)])
    }

    func testCustomKeepTime() {
        var l = DisplayLease(graceUs: DisplayLease.keepUs(env: ["MATEBRIDGE_DISPLAY_KEEP_S": "300"]))
        _ = l.sessionStarted(device: device(1), settings: s)
        l.sessionEnded(now: 0)
        XCTAssertTrue(l.tick(now: 299 * sec).isEmpty)
        XCTAssertEqual(l.tick(now: 300 * sec), [.teardown(.keepExpired)])
    }
}

/// `MATEBRIDGE_DISPLAY_KEEP_S` (T-165).
final class DisplayParkTests: XCTestCase {
    func testDefaultIsTenSeconds() {
        XCTAssertEqual(DisplayLease.defaultKeepSeconds, 10)
        XCTAssertEqual(DisplayLease.defaultGraceUs, 10_000_000, "the default keep time is unchanged")
        XCTAssertEqual(DisplayLease.keepUs(env: [:]), DisplayLease.defaultGraceUs)
    }

    func testAcceptedRange() {
        for (text, seconds) in [("10", 10), ("11", 11), ("300", 300), ("1800", 1800), ("86400", 86_400), (" 60 ", 60)] {
            XCTAssertEqual(DisplayLease.keepSeconds(text), seconds, text)
        }
        XCTAssertEqual(DisplayLease.keepUs(env: ["MATEBRIDGE_DISPLAY_KEEP_S": "300"]), 300_000_000)
    }

    func testAnythingElseFallsBackToTen() {
        let bad: [String?] = [nil, "", " ", "abc", "10s", "5m", "1.5", "9", "0", "-1", "-10", "86401",
                              "99999999999999999999999", "0x10", "+"]
        for text in bad {
            XCTAssertEqual(DisplayLease.keepSeconds(text), 10, String(describing: text))
        }
        XCTAssertEqual(DisplayLease.keepUs(env: ["MATEBRIDGE_DISPLAY_KEEP_S": "9"]), 10_000_000)
        XCTAssertEqual(DisplayLease.keepUs(env: ["OTHER": "300"]), 10_000_000)
    }
}
