import CoreMedia
import CoreVideo
import Foundation
import YUV444Core
import YUV444GPU

/// The result of encoding a whole scene clip as an AVC444v2 pair (two sessions).
struct SequenceResult {
    var main: [VTStream.Output?]
    var aux: [VTStream.Output?]
    /// Per frame: GPU 4:4:4 truth and source RGB, for the requested sample frames only.
    var truth: [Int: Planes444] = [:]
    var rgb: [Int: [UInt8]] = [:]
    var bgra: [Int: [UInt8]] = [:]
    var packGpuUs: [Double] = []
    var seconds = 0.0
    var mainSettings = "", auxSettings = "", hardware = ""
    var errors = 0
}

/// Offline encode: render each frame, pack it on the GPU, submit both views (the encoders run concurrently; at most
/// `maxInFlight` frames queued per session), then wait. Not paced.
func encodeSequence(scene: Scene, size: FrameSize, frames: Int, fps: Int, chroma: MainChroma, mainKbps: Int, auxKbps: Int,
                    quality: Float? = nil, auxQuality: Float? = nil, auxMinQP: Int? = nil, auxMaxQP: Int? = nil,
                    auxBurst: Int = 2, sampleFrames: Set<Int> = [], keepBGRA: Bool = false) throws -> SequenceResult {
    guard let bgra = PixelBufferIO.makeBGRA(width: size.width, height: size.height) else { throw ProbeError("BGRA buffer") }
    let packer = try Packer444(width: size.width, height: size.height, mainChroma: chroma)
    let mainStream = try VTStream(.init(width: size.width, height: size.height, fps: fps, bitrateKbps: mainKbps, quality: quality))
    let auxStream = try VTStream(.init(width: size.width, height: size.height, fps: fps, bitrateKbps: auxKbps, quality: auxQuality ?? quality,
                                       minQP: auxMinQP, maxQP: auxMaxQP, burstFactor: auxBurst))
    var result = SequenceResult(main: Array(repeating: nil, count: frames), aux: Array(repeating: nil, count: frames))
    result.mainSettings = mainStream.settingsSummary
    result.auxSettings = auxStream.settingsSummary
    result.hardware = "\(mainStream.hardware)/\(auxStream.hardware)"
    let lock = NSLock()
    let mainSlots = DispatchSemaphore(value: 4), auxSlots = DispatchSemaphore(value: 4)
    var errors = 0
    let start = Date()
    for i in 0..<frames {
        scene.render(frame: i, into: bgra, size: size)
        if sampleFrames.contains(i) {
            result.truth[i] = try packer.planes444(bgra)
            if keepBGRA { result.bgra[i] = PixelBufferIO.readBGRA(bgra) }
            result.rgb[i] = ColorMath.rgb(bgra: PixelBufferIO.readBGRA(bgra), width: size.width, height: size.height)
        }
        let packed = try packer.pack(bgra)
        result.packGpuUs.append(Double(packed.gpuUs))
        guard let aux = packed.aux else { throw ProbeError("no aux view") }
        mainSlots.wait()
        mainStream.encode(packed.main, index: i) { out in
            lock.withLock { if let out { result.main[i] = out } else { errors += 1 } }
            mainSlots.signal()
        }
        auxSlots.wait()
        auxStream.encode(aux, index: i) { out in
            lock.withLock { if let out { result.aux[i] = out } else { errors += 1 } }
            auxSlots.signal()
        }
    }
    mainStream.finish()
    auxStream.finish()
    result.seconds = Date().timeIntervalSince(start)
    result.errors = lock.withLock { errors }
    return result
}

/// Bytes per frame of one view, by phase: (mean, frames); frame 0 (the IDR) is reported separately.
func bytesByPhase(_ outputs: [VTStream.Output?], frames: Int) -> (idr: Int, perPhase: [ScenePhase: Double]) {
    var sums: [ScenePhase: (Int, Int)] = [:]
    var idr = 0
    for (i, o) in outputs.enumerated() {
        guard let o else { continue }
        if i == 0 { idr = o.bytes; continue }
        let p = ScenePhase.of(frame: i, frames: frames)
        let cur = sums[p] ?? (0, 0)
        sums[p] = (cur.0 + o.bytes, cur.1 + 1)
    }
    return (idr, sums.mapValues { $0.1 == 0 ? 0 : Double($0.0) / Double($0.1) })
}

/// Mbps at `fps` for a bytes-per-frame figure.
func mbps(_ bytesPerFrame: Double, fps: Int) -> Double { bytesPerFrame * 8 * Double(fps) / 1e6 }
