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

    // MARK: Metal kernels vs CPU reference and vs the T-235 device-LUT source

    /// Test image: icon blocks, a pseudo-random patch and the saturation corners (pure blue on white, yellow on
    /// black: targets the luma code range cannot reach), at any size >= 67x45.
    static func mixedImage(width w: Int, height h: Int, seed initial: UInt32 = 12345) -> [UInt8] {
        var img = iconImage(width: w, height: h, background: (128, 128, 128), fill: (230, 30, 40))
        var seed = initial
        for y in (h * 2 / 3)..<h {
            for x in 0..<(w * 4 / 9) {
                seed = seed &* 1_664_525 &+ 1_013_904_223
                let o = (y * w + x) * 4
                img[o] = UInt8(truncatingIfNeeded: seed >> 8)
                img[o + 1] = UInt8(truncatingIfNeeded: seed >> 16)
                img[o + 2] = UInt8(truncatingIfNeeded: seed >> 24)
            }
        }
        for y in 0..<(h / 3) {
            for x in (w * 2 / 3)..<w {
                let o = (y * w + x) * 4
                let blue = y >= h / 9 && y < h * 2 / 9 && x >= w * 3 / 4 && x < w * 6 / 7
                img[o] = 255; img[o + 1] = blue ? 0 : 255; img[o + 2] = blue ? 0 : 255
            }
        }
        for y in (h * 2 / 3)..<h {
            for x in (w * 2 / 3)..<w {
                let o = (y * w + x) * 4
                let yellow = y >= h * 3 / 4 && y < h * 6 / 7 && x >= w * 3 / 4 && x < w * 6 / 7
                img[o] = 0; img[o + 1] = yellow ? 255 : 0; img[o + 2] = yellow ? 255 : 0
            }
        }
        return img
    }

    /// Fully random pixels: every 2x2 block is non-flat, every luma search runs.
    static func noiseImage(width w: Int, height h: Int, seed initial: UInt32) -> [UInt8] {
        var img = [UInt8](repeating: 255, count: w * h * 4)
        var seed = initial
        for i in 0..<(w * h) {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            img[i * 4] = UInt8(truncatingIfNeeded: seed >> 8)
            img[i * 4 + 1] = UInt8(truncatingIfNeeded: seed >> 16)
            img[i * 4 + 2] = UInt8(truncatingIfNeeded: seed >> 24)
        }
        return img
    }

    private struct GPUPlanes {
        var y: [UInt8]
        var cbcr: [UInt8]
    }

    /// Runs the two-pass kernels in `source` (chroma, then luma in a second encoder) on `img` in `mode`.
    private func runTwoPass(source: String, chromaName: String, lumaName: String, _ img: [UInt8], w: Int, h: Int,
                            adjust: SharpYUV.Upsample?) throws -> GPUPlanes {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        let options = MTLCompileOptions()
        options.mathMode = .safe
        options.mathFloatingPointFunctions = .precise
        let lib = try device.makeLibrary(source: source, options: options)
        let chroma = try device.makeComputePipelineState(function: try XCTUnwrap(lib.makeFunction(name: chromaName)))
        let luma = try device.makeComputePipelineState(function: try XCTUnwrap(lib.makeFunction(name: lumaName)))
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let table = try XCTUnwrap(SharpYUV.eotfTable.withUnsafeBytes {
            device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared)
        })
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
        var mode = SharpYUVKernel.lumaMode(adjust)
        let group = MTLSize(width: 8, height: 8, depth: 1)
        let yTex = try tex(.r8Unorm, w, h), cTex = try tex(.rg8Unorm, cw, ch)
        let cb = try XCTUnwrap(queue.makeCommandBuffer())
        let e1 = try XCTUnwrap(cb.makeComputeCommandEncoder())
        e1.setComputePipelineState(chroma)
        e1.setTexture(src, index: 0)
        e1.setTexture(cTex, index: 1)
        e1.dispatchThreads(MTLSize(width: cw, height: ch, depth: 1), threadsPerThreadgroup: group)
        e1.endEncoding()
        let e2 = try XCTUnwrap(cb.makeComputeCommandEncoder())
        e2.setComputePipelineState(luma)
        e2.setTexture(src, index: 0)
        e2.setTexture(cTex, index: 1)
        e2.setTexture(yTex, index: 2)
        e2.setBytes(&mode, length: 4, index: 0)
        e2.setBuffer(table, offset: 0, index: 1)
        e2.dispatchThreads(MTLSize(width: w, height: h, depth: 1), threadsPerThreadgroup: group)
        e2.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
        XCTAssertEqual(cb.status, .completed)
        var gy = [UInt8](repeating: 0, count: w * h)
        var gc = [UInt8](repeating: 0, count: cw * ch * 2)
        gy.withUnsafeMutableBytes { yTex.getBytes($0.baseAddress!, bytesPerRow: w, from: MTLRegionMake2D(0, 0, w, h),
                                                  mipmapLevel: 0) }
        gc.withUnsafeMutableBytes { cTex.getBytes($0.baseAddress!, bytesPerRow: cw * 2,
                                                  from: MTLRegionMake2D(0, 0, cw, ch), mipmapLevel: 0) }
        return GPUPlanes(y: gy, cbcr: gc)
    }

    /// The production kernels (LUT in `constant` memory) and the T-235 source (LUT in `device` memory) on `img`.
    private func runBoth(_ img: [UInt8], w: Int, h: Int, adjust: SharpYUV.Upsample?) throws
        -> (prod: GPUPlanes, legacy: GPUPlanes) {
        let prod = try runTwoPass(source: SharpYUVKernel.metalSource, chromaName: SharpYUVKernel.chromaFunction,
                                  lumaName: SharpYUVKernel.lumaFunction, img, w: w, h: h, adjust: adjust)
        let legacy = try runTwoPass(source: LegacyTwoPassKernel.source, chromaName: LegacyTwoPassKernel.chromaFunction,
                                    lumaName: LegacyTwoPassKernel.lumaFunction, img, w: w, h: h, adjust: adjust)
        return (prod, legacy)
    }

    private func maxDiff(_ a: [UInt8], _ b: [UInt8]) -> (max: Int, count: Int) {
        var m = 0, n = 0
        for (x, y) in zip(a, b) {
            let d = abs(Int(x) - Int(y))
            m = max(m, d)
            if d > 0 { n += 1 }
        }
        return (m, n)
    }

    /// The shipped Metal kernel against the CPU reference (the T-235 tolerance: `pow` and rounding ties may differ on
    /// the GPU by one code).
    func testMetalKernelMatchesCPUReference() throws {
        let w = 67, h = 45   // odd size
        let img = Self.mixedImage(width: w, height: h)
        for adjust in [nil, SharpYUV.Upsample.nearest] {
            let gpu = try runBoth(img, w: w, h: h, adjust: adjust).prod
            let cpu = SharpYUV.convert(bgra: img, width: w, height: h, adjustFor: adjust)
            let dy = maxDiff(gpu.y, cpu.y), dc = maxDiff(gpu.cbcr, cpu.cbcr)
            print("T-314 vs cpu \(adjust?.rawValue ?? "plain"): max|dY|=\(dy.max) (\(dy.count) px) max|dC|=\(dc.max)")
            XCTAssertLessThanOrEqual(dy.max, 1, "\(String(describing: adjust))")
            XCTAssertLessThanOrEqual(dc.max, 1, "\(String(describing: adjust))")
        }
    }

    /// T-314 hard gate: the production two-pass kernels (LUT in `constant` memory) produce exactly the bytes of the
    /// T-235 source (LUT in `device` memory), on odd and even sizes, in both modes, on icon / saturation-corner /
    /// full-noise content.
    func testProductionKernelsAreBitExactWithDeviceLUTSource() throws {
        let sizes = [(67, 45), (64, 48), (1, 1), (2, 1), (1, 3), (5, 2), (130, 91), (256, 144)]
        for (w, h) in sizes {
            var images = [("noise", Self.noiseImage(width: w, height: h, seed: UInt32(w * 31 + h)))]
            if w >= 67 && h >= 45 { images.append(("mixed", Self.mixedImage(width: w, height: h, seed: UInt32(h)))) }
            for (name, img) in images {
                for adjust in [nil, SharpYUV.Upsample.nearest] {
                    let r = try runBoth(img, w: w, h: h, adjust: adjust)
                    XCTAssertEqual(r.prod.y, r.legacy.y, "Y \(name) \(w)x\(h) \(adjust?.rawValue ?? "plain")")
                    XCTAssertEqual(r.prod.cbcr, r.legacy.cbcr, "CbCr \(name) \(w)x\(h) \(adjust?.rawValue ?? "plain")")
                    // Same distance from the CPU reference as the two-pass kernels had (and never worse than 1).
                    let cpu = SharpYUV.convert(bgra: img, width: w, height: h, adjustFor: adjust)
                    XCTAssertLessThanOrEqual(maxDiff(r.prod.y, cpu.y).max, 1, "\(name) \(w)x\(h)")
                    XCTAssertEqual(maxDiff(r.prod.y, cpu.y).count, maxDiff(r.legacy.y, cpu.y).count)
                }
            }
        }
    }
}
