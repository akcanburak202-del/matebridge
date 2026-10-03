import XCTest
@testable import MateBridgeCore

final class EncoderHardwareCheckTests: XCTestCase {
    func testHardwareIsInfoWithoutMenuText() {
        let c = EncoderHardwareCheck(usingHardware: true, status: 0)
        XCTAssertEqual(c, .hardware)
        XCTAssertEqual(c.logLevel, .info)
        XCTAssertEqual(c.logFields, "using_hw=1")
        XCTAssertNil(c.menuText)
    }

    func testSoftwareIsWarningWithMenuText() {
        let c = EncoderHardwareCheck(usingHardware: false, status: 0)
        XCTAssertEqual(c, .software)
        XCTAssertEqual(c.logLevel, .warning)
        XCTAssertEqual(c.logFields, "using_hw=0")
        XCTAssertEqual(c.menuText, "yazılım kodlayıcı")
    }

    func testUnreadableIsWarningWithStatus() {
        let c = EncoderHardwareCheck(usingHardware: nil, status: -12900)
        XCTAssertEqual(c, .unknown(status: -12900))
        XCTAssertEqual(c.logLevel, .warning)
        XCTAssertEqual(c.logFields, "using_hw=unknown status=-12900")
        XCTAssertEqual(c.menuText, "kodlayıcı türü bilinmiyor")
    }

    /// The call succeeded but returned no boolean: still unknown, with status 0.
    func testMissingValueWithNoErrIsUnknown() {
        let c = EncoderHardwareCheck(usingHardware: nil, status: 0)
        XCTAssertEqual(c, .unknown(status: 0))
        XCTAssertEqual(c.logFields, "using_hw=unknown status=0")
        XCTAssertEqual(c.logLevel, .warning)
    }

    /// A status passed with a readable value is ignored.
    func testStatusIgnoredWhenValueKnown() {
        XCTAssertEqual(EncoderHardwareCheck(usingHardware: true, status: -1), .hardware)
        XCTAssertEqual(EncoderHardwareCheck(usingHardware: false, status: -1), .software)
    }

    func testEventName() {
        XCTAssertEqual(EncoderHardwareCheck.event, "encoder_hw")
    }
}
