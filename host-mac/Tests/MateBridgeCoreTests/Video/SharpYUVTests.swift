import Metal
import XCTest
@testable import MateBridgeCore

/// T-235: the CPU reference of the sharp-YUV chroma pass, and the Metal kernel against it.
final class SharpYUVTests: XCTestCase {
    /// An icon-like test block: a saturated rounded square, a 1 px line and a 2 px stripe on a flat background, edges at
    /// odd and even coordinates so 2x2 chroma blocks straddle them.
    static func iconImage(width: Int, height: Int, background: (UInt8, UInt8, UInt8),
                          fill: (UInt8, UInt8, UInt8)) -> [UInt8] {
        var px = [UInt8](repeating: 255, count: width * height * 4)
        func put(_ x: Int, _ y: Int, _ c: (UInt8, UInt8, UInt8)) {
            let o = (y * width + x) * 4
            px[o] = c.2; px[o + 1] = c.1; px[o + 2] = c.0  // BGRA
        }
        let x0 = 5, y0 = 3, x1 = width * 2 / 3, y1 = height * 2 / 3, r = 5
        for y in 0..<height {
            for x in 0..<width {
                put(x, y, background)
                guard x >= x0, x <= x1, y >= y0, y <= y1 else { continue }
                let cx = x < x0 + r ? x0 + r : (x > x1 - r ? x1 - r : x)
                let cy = y < y0 + r ? y0 + r : (y > y1 - r ? y1 - r : y)
                if (x - cx) * (x - cx) + (y - cy) * (y - cy) <= r * r { put(x, y, fill) }
            }
        }
        for x in 0..<width { put(x, height - 5, fill) }                       // 1 px line
        for y in 0..<height where y % 6 < 2 { put(width - 4, y, (40, 60, 230)) }  // blue dashes
        return px
    }

    private func gain(width: Int, height: Int, bg: (UInt8, UInt8, UInt8), fill: (UInt8, UInt8, UInt8),
                      _ up: SharpYUV.Upsample) -> (plain: Double, sharp: Double) {
        let img = Self.iconImage(width: width, height: height, background: bg, fill: fill)
        let plain = SharpYUV.convert(bgra: img, width: width, height: height, adjustFor: nil)
        let sharp = SharpYUV.convert(bgra: img, width: width, height: height, adjustFor: up)
        let p = SharpYUV.lightnessPSNR(source: img, width: width, height: height,
                                       reconstructed: SharpYUV.reconstruct(plain, upsample: up))
        let s = SharpYUV.lightnessPSNR(source: img, width: width, height: height,
                                       reconstructed: SharpYUV.reconstruct(sharp, upsample: up))
        return (p, s)
    }

    /// Red on grey (the Dock icon case): luma adjustment removes most of the lightness error at the edges, with the
    /// nearest-neighbour decoder upsampling it was adjusted for (T-302 removed the bilinear model).
    func testLumaAdjustmentImprovesLightnessAtRedGreyEdges() {
        for up in SharpYUV.Upsample.allCases {
            let g = gain(width: 48, height: 40, bg: (128, 128, 128), fill: (230, 30, 40), up)
            print("T-235 red/grey \(up.rawValue): plain \(String(format: "%.1f", g.plain)) dB -> sharp "
                  + "\(String(format: "%.1f", g.sharp)) dB")
            XCTAssertGreaterThan(g.sharp - g.plain, 20, "\(up)")
        }
    }

    func testLumaAdjustmentImprovesLightnessOnDarkBackground() {
        for up in SharpYUV.Upsample.allCases {
            let g = gain(width: 48, height: 40, bg: (30, 30, 34), fill: (220, 40, 200), up)
            print("T-235 magenta/dark \(up.rawValue): plain \(String(format: "%.1f", g.plain)) dB -> sharp "
                  + "\(String(format: "%.1f", g.sharp)) dB")
            XCTAssertGreaterThan(g.sharp - g.plain, 10, "\(up)")
        }
    }

    /// A flat colour needs no adjustment: the adjusted Y differs from plain Y' by at most one code.
    func testFlatColourIsNearlyUnchanged() {
        let w = 8, h = 6
        var img = [UInt8](repeating: 255, count: w * h * 4)
        for i in 0..<(w * h) { img[i * 4] = 40; img[i * 4 + 1] = 160; img[i * 4 + 2] = 200 }
        let plain = SharpYUV.convert(bgra: img, width: w, height: h, adjustFor: nil)
        for up in SharpYUV.Upsample.allCases {
            let sharp = SharpYUV.convert(bgra: img, width: w, height: h, adjustFor: up)
            XCTAssertEqual(sharp.cbcr, plain.cbcr)
            for (a, b) in zip(sharp.y, plain.y) { XCTAssertLessThanOrEqual(abs(Int(a) - Int(b)), 1) }
        }
    }

    /// Full-range BT.709 codes for primaries and greys (the plain path).
    func testPlainCodes() {
        func one(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> (UInt8, UInt8, UInt8) {
            var img = [UInt8](repeating: 255, count: 16)
            for i in 0..<4 { img[i * 4] = b; img[i * 4 + 1] = g; img[i * 4 + 2] = r }
            let p = SharpYUV.convert(bgra: img, width: 2, height: 2, adjustFor: nil)
            return (p.y[0], p.cbcr[0], p.cbcr[1])
        }
        XCTAssert(one(0, 0, 0) == (0, 128, 128))
        XCTAssert(one(255, 255, 255) == (255, 128, 128))
        XCTAssert(one(128, 128, 128) == (128, 128, 128))
        // Red: Y' 0.2126 -> 54, Cb' -0.1146 -> 99, Cr' 0.5 -> 255 (clamped from 255.5).
        XCTAssert(one(255, 0, 0) == (54, 99, 255))
        // Blue: Y' 0.0722 -> 18, Cb' 0.5 -> 255, Cr' -0.0458 -> 116.
        XCTAssert(one(0, 0, 255) == (18, 255, 116))
    }

    /// Odd sizes: the last column/row repeat into the chroma block.
    func testOddSize() {
        let img = Self.iconImage(width: 13, height: 9, background: (128, 128, 128), fill: (230, 30, 40))
        let p = SharpYUV.convert(bgra: img, width: 13, height: 9, adjustFor: .nearest)
        XCTAssertEqual(p.chromaWidth, 7)
        XCTAssertEqual(p.chromaHeight, 5)
        XCTAssertEqual(p.y.count, 13 * 9)
        XCTAssertEqual(p.cbcr.count, 7 * 5 * 2)
    }

    func testAdjustedLumaHitsTargetForNeutralChroma() {
        // With neutral chroma the rebuilt pixel is grey: the code whose sRGB luminance is closest to the target.
        for code in [0, 1, 17, 64, 128, 200, 254, 255] {
            let target = SharpYUV.srgbToLinear(Float(code) / 255)
            XCTAssertEqual(Int(SharpYUV.adjustedLuma(target: target, cb: 0, cr: 0)), code)
        }
    }

    // MARK: Metal kernel vs CPU reference

    func testMetalKernelMatchesCPUReference() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        let options = MTLCompileOptions()
        options.mathMode = .safe
        options.mathFloatingPointFunctions = .precise
        let library = try device.makeLibrary(source: SharpYUVKernel.metalSource, options: options)
        let chroma = try device.makeComputePipelineState(
            function: try XCTUnwrap(library.makeFunction(name: SharpYUVKernel.chromaFunction)))
        let luma = try device.makeComputePipelineState(
            function: try XCTUnwrap(library.makeFunction(name: SharpYUVKernel.lumaFunction)))
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let table = try XCTUnwrap(SharpYUV.eotfTable.withUnsafeBytes {
            device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared)
        })

        // Odd size, two backgrounds, plus a pseudo-random patch.
        let w = 67, h = 45
        var img = Self.iconImage(width: w, height: h, background: (128, 128, 128), fill: (230, 30, 40))
        var seed: UInt32 = 12345
        for y in 30..<h {
            for x in 0..<30 {
                seed = seed &* 1_664_525 &+ 1_013_904_223
                let o = (y * w + x) * 4
                img[o] = UInt8(truncatingIfNeeded: seed >> 8)
                img[o + 1] = UInt8(truncatingIfNeeded: seed >> 16)
                img[o + 2] = UInt8(truncatingIfNeeded: seed >> 24)
            }
        }
        // Saturation corners: pure blue on white (targets the luma code range cannot reach: code 255 / 0) and yellow
        // on black.
        for y in 0..<15 {
            for x in 45..<w {
                let o = (y * w + x) * 4
                let blue = y >= 5 && y < 10 && x >= 50 && x < 57
                img[o] = 255; img[o + 1] = blue ? 0 : 255; img[o + 2] = blue ? 0 : 255
            }
        }
        for y in 30..<h {
            for x in 45..<w {
                let o = (y * w + x) * 4
                let yellow = y >= 34 && y < 39 && x >= 49 && x < 58
                img[o] = 0; img[o + 1] = yellow ? 255 : 0; img[o + 2] = yellow ? 255 : 0
            }
        }
        let cw = (w + 1) / 2, ch = (h + 1) / 2

        func tex(_ f: MTLPixelFormat, _ tw: Int, _ th: Int) throws -> MTLTexture {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: f, width: tw, height: th, mipmapped: false)
            d.usage = [.shaderRead, .shaderWrite]
            d.storageMode = .shared
            return try XCTUnwrap(device.makeTexture(descriptor: d))
        }
        let src = try tex(.bgra8Unorm, w, h)
        img.withUnsafeBytes { src.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0,
                                          withBytes: $0.baseAddress!, bytesPerRow: w * 4) }

        for adjust in [nil, SharpYUV.Upsample.nearest] {
            let yTex = try tex(.r8Unorm, w, h), cTex = try tex(.rg8Unorm, cw, ch)
            let cb = try XCTUnwrap(queue.makeCommandBuffer())
            let e1 = try XCTUnwrap(cb.makeComputeCommandEncoder())
            e1.setComputePipelineState(chroma)
            e1.setTexture(src, index: 0)
            e1.setTexture(cTex, index: 1)
            e1.dispatchThreads(MTLSize(width: cw, height: ch, depth: 1),
                               threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1))
            e1.endEncoding()
            let e2 = try XCTUnwrap(cb.makeComputeCommandEncoder())
            var mode = SharpYUVKernel.lumaMode(adjust)
            e2.setComputePipelineState(luma)
            e2.setTexture(src, index: 0)
            e2.setTexture(cTex, index: 1)
            e2.setTexture(yTex, index: 2)
            e2.setBytes(&mode, length: 4, index: 0)
            e2.setBuffer(table, offset: 0, index: 1)
            e2.dispatchThreads(MTLSize(width: w, height: h, depth: 1),
                               threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1))
            e2.endEncoding()
            cb.commit()
            cb.waitUntilCompleted()
            XCTAssertEqual(cb.status, .completed)

            var gpuY = [UInt8](repeating: 0, count: w * h)
            var gpuC = [UInt8](repeating: 0, count: cw * ch * 2)
            gpuY.withUnsafeMutableBytes { yTex.getBytes($0.baseAddress!, bytesPerRow: w, from: MTLRegionMake2D(0, 0, w, h),
                                                        mipmapLevel: 0) }
            gpuC.withUnsafeMutableBytes { cTex.getBytes($0.baseAddress!, bytesPerRow: cw * 2,
                                                        from: MTLRegionMake2D(0, 0, cw, ch), mipmapLevel: 0) }
            let cpu = SharpYUV.convert(bgra: img, width: w, height: h, adjustFor: adjust)
            var maxY = 0, maxC = 0, diffY = 0
            for (a, b) in zip(gpuY, cpu.y) {
                let d = abs(Int(a) - Int(b))
                maxY = max(maxY, d)
                if d > 0 { diffY += 1 }
            }
            for (a, b) in zip(gpuC, cpu.cbcr) { maxC = max(maxC, abs(Int(a) - Int(b))) }
            print("T-235 metal vs cpu \(adjust?.rawValue ?? "plain"): max|dY|=\(maxY) (\(diffY) px) max|dC|=\(maxC)")
            XCTAssertLessThanOrEqual(maxY, 1, "\(String(describing: adjust))")
            XCTAssertLessThanOrEqual(maxC, 1, "\(String(describing: adjust))")
        }
    }
}
