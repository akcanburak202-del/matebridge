import CoreVideo
import Metal
import XCTest
@testable import YUV444Core
@testable import YUV444GPU

/// The Metal packer against the CPU reference (`AVC444v2`). Skipped on a machine without a Metal device.
final class GPUPackerTests: XCTestCase {
    private func noise(_ w: Int, _ h: Int) -> CVPixelBuffer {
        let pb = PixelBufferIO.makeBGRA(width: w, height: h)!
        CVPixelBufferLockBaseAddress(pb, [])
        let base = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(pb)
        var s: UInt64 = 42
        for y in 0..<h {
            for x in 0..<(w * 4) {
                s = s &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                // Mix flat areas and noise so saturated edges and rounding ties both occur.
                base[y * stride + x] = (x / 4 / 8 + y / 4) % 3 == 0 ? UInt8(truncatingIfNeeded: s >> 40) : UInt8((x & 3) == 3 ? 255 : (x / 4 * 9 + y * 5) % 256)
            }
        }
        CVPixelBufferUnlockBaseAddress(pb, [])
        return pb
    }

    private func requireDevice() throws {
        try XCTSkipIf(MTLCreateSystemDefaultDevice() == nil, "no Metal device")
    }

    func testConvert444MatchesCPUWithinOneCode() throws {
        try requireDevice()
        let (w, h) = (64, 32)
        let src = noise(w, h)
        let packer = try Packer444(width: w, height: h, mainChroma: .pick)
        let gpu = try packer.planes444(src)
        let cpu = ColorMath.planes444(bgra: PixelBufferIO.readBGRA(src), width: w, height: h)
        for (name, a, b) in [("y", gpu.y, cpu.y), ("cb", gpu.cb, cpu.cb), ("cr", gpu.cr, cpu.cr)] {
            let e = Metrics.absError(a, b)
            XCTAssertLessThanOrEqual(e.max, 1, name)
            XCTAssertLessThan(e.mean, 0.01, name)
        }
    }

    func testFusedAndTwoPassMatchCPUPackingExactly() throws {
        try requireDevice()
        let (w, h) = (96, 48)
        let src = noise(w, h)
        for chroma in MainChroma.allCases {
            let reference = try Packer444(width: w, height: h, mainChroma: chroma).planes444(src)
            let (cpuMain, cpuAux) = AVC444v2.pack(reference, mainChroma: chroma)
            for strategy in Packer444.Strategy.allCases {
                let packer = try Packer444(width: w, height: h, mainChroma: chroma, strategy: strategy)
                let r = try packer.pack(src)
                XCTAssertEqual(PixelBufferIO.readPlanes420(r.main), cpuMain, "main \(chroma) \(strategy)")
                XCTAssertEqual(PixelBufferIO.readPlanes420(try XCTUnwrap(r.aux)), cpuAux, "aux \(chroma) \(strategy)")
            }
        }
    }

    func testMainOnlyPassMatchesFullPassMainView() throws {
        try requireDevice()
        let (w, h) = (64, 32)
        let src = noise(w, h)
        let both = try Packer444(width: w, height: h, mainChroma: .box).pack(src)
        let only = try Packer444(width: w, height: h, mainChroma: .box, includeAux: false).pack(src)
        XCTAssertNil(only.aux)
        XCTAssertEqual(PixelBufferIO.readPlanes420(only.main), PixelBufferIO.readPlanes420(both.main))
    }

    func testGPUPackAndCPUUnpackRoundTripPick() throws {
        try requireDevice()
        let (w, h) = (64, 32)
        let src = noise(w, h)
        let packer = try Packer444(width: w, height: h, mainChroma: .pick)
        let truth = try packer.planes444(src)
        let r = try packer.pack(src)
        let back = AVC444v2.unpack(main: PixelBufferIO.readPlanes420(r.main), aux: PixelBufferIO.readPlanes420(try XCTUnwrap(r.aux)),
                                   reconstruction: .asIs)
        XCTAssertEqual(back, truth)
    }

    func testOutputsCarrySessionTags() throws {
        try requireDevice()
        let src = noise(32, 16)
        let r = try Packer444(width: 32, height: 16, mainChroma: .pick).pack(src)
        for pb in [r.main, try XCTUnwrap(r.aux)] {
            XCTAssertEqual(CVBufferCopyAttachment(pb, kCVImageBufferColorPrimariesKey, nil) as? String,
                           SessionTags.primaries as String)
            XCTAssertEqual(CVBufferCopyAttachment(pb, kCVImageBufferTransferFunctionKey, nil) as? String,
                           SessionTags.transfer as String)
            XCTAssertEqual(CVBufferCopyAttachment(pb, kCVImageBufferYCbCrMatrixKey, nil) as? String,
                           SessionTags.matrix as String)
        }
    }

    func testInvalidSizeIsRejected() {
        XCTAssertThrowsError(try Packer444(width: 30, height: 16, mainChroma: .pick))
    }
}
