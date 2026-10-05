import DecProbeCore
import Foundation

// T-248 / T-249: makes the HEVC clips for the Android decoder probe. See ../../README.md.
// Touches only the hardware HEVC encoder (one session at a time, a few seconds per clip): no display, no capture,
// no window. Do not run it while a MateBridge stream is live.

let args = ProbeArgs(Array(CommandLine.arguments.dropFirst()))
if args.flag("help") || args.flag("h") {
    print("""
    usage: decprobe-clips [--frames 600] [--fps 120] [--clips full] [--variants LIST] [--grain N] [--no-retry]
                          [--out-dir ~/.cache/matebridge-tools/data/decprobe] [--preview FRAME]
      --clips     crops to make: full,half,half_right,quarter (default full)
      --variants  comma list of DEPTH@MBPS[/idrN]; DEPTH = 8 | 10sdr | 10pq; MBPS = full-frame Mbps (crops scale by area)
                  default: 8@60,10sdr@60,10pq@60,8@80,8@100,8@150,10pq@80,10pq@100,10pq@150,8@60/idr60
      --grain     photo grain amplitude (default grows with the bitrate); --no-retry stops the automatic re-encode
                  with more grain when a clip lands more than 15 % under its target bitrate
    """)
    exit(0)
}

let frames = args.int("frames", 600)
let fps = args.int("fps", 120)
let defaultDir = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".cache/matebridge-tools/data/decprobe").path
let outDir = (args.string("out-dir", defaultDir) as NSString).expandingTildeInPath
let wanted = args.string("clips", "full").split(separator: ",").map(String.init)
let variants: [ClipVariant]
if let v = args.options["variants"] {
    guard let parsed = ClipVariant.parseList(v) else {
        print("error: bad --variants '\(v)' (expected DEPTH@MBPS[/idrN], e.g. 10pq@100,8@60/idr60)")
        exit(2)
    }
    variants = parsed
} else {
    variants = ClipVariant.defaultSet
}
var clips: [ClipSpec] = []
for v in variants {
    clips += ClipSpec.standard(fullBitrateKbps: v.mbps * 1000, depth: v.depth, idrInterval: v.idrInterval)
        .filter { wanted.contains($0.id) }
}

/// Grain amplitude that usually reaches the target: 6 up to 60 Mbps, then +1 per 4 Mbps.
func defaultGrain(fullMbps: Double) -> Int { 6 + max(0, Int((fullMbps - 60) / 4)) }

var scenes: [Int: Scene] = [:]
func scene(grain: Int) -> Scene {
    if let s = scenes[grain] { return s }
    let t0 = Date()
    let s = Scene(frames: frames, grain: grain)
    print(String(format: "scene ready in %.1f s (%d frames, grain %d, %d fps rate control)", Date().timeIntervalSince(t0),
                 frames, grain, fps))
    scenes = [grain: s]   // keep one scene: a photo at this size is large
    return s
}

/// Checks the file the Android probe will parse; returns problems (empty = ok) and a short description.
func verify(path: String, spec: ClipSpec, encoded: ClipEncoder.Result) throws -> (problems: [String], text: String) {
    let bytes = [UInt8](try Data(contentsOf: URL(fileURLWithPath: path)))
    let pictures = AnnexB.pictureCount(bytes), irap = AnnexB.irapCount(bytes)
    let wantIrap = spec.idrInterval > 0 ? (frames + spec.idrInterval - 1) / spec.idrInterval : 1
    var problems: [String] = []
    if pictures != frames || encoded.frames != frames { problems.append("pictures=\(pictures) != \(frames)") }
    if encoded.errors != 0 { problems.append("encoder errors=\(encoded.errors)") }
    if irap < wantIrap { problems.append("irap=\(irap) < \(wantIrap)") }
    let nals = AnnexB.splitNALs(bytes)
    var text = "pictures=\(pictures) irap=\(irap)"
    if let spsNal = nals.first(where: { AnnexB.nalType($0) == 33 }), let sps = HevcSPS.parse(spsNal) {
        let c = spec.depth.colour
        text += " sps[profile=\(sps.profileIdc) depth=\(sps.bitDepthLuma)/\(sps.bitDepthChroma) "
            + "colour=\(sps.colourPrimaries.map(String.init) ?? "-")/\(sps.transfer.map(String.init) ?? "-")/"
            + "\(sps.matrix.map(String.init) ?? "-")]"
        if sps.profileIdc != spec.depth.profileIdc { problems.append("profile_idc=\(sps.profileIdc)") }
        if sps.bitDepthLuma != spec.depth.bitDepth || sps.bitDepthChroma != spec.depth.bitDepth {
            problems.append("bit_depth=\(sps.bitDepthLuma)/\(sps.bitDepthChroma)")
        }
        if sps.width != spec.width || sps.height != spec.height { problems.append("sps size \(sps.width)x\(sps.height)") }
        if sps.colourPrimaries != c.primaries || sps.transfer != c.transfer || sps.matrix != c.matrix {
            problems.append("VUI colour \(String(describing: sps.colourPrimaries))/\(String(describing: sps.transfer))/"
                + "\(String(describing: sps.matrix)) != \(c.primaries)/\(c.transfer)/\(c.matrix)")
        }
    } else {
        problems.append("SPS missing or not parseable")
    }
    if spec.depth == .pq10 {
        let sei = HevcSPS.seiPayloadTypes(nals)
        text += " sei=\(sei.sorted())"
        if !sei.contains(137) { problems.append("no mastering display SEI") }
        if !sei.contains(144) { problems.append("no content light level SEI") }
    }
    return (problems, text)
}

do {
    try FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
    if let p = args.options["preview"], let index = Int(p) {
        // Writes the selected clips' frame `index` as PNG instead of encoding (to eyeball the content).
        let s = scene(grain: args.int("grain", 6))
        for spec in ClipSpec.standard().filter({ wanted.contains($0.id) }) {
            let path = (outDir as NSString).appendingPathComponent("preview_\(spec.id)_\(index).png")
            try Preview.write(scene: s, spec: spec, frame: index, to: path)
            print("wrote \(path)")
        }
        exit(0)
    }
    var failed = false
    var off: [String] = []
    for spec in clips {
        let path = (outDir as NSString).appendingPathComponent(spec.fileName)
        var grain = args.options["grain"].flatMap { Int($0) }
            ?? defaultGrain(fullMbps: Double(spec.bitrateKbps) / 1000 * Double(ClipSpec.sceneWidth * ClipSpec.sceneHeight)
                / Double(spec.width * spec.height))
        var attempt = 0
        var r = ClipEncoder.Result()
        var mbps = 0.0, dev = 0.0
        while true {
            r = try ClipEncoder(spec: spec, scene: scene(grain: grain), frames: frames, fps: fps).run(to: path)
            mbps = Realized.mbps(bytes: r.bytes, frames: frames, fps: fps)
            dev = Realized.deviation(actualMbps: mbps, targetKbps: spec.bitrateKbps)
            attempt += 1
            // Content too easy (under target) or too hard (over): adjust the grain and try again (at most 3 retries).
            if Realized.isOffTarget(dev), !args.flag("no-retry"), args.options["grain"] == nil, attempt <= 3 {
                let next = dev < 0 ? grain * 3 / 2 + 1 : grain * 4 / 5
                if next != grain {
                    grain = next
                    print(String(format: "     %@ realized %.1f Mbps is %+.0f %% from target, retrying with grain %d",
                                 spec.fileName, mbps, dev * 100, grain))
                    continue
                }
            }
            break
        }
        let (problems, text) = try verify(path: path, spec: spec, encoded: r)
        let ok = problems.isEmpty
        failed = failed || !ok
        let offTarget = Realized.isOffTarget(dev)
        if offTarget { off.append(spec.fileName) }
        print(String(format: "%@ %@ %dx%d depth=%@ target %d kbps: %@ errors=%d bytes=%d "
                         + "realized %.1f Mbps at %d fps (%+.0f %%)%@ %.0f KB/frame grain=%d encode %.1f s %@",
                     ok ? "OK  " : "FAIL", spec.fileName, spec.width, spec.height, spec.depth.rawValue,
                     spec.bitrateKbps, text, r.errors, r.bytes, mbps, fps, dev * 100,
                     offTarget ? " OFF-TARGET" : "", Double(r.bytes) / Double(max(frames, 1)) / 1024, grain, r.seconds, path))
        if !ok { print("     problems: " + problems.joined(separator: "; ")) }
        print("     settings: " + r.settings.joined(separator: " "))
    }
    if !off.isEmpty { print("OFF-TARGET (more than 15 % from the target bitrate): " + off.joined(separator: ", ")) }
    exit(failed ? 1 : 0)
} catch {
    print("error: \(error)")
    exit(1)
}
