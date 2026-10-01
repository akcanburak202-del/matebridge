import XCTest
@testable import MateBridgeCore

/// T-086: codec, bitrate precedence, encoder knobs, idle refresh, quality metrics, bench options.
final class EncoderKnobsTests: XCTestCase {
    // MARK: Parsing

    func testParseCodec() {
        XCTAssertEqual(VideoSettings.parseCodec("h264"), .h264)
        XCTAssertEqual(VideoSettings.parseCodec(" H264 "), .h264)
        for other in [nil, "", "hevc", "HEVC", "avc", "vp9"] { XCTAssertEqual(VideoSettings.parseCodec(other), .hevc) }
    }

    func testParseH264Profile() {
        XCTAssertEqual(H264Profile.parse("main"), .main)
        XCTAssertEqual(H264Profile.parse("CBP"), .cbp)
        XCTAssertEqual(H264Profile.parse("high52"), .high52)
        for other in [nil, "", "high", "baseline", "x"] { XCTAssertEqual(H264Profile.parse(other), .high) }
    }

    func testEncoderKnobDefaultsAreTodaysBehaviour() {
        let k = EncoderKnobs.parse([:])
        XCTAssertEqual(k, EncoderKnobs())
        XCTAssertTrue(k.prioritizeSpeed)
        XCTAssertNil(k.quality)
        XCTAssertEqual(k.h264Profile, .high)
        XCTAssertFalse(k.idleRefresh.isEnabled)
        XCTAssertTrue(k.retagInput)
        XCTAssertEqual(k.logFields, "prio_speed=1 quality=unset idle_refresh=off input_retag=1")
    }

    func testEncoderKnobValues() {
        let k = EncoderKnobs.parse([
            "MATEBRIDGE_PRIO_SPEED": "0", "MATEBRIDGE_QUALITY": "0.8", "MATEBRIDGE_H264_PROFILE": "main",
            "MATEBRIDGE_IDLE_REFRESH_MS": "300", "MATEBRIDGE_IDLE_REFRESH_COUNT": "5",
        ])
        XCTAssertFalse(k.prioritizeSpeed)
        XCTAssertEqual(k.quality, 0.8)
        XCTAssertEqual(k.h264Profile, .main)
        XCTAssertEqual(k.idleRefresh, IdleRefreshConfig(delayMs: 300, count: 5, keyframe: false))
        XCTAssertEqual(k.logFields, "prio_speed=0 quality=0.80 idle_refresh=300ms*5 input_retag=1")
        XCTAssertTrue(EncoderKnobs.parse(["MATEBRIDGE_PRIO_SPEED": "1"]).prioritizeSpeed)
        XCTAssertTrue(EncoderKnobs.parse(["MATEBRIDGE_PRIO_SPEED": "no"]).prioritizeSpeed)
    }

    func testParseQuality() {
        XCTAssertEqual(EncoderKnobs.parseQuality("0"), 0)
        XCTAssertEqual(EncoderKnobs.parseQuality("1.0"), 1)
        XCTAssertEqual(EncoderKnobs.parseQuality(" 0.55 "), 0.55)
        for bad in [nil, "", "-0.1", "1.01", "nan", "inf", "x"] { XCTAssertNil(EncoderKnobs.parseQuality(bad), "\(bad ?? "nil")") }
    }

    func testIdleRefreshConfigParse() {
        XCTAssertEqual(IdleRefreshConfig.parse([:]), IdleRefreshConfig())
        XCTAssertEqual(IdleRefreshConfig.parse(["MATEBRIDGE_IDLE_REFRESH_MS": "0"]).delayMs, 0)
        XCTAssertEqual(IdleRefreshConfig.parse(["MATEBRIDGE_IDLE_REFRESH_MS": "10001"]).delayMs, 0)
        XCTAssertEqual(IdleRefreshConfig.parse(["MATEBRIDGE_IDLE_REFRESH_MS": "abc"]).delayMs, 0)
        let c = IdleRefreshConfig.parse(["MATEBRIDGE_IDLE_REFRESH_MS": "250", "MATEBRIDGE_IDLE_REFRESH_COUNT": "99",
                                         "MATEBRIDGE_IDLE_REFRESH_KEY": "1"])
        XCTAssertEqual(c, IdleRefreshConfig(delayMs: 250, count: 3, keyframe: true))
        XCTAssertEqual(c.logValue, "250ms*key")
        XCTAssertEqual(IdleRefreshConfig().logValue, "off")
    }

    // MARK: Settings

    func testCodecKnobReachesStreamConfig() {
        let base = VideoSettings.tabletDefault
        XCTAssertEqual(base.applyingExperimentKnobs([:]).streamConfig(configID: 1).codec, .hevc)
        let h = base.applyingExperimentKnobs(["MATEBRIDGE_CODEC": "h264"])
        XCTAssertEqual(h.codec, .h264)
        XCTAssertEqual(h.streamConfig(configID: 1).codec, .h264)
        XCTAssertEqual(h.streamConfig(configID: 1).codec.rawValue, 1)
        // A STREAM_PREFS reconfiguration keeps the codec.
        XCTAssertEqual(h.applying(StreamPrefs(fps: 120, scalePermille: 1000)).codec, .h264)
    }

    func testEnvBitrateWinsOverPrefs() {
        let prefs = StreamPrefs(fps: 120, scalePermille: 1000)
        let plain = VideoSettings.tabletDefault.applyingExperimentKnobs([:])
        XCTAssertEqual(plain.applying(prefs).bitrateKbps, 60_000)
        XCTAssertEqual(plain.applying(prefs).bitrateSource, "prefs")

        let env = VideoSettings.tabletDefault.applyingExperimentKnobs(["MATEBRIDGE_BITRATE_KBPS": "100000"])
        XCTAssertEqual(env.bitrateKbps, 100_000)
        XCTAssertEqual(env.bitrateSource, "env")
        let applied = env.applying(prefs)
        XCTAssertEqual(applied.bitrateKbps, 100_000)
        XCTAssertEqual(applied.bitrateSource, "env")
        XCTAssertEqual(applied.streamConfig(configID: 1).bitrateKbps, 100_000)
        // Outside the prefs clamp (20...80 Mbps), inside the env range (5...150 Mbps).
        let low = VideoSettings.tabletDefault.applyingExperimentKnobs(["MATEBRIDGE_BITRATE_KBPS": "8000"])
        XCTAssertEqual(low.applying(prefs).bitrateKbps, 8_000)
        // Reconnect with stored prefs: still the env value.
        let initial = VideoSettings.initialSettings(defaults: env, stored: StreamPrefs(fps: 60, scalePermille: 500),
                                                    defaultRefreshHz: 60)
        XCTAssertEqual(initial.bitrateKbps, 100_000)
        // An invalid value is ignored: the mode default stays.
        let bad = VideoSettings.tabletDefault.applyingExperimentKnobs(["MATEBRIDGE_BITRATE_KBPS": "200000"])
        XCTAssertEqual(bad.applying(prefs).bitrateKbps, 60_000)
        XCTAssertEqual(bad.bitrateSource, "prefs")
    }

    // MARK: Idle refresh

    private let ms: UInt64 = 1_000

    func testIdleRefreshOffDoesNothing() {
        var p = IdleRefreshPolicy(config: IdleRefreshConfig(), fps: 120)
        p.captured(nowUs: 0)
        for t in stride(from: UInt64(0), to: 5_000 * ms, by: 8_000) { XCTAssertEqual(p.tick(nowUs: t), .none) }
    }

    func testIdleRefreshNothingBeforeFirstCapture() {
        var p = IdleRefreshPolicy(config: IdleRefreshConfig(delayMs: 100), fps: 120)
        XCTAssertEqual(p.tick(nowUs: 10_000 * ms), .none)
    }

    func testIdleRefreshResubmitsCountTimesOnePerFrameThenStops() {
        var p = IdleRefreshPolicy(config: IdleRefreshConfig(delayMs: 300, count: 3), fps: 120)
        XCTAssertEqual(p.intervalUs, 8_333)
        let start: UInt64 = 1_000_000 * ms
        p.captured(nowUs: start)
        XCTAssertEqual(p.tick(nowUs: start + 299 * ms), .none)
        XCTAssertEqual(p.tick(nowUs: start + 300 * ms), .resubmit(first: true))
        // Not before one frame interval.
        XCTAssertEqual(p.tick(nowUs: start + 300 * ms + 8_000), .none)
        XCTAssertEqual(p.tick(nowUs: start + 300 * ms + 8_333), .resubmit(first: false))
        XCTAssertEqual(p.tick(nowUs: start + 300 * ms + 16_666), .resubmit(first: false))
        // Done for this static stretch, however long it lasts.
        for t in stride(from: start + 320 * ms, to: start + 10_000 * ms, by: 8_000) {
            XCTAssertEqual(p.tick(nowUs: t), .none)
        }
        // A new capture re-arms it.
        p.captured(nowUs: start + 10_000 * ms)
        XCTAssertEqual(p.tick(nowUs: start + 10_300 * ms), .resubmit(first: true))
    }

    func testIdleRefreshCaptureCancelsRemainingResubmits() {
        var p = IdleRefreshPolicy(config: IdleRefreshConfig(delayMs: 100, count: 5), fps: 60)
        p.captured(nowUs: 0)
        XCTAssertEqual(p.tick(nowUs: 100 * ms), .resubmit(first: true))
        p.captured(nowUs: 110 * ms)
        XCTAssertEqual(p.tick(nowUs: 130 * ms), .none)
        XCTAssertEqual(p.tick(nowUs: 209 * ms), .none)
        XCTAssertEqual(p.tick(nowUs: 210 * ms), .resubmit(first: true))
    }

    func testIdleRefreshCountOneAndKeyframeMode() {
        var one = IdleRefreshPolicy(config: IdleRefreshConfig(delayMs: 50, count: 1), fps: 120)
        one.captured(nowUs: 0)
        XCTAssertEqual(one.tick(nowUs: 50 * ms), .resubmit(first: true))
        XCTAssertEqual(one.tick(nowUs: 100 * ms), .none)

        var key = IdleRefreshPolicy(config: IdleRefreshConfig(delayMs: 50, count: 3, keyframe: true), fps: 120)
        key.captured(nowUs: 0)
        XCTAssertEqual(key.tick(nowUs: 49 * ms), .none)
        XCTAssertEqual(key.tick(nowUs: 50 * ms), .keyframe)
        XCTAssertEqual(key.tick(nowUs: 60 * ms), .none)
        XCTAssertEqual(key.tick(nowUs: 5_000 * ms), .none)
        key.reset()
        XCTAssertEqual(key.tick(nowUs: 6_000 * ms), .none)
    }

    // MARK: Stamps

    /// The tablet pacer's lateness is `x = ready - capture_time`. A re-submission must get the same x as the real
    /// frames around it, i.e. the same capture-to-delivery lead (SCK stamps ~6.6 ms ahead of delivery).
    func testResubmissionKeepsTheRealFramesLead() {
        let deliveredUs: UInt64 = 1_000_000_000
        let captureUs = deliveredUs + 6_600
        let lead = ResubmitStamp.lead(captureUs: captureUs, deliveredUs: deliveredUs)
        XCTAssertEqual(lead, 6_600)
        let nowUs = deliveredUs + 300_000   // idle refresh 300 ms later
        let stamp = ResubmitStamp.stamp(nowUs: nowUs, leadUs: lead, lastStampUs: captureUs)
        // Same encode + transport delay after submission -> same ready offset -> same x.
        let pipelineUs: UInt64 = 12_000
        let xReal = Int64(deliveredUs + pipelineUs) - Int64(captureUs)
        let xRefresh = Int64(nowUs + pipelineUs) - Int64(stamp)
        XCTAssertEqual(xRefresh, xReal)
        XCTAssertEqual(stamp, nowUs + 6_600)
    }

    func testResubmissionStampsIncreaseAndHandleNegativeLead() {
        // Back-to-back refreshes within the same microsecond never repeat a stamp.
        let a = ResubmitStamp.stamp(nowUs: 5_000, leadUs: 100, lastStampUs: 4_000)
        let b = ResubmitStamp.stamp(nowUs: 5_000, leadUs: 100, lastStampUs: a)
        XCTAssertEqual(a, 5_100)
        XCTAssertEqual(b, 5_101)
        // A real capture stamped later than now + lead still bounds the stamp from below.
        XCTAssertEqual(ResubmitStamp.stamp(nowUs: 5_000, leadUs: 0, lastStampUs: 9_000), 9_001)
        // Stamps behind delivery (negative lead) and no previous stamp.
        XCTAssertEqual(ResubmitStamp.lead(captureUs: 1_000, deliveredUs: 3_000), -2_000)
        XCTAssertEqual(ResubmitStamp.stamp(nowUs: 10_000, leadUs: -2_000, lastStampUs: nil), 8_000)
        XCTAssertEqual(ResubmitStamp.stamp(nowUs: 1_000, leadUs: -2_000, lastStampUs: nil), 0)
    }

    // MARK: SPS levels

    func testH264LevelAndProfile() {
        let sps: [UInt8] = [0x67, 100, 0x00, 52, 0xAC, 0xD9]
        XCTAssertEqual(H264SPS.profileIdc(sps), 100)
        XCTAssertEqual(H264SPS.levelIdc(sps), 52)
        XCTAssertNil(H264SPS.levelIdc([0x68, 0xEE, 0x3C, 0x80]))   // PPS
        XCTAssertNil(H264SPS.levelIdc([0x67, 100]))
    }

    func testHEVCGeneralLevelSkipsEmulationPrevention() {
        // NAL header (SPS = type 33), vps/sub-layer byte, 11 profile bytes containing 00 00 03 escapes, level 153.
        let profile: [UInt8] = [0x01, 0x60, 0x00, 0x00, 0x03, 0x00, 0x90, 0x00, 0x00, 0x03, 0x00, 0x00, 0x03, 0x00]
        let nal: [UInt8] = [0x42, 0x01, 0x01] + profile + [153, 0xA0]
        XCTAssertEqual(HEVCSPS.generalLevelIdc(sps: nal), 153)
        XCTAssertNil(HEVCSPS.generalLevelIdc(sps: [0x40, 0x01, 0x0C, 0x01]))   // VPS
    }

    // MARK: Quality metrics

    func testPSNRAndSSIMOfIdenticalPlanes() {
        let data = (0..<(64 * 32)).map { UInt8(truncatingIfNeeded: $0 &* 37) }
        let a = LumaPlane(width: 64, height: 32, data: data)
        XCTAssertEqual(ImageQuality.psnr(a, a), .infinity)
        XCTAssertEqual(ImageQuality.ssim(a, a), 1, accuracy: 1e-12)
    }

    func testPSNRKnownValueAndStride() {
        let a = LumaPlane(width: 16, height: 16, data: [UInt8](repeating: 100, count: 256))
        // Stride 20 with padding bytes that must be ignored.
        var padded = [UInt8](repeating: 255, count: 20 * 16)
        for y in 0..<16 { for x in 0..<16 { padded[y * 20 + x] = 110 } }
        let b = LumaPlane(width: 16, height: 16, stride: 20, data: padded)
        // MSE 100 -> 10 log10(65025 / 100).
        XCTAssertEqual(ImageQuality.psnr(a, b), 10 * log10(65_025.0 / 100), accuracy: 1e-9)
        // Uniform blocks with different means: SSIM = (2 m1 m2 + C1) / (m1^2 + m2^2 + C1).
        let c1 = 6.5025
        XCTAssertEqual(ImageQuality.ssim(a, b), (2 * 100 * 110 + c1) / (100 * 100 + 110 * 110 + c1), accuracy: 1e-9)
    }

    func testSSIMDropsWithBlur() {
        // Sharp 1-px stripes vs. their 3-tap blur: SSIM clearly below 1, PSNR finite.
        let w = 64, h = 16
        let sharp = (0..<(w * h)).map { i -> UInt8 in (i % w) % 2 == 0 ? 20 : 235 }
        var blurred = sharp
        for y in 0..<h { for x in 1..<(w - 1) {
            blurred[y * w + x] = UInt8((Int(sharp[y * w + x - 1]) + 2 * Int(sharp[y * w + x]) + Int(sharp[y * w + x + 1])) / 4)
        } }
        let a = LumaPlane(width: w, height: h, data: sharp), b = LumaPlane(width: w, height: h, data: blurred)
        XCTAssertLessThan(ImageQuality.ssim(a, b), 0.95)
        XCTAssertTrue(ImageQuality.psnr(a, b).isFinite)
        // Only detailed reference blocks: a flat half that matches exactly no longer dilutes the score.
        var halfFlat = sharp, halfFlatBlur = blurred
        for y in 0..<h { for x in 0..<(w / 2) { halfFlat[y * w + x] = 255; halfFlatBlur[y * w + x] = 255 } }
        let ra = LumaPlane(width: w, height: h, data: halfFlat), rb = LumaPlane(width: w, height: h, data: halfFlatBlur)
        let all = ImageQuality.ssim(ra, rb), text = ImageQuality.ssim(ra, rb, minReferenceVariance: 100)
        XCTAssertLessThan(text, all)
        XCTAssertLessThan(text, 0.2)
        XCTAssertEqual(ImageQuality.ssim(ra, ra, minReferenceVariance: 1e9), 0)   // no block qualifies
        // Partial blocks are skipped: a 7x7 plane has no full window.
        let tiny = LumaPlane(width: 7, height: 7, data: [UInt8](repeating: 0, count: 49))
        XCTAssertEqual(ImageQuality.ssim(tiny, tiny), 0)
    }

    // MARK: Benches

    func testEncodeBenchQualityVariants() {
        let noprio = EncodeBenchConfig.named("nolat-rtoff-noprio")!
        XCTAssertFalse(noprio.prioritizeSpeed || noprio.lowLatencyRateControl)
        XCTAssertEqual(noprio.realTime, false)
        XCTAssertNil(noprio.quality)
        let q80 = EncodeBenchConfig.named("nolat-rtoff-q80")!
        XCTAssertEqual(q80.quality, 0.8)
        XCTAssertTrue(q80.prioritizeSpeed)
        XCTAssertNil(EncodeBenchConfig.named("nolat-rtoff")!.quality)
    }

    func testEncodeBenchEnvironment() throws {
        let o = try XCTUnwrap(EncodeBenchOptions.parse(["--encode-bench", "--config", "nolat-rtoff"])).get()
        XCTAssertEqual(o.applyingEnvironment([:]), o)
        let h = o.applyingEnvironment(["MATEBRIDGE_CODEC": "h264", "MATEBRIDGE_H264_PROFILE": "cbp",
                                       "MATEBRIDGE_BITRATE_KBPS": "60000"])
        XCTAssertEqual(h.codec, .h264)
        XCTAssertEqual(h.h264Profile, .cbp)
        XCTAssertEqual(h.configs.map(\.bitrateKbps), [60_000])
    }

    func testSharpnessBenchOptions() throws {
        XCTAssertNil(SharpnessBenchOptions.parse(["app", "--encode-bench"]))
        let d = try XCTUnwrap(SharpnessBenchOptions.parse(["app", "--sharpness-bench"])).get()
        XCTAssertEqual(d, SharpnessBenchOptions())
        let o = try XCTUnwrap(SharpnessBenchOptions.parse(
            ["--sharpness-bench", "--fps", "60", "--motion-frames", "10", "--shift-px", "4", "--static-ms", "0"])).get()
        XCTAssertEqual([o.fps, o.motionFrames, o.shiftPx, o.staticMs], [60, 10, 4, 0])
        for bad in [["--fps", "0"], ["--motion-frames", "x"], ["--shift-px", "65"], ["--static-ms"]] {
            guard case .failure = SharpnessBenchOptions.parse(["--sharpness-bench"] + bad)! else {
                return XCTFail("\(bad) should fail")
            }
        }
    }

    func testSharpnessBenchStaticWaitCoversIdleRefresh() {
        var o = SharpnessBenchOptions()
        o.staticMs = 100
        XCTAssertEqual(o.effectiveStaticMs(idleRefresh: IdleRefreshConfig()), 100)
        // 300 ms + 3 frames at 120 fps (25 ms) + 250 ms.
        XCTAssertEqual(o.effectiveStaticMs(idleRefresh: IdleRefreshConfig(delayMs: 300, count: 3)), 575)
        XCTAssertEqual(o.effectiveStaticMs(idleRefresh: IdleRefreshConfig(delayMs: 300, keyframe: true)), 559)
        o.staticMs = 2_000
        XCTAssertEqual(o.effectiveStaticMs(idleRefresh: IdleRefreshConfig(delayMs: 300)), 2_000)
    }
}
