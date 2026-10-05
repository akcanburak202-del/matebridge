import CoreVideo
import Foundation
import YUV444Core
import YUV444GPU

private func waitUntil(_ target: UInt64) {
    while true {
        let now = nowNs()
        if now >= target { return }
        let rest = target - now
        if rest > 1_500_000 { Thread.sleep(forTimeInterval: Double(rest - 1_000_000) / 1e9) }
    }
}

/// M2: capacity and encode latency of one (main only) versus two (main + aux) concurrent hardware HEVC sessions fed by
/// the Metal packer, unpaced (as fast as the sessions take frames) and paced at a stream fps, newest-frame-wins like
/// the host (a session with `maxInFlight` = 2 frames queued drops the new frame).
func runEncodeBench(_ args: ProbeArgs) throws {
    let seconds = args.double("seconds", 8)
    let warmup = 1.0
    let content = args.string("content", "scroll")
    let chroma = parseChromas(args.string("main-chroma", "box"))[0]
    let mainMbps = args.double("main-mbps", 40)
    let auxRatio = args.double("aux-ratio", 0.5)
    var runs: [(views: Int, pace: Int)] = [(1, 0), (2, 0), (1, 60), (2, 60), (1, 120), (2, 120)]
    if !args.flag("matrix") {
        runs = [(args.string("views", "both") == "main" ? 1 : 2, args.int("pace", 60))]
    }
    for size in parseSizes(args) {
        let scene = Scene(frames: 600)
        let ring = try renderRing(scene, size: size, from: contentStart(content, frames: 600), count: args.int("ring", 32))
        let rates = ClipNaming.bitrates(size: size, mainMbps: mainMbps, auxRatio: auxRatio)
        line("== encode-bench \(size) content=\(content) main=\(rates.mainKbps)k aux=\(rates.auxKbps)k main-chroma=\(chroma.rawValue) "
            + "window=\(seconds)s (+\(warmup)s warm-up) maxInFlight=2 per session")
        for run in runs {
            line(try benchOnce(size: size, ring: ring, views: run.views, pace: run.pace, seconds: seconds, warmup: warmup,
                               chroma: chroma, mainKbps: rates.mainKbps, auxKbps: rates.auxKbps))
        }
    }
}

private final class Tracker: @unchecked Sendable {
    private let lock = NSLock()
    let capacity = 40_000
    var tickStart: [UInt64]
    var submit: [[UInt64]]       // [view][tick]
    var done: [[UInt64]]
    var bytes: [[Int]]
    init() {
        tickStart = [UInt64](repeating: 0, count: capacity)
        submit = [[UInt64]](repeating: [UInt64](repeating: 0, count: capacity), count: 2)
        done = submit
        bytes = [[Int]](repeating: [Int](repeating: 0, count: capacity), count: 2)
    }
    func finish(view: Int, tick: Int, bytes b: Int) {
        lock.withLock { done[view][tick] = nowNs(); bytes[view][tick] = b }
    }
}

private func benchOnce(size: FrameSize, ring: [CVPixelBuffer], views: Int, pace: Int, seconds: Double, warmup: Double,
                       chroma: MainChroma, mainKbps: Int, auxKbps: Int) throws -> String {
    let packer = try Packer444(width: size.width, height: size.height, mainChroma: chroma, includeAux: views == 2)
    let fpsForRate = pace > 0 ? pace : 60
    let streams = try [
        VTStream(.init(width: size.width, height: size.height, fps: fpsForRate, bitrateKbps: mainKbps)),
        views == 2 ? try VTStream(.init(width: size.width, height: size.height, fps: fpsForRate, bitrateKbps: auxKbps)) : nil,
    ]
    let slots = [DispatchSemaphore(value: 2), DispatchSemaphore(value: 2)]
    let tracker = Tracker()
    var drops = [0, 0]
    var packGpu: [Double] = [], packWall: [Double] = []
    var late = 0
    let period = pace > 0 ? 1e9 / Double(pace) : 0
    let t0 = nowNs()
    let measureFrom = t0 + UInt64(warmup * 1e9)
    let end = measureFrom + UInt64(seconds * 1e9)
    var tick = 0
    while nowNs() < end, tick < tracker.capacity {
        if period > 0 {
            let target = t0 + UInt64(Double(tick) * period)
            waitUntil(target)
            if nowNs() > target + 2_000_000 { late += 1 }
        }
        let start = nowNs()
        tracker.tickStart[tick] = start
        let r = try packer.pack(ring[pingPong(tick, ring.count)])
        let measuring = start >= measureFrom
        if measuring { packGpu.append(Double(r.gpuUs)); packWall.append(Double(r.wallUs)) }
        for v in 0..<views {
            guard let stream = streams[v] else { continue }
            let pb = v == 0 ? r.main : r.aux!
            let ok = pace > 0 ? slots[v].wait(timeout: .now()) == .success : { slots[v].wait(); return true }()
            if !ok { if measuring { drops[v] += 1 }; continue }
            let t = tick
            tracker.submit[v][t] = nowNs()
            let accepted = stream.encode(pb, index: t, forceKey: false) { out in
                tracker.finish(view: v, tick: t, bytes: out?.bytes ?? 0)
                slots[v].signal()
            }
            if !accepted { slots[v].signal() }
        }
        tick += 1
    }
    for s in streams { s?.finish() }
    let elapsed = Double(nowNs() - measureFrom) / 1e9
    var viewLat: [[Double]] = [[], []], pairLat: [Double] = []
    var doneCount = [0, 0], viewBytes = [0, 0], submitted = 0
    for t in 0..<tick where tracker.tickStart[t] >= measureFrom {
        var pairMax: UInt64 = 0
        var both = true
        for v in 0..<views {
            let d = tracker.done[v][t]
            guard d != 0 else { both = false; continue }
            doneCount[v] += 1
            viewBytes[v] += tracker.bytes[v][t]
            viewLat[v].append(Double(d - tracker.submit[v][t]) / 1e6)
            pairMax = max(pairMax, d)
        }
        if both { submitted += 1; pairLat.append(Double(pairMax - tracker.tickStart[t]) / 1e6) }
    }
    func rate(_ n: Int) -> String { String(format: "%.1f", Double(n) / elapsed) }
    func mb(_ b: Int) -> String { String(format: "%.1f", Double(b) * 8 / elapsed / 1e6) }
    var text = String(format: "views=%d pace=%3d fps | done/s main=%@", views, pace, rate(doneCount[0]))
    if views == 2 { text += " aux=\(rate(doneCount[1])) pairs=\(rate(submitted))" }
    text += " | dropped main=\(drops[0])"
    if views == 2 { text += " aux=\(drops[1])" }
    if pace > 0 { text += " late=\(late)" }
    text += " | pack gpu_us \(Metrics.summary(packGpu)) wall_us \(Metrics.summary(packWall))"
    text += " | enc_main_ms \(Metrics.summary(viewLat[0]))"
    if views == 2 { text += " enc_aux_ms \(Metrics.summary(viewLat[1])) pair_ms(incl. pack) \(Metrics.summary(pairLat))" }
    text += " | Mbps main=\(mb(viewBytes[0]))"
    if views == 2 { text += " aux=\(mb(viewBytes[1]))" }
    text += " thermal=\(thermalNote())"
    return text
}
