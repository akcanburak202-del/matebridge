import XCTest
@testable import MateBridgeCore

final class EncoderProfileTests: XCTestCase {
    func testParse() {
        XCTAssertEqual(EncoderProfile.parse("llrc"), .llrc)
        XCTAssertEqual(EncoderProfile.parse("FAST"), .fast)
        XCTAssertNil(EncoderProfile.parse("x"))
        XCTAssertNil(EncoderProfile.parse(nil))
    }

    func testResolve() {
        XCTAssertEqual(EncoderProfile.resolve(fps: 60, override: nil, defaultProfile: .fast), .fast)
        XCTAssertEqual(EncoderProfile.resolve(fps: 60, override: .llrc, defaultProfile: .fast), .llrc)
        XCTAssertEqual(EncoderProfile.resolve(fps: 60, override: nil, defaultProfile: .llrc), .llrc)
        XCTAssertEqual(EncoderProfile.resolve(fps: 120, override: nil, defaultProfile: .llrc), .fast)
    }

    func testFrameSizeStats() {
        var frames: [(size: Int, isKey: Bool)] = [(1000, true)]
        for _ in 0..<99 { frames.append((100, false)) }
        frames.append((300, false))
        let s = FrameSizeStats(frames: frames)
        XCTAssertEqual(s.keyCount, 1)
        XCTAssertEqual(s.keyMax, 1000)
        XCTAssertEqual(s.deltaCount, 100)
        XCTAssertEqual(s.deltaP50, 100)
        XCTAssertEqual(s.deltaMax, 300)
        XCTAssertTrue(s.isSmooth)
        XCTAssertFalse(FrameSizeStats(frames: [(10, false), (10, false), (10, false), (10, false), (1000, false)]).isSmooth)
        XCTAssertFalse(FrameSizeStats(frames: []).isSmooth)
    }

    func testBenchContentOption() throws {
        let o = try XCTUnwrap(EncodeBenchOptions.parse(["--encode-bench", "--content", "patch", "--config", "fast"])).get()
        XCTAssertEqual(o.content, .patch)
        XCTAssertEqual(o.configs.map(\.name), ["fast"])
        guard case .failure = EncodeBenchOptions.parse(["--encode-bench", "--content", "x"])! else { return XCTFail() }
    }
}
