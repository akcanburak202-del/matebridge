import AppKit
import CoreGraphics
import CursorProbeCore
import Foundation

// T-271 local-cursor probe. Can the host read the current cursor shape, hidden state and position with public API,
// cheaply and correctly? Passive and read-only: no window (activation policy .prohibited), no pointer movement,
// no clicks, no event injection, no private API. See README.md.
//
//   cursor-probe once   [--iterations N]
//   cursor-probe record --seconds N --out FILE [--hz 60|120] [--dump-dir DIR] [--no-position] [--no-windowlist]

setvbuf(stdout, nil, _IOLBF, 0)

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write(Data((msg + "\n").utf8))
    exit(2)
}

let opts: ProbeOptions
switch ProbeOptions.parse(Array(CommandLine.arguments.dropFirst())) {
case .success(let o): opts = o
case .failure(let e): fail("cursor-probe: \(e)\nusage: cursor-probe once [--iterations N] | record --seconds N --out FILE [--hz 60|120] [--dump-dir DIR] [--no-position] [--no-windowlist]")
}

func describe(_ c: NSCursor?) -> String {
    guard let c else { return "nil" }
    guard let s = CursorSampling.shape(c) else { return "cursor without usable image" }
    let i = s.info
    return "id=\(i.id) px=\(i.pixelWidth)x\(i.pixelHeight) pt=\(f(i.pointWidth))x\(f(i.pointHeight)) scale=\(f(i.scale))"
        + " hot=\(f(i.hotSpotX)),\(f(i.hotSpotY)) reps=\(i.reps.joined(separator: "|"))"
}

func cpuSeconds() -> Double {
    var ru = rusage()
    getrusage(RUSAGE_SELF, &ru)
    func sec(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1e6 }
    return sec(ru.ru_utime) + sec(ru.ru_stime)
}

/// Times `body` `n` times, returns stats. The sink keeps the optimizer from deleting the call.
nonisolated(unsafe) var sink = 0
func cost(_ n: Int, _ body: () -> Int) -> DurationStats? {
    var samples = [UInt64]()
    samples.reserveCapacity(n)
    for _ in 0..<n {
        let t0 = nowNs()
        sink &+= body()
        samples.append(nowNs() - t0)
    }
    return DurationStats(nanoseconds: samples)
}

/// Mean cost of a very cheap call, from one timed batch (the clock ticks every ~42 ns, too coarse per call).
func batchMeanNs(_ n: Int, _ body: () -> Int) -> Double {
    let t0 = nowNs()
    for _ in 0..<n { sink &+= body() }
    return Double(nowNs() - t0) / Double(n)
}

func line(_ label: String, _ s: DurationStats?) {
    print("  \(label.padding(toLength: 44, withPad: " ", startingAt: 0)) \(s?.summary ?? "n/a")")
}

// MARK: - once

func runOnce() {
    print("cursor-probe once (passive, read-only)")
    print("macOS \(ProcessInfo.processInfo.operatingSystemVersionString), pid \(getpid())")

    // Session: is there a window server connection? (public API)
    let session = CGSessionCopyCurrentDictionary() as? [String: Any]
    print("session: onConsole=\(session?["kCGSSessionOnConsoleKey"] ?? "unknown")"
          + " loginDone=\(session?["kCGSessionLoginDoneKey"] ?? "unknown")")

    print("\n== before NSApplication init ==")
    print("  NSCursor.currentSystem: \(describe(NSCursor.currentSystem))")
    print("  NSCursor.current:       \(describe(NSCursor.current))")

    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited) // no Dock icon, no menu bar, no window
    print("\n== after NSApplication init (policy .prohibited) ==")
    let sys = NSCursor.currentSystem
    let cur = NSCursor.current
    print("  NSCursor.currentSystem: \(describe(sys))")
    print("  NSCursor.current:       \(describe(cur))")
    if let sys {
        print("  same object: \(sys === cur), same shape id: \(CursorSampling.shape(sys)?.info.id == CursorSampling.shape(cur)?.info.id)")
    }
    var ids = Set<UInt>()
    for _ in 0..<200 { if let c = NSCursor.currentSystem { ids.insert(UInt(bitPattern: Unmanaged.passUnretained(c).toOpaque())) } }
    print("  distinct currentSystem objects over 200 calls: \(ids.count) (1 means a cached/stable object)")
    print("  CGCursorIsVisible (dlsym): \(CursorSampling.cgCursorIsVisible.map(String.init) ?? "symbol missing")")
    print("  CGEvent(source:nil).location: \(CursorSampling.cgEventLocation.map { "\(f(Double($0.x))),\(f(Double($0.y)))" } ?? "nil")")
    print("  NSEvent.mouseLocation: \(f(Double(CursorSampling.nsMouseLocation.x))),\(f(Double(CursorSampling.nsMouseLocation.y)))")
    let wins = CursorSampling.windowServerWindows()
    let cw = CursorSampling.windowListCursor()
    print("  CGWindowList cursor window: present=\(cw.present) origin=\(f(cw.x)),\(f(cw.y)) size=\(f(cw.w))x\(f(cw.h)) alpha=\(f(cw.alpha))")
    print("  CGWindowList Window Server windows: \(wins.count)")
    for w in wins.prefix(10) { print("    \(w)") }

    let n = opts.iterations
    print("\n== call cost (n=\(n), main thread, warm) ==")
    for _ in 0..<50 { _ = NSCursor.currentSystem.map { CursorSampling.shape($0) } }
    line("currentSystem (object only)") { cost(n) { NSCursor.currentSystem == nil ? 0 : 1 } }
    line("currentSystem + full shape (render+hash)") { cost(n) { NSCursor.currentSystem.flatMap { CursorSampling.shape($0) }?.info.pixelWidth ?? 0 } }
    line("NSCursor.current (object only)") { cost(n) { NSCursor.current.hotSpot.x == 0 ? 0 : 1 } }
    line("CGCursorIsVisible") { cost(n) { CursorSampling.cgCursorIsVisible == true ? 1 : 0 } }
    line("CGEvent(source:nil).location") { cost(n) { Int(CursorSampling.cgEventLocation?.x ?? 0) } }
    line("NSEvent.mouseLocation") { cost(n) { Int(CursorSampling.nsMouseLocation.x) } }
    line("CGWindowList cursor lookup") { cost(min(n, 300)) { CursorSampling.windowListCursor().present ? 1 : 0 } }
    print("  batch means (n=\(n * 20)): CGCursorIsVisible \(f(batchMeanNs(n * 20) { CursorSampling.cgCursorIsVisible == true ? 1 : 0 } )) ns,"
          + " CGEvent location \(f(batchMeanNs(n * 20) { Int(CursorSampling.cgEventLocation?.x ?? 0) } )) ns,"
          + " NSEvent.mouseLocation \(f(batchMeanNs(n * 20) { Int(CursorSampling.nsMouseLocation.x) } )) ns")
    print("\nsink=\(sink)")
}

func line(_ label: String, _ make: () -> DurationStats?) { line(label, make()) }

// MARK: - record

/// Set from the signal handler (plain Bool store; the poll loop only reads it).
nonisolated(unsafe) var stopFlag = false

final class Recorder {
    let o: ProbeOptions
    let start = nowNs()
    var buffer = [String]()
    let file: FileHandle
    var dumped = Set<String>()
    var dumpCount = 0

    init(_ o: ProbeOptions) {
        self.o = o
        let url = URL(fileURLWithPath: o.outPath!)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        guard let h = try? FileHandle(forWritingTo: url) else { fail("cursor-probe: cannot open \(url.path)") }
        file = h
        if let d = o.dumpDir {
            do { try FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true) }
            catch { fail("cursor-probe: cannot create \(d)") }
        }
    }

    var t: Double { Double(nowNs() - start) / 1e9 }

    func emit(_ s: String) {
        buffer.append(s)
        if buffer.count >= 200 { flush() }
    }

    func flush() {
        guard !buffer.isEmpty else { return }
        file.write(Data((buffer.joined(separator: "\n") + "\n").utf8))
        buffer.removeAll(keepingCapacity: true)
    }

    func dumpIfNew(_ s: ShapeSample) {
        guard let dir = o.dumpDir else { return }
        let name = s.info.dumpFileName
        guard dumped.insert(name).inserted else { return }
        if CursorSampling.writePNG(s.image, to: URL(fileURLWithPath: dir).appendingPathComponent(name)) { dumpCount += 1 }
    }

    /// Per-source state for shape tracking. currentSystem is hashed on every tick (cost: see README) because it
    /// returns a fresh object each call, so there is no cheaper identity to compare.
    struct ShapeTrack {
        var tracker = ChangeTracker<ShapeKey>()
        var nilSeen = false
        var digests = 0
    }
    struct ShapeKey: Equatable { var digest: UInt64; var hotX: Double; var hotY: Double }

    func track(_ cursor: NSCursor?, name: String, _ st: inout ShapeTrack) {
        guard let cursor, let s = CursorSampling.shape(cursor) else {
            if !st.nilSeen { emit(RecordLine.shapeNil(t: t, source: name)) }
            st.nilSeen = true
            return
        }
        st.nilSeen = false
        st.digests += 1
        if st.tracker.update(ShapeKey(digest: s.info.digest, hotX: s.info.hotSpotX, hotY: s.info.hotSpotY)) {
            emit(RecordLine.shape(t: t, source: name, s.info))
            dumpIfNew(s)
        }
    }

    func run() {
        let period = UInt64(1e9 / Double(o.hz))
        let totalNs = UInt64(o.seconds * 1e9)
        emit("# cursor-probe record hz=\(o.hz) seconds=\(f(o.seconds)) position=\(o.recordPosition) windowlist=\(o.useWindowList)")
        emit("# format: <seconds> <kind> key=value ... ; no keys or text are recorded")

        var sys = ShapeTrack(), cur = ShapeTrack()
        var visTracker = ChangeTracker<Bool?>()
        var posTracker = ChangeTracker<[Int]>()
        var winTracker = ChangeTracker<CursorSampling.CursorWindow>()
        var tickCost = [UInt64](), lateness = [UInt64]()
        var costSys = [UInt64](), costCur = [UInt64](), costWin = [UInt64](), costPos = [UInt64](), costVis = [UInt64]()
        tickCost.reserveCapacity(Int(o.seconds * Double(o.hz)) + 16)
        lateness.reserveCapacity(tickCost.capacity)
        var skipped = 0

        let cpu0 = cpuSeconds()
        let wall0 = nowNs()
        var tick = 0
        var next = wall0
        while !stopFlag && nowNs() - wall0 < totalNs {
            // Precise sleep to the tick (a run-loop timer would add ~1 ms of coalescing).
            let now = nowNs()
            if next > now {
                // macOS coalesces a sleep by ~20 % of its length (3 ms late for a 16 ms sleep), so sleep half of
                // what is left until 200 us remain, then spin. A product host would use a .strict timer instead.
                let left = next - now
                if left > 200_000 {
                    var ts = timespec(tv_sec: 0, tv_nsec: Int(min(left / 2, 500_000_000)))
                    nanosleep(&ts, nil)
                }
                continue
            }
            lateness.append(now - next)
            let t0 = nowNs()

            track(NSCursor.currentSystem, name: "currentSystem", &sys)
            let t1 = nowNs()
            costSys.append(t1 - t0)
            var tMark = t1
            if tick % max(1, o.hz / 10) == 0 { // comparison only, ~10 Hz
                track(NSCursor.current, name: "current", &cur)
                costCur.append(nowNs() - tMark)
                tMark = nowNs()
            }
            if visTracker.update(CursorSampling.cgCursorIsVisible) {
                emit(RecordLine.visible(t: t, source: "CGCursorIsVisible", visTracker.last!))
            }
            costVis.append(nowNs() - tMark)
            tMark = nowNs()
            if o.recordPosition, let p = CursorSampling.cgEventLocation {
                if posTracker.update([Int(p.x.rounded()), Int(p.y.rounded())]) {
                    emit(RecordLine.position(t: t, x: Double(p.x), y: Double(p.y)))
                }
            }
            costPos.append(nowNs() - tMark)
            tMark = nowNs()
            if o.useWindowList && tick % max(1, o.hz / 10) == 0 { // ~10 Hz, it is the expensive candidate
                let w = CursorSampling.windowListCursor()
                if winTracker.update(w) {
                    emit(RecordLine.windowCursor(t: t, present: w.present, x: w.x, y: w.y, w: w.w, h: w.h, alpha: w.alpha))
                }
                costWin.append(nowNs() - tMark)
            }
            tickCost.append(nowNs() - t0)

            tick += 1
            next += period
            while next < nowNs() { next += period; skipped += 1 } // overran: drop ticks, do not burst
        }
        let wall = Double(nowNs() - wall0) / 1e9
        let cpu = cpuSeconds() - cpu0

        emit("# summary ticks=\(tick) skipped=\(skipped) wall=\(f(wall))s cpu=\(f(cpu * 1000))ms cpuShare=\(f(cpu / wall * 100))%")
        flush()
        try? file.close()

        print("record done: \(tick) ticks at \(o.hz) Hz over \(f(wall)) s, \(skipped) skipped ticks")
        print("  CPU: \(f(cpu * 1000)) ms of \(f(wall * 1000)) ms wall = \(f(cpu / wall * 100)) % of one core (includes the run loop)")
        print("  per-tick cost:  \(DurationStats(nanoseconds: tickCost)?.summary ?? "n/a")")
        print("    currentSystem part: \(DurationStats(nanoseconds: costSys)?.summary ?? "n/a")")
        print("    NSCursor.current (10 Hz): \(DurationStats(nanoseconds: costCur)?.summary ?? "n/a")")
        print("    visibility part:    \(DurationStats(nanoseconds: costVis)?.summary ?? "n/a")")
        print("    position part:      \(DurationStats(nanoseconds: costPos)?.summary ?? "n/a")")
        print("    window list (10 Hz): \(DurationStats(nanoseconds: costWin)?.summary ?? "n/a")")
        print("  tick lateness:  \(DurationStats(nanoseconds: lateness)?.summary ?? "n/a")")
        for (name, st) in [("currentSystem", sys), ("current", cur)] {
            print("  \(name): shape changes=\(st.tracker.changes) hashed=\(st.digests) ticks")
        }
        print("  visibility changes=\(visTracker.changes) last=\(visTracker.last.map { $0.map(String.init) ?? "n/a" } ?? "-")")
        print("  position changes=\(posTracker.changes)  cursorwindow changes=\(winTracker.changes)")
        print("  distinct shapes dumped: \(dumpCount)\(o.dumpDir.map { " -> \($0)" } ?? " (no --dump-dir)")")
    }
}

// MARK: - dispatch

switch opts.mode {
case .once:
    runOnce()
case .record:
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)
    let r = Recorder(opts)
    signal(SIGINT) { _ in stopFlag = true }
    signal(SIGTERM) { _ in stopFlag = true }
    // Without these, timers of a windowless CLI are coalesced (~1.5 ms late) and the cores idle down between ticks.
    pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0)
    let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical],
                                                         reason: "cursor-probe polling")
    print("recording \(f(opts.seconds)) s at \(opts.hz) Hz -> \(opts.outPath!) (Ctrl-C stops early and still writes the summary)")
    r.run()
    ProcessInfo.processInfo.endActivity(activity)
}
