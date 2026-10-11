import XCTest
@testable import MateBridgeCore

/// T-240 (decision 0033, PROTOCOL.md 0x05): `STREAM_PREFS.chroma` on the host. Wire codec, input priority
/// (`MATEBRIDGE_CHROMA` > prefs > default), the HDR10 rule, settings derivation, remembered prefs and log fields.
final class ChromaPrefsTests: XCTestCase {
    private let base = VideoSettings.tabletDefault
    private let dev = DeviceID(bytes: [UInt8](repeating: 0xC4, count: 16))!

    private func prefs(fps: UInt16 = 60, scale: UInt16 = 1000, kbps: UInt32 = 0, w: UInt16 = 0, h: UInt16 = 0,
                       dr: UInt8 = 0, chroma: UInt8 = 0) -> StreamPrefs {
        StreamPrefs(fps: fps, scalePermille: scale, bitrateKbps: kbps, displayWidthPx: w, displayHeightPx: h,
                    dynamicRange: dr, chroma: chroma)
    }

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

    func testSharpChromaFixtureRoundTrips() throws {
        let p = prefs(chroma: 1)
        XCTAssertEqual(try Message.streamPrefs(p).encode(), Fixtures.bytes("stream_prefs_sharp_chroma"))
        XCTAssertEqual(try decode(Fixtures.bytes("stream_prefs_sharp_chroma")), .streamPrefs(p))
        XCTAssertEqual(p.requestedChroma, .sharp)
    }

    func testRangeGroupWrittenWhenEitherFieldIsSet() throws {
        // chroma alone: display 0x0 and dynamic_range 0 are written before it (14 bytes).
        let sharp = try Message.streamPrefs(prefs(chroma: 1)).encode()
        XCTAssertEqual(sharp.count, 5 + 14)
        XCTAssertEqual(Array(sharp[13...]), [0, 0, 0, 0, 0, 1])
        // HDR10 + sharp: both bytes.
        let both = try Message.streamPrefs(prefs(w: 1848, h: 1214, dr: 1, chroma: 1)).encode()
        XCTAssertEqual(Array(both[13...]), [0x38, 0x07, 0xbe, 0x04, 1, 1])
        // Neither: the older 8/12-byte shapes stay (no range group).
        XCTAssertEqual(try Message.streamPrefs(prefs()).encode().count, 5 + 8)
        XCTAssertEqual(try Message.streamPrefs(prefs(w: 1848, h: 1214)).encode().count, 5 + 12)
        // The old HDR fixture (chroma 0) is byte-identical.
        XCTAssertEqual(try Message.streamPrefs(prefs(fps: 120, scale: 660, w: 1848, h: 1214, dr: 1)).encode(),
                       Fixtures.bytes("stream_prefs_hdr"))
    }

    func testUnknownChromaIsNormal() throws {
        for raw: UInt8 in [3, 0x7f, 0xff] {  // 2 is full colour since decision 0034
            let p = prefs(chroma: raw)
            // The wire value survives the codec untouched...
            XCTAssertEqual(try decode(try Message.streamPrefs(p).encode()), .streamPrefs(p))
            // ...and the host counts it as 0.
            XCTAssertEqual(p.normalized.chroma, 0, "\(raw)")
            XCTAssertEqual(p.requestedChroma, .normal)
            XCTAssertEqual(base.applying(p), base.applying(prefs()))
        }
        XCTAssertEqual(ChromaPreference(wire: 0), .normal)
        XCTAssertEqual(ChromaPreference(wire: 1), .sharp)
    }

    func testLongerPayloadKeepsChromaAndIgnoresTheTail() throws {
        let payload: [UInt8] = [0x3c, 0, 0xe8, 0x03, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0xAA, 0xBB]  // 14 + link group + tail
        XCTAssertEqual(try decode(frame(payload)), .streamPrefs(prefs(chroma: 1)))
    }

    // MARK: Policy: input priority

    func testPriorityEnvOverPrefsOverDefault() {
        // Default: nothing set -> today's 420.
        let none = ChromaPolicy.resolve(knob: .unset, preference: .normal)
        XCTAssertEqual(none, ChromaDecision(knob: .unset, source: .default, requested: .yuv420, applied: .yuv420,
                                            reason: nil))
        XCTAssertFalse(none.statsEnabled)
        XCTAssertEqual(none, ChromaPolicy.resolve(knob: .unset),
                       "no preference = the T-235 default")

        // Prefs: sharp -> sharp_nearest.
        let sharpDecision = ChromaPolicy.resolve(knob: .unset, preference: .sharp)
        XCTAssertEqual(sharpDecision.source, .prefs)
        XCTAssertEqual(sharpDecision.requested, .sharpNearest)
        XCTAssertEqual(sharpDecision.applied, .sharpNearest)
        XCTAssertNil(sharpDecision.reason)
        XCTAssertTrue(sharpDecision.statsEnabled, "the sharp path keeps its stats window")
        XCTAssertEqual(sharpDecision.applied.captureFormat, .bgra)

        // Env wins over prefs, whatever both say. An invalid or retired value is not set (T-302): see below.
        for raw in ["420", "sharp_nearest"] {
            let knob = ChromaKnob.parse(raw)
            for pref in [ChromaPreference.normal, .sharp] {
                let d = ChromaPolicy.resolve(knob: knob, preference: pref)
                XCTAssertEqual(d.source, .env, "\(raw) \(pref)")
                XCTAssertEqual(d, ChromaPolicy.resolve(knob: knob), "\(raw) \(pref)")
            }
        }
        // T-302: retired and invalid values do not override the tablet; its preference wins.
        for raw in ["sharp_bilinear", "444", "bogus"] {
            let knob = ChromaKnob.parse(raw)
            XCTAssertFalse(knob.isSet, raw)
            XCTAssertEqual(ChromaPolicy.resolve(knob: knob, preference: .normal).source, .default, raw)
            let d = ChromaPolicy.resolve(knob: knob, preference: .sharp)
            XCTAssertEqual(d.source, .prefs, raw)
            XCTAssertEqual(d.applied, .sharpNearest, "env=\(raw) + tablet chroma=1 -> sharp_nearest")
        }
        let envOff = ChromaPolicy.resolve(knob: .parse("420"), preference: .sharp)
        XCTAssertEqual(envOff.applied, .yuv420, "MATEBRIDGE_CHROMA=420 turns the tablet's choice off")
        XCTAssertEqual(envOff.applied.captureFormat, .yuv420FullRange)
    }

    func testMetalFallbackKeepsThePrefsSource() {
        let d = ChromaPolicy.resolve(knob: .unset, preference: .sharp)
            .fallingBack(.metalUnavailable)
        XCTAssertEqual(d.source, .prefs)
        XCTAssertEqual(d.requested, .sharpNearest)
        XCTAssertEqual(d.applied, .yuv420)
        XCTAssertFalse(d.statsEnabled, "no sharp path, no knob: no stats")
    }

    // MARK: HDR10 rule

    func testHDRIgnoresThePreference() {
        let d = ChromaPolicy.resolve(knob: .unset, preference: .sharp,
                                     dynamicRange: .hdr10)
        XCTAssertEqual(d.applied, .yuv420)
        XCTAssertEqual(d.reason, .hdr)
        XCTAssertEqual(d.source, .prefs)
        XCTAssertNil(d.applied.sharpUpsample)
        XCTAssertFalse(d.statsEnabled)
        let none = ChromaPolicy.resolve(knob: .unset, preference: .normal,
                                        dynamicRange: .hdr10)
        XCTAssertNil(none.reason, "nothing requested, nothing ignored")
        XCTAssertEqual(none.source, .default)
    }

    func testHDRSettingsCarryNormalChromaAndFallbackRestoresSharp() {
        let hdrSharp = prefs(fps: 120, scale: 660, w: 1848, h: 1214, dr: 1, chroma: 1)
        let hdr = base.applying(hdrSharp)
        XCTAssertEqual(hdr.dynamicRange, .hdr10)
        XCTAssertEqual(hdr.chromaPreference, .normal, "no effect under HDR10")
        XCTAssertEqual(hdr, base.applying(prefs(fps: 120, scale: 660, w: 1848, h: 1214, dr: 1)),
                       "toggling chroma under HDR10 is no change of the settings (no reconfigure)")
        // The SDR fallback re-applies the prefs without HDR: the choice takes effect.
        let sdr = base.applying(hdrSharp, allowHDR: false)
        XCTAssertEqual(sdr.dynamicRange, .sdr)
        XCTAssertEqual(sdr.chromaPreference, .sharp)
        let fixed = HDRFallback().revalidated(hdr, base: base, prefs: hdrSharp,
                                              allowGameDisplay: true)
        XCTAssertNil(fixed, "HDR still allowed: nothing to revalidate")
        var failed = HDRFallback()
        XCTAssertTrue(failed.startFailed(settings: hdr, reason: .captureFailed))
        XCTAssertEqual(failed.revalidated(hdr, base: base, prefs: hdrSharp,
                                          allowGameDisplay: true)?.chromaPreference, .sharp)
        // H.264 never runs HDR10, so the choice applies.
        var h264 = base
        h264.codec = .h264
        XCTAssertEqual(h264.applying(hdrSharp).chromaPreference, .sharp)
    }

    // MARK: Settings

    func testChangeKeepsTheDisplayButChangesTheSettings() {
        let normal = base.applying(prefs())
        let sharp = base.applying(prefs(chroma: 1))
        XCTAssertEqual(sharp.chromaPreference, .sharp)
        XCTAssertNotEqual(sharp, normal, "a new config_id and a capture + encoder restart")
        XCTAssertEqual(sharp.displayMode, normal.displayMode, "the virtual display is kept")
        XCTAssertTrue(sharp.sameDisplay(as: normal))
        XCTAssertEqual(DisplayReuse.decide(current: normal.displayMode, online: true, wanted: sharp.displayMode), .reuse)
        XCTAssertEqual(sharp.streamConfig(configID: 4), normal.streamConfig(configID: 4),
                       "STREAM_CONFIG does not carry the chroma choice")
        // Game display too.
        let game = base.applying(prefs(fps: 120, scale: 660, w: 1848, h: 1214, chroma: 1))
        XCTAssertEqual(game.chromaPreference, .sharp)
        XCTAssertEqual(game.displayModeText, "1848x1214@1x")
    }

    func testDefaultPathIsUnchanged() {
        // chroma = 0, no knob: the settings equal those of a prefs value without the field, and the encoder decision
        // is T-235's default (420f capture, no Metal pass, no stats window).
        XCTAssertEqual(base.chromaPreference, .normal)
        XCTAssertEqual(base.applying(prefs()).chromaPreference, .normal)
        let d = ChromaPolicy.resolve(knob: .unset, preference: base.applying(prefs()).chromaPreference)
        XCTAssertEqual(d.applied, .yuv420)
        XCTAssertEqual(d.applied.captureFormat, .yuv420FullRange)
        XCTAssertNil(d.applied.sharpUpsample)
        XCTAssertEqual(d.applied.expectedChromaFormatIdc, 1)
        XCTAssertFalse(d.statsEnabled)
        XCTAssertEqual(d, ChromaDecision(knob: .unset, applied: .yuv420, reason: nil),
                       "same as the encoder's T-235 initial decision")
    }

    // MARK: Remembered prefs

    func testRememberedPrefsCarryChroma() {
        let sharp = prefs(chroma: 1)
        XCTAssertEqual(StreamPrefsStorageCodec.encode(sharp), [60, 1000, 0, 0, 0, 0, 1])
        XCTAssertEqual(StreamPrefsStorageCodec.decode([60, 1000, 0, 0, 0, 0, 1]), sharp)
        let all = prefs(fps: 120, scale: 660, kbps: 40_000, w: 1848, h: 1214, dr: 1, chroma: 1)
        XCTAssertEqual(StreamPrefsStorageCodec.encode(all), [120, 660, 40_000, 1848, 1214, 1, 1])
        XCTAssertEqual(StreamPrefsStorageCodec.decode(StreamPrefsStorageCodec.encode(all)), all)
        // Older shapes unchanged: chroma 0 is not written.
        XCTAssertEqual(StreamPrefsStorageCodec.encode(prefs()), [60, 1000, 0])
        XCTAssertEqual(StreamPrefsStorageCodec.encode(prefs(w: 1848, h: 1214)), [60, 1000, 0, 1848, 1214])
        XCTAssertEqual(StreamPrefsStorageCodec.encode(prefs(dr: 1)), [60, 1000, 0, 0, 0, 1])
        XCTAssertEqual(StreamPrefsStorageCodec.decode([60, 1000, 0, 0, 0, 1])?.chroma, 0, "6 values: normal")
        // Unknown values are stored as 0 (normalized) and read back as 0; out of range is rejected.
        XCTAssertEqual(StreamPrefsStorageCodec.encode(prefs(chroma: 9)), [60, 1000, 0])
        XCTAssertEqual(StreamPrefsStorageCodec.decode([60, 1000, 0, 0, 0, 0, 9])?.chroma, 0)
        XCTAssertNil(StreamPrefsStorageCodec.decode([60, 1000, 0, 0, 0, 0, 256]))
        XCTAssertNil(StreamPrefsStorageCodec.decode([60, 1000, 0, 0, 0, 0, -1]))

        let store = InMemoryStreamPrefsStore()
        store.save(sharp, device: dev)
        XCTAssertEqual(store.load(device: dev)?.chroma, 1)
        let initial = VideoSettings.initialSettings(defaults: base, stored: store.load(device: dev))
        XCTAssertEqual(initial.chromaPreference, .sharp, "a reconnecting tablet starts on the sharp path")
        XCTAssertEqual(initial, base.applying(sharp), "its first STREAM_PREFS then changes nothing")
    }

    // MARK: Logs

    func testConfigLineSource() {
        let info = ChromaBitstreamInfo(chromaFormatIdc: 1, profileIdc: 1, vuiFullRange: true, chromaSampleLocTop: 1,
                                       parsed: true)
        let sharp = ChromaPolicy.resolve(knob: .unset, preference: .sharp)
        var l = ChromaConfigLog.line(sharp, info)
        XCTAssertEqual(l.level, .info)
        XCTAssertEqual(l.fields, "requested=sharp_nearest applied=sharp_nearest source=prefs chroma_format_idc=1 "
                       + "profile_idc=1 vui_full_range=1 chroma_loc=1")

        let none = ChromaPolicy.resolve(knob: .unset)
        l = ChromaConfigLog.line(none, ChromaBitstreamInfo(chromaFormatIdc: 1, profileIdc: 1, vuiFullRange: true,
                                                           parsed: true))
        XCTAssertEqual(l.level, .info)
        XCTAssertEqual(l.fields, "requested=420 applied=420 source=default chroma_format_idc=1 profile_idc=1 "
                       + "vui_full_range=1 chroma_loc=unset")

        let hdr = ChromaPolicy.resolve(knob: .unset, preference: .sharp,
                                       dynamicRange: .hdr10)
        l = ChromaConfigLog.line(hdr, ChromaBitstreamInfo(chromaFormatIdc: 1, profileIdc: 2, vuiFullRange: false,
                                                          parsed: true))
        XCTAssertEqual(l.level, .warning)
        XCTAssertTrue(l.fields.hasPrefix("requested=sharp_nearest applied=420 reason=hdr source=prefs "), l.fields)

        let env = ChromaPolicy.resolve(knob: .parse("420"), preference: .sharp)
        XCTAssertTrue(ChromaConfigLog.line(env, info).fields.hasPrefix(
            "requested=420 applied=420 source=env "))

        XCTAssertEqual(ChromaPreference.normal.logName, "normal")
        XCTAssertEqual(ChromaPreference.sharp.logName, "sharp")
    }
}
