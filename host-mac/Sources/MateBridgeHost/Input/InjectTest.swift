import Foundation
import MateBridgeCore

/// `MateBridgeApp --inject-test`: injects protocol input into the MateBridge virtual display through the REAL input
/// path (`InputController`: state machine, planner, gating, `CGEventPoster`), so the orchestrator can watch it land in
/// Krita or any other app on that display. It posts real events. Never run it unattended, and never from a test.
///
///     MateBridgeApp --inject-test --fixture pen_hover_to_contact [--fixture pen_leave ...]
///     MateBridgeApp --inject-test --stroke ramp|circle|tilt [--repeat N]
///     MateBridgeApp --inject-test --tap 2            (touch taps at the display center; 2 = double click)
///     MateBridgeApp --inject-test --scroll           (one precise scroll gesture at the display center, finger moving down)
///     MateBridgeApp --inject-test --pinch in|out     (one magnify gesture at the display center: BEGAN, 20 CHANGED, ENDED)
///     MateBridgeApp --inject-test --wheel 5          (5 mouse-wheel steps at the display center)
///     MateBridgeApp --inject-test --keys "cmd+a,tab"  (keyboard combos, see below; goes to the focused app)
///
/// `--keys` takes comma-separated combos of `+`-joined names. Modifiers are named by the Mac key they should produce
/// through the default mapping of decision 0008 (`cmd` is sent as the PC Ctrl key, `opt`/`alt` as PC Alt, `ctrl` as PC
/// Meta, `shift`); the rest are letters, digits, `enter`, `tab`, `space`, `esc`, `backspace`, `delete`, `left`, `right`,
/// `up`, `down`, `home`, `end`, `pageup`, `pagedown`, `f1`...`f12`, `grave` (evdev 41), `iso102` (evdev 86) and the
/// punctuation names `minus`, `equal`, `lbracket`, `rbracket`, `semicolon`, `quote`, `backslash`, `comma`, `period`,
/// `slash`. Each combo presses its modifiers, then its key, holds it (`--key-hold MS`, default 60; more than the
/// repeat delay shows auto-repeat), then releases in reverse. `capslock` alone toggles the Mac's Caps Lock.
///
/// Options: `--countdown S` (default 5: time to bring the target window to the virtual display),
/// `--create-display` (make a virtual display when none exists; conflicts with a running host, which owns the fixed
/// serial), `--fixtures-dir DIR` (default: found by walking up from the working directory or the executable).
///
/// It needs the Accessibility permission for the process that runs it and a virtual display: start MateBridge and
/// connect the tablet, or pass `--create-display`. Ctrl-C releases everything before exiting.
public enum InjectTest {
    public struct Options: Sendable {
        public var fixtures: [String] = []
        public var stroke: String?
        public var taps = 0
        public var scrollGesture = false
        /// "in" (fingers closing, zoom out) or "out" (fingers spreading, zoom in).
        public var pinch: String?
        public var wheelSteps = 0
        public var keys: String?
        public var keyHoldMs = 60
        public var repeats = 1
        public var countdown: Double = 5
        public var createDisplay = false
        public var fixturesDirectory: String?
    }

    public struct ParseError: Error, Sendable { public let message: String }

    public static let usage = """
        usage: MateBridgeApp --inject-test [--fixture NAME]... [--stroke ramp|circle|tilt] [--tap N]
                             [--scroll] [--pinch in|out] [--wheel N] [--keys COMBOS] [--key-hold MS] [--repeat N] [--countdown S] [--create-display] [--fixtures-dir DIR]
        """

    /// nil when `--inject-test` is absent. Any argument it does not know, or a stray value, is an error.
    public static func parse(_ args: [String]) -> Result<Options, ParseError>? {
        guard args.contains("--inject-test") else { return nil }
        var o = Options()
        var i = 1  // argv[0] is the executable
        func fail(_ text: String) -> Result<Options, ParseError> { .failure(ParseError(message: text + "\n" + usage)) }
        while i < args.count {
            let flag = args[i]
            func value() -> String? { i + 1 < args.count && !args[i + 1].hasPrefix("--") ? args[i + 1] : nil }
            switch flag {
            case "--fixture":
                guard let v = value() else { return fail("--fixture needs a fixture name") }
                o.fixtures.append(v); i += 1
            case "--stroke":
                guard let v = value(), ["ramp", "circle", "tilt"].contains(v) else { return fail("--stroke needs ramp, circle or tilt") }
                o.stroke = v; i += 1
            case "--tap":
                guard let v = value(), let n = Int(v), (1...5).contains(n) else { return fail("--tap needs 1...5") }
                o.taps = n; i += 1
            case "--scroll": o.scrollGesture = true
            case "--pinch":
                guard let v = value(), ["in", "out"].contains(v) else { return fail("--pinch needs in or out") }
                o.pinch = v; i += 1
            case "--wheel":
                guard let v = value(), let n = Int(v), (1...50).contains(n) else { return fail("--wheel needs 1...50") }
                o.wheelSteps = n; i += 1
            case "--keys":
                guard let v = value(), (try? keyScript(v, holdMs: 60)) != nil else {
                    return fail("--keys needs combos like \"cmd+a,tab\" made of known key names")
                }
                o.keys = v; i += 1
            case "--key-hold":
                guard let v = value(), let n = Int(v), (10...10_000).contains(n) else { return fail("--key-hold needs 10...10000 ms") }
                o.keyHoldMs = n; i += 1
            case "--repeat":
                guard let v = value(), let n = Int(v), (1...20).contains(n) else { return fail("--repeat needs 1...20") }
                o.repeats = n; i += 1
            case "--countdown":
                guard let v = value(), let s = Double(v), (0...60).contains(s) else { return fail("--countdown needs 0...60 seconds") }
                o.countdown = s; i += 1
            case "--inject-test": break
            case "--create-display": o.createDisplay = true
            case "--fixtures-dir":
                guard let v = value() else { return fail("--fixtures-dir needs a directory") }
                o.fixturesDirectory = v; i += 1
            default:
                // A typo must not silently inject something else, or nothing at all: this posts real input.
                return fail("unknown argument \(flag)")
            }
            i += 1
        }
        if o.fixtures.isEmpty && o.stroke == nil && o.taps == 0 && !o.scrollGesture && o.pinch == nil && o.wheelSteps == 0 && o.keys == nil {
            return fail("nothing to inject")
        }
        return .success(o)
    }

    // MARK: Script

    private struct Step {
        var delayMs: Int
        /// nil is a pause.
        var message: Message?
    }

    /// Blocking; returns the process exit code. Run it off the main thread.
    public static func run(_ o: Options) -> Int32 {
        guard SystemAccessibility().isTrusted() else {
            print("error: this process has no Accessibility permission (System Settings > Privacy & Security > Accessibility).")
            return 3
        }
        var script: [Step] = []
        do { script = try buildScript(o) } catch {
            print("error: \(error)")
            return 2
        }

        let locator = VirtualDisplayLocator()
        var created: VirtualDisplay?
        var geometry = locator.geometry()
        if geometry == nil {
            guard o.createDisplay else {
                print("error: no MateBridge virtual display found. Start MateBridge and connect the tablet, or pass --create-display.")
                return 4
            }
            do {
                created = try VirtualDisplay(name: "MateBridge", pixelWidth: 2800, pixelHeight: 1840, hidpi: true)
            } catch {
                print("error: cannot create the virtual display: \(error)")
                return 4
            }
            for _ in 0..<50 where geometry == nil {
                Thread.sleep(forTimeInterval: 0.1)
                geometry = locator.geometry()
            }
        }
        guard let geometry else {
            print("error: the virtual display was created but not found by vendor/product (see VirtualDisplayLocator).")
            return 4
        }
        print("virtual display: \(Int(geometry.widthPt))x\(Int(geometry.heightPt)) pt, scale \(geometry.scale), origin (\(Int(geometry.originX)), \(Int(geometry.originY)))")

        if o.countdown > 0 {
            print("bring the target window (e.g. Krita canvas) to the virtual display; starting in \(Int(o.countdown)) s ...")
            var left = o.countdown
            while left > 0 {
                Thread.sleep(forTimeInterval: min(1, left))
                left -= 1
            }
        }

        let controller = InputController()
        controller.start { _ in }
        controller.sessionStarted(sessionID: 1, configID: 1)

        // Ctrl-C and kill release everything first: a pen left down would drag on in the target app.
        let signalQueue = DispatchQueue(label: "dev.matebridge.injecttest.signal")
        var signalSources: [DispatchSourceSignal] = []
        for sig in [SIGINT, SIGTERM, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: signalQueue)
            source.setEventHandler {
                controller.releaseInput(.shutdown)
                controller.sessionEnded()
                controller.shutdown()
                print("interrupted: input released")
                exit(130)
            }
            source.resume()
            signalSources.append(source)
        }

        var sent = 0
        for _ in 0..<o.repeats {
            for step in script {
                if step.delayMs > 0 { Thread.sleep(forTimeInterval: Double(step.delayMs) / 1000) }
                if let message = step.message {
                    controller.deliver(message)
                    sent += 1
                }
            }
        }

        // Whatever the script left held (a hovering pen, an open scroll) is released, as a real disconnect would.
        controller.releaseInput(.shutdown)
        controller.sessionEnded()
        controller.shutdown()
        withExtendedLifetime(created) {}  // the display lives until here
        signalSources.forEach { $0.cancel() }
        print("done: \(sent) messages injected, input released")
        return 0
    }

    // MARK: Building the script

    private struct ScriptError: Error, CustomStringConvertible {
        let description: String
    }

    private static func buildScript(_ o: Options) throws -> [Step] {
        var script: [Step] = []
        if !o.fixtures.isEmpty {
            let dir = try fixturesDirectory(o)
            for name in o.fixtures {
                for message in try loadFixture(name, in: dir) { script.append(Step(delayMs: 10, message: message)) }
                script.append(Step(delayMs: 300, message: nil))
            }
        }
        if let stroke = o.stroke {
            script += strokeScript(stroke)
        }
        if o.taps > 0 {
            script += tapScript(o.taps, afterPen: o.stroke != nil || !o.fixtures.isEmpty)
        }
        if o.scrollGesture { script += scrollScript() }
        if let pinch = o.pinch { script += pinchScript(spreading: pinch == "out") }
        if o.wheelSteps > 0 { script += wheelScript(o.wheelSteps) }
        if let keys = o.keys { script += try keyScript(keys, holdMs: o.keyHoldMs) }
        return script
    }

    private static func fixturesDirectory(_ o: Options) throws -> URL {
        if let d = o.fixturesDirectory { return URL(fileURLWithPath: (d as NSString).expandingTildeInPath) }
        let starts = [FileManager.default.currentDirectoryPath, CommandLine.arguments.first ?? ""]
        for start in starts where !start.isEmpty {
            var url = URL(fileURLWithPath: start)
            for _ in 0..<10 {
                let candidate = url.appendingPathComponent("protocol/fixtures")
                if FileManager.default.fileExists(atPath: candidate.appendingPathComponent("gen.py").path) { return candidate }
                url.deleteLastPathComponent()
            }
        }
        throw ScriptError(description: "protocol/fixtures not found; pass --fixtures-dir")
    }

    /// `.hex` fixtures: `#` comments and whitespace are stripped, the rest is hex.
    private static func loadFixture(_ name: String, in dir: URL) throws -> [Message] {
        let url = dir.appendingPathComponent(name + ".hex")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw ScriptError(description: "cannot read fixture \(name) in \(dir.path)")
        }
        var digits = ""
        for line in text.split(whereSeparator: \.isNewline) {
            digits += line.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0].filter { !$0.isWhitespace }
        }
        guard digits.count % 2 == 0 else { throw ScriptError(description: "fixture \(name): odd number of hex digits") }
        var bytes: [UInt8] = []
        var index = digits.startIndex
        while index < digits.endIndex {
            let next = digits.index(index, offsetBy: 2)
            guard let byte = UInt8(digits[index..<next], radix: 16) else { throw ScriptError(description: "fixture \(name): bad hex") }
            bytes.append(byte)
            index = next
        }
        var decoder = FrameDecoder(connection: .control)
        decoder.append(bytes)
        var messages: [Message] = []
        do {
            while let m = try decoder.nextMessage() { messages.append(m) }
        } catch {
            throw ScriptError(description: "fixture \(name) does not decode: \(error)")
        }
        return messages
    }

    /// A protocol-level pen gesture: hover in, one stroke of pressure/tilt, lift, hover, leave. Three samples per
    /// message every 9 ms (about the tablet's 330 Hz), in the region between 25% and 75% of the display.
    private static func strokeScript(_ pattern: String) -> [Step] {
        func sample(_ x: Double, _ y: Double, pressure: Double = 0, tiltX: Double = 0, tiltY: Double = 0,
                    _ flags: PenFlags) -> PenSample {
            PenSample(dtUs: 0, x: NormalizedCoord.encode(px: x, surface: 1), y: NormalizedCoord.encode(px: y, surface: 1),
                      pressure: PressureCodec.encode(pressure), tiltX: TiltCodec.encode(tiltX),
                      tiltY: TiltCodec.encode(tiltY), flags: flags)
        }
        var samples: [PenSample] = []
        let count = 150
        func position(_ t: Double) -> (Double, Double) {
            switch pattern {
            case "circle":
                let a = 2 * Double.pi * t
                return (0.5 + 0.13 * cos(a), 0.5 + 0.2 * sin(a))
            default:
                return (0.25 + 0.5 * t, 0.5)
            }
        }
        let start = position(0)
        for i in 0..<12 {  // approach, hovering
            let f = Double(i) / 11
            samples.append(sample(start.0 - 0.05 * (1 - f), start.1, .inRange))
        }
        var last = start
        for i in 0..<count {
            let t = Double(i) / Double(count - 1)
            let (x, y) = position(t)
            let pressure: Double, tiltX: Double, tiltY: Double
            switch pattern {
            case "circle":
                pressure = 0.3 + 0.7 * (0.5 - 0.5 * cos(2 * Double.pi * t)); tiltX = 0; tiltY = 0
            case "tilt":
                pressure = 0.6; tiltX = -1 + 2 * t; tiltY = 1 - 2 * t
            default:  // ramp
                pressure = 1 - abs(2 * t - 1); tiltX = 0; tiltY = 0
            }
            let flags: PenFlags = i == 0 ? [.inRange, .contact, .strokeStart] : [.inRange, .contact]
            samples.append(sample(x, y, pressure: max(pressure, 0.02), tiltX: tiltX, tiltY: tiltY, flags))
            last = (x, y)
        }
        for _ in 0..<6 { samples.append(sample(last.0, last.1, .inRange)) }  // lifted, still hovering
        samples.append(sample(last.0, last.1, []))  // out of range

        var script: [Step] = []
        var index = 0
        var timeUs: UInt64 = 1_000_000
        while index < samples.count {
            var batch = Array(samples[index..<min(index + 3, samples.count)])
            for k in batch.indices { batch[k].dtUs = UInt32(k) * 3000 }
            script.append(Step(delayMs: 9, message: .pen(PenBatch(tool: .pen, baseTimeUs: timeUs, samples: batch))))
            timeUs += 9000
            index += 3
        }
        return script
    }

    /// One precise scroll gesture: BEGAN, 40 CHANGED of 6 pt every 16 ms (finger moving down: natural direction moves
    /// the content down), ENDED. Nothing has moved the cursor before it, so it is located at the display center.
    private static func scrollScript() -> [Step] {
        func scroll(_ phase: ScrollPhase, dy: Float, delay: Int) -> Step {
            Step(delayMs: delay, message: .scroll(Scroll(timeUs: 0, dx: 0, dy: dy, phase: phase)))
        }
        var script = [scroll(.began, dy: 0, delay: 1000)]
        for _ in 0..<40 { script.append(scroll(.changed, dy: 6, delay: 16)) }
        script.append(scroll(.ended, dy: 0, delay: 16))
        return script
    }

    /// One magnify gesture from the touchscreen at the display center: BEGAN, 20 CHANGED of +-3 percent every 16 ms,
    /// ENDED. `spreading` zooms in.
    private static func pinchScript(spreading: Bool) -> [Step] {
        func pinch(_ phase: PinchPhase, scale: Float, delay: Int) -> Step {
            Step(delayMs: delay, message: .pinch(Pinch(timeUs: 0, scale: scale, x: 32768, y: 32768, phase: phase,
                                                        source: .touch)))
        }
        var script = [pinch(.began, scale: 0, delay: 1000)]
        for _ in 0..<20 { script.append(pinch(.changed, scale: spreading ? 0.03 : -0.03, delay: 16)) }
        script.append(pinch(.ended, scale: 0, delay: 16))
        return script
    }

    private static let modifierScanCodes: [String: UInt16] = ["shift": 42, "cmd": 29, "command": 29, "opt": 56, "alt": 56,
                                                              "option": 56, "ctrl": 125, "control": 125]

    private static let keyScanCodes: [String: UInt16] = {
        var t: [String: UInt16] = [
            "esc": 1, "minus": 12, "equal": 13, "backspace": 14, "tab": 15, "lbracket": 26, "rbracket": 27, "enter": 28,
            "semicolon": 39, "quote": 40, "grave": 41, "backslash": 43, "comma": 51, "period": 52, "slash": 53,
            "space": 57, "capslock": 58, "iso102": 86, "home": 102, "up": 103, "pageup": 104, "left": 105,
            "right": 106, "end": 107, "down": 108, "pagedown": 109, "delete": 111,
        ]
        let letters: [(Character, UInt16)] = [
            ("q", 16), ("w", 17), ("e", 18), ("r", 19), ("t", 20), ("y", 21), ("u", 22), ("i", 23), ("o", 24), ("p", 25),
            ("a", 30), ("s", 31), ("d", 32), ("f", 33), ("g", 34), ("h", 35), ("j", 36), ("k", 37), ("l", 38),
            ("z", 44), ("x", 45), ("c", 46), ("v", 47), ("b", 48), ("n", 49), ("m", 50),
        ]
        for (c, code) in letters { t[String(c)] = code }
        for (i, c) in "1234567890".enumerated() { t[String(c)] = UInt16(2 + i) }
        for i in 1...12 { t["f\(i)"] = i <= 10 ? UInt16(58 + i) : UInt16(76 + i) }
        return t
    }()

    /// `--keys`: each combo presses its modifiers, then its key, holds it, then releases in reverse. Messages carry
    /// scan codes only, as the tablet's do; `lock_state` follows the Caps Lock toggles of the script.
    private static func keyScript(_ text: String, holdMs: Int) throws -> [Step] {
        var script: [Step] = []
        var caps = false
        var timeUs: UInt64 = 1_000_000
        func key(_ scan: UInt16, _ action: KeyAction, delay: Int) {
            timeUs += UInt64(max(delay, 1)) * 1000
            script.append(Step(delayMs: delay, message: .key(KeyEvent(timeUs: timeUs, scanCode: scan, androidKeyCode: 0,
                                                                        action: action, capsLockOn: caps))))
        }
        for combo in text.split(separator: ",") {
            let names = combo.split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            guard let last = names.last, !last.isEmpty else { throw ScriptError(description: "empty key combo") }
            var modifiers: [UInt16] = []
            for name in names.dropLast() {
                guard let scan = modifierScanCodes[name] else { throw ScriptError(description: "unknown modifier \(name)") }
                modifiers.append(scan)
            }
            guard let scan = keyScanCodes[last] ?? modifierScanCodes[last] else {
                throw ScriptError(description: "unknown key \(last)")
            }
            for m in modifiers { key(m, .down, delay: 30) }
            key(scan, .down, delay: 30)
            if scan == 58 { caps.toggle() }  // Caps Lock: the state after the event is what the UP carries
            key(scan, .up, delay: holdMs)
            for m in modifiers.reversed() { key(m, .up, delay: 30) }
            script.append(Step(delayMs: 300, message: nil))
        }
        return script
    }

    /// Mouse wheel steps of 10 pt (the client's assumed one tick), 100 ms apart.
    private static func wheelScript(_ steps: Int) -> [Step] {
        (0..<steps).map { i in
            Step(delayMs: i == 0 ? 1000 : 100, message: .scroll(Scroll(timeUs: 0, dx: 0, dy: 10, phase: .none)))
        }
    }

    /// Touch taps at the display center, 60 ms down and 120 ms apart: N presses close in time and place, so N = 2 is a
    /// double click. The touch gate keeps fingers out for 1 s after pen activity, hence the wait.
    private static func tapScript(_ taps: Int, afterPen: Bool) -> [Step] {
        var script: [Step] = []
        func touch(_ buttons: PointerButtons, delay: Int) {
            script.append(Step(delayMs: delay, message: .pointerAbs(PointerAbs(timeUs: 0, x: 32768, y: 32768, buttons: buttons, source: .touch))))
        }
        for i in 0..<taps {
            touch(.left, delay: i == 0 ? (afterPen ? 1300 : 0) : 120)
            touch([], delay: 60)
        }
        return script
    }
}
