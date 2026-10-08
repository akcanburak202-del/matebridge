import XCTest
@testable import MateBridgeCore

/// T-235: `MATEBRIDGE_CHROMA` parsing, the applied-mode decision and its fallbacks, capture formats, the
/// `chroma_config` / `chroma_stats` lines and the SPS chroma fields.
final class ChromaKnobTests: XCTestCase {
    func testParse() {
        XCTAssertEqual(ChromaKnob.parse(nil), .unset)
        XCTAssertEqual(ChromaKnob.parse(""), .unset)
        XCTAssertEqual(ChromaKnob.parse("  "), .unset)
        XCTAssertEqual(ChromaKnob.parse("420"), ChromaKnob(requested: .yuv420, isSet: true, invalid: false))
        XCTAssertEqual(ChromaKnob.parse(" SHARP_Nearest "),
                       ChromaKnob(requested: .sharpNearest, isSet: true, invalid: false))
        // T-302: `444` and `sharp_bilinear` were removed: set, invalid, 4:2:0.
        for bad in ["444", "sharp_bilinear", "sharp", "422", "1", "yes", "4:4:4"] {
            XCTAssertEqual(ChromaKnob.parse(bad), ChromaKnob(requested: .yuv420, isSet: true, invalid: true), bad)
        }
        XCTAssertEqual(ChromaKnob.parse(env: ["MATEBRIDGE_CHROMA": "sharp_nearest"]).requested, .sharpNearest)
        XCTAssertEqual(ChromaKnob.parse(env: [:]), .unset)
    }

    func testResolve() {
        func r(_ m: String) -> ChromaDecision { ChromaPolicy.resolve(knob: .parse(m)) }
        XCTAssertEqual(ChromaPolicy.resolve(knob: .unset).applied, .yuv420)
        XCTAssertNil(ChromaPolicy.resolve(knob: .unset).reason)
        for m in ["sharp_nearest", "420"] {
            XCTAssertEqual(r(m).applied.rawValue, m)
            XCTAssertNil(r(m).reason)
        }
        XCTAssertEqual(r("bogus").applied, .yuv420)
        XCTAssertNil(r("bogus").reason)
        XCTAssertEqual(r("444").applied, .yuv420)
        XCTAssertTrue(r("444").knob.invalid)
    }

    func testFallingBackKeepsTheRequest() {
        let d = ChromaPolicy.resolve(knob: .parse("sharp_nearest")).fallingBack(.metalUnavailable)
        XCTAssertEqual(d.requested, .sharpNearest)
        XCTAssertEqual(d.applied, .yuv420)
        XCTAssertEqual(d.reason, .metalUnavailable)
        XCTAssertEqual(d.applied.captureFormat, .yuv420FullRange)
    }

    func testCaptureFormatAndExpectations() {
        // Default path: today's 420f capture.
        XCTAssertEqual(ChromaMode.yuv420.captureFormat, .yuv420FullRange)
        XCTAssertEqual(ChromaMode.sharpNearest.captureFormat, .bgra)
        XCTAssertEqual(ChromaMode.sharpNearest.sharpUpsample, .nearest)
        XCTAssertNil(ChromaMode.yuv420.sharpUpsample)
        XCTAssertNil(ChromaMode.packed444.sharpUpsample)
        XCTAssertEqual(ChromaMode.sharpNearest.expectedChromaFormatIdc, 1)
        XCTAssertEqual(ChromaMode.packed444.expectedChromaFormatIdc, 1)
    }

    func testStatsOnlyWhenSetOrSharp() {
        XCTAssertFalse(ChromaPolicy.resolve(knob: .unset).statsEnabled)
        XCTAssertTrue(ChromaPolicy.resolve(knob: .parse("420")).statsEnabled)
        XCTAssertTrue(ChromaPolicy.resolve(knob: .parse("x")).statsEnabled)
    }

    func testEncoderConfigFieldOnlyWhenSet() {
        var k = EncoderKnobs()
        let base = k.logFields
        XCTAssertFalse(base.contains("chroma"))
        XCTAssertEqual(EncoderKnobs.parse([:]).logFields, base)
        k.chroma = .parse("sharp_nearest")
        XCTAssertEqual(k.logFields, base + " chroma=sharp_nearest")
        k.chroma = .parse("nope")
        XCTAssertEqual(k.logFields, base + " chroma=invalid")
        XCTAssertTrue(EncoderKnobs.parse(["MATEBRIDGE_CHROMA": "444"]).chroma.invalid)
    }

    func testProfileKnobsListsChroma() {
        XCTAssertTrue(StreamProfileLog.knobAllowList.contains(ChromaKnob.envKey))
        XCTAssertEqual(StreamProfileLog.knobsField(["MATEBRIDGE_CHROMA": "sharp_nearest"]),
                       "MATEBRIDGE_CHROMA:sharp_nearest")
    }

    func testConfigLine() {
        let sharp = ChromaPolicy.resolve(knob: .parse("sharp_nearest"))
        var l = ChromaConfigLog.line(sharp, ChromaBitstreamInfo(chromaFormatIdc: 1, profileIdc: 1, vuiFullRange: true,
                                                                chromaSampleLocTop: 1, parsed: true))
        XCTAssertEqual(l.level, .info)
        XCTAssertEqual(l.fields, "requested=sharp_nearest applied=sharp_nearest source=env chroma_format_idc=1 "
                       + "profile_idc=1 vui_full_range=1 chroma_loc=1")

        // VideoToolbox writing a 4:4:4 SPS for a 4:2:0 mode is a mismatch.
        l = ChromaConfigLog.line(sharp, ChromaBitstreamInfo(chromaFormatIdc: 3, profileIdc: 4, vuiFullRange: false,
                                                            chromaSampleLocTop: nil, parsed: true))
        XCTAssertEqual(l.level, .warning)
        XCTAssertTrue(l.fields.hasSuffix(" mismatch=1"), l.fields)

        let invalid = ChromaPolicy.resolve(knob: .parse("zzz"))
        l = ChromaConfigLog.line(invalid, ChromaBitstreamInfo(chromaFormatIdc: 1, profileIdc: 100))
        XCTAssertEqual(l.level, .warning)
        XCTAssertEqual(l.fields, "requested=420 applied=420 reason=invalid_value source=env chroma_format_idc=1 "
                       + "profile_idc=100 vui_full_range=unknown chroma_loc=unknown")

        l = ChromaConfigLog.line(sharp.fallingBack(.metalUnavailable), ChromaBitstreamInfo())
        XCTAssertEqual(l.level, .warning)
        XCTAssertEqual(l.fields, "requested=sharp_nearest applied=420 reason=metal_unavailable source=env "
                       + "chroma_format_idc=unknown profile_idc=unknown vui_full_range=unknown chroma_loc=unknown")
    }

    func testStatsWindow() {
        var w = ChromaStatsWindow(mode: .sharpNearest, startUs: 1_000_000)
        for i in 1...100 { w.recordConversion(wallUs: UInt64(i * 10), gpuUs: UInt64(i * 4)) }
        for i in 1...10 { w.recordEncoded(captureToEncodeUs: UInt64(i * 1000)) }
        w.recordConversionFailure()
        XCTAssertNil(w.take(nowUs: 1_000_000 + ChromaStatsWindow.windowUs - 1))
        XCTAssertNil(w.take(nowUs: 0))  // clock before the start: never due
        let f = w.take(nowUs: 1_000_000 + ChromaStatsWindow.windowUs)
        XCTAssertEqual(f, "mode=sharp_nearest frames=10 conv_ms_p50_95=0.50/0.95 gpu_ms_p50_95=0.20/0.38 "
                       + "cap_enc_ms_p50_95=5.00/10.00 conv=100 conv_fail=1")
        // A new window starts empty at the time of the take.
        XCTAssertNil(w.take(nowUs: 1_000_000 + ChromaStatsWindow.windowUs + 5))
        XCTAssertEqual(w.take(nowUs: 1_000_000 + 2 * ChromaStatsWindow.windowUs),
                       "mode=sharp_nearest frames=0 conv_ms_p50_95=- gpu_ms_p50_95=- cap_enc_ms_p50_95=- conv=0 conv_fail=0")
    }

    func testStatsWindowIsBounded() {
        var w = ChromaStatsWindow(mode: .packed444, startUs: 0)
        for _ in 0..<(ChromaStatsWindow.maxSamples + 500) {
            w.recordEncoded(captureToEncodeUs: 7000)
            w.recordConversion(wallUs: 1, gpuUs: 1)
        }
        let f = w.take(nowUs: ChromaStatsWindow.windowUs) ?? ""
        XCTAssertTrue(f.hasPrefix("mode=packed444 frames=\(ChromaStatsWindow.maxSamples + 500) "), f)
        XCTAssertTrue(f.contains(" cap_enc_ms_p50_95=7.00/7.00 "), f)
        XCTAssertTrue(f.contains(" conv=\(ChromaStatsWindow.maxSamples + 500) "), f)
    }

    // MARK: SPS chroma fields

    /// VideoToolbox HEVC Main SPS (640x480, sRGB/BT.709 full range), 420f input tagged
    /// `kCVImageBufferChromaLocation_Center`: VideoToolbox writes `chroma_loc_info` (type 1). Captured on the M6
    /// (scratch probe, T-235).
    static let spsMainCenter: [UInt8] = [
        0x42, 0x01, 0x01, 0x01, 0x60, 0x00, 0x00, 0x03, 0x00, 0xB0, 0x00, 0x00, 0x03, 0x00, 0x00, 0x03, 0x00, 0x5A,
        0xA0, 0x05, 0x02, 0x01, 0xE1, 0x62, 0x05, 0xE4, 0x91, 0x64, 0x55, 0xCB, 0x97, 0x2E, 0xA6, 0xE0, 0x21, 0xA0,
        0x34, 0x80, 0x40,
    ]
    /// The same without a chroma location attachment (and with `_Left`, the HEVC default): no `chroma_loc_info`.
    static let spsMainDefault: [UInt8] = Array(spsMainCenter.prefix(36)) + [0x20, 0x10]
    /// HEVC Main 4:4:4 SPS (`HEVC_Main444_AutoLevel`, fast path, BGRA input, 640x480).
    static let spsMain444: [UInt8] = [
        0x42, 0x01, 0x01, 0x04, 0x08, 0x00, 0x00, 0x03, 0x00, 0xBE, 0x08, 0x00, 0x00, 0x03, 0x00, 0x00, 0x5A, 0x90,
        0x00, 0xA0, 0x40, 0x3C, 0x2C, 0x40, 0xBC, 0x92, 0x2C, 0x8A, 0xB9, 0x72, 0xE5, 0xD4, 0xD4, 0x04, 0x34, 0x04,
        0x02,
    ]

    func testSPSSummaryMainWithChromaLocation() throws {
        let s = try XCTUnwrap(HEVCSPS.summary(sps: Self.spsMainCenter))
        XCTAssertEqual(s.generalProfileIdc, 1)
        XCTAssertEqual(s.chromaFormatIdc, 1)
        XCTAssertTrue(s.vuiPresent)
        XCTAssertEqual(s.vuiColor?.fullRange, true)
        XCTAssertEqual(s.vuiColor?.transferCharacteristics, 13)
        XCTAssertEqual(s.chromaSampleLocTop, 1)
    }

    func testSPSSummaryMainDefault() throws {
        let s = try XCTUnwrap(HEVCSPS.summary(sps: Self.spsMainDefault))
        XCTAssertEqual(s.chromaFormatIdc, 1)
        XCTAssertEqual(s.vuiColor?.fullRange, true)
        XCTAssertNil(s.chromaSampleLocTop)
        // vuiColor is unchanged by the T-235 refactor.
        XCTAssertEqual(HEVCSPS.vuiColor(sps: Self.spsMainDefault), s.vuiColor)
    }

    func testSPSSummaryMain444() throws {
        let s = try XCTUnwrap(HEVCSPS.summary(sps: Self.spsMain444))
        XCTAssertEqual(s.generalProfileIdc, 4)
        XCTAssertEqual(s.chromaFormatIdc, 3)
        let info = ChromaBitstreamInfo.parse(parameterSets: [[0x40, 0x01, 0x0C], Self.spsMain444], codec: .hevc)
        XCTAssertEqual(info.chromaFormatIdc, 3)
        XCTAssertEqual(info.profileIdc, 4)
        XCTAssertTrue(info.parsed)
    }

    func testSPSSummaryRejectsGarbage() {
        XCTAssertNil(HEVCSPS.summary(sps: []))
        XCTAssertNil(HEVCSPS.summary(sps: [0x40, 0x01, 0x0C, 0x01]))  // VPS
        XCTAssertNil(HEVCSPS.summary(sps: Array(Self.spsMain444.prefix(8))))
        XCTAssertEqual(ChromaBitstreamInfo.parse(parameterSets: [], codec: .hevc), ChromaBitstreamInfo())
    }

    func testH264ChromaFormat() {
        // High profile (100), sps id 0 (ue "1"), chroma_format_idc 1 (ue "010"): 0b1010_0000.
        XCTAssertEqual(H264SPS.chromaFormatIdc([0x67, 100, 0x00, 52, 0b1010_0000]), 1)
        // High 4:4:4 Predictive (244), sps id 0, chroma 3 (ue "00100"): 0b1001_0000.
        XCTAssertEqual(H264SPS.chromaFormatIdc([0x67, 244, 0x00, 52, 0b1001_0000]), 3)
        // Main profile (77) has no chroma_format_idc: 4:2:0.
        XCTAssertEqual(H264SPS.chromaFormatIdc([0x67, 77, 0x40, 40, 0xFF]), 1)
        XCTAssertNil(H264SPS.chromaFormatIdc([0x68, 100, 0, 52, 0]))
        let info = ChromaBitstreamInfo.parse(parameterSets: [[0x67, 244, 0x00, 52, 0b1001_0000]], codec: .h264)
        XCTAssertEqual(info.chromaFormatIdc, 3)
        XCTAssertEqual(info.profileIdc, 244)
        XCTAssertFalse(info.parsed)
    }
}
