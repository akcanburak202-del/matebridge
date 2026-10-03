import XCTest
@testable import MateBridgeCore

/// T-086: codec, bitrate precedence, encoder knobs, quality metrics, bench options. T-204: `ev=profile`.
final class EncoderKnobsTests: XCTestCase {
    // MARK: Parsing

    func testParseCodec() {
        XCTAssertEqual(VideoSettings.parseCodec("h264"), .h264)
        XCTAssertEqual(VideoSettings.parseCodec(" H264 "), .h264)
        for other in [nil, "", "hevc", "HEVC", "avc", "vp9"] { XCTAssertEqual(VideoSettings.parseCodec(other), .hevc) }
    }

    func testEncoderKnobDefaultsAreTodaysBehaviour() {
        let k = EncoderKnobs.parse([:])
        XCTAssertEqual(k, EncoderKnobs())
        XCTAssertNil(k.quality)
        XCTAssertEqual(k.logFields, "prio_speed=1 quality=unset idle_refresh=off input_retag=1")
    }

    func testEncoderKnobValues() {
        let k = EncoderKnobs.parse(["MATEBRIDGE_QUALITY": "0.8"])
        XCTAssertEqual(k.quality, 0.8)
        XCTAssertEqual(k.logFields, "prio_speed=1 quality=0.80 idle_refresh=off input_retag=1")
    }

    /// T-204: the retired knobs are not read any more; the `encoder_config` fields they fed are constants.
    func testRetiredKnobsAreIgnored() {
        let retired = [
            "MATEBRIDGE_PRIO_SPEED": "0", "MATEBRIDGE_H264_PROFILE": "cbp", "MATEBRIDGE_INPUT_RETAG": "0",
            "MATEBRIDGE_IDLE_REFRESH_MS": "300", "MATEBRIDGE_IDLE_REFRESH_COUNT": "5", "MATEBRIDGE_IDLE_REFRESH_KEY": "1",
            "MATEBRIDGE_IDLE_REFRESH_BUFFER": "copy", "MATEBRIDGE_IDLE_REFRESH_QP": "10", "MATEBRIDGE_FRAME_DELAY": "1",
        ]
        XCTAssertEqual(EncoderKnobs.parse(retired), EncoderKnobs())
        XCTAssertEqual(EncoderKnobs.parse(retired).logFields, "prio_speed=1 quality=unset idle_refresh=off input_retag=1")
        let base = VideoSettings.tabletDefault
        XCTAssertEqual(base.applyingExperimentKnobs(retired), base.applyingExperimentKnobs([:]))
        XCTAssertEqual(StreamProfileLog.knobsField(retired), "-")
    }

    func testParseQuality() {
        XCTAssertEqual(EncoderKnobs.parseQuality("0"), 0)
        XCTAssertEqual(EncoderKnobs.parseQuality("1.0"), 1)
        XCTAssertEqual(EncoderKnobs.parseQuality(" 0.55 "), 0.55)
        for bad in [nil, "", "-0.1", "1.01", "nan", "inf", "x"] { XCTAssertNil(EncoderKnobs.parseQuality(bad), "\(bad ?? "nil")") }
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
        // T-204: `MATEBRIDGE_H264_PROFILE` is not read any more (constant High profile).
        XCTAssertEqual(h, o.applyingEnvironment(["MATEBRIDGE_CODEC": "h264", "MATEBRIDGE_BITRATE_KBPS": "60000"]))
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
        // T-087 option kept: resume frames.
        XCTAssertEqual(try XCTUnwrap(SharpnessBenchOptions.parse(["--sharpness-bench", "--resume-frames", "120"]))
            .get().resumeFrames, 120)
        // T-204: `--refresh-buffer` is gone; like any unknown argument it no longer changes the options.
        XCTAssertEqual(try XCTUnwrap(SharpnessBenchOptions.parse(["--sharpness-bench", "--refresh-buffer", "copy"]))
            .get(), SharpnessBenchOptions())
    }

    // MARK: Profile line (T-204)

    private let build = BuildInfo(version: "0.1", build: "20261003121314", sha: "65dc662-dirty")

    func testProfileWithEmptyEnvironmentListsNoKnobs() {
        let f = StreamProfileLog.fields(settings: .tabletDefault, encoderProfile: .fast, build: build, env: [:])
        XCTAssertEqual(f, "fps=60 bitrate_kbps=30000 bitrate_source=prefs codec=hevc encoder_profile=fast "
                       + "scale_permille=1000 refresh_hz=60 sha=65dc662-dirty knobs=-")
        XCTAssertTrue(StreamProfileLog.knobs([:]).isEmpty)
    }

    func testProfileListsSetKnobsWithValues() {
        let env = ["MATEBRIDGE_BITRATE_KBPS": "40000"]
        let s = VideoSettings.tabletDefault.applyingExperimentKnobs(env)
        let f = StreamProfileLog.fields(settings: s, encoderProfile: .fast, build: build, env: env)
        XCTAssertTrue(f.contains(" bitrate_kbps=40000 bitrate_source=env "), f)
        XCTAssertTrue(f.hasSuffix(" knobs=MATEBRIDGE_BITRATE_KBPS:40000"), f)
        // Allow-list order, not dictionary order; the T-177 step value keeps its commas.
        let many = ["MATEBRIDGE_AUDIO": "off", "MATEBRIDGE_FPS": "120", "MATEBRIDGE_BITRATE_STEP": "60000,15000@5s",
                    "MATEBRIDGE_ENCODER": "llrc"]
        XCTAssertEqual(StreamProfileLog.knobsField(many),
                       "MATEBRIDGE_FPS:120;MATEBRIDGE_ENCODER:llrc;MATEBRIDGE_BITRATE_STEP:60000,15000@5s;MATEBRIDGE_AUDIO:off")
    }

    func testProfileIgnoresRetiredAndUnknownKeys() {
        let env = ["MATEBRIDGE_IDLE_REFRESH_MS": "300", "MATEBRIDGE_INPUT_RETAG": "0", "MATEBRIDGE_PRIO_SPEED": "0",
                   "MATEBRIDGE_H264_PROFILE": "main", "MATEBRIDGE_FRAME_DELAY": "1", "MATEBRIDGE_VIDEO_SOCKET": "nw",
                   "MATEBRIDGE_CONTROL_SOCKET": "nw", "MATEBRIDGE_SIGN_IDENTITY": "someone", "HOME": "/Users/x",
                   "MATEBRIDGE_CODEC": "h264"]
        XCTAssertEqual(StreamProfileLog.knobsField(env), "MATEBRIDGE_CODEC:h264")
        let f = StreamProfileLog.fields(settings: .tabletDefault, encoderProfile: .fast, build: build, env: env)
        XCTAssertFalse(f.contains("IDLE_REFRESH"), f)
        XCTAssertFalse(f.contains("/Users"), f)
    }

    func testProfileValuesStayOneToken() {
        XCTAssertEqual(StreamProfileLog.knobsField(["MATEBRIDGE_SERVICE_CLASS": " a b=c;d\te "]),
                       "MATEBRIDGE_SERVICE_CLASS:a_b_c_d_e")
        XCTAssertEqual(StreamProfileLog.knobsField(["MATEBRIDGE_TCP_LOG": "  "]), "MATEBRIDGE_TCP_LOG:_")
        let long = String(repeating: "9", count: 200)
        XCTAssertEqual(StreamProfileLog.knobs(["MATEBRIDGE_FPS": long]).first?.value.count,
                       StreamProfileLog.maxValueLength)
        let f = StreamProfileLog.fields(settings: .tabletDefault, encoderProfile: .llrc, build: build,
                                        env: ["MATEBRIDGE_SERVICE_CLASS": "x y"])
        for token in f.split(separator: " ") { XCTAssertEqual(token.filter { $0 == "=" }.count, 1, String(token)) }
    }

    func testProfileShaComesFromBuildInfo() {
        let f = StreamProfileLog.fields(settings: .tabletDefault, encoderProfile: .fast, build: build, env: [:])
        XCTAssertTrue(f.contains(" sha=65dc662-dirty "), f)
        // The same `sha=` token as `ev=app_start` (T-145).
        XCTAssertTrue(build.logFields(os: "x").contains(" sha=65dc662-dirty "))
        let unknown = StreamProfileLog.fields(settings: .tabletDefault, encoderProfile: .fast,
                                              build: BuildInfo(infoDictionary: nil), env: [:])
        XCTAssertTrue(unknown.contains(" sha=unknown "), unknown)
    }

    func testProfileAllowListIsTheKeptHostKnobs() {
        let list = StreamProfileLog.knobAllowList
        XCTAssertEqual(Set(list).count, list.count)
        XCTAssertTrue(list.allSatisfy { $0.hasPrefix("MATEBRIDGE_") })
        for kept in ["MATEBRIDGE_FPS", "MATEBRIDGE_BITRATE_KBPS", "MATEBRIDGE_CODEC", "MATEBRIDGE_REFRESH",
                     "MATEBRIDGE_ENCODER", "MATEBRIDGE_QUALITY", "MATEBRIDGE_KEYFRAME_INTERVAL_S",
                     "MATEBRIDGE_WIFI_BITRATE_KBPS", "MATEBRIDGE_SERVICE_CLASS", "MATEBRIDGE_NOTSENT_LOWAT_KB",
                     "MATEBRIDGE_AUDIO", "MATEBRIDGE_SENDQ_LOG", "MATEBRIDGE_LAT_TRACE", "MATEBRIDGE_TCP_LOG",
                     "MATEBRIDGE_DISPLAY_KEEP_S", "MATEBRIDGE_BITRATE_STEP", "MATEBRIDGE_RATE_WINDOW_MS"] {
            XCTAssertTrue(list.contains(kept), kept)
        }
        for gone in ["MATEBRIDGE_IDLE_REFRESH_MS", "MATEBRIDGE_FRAME_DELAY", "MATEBRIDGE_PRIO_SPEED",
                     "MATEBRIDGE_H264_PROFILE", "MATEBRIDGE_INPUT_RETAG", "MATEBRIDGE_VIDEO_SOCKET",
                     "MATEBRIDGE_CONTROL_SOCKET"] {
            XCTAssertFalse(list.contains(gone), gone)
        }
    }
}
