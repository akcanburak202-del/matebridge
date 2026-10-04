import AppKit
import CoreGraphics
import Foundation
import HDRProbeCore

// T-226 HDR feasibility probe. See ../../README.md for exact run instructions and what each command touches.
//
//   inspect                      read-only: runtime selectors, screens' EDR, VT capabilities, SCK presets
//   vd [options]                 CREATES A VIRTUAL DISPLAY (needs user approval; run by the orchestrator)
//   encode [options]             uses the hardware encoder (never while a MateBridge stream is live)

let args = ProbeArgs(Array(CommandLine.arguments.dropFirst()))

func usage() {
    print("""
    usage:
      hdr-probe inspect
      hdr-probe vd [--tf N | --sweep] [--reference] [--p3] [--size 1920x1080] [--hz 60]
                   [--capture sdr|local|canonical|recording] [--capture-seconds 3] [--hold 0]
      hdr-probe encode [--path fast|llrc] [--transfer pq|hlg] [--fps 120] [--seconds 5] [--size 2800x1840]
                       [--bitrate-kbps 30000] [--out clip.mp4]
    """)
}

/// Creates one display, reports what macOS thinks of it, optionally captures, then removes it.
func probeDisplay(tf: UInt32?, serial: UInt32) async {
    let (w, h) = args.size("size", (1920, 1080))
    let req = VirtualDisplayRequest(pixelWidth: w, pixelHeight: h, refreshRate: args.double("hz", 60), transferFunction: tf,
                                    isReference: args.flag("reference"), p3Primaries: args.flag("p3"), serial: serial)
    print("== vd transferFunction=\(tf.map(String.init) ?? "none (3-arg init)") reference=\(req.isReference) "
          + "p3=\(req.p3Primaries) \(w)x\(h)@\(Int(req.refreshRate))")
    let display: HDRVirtualDisplay
    do {
        display = try await MainActor.run { try HDRVirtualDisplay(req) }
    } catch {
        print("  create failed: \(error)")
        return
    }
    print("  displayID=\(display.displayID)")
    // The window server publishes the new screen asynchronously; NSScreen updates on the main run loop.
    try? await Task.sleep(nanoseconds: 3_000_000_000)
    await MainActor.run { Inspect.screens(only: display.displayID) }
    let opts = [kCGDisplayShowDuplicateLowResolutionModes as String: true] as CFDictionary
    for m in (CGDisplayCopyAllDisplayModes(display.displayID, opts) as? [CGDisplayMode]) ?? [] {
        print("  mode \(m.pixelWidth)x\(m.pixelHeight)@\(Int(m.refreshRate.rounded())) ioFlags=0x\(String(m.ioFlags, radix: 16)) "
              + "usable=\(m.isUsableForDesktopGUI())")
    }

    if let preset = args.options["capture"] {
        let lines = (try? await HDRCapture().run(displayID: display.displayID, preset: preset, width: w, height: h,
                                                 seconds: args.double("capture-seconds", 3))) ?? ["capture threw"]
        lines.forEach { print("  \($0)") }
    }
    let hold = args.double("hold", 0)
    if hold > 0 {
        print("  holding \(Int(hold)) s: move HDR content (e.g. an HDR video or the game) onto display \(display.displayID) now")
        try? await Task.sleep(nanoseconds: UInt64(hold * 1e9))
        await MainActor.run { Inspect.screens(only: display.displayID) }
        if let preset = args.options["capture"] {
            let lines = (try? await HDRCapture().run(displayID: display.displayID, preset: preset, width: w, height: h,
                                                     seconds: args.double("capture-seconds", 3))) ?? ["capture threw"]
            lines.forEach { print("  (after hold) \($0)") }
        }
    }
    await MainActor.run { display.invalidate() }
    // Same gap the product keeps before re-creating a display (DisplayRecreateGap).
    try? await Task.sleep(nanoseconds: 3_000_000_000)
    print("  removed")
}

switch args.command {
case "inspect":
    Inspect.runtime()
    print("== Screens")
    Inspect.screens()
    Inspect.encoder()
    Inspect.capturePresets()

case "vd":
    // An NSApplication is needed so NSScreen sees the new display. It stays invisible: no window, no Dock icon.
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)
    Task {
        print("== Screens before")
        await MainActor.run { Inspect.screens() }
        if args.flag("sweep") {
            var serial: UInt32 = 0x2260
            for tf in [nil, 0, 1, 2, 3, 4] as [UInt32?] {
                await probeDisplay(tf: tf, serial: serial)
                serial += 1
            }
        } else {
            await probeDisplay(tf: args.options["tf"].flatMap(UInt32.init), serial: 0x2260)
        }
        print("== Screens after")
        await MainActor.run { Inspect.screens() }
        exit(0)
    }
    app.run()

case "encode":
    let (w, h) = args.size("size", (2800, 1840))
    let cfg = HDRBench.Config(width: w, height: h, fps: args.int("fps", 120), seconds: args.double("seconds", 5),
                              path: args.options["path"] ?? "fast", transfer: args.options["transfer"] ?? "pq",
                              bitrateKbps: args.int("bitrate-kbps", 30_000), out: args.options["out"])
    do {
        try HDRBench(cfg).run().forEach { print($0) }
    } catch {
        print("encode failed: \(error)")
        exit(1)
    }

default:
    usage()
}
