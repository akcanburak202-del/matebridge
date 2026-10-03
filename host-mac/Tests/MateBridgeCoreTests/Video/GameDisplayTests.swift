import XCTest
@testable import MateBridgeCore

/// T-214 (decision 0029, PROTOCOL.md 0x05 host rules): the 1x game display on the host.
final class GameDisplayTests: XCTestCase {
    private let base = VideoSettings.tabletDefault
    private let dev = DeviceID(bytes: [UInt8](repeating: 0xD4, count: 16))!

    private func prefs(fps: UInt16 = 120, scale: UInt16 = 660, kbps: UInt32 = 0, w: UInt16, h: UInt16) -> StreamPrefs {
        StreamPrefs(fps: fps, scalePermille: scale, bitrateKbps: kbps, displayWidthPx: w, displayHeightPx: h)
    }

    // MARK: Validation

    func testAcceptsTheOfferedSizes() {
        for (w, h) in [(1400, 920), (1848, 1214), (2100, 1380), (2800, 1840)] {
            XCTAssertTrue(GameDisplayPolicy.accepts(w: w, h: h, nativeW: 2800, nativeH: 1840), "\(w)x\(h)")
        }
    }

    func testRejectsInvalidSizes() {
        let bad: [(Int, Int, String)] = [
            (1849, 1214, "odd width"), (1848, 1215, "odd height"),
            (2802, 1842, "larger than native"), (2800, 1842, "taller than native"),
            (1398, 918, "below half"), (1398, 920, "narrower than half"),
            (1848, 1200, "aspect > 0.5 %"), (2000, 1380, "aspect > 0.5 %"),
            (0, 1214, "width 0"), (1848, 0, "height 0"), (0, 0, "native request"),
        ]
        for (w, h, why) in bad {
            XCTAssertFalse(GameDisplayPolicy.accepts(w: w, h: h, nativeW: 2800, nativeH: 1840), "\(w)x\(h): \(why)")
        }
        XCTAssertFalse(GameDisplayPolicy.accepts(w: 2, h: 2, nativeW: 0, nativeH: 0), "no native size")
    }

    func testAspectToleranceBoundary() {
        // |w·H − h·W| ≤ 0.005·h·W. 1848x1214: diff 1120 vs limit 16996.
        XCTAssertTrue(GameDisplayPolicy.accepts(w: 1848, h: 1214, nativeW: 2800, nativeH: 1840))
        // 1848x1226: diff |3400320 − 3432800| = 32480 > 0.005·1226·2800 = 17164.
        XCTAssertFalse(GameDisplayPolicy.accepts(w: 1848, h: 1226, nativeW: 2800, nativeH: 1840))
        // 1848x1220: diff 15680 ≤ 17080.
        XCTAssertTrue(GameDisplayPolicy.accepts(w: 1848, h: 1220, nativeW: 2800, nativeH: 1840))
    }

    // MARK: Settings and STREAM_CONFIG

    func testValidSizeGivesOneXDisplayAndScaleIsIgnored() {
        let s = base.applying(prefs(w: 1848, h: 1214))
        XCTAssertFalse(s.displayHiDPI)
        XCTAssertEqual([s.widthPx, s.heightPx, s.widthPt, s.heightPt], [1848, 1214, 1848, 1214])
        XCTAssertEqual(s.scalePermille, 1000, "the mode's scale is ignored")
        XCTAssertEqual([s.encodedWidthPx, s.encodedHeightPx], [1848, 1214])
        XCTAssertEqual([s.nativeWidthPx, s.nativeHeightPx], [2800, 1840])
        XCTAssertEqual(s.displayModeText, "1848x1214@1x")
        XCTAssertEqual([s.fps, s.displayRefreshHz], [120, 120])
        let cfg = s.streamConfig(configID: 4)
        XCTAssertEqual([cfg.widthPx, cfg.heightPx], [1848, 1214])
        XCTAssertEqual([cfg.widthPt, cfg.heightPt], [1848, 1214], "px = pt on the game display")
        XCTAssertEqual(cfg.configID, 4)
    }

    func testInvalidSizesGiveTheNativeDisplay() {
        let native = base.applying(prefs(w: 0, h: 0))
        XCTAssertTrue(native.displayHiDPI)
        for (w, h) in [(1849, 1214), (2802, 1842), (1398, 918), (1848, 1200), (0, 1214), (1848, 0)] as [(UInt16, UInt16)] {
            let s = base.applying(prefs(w: w, h: h))
            XCTAssertTrue(s.displayHiDPI, "\(w)x\(h)")
            XCTAssertEqual(s, native, "\(w)x\(h): same as 0x0")
            XCTAssertEqual([s.widthPx, s.heightPx, s.widthPt, s.heightPt], [2800, 1840, 1400, 920])
            XCTAssertEqual(s.scalePermille, 660, "the mode's scale applies on the native display")
        }
    }

    func testZeroDisplayIsTodaysStreamConfig() {
        for (fps, scale, kbps) in [(60, 1000, 0), (120, 660, 0), (144, 750, 0), (60, 500, 45_000)] as [(UInt16, UInt16, UInt32)] {
            let old = StreamPrefs(fps: fps, scalePermille: scale, bitrateKbps: kbps)
            let new = prefs(fps: fps, scale: scale, kbps: kbps, w: 0, h: 0)
            XCTAssertEqual(base.applying(new), base.applying(old))
            XCTAssertEqual(base.applying(new).streamConfig(configID: 2), base.applying(old).streamConfig(configID: 2))
        }
        // Today's 120/660 values, spelled out.
        let cfg = base.applying(prefs(w: 0, h: 0)).streamConfig(configID: 2)
        XCTAssertEqual([cfg.widthPx, cfg.heightPx, cfg.widthPt, cfg.heightPt], [1848, 1214, 1400, 920])
    }

    func testGameDisplayCanBeDisabled() {
        let s = base.applying(prefs(w: 1848, h: 1214), allowGameDisplay: false)
        XCTAssertTrue(s.displayHiDPI)
        XCTAssertEqual(s, base.applying(prefs(w: 0, h: 0)))
    }

    func testBackToNativeFromGameDisplay() {
        let game = base.applying(prefs(w: 1400, h: 920))
        let back = game.applying(prefs(fps: 60, scale: 1000, w: 0, h: 0))
        XCTAssertEqual(back, base.applying(StreamPrefs(fps: 60, scalePermille: 1000)))
        XCTAssertEqual(back.displayModeText, "2800x1840@2x")
        // Another game size from a game display validates against the native size, not the current one.
        let other = game.applying(prefs(w: 2100, h: 1380))
        XCTAssertEqual(other, base.applying(prefs(w: 2100, h: 1380)))
    }

    // MARK: Bitrate

    func testDefaultBitrateFollowsTheEffectiveScale() {
        let game = base.applying(prefs(fps: 120, scale: 1000, w: 1848, h: 1214))
        let scaled = base.applying(StreamPrefs(fps: 120, scalePermille: 660))
        XCTAssertEqual(game.effectiveScalePermille, 660)
        XCTAssertEqual(game.bitrateKbps, scaled.bitrateKbps, "1848 → the same default as scale 660")
        XCTAssertEqual(game.bitrateSource, "prefs")
        XCTAssertEqual(base.applying(prefs(fps: 60, w: 1400, h: 920)).bitrateKbps,
                       VideoSettings.defaultBitrateKbps(fps: 60, scalePermille: 500))
        // The user's and the env bitrate keep their priority.
        XCTAssertEqual(base.applying(prefs(kbps: 50_000, w: 1848, h: 1214)).bitrateKbps, 50_000)
        let env = base.applyingExperimentKnobs(["MATEBRIDGE_BITRATE_KBPS": "45000"])
        XCTAssertEqual(env.applying(prefs(kbps: 50_000, w: 1848, h: 1214)).bitrateKbps, 45_000)
        XCTAssertEqual(scaled.effectiveScalePermille, 660, "native: the prefs scale itself")
    }

    // MARK: Remembered prefs (T-049)

    func testStorageRoundTripsFiveValuesAndReadsOldRecords() {
        let game = prefs(fps: 120, scale: 660, kbps: 40_000, w: 1848, h: 1214)
        XCTAssertEqual(StreamPrefsStorageCodec.encode(game), [120, 660, 40_000, 1848, 1214])
        XCTAssertEqual(StreamPrefsStorageCodec.decode(StreamPrefsStorageCodec.encode(game)), game)
        // No game display: the record stays 3 values (readable by older builds).
        XCTAssertEqual(StreamPrefsStorageCodec.encode(StreamPrefs(fps: 60, scalePermille: 1000)), [60, 1000, 0])
        XCTAssertEqual(StreamPrefsStorageCodec.decode([120, 750]), StreamPrefs(fps: 120, scalePermille: 750))
        XCTAssertEqual(StreamPrefsStorageCodec.decode([120, 750, 30_000]),
                       StreamPrefs(fps: 120, scalePermille: 750, bitrateKbps: 30_000))
        for bad in [[], [60], [60, 1000, 0, 1848], [60, 1000, 0, 1848, 1214, 1], [60, 1000, 0, -1, 1214],
                    [60, 1000, 0, 1848, 70_000]] {
            XCTAssertNil(StreamPrefsStorageCodec.decode(bad), "\(bad)")
        }
    }

    func testRememberedGameDisplayStartsTheSessionInIt() {
        let store = InMemoryStreamPrefsStore()
        let game = prefs(w: 1848, h: 1214)
        store.save(game, device: dev)
        let initial = VideoSettings.initialSettings(defaults: base, stored: store.load(device: dev), defaultRefreshHz: 60)
        XCTAssertEqual(initial.displayModeText, "1848x1214@1x")
        XCTAssertEqual(base.applying(game), initial, "the tablet's first STREAM_PREFS changes nothing")
        let disabled = VideoSettings.initialSettings(defaults: base, stored: store.load(device: dev), defaultRefreshHz: 60,
                                                     allowGameDisplay: false)
        XCTAssertTrue(disabled.displayHiDPI)
    }

    // MARK: Lease (identity = device + native size)

    func testModeChangeIsAReconfigureWhileActiveAndParked() {
        let game = base.applying(prefs(w: 1848, h: 1214))
        var l = DisplayLease()
        _ = l.sessionStarted(device: dev, settings: base)
        XCTAssertTrue(game.sameNative(as: base))
        XCTAssertFalse(game.sameDisplay(as: base))
        XCTAssertEqual(l.reconfigure(settings: game), [.reconfigure(game)], "native -> game: no teardown")
        XCTAssertEqual(l.reconfigure(settings: base), [.reconfigure(base)], "game -> native: no teardown")
        // Parked native display, the tablet returns in game mode (and the other way round).
        l.sessionEnded(now: 0)
        XCTAssertEqual(l.sessionStarted(device: dev, settings: game), [.reconfigure(game)])
        l.sessionEnded(now: 0)
        XCTAssertEqual(l.sessionStarted(device: dev, settings: game), [.reuse])
        l.sessionEnded(now: 0)
        XCTAssertEqual(l.sessionStarted(device: dev, settings: base), [.reconfigure(base)])
        XCTAssertNil(l.lastTeardownReason)
    }

    func testOtherNativeSizeTearsDown() {
        let game = base.applying(prefs(w: 1848, h: 1214))
        var l = DisplayLease()
        _ = l.sessionStarted(device: dev, settings: game)
        l.sessionEnded(now: 0)
        var otherTablet = VideoSettings.tabletDefault
        otherTablet.widthPx = 1920
        otherTablet.heightPx = 1200
        otherTablet.widthPt = 960
        otherTablet.heightPt = 600
        XCTAssertEqual(l.sessionStarted(device: dev, settings: otherTablet), [.teardown, .create(otherTablet)])
        XCTAssertEqual(l.lastTeardownReason, .sizeChanged)
        let otherGame = otherTablet.applying(prefs(w: 1440, h: 900))
        XCTAssertFalse(otherGame.displayHiDPI)
        XCTAssertEqual(l.reconfigure(settings: otherGame), [.reconfigure(otherGame)])
        XCTAssertEqual(l.reconfigure(settings: game), [.teardown, .create(game)], "another native size")
        XCTAssertEqual(l.lastTeardownReason, .sizeChanged)
    }

    // MARK: Display reuse (VideoPipeline.obtainDisplay)

    func testReuseOnlyOnExactMatch() {
        let native = DisplayMode(widthPx: 2800, heightPx: 1840, hidpi: true, refreshHz: 120)
        XCTAssertEqual(DisplayReuse.decide(current: native, online: true, wanted: native), .reuse)
        XCTAssertEqual(DisplayReuse.decide(current: native, online: false, wanted: native), .recreate(.offline))
        var slow = native
        slow.refreshHz = 60
        XCTAssertEqual(DisplayReuse.decide(current: native, online: true, wanted: slow), .recreate(.refreshChange))
        let game = DisplayMode(widthPx: 1848, heightPx: 1214, hidpi: false, refreshHz: 120)
        XCTAssertEqual(DisplayReuse.decide(current: native, online: true, wanted: game), .recreate(.modeChange))
        XCTAssertEqual(DisplayReuse.decide(current: game, online: true, wanted: native), .recreate(.modeChange))
        var oneX = native
        oneX.hidpi = false
        XCTAssertEqual(DisplayReuse.decide(current: native, online: true, wanted: oneX), .recreate(.modeChange),
                       "same pixels, other HiDPI")
        var otherGame = game
        otherGame.widthPx = 1400
        otherGame.heightPx = 920
        XCTAssertEqual(DisplayReuse.decide(current: game, online: false, wanted: otherGame), .recreate(.modeChange),
                       "the mode reason wins")
        XCTAssertEqual(DisplayReuse.Reason.modeChange.logName, "mode_change")
    }

    func testSettingsDisplayMode() {
        let game = base.applying(prefs(w: 1848, h: 1214))
        XCTAssertEqual(game.displayMode, DisplayMode(widthPx: 1848, heightPx: 1214, hidpi: false, refreshHz: 120))
        XCTAssertEqual(base.displayMode, DisplayMode(widthPx: 2800, heightPx: 1840, hidpi: true, refreshHz: 60))
        XCTAssertEqual(base.displayModeText, "2800x1840@2x")
    }

    func testRecreateGap() {
        XCTAssertEqual(DisplayRecreateGap.gapUs, 700_000)
        XCTAssertEqual(DisplayRecreateGap.remainingUs(lastRemovedUs: nil, nowUs: 5), 0, "nothing removed yet")
        XCTAssertEqual(DisplayRecreateGap.remainingUs(lastRemovedUs: 1_000_000, nowUs: 1_000_000), 700_000)
        XCTAssertEqual(DisplayRecreateGap.remainingUs(lastRemovedUs: 1_000_000, nowUs: 1_200_000), 500_000)
        XCTAssertEqual(DisplayRecreateGap.remainingUs(lastRemovedUs: 1_000_000, nowUs: 1_700_000), 0)
        XCTAssertEqual(DisplayRecreateGap.remainingUs(lastRemovedUs: 1_000_000, nowUs: 9_000_000), 0)
        XCTAssertEqual(DisplayRecreateGap.remainingUs(lastRemovedUs: 1_000_000, nowUs: 10), 700_000, "clock went back")
    }

    // MARK: Fallback (game_display_failed)

    func testOneFallbackToNativeOnGameDisplayFailure() {
        let game = base.applying(prefs(w: 1848, h: 1214))
        var f = GameDisplayFallback()
        XCTAssertTrue(f.allowsGameDisplay)
        XCTAssertFalse(f.startFailed(settings: game, displayFailure: false), "e.g. permission: no fallback")
        XCTAssertTrue(f.allowsGameDisplay)
        XCTAssertFalse(f.startFailed(settings: base, displayFailure: true), "native failure: nothing to fall back to")
        XCTAssertTrue(f.allowsGameDisplay)
        XCTAssertTrue(f.startFailed(settings: game, displayFailure: true))
        XCTAssertFalse(f.allowsGameDisplay, "off for the rest of the process")
        // The fallback settings are native; their failure does not fall back again.
        let fallback = base.applying(prefs(w: 1848, h: 1214), allowGameDisplay: f.allowsGameDisplay)
        XCTAssertTrue(fallback.displayHiDPI)
        XCTAssertEqual(fallback.scalePermille, 660, "the prefs are re-applied without the display")
        XCTAssertFalse(f.startFailed(settings: fallback, displayFailure: true))
        XCTAssertFalse(f.allowsGameDisplay)
    }

    // MARK: Announced config vs activation (T-214 review)

    /// A paired reconnect's HELLO is answered while game displays are allowed; before its proof the old session's
    /// game display fails and switches them off; the activation derives native settings. The game STREAM_CONFIG sent
    /// at HELLO must not stay in force: activation reports the difference and the native config gets a new config_id.
    func testFallbackBetweenHelloAndActivationForcesANewConfigID() {
        let store = InMemoryStreamPrefsStore()
        store.save(prefs(w: 1848, h: 1214), device: dev)
        var fallback = GameDisplayFallback()
        var announced = AnnouncedStreamConfigs()

        // HELLO of the reconnect (StreamCoordinator.streamConfig(for:)).
        let atHello = VideoSettings.initialSettings(defaults: base, stored: store.load(device: dev), defaultRefreshHz: 60,
                                                    allowGameDisplay: fallback.allowsGameDisplay)
        let helloConfig = atHello.streamConfig(configID: 1)
        announced.record(helloConfig, device: dev)
        XCTAssertEqual([helloConfig.widthPx, helloConfig.heightPx, helloConfig.widthPt, helloConfig.heightPt],
                       [1848, 1214, 1848, 1214])

        // The old session's game display fails before the proof.
        XCTAssertTrue(fallback.startFailed(settings: atHello, displayFailure: true))

        // Activation (StreamCoordinator.sessionStarted) derives the settings again.
        let atActivation = VideoSettings.initialSettings(defaults: base, stored: store.load(device: dev),
                                                         defaultRefreshHz: 60, allowGameDisplay: fallback.allowsGameDisplay)
        XCTAssertTrue(atActivation.displayHiDPI)
        XCTAssertTrue(announced.activationDiffers(device: dev, activation: atActivation.streamConfig(configID: 1)),
                      "the announced game config disagrees with the native pipeline")
        let reannounced = atActivation.streamConfig(configID: nextConfigID(after: 1))
        XCTAssertEqual(reannounced.configID, 2)
        XCTAssertEqual([reannounced.widthPt, reannounced.heightPt], [1400, 920])
        XCTAssertEqual([reannounced.widthPx, reannounced.heightPx], [1848, 1214], "native display, the mode's 660 scale")
        // Resending the same prefs then changes nothing, and the live settings already match the announced config.
        XCTAssertEqual(base.applying(prefs(w: 1848, h: 1214), allowGameDisplay: fallback.allowsGameDisplay), atActivation)
        XCTAssertEqual(announced.count, 0, "the record is consumed")
    }

    func testActivationMatchingTheHelloConfigNeedsNoNewConfigID() {
        var announced = AnnouncedStreamConfigs()
        let game = base.applying(prefs(w: 1848, h: 1214))
        announced.record(game.streamConfig(configID: 1), device: dev)
        XCTAssertFalse(announced.activationDiffers(device: dev, activation: game.streamConfig(configID: 1)))
        XCTAssertFalse(announced.activationDiffers(device: dev, activation: base.streamConfig(configID: 1)),
                       "consumed: a second activation has nothing to compare")
        // Only the bitrate differs (the Wi-Fi bitrate knob is applied at activation only): no new config_id.
        announced.record(game.streamConfig(configID: 1), device: dev)
        let wifi = game.applyingTransportKnobs(["MATEBRIDGE_WIFI_BITRATE_KBPS": "25000"], transport: .network)
        XCTAssertNotEqual(wifi.bitrateKbps, game.bitrateKbps)
        XCTAssertFalse(announced.activationDiffers(device: dev, activation: wifi.streamConfig(configID: 1)))
        // Other stored prefs in between (T-049): the stream size differs, so a new config_id is needed too.
        announced.record(base.streamConfig(configID: 1), device: dev)
        XCTAssertTrue(announced.activationDiffers(
            device: dev, activation: base.applying(StreamPrefs(fps: 120, scalePermille: 750)).streamConfig(configID: 1)))
        let other = DeviceID(bytes: [UInt8](repeating: 0xE5, count: 16))!
        XCTAssertFalse(announced.activationDiffers(device: other, activation: game.streamConfig(configID: 1)),
                       "no HELLO recorded: unchanged behaviour")
    }

    func testAnnouncedConfigsAreBounded() {
        var announced = AnnouncedStreamConfigs()
        for n in 0..<40 {
            announced.record(base.streamConfig(configID: 1), device: DeviceID(bytes: [UInt8](repeating: UInt8(n), count: 16))!)
        }
        XCTAssertEqual(announced.count, AnnouncedStreamConfigs.maxDevices)
        let last = DeviceID(bytes: [UInt8](repeating: 39, count: 16))!
        XCTAssertTrue(announced.activationDiffers(device: last, activation: base.applying(prefs(w: 1848, h: 1214))
            .streamConfig(configID: 1)), "the newest record is kept")
    }

    func testOutcomeForTheLog() {
        XCTAssertEqual(GameDisplayPolicy.outcome(of: prefs(w: 0, h: 0), nativeW: 2800, nativeH: 1840, allowed: true), .none)
        XCTAssertEqual(GameDisplayPolicy.outcome(of: prefs(w: 1848, h: 1214), nativeW: 2800, nativeH: 1840, allowed: true),
                       .applied)
        XCTAssertEqual(GameDisplayPolicy.outcome(of: prefs(w: 1849, h: 1214), nativeW: 2800, nativeH: 1840, allowed: true),
                       .rejected)
        XCTAssertEqual(GameDisplayPolicy.outcome(of: prefs(w: 1848, h: 1214), nativeW: 2800, nativeH: 1840, allowed: false),
                       .disabled)
        XCTAssertEqual(GameDisplayPolicy.outcome(of: prefs(w: 1849, h: 1214), nativeW: 2800, nativeH: 1840, allowed: false),
                       .rejected)
    }

    func testProfileLineNamesTheDisplay() {
        let build = BuildInfo(version: "0.1", build: "20261004000000", sha: "abc1234")
        let f = StreamProfileLog.fields(settings: base.applying(prefs(w: 1848, h: 1214)), encoderProfile: .fast,
                                        build: build, env: [:])
        XCTAssertTrue(f.contains(" scale_permille=1000 refresh_hz=120 display=1848x1214@1x sha=abc1234 "), f)
    }
}
