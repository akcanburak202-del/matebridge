import XCTest
@testable import MateBridgeCore

final class EncodeBenchTests: XCTestCase {
    func testAbsentFlagIsNil() { XCTAssertNil(EncodeBenchOptions.parse(["app", "--seconds", "3"])) }

    func testDefaultsUseWholeCatalog() throws {
        let o = try XCTUnwrap(EncodeBenchOptions.parse(["app", "--encode-bench"])).get()
        XCTAssertEqual(o.fps, 120)
        XCTAssertEqual(o.seconds, 5)
        XCTAssertEqual(o.configs, EncodeBenchConfig.catalog)
    }

    func testExplicitOptions() throws {
        let o = try XCTUnwrap(EncodeBenchOptions.parse(
            ["app", "--encode-bench", "--fps", "90", "--seconds", "2.5", "--config", "baseline", "--config", "dual"])).get()
        XCTAssertEqual(o.fps, 90)
        XCTAssertEqual(o.seconds, 2.5)
        XCTAssertEqual(o.configs.map(\.name), ["baseline", "dual"])
        XCTAssertEqual(o.configs[1].sessions, 2)
    }

    func testBadArguments() {
        for args in [["--fps", "0"], ["--fps", "x"], ["--seconds", "-1"], ["--config", "nope"], ["--config"],
                     ["--input-tags", "p3"], ["--input-tags"]] {
            guard case .failure = EncodeBenchOptions.parse(["--encode-bench"] + args)! else {
                return XCTFail("\(args) should fail")
            }
        }
    }

    func testInputTags() throws {
        let d = try XCTUnwrap(EncodeBenchOptions.parse(["app", "--encode-bench"])).get()
        XCTAssertEqual(d.inputTags, .none)
        let o = try XCTUnwrap(EncodeBenchOptions.parse(["app", "--encode-bench", "--input-tags", "sck"])).get()
        XCTAssertEqual(o.inputTags, .sck)
        // T-204: `MATEBRIDGE_INPUT_RETAG` is not read any more (the bench always retags, as the app does).
        XCTAssertEqual(o.applyingEnvironment(["MATEBRIDGE_INPUT_RETAG": "0"]), o.applyingEnvironment([:]))
    }

    func testCatalogNamesUniqueAndBaselineMatchesEncoder() {
        let names = EncodeBenchConfig.catalog.map(\.name)
        XCTAssertEqual(Set(names).count, names.count)
        let b = EncodeBenchConfig.named("baseline")!
        XCTAssertEqual(b.realTime, true)
        XCTAssertTrue(b.lowLatencyRateControl && b.prioritizeSpeed && b.dataRateLimits)
        XCTAssertEqual(b.bitrateKbps, 30_000)
    }
}
