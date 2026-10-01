import XCTest
@testable import MateBridgeCore

/// T-106 (decision 0013): `STREAM_PREFS.bitrate_kbps` on the host.
final class BitratePrefsTests: XCTestCase {
    private let base = VideoSettings.tabletDefault
    private let device = DeviceID(bytes: [UInt8](repeating: 0xC3, count: 16))!

    private func prefs(_ kbps: UInt32, fps: UInt16 = 60, scale: UInt16 = 1000) -> StreamPrefs {
        StreamPrefs(fps: fps, scalePermille: scale, bitrateKbps: kbps)
    }

    // MARK: clamping

    func testZeroMeansModeDefaultAndNonZeroIsClamped() {
        XCTAssertNil(VideoSettings.clampedUserBitrateKbps(0))
        XCTAssertEqual(VideoSettings.clampedUserBitrateKbps(1), 5_000)
        XCTAssertEqual(VideoSettings.clampedUserBitrateKbps(4_999), 5_000)
        XCTAssertEqual(VideoSettings.clampedUserBitrateKbps(5_000), 5_000)
        XCTAssertEqual(VideoSettings.clampedUserBitrateKbps(60_000), 60_000)
        XCTAssertEqual(VideoSettings.clampedUserBitrateKbps(150_000), 150_000)
        XCTAssertEqual(VideoSettings.clampedUserBitrateKbps(150_001), 150_000)
        XCTAssertEqual(VideoSettings.clampedUserBitrateKbps(UInt32.max), 150_000)
    }

    // MARK: priority env > user > mode default

    func testModeDefaultWhenZero() {
        let s = base.applying(prefs(0, fps: 144))
        XCTAssertEqual(s.bitrateKbps, 72_000)
        XCTAssertNil(s.userBitrateKbps)
        XCTAssertEqual(s.bitrateSource, "prefs")
        XCTAssertEqual(s.streamConfig(configID: 2).bitrateKbps, 72_000)
    }

    func testUserBitrateWinsOverModeDefault() {
        let s = base.applying(prefs(100_000))
        XCTAssertEqual(s.bitrateKbps, 100_000)
        XCTAssertEqual(s.bitrateSource, "user")
        XCTAssertEqual(s.streamConfig(configID: 2).bitrateKbps, 100_000, "STREAM_CONFIG carries the applied value")
        let clamped = base.applying(prefs(1))
        XCTAssertEqual(clamped.bitrateKbps, 5_000)
        XCTAssertEqual(clamped.streamConfig(configID: 2).bitrateKbps, 5_000)
        let high = base.applying(prefs(999_999))
        XCTAssertEqual(high.bitrateKbps, 150_000)
        // The user's value is not limited to the 20...80 Mbps mode-default band.
        XCTAssertEqual(base.applying(prefs(15_000, fps: 144)).bitrateKbps, 15_000)
    }

    func testEnvBitrateWinsOverUser() {
        let env = base.applyingExperimentKnobs(["MATEBRIDGE_BITRATE_KBPS": "45000"])
        let s = env.applying(prefs(100_000))
        XCTAssertEqual(s.bitrateKbps, 45_000)
        XCTAssertEqual(s.bitrateSource, "env")
        XCTAssertNil(s.userBitrateKbps)
        XCTAssertEqual(s.streamConfig(configID: 2).bitrateKbps, 45_000)
    }

    func testWifiEnvBitrateWinsOverUserOnWifiOnly() {
        let knobs = ["MATEBRIDGE_WIFI_BITRATE_KBPS": "25000"]
        let wifi = base.applyingExperimentKnobs(knobs).applyingTransportKnobs(knobs, transport: .network)
        let w = wifi.applying(prefs(100_000))
        XCTAssertEqual(w.bitrateKbps, 25_000)
        XCTAssertEqual(w.bitrateSource, "wifi_env")
        let usb = base.applyingExperimentKnobs(knobs).applyingTransportKnobs(knobs, transport: .usb)
        let u = usb.applying(prefs(100_000))
        XCTAssertEqual(u.bitrateKbps, 100_000)
        XCTAssertEqual(u.bitrateSource, "user")
    }

    func testBackToZeroReturnsToModeDefault() {
        let user = base.applying(prefs(100_000))
        let auto = user.applying(prefs(0))
        XCTAssertEqual(auto.bitrateKbps, 30_000)
        XCTAssertEqual(auto.bitrateSource, "prefs")
        // Derived from the same base it equals the plain default (applyPrefs always starts from `base`).
        XCTAssertEqual(base.applying(prefs(0)), base.applying(StreamPrefs(fps: 60, scalePermille: 1000)))
    }

    // MARK: reconfiguration policy

    func testBitrateOnlyChangeKeepsTheVirtualDisplay() {
        var lease = DisplayLease()
        let running = base.applying(prefs(0))
        _ = lease.sessionStarted(device: device, settings: running)
        let wanted = base.applying(prefs(60_000))
        XCTAssertNotEqual(wanted, running)
        XCTAssertEqual(wanted.displayRefreshHz, running.displayRefreshHz, "same refresh: VideoPipeline keeps the display")
        XCTAssertTrue(wanted.sameDisplay(as: running))
        XCTAssertEqual(lease.reconfigure(settings: wanted), [.reconfigure(wanted)], "restart, not teardown + create")
        // Also at 120 Hz: the refresh rate follows fps, not the bitrate.
        let fast = base.applying(prefs(0, fps: 120))
        let fastUser = base.applying(prefs(100_000, fps: 120))
        XCTAssertEqual(fast.displayRefreshHz, fastUser.displayRefreshHz)
    }

    func testSamePrefsAgainChangesNothing() {
        var lease = DisplayLease()
        let a = base.applying(prefs(60_000))
        _ = lease.sessionStarted(device: device, settings: a)
        let b = base.applying(prefs(60_000))
        XCTAssertEqual(a, b)
        XCTAssertTrue(lease.reconfigure(settings: b).isEmpty)
    }

    func testUserBitrateChangeUnderEnvOverrideIsNoChange() {
        let env = base.applyingExperimentKnobs(["MATEBRIDGE_BITRATE_KBPS": "45000"])
        XCTAssertEqual(env.applying(prefs(0)), env.applying(prefs(100_000)),
                       "env wins: the tablet's bitrate alone must not trigger a reconfiguration")
    }

    func testGateLimitsBitrateChangesToOnePerSecond() {
        var g = StreamPrefsGate()
        XCTAssertEqual(g.offer(prefs(15_000), now: 0), prefs(15_000))
        g.markApplied(now: 0)
        XCTAssertNil(g.offer(prefs(60_000), now: 100_000))
        XCTAssertNil(g.offer(prefs(100_000), now: 200_000))
        XCTAssertEqual(g.poll(now: 1_000_000), prefs(100_000), "newest wins")
    }

    // MARK: remembering (T-049)

    func testInMemoryStoreRemembersTheBitrate() {
        let store = InMemoryStreamPrefsStore()
        store.save(prefs(60_000, fps: 120, scale: 750), device: device)
        XCTAssertEqual(store.load(device: device)?.bitrateKbps, 60_000)
        let initial = VideoSettings.initialSettings(defaults: base, stored: store.load(device: device),
                                                    defaultRefreshHz: 60)
        XCTAssertEqual(initial.bitrateKbps, 60_000)
        XCTAssertEqual(initial.bitrateSource, "user")
        XCTAssertEqual([initial.fps, initial.scalePermille], [120, 750])
    }

    func testStorageCodecRoundTripsAndReadsOldRecords() {
        let p = prefs(100_000, fps: 144, scale: 800)
        XCTAssertEqual(StreamPrefsStorageCodec.encode(p), [144, 800, 100_000])
        XCTAssertEqual(StreamPrefsStorageCodec.decode(StreamPrefsStorageCodec.encode(p)), p)
        XCTAssertEqual(StreamPrefsStorageCodec.decode([120, 750]), StreamPrefs(fps: 120, scalePermille: 750, bitrateKbps: 0),
                       "pre-T-106 records: mode default")
        XCTAssertEqual(StreamPrefsStorageCodec.decode([90, 20, 0]), StreamPrefs(fps: 60, scalePermille: 500),
                       "normalized like before")
        XCTAssertNil(StreamPrefsStorageCodec.decode([]))
        XCTAssertNil(StreamPrefsStorageCodec.decode([60]))
        XCTAssertNil(StreamPrefsStorageCodec.decode([60, 1000, 0, 0]))
        XCTAssertNil(StreamPrefsStorageCodec.decode([-1, 1000]))
        XCTAssertNil(StreamPrefsStorageCodec.decode([60, 70_000]))
        XCTAssertNil(StreamPrefsStorageCodec.decode([60, 1000, -5]))
        XCTAssertNil(StreamPrefsStorageCodec.decode([60, 1000, Int(UInt32.max) + 1]))
        // The raw value is kept; clamping happens when it is applied.
        XCTAssertEqual(StreamPrefsStorageCodec.decode([60, 1000, 1])?.bitrateKbps, 1)
    }
}
