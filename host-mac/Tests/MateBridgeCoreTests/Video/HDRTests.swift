import CoreVideo
import XCTest
@testable import MateBridgeCore

/// T-237 (decision 0032, PROTOCOL.md 0x03/0x05): HDR10 on the host. Wire codec edges, policy, fallback, display
/// identity, remembered prefs, metadata bytes and log fields.
final class HDRTests: XCTestCase {
    private let base = VideoSettings.tabletDefault
    private let dev = DeviceID(bytes: [UInt8](repeating: 0xE7, count: 16))!

    private func prefs(fps: UInt16 = 120, scale: UInt16 = 660, kbps: UInt32 = 0, w: UInt16 = 0, h: UInt16 = 0,
                       dr: UInt8 = 0) -> StreamPrefs {
        StreamPrefs(fps: fps, scalePermille: scale, bitrateKbps: kbps, displayWidthPx: w, displayHeightPx: h,
                    dynamicRange: dr)
    }

    /// A STREAM_PREFS frame with a hand-made payload.
    private func frame(_ payload: [UInt8]) -> [UInt8] {
        let n = UInt32(payload.count)
        return [0x05, UInt8(n & 0xff), UInt8((n >> 8) & 0xff), UInt8((n >> 16) & 0xff), UInt8(n >> 24)] + payload
    }

    private func decode(_ bytes: [UInt8]) throws -> Message? {
        var d = FrameDecoder(connection: .control)
        d.append(bytes)
        return try d.nextMessage()
    }

    // MARK: Wire codec

    func testSDRPrefsEncodeExactlyAsBefore() throws {
        XCTAssertEqual(try Message.streamPrefs(prefs(fps: 120, scale: 750)).encode(), Fixtures.bytes("stream_prefs"))
        XCTAssertEqual(try Message.streamPrefs(prefs(kbps: 60000, w: 1848, h: 1214)).encode(),
                       Fixtures.bytes("stream_prefs_game_display"))
        XCTAssertEqual(try Message.streamPrefs(prefs(fps: 120, scale: 1000, kbps: 40000)).encode(),
                       Fixtures.bytes("stream_prefs_bitrate"))
    }

    func testHDRWithoutGameDisplayWritesAZeroDisplayGroup() throws {
        let p = prefs(fps: 120, scale: 1000, dr: 1)
        let bytes = try Message.streamPrefs(p).encode()
        XCTAssertEqual(bytes.count, 5 + 14)
        XCTAssertEqual(Array(bytes[13...]), [0, 0, 0, 0, 1, 0], "display 0x0, dynamic_range 1, chroma 0")
        XCTAssertEqual(try decode(bytes), .streamPrefs(p))
    }

    func testLongerPayloadIsAcceptedAndTheTailIgnored() throws {
        let payload: [UInt8] = [0x78, 0, 0x94, 0x02, 0, 0, 0, 0, 0x38, 0x07, 0xbe, 0x04, 1, 0, 0xAA, 0xBB, 0xCC]
        XCTAssertEqual(try decode(frame(payload)), .streamPrefs(prefs(w: 1848, h: 1214, dr: 1)))
    }

    func testShortGroupsAreRejected() {
        let full: [UInt8] = [0x78, 0, 0x94, 0x02, 0, 0, 0, 0, 0x38, 0x07, 0xbe, 0x04, 1, 0]
        for n in [9, 10, 11, 13] {
            XCTAssertThrowsError(try decode(frame(Array(full.prefix(n)))), "\(n) bytes") {
                XCTAssertEqual($0 as? ProtocolError, .payloadTooShort(type: 0x05), "\(n) bytes")
            }
        }
        for n in [8, 12, 14] {
            XCTAssertNoThrow(try decode(frame(Array(full.prefix(n)))), "\(n) bytes")
        }
    }

    func testUnknownDynamicRangeIsSDR() throws {
        for raw: UInt8 in [2, 3, 0x7f, 0xff] {
            let p = prefs(w: 1848, h: 1214, dr: raw)
            // The wire value survives the codec untouched...
            XCTAssertEqual(try decode(try Message.streamPrefs(p).encode()), .streamPrefs(p))
            // ...and the host counts it as 0.
            XCTAssertEqual(p.normalized.dynamicRange, 0, "\(raw)")
            XCTAssertEqual(p.requestedDynamicRange, .sdr)
            let s = base.applying(p)
            XCTAssertEqual(s.dynamicRange, .sdr)
            XCTAssertEqual(s, base.applying(prefs(w: 1848, h: 1214)))
        }
        XCTAssertEqual(DynamicRange(wire: 1), .hdr10)
        XCTAssertEqual(DynamicRange(wire: 0), .sdr)
    }

    // MARK: Policy and STREAM_CONFIG

    func testPolicyDecisions() {
        XCTAssertEqual(HDRPolicy.decide(requested: .sdr, codec: .hevc, allowed: true), .sdr)
        XCTAssertEqual(HDRPolicy.decide(requested: .sdr, codec: .h264, allowed: false), .sdr)
        XCTAssertEqual(HDRPolicy.decide(requested: .hdr10, codec: .hevc, allowed: true), .hdr10)
        XCTAssertEqual(HDRPolicy.decide(requested: .hdr10, codec: .h264, allowed: true), .fallback(.codecNotHEVC))
        XCTAssertEqual(HDRPolicy.decide(requested: .hdr10, codec: .hevc, allowed: false), .fallback(.disabled))
        XCTAssertEqual(HDRPolicy.Decision.fallback(.disabled).applied, .sdr)
        XCTAssertEqual(HDRPolicy.Decision.hdr10.applied, .hdr10)
        XCTAssertNil(HDRPolicy.Decision.hdr10.reason)
        XCTAssertEqual(HDRPolicy.Decision.fallback(.codecNotHEVC).reason, .codecNotHEVC)
    }

    func testHDRRequestGivesHDR10SettingsAndTheFixtureConfig() throws {
        let s = base.applying(prefs(kbps: 60000, w: 1848, h: 1214, dr: 1))
        XCTAssertEqual(s.dynamicRange, .hdr10)
        XCTAssertEqual(s.displayModeText, "1848x1214@1x", "works with the game display (decision 0029)")
        let cfg = s.streamConfig(configID: 3)
        XCTAssertEqual([cfg.colorPrimaries, cfg.transfer, cfg.matrix], [9, 16, 9])
        XCTAssertFalse(cfg.fullRange)
        XCTAssertEqual(try Message.streamConfig(cfg).encode(), Fixtures.bytes("stream_config_hdr10"))
        // The native display carries HDR10 too (the client only asks in game mode; the host does not require it).
        let native = base.applying(prefs(fps: 60, scale: 1000, dr: 1))
        XCTAssertEqual(native.dynamicRange, .hdr10)
        XCTAssertTrue(native.displayHiDPI)
    }

    func testSDRSettingsAndConfigAreUnchanged() throws {
        for p in [prefs(kbps: 60000, w: 1848, h: 1214), prefs(fps: 60, scale: 1000), prefs(fps: 144, scale: 750)] {
            let s = base.applying(p)
            XCTAssertEqual(s.dynamicRange, .sdr)
            XCTAssertEqual(s.displayTransfer, VirtualDisplayTransfer.parse(nil))
            XCTAssertEqual(s.displayMode.transfer, 0)
            let cfg = s.streamConfig(configID: 2)
            XCTAssertEqual([cfg.colorPrimaries, cfg.transfer, cfg.matrix], [1, 13, 1])
            XCTAssertTrue(cfg.fullRange)
        }
        let game = base.applying(prefs(kbps: 60000, w: 1848, h: 1214)).streamConfig(configID: 2)
        XCTAssertEqual(try Message.streamConfig(game).encode(), Fixtures.bytes("stream_config_game_display"))
        XCTAssertEqual(try Message.streamConfig(base.streamConfig(configID: 1)).encode().count,
                       Fixtures.bytes("stream_config").count)
    }

    func testEveryPolicyFallbackGivesSDR() {
        let h264 = base.applyingExperimentKnobs(["MATEBRIDGE_CODEC": "h264"])
        let a = h264.applying(prefs(w: 1848, h: 1214, dr: 1))
        XCTAssertEqual(a.dynamicRange, .sdr)
        XCTAssertEqual(a.streamConfig(configID: 1).transfer, 13)
        let b = base.applying(prefs(w: 1848, h: 1214, dr: 1), allowHDR: false)
        XCTAssertEqual(b.dynamicRange, .sdr)
        XCTAssertEqual(b, base.applying(prefs(w: 1848, h: 1214)), "exactly the SDR settings")
        XCTAssertEqual(VideoSettings.initialSettings(defaults: base, stored: prefs(dr: 1),
                                                     allowHDR: false).dynamicRange, .sdr)
    }

    func testDynamicRangeChangeIsANewConfigAndARecreatedDisplay() {
        let sdr = base.applying(prefs(w: 1848, h: 1214))
        let hdr = base.applying(prefs(w: 1848, h: 1214, dr: 1))
        // The coordinator sends a new config_id whenever the derived settings differ (applyPrefs).
        XCTAssertNotEqual(sdr, hdr)
        XCTAssertTrue(AnnouncedStreamConfigs.differs(sdr.streamConfig(configID: 1), hdr.streamConfig(configID: 1)))
        // The lease keeps the display identity (same native size) and asks for a reconfigure...
        var lease = DisplayLease()
        _ = lease.sessionStarted(device: dev, settings: sdr)
        XCTAssertEqual(lease.reconfigure(settings: hdr), [.reconfigure(hdr)])
        XCTAssertEqual(lease.reconfigure(settings: hdr), [], "the same request again changes nothing")
        // ...and the pipeline recreates the display: the transfer function is fixed at creation.
        XCTAssertEqual(hdr.displayMode.transfer, 1)
        XCTAssertEqual(DisplayReuse.decide(current: sdr.displayMode, online: true, wanted: hdr.displayMode),
                       .recreate(.transferChange))
        XCTAssertEqual(DisplayReuse.decide(current: hdr.displayMode, online: true, wanted: sdr.displayMode),
                       .recreate(.transferChange))
        XCTAssertEqual(DisplayReuse.decide(current: hdr.displayMode, online: true, wanted: hdr.displayMode), .reuse)
        XCTAssertEqual(DisplayReuse.decide(current: hdr.displayMode, online: false, wanted: hdr.displayMode),
                       .recreate(.offline))
        // Mode and refresh changes are reported first, as before.
        let native = base.applying(prefs(fps: 60, scale: 1000, dr: 1))
        XCTAssertEqual(DisplayReuse.decide(current: sdr.displayMode, online: true, wanted: native.displayMode),
                       .recreate(.modeChange))
        XCTAssertEqual(DisplayReuse.Reason.transferChange.logName, "transfer_change")
    }

    func testDeveloperKnobDisplayIsKeptAcrossDynamicRangeChanges() {
        let knob = base.applyingExperimentKnobs(["MATEBRIDGE_VD_TRANSFER": "1"])
        XCTAssertEqual(knob.vdTransferKnob, VirtualDisplayTransfer.Knob(requested: 1, invalid: false))
        let sdr = knob.applying(prefs(w: 1848, h: 1214))
        let hdr = knob.applying(prefs(w: 1848, h: 1214, dr: 1))
        XCTAssertEqual(sdr.displayTransfer.requested, 1, "SDR stream on an HDR display (T-232)")
        XCTAssertEqual(hdr.displayTransfer.requested, 1)
        XCTAssertEqual(DisplayReuse.decide(current: sdr.displayMode, online: true, wanted: hdr.displayMode), .reuse)
        // HDR10 does not need the knob; without it the default stays the legacy mode.
        XCTAssertEqual(base.applyingExperimentKnobs([:]).vdTransferKnob, VirtualDisplayTransfer.parse(nil))
        XCTAssertEqual(base.applying(prefs(dr: 1)).displayTransfer, VirtualDisplayTransfer.Knob(requested: 1, invalid: false))
        let invalid = base.applyingExperimentKnobs(["MATEBRIDGE_VD_TRANSFER": "7"])
        XCTAssertEqual(invalid.applying(prefs()).displayTransfer, VirtualDisplayTransfer.Knob(requested: 0, invalid: true))
    }

    // MARK: Runtime fallback

    func testEveryRuntimeFailureFallsBackOnceWithItsReason() {
        let hdr = base.applying(prefs(w: 1848, h: 1214, dr: 1))
        for reason in [HDRFallbackReason.displayRejected, .captureFailed, .encoderRejected] {
            var f = HDRFallback()
            XCTAssertTrue(f.allowsHDR)
            XCTAssertTrue(f.startFailed(settings: hdr, reason: reason), reason.rawValue)
            XCTAssertFalse(f.allowsHDR)
            XCTAssertEqual(f.failure, reason)
            // The re-applied prefs are SDR, which never falls back again.
            let sdr = base.applying(prefs(w: 1848, h: 1214, dr: 1), allowHDR: f.allowsHDR)
            XCTAssertEqual(sdr.dynamicRange, .sdr)
            XCTAssertEqual(sdr.streamConfig(configID: 4).transfer, 13)
            XCTAssertFalse(f.startFailed(settings: sdr, reason: reason))
        }
        XCTAssertEqual(HDRFallbackReason.displayRejected.rawValue, "display_rejected")
        XCTAssertEqual(HDRFallbackReason.captureFailed.rawValue, "capture_failed")
        XCTAssertEqual(HDRFallbackReason.encoderRejected.rawValue, "encoder_rejected")
        XCTAssertEqual(HDRFallbackReason.codecNotHEVC.rawValue, "codec_not_hevc")
        XCTAssertEqual(HDRFallbackReason.disabled.rawValue, "disabled")
    }

    func testOtherFailuresDoNotSwitchHDROff() {
        let hdr = base.applying(prefs(dr: 1))
        let sdr = base.applying(prefs())
        var f = HDRFallback()
        XCTAssertFalse(f.startFailed(settings: hdr, reason: nil), "not an HDR ring (permission, display sleep, …)")
        XCTAssertFalse(f.startFailed(settings: hdr, reason: .disabled), "policy reasons are not failures")
        XCTAssertFalse(f.startFailed(settings: hdr, reason: .codecNotHEVC))
        XCTAssertFalse(f.startFailed(settings: sdr, reason: .encoderRejected), "an SDR pipeline never falls back")
        XCTAssertTrue(f.allowsHDR)
    }

    func testQueuedSessionStartIsRevalidated() {
        let p = prefs(w: 1848, h: 1214, dr: 1)
        let hdr = base.applying(p)
        var f = HDRFallback()
        XCTAssertNil(f.revalidated(hdr, base: base, prefs: p, allowGameDisplay: true))
        _ = f.startFailed(settings: hdr, reason: .captureFailed)
        let fixed = f.revalidated(hdr, base: base, prefs: p, allowGameDisplay: true)
        XCTAssertEqual(fixed, base.applying(p, allowHDR: false))
        XCTAssertEqual(fixed?.displayModeText, "1848x1214@1x", "the game display stays")
        let noGame = f.revalidated(hdr, base: base, prefs: p, allowGameDisplay: false)
        XCTAssertEqual(noGame?.displayHiDPI, true)
        XCTAssertNil(f.revalidated(base.applying(prefs()), base: base, prefs: prefs(),
                                   allowGameDisplay: true), "SDR settings are valid")
        // The game display fallback re-applies without switching a disabled HDR back on.
        var g = GameDisplayFallback()
        _ = g.startFailed(settings: hdr, displayFailure: true)
        let afterGame = g.revalidated(hdr, base: base, prefs: p, allowHDR: false)
        XCTAssertEqual(afterGame?.dynamicRange, .sdr)
        XCTAssertEqual(g.revalidated(hdr, base: base, prefs: p)?.dynamicRange, .hdr10)
    }

    func testRefusedEncoderProperty() {
        XCTAssertNil(HDRPolicy.refusedEncoderProperty([]))
        XCTAssertNil(HDRPolicy.refusedEncoderProperty(["Quality=-12900", "DataRateLimits=-12900"]))
        XCTAssertEqual(HDRPolicy.refusedEncoderProperty(["Quality=-1", "ProfileLevel=-12900"]), "ProfileLevel=-12900")
        XCTAssertEqual(HDRPolicy.refusedEncoderProperty(["MasteringDisplayColorVolume=-12902"]),
                       "MasteringDisplayColorVolume=-12902")
        XCTAssertEqual(HDRPolicy.refusedEncoderProperty(["HDRMetadataInsertionMode=-12900"]),
                       "HDRMetadataInsertionMode=-12900")
        XCTAssertNil(HDRPolicy.refusedEncoderProperty(["ProfileLevelX=1"]), "exact names only")
        // Codex review: a failed VTCompressionSessionPrepareToEncodeFrames under HDR10 is an encoder refusal too.
        XCTAssertEqual(HDRPolicy.refusedEncoderProperty(["Quality=-1", "PrepareToEncodeFrames=-12902"]),
                       "PrepareToEncodeFrames=-12902")
    }

    // MARK: Display teardown (Codex review: unconsumed inherited display)

    private final class FakeDisplay {}

    func testFailedStartReleasesAnUnconsumedInheritedDisplay() {
        let inherited = FakeDisplay()
        // HDR10 encoder refused before obtainDisplay: no running display, the handed-over one is released, so the
        // SDR fallback can create its display (same vendor/product/serial) after the recreate gap.
        let failed = DisplayTeardown.plan(current: nil, inherited: inherited, keeping: false)
        XCTAssertNil(failed.keep)
        XCTAssertEqual(failed.release.count, 1)
        XCTAssertTrue(failed.release.first === inherited)
        // Running display only (normal stop): released; nothing at all: nothing to do.
        let current = FakeDisplay()
        let stop = DisplayTeardown.plan(current: current, inherited: nil, keeping: false)
        XCTAssertNil(stop.keep)
        XCTAssertTrue(stop.release.count == 1 && stop.release[0] === current)
        let none = DisplayTeardown.plan(current: nil as FakeDisplay?, inherited: nil, keeping: false)
        XCTAssertNil(none.keep)
        XCTAssertTrue(none.release.isEmpty)
        // Both (defensive): all released when not keeping.
        XCTAssertEqual(DisplayTeardown.plan(current: current, inherited: inherited, keeping: false).release.count, 2)
    }

    func testKeepingHandsOnOneDisplayAndReleasesTheRest() {
        let current = FakeDisplay(), inherited = FakeDisplay()
        let running = DisplayTeardown.plan(current: current, inherited: nil, keeping: true)
        XCTAssertTrue(running.keep === current)
        XCTAssertTrue(running.release.isEmpty)
        let unconsumed = DisplayTeardown.plan(current: nil, inherited: inherited, keeping: true)
        XCTAssertTrue(unconsumed.keep === inherited, "still alive: handed on instead of dropped")
        XCTAssertTrue(unconsumed.release.isEmpty)
        let both = DisplayTeardown.plan(current: current, inherited: inherited, keeping: true)
        XCTAssertTrue(both.keep === current)
        XCTAssertTrue(both.release.count == 1 && both.release[0] === inherited, "never two displays")
        let same = DisplayTeardown.plan(current: current, inherited: current, keeping: false)
        XCTAssertEqual(same.release.count, 1, "the same object is released once")
    }

    // MARK: Remembered prefs

    func testRememberedPrefsCarryTheDynamicRange() {
        let hdrGame = prefs(kbps: 40_000, w: 1848, h: 1214, dr: 1)
        XCTAssertEqual(StreamPrefsStorageCodec.encode(hdrGame), [120, 660, 40_000, 1848, 1214, 1])
        XCTAssertEqual(StreamPrefsStorageCodec.decode([120, 660, 40_000, 1848, 1214, 1]), hdrGame)
        let hdrNative = prefs(fps: 60, scale: 1000, dr: 1)
        XCTAssertEqual(StreamPrefsStorageCodec.encode(hdrNative), [60, 1000, 0, 0, 0, 1])
        XCTAssertEqual(StreamPrefsStorageCodec.decode(StreamPrefsStorageCodec.encode(hdrNative)), hdrNative)
        // SDR records keep their old shape; an unknown value is stored as 0 (normalized) and read back as 0.
        XCTAssertEqual(StreamPrefsStorageCodec.encode(prefs(w: 1848, h: 1214)), [120, 660, 0, 1848, 1214])
        XCTAssertEqual(StreamPrefsStorageCodec.encode(prefs(dr: 9)), [120, 660, 0])
        XCTAssertEqual(StreamPrefsStorageCodec.decode([120, 660, 0, 0, 0, 9])?.dynamicRange, 0)
        XCTAssertNil(StreamPrefsStorageCodec.decode([120, 660, 0, 0, 0, 256]))
        XCTAssertNil(StreamPrefsStorageCodec.decode([120, 660, 0, 0, 0, -1]))

        let store = InMemoryStreamPrefsStore()
        store.save(hdrGame, device: dev)
        XCTAssertEqual(store.load(device: dev)?.dynamicRange, 1)
        let initial = VideoSettings.initialSettings(defaults: base, stored: store.load(device: dev))
        XCTAssertEqual(initial.dynamicRange, .hdr10, "a reconnecting tablet starts in HDR10")
        XCTAssertEqual(initial.displayModeText, "1848x1214@1x")
        XCTAssertEqual(initial.streamConfig(configID: 1).transfer, 16)
    }

    // MARK: Metadata and colour tags

    func testHDR10MetadataBytes() {
        let md = HDR10Metadata.host
        XCTAssertEqual(md.mdcvSEI, [
            0x33, 0xC2, 0x86, 0xC4,  // green 0.265, 0.690
            0x1D, 0x4C, 0x0B, 0xB8,  // blue 0.150, 0.060
            0x84, 0xD0, 0x3E, 0x80,  // red 0.680, 0.320
            0x3D, 0x13, 0x40, 0x42,  // white D65 0.3127, 0.3290
            0x00, 0x98, 0x96, 0x80,  // max 1000 cd/m² (0.0001 units)
            0x00, 0x00, 0x00, 0x01,  // min 0.0001 cd/m²
        ])
        XCTAssertEqual(md.cllSEI, [0x03, 0xE8, 0x01, 0x90], "MaxCLL 1000, MaxFALL 400")
    }

    func testSessionColorTagsMatchCoreVideo() {
        XCTAssertEqual(SessionColorTags.hdr10, ColorTags(
            primaries: kCVImageBufferColorPrimaries_ITU_R_2020 as String,
            transfer: kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String,
            matrix: kCVImageBufferYCbCrMatrix_ITU_R_2020 as String))
        XCTAssertEqual(SessionColorTags.sdr, ColorTags(
            primaries: kCVImageBufferColorPrimaries_ITU_R_709_2 as String,
            transfer: kCVImageBufferTransferFunction_sRGB as String,
            matrix: kCVImageBufferYCbCrMatrix_ITU_R_709_2 as String))
        XCTAssertEqual(SessionColorTags.tags(for: .hdr10), SessionColorTags.hdr10)
        XCTAssertEqual(SessionColorTags.tags(for: .sdr), SessionColorTags.sdr)
        // An HDR capture already tagged like the session is not retagged; an SDR-tagged buffer is.
        XCTAssertFalse(InputRetag.needsRetag(buffer: SessionColorTags.hdr10, hasColorSpace: true,
                                             session: SessionColorTags.hdr10))
        XCTAssertTrue(InputRetag.needsRetag(buffer: SessionColorTags.sdr, hasColorSpace: true,
                                            session: SessionColorTags.hdr10))
    }

    // MARK: Chroma knob (T-235) with HDR10

    func testHDRWinsOverTheChromaKnob() {
        for raw in ["420", "sharp_nearest", "bogus"] {
            let knob = ChromaKnob.parse(raw)
            let d = ChromaPolicy.resolve(knob: knob, dynamicRange: .hdr10)
            XCTAssertEqual(d.applied, .yuv420, raw)
            XCTAssertEqual(d.reason, .hdr, raw)
            XCTAssertEqual(d.applied.captureFormat, .yuv420FullRange, "no BGRA / Metal pass")
            XCTAssertNil(d.applied.sharpUpsample)
            XCTAssertTrue(d.statsEnabled, "a set knob keeps its stats window")
            let line = ChromaConfigLog.line(d, ChromaBitstreamInfo(chromaFormatIdc: 1, profileIdc: 2,
                                                                  vuiFullRange: false, parsed: true))
            XCTAssertTrue(line.fields.hasPrefix("requested=\(knob.requested.rawValue) applied=420 reason=hdr "),
                          line.fields)
            XCTAssertFalse(line.fields.contains("mismatch"), "Main10 4:2:0 matches the applied 420")
            XCTAssertEqual(line.level, .warning)
        }
        // Unset knob with HDR: nothing to report, nothing logged.
        let unset = ChromaPolicy.resolve(knob: .unset, dynamicRange: .hdr10)
        XCTAssertEqual(unset.applied, .yuv420)
        XCTAssertNil(unset.reason)
        XCTAssertFalse(unset.statsEnabled)
        XCTAssertEqual(ChromaFallbackReason.hdr.rawValue, "hdr")
    }

    func testChromaKnobUnchangedForSDR() {
        for raw in [nil, "420", "sharp_nearest", "bogus"] {
            let knob = ChromaKnob.parse(raw)
            XCTAssertEqual(ChromaPolicy.resolve(knob: knob, dynamicRange: .sdr), ChromaPolicy.resolve(knob: knob),
                           raw ?? "unset")
        }
        XCTAssertEqual(ChromaPolicy.resolve(knob: .parse("sharp_nearest"),
                                            dynamicRange: .sdr).applied, .sharpNearest)
    }

    // MARK: Logs

    func testHDRConfigFields() {
        let hdr = base.applying(prefs(kbps: 60000, w: 1848, h: 1214, dr: 1))
        XCTAssertEqual(HDRLog.configFields(requested: .hdr10, settings: hdr, reason: nil),
                       "requested=1 applied=1 primaries=9 transfer=16 matrix=9 full_range=0 display_transfer=1 "
                       + "encoded=1848x1214 fps=120")
        let fellBack = base.applying(prefs(kbps: 60000, w: 1848, h: 1214, dr: 1), allowHDR: false)
        XCTAssertEqual(HDRLog.configFields(requested: .hdr10, settings: fellBack, reason: .disabled),
                       "requested=1 applied=0 reason=disabled primaries=1 transfer=13 matrix=1 full_range=1 "
                       + "display_transfer=0 encoded=1848x1214 fps=120")
        let sdr = base.applying(prefs(fps: 60, scale: 1000))
        XCTAssertEqual(HDRLog.configFields(requested: .sdr, settings: sdr, reason: .disabled),
                       "requested=0 applied=0 primaries=1 transfer=13 matrix=1 full_range=1 display_transfer=0 "
                       + "encoded=2800x1840 fps=60", "no reason when SDR was asked for")
    }

    func testHDRFallbackFields() {
        let sdr = base.applying(prefs(w: 1848, h: 1214, dr: 1), allowHDR: false)
        XCTAssertEqual(HDRLog.fallbackFields(reason: .encoderRejected, detail: "ProfileLevel=-12900", configID: 5,
                                             settings: sdr),
                       "reason=encoder_rejected detail=ProfileLevel_-12900 config_id=5 display=1848x1214@1x "
                       + "encoded=1848x1214")
        XCTAssertEqual(HDRLog.fallbackFields(reason: .displayRejected, detail: nil, configID: 2, settings: sdr),
                       "reason=display_rejected config_id=2 display=1848x1214@1x encoded=1848x1214")
        XCTAssertEqual(HDRLog.fallbackFields(reason: .captureFailed, detail: "a b;c", configID: 2, settings: sdr),
                       "reason=capture_failed detail=a_b_c config_id=2 display=1848x1214@1x encoded=1848x1214")
    }
}
