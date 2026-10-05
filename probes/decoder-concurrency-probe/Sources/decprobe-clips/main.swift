import DecProbeCore
import Foundation

// T-248: makes the HEVC clips for the Android decoder concurrency probe. See ../../README.md.
// Touches only the hardware HEVC encoder (one session at a time, a few seconds per clip): no display, no capture,
// no window. Do not run it while a MateBridge stream is live.

let args = ProbeArgs(Array(CommandLine.arguments.dropFirst()))
if args.flag("help") || args.flag("h") {
    print("""
    usage: decprobe-clips [--frames 600] [--fps 120] [--full-kbps 60000] [--clips full,half,half_right,quarter]
                          [--out-dir ~/.cache/matebridge-tools/data/decprobe]
    """)
    exit(0)
}

let frames = args.int("frames", 600)
let fps = args.int("fps", 120)
let defaultDir = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".cache/matebridge-tools/data/decprobe").path
let outDir = (args.string("out-dir", defaultDir) as NSString).expandingTildeInPath
let wanted = Set(args.string("clips", "full,half,half_right,quarter").split(separator: ",").map(String.init))
let clips = ClipSpec.standard(fullBitrateKbps: args.int("full-kbps", 60_000)).filter { wanted.contains($0.id) }

do {
    try FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
    let t0 = Date()
    let scene = Scene(frames: frames)
    print(String(format: "scene ready in %.1f s (%d frames, %d fps rate control)", Date().timeIntervalSince(t0),
                 frames, fps))
    if let p = args.options["preview"], let index = Int(p) {
        // Writes the selected clips' frame `index` as PNG instead of encoding (to eyeball the content).
        for spec in clips {
            let path = (outDir as NSString).appendingPathComponent("preview_\(spec.id)_\(index).png")
            try Preview.write(scene: scene, spec: spec, frame: index, to: path)
            print("wrote \(path)")
        }
        exit(0)
    }
    var failed = false
    for spec in clips {
        let path = (outDir as NSString).appendingPathComponent(spec.fileName)
        let r = try ClipEncoder(spec: spec, scene: scene, frames: frames, fps: fps).run(to: path)
        // Verify the file the Android probe will parse: one picture per frame, one IRAP at the start.
        let bytes = [UInt8](try Data(contentsOf: URL(fileURLWithPath: path)))
        let pictures = AnnexB.pictureCount(bytes), irap = AnnexB.irapCount(bytes)
        let ok = pictures == frames && r.frames == frames && r.errors == 0 && irap >= 1
        failed = failed || !ok
        print(String(format: "%@ %@ %dx%d target %d kbps: frames=%d pictures=%d irap=%d errors=%d bytes=%d "
                         + "(%.1f Mbps at %d fps, %.0f KB/frame) encode %.1f s %@",
                     ok ? "OK  " : "FAIL", spec.fileName, spec.width, spec.height, spec.bitrateKbps, r.frames,
                     pictures, irap, r.errors, r.bytes, Double(r.bytes) * 8 * Double(fps) / Double(max(frames, 1)) / 1e6,
                     fps, Double(r.bytes) / Double(max(frames, 1)) / 1024, r.seconds, path))
        print("     settings: " + r.settings.joined(separator: " "))
    }
    exit(failed ? 1 : 0)
} catch {
    print("error: \(error)")
    exit(1)
}
