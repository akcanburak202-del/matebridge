import CoreVideo
import Foundation
import YUV444Core
import YUV444GPU

/// A colour-tag scenario for the buffers fed to the encoder (the session always declares MateBridge's tags).
private struct TagScenario {
    var name: String
    var apply: (CVPixelBuffer) -> Void
}

private let scenarios: [TagScenario] = [
    TagScenario(name: "retagged to the session's tags (T-113, MateBridge)") { SessionTags.apply(to: $0, centredChroma: false) },
    TagScenario(name: "no colour attachments") { _ in },
    TagScenario(name: "SCK-like: 709 primaries, 709 transfer, 709 matrix") {
        CVBufferSetAttachment($0, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment($0, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment($0, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
    },
    TagScenario(name: "matrix BT.601, rest as session") {
        SessionTags.apply(to: $0, centredChroma: false)
        CVBufferSetAttachment($0, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_601_4, .shouldPropagate)
    },
    TagScenario(name: "BT.2020 primaries/matrix, PQ transfer") {
        CVBufferSetAttachment($0, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_2020, .shouldPropagate)
        CVBufferSetAttachment($0, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ, .shouldPropagate)
        CVBufferSetAttachment($0, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_2020, .shouldPropagate)
    },
]

/// Flat 16x16 luma and 8x8 chroma blocks (CTU/CU aligned, so a near-lossless encode reproduces them) cycling through all
/// 256 values, plus a smooth ramp band along the bottom: data, not a picture, like the auxiliary view.
private func patternPlanes(width w: Int, height h: Int) -> Planes420 {
    var p = Planes420(width: w, height: h)
    let rampTop = h - 64
    for y in 0..<h {
        for x in 0..<w {
            p.y[y * w + x] = y >= rampTop ? UInt8(truncatingIfNeeded: x) : UInt8(truncatingIfNeeded: (x / 16) * 13 + (y / 16) * 29)
        }
    }
    let cw = w / 2, ch = h / 2
    for j in 0..<ch {
        for i in 0..<cw {
            p.cb[j * cw + i] = UInt8(truncatingIfNeeded: (i / 8) * 11 + (j / 8) * 37 + 5)
            p.cr[j * cw + i] = UInt8(truncatingIfNeeded: (i / 8) * 23 + (j / 8) * 7 + 101)
        }
    }
    return p
}

/// M4: does the auxiliary view survive the encoder bit-faithfully, and does a colour-tag mismatch (what VideoToolbox
/// converts away, T-113) destroy it? Encodes one near-lossless picture (a few identical frames, so the P frames are
/// covered too) per scenario, decodes it and compares every sample with the input.
func runBitExact(_ args: ProbeArgs) throws {
    let size = parseSizes(args, default: "1280x720")[0]
    var inputs: [(String, Planes420)] = [("pattern \(size) (flat blocks + ramp)", patternPlanes(width: size.width, height: size.height))]
    if !args.flag("no-real") {
        // A real auxiliary view: packed by the GPU from a scene frame (box main chroma).
        let real = FrameSize.reduced
        let scene = Scene(frames: 600)
        if let src = PixelBufferIO.makeBGRA(width: real.width, height: real.height) {
            scene.render(frame: 400, into: src, size: real)
            let packed = try Packer444(width: real.width, height: real.height, mainChroma: .box).pack(src)
            inputs.append(("real aux view of scene frame 400 at \(real)", PixelBufferIO.readPlanes420(packed.aux!)))
            inputs.append(("real main view of scene frame 400 at \(real) (control)", PixelBufferIO.readPlanes420(packed.main)))
        }
    }
    let frames = 3
    for (title, planes) in inputs {
        line("== bitexact: \(title)")
        line("scenario                                                     | Y max/mean        Cb max/mean       Cr max/mean       | exact%  PSNR Y/Cb/Cr dB")
        for scenario in scenarios {
            // Near-lossless: Quality 1.0, else a very high bitrate.
            let stream = try VTStream(.init(width: planes.width, height: planes.height, fps: 60, bitrateKbps: 400_000, quality: 1.0))
            let decoder = VTDecoder()
            var outputs: [VTStream.Output?] = Array(repeating: nil, count: frames)
            for i in 0..<frames {
                guard let pb = PixelBufferIO.make420f(width: planes.width, height: planes.height) else { throw ProbeError("buffer") }
                PixelBufferIO.write(planes, to: pb)
                scenario.apply(pb)
                let sem = DispatchSemaphore(value: 0)
                stream.encode(pb, index: i) { outputs[i] = $0; sem.signal() }
                sem.wait()
            }
            var last: Planes420?
            for o in outputs {
                guard let o else { throw ProbeError("encode failed") }
                try decoder.decode(o.sample) { last = PixelBufferIO.readPlanes420($0) }
            }
            guard let d = last else { continue }
            let ey = Metrics.absError(planes.y, d.y), ecb = Metrics.absError(planes.cb, d.cb), ecr = Metrics.absError(planes.cr, d.cr)
            var same = 0
            for i in 0..<planes.y.count where planes.y[i] == d.y[i] { same += 1 }
            for i in 0..<planes.cb.count where planes.cb[i] == d.cb[i] { same += 1 }
            for i in 0..<planes.cr.count where planes.cr[i] == d.cr[i] { same += 1 }
            let exact = Double(same) / Double(planes.sampleCount) * 100
            line(String(format: "%-60@ | %3d / %6.3f     %3d / %6.3f     %3d / %6.3f     | %6.2f  %@ / %@ / %@",
                        scenario.name as NSString, ey.max, ey.mean, ecb.max, ecb.mean, ecr.max, ecr.mean, exact,
                        Metrics.db(Metrics.psnr(planes.y, d.y)), Metrics.db(Metrics.psnr(planes.cb, d.cb)),
                        Metrics.db(Metrics.psnr(planes.cr, d.cr))))
            if !stream.qualityApplied { line("   (note: Quality refused, encoded at 400 Mbps average)") }
        }
    }
}
