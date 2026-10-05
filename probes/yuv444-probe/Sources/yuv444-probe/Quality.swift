import CoreVideo
import Foundation
import YUV444Core
import YUV444GPU

/// One reconstruction measured against the 4:4:4 truth and the source RGB.
struct QualityRow {
    var y = 0.0, cb = 0.0, cr = 0.0, rgb = 0.0, edgeCb = 0.0, edgeCr = 0.0
    var edgePixels = 0
}

func evaluate(_ recon: Planes444, truth: Planes444, sourceRGB: [UInt8], mask: [Bool]) -> QualityRow {
    var r = QualityRow()
    r.y = Metrics.psnr(recon.y, truth.y)
    r.cb = Metrics.psnr(recon.cb, truth.cb)
    r.cr = Metrics.psnr(recon.cr, truth.cr)
    r.rgb = Metrics.psnr(ColorMath.rgb(recon), sourceRGB)
    r.edgeCb = Metrics.psnr(recon.cb, truth.cb, mask: mask)
    r.edgeCr = Metrics.psnr(recon.cr, truth.cr, mask: mask)
    r.edgePixels = mask.reduce(0) { $0 + ($1 ? 1 : 0) }
    return r
}

private func fmt(_ r: QualityRow) -> String {
    "Y \(Metrics.db(r.y)) Cb \(Metrics.db(r.cb)) Cr \(Metrics.db(r.cr)) RGB \(Metrics.db(r.rgb)) | edge Cb \(Metrics.db(r.edgeCb)) Cr \(Metrics.db(r.edgeCr))"
}

/// Accumulates rows per scheme name and prints the per-scheme mean (inf counts as 100 dB).
private struct Aggregate {
    var order: [String] = []
    var rows: [String: [QualityRow]] = [:]
    mutating func add(_ name: String, _ r: QualityRow) {
        if rows[name] == nil { order.append(name) }
        rows[name, default: []].append(r)
    }
    func print(title: String) {
        line(title)
        for name in order {
            let rs = rows[name]!
            func m(_ k: KeyPath<QualityRow, Double>) -> Double { rs.map { min($0[keyPath: k], 100) }.reduce(0, +) / Double(rs.count) }
            var r = QualityRow()
            r.y = m(\.y); r.cb = m(\.cb); r.cr = m(\.cr); r.rgb = m(\.rgb); r.edgeCb = m(\.edgeCb); r.edgeCr = m(\.edgeCr)
            line("  " + name.padding(toLength: 44, withPad: " ", startingAt: 0) + fmt(r))
        }
    }
}

private func plainSharp(bgra: [UInt8], size: FrameSize) -> Planes444 {
    let s = SharpYUVRef.convert(bgra: bgra, width: size.width, height: size.height, adjustFor: .nearest)
    var cb = [UInt8](repeating: 0, count: (size.width / 2) * (size.height / 2)), cr = cb
    for i in 0..<cb.count { cb[i] = s.cbcr[2 * i]; cr[i] = s.cbcr[2 * i + 1] }
    return ColorMath.upsample(Planes420(width: size.width, height: size.height, y: s.y, cb: cb, cr: cr), .nearest)
}

private func plain420FromSharp(bgra: [UInt8], size: FrameSize) -> Planes420 {
    let s = SharpYUVRef.convert(bgra: bgra, width: size.width, height: size.height, adjustFor: .nearest)
    var cb = [UInt8](repeating: 0, count: (size.width / 2) * (size.height / 2)), cr = cb
    for i in 0..<cb.count { cb[i] = s.cbcr[2 * i]; cr[i] = s.cbcr[2 * i + 1] }
    return Planes420(width: size.width, height: size.height, y: s.y, cb: cb, cr: cr)
}

/// M3: bit cost of the auxiliary view by scene phase, and the quality of the reconstructed 4:4:4 against plain 4:2:0 and
/// the 0033 sharp-YUV 4:2:0.
func runQuality(_ args: ProbeArgs) throws {
    let size = parseSizes(args, default: "2800x1840")[0]
    let frames = args.int("frames", 600)
    let fps = args.int("fps", 60)
    let chromas = parseChromas(args.string("main-chroma", "box,pick"))
    let mainMbps = args.double("main-mbps", 40)
    let auxRatio = args.double("aux-ratio", 0.5)
    let perPhase = args.int("samples", 1)
    // T-262 aux-session experiments (auxiliary view only).
    let auxQuality: Float? = !args.string("aux-quality", "").isEmpty ? Float(args.double("aux-quality", 0.5)) : nil
    let auxMinQP: Int? = !args.string("aux-min-qp", "").isEmpty ? args.int("aux-min-qp", 0) : nil
    let auxMaxQP: Int? = !args.string("aux-max-qp", "").isEmpty ? args.int("aux-max-qp", 0) : nil
    let auxBurst = args.int("aux-burst", 2)
    let rates = ClipNaming.bitrates(size: size, mainMbps: mainMbps, auxRatio: auxRatio)
    let q = max(1, frames / 4)
    var sampleFrames: [Int] = []
    for phase in ScenePhase.allCases {
        for k in 1...perPhase { sampleFrames.append(phase.start(frames: frames) + k * q / (perPhase + 1)) }
    }
    let scene = Scene(frames: frames, grain: args.int("grain", 4))
    line("== quality \(size) frames=\(frames) fps=\(fps) main=\(rates.mainKbps)k aux=\(rates.auxKbps)k samples=\(sampleFrames)")

    var pre = Aggregate()
    var post = Aggregate()
    var truthKept: [Int: (truth: Planes444, rgb: [UInt8], mask: [Bool], bgra: [UInt8])] = [:]

    for chroma in chromas {
        let r = try encodeSequence(scene: scene, size: size, frames: frames, fps: fps, chroma: chroma, mainKbps: rates.mainKbps,
                                   auxKbps: rates.auxKbps, auxQuality: auxQuality, auxMinQP: auxMinQP, auxMaxQP: auxMaxQP,
                                   auxBurst: auxBurst, sampleFrames: Set(sampleFrames), keepBGRA: true)
        line(String(format: "-- main-chroma=%@ encoded in %.1f s hw=%@ settings main=%@ aux=%@ errors=%d pack_gpu p50=%.0f us",
                    chroma.rawValue, r.seconds, r.hardware, r.mainSettings, r.auxSettings, r.errors,
                    Metrics.percentile(r.packGpuUs, 50)))
        // Bit cost by phase.
        let m = bytesByPhase(r.main, frames: frames), a = bytesByPhase(r.aux, frames: frames)
        line("   bytes/frame by phase (frame 0 = IDR excluded)        main kB   aux kB   aux/main   main Mbps@\(fps)   aux Mbps@\(fps)")
        for phase in ScenePhase.allCases {
            let mb = m.perPhase[phase] ?? 0, ab = a.perPhase[phase] ?? 0
            line(String(format: "   %-44@ %8.1f %8.1f %9.2f %14.1f %14.1f", phase.rawValue as NSString, mb / 1000, ab / 1000,
                        mb > 0 ? ab / mb : 0, mbps(mb, fps: fps), mbps(ab, fps: fps)))
        }
        line(String(format: "   IDR frame: main %.0f kB, aux %.0f kB; whole clip: main %.1f Mbps, aux %.1f Mbps", Double(m.idr) / 1000,
                    Double(a.idr) / 1000, mbps(Double(r.main.compactMap { $0?.bytes }.reduce(0, +)) / Double(frames), fps: fps),
                    mbps(Double(r.aux.compactMap { $0?.bytes }.reduce(0, +)) / Double(frames), fps: fps)))

        // Decode both streams, keep the sample frames.
        var mainDec: [Int: Planes420] = [:], auxDec: [Int: Planes420] = [:]
        for (outputs, isMain) in [(r.main, true), (r.aux, false)] {
            let decoder = VTDecoder()
            for (i, o) in outputs.enumerated() {
                guard let o else { throw ProbeError("missing encoded frame \(i)") }
                try decoder.decode(o.sample) { pb in
                    guard sampleFrames.contains(i) else { return }
                    let planes = PixelBufferIO.readPlanes420(pb)
                    if isMain { mainDec[i] = planes } else { auxDec[i] = planes }
                }
            }
        }
        for f in sampleFrames {
            guard let truth = r.truth[f], let rgb = r.rgb[f], let bgra = r.bgra[f], let md = mainDec[f], let ad = auxDec[f] else { continue }
            let mask = Metrics.colourEdgeMask(cb: truth.cb, cr: truth.cr, width: size.width, height: size.height)
            truthKept[f] = (truth, rgb, mask, bgra)
            let name = "\(chroma.rawValue)"
            post.add("packed \(name) main+aux, rebuilt as-is", evaluate(AVC444v2.unpack(main: md, aux: ad, reconstruction: .asIs), truth: truth, sourceRGB: rgb, mask: mask))
            if args.flag("by-phase") {
                let ph = ScenePhase.of(frame: f, frames: frames).rawValue
                post.add("  [\(ph)] packed \(name) as-is", evaluate(AVC444v2.unpack(main: md, aux: ad, reconstruction: .asIs), truth: truth, sourceRGB: rgb, mask: mask))
                post.add("  [\(ph)] main-only 4:2:0 (\(chroma.rawValue) chroma) nearest", evaluate(ColorMath.upsample(md, .nearest), truth: truth, sourceRGB: rgb, mask: mask))
            }
            if chroma == .box {
                post.add("packed box main+aux, inverse box", evaluate(AVC444v2.unpack(main: md, aux: ad, reconstruction: .inverseBox), truth: truth, sourceRGB: rgb, mask: mask))
                post.add("plain 4:2:0 (main only, box) nearest", evaluate(ColorMath.upsample(md, .nearest), truth: truth, sourceRGB: rgb, mask: mask))
                post.add("plain 4:2:0 (main only, box) bilinear", evaluate(ColorMath.upsample(md, .bilinear), truth: truth, sourceRGB: rgb, mask: mask))
            }
        }
    }

    // Pre-codec references (no compression): what each scheme loses to chroma subsampling alone.
    for f in sampleFrames {
        guard let k = truthKept[f] else { continue }
        let (boxMain, boxAux) = AVC444v2.pack(k.truth, mainChroma: .box)
        pre.add("4:4:4 (rebuilt from the codes)", evaluate(k.truth, truth: k.truth, sourceRGB: k.rgb, mask: k.mask))
        pre.add("plain 4:2:0 box nearest", evaluate(ColorMath.upsample(boxMain, .nearest), truth: k.truth, sourceRGB: k.rgb, mask: k.mask))
        pre.add("plain 4:2:0 box bilinear", evaluate(ColorMath.upsample(boxMain, .bilinear), truth: k.truth, sourceRGB: k.rgb, mask: k.mask))
        pre.add("0033 sharp YUV 4:2:0 nearest", evaluate(plainSharp(bgra: k.bgra, size: size), truth: k.truth, sourceRGB: k.rgb, mask: k.mask))
        pre.add("packed box, rebuilt as-is", evaluate(AVC444v2.unpack(main: boxMain, aux: boxAux, reconstruction: .asIs), truth: k.truth, sourceRGB: k.rgb, mask: k.mask))
        pre.add("packed box, inverse box", evaluate(AVC444v2.unpack(main: boxMain, aux: boxAux, reconstruction: .inverseBox), truth: k.truth, sourceRGB: k.rgb, mask: k.mask))
        let (pickMain, pickAux) = AVC444v2.pack(k.truth, mainChroma: .pick)
        pre.add("packed pick", evaluate(AVC444v2.unpack(main: pickMain, aux: pickAux, reconstruction: .asIs), truth: k.truth, sourceRGB: k.rgb, mask: k.mask))
    }
    pre.print(title: "-- before compression (mean over \(truthKept.count) sample frames, dB; PSNR vs the 4:4:4 truth, RGB vs the source)")
    post.print(title: "-- after VideoToolbox encode + decode at \(rates.mainKbps)k/\(rates.auxKbps)k, sequence run (mean over sample frames, dB)")

    if !args.flag("no-intra") {
        let qualities = args.string("intra-quality", "0.6,0.8").split(separator: ",").compactMap { Float($0) }
        try runIntraComparison(size: size, scene: scene, frames: frames, kept: truthKept, qualities: qualities, sampleFrames: sampleFrames)
    }
}

/// Equal-quality still comparison: each sample frame as an IDR at the same VideoToolbox `Quality`, for plain 4:2:0, 0033
/// sharp 4:2:0 and the packed pair, so the bits and the dB of each scheme are comparable.
private func runIntraComparison(size: FrameSize, scene: Scene, frames: Int,
                                kept: [Int: (truth: Planes444, rgb: [UInt8], mask: [Bool], bgra: [UInt8])],
                                qualities: [Float], sampleFrames: [Int]) throws {
    let packer = try Packer444(width: size.width, height: size.height, mainChroma: .box)
    guard let src = PixelBufferIO.makeBGRA(width: size.width, height: size.height),
          let sharpBuf = PixelBufferIO.make420f(width: size.width, height: size.height) else { throw ProbeError("buffers") }
    for quality in qualities {
        var agg = Aggregate()
        var bytes: [String: [Double]] = [:]
        let main = try VTStream(.init(width: size.width, height: size.height, fps: 60, bitrateKbps: 400_000, quality: quality))
        let aux = try VTStream(.init(width: size.width, height: size.height, fps: 60, bitrateKbps: 400_000, quality: quality))
        let sharp = try VTStream(.init(width: size.width, height: size.height, fps: 60, bitrateKbps: 400_000, quality: quality))
        guard main.qualityApplied else { line("-- intra quality \(quality): VideoToolbox refused the Quality property, skipped"); continue }
        let decoders = [VTDecoder(), VTDecoder(), VTDecoder()]
        var idx = 0
        for f in sampleFrames {
            guard let k = kept[f] else { continue }
            scene.render(frame: f, into: src, size: size)
            let packed = try packer.pack(src)
            PixelBufferIO.write(plain420FromSharp(bgra: k.bgra, size: size), to: sharpBuf)
            SessionTags.apply(to: sharpBuf, centredChroma: true)
            var decoded: [Planes420?] = [nil, nil, nil]
            var sizes = [0, 0, 0]
            for (n, (stream, pb)) in [(main, packed.main), (aux, packed.aux!), (sharp, sharpBuf)].enumerated() {
                let sem = DispatchSemaphore(value: 0)
                var out: VTStream.Output?
                stream.encode(pb, index: idx, forceKey: true) { o in out = o; sem.signal() }
                sem.wait()
                guard let out else { throw ProbeError("intra encode failed") }
                sizes[n] = out.bytes
                try decoders[n].decode(out.sample) { decoded[n] = PixelBufferIO.readPlanes420($0) }
            }
            idx += 1
            guard let md = decoded[0], let ad = decoded[1], let sd = decoded[2] else { continue }
            agg.add("plain 4:2:0 box (main only) bilinear", evaluate(ColorMath.upsample(md, .bilinear), truth: k.truth, sourceRGB: k.rgb, mask: k.mask))
            agg.add("0033 sharp 4:2:0 nearest", evaluate(ColorMath.upsample(sd, .nearest), truth: k.truth, sourceRGB: k.rgb, mask: k.mask))
            agg.add("packed box, as-is", evaluate(AVC444v2.unpack(main: md, aux: ad, reconstruction: .asIs), truth: k.truth, sourceRGB: k.rgb, mask: k.mask))
            agg.add("packed box, inverse box", evaluate(AVC444v2.unpack(main: md, aux: ad, reconstruction: .inverseBox), truth: k.truth, sourceRGB: k.rgb, mask: k.mask))
            let phase = ScenePhase.of(frame: f, frames: frames).rawValue
            line(String(format: "   quality %.2f frame %3d (%@): IDR kB main %.0f aux %.0f sharp %.0f", quality, f, phase as NSString,
                        Double(sizes[0]) / 1000, Double(sizes[1]) / 1000, Double(sizes[2]) / 1000))
            bytes["main", default: []].append(Double(sizes[0]))
            bytes["aux", default: []].append(Double(sizes[1]))
            bytes["sharp", default: []].append(Double(sizes[2]))
        }
        let mm = Metrics.mean(bytes["main"] ?? []), am = Metrics.mean(bytes["aux"] ?? []), sm = Metrics.mean(bytes["sharp"] ?? [])
        line(String(format: "-- intra, VideoToolbox Quality %.2f (mean IDR kB: plain/main %.0f, aux %.0f = %.2fx main, 0033 sharp %.0f; packed total %.2fx plain)",
                    quality, mm / 1000, am / 1000, mm > 0 ? am / mm : 0, sm / 1000, mm > 0 ? (mm + am) / mm : 0))
        agg.print(title: "   dB, mean over sample frames")
    }
}
