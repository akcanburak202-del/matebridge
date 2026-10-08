import XCTest
@testable import MateBridgeCore

/// T-281: `MATEBRIDGE_VD_PRIMARIES` parsing, the primaries decision (HDR -> p3, SDR -> none, `default` -> none), the
/// descriptor properties and selector fallback, `DisplayReuse` with primaries, and the `ev=vd_transfer` fields.
final class VirtualDisplayPrimariesTests: XCTestCase {
    typealias P = VirtualDisplayPrimaries
    typealias T = VirtualDisplayTransfer

    // MARK: Parsing

    func testParseUnsetIsAutomatic() {
        for raw in [nil, "", "  ", "\n"] {
            XCTAssertEqual(P.parse(raw), P.Knob(requested: nil, invalid: false), String(describing: raw))
        }
        XCTAssertEqual(P.parse(env: [:]), P.Knob(requested: nil, invalid: false))
    }

    func testParseDefaultAndP3() {
        XCTAssertEqual(P.parse("default"), P.Knob(requested: .default, invalid: false))
        XCTAssertEqual(P.parse(" Default "), P.Knob(requested: .default, invalid: false))
        XCTAssertEqual(P.parse("p3"), P.Knob(requested: .p3, invalid: false))
        XCTAssertEqual(P.parse("P3\n"), P.Knob(requested: .p3, invalid: false))
        XCTAssertEqual(P.parse(env: ["MATEBRIDGE_VD_PRIMARIES": "default"]), P.Knob(requested: .default, invalid: false))
    }

    func testParseInvalidIsP3AndFlagged() {
        for raw in ["0", "1", "srgb", "display-p3", "p3 p3", "2020"] {
            XCTAssertEqual(P.parse(raw), P.Knob(requested: .p3, invalid: true), raw)
        }
    }

    // MARK: Decision

    func testDecideHDRDefaultsToP3() {
        XCTAssertEqual(P.decide(transferRequested: 1, knob: P.parse(nil)), .p3)
        XCTAssertEqual(P.decide(transferRequested: 1, knob: P.parse("p3")), .p3)
        XCTAssertEqual(P.decide(transferRequested: 1, knob: P.parse("bogus")), .p3)
    }

    func testDecideSDRNeverGetsPrimaries() {
        for raw in [nil, "default", "p3", "bogus"] {
            XCTAssertEqual(P.decide(transferRequested: 0, knob: P.parse(raw)), .default, String(describing: raw))
        }
    }

    func testDecideDefaultKnobSwitchesP3Off() {
        XCTAssertEqual(P.decide(transferRequested: 1, knob: P.parse("default")), .default)
    }

    func testSettingsFollowTransfer() {
        var hdr = VideoSettings.tabletDefault
        hdr.dynamicRange = .hdr10
        XCTAssertEqual(hdr.displayMode.primaries, .p3)
        var sdr = VideoSettings.tabletDefault
        XCTAssertEqual(sdr.displayMode.primaries, .default)
        // `default` switches P3 off for either.
        hdr = hdr.applyingExperimentKnobs(["MATEBRIDGE_VD_PRIMARIES": "default"])
        XCTAssertEqual(hdr.displayMode.primaries, .default)
        XCTAssertEqual(hdr.displayMode.transfer, 1)
        sdr = sdr.applyingExperimentKnobs(["MATEBRIDGE_VD_PRIMARIES": "p3"])
        XCTAssertEqual(sdr.displayMode.primaries, .default, "an SDR display never gets primaries")
    }

    // MARK: Descriptor values

    func testDefaultSetsNothing() {
        XCTAssertTrue(P.properties(for: .default).isEmpty)
    }

    func testP3PropertiesAreSidecarsValues() {
        let props = P.properties(for: .p3)
        XCTAssertEqual(props.map(\.key), ["redPrimary", "greenPrimary", "bluePrimary", "whitePoint"])
        XCTAssertEqual(props.map(\.value), [P.Point(x: 0.68, y: 0.32), P.Point(x: 0.265, y: 0.69),
                                            P.Point(x: 0.15, y: 0.06), P.Point(x: 0.3127, y: 0.329)])
        XCTAssertEqual(props.map(\.setterName), ["setRedPrimary:", "setGreenPrimary:", "setBluePrimary:", "setWhitePoint:"])
    }

    // MARK: Selector fallback

    func testResolveAppliesWhenAllSettersExist() {
        let a = P.resolve(choice: .p3, invalidKnob: false) { _ in true }
        XCTAssertEqual(a, P.Applied(choice: .p3))
    }

    func testResolveFallsBackWhenAnySetterIsMissing() {
        for missing in P.properties(for: .p3).map(\.setterName) {
            let a = P.resolve(choice: .p3, invalidKnob: false) { $0 != missing }
            XCTAssertEqual(a, P.Applied(choice: .default, fallback: .selectorMissing), missing)
        }
    }

    func testResolveDefaultNeverAsksTheDescriptor() {
        let a = P.resolve(choice: .default, invalidKnob: false) { _ in XCTFail("no selector is needed"); return false }
        XCTAssertEqual(a, .none)
    }

    func testResolveKeepsInvalidFlag() {
        XCTAssertTrue(P.resolve(choice: .p3, invalidKnob: true) { _ in true }.invalidKnob)
        XCTAssertTrue(P.resolve(choice: .default, invalidKnob: true) { _ in true }.invalidKnob)
    }

    // MARK: DisplayReuse

    func testReuseRequiresTheSamePrimaries() {
        let p3 = DisplayMode(widthPx: 2800, heightPx: 1840, hidpi: true, refreshHz: 60, transfer: 1, primaries: .p3)
        let plain = DisplayMode(widthPx: 2800, heightPx: 1840, hidpi: true, refreshHz: 60, transfer: 1)
        XCTAssertEqual(DisplayReuse.decide(current: p3, online: true, wanted: p3), .reuse)
        XCTAssertEqual(DisplayReuse.decide(current: plain, online: true, wanted: plain), .reuse)
        XCTAssertEqual(DisplayReuse.decide(current: plain, online: true, wanted: p3), .recreate(.transferChange))
        XCTAssertEqual(DisplayReuse.decide(current: p3, online: true, wanted: plain), .recreate(.transferChange))
    }

    func testSDRHDRSwitchStillRecreatesTheDisplay() {
        var sdr = VideoSettings.tabletDefault
        var hdr = sdr
        hdr.dynamicRange = .hdr10
        XCTAssertEqual(DisplayReuse.decide(current: sdr.displayMode, online: true, wanted: hdr.displayMode),
                       .recreate(.transferChange))
        XCTAssertEqual(DisplayReuse.decide(current: hdr.displayMode, online: true, wanted: sdr.displayMode),
                       .recreate(.transferChange))
        XCTAssertEqual(DisplayReuse.decide(current: hdr.displayMode, online: true, wanted: hdr.displayMode), .reuse)
        sdr.dynamicRange = .sdr
        XCTAssertEqual(DisplayReuse.decide(current: sdr.displayMode, online: true, wanted: sdr.displayMode), .reuse)
    }

    func testSDRDisplayModeIsUnchangedByTheKnob() {
        let sdr = VideoSettings.tabletDefault
        let withKnob = sdr.applyingExperimentKnobs(["MATEBRIDGE_VD_PRIMARIES": "p3"])
        XCTAssertEqual(sdr.displayMode, withKnob.displayMode)
    }

    // MARK: Log fields

    func testLogFieldsHDRWithP3AndWideGamut() {
        let o = T.Outcome(requested: 1, applied: 1, fallback: nil, primaries: P.Applied(choice: .p3))
        XCTAssertEqual(T.logFields(o, edr: EDRHeadroom(current: 1, potential: 5), wideGamut: true),
                       "requested=1 applied=1 edr_max=1.00 edr_potential=5.00 primaries=p3 wide_gamut=1")
        XCTAssertEqual(o.logLevel, .info)
    }

    func testLogFieldsSDRIsPrimariesDefaultAndWideGamutZero() {
        XCTAssertEqual(T.logFields(.legacy, edr: EDRHeadroom(current: 1, potential: 1), wideGamut: false),
                       "requested=0 applied=0 edr_max=1.00 edr_potential=1.00 primaries=default wide_gamut=0")
    }

    func testLogFieldsTransferFallbackKeepsP3() {
        // tf=1 was refused, the display stays an SDR display with P3 primaries (no extra recreation).
        let o = T.Outcome(requested: 1, applied: 0, fallback: .settingsRejected, primaries: P.Applied(choice: .p3))
        XCTAssertEqual(T.logFields(o, edr: nil, wideGamut: true),
                       "requested=1 applied=0 reason=settings_rejected edr_max=na edr_potential=na primaries=p3 wide_gamut=1")
        XCTAssertEqual(o.logLevel, .warning)
    }

    func testLogFieldsPrimariesFallback() {
        let p = P.Applied(choice: .default, fallback: .selectorMissing)
        let o = T.Outcome(requested: 1, applied: 1, fallback: nil, primaries: p)
        XCTAssertEqual(T.logFields(o, edr: nil),
                       "requested=1 applied=1 edr_max=na edr_potential=na primaries=default "
                       + "primaries_fallback=selector_missing wide_gamut=na")
        XCTAssertEqual(o.logLevel, .warning)
        XCTAssertEqual(P.FallbackReason.selectorMissing.rawValue, "selector_missing")
    }

    func testLogFieldsInvalidPrimariesKnob() {
        let o = T.Outcome(requested: 1, applied: 1, fallback: nil,
                          primaries: P.Applied(choice: .p3, invalidKnob: true))
        XCTAssertTrue(T.logFields(o, edr: nil).contains(" primaries=p3 primaries_reason=invalid_value wide_gamut=na"))
        XCTAssertEqual(o.logLevel, .warning)
    }

    func testLogFieldsAreOneTokenEach() {
        let p = P.Applied(choice: .default, fallback: .selectorMissing, invalidKnob: true)
        let o = T.Outcome(requested: 1, applied: 0, fallback: .modeNil, primaries: p)
        for token in T.logFields(o, edr: nil, wideGamut: false).split(separator: " ") {
            XCTAssertEqual(token.filter { $0 == "=" }.count, 1, String(token))
        }
    }

    func testKnobListedInProfile() {
        XCTAssertTrue(StreamProfileLog.knobAllowList.contains(P.envKey))
        XCTAssertEqual(StreamProfileLog.knobsField(["MATEBRIDGE_VD_PRIMARIES": "default"]),
                       "MATEBRIDGE_VD_PRIMARIES:default")
    }
}
