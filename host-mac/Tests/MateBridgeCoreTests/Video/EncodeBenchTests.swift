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
        for args in [["--fps", "0"], ["--fps", "x"], ["--seconds", "-1"], ["--config", "nope"], ["--config"]] {
            guard case .failure = EncodeBenchOptions.parse(["--encode-bench"] + args)! else {
                return XCTFail("\(args) should fail")
            }
        }
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
