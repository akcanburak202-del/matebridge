import CoreGraphics
import Foundation
import ProbeCore

final class StopFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.lock(); value = true; lock.unlock() }
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
}

func modes(of id: CGDirectDisplayID) -> [(CGDisplayMode, DisplayModeInfo)] {
    let opts = [kCGDisplayShowDuplicateLowResolutionModes as String: true] as CFDictionary
    let list = (CGDisplayCopyAllDisplayModes(id, opts) as? [CGDisplayMode]) ?? []
    return list.map { m in
        (m, DisplayModeInfo(width: m.width, height: m.height, pixelWidth: m.pixelWidth,
                            pixelHeight: m.pixelHeight, refreshRate: m.refreshRate))
    }
}

func run() async -> Int32 {
    let options: ProbeOptions
    do { options = try ProbeOptions.parse(Array(CommandLine.arguments.dropFirst())) } catch {
        FileHandle.standardError.write(Data("error: \(error)\n\(ProbeOptions.usage)\n".utf8))
        return 64
    }

    guard CGPreflightScreenCaptureAccess() else {
        FileHandle.standardError.write(Data("""
        error: Screen Recording permission is not granted for this process.
        Grant it in System Settings > Privacy & Security > Screen & System Audio Recording
        (for the terminal app running this tool), then re-run.

        """.utf8))
        return 77
    }

    let stop = StopFlag()
    signal(SIGINT, SIG_IGN); signal(SIGTERM, SIG_IGN); signal(SIGHUP, SIG_IGN)
    let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
    let sigterm = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
    let sighup = DispatchSource.makeSignalSource(signal: SIGHUP, queue: .global())
    sigint.setEventHandler { stop.set() }
    sigterm.setEventHandler { stop.set() }
    sighup.setEventHandler { stop.set() }
    sigint.resume(); sigterm.resume(); sighup.resume()

    let vd: VirtualDisplay
    do {
        vd = try VirtualDisplay(name: "MateBridge Probe", pixelWidth: options.width,
                                pixelHeight: options.height, hidpi: options.hidpi)
    } catch {
        FileHandle.standardError.write(Data("error: cannot create virtual display: \(error)\n".utf8))
        return 1
    }
    defer { vd.invalidate() }
    try? await Task.sleep(for: .seconds(1)) // let WindowServer register the display
    if stop.isSet { print("interrupted; removing virtual display"); return 130 }

    let id = vd.displayID
    print("virtual display created: id=\(id)")
    print("active displays:")
    var count: UInt32 = 0
    var ids = [CGDirectDisplayID](repeating: 0, count: 16)
    CGGetActiveDisplayList(16, &ids, &count)
    for d in ids.prefix(Int(count)) {
        let mark = d == id ? " <- virtual" : ""
        let b = CGDisplayBounds(d)
        print("  id=\(d) pixels=\(CGDisplayPixelsWide(d))x\(CGDisplayPixelsHigh(d)) points=\(Int(b.width))x\(Int(b.height))\(mark)")
    }

    let all = modes(of: id)
    print("available modes (points / pixels @Hz):")
    for (_, i) in all {
        print("  \(i.width)x\(i.height) / \(i.pixelWidth)x\(i.pixelHeight) @\(i.refreshRate)\(i.isHiDPI ? " HiDPI" : "")")
    }
    if let want = ModeSelector.select(from: all.map(\.1), pixelWidth: options.width,
                                      pixelHeight: options.height, hidpi: options.hidpi),
       let cg = all.first(where: { $0.1 == want })?.0 {
        let r = CGDisplaySetDisplayMode(id, cg, nil)
        print("selected mode: \(want.width)x\(want.height) pt / \(want.pixelWidth)x\(want.pixelHeight) px @\(want.refreshRate) (setMode=\(r == .success ? "ok" : "error \(r.rawValue)"))")
    } else {
        print("selected mode: none matched \(options.width)x\(options.height) hidpi=\(options.hidpi); keeping default")
    }

    try? FileManager.default.createDirectory(atPath: "out", withIntermediateDirectories: true)
    if stop.isSet { return 130 }
    let capture = DisplayCapture(outputURL: URL(fileURLWithPath: "out/first-frame.png"))
    do {
        try await capture.start(displayID: id, pixelWidth: options.width, pixelHeight: options.height)
        if stop.isSet { await capture.stop(); print("interrupted; removing virtual display"); return 130 }
    } catch {
        FileHandle.standardError.write(Data("error: capture failed: \(error)\n".utf8))
        return 1
    }

    let start = ProcessInfo.processInfo.systemUptime
    let deadline = start + Double(options.seconds)
    var windowStart = start
    var windowIndex = 1
    print("capturing for \(options.seconds)s (10s windows; keep the display idle in window 1, move a window on it afterwards)")
    while !stop.isSet {
        try? await Task.sleep(for: .milliseconds(200))
        let now = ProcessInfo.processInfo.systemUptime
        if now - windowStart >= 10 || now >= deadline {
            let n = capture.takeWindowCount()
            let dt = now - windowStart
            print(String(format: "window %d: %d frames in %.1fs = %.1f fps", windowIndex, n, dt, FrameCounter.fps(frames: n, seconds: dt)))
            windowIndex += 1; windowStart = now
        }
        if now >= deadline { break }
    }
    await capture.stop()
    print("total frames: \(capture.totalFrames); removing virtual display")
    return 0
}

exit(await run())
