import AppKit
import ApplicationServices
import Foundation
import PenInjection

let usage = """
usage: pen-sink-probe pen-view
       pen-sink-probe inject [--pattern ramp|circle|tilt] [--x N --y N --w N --h N] [--repeat N]
  pen-view  opens a window that shows every NSEvent's pen fields and draws pressure-width lines.
  inject    posts synthetic pen events (needs Accessibility). Default rect: centered on the main display, 800x300.
"""

func fail(_ msg: String, code: Int32 = 2) -> Never {
    FileHandle.standardError.write(Data((msg + "\n").utf8))
    exit(code)
}

let args = Array(CommandLine.arguments.dropFirst())
guard let mode = args.first else { fail(usage) }

switch mode {
case "pen-view":
    MainActor.assumeIsolated { runPenView() }
case "inject":
    runInject(Array(args.dropFirst()))
default:
    fail(usage)
}

// MARK: - pen-view

@MainActor
final class PenView: NSView {
    private var lines: [String] = []
    private var strokes: [[(CGPoint, CGFloat)]] = []
    private var current: [(CGPoint, CGFloat)] = []
    private var inProximity = false

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for a in trackingAreas { removeTrackingArea(a) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }

    private func log(_ s: String) {
        lines.append(s)
        if lines.count > 18 { lines.removeFirst(lines.count - 18) }
        needsDisplay = true
    }

    private func describe(_ e: NSEvent) -> String {
        let name: String
        switch e.type {
        case .leftMouseDown: name = "leftMouseDown"
        case .leftMouseUp: name = "leftMouseUp"
        case .leftMouseDragged: name = "leftMouseDragged"
        case .mouseMoved: name = "mouseMoved"
        case .tabletPoint: name = "tabletPoint"
        case .tabletProximity: name = "tabletProximity"
        default: name = "type\(e.type.rawValue)"
        }
        if e.type == .tabletProximity {
            return "\(name) enter=\(e.isEnteringProximity) pointerType=\(e.pointingDeviceType.rawValue) deviceID=\(e.deviceID) vendor=\(e.vendorID)"
        }
        let sub = e.subtype.rawValue
        return String(format: "%@ sub=%d p=%.3f tilt=(%.2f,%.2f) rot=%.1f dev=%d", name, sub, e.pressure, e.tilt.x, e.tilt.y, e.rotation, e.deviceID)
    }

    private func handle(_ e: NSEvent) {
        log(describe(e))
        let p = convert(e.locationInWindow, from: nil)
        let w = CGFloat(e.pressure) * 14
        switch e.type {
        case .leftMouseDown: current = [(p, w)]
        case .leftMouseDragged:
            current.append((p, w))
            if current.count > 5000 { current.removeFirst(current.count - 5000) }
        case .leftMouseUp:
            current.append((p, w))
            strokes.append(current); current = []
            if strokes.count > 50 { strokes.removeFirst(strokes.count - 50) }
        default: break
        }
        needsDisplay = true
    }

    override func mouseDown(with e: NSEvent) { handle(e) }
    override func mouseDragged(with e: NSEvent) { handle(e) }
    override func mouseUp(with e: NSEvent) { handle(e) }
    override func mouseMoved(with e: NSEvent) { handle(e) }
    override func tabletPoint(with e: NSEvent) { log(describe(e)) }
    override func tabletProximity(with e: NSEvent) {
        inProximity = e.isEnteringProximity
        log(describe(e))
    }
    override func keyDown(with e: NSEvent) {
        if e.keyCode == 8 { strokes = []; current = []; needsDisplay = true }  // 'c' clears
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill(); dirtyRect.fill()
        for s in strokes + [current] where s.count > 1 {
            for i in 1..<s.count {
                let path = NSBezierPath()
                path.lineCapStyle = .round
                path.lineWidth = max(0.5, (s[i].1 + s[i - 1].1) / 2)
                path.move(to: s[i - 1].0); path.line(to: s[i].0)
                NSColor.labelColor.setStroke(); path.stroke()
            }
        }
        let header = "proximity: \(inProximity ? "IN" : "out")   (press 'c' to clear)"
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
                                                    .foregroundColor: NSColor.secondaryLabelColor]
        (header + "\n" + lines.joined(separator: "\n")).draw(at: NSPoint(x: 8, y: 8), withAttributes: attrs)
    }
}

@MainActor
func runPenView() {
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    let screen = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    let size = NSSize(width: 1000, height: 600)
    let frame = NSRect(x: screen.midX - size.width / 2, y: screen.midY - size.height / 2, width: size.width, height: size.height)
    let win = NSWindow(contentRect: frame, styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    win.title = "pen-sink-probe"
    let view = PenView(frame: NSRect(origin: .zero, size: size))
    win.contentView = view
    win.acceptsMouseMovedEvents = true
    win.makeKeyAndOrderFront(nil)
    win.makeFirstResponder(view)
    app.activate()
    app.run()
}

// MARK: - inject

func runInject(_ a: [String]) {
    var pattern = PenPattern.ramp
    var rect: [String: Double] = [:]
    var repeats = 1
    var i = 0
    while i < a.count {
        guard i + 1 < a.count else { fail("missing value for \(a[i])\n\(usage)") }
        let v = a[i + 1]
        switch a[i] {
        case "--pattern":
            guard let p = PenPattern(rawValue: v) else { fail("unknown pattern '\(v)'\n\(usage)") }
            pattern = p
        case "--x", "--y", "--w", "--h":
            guard let d = Double(v) else { fail("bad number '\(v)'") }
            rect[String(a[i].dropFirst(2))] = d
        case "--repeat":
            guard let n = Int(v), n > 0 else { fail("bad --repeat '\(v)'") }
            repeats = n
        default: fail("unknown option \(a[i])\n\(usage)")
        }
        i += 2
    }

    // Detect Accessibility without triggering the system prompt.
    guard AXIsProcessTrusted() else {
        fail("""
        Accessibility permission is missing, so events cannot be posted.
        Grant it to the terminal app running this command in System Settings > Privacy & Security > Accessibility, then re-run.
        """, code: 3)
    }

    let bounds = CGDisplayBounds(CGMainDisplayID())
    let w = rect["w"] ?? 800, h = rect["h"] ?? 300
    let ox = rect["x"] ?? (bounds.midX - w / 2), oy = rect["y"] ?? (bounds.midY - h / 2)
    let session = PenSession()
    let pat = pattern, reps = repeats

    // SIGINT/SIGTERM/SIGHUP/SIGQUIT: cancel() takes the same lock as the worker's posts, so release happens
    // from the true state and the worker can no longer post afterwards.
    let signals = [SIGINT, SIGTERM, SIGHUP, SIGQUIT]
    for sig in signals { signal(sig, SIG_IGN) }
    let sources = signals.map { sig -> DispatchSourceSignal in
        let s = DispatchSource.makeSignalSource(signal: sig, queue: .main)
        s.setEventHandler { session.cancel(); exit(130) }
        s.resume()
        return s
    }

    let worker = Thread {
        do {
            guard try session.setProximity(true) else { return }
            usleep(50_000)
            outer: for _ in 0..<reps {
                let samples = pat.strokeSamples(originX: ox, originY: oy, width: w, height: h)
                // A few hover moves first so the app sees the pen approach.
                let first = samples[0]
                for _ in 0..<5 {
                    let hover = PenSample(x: first.x, y: first.y, pressure: 0, tiltX: first.tiltX, tiltY: first.tiltY, phase: .move)
                    guard try session.send(hover) else { break outer }
                    usleep(8_000)
                }
                for s in samples {
                    guard try session.send(s) else { break outer }
                    usleep(8_000)
                }
                usleep(100_000)
            }
        } catch {
            FileHandle.standardError.write(Data("inject failed: \(error)\n".utf8))
        }
        session.release()
        exit(0)
    }
    worker.start()
    // dispatchMain() never returns; withExtendedLifetime keeps the signal sources alive for the process.
    withExtendedLifetime(sources) { dispatchMain() }
}
