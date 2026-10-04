import XCTest
@testable import MateBridgeCore

/// T-232: `MATEBRIDGE_VD_TRANSFER` parsing, the mode-initializer decision and its fallback, and `ev=vd_transfer`.
final class VirtualDisplayTransferTests: XCTestCase {
    typealias T = VirtualDisplayTransfer

    func testParseUnsetAndZeroAreLegacy() {
        for raw in [nil, "", "  ", "0", " 0 "] {
            XCTAssertEqual(T.parse(raw), T.Knob(requested: 0, invalid: false), String(describing: raw))
        }
        XCTAssertEqual(T.parse(env: [:]), T.Knob(requested: 0, invalid: false))
    }

    func testParseOne() {
        XCTAssertEqual(T.parse("1"), T.Knob(requested: 1, invalid: false))
        XCTAssertEqual(T.parse(" 1\n"), T.Knob(requested: 1, invalid: false))
        XCTAssertEqual(T.parse(env: ["MATEBRIDGE_VD_TRANSFER": "1"]), T.Knob(requested: 1, invalid: false))
    }

    func testParseInvalidIsLegacyAndFlagged() {
        for raw in ["2", "-1", "01", "true", "yes", "abc", "1.0", "0x1"] {
            XCTAssertEqual(T.parse(raw), T.Knob(requested: 0, invalid: true), raw)
        }
    }

    func testDecideDefaultIsLegacyWhateverTheSelector() {
        XCTAssertEqual(T.decide(requested: 0, selectorAvailable: true), .legacy)
        XCTAssertEqual(T.decide(requested: 0, selectorAvailable: false), .legacy)
    }

    func testDecideRequestedUsesSelectorOrFallsBack() {
        XCTAssertEqual(T.decide(requested: 1, selectorAvailable: true), .transfer(1))
        XCTAssertEqual(T.decide(requested: 1, selectorAvailable: false), .fallback(.selectorMissing))
    }

    func testFallbackAfterAttempt() {
        XCTAssertNil(T.fallbackAfterAttempt(modeCreated: true, settingsAccepted: true))
        XCTAssertEqual(T.fallbackAfterAttempt(modeCreated: true, settingsAccepted: false), .settingsRejected)
        // A nil mode is never applied, so it wins over the settings flag.
        XCTAssertEqual(T.fallbackAfterAttempt(modeCreated: false, settingsAccepted: false), .modeNil)
        XCTAssertEqual(T.fallbackAfterAttempt(modeCreated: false, settingsAccepted: true), .modeNil)
    }

    func testLogFieldsDefault() {
        XCTAssertEqual(T.logFields(.legacy, edr: EDRHeadroom(current: 1, potential: 1)),
                       "requested=0 applied=0 edr_max=1.00 edr_potential=1.00")
        XCTAssertEqual(T.Outcome.legacy.logLevel, .info)
    }

    func testLogFieldsApplied() {
        let o = T.Outcome(requested: 1, applied: 1, fallback: nil)
        XCTAssertEqual(T.logFields(o, edr: EDRHeadroom(current: 1.5, potential: 4)),
                       "requested=1 applied=1 edr_max=1.50 edr_potential=4.00")
        XCTAssertEqual(o.logLevel, .info)
    }

    func testLogFieldsFallbackAndMissingScreen() {
        for reason in [T.FallbackReason.selectorMissing, .modeNil, .settingsRejected] {
            let o = T.Outcome(requested: 1, applied: 0, fallback: reason)
            XCTAssertEqual(T.logFields(o, edr: nil),
                           "requested=1 applied=0 reason=\(reason.rawValue) edr_max=na edr_potential=na")
            XCTAssertEqual(o.logLevel, .warning)
        }
        XCTAssertEqual(T.FallbackReason.selectorMissing.rawValue, "selector_missing")
        XCTAssertEqual(T.FallbackReason.modeNil.rawValue, "mode_nil")
        XCTAssertEqual(T.FallbackReason.settingsRejected.rawValue, "settings_rejected")
    }

    func testLogFieldsInvalidKnob() {
        let o = T.Outcome(requested: 0, applied: 0, fallback: nil, invalidKnob: true)
        XCTAssertEqual(T.logFields(o, edr: EDRHeadroom(current: 1, potential: 1)),
                       "requested=0 applied=0 reason=invalid_value edr_max=1.00 edr_potential=1.00")
        XCTAssertEqual(o.logLevel, .warning)
    }

    func testLogFieldsNonFiniteEdrIsNa() {
        XCTAssertEqual(T.logFields(.legacy, edr: EDRHeadroom(current: .nan, potential: .infinity)),
                       "requested=0 applied=0 edr_max=na edr_potential=na")
    }

    func testLogFieldsAreOneTokenEach() {
        let o = T.Outcome(requested: 1, applied: 0, fallback: .modeNil, invalidKnob: false)
        for token in T.logFields(o, edr: nil).split(separator: " ") {
            XCTAssertEqual(token.filter { $0 == "=" }.count, 1, String(token))
        }
    }

    func testKnobListedInProfile() {
        XCTAssertTrue(StreamProfileLog.knobAllowList.contains(T.envKey))
        XCTAssertEqual(StreamProfileLog.knobsField(["MATEBRIDGE_VD_TRANSFER": "1"]), "MATEBRIDGE_VD_TRANSFER:1")
        XCTAssertEqual(StreamProfileLog.knobsField(["MATEBRIDGE_FPS": "120", "MATEBRIDGE_VD_TRANSFER": "1"]),
                       "MATEBRIDGE_FPS:120;MATEBRIDGE_VD_TRANSFER:1")
    }
}
