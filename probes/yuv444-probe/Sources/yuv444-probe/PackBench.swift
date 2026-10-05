import CoreVideo
import Foundation
import YUV444Core
import YUV444GPU

/// M1: GPU time of the packer at each frame size, for the fused and the two-pass kernels, `pick` and `box`, and the
/// main-view-only pass (a plain BGRA -> 420f conversion: the baseline the aux view adds to).
func runPackBench(_ args: ProbeArgs) throws {
    let iters = args.int("iters", 400)
    let warmup = args.int("warmup", 40)
    let content = args.string("content", "scroll")
    for size in parseSizes(args) {
        let scene = Scene(frames: 600)
        guard let src = try renderRing(scene, size: size, from: contentStart(content, frames: 600), count: 1).first else { continue }
        line("== pack-bench \(size) iters=\(iters) content=\(content) thermal=\(thermalNote())")
        line("variant                  gpu_us p50/p95/p99/max       wall_us p50/p95/p99/max")
        struct Variant { var name: String; var chroma: MainChroma; var strategy: Packer444.Strategy; var aux: Bool }
        let variants = [
            Variant(name: "main-only (box)", chroma: .box, strategy: .fused, aux: false),
            Variant(name: "fused v2 pick", chroma: .pick, strategy: .fused, aux: true),
            Variant(name: "fused v2 box", chroma: .box, strategy: .fused, aux: true),
            Variant(name: "two-pass v2 pick", chroma: .pick, strategy: .twoPass, aux: true),
            Variant(name: "two-pass v2 box", chroma: .box, strategy: .twoPass, aux: true),
        ]
        for v in variants {
            let packer = try Packer444(width: size.width, height: size.height, mainChroma: v.chroma, strategy: v.strategy,
                                       includeAux: v.aux)
            for _ in 0..<warmup { _ = try packer.pack(src) }
            var gpu: [Double] = [], wall: [Double] = []
            for _ in 0..<iters {
                let r = try packer.pack(src)
                gpu.append(Double(r.gpuUs))
                wall.append(Double(r.wallUs))
            }
            line(String(format: "%-24@ %-28@ %@", v.name as NSString, Metrics.summary(gpu) as NSString, Metrics.summary(wall) as NSString))
        }
    }
}
