import CoreVideo
import Foundation
import YUV444Core
import YUV444GPU

let defaultDataDir = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".cache/matebridge-tools/data/yuv444").path

func dataDir(_ args: ProbeArgs) -> String { (args.string("out-dir", defaultDataDir) as NSString).expandingTildeInPath }

func parseSizes(_ args: ProbeArgs, default def: String = "2800x1840,1848x1214") -> [FrameSize] {
    guard let sizes = FrameSize.parseList(args.string("size", def)) else {
        print("error: bad --size '\(args.string("size", def))' (WxH list, width % 4 == 0, height % 2 == 0)")
        exit(2)
    }
    return sizes
}

func parseChromas(_ text: String) -> [MainChroma] {
    let list = text.split(separator: ",").compactMap { MainChroma(rawValue: String($0)) }
    if list.isEmpty { print("error: bad main chroma '\(text)' (pick, box)"); exit(2) }
    return list
}

/// Renders `count` consecutive scene frames starting at `from` into BGRA buffers (the source ring of the benches).
func renderRing(_ scene: Scene, size: FrameSize, from: Int, count: Int) throws -> [CVPixelBuffer] {
    var out: [CVPixelBuffer] = []
    for i in 0..<count {
        guard let pb = PixelBufferIO.makeBGRA(width: size.width, height: size.height) else { throw ProbeError("BGRA buffer") }
        scene.render(frame: from + i, into: pb, size: size)
        out.append(pb)
    }
    return out
}

/// Ping-pong index into a ring of `n` frames: 0, 1, ..., n-1, n-2, ..., 1, 0, 1, ... (continuous motion, no jump cut).
func pingPong(_ i: Int, _ n: Int) -> Int {
    guard n > 1 else { return 0 }
    let period = 2 * (n - 1)
    let k = i % period
    return k < n ? k : period - k
}

/// Scene frame index where the named content starts ("still", "typing", "scroll", "video") for a clip of `frames`.
func contentStart(_ name: String, frames: Int) -> Int {
    (ScenePhase(rawValue: name) ?? .scroll).start(frames: frames) + 2
}

extension Planes420 {
    /// Total bytes of the three planes (for logging only).
    var sampleCount: Int { y.count + cb.count + cr.count }
}

func line(_ s: String) { print(s); fflush(stdout) }

func thermalNote() -> String {
    switch ProcessInfo.processInfo.thermalState {
    case .nominal: return "nominal"
    case .fair: return "fair"
    case .serious: return "serious"
    case .critical: return "critical"
    @unknown default: return "?"
    }
}
