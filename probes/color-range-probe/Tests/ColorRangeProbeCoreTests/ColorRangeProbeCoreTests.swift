import XCTest
@testable import ColorRangeProbeCore

final class BandsTests: XCTestCase {
    func testColumnsPartitionTheWidth() {
        for width in [2800, 1920, 100, 64] {
            var covered = 0
            for i in Bands.values.indices {
                let c = Bands.columns(index: i, width: width)
                XCTAssertEqual(c.lowerBound, covered, "width \(width) band \(i)")
                for x in [c.lowerBound, c.upperBound - 1] { XCTAssertEqual(Bands.band(x: x, width: width), i) }
                covered = c.upperBound
            }
            XCTAssertEqual(covered, width)
        }
        XCTAssertEqual(Bands.columns(index: 0, width: 2800), 0..<350)
        XCTAssertEqual(Bands.measuredColumns(index: 0, width: 2800), 48..<302)
    }

    func testFillThenMeasureReturnsBandValues() {
        let w = 800, h = 64, stride = 832
        var plane = [UInt8](repeating: 99, count: stride * h)
        plane.withUnsafeMutableBufferPointer { Bands.fillLuma($0.baseAddress!, width: w, height: h, stride: stride) }
        XCTAssertEqual(plane[w], 99, "padding untouched")
        let stats = plane.withUnsafeBufferPointer { Bands.measureLuma($0.baseAddress!, width: w, height: h, stride: stride) }
        XCTAssertEqual(stats.map(\.median), Bands.values)
        XCTAssertEqual(stats.map(\.min), Bands.values)
        XCTAssertEqual(stats.map(\.max), Bands.values)
    }

    func testChromaFillIsNeutral() {
        var plane = [UInt8](repeating: 0, count: 10 * 3)
        plane.withUnsafeMutableBufferPointer { Bands.fillChroma($0.baseAddress!, widthBytes: 8, height: 3, stride: 10) }
        XCTAssertEqual(plane[0..<8].allSatisfy { $0 == 128 }, true)
        XCTAssertEqual(plane[8], 0)
    }

    func testStatFromHistogram() {
        var h = [Int](repeating: 0, count: 256)
        h[16] = 10; h[17] = 3; h[200] = 1
        XCTAssertEqual(Bands.stat(histogram: h), Bands.Stat(median: 16, min: 16, max: 200))
        XCTAssertEqual(Bands.stat(histogram: h).text, "16 (16-200)")
        XCTAssertEqual(Bands.stat(histogram: [Int](repeating: 0, count: 256)), Bands.Stat(median: 0, min: 0, max: 0))
        XCTAssertEqual(Bands.Stat(median: 5, min: 5, max: 5).text, "5")
    }
}

final class VerdictTests: XCTestCase {
    func testMatchingDecodeFormat() {
        XCTAssertEqual(YUVFormat.matching(vuiFullRange: true), .full)
        XCTAssertEqual(YUVFormat.matching(vuiFullRange: false), .video)
    }

    func testClassify() {
        let v = Bands.values
        XCTAssertEqual(Verdict.blackBand(.full), 0)
        XCTAssertEqual(Verdict.blackBand(.video), 2)
        // Measured T-230 rows: prod, noretag, 420v-retag, 420v-noretag.
        XCTAssertTrue(Verdict.classify(input: .full, vuiFullRange: true, coded: v).hasPrefix("OK, pass-through"))
        XCTAssertTrue(Verdict.classify(input: .full, vuiFullRange: true, coded: [0, 1, 14, 35, 73, 139, 237, 255])
            .hasPrefix("black OK but values converted"))
        XCTAssertTrue(Verdict.classify(input: .video, vuiFullRange: false, coded: v).hasPrefix("OK, pass-through"))
        XCTAssertTrue(Verdict.classify(input: .video, vuiFullRange: false, coded: [16, 16, 16, 30, 70, 137, 235, 235])
            .hasPrefix("black OK but values converted"))
        // The suspected failure: full-range flag but black lifted to 16.
        XCTAssertTrue(Verdict.classify(input: .full, vuiFullRange: true, coded: [16, 23, 30, 43, 71, 126, 217, 234])
            .hasPrefix("WRONG: values converted and black moved"))
        XCTAssertTrue(Verdict.classify(input: .full, vuiFullRange: false, coded: v).hasPrefix("WRONG: full=0"))
        XCTAssertTrue(Verdict.classify(input: .full, vuiFullRange: nil, coded: v).hasPrefix("WRONG: no VUI range"))
        XCTAssertEqual(Verdict.classify(input: .full, vuiFullRange: true, coded: []), "no measurement")
    }
}

final class OptionsTests: XCTestCase {
    func testDefaults() throws {
        let o = try ProbeOptions.parse([]).get()
        XCTAssertEqual(o.width, 2800); XCTAssertEqual(o.height, 1840)
        XCTAssertEqual(o.configs, ProbeConfig.all)
        XCTAssertEqual(ProbeConfig.all.first?.name, "prod")
    }

    func testParse() throws {
        let o = try ProbeOptions.parse(["--only", "prod,420v-noretag", "--frames", "5", "--size", "1920x1080",
                                        "--out", "/x", "--bitrate-kbps", "8000", "--fps", "120"]).get()
        XCTAssertEqual(o.configs.map(\.name), ["prod", "420v-noretag"])
        XCTAssertEqual(o.frames, 5); XCTAssertEqual(o.width, 1920); XCTAssertEqual(o.height, 1080)
        XCTAssertEqual(o.outDir, "/x"); XCTAssertEqual(o.bitrateKbps, 8000); XCTAssertEqual(o.fps, 120)
    }

    func testRejects() {
        XCTAssertEqual(ProbeOptions.parse(["--only", "nope"]), .failure(.unknownConfig("nope")))
        XCTAssertEqual(ProbeOptions.parse(["--size", "1921x1080"]), .failure(.badValue("--size")))
        XCTAssertEqual(ProbeOptions.parse(["--frames", "0"]), .failure(.badValue("--frames")))
        XCTAssertEqual(ProbeOptions.parse(["--bogus"]), .failure(.unknown("--bogus")))
    }
}

final class HEVCSPSCopyTests: XCTestCase {
    /// Same vector as host-mac HEVCSPSTests: Apple VideoToolbox HEVC SPS, sRGB/BT.709 full range.
    private let appleSPS: [UInt8] = [
        0x42, 0x01, 0x03, 0x01, 0x60, 0x00, 0x00, 0x03, 0x00, 0xB0, 0x00, 0x00, 0x03, 0x00, 0x00, 0x03, 0x00,
        0x96, 0x00, 0x00, 0xA0, 0x01, 0x5E, 0x20, 0x07, 0x31, 0x62, 0x02, 0x39, 0x24, 0x52, 0x10, 0xB9, 0xF8,
        0x4F, 0x42, 0xFA, 0x86, 0xF5, 0x43, 0xFA, 0xA8, 0x23, 0xD5, 0x52, 0x9B, 0x80, 0x86, 0x80, 0x81, 0xFC,
        0x20, 0x10, 0x40,
    ]

    func testParsesAppleSPSVui() {
        XCTAssertEqual(HEVCSPS.vuiColor(sps: appleSPS),
                       HEVCVUIColor(fullRange: true, colourPrimaries: 1, transferCharacteristics: 13,
                                    matrixCoefficients: 1, colourDescriptionPresent: true))
        XCTAssertNil(HEVCSPS.vuiColor(sps: Array(appleSPS.prefix(30))))
    }

    func testAnnexBRoundTrip() {
        let sample: [UInt8] = [0, 0, 0, 3, 0x26, 0x01, 0xAF, 0, 0, 0, 2, 0x02, 0x01]
        let annexB = AnnexB.convert(lengthPrefixed: sample)!
        XCTAssertEqual(AnnexB.nalUnits(annexB), [[0x26, 0x01, 0xAF], [0x02, 0x01]])
    }
}
