import XCTest
@testable import YUV444Core

final class PackingTests: XCTestCase {
    /// Deterministic noise planes.
    static func randomPlanes(_ w: Int, _ h: Int, seed: UInt64 = 7) -> Planes444 {
        var s = seed
        func next() -> UInt8 {
            s = s &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return UInt8(truncatingIfNeeded: s >> 40)
        }
        var p = Planes444(width: w, height: h)
        for i in 0..<(w * h) { p.y[i] = next(); p.cb[i] = next(); p.cr[i] = next() }
        return p
    }

    func testPickRoundTripIsBitExact() {
        for (w, h) in [(8, 4), (64, 32), (28, 18), (100, 50)] {
            let p = Self.randomPlanes(w, h)
            let (main, aux) = AVC444v2.pack(p, mainChroma: .pick)
            XCTAssertEqual(AVC444v2.unpack(main: main, aux: aux, reconstruction: .asIs), p, "\(w)x\(h)")
        }
    }

    func testMainViewIsPlain420() {
        let p = Self.randomPlanes(32, 16)
        let (main, _) = AVC444v2.pack(p, mainChroma: .pick)
        XCTAssertEqual(main.y, p.y)
        for j in 0..<8 {
            for i in 0..<16 {
                XCTAssertEqual(main.cb[j * 16 + i], p.cb[2 * j * 32 + 2 * i])
                XCTAssertEqual(main.cr[j * 16 + i], p.cr[2 * j * 32 + 2 * i])
            }
        }
    }

    func testBoxMainChromaIsRoundedMean() {
        var p = Planes444(width: 8, height: 4)
        // Block (0,0) Cb = 10, 11, 12, 14 -> (47 + 2) >> 2 = 12.
        p.cb[0] = 10; p.cb[1] = 11; p.cb[8] = 12; p.cb[9] = 14
        let (main, _) = AVC444v2.pack(p, mainChroma: .box)
        XCTAssertEqual(main.cb[0], 12)
    }

    func testBoxInverseRecoversWithinMeanRounding() {
        let p = Self.randomPlanes(64, 32, seed: 99)
        let (main, aux) = AVC444v2.pack(p, mainChroma: .box)
        let back = AVC444v2.unpack(main: main, aux: aux, reconstruction: .inverseBox)
        XCTAssertEqual(back.y, p.y)
        var worst = 0
        for i in 0..<(64 * 32) {
            let x = i % 64, y = i / 64
            let evenEven = x % 2 == 0 && y % 2 == 0
            let dcb = Int(back.cb[i]) - Int(p.cb[i]), dcr = Int(back.cr[i]) - Int(p.cr[i])
            if evenEven {
                // mean = round(S / 4): S in [4m - 2, 4m + 1], the estimate 4m is off by -1...+2 (before clamping).
                XCTAssertTrue((-1...2).contains(dcb) || back.cb[i] == 0 || back.cb[i] == 255, "cb \(dcb) at \(x),\(y)")
                XCTAssertTrue((-1...2).contains(dcr) || back.cr[i] == 0 || back.cr[i] == 255, "cr \(dcr) at \(x),\(y)")
                worst = max(worst, abs(dcb), abs(dcr))
            } else {
                XCTAssertEqual(dcb, 0, "cb at \(x),\(y)")
                XCTAssertEqual(dcr, 0, "cr at \(x),\(y)")
            }
        }
        XCTAssertLessThanOrEqual(worst, 255)
    }

    func testBoxAsIsOnlyTouchesEvenEvenSamples() {
        let p = Self.randomPlanes(32, 16, seed: 3)
        let (main, aux) = AVC444v2.pack(p, mainChroma: .box)
        let back = AVC444v2.unpack(main: main, aux: aux, reconstruction: .asIs)
        for i in 0..<(32 * 16) where !((i % 32) % 2 == 0 && (i / 32) % 2 == 0) {
            XCTAssertEqual(back.cb[i], p.cb[i])
            XCTAssertEqual(back.cr[i], p.cr[i])
        }
    }

    /// The layout of the auxiliary view, spelled out (MS-RDPEGFX 3.3.8.3.3 / FreeRDP `general_ChromaV2ToYUV444`):
    /// each source sample lands at exactly one place.
    func testAuxLayoutMatchesSpecIndices() {
        let w = 16, h = 8
        var p = Planes444(width: w, height: h)
        // Unique markers: Cb sample = (x + 16 y) | 0x80 ... keep within a byte with a small frame.
        for y in 0..<h { for x in 0..<w { p.cb[y * w + x] = UInt8(y * w + x); p.cr[y * w + x] = UInt8(128 + (y * w + x) % 128) } }
        let (_, aux) = AVC444v2.pack(p, mainChroma: .pick)
        // aux Y: left half = Cb odd columns, right half = Cr odd columns.
        XCTAssertEqual(aux.y[3 * w + 2], p.cb[3 * w + 5])          // x = 2 -> Cb[2*2+1, 3]
        XCTAssertEqual(aux.y[3 * w + w / 2 + 2], p.cr[3 * w + 5])  // x = 2 + W/2 -> Cr[2*2+1, 3]
        // aux Cb/Cr: row j = 1 -> source row 3; x = 1 (left) -> columns 4 and 6; x = 1 + W/4 (right) -> Cr.
        let cw = w / 2, q = w / 4
        XCTAssertEqual(aux.cb[1 * cw + 1], p.cb[3 * w + 4])
        XCTAssertEqual(aux.cr[1 * cw + 1], p.cb[3 * w + 6])
        XCTAssertEqual(aux.cb[1 * cw + q + 1], p.cr[3 * w + 4])
        XCTAssertEqual(aux.cr[1 * cw + q + 1], p.cr[3 * w + 6])
    }

    func testEverySampleOfTheViewsIsUsedOnce() {
        // Pack a frame whose chroma samples are all distinct per plane (w*h = 128 here), count how often each marker
        // appears in main (pick) + aux chroma and aux luma: Cb and Cr must each appear exactly once.
        let w = 16, h = 8
        var p = Planes444(width: w, height: h)
        for i in 0..<(w * h) { p.cb[i] = UInt8(i); p.cr[i] = UInt8(128 + i) }
        let (main, aux) = AVC444v2.pack(p, mainChroma: .pick)
        var seen = [Int: Int]()
        for v in main.cb + main.cr + aux.cb + aux.cr + aux.y { seen[Int(v), default: 0] += 1 }
        for i in 0..<(w * h) {
            XCTAssertEqual(seen[Int(UInt8(i))], 1, "Cb \(i)")
        }
        // Cr markers 128..255 collide with Cb markers 128..127? i < 128 so Cb 0..127, Cr 128..255: disjoint.
        for i in 0..<(w * h) { XCTAssertEqual(seen[128 + i], 1, "Cr \(i)") }
    }

    func testSizeValidity() {
        XCTAssertTrue(AVC444v2.isValid(width: 2800, height: 1840))
        XCTAssertTrue(AVC444v2.isValid(width: 1848, height: 1214))
        XCTAssertFalse(AVC444v2.isValid(width: 1850, height: 1214))
        XCTAssertFalse(AVC444v2.isValid(width: 1848, height: 1215))
    }

    func testColorMathGreyAndPrimaries() {
        // 2x1 pixels (B, G, R, A): mid grey, pure red.
        let bgra: [UInt8] = [128, 128, 128, 255, 0, 0, 255, 255]
        let p = ColorMath.planes444(bgra: bgra, width: 2, height: 1)
        XCTAssertEqual(p.y[0], 128)
        XCTAssertEqual(p.cb[0], 128)
        XCTAssertEqual(p.cr[0], 128)
        XCTAssertEqual(p.y[1], 54)    // 0.2126 * 255 = 54.2
        XCTAssertEqual(p.cr[1], 255)  // (1 - 0.2126) / 1.5748 = 0.5 -> 255.5 -> clamped
        // Rebuilding the planes gives the source back within a code value.
        let rgb = ColorMath.rgb(p)
        XCTAssertEqual(Int(rgb[0]), 128, accuracy: 1)
        XCTAssertEqual(Int(rgb[3]), 255, accuracy: 1)
    }

    func testBilinearUpsampleOfFlatChromaIsFlat() {
        let p = Planes420(width: 8, height: 4, fill: 100)
        let up = ColorMath.upsample(p, .bilinear)
        XCTAssertTrue(up.cb.allSatisfy { $0 == 100 })
    }

    func testPSNRAndPercentiles() {
        XCTAssertEqual(Metrics.psnr([1, 2, 3], [1, 2, 3]), .infinity)
        XCTAssertEqual(Metrics.psnr([0], [255]), 0, accuracy: 1e-9)
        XCTAssertEqual(Metrics.percentile([1, 2, 3, 4], 50), 2)
        XCTAssertEqual(Metrics.percentile([1, 2, 3, 4], 100), 4)
        XCTAssertEqual(Metrics.percentile([], 50), 0)
    }

    func testArgsAndSizes() {
        let a = ProbeArgs(["--size", "2800x1840", "--fast", "--n", "5"])
        XCTAssertEqual(a.string("size", ""), "2800x1840")
        XCTAssertTrue(a.flag("fast"))
        XCTAssertEqual(a.int("n", 0), 5)
        XCTAssertEqual(FrameSize.parseList("2800x1840,1848x1214"), [.full, .reduced])
        XCTAssertNil(FrameSize.parseList("2801x1840"))
        XCTAssertNil(FrameSize.parseList("abc"))
    }

    func testPhasesAndNaming() {
        XCTAssertEqual(ScenePhase.of(frame: 0, frames: 600), .still)
        XCTAssertEqual(ScenePhase.of(frame: 149, frames: 600), .still)
        XCTAssertEqual(ScenePhase.of(frame: 150, frames: 600), .typing)
        XCTAssertEqual(ScenePhase.of(frame: 599, frames: 600), .video)
        XCTAssertEqual(ClipNaming.mainName(.full, fps: 60), "main_2800x1840_60.h265")
        XCTAssertEqual(ClipNaming.auxName(.reduced, fps: 60), "aux_1848x1214_60.h265")
        let b = ClipNaming.bitrates(size: .full, mainMbps: 40, auxRatio: 0.5)
        XCTAssertEqual(b.mainKbps, 40_000)
        XCTAssertEqual(b.auxKbps, 20_000)
        XCTAssertLessThan(ClipNaming.bitrates(size: .reduced, mainMbps: 40, auxRatio: 0.5).mainKbps, 40_000)
    }

    func testAnnexBPictureCount() {
        let nal: [UInt8] = [0x26, 0x01, 0x80, 0xAF]   // IDR_W_RADL, first_slice_segment_in_pic_flag set
        let stream = AnnexB.join([nal, nal])
        XCTAssertEqual(AnnexB.pictureCount(stream), 2)
        XCTAssertEqual(AnnexB.irapCount(stream), 2)
    }
}
