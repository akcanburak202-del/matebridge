import XCTest
@testable import MateBridgeCore

/// T-113: captured buffers are retagged to the session's colour tags so VideoToolbox skips its colour conversion.
final class InputColorTagsTests: XCTestCase {
    private let session = ColorTags(primaries: "ITU_R_709_2", transfer: "IEC_sRGB", matrix: "ITU_R_709_2")
    /// What ScreenCaptureKit attaches to its 420f buffers when configured for sRGB (measured on the Mac mini).
    private let sck = ColorTags(primaries: "ITU_R_709_2", transfer: "ITU_R_709_2", matrix: "ITU_R_709_2")

    func testKnobDefaultsOnAndOnlyZeroTurnsItOff() {
        XCTAssertTrue(InputRetag.isEnabled([:]))
        XCTAssertTrue(InputRetag.isEnabled(["MATEBRIDGE_INPUT_RETAG": "1"]))
        XCTAssertTrue(InputRetag.isEnabled(["MATEBRIDGE_INPUT_RETAG": "off"]))
        XCTAssertFalse(InputRetag.isEnabled(["MATEBRIDGE_INPUT_RETAG": "0"]))
        XCTAssertFalse(InputRetag.isEnabled(["MATEBRIDGE_INPUT_RETAG": " 0 "]))
        XCTAssertFalse(EncoderKnobs.parse(["MATEBRIDGE_INPUT_RETAG": "0"]).retagInput)
        XCTAssertTrue(EncoderKnobs.parse(["MATEBRIDGE_INPUT_RETAG": "0"]).logFields.hasSuffix("input_retag=0"))
    }

    func testScreenCaptureKitTagsAreRewritten() {
        XCTAssertTrue(InputRetag.needsRetag(buffer: sck, hasColorSpace: true, session: session))
        XCTAssertTrue(InputRetag.needsRetag(buffer: sck, hasColorSpace: false, session: session))
    }

    func testMatchingTagsAreLeftAlone() {
        XCTAssertFalse(InputRetag.needsRetag(buffer: session, hasColorSpace: true, session: session))
        XCTAssertFalse(InputRetag.needsRetag(buffer: session, hasColorSpace: false, session: session))
    }

    func testUntaggedBufferIsLeftAlone() {
        XCTAssertFalse(InputRetag.needsRetag(buffer: ColorTags(), hasColorSpace: false, session: session))
    }

    func testPartialTagsOrColorSpaceOnlyAreRewritten() {
        // VideoToolbox converts these too (measured): a lone matrix tag, or a lone CGColorSpace.
        XCTAssertTrue(InputRetag.needsRetag(buffer: ColorTags(matrix: "ITU_R_709_2"), hasColorSpace: false,
                                            session: session))
        XCTAssertTrue(InputRetag.needsRetag(buffer: ColorTags(), hasColorSpace: true, session: session))
    }

    func testLogValue() {
        XCTAssertEqual(sck.logValue, "ITU_R_709_2/ITU_R_709_2/ITU_R_709_2")
        XCTAssertEqual(ColorTags(transfer: "IEC_sRGB").logValue, "-/IEC_sRGB/-")
        XCTAssertTrue(ColorTags().isEmpty)
    }
}
