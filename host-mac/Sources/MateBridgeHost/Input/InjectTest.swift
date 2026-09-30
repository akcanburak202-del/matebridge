import Foundation
import MateBridgeCore

/// `MateBridgeApp --inject-test`: injects protocol input into the MateBridge virtual display through the REAL input
/// path (`InputController`: state machine, planner, gating, `CGEventPoster`), so the orchestrator can watch it land in
/// Krita or any other app on that display. It posts real events. Never run it unattended, and never from a test.
///
///     MateBridgeApp --inject-test --fixture pen_hover_to_contact [--fixture pen_leave ...]
///     MateBridgeApp --inject-test --stroke ramp|circle|tilt [--repeat N]
///     MateBridgeApp --inject-test --tap 2            (touch taps at the display center; 2 = double click)
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
        public var repeats = 1
        public var countdown: Double = 5
        public var createDisplay = false
        public var fixturesDirectory: String?
    }

    public struct ParseError: Error, Sendable { public let message: String }

    public static let usage = """
        usage: MateBridgeApp --inject-test [--fixture NAME]... [--stroke ramp|circle|tilt] [--tap N]
                             [--repeat N] [--countdown S] [--create-display] [--fixtures-dir DIR]
        """

    /// nil when `--inject-test` is absent.
    public static func parse(_ args: [String]) -> Result<Options, ParseError>? {
        guard args.contains("--inject-test") else { return nil }
        var o = Options()
        var i = 0
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
            case "--repeat":
                guard let v = value(), let n = Int(v), (1...20).contains(n) else { return fail("--repeat needs 1...20") }
                o.repeats = n; i += 1
            case "--countdown":
                guard let v = value(), let s = Double(v), (0...60).contains(s) else { return fail("--countdown needs 0...60 seconds") }
                o.countdown = s; i += 1
            case "--create-display": o.createDisplay = true
            case "--fixtures-dir":
                guard let v = value() else { return fail("--fixtures-dir needs a directory") }
                o.fixturesDirectory = v; i += 1
            default: break
            }
            i += 1
        }
        if o.fixtures.isEmpty && o.stroke == nil && o.taps == 0 { return fail("nothing to inject") }
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
