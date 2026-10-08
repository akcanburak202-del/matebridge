import XCTest
@testable import MateBridgeCore

/// T-258 (decision 0034, PROTOCOL.md 0x05 "Tam renk"): when packed full colour applies, the session consent rules, the
/// developer knob's priority, HDR, the runtime fallback and the keyframe request `view`.
final class FullChromaPolicyTests: XCTestCase {
    private func hello(_ caps: Capabilities) -> Hello {
        Hello(deviceID: DeviceID(bytes: [UInt8](repeating: 0xA1, count: 16))!, screenWidthPx: 2800, screenHeightPx: 1840,
              densityDpi: 360, maxRefreshHz: 144, capabilities: caps, deviceName: "t")
    }

    private func base(bit11: Bool = true) -> VideoSettings {
        VideoSettings.forTablet(hello(bit11 ? [.decodeHEVC, .fullChroma] : [.decodeHEVC]))
    }

    private func prefs(fps: UInt16 = 60, scale: UInt16 = 1000, w: UInt16 = 0, h: UInt16 = 0, dr: UInt8 = 0,
                       chroma: UInt8 = 2) -> StreamPrefs {
        StreamPrefs(fps: fps, scalePermille: scale, bitrateKbps: 0, displayWidthPx: w, displayHeightPx: h,
                    dynamicRange: dr, chroma: chroma)
    }

    private let session = FullChromaSession(prefsFromThisSession: true, allowed: true)

    // MARK: Conditions

    func testGunluk60NativeSdrIsGranted() {
        let s = base().applying(prefs(), fullChroma: session)
        XCTAssertTrue(s.fullChromaGranted)
        XCTAssertEqual(s.chromaPreference, .full)
        XCTAssertTrue(s.packedChroma)
        XCTAssertEqual(s.chromaLayout, 1)
        XCTAssertEqual(s.streamConfig(configID: 4).chromaLayout, 1)
    }

    func testOtherModesFallBackToSharp() {
        for p in [prefs(fps: 120), prefs(fps: 144), prefs(scale: 750), prefs(w: 1848, h: 1214), prefs(fps: 120, w: 1848, h: 1214, dr: 1)] {
            let s = base().applying(p, fullChroma: session)
            XCTAssertFalse(s.packedChroma, "\(p)")
            XCTAssertEqual(s.streamConfig(configID: 1).chromaLayout, 0)
            if s.dynamicRange == .hdr10 { XCTAssertEqual(s.chromaPreference, .normal) } else { XCTAssertEqual(s.chromaPreference, .sharp, "\(p)") }
        }
    }

    func testHdrKeepsNormalEvenAtThe60Mode() {
        let s = base().applying(prefs(dr: 1), fullChroma: session)
        XCTAssertEqual(s.dynamicRange, .hdr10)
        XCTAssertEqual(s.chromaPreference, .normal)
        XCTAssertFalse(s.packedChroma)
    }

    func testH264IsNotPacked() {
        var b = base()
        b.codec = .h264
        XCTAssertEqual(b.applying(prefs(), fullChroma: session).chromaPreference, .sharp)
    }

    // MARK: Session consent (Codex T-257)

    func testClientWithoutBit11IsNeverGranted() {
        let s = base(bit11: false).applying(prefs(), fullChroma: session)
        XCTAssertFalse(s.fullChromaGranted)
        XCTAssertEqual(s.chromaPreference, .sharp)
        XCTAssertEqual(s.chromaLayout, 0)
    }

    func testRememberedPrefsCountAsSharpUntilThisSessionsPrefsArrive() {
        let remembered = base().applying(prefs())  // default FullChromaSession: not from this session
        XCTAssertFalse(remembered.fullChromaGranted)
        XCTAssertEqual(remembered.chromaPreference, .sharp)
        XCTAssertEqual(VideoSettings.initialSettings(defaults: base(), stored: prefs()).chromaLayout, 0)
        let live = base().applying(prefs(), fullChroma: session)
        XCTAssertNotEqual(remembered, live, "this session's prefs make a reconfiguration")
    }

    func testPackedChromaPreferenceIsNormalizedAndKept() {
        XCTAssertEqual(prefs(chroma: 2).normalized.chroma, 2)
        XCTAssertEqual(prefs(chroma: 2).requestedChroma, .full)
        XCTAssertEqual(ChromaPreference(wire: 2), .full)
        XCTAssertEqual(ChromaPreference.full.logName, "full")
    }

    // MARK: Developer knob

    func testKnobPackedStillNeedsTheSessionGrant() {
        var b = base()
        b.chromaKnob = .parse("packed444")
        XCTAssertTrue(b.applying(prefs(), fullChroma: session).packedChroma)
        XCTAssertFalse(b.applying(prefs()).packedChroma, "remembered prefs cannot grant it")
        XCTAssertFalse(b.applying(prefs(chroma: 0), fullChroma: session).packedChroma)
        XCTAssertFalse(b.applying(prefs(fps: 120), fullChroma: session).packedChroma)
        var old = base(bit11: false)
        old.chromaKnob = .parse("packed444")
        XCTAssertFalse(old.applying(prefs(), fullChroma: session).packedChroma)
    }

    func testOtherKnobValuesWinOverTheTablet() {
        for raw in ["420", "sharp_nearest"] {
            var b = base()
            b.chromaKnob = .parse(raw)
            XCTAssertFalse(b.applying(prefs(), fullChroma: session).packedChroma, raw)
        }
    }

    /// T-302: a retired (`444`, `sharp_bilinear`) or invalid value is not a set knob: the tablet's full colour wins.
    func testRetiredKnobValuesDoNotBlockTheTablet() {
        for raw in ["444", "sharp_bilinear", "bogus"] {
            var b = base()
            b.chromaKnob = .parse(raw)
            XCTAssertTrue(b.applying(prefs(), fullChroma: session).packedChroma, raw)
            let d = ChromaPolicy.resolve(knob: b.chromaKnob, preference: .full, packedChroma: true)
            XCTAssertEqual(d.applied, .packed444, raw)
            XCTAssertEqual(d.source, .prefs, raw)
        }
    }

    func testEncoderPolicy() {
        // Tablet choice: full -> packed444 when granted.
        let full = ChromaPolicy.resolve(knob: .unset, preference: .full, packedChroma: true)
        XCTAssertEqual(full.applied, .packed444)
        XCTAssertEqual(full.source, .prefs)
        XCTAssertNil(full.reason)
        // Knob packed444 without the grant: the sharp path, with the reason.
        let denied = ChromaPolicy.resolve(knob: .parse("packed444"), packedChroma: false)
        XCTAssertEqual(denied.applied, .sharpNearest)
        XCTAssertEqual(denied.reason, .fullChromaDenied)
        XCTAssertEqual(denied.source, .env)
        let granted = ChromaPolicy.resolve(knob: .parse("packed444"), packedChroma: true)
        XCTAssertEqual(granted.applied, .packed444)
        // HDR wins over everything.
        let hdr = ChromaPolicy.resolve(knob: .parse("packed444"), dynamicRange: .hdr10,
                                       packedChroma: true)
        XCTAssertEqual(hdr.applied, .yuv420)
        XCTAssertEqual(hdr.reason, .hdr)
        XCTAssertTrue(full.statsEnabled)
        XCTAssertEqual(ChromaMode.packed444.captureFormat, .bgra)
        XCTAssertEqual(ChromaMode.packed444.expectedChromaFormatIdc, 1)
    }

    func testChromaConfigLogNamesTheLayoutAndStream() {
        let d = ChromaPolicy.resolve(knob: .unset, preference: .full, packedChroma: true)
        let info = ChromaBitstreamInfo(chromaFormatIdc: 1, profileIdc: 1, vuiFullRange: true, chromaSampleLocTop: nil, parsed: true)
        XCTAssertTrue(ChromaConfigLog.line(d, info).fields.hasSuffix("layout=packed444 view=main"))
        XCTAssertTrue(ChromaConfigLog.line(d, info, view: "aux").fields.hasSuffix("layout=packed444 view=aux"))
        XCTAssertEqual(ChromaConfigLog.line(d, info).level, .info)
        let plain = ChromaPolicy.resolve(knob: .unset, preference: .normal)
        XCTAssertFalse(ChromaConfigLog.line(plain, info).fields.contains("layout="))
    }

    // MARK: Runtime fallback

    func testFallbackIsNormalNotSharpAndKeepsThePreference() {
        let fell = base().applying(prefs(), fullChroma: FullChromaSession(prefsFromThisSession: true, allowed: false))
        XCTAssertEqual(fell.chromaPreference, .normal)
        XCTAssertFalse(fell.packedChroma)
        XCTAssertEqual(fell.chromaLayout, 0)
        // A request that never qualified stays sharp even in the fallback state.
        let other = base().applying(prefs(fps: 120), fullChroma: FullChromaSession(prefsFromThisSession: true, allowed: false))
        XCTAssertEqual(other.chromaPreference, .sharp)
    }

    func testRuntimeFallbackIsNormalEvenWithThePackedKnob() {
        var b = base()
        b.chromaKnob = .parse("packed444")
        let fell = b.applying(prefs(), fullChroma: FullChromaSession(prefsFromThisSession: true, allowed: false))
        XCTAssertTrue(fell.fullChromaFellBack)
        XCTAssertFalse(fell.packedChroma)
        let d = ChromaPolicy.resolve(knob: fell.chromaKnob, preference: fell.chromaPreference, packedChroma: fell.packedChroma, packedFellBack: fell.fullChromaFellBack)
        XCTAssertEqual(d.applied, .yuv420, "normal 4:2:0, not sharp")
        XCTAssertEqual(d.reason, .fullChromaFallback)
        // An ungranted request (no consent) is still the sharp path.
        let denied = b.applying(prefs())
        XCTAssertFalse(denied.fullChromaFellBack)
        XCTAssertEqual(ChromaPolicy.resolve(knob: denied.chromaKnob, preference: denied.chromaPreference, packedChroma: false,
                                            packedFellBack: denied.fullChromaFellBack).applied, .sharpNearest)
        // A fresh grant clears the flag.
        XCTAssertFalse(b.applying(prefs(), fullChroma: session).fullChromaFellBack)
    }

    func testStreamModeChangeIsDetectedIgnoringChromaAndBitrate() {
        let a = base().applying(prefs(), fullChroma: session)
        let b = base().applying(prefs(chroma: 0))
        XCTAssertTrue(a.sameStreamMode(as: b))
        XCTAssertFalse(a.sameStreamMode(as: base().applying(prefs(fps: 120))))
        XCTAssertFalse(a.sameStreamMode(as: base().applying(prefs(scale: 800))))
        XCTAssertFalse(a.sameStreamMode(as: base().applying(prefs(w: 1848, h: 1214))))
        XCTAssertFalse(a.sameStreamMode(as: base().applying(prefs(dr: 1))))
    }

    // MARK: Keyframe view (decision 0034, PROTOCOL.md 0x23)

    func testKeyframeViewValues() {
        XCTAssertEqual(KeyframeView(wire: 0), .main)
        XCTAssertEqual(KeyframeView(wire: 1), .auxiliary)
        XCTAssertEqual(KeyframeView(wire: 2), .both)
        XCTAssertEqual(KeyframeView(wire: 9), .both)
        XCTAssertTrue(KeyframeView.both.wantsMain && KeyframeView.both.wantsAuxiliary)
        XCTAssertFalse(KeyframeView.main.wantsAuxiliary)
        XCTAssertFalse(KeyframeView.auxiliary.wantsMain)
        XCTAssertEqual(KeyframeView.main.merged(with: .auxiliary), .both)
        XCTAssertEqual(KeyframeView.main.merged(with: .main), .main)
        XCTAssertEqual(KeyframeView.auxiliary.merged(with: .auxiliary), .auxiliary)
    }

    func testKeyframeRequestWireView() throws {
        func decode(_ payload: [UInt8]) throws -> Message? {
            try Message.decode(type: 0x23, payload: payload)
        }
        XCTAssertEqual(try decode([1]), .keyframeRequest(.decodeError, view: nil))
        XCTAssertEqual(try decode([1, 0]), .keyframeRequest(.decodeError, view: .main))
        XCTAssertEqual(try decode([1, 1]), .keyframeRequest(.decodeError, view: .auxiliary))
        XCTAssertEqual(try decode([2, 7]), .keyframeRequest(.framesDropped, view: .both), "unknown view = both")
        XCTAssertEqual(try decode([1, 1, 0xEE]), .keyframeRequest(.decodeError, view: .auxiliary), "long payload")
        XCTAssertEqual(try Message.keyframeRequest(.startup).encodePayload(), [0])
        XCTAssertEqual(try Message.keyframeRequest(.startup, view: .auxiliary).encodePayload(), [0, 1])
        XCTAssertThrowsError(try decode([]))
    }

    func testVideoFrameViewWireAndEncodedFrame() throws {
        var e = EncodedVideoFrame(flags: .keyframe, captureTimeUs: 5, data: [1, 2])
        XCTAssertEqual(e.toVideoFrame(seq: 3).view, 0)
        e.view = 1
        XCTAssertEqual(e.toVideoFrame(seq: 3).view, 1)
        let bytes = try Message.videoFrame(e.toVideoFrame(seq: 3)).encode()
        XCTAssertEqual(bytes[5 + 13], 1, "view is the byte after flags")
    }
}
