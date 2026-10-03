import Foundation
import Testing
@testable import MateBridgeCore

// T-171: clock offset from PONG, input age at delivery, fixed-size histograms, `ev=input_age` cadence and privacy.

private let ms: UInt64 = 1_000
private let sec: UInt64 = 1_000_000

/// A fake client clock: `client = host + offset`, optionally running fast by `ppm`.
private struct FakeClient {
    var offset: Int64
    var ppm: Double = 0
    func time(atHost h: UInt64) -> UInt64 {
        UInt64(Int64(h) + offset + Int64((Double(h) * ppm / 1_000_000).rounded()))
    }
}

/// One PING/PONG exchange: sent at `sentAt` (host), answered after `up` µs, back after `down` more.
@discardableResult
private func exchange(_ e: inout ClockOffsetEstimator, client: FakeClient, sentAt: UInt64, up: UInt64,
                      down: UInt64) -> Bool {
    e.add(echoUs: sentAt, responderUs: client.time(atHost: sentAt + up), receivedUs: sentAt + up + down)
}

private func pong(_ client: FakeClient, sentAt: UInt64, up: UInt64) -> Pong {
    Pong(seq: 1, echoTimeUs: sentAt, responderTimeUs: client.time(atHost: sentAt + up))
}

private func key(_ t: UInt64) -> Message {
    .key(KeyEvent(timeUs: t, scanCode: 30, androidKeyCode: 29, action: .down, capsLockOn: false))
}

/// Parses `k=v k=v` into a dictionary (the log line's fields).
private func fields(_ s: String) -> [String: String] {
    var d: [String: String] = [:]
    for part in s.split(separator: " ") {
        let kv = part.split(separator: "=", maxSplits: 1).map(String.init)
        if kv.count == 2 { d[kv[0]] = kv[1] }
    }
    return d
}

/// A tracker with a known offset of `offset` (client − host) from one symmetric 2 ms round trip.
private func tracker(offset: Int64 = 3_000_000_000) -> InputAgeTracker {
    var t = InputAgeTracker()
    let client = FakeClient(offset: offset)
    t.clockSample(pong(client, sentAt: 10 * sec, up: 1 * ms), receivedUs: 10 * sec + 2 * ms)
    return t
}

@Suite struct ClockOffsetEstimatorTests {
    @Test("EST-1 the lowest-RTT sample of the window wins; the offset is responder − (echo + rtt/2)")
    func minRttWins() {
        var e = ClockOffsetEstimator()
        #expect(e.offsetUs == nil && e.bestRttUs == nil)
        let client = FakeClient(offset: 5 * Int64(sec))
        // Asymmetric, slow samples (queueing on the way back) and one quick symmetric one.
        exchange(&e, client: client, sentAt: 1 * sec, up: 2 * ms, down: 30 * ms)
        exchange(&e, client: client, sentAt: 2 * sec, up: 1 * ms, down: 1 * ms)
        exchange(&e, client: client, sentAt: 3 * sec, up: 3 * ms, down: 40 * ms)
        #expect(e.bestRttUs == 2 * ms)
        #expect(e.offsetUs == 5 * Int64(sec))
        // A slow sample alone would be off by half its asymmetry.
        var slow = ClockOffsetEstimator()
        exchange(&slow, client: client, sentAt: 1 * sec, up: 2 * ms, down: 30 * ms)
        #expect(slow.offsetUs == 5 * Int64(sec) - 14 * Int64(ms))
    }

    @Test("EST-2 a bogus echo (in the host's future, rtt < 0) is ignored")
    func bogusEcho() {
        var e = ClockOffsetEstimator()
        let future = e.add(echoUs: 5 * sec, responderUs: 1, receivedUs: 4 * sec)
        #expect(!future)
        #expect(e.offsetUs == nil && e.accepted == 0)
        let good = e.add(echoUs: 4 * sec, responderUs: 4 * sec + 500, receivedUs: 4 * sec + 1_000)
        let wild = e.add(echoUs: UInt64.max, responderUs: 0, receivedUs: 0)
        #expect(good && !wild)
        #expect(e.offsetUs == 0 && e.bestRttUs == 1_000 && e.accepted == 1)
    }

    @Test("EST-3 only the last `window` samples count: an old quick sample is forgotten")
    func windowRolls() {
        var e = ClockOffsetEstimator(window: 8)
        exchange(&e, client: FakeClient(offset: 1_000), sentAt: 0, up: 100, down: 100)  // rtt 200 µs
        for i in 1...7 { exchange(&e, client: FakeClient(offset: 1_000), sentAt: UInt64(i) * sec, up: 5 * ms, down: 5 * ms) }
        #expect(e.bestRttUs == 200)
        exchange(&e, client: FakeClient(offset: 1_000), sentAt: 8 * sec, up: 5 * ms, down: 5 * ms)
        #expect(e.bestRttUs == 10 * ms)
    }

    @Test("EST-4 clock skew: a client clock running 100 ppm fast is tracked within the window's drift")
    func skew() {
        var e = ClockOffsetEstimator()
        let client = FakeClient(offset: -7 * Int64(sec), ppm: 100)
        for i in 0..<40 {
            let sentAt = 100 * sec + UInt64(i) * 500 * ms
            let jitter = UInt64((i * 7) % 5) * ms
            exchange(&e, client: client, sentAt: sentAt, up: 1 * ms + jitter, down: 1 * ms + jitter)
            let truth = Int64(client.time(atHost: sentAt)) - Int64(sentAt)
            // Window of 8 samples × 500 ms × 100 ppm = 400 µs of drift at most, plus 1 µs of rounding.
            #expect(abs((e.offsetUs ?? 0) - truth) <= 401)
        }
    }

    @Test("EST-5 a backwards jump of the client clock: never traps, and the window forgets the old clock")
    func clientClockJumpsBack() {
        var e = ClockOffsetEstimator()
        var client = FakeClient(offset: 20 * Int64(sec))
        let base = 100 * sec
        for i in 0..<8 { exchange(&e, client: client, sentAt: base + UInt64(i) * 500 * ms, up: 1 * ms, down: 1 * ms) }
        #expect(e.offsetUs == 20 * Int64(sec))
        client.offset = -30 * Int64(sec)  // the client's clock jumps back 50 s
        for i in 8..<16 {
            exchange(&e, client: client, sentAt: base + UInt64(i) * 500 * ms, up: 2 * ms, down: 2 * ms)
        }
        #expect(e.offsetUs == -30 * Int64(sec))
    }

    @Test("EST-6 hostile values wrap, they never trap")
    func hostileValues() {
        var e = ClockOffsetEstimator()
        let a = e.add(echoUs: 0, responderUs: UInt64.max, receivedUs: UInt64.max)
        let b = e.add(echoUs: 1, responderUs: 0, receivedUs: UInt64.max)
        #expect(a && b)
        #expect(e.offsetUs != nil)
        var t = InputAgeTracker()
        t.clockSample(Pong(seq: 1, echoTimeUs: 0, responderTimeUs: UInt64.max), receivedUs: 10)
        t.record(.pen(PenBatch(tool: .pen, baseTimeUs: UInt64.max, samples: [
            PenSample(dtUs: UInt32.max, x: 0, y: 0, pressure: 0, tiltX: 0, tiltY: 0, flags: [])])),
                 receivedUs: UInt64.max)
        t.record(key(UInt64.max), receivedUs: 0)
        let report = t.takeReport(now: UInt64.max, force: true)
        #expect(report != nil)
    }
}

@Suite struct InputAgeTests {
    @Test("AGE-1 every PEN sample gets age = recv − (base + dt − offset)")
    func penSampleAges() {
        let offset: Int64 = 3_000_000_000
        var t = tracker(offset: offset)
        #expect(t.estimator.offsetUs == offset)
        let recv = 20 * sec
        // The samples were taken 9, 7 and 4 ms before `recv` on the host's clock.
        let base = UInt64(Int64(recv - 9 * ms) + offset)
        let batch = PenBatch(tool: .pen, baseTimeUs: base, samples: [0, 2_000, 5_000].map {
            PenSample(dtUs: $0, x: 100, y: 200, pressure: 300, tiltX: 0, tiltY: 0, flags: [])
        })
        #expect(t.age(clientTimeUs: base + 2_000, receivedUs: recv) == 7_000)
        t.record(.pen(batch), receivedUs: recv)
        let f = fields(t.takeReport(now: recv, force: true) ?? "")
        #expect(f["pen_n"] == "3")
        #expect(f["pen_max_us"] == "9000")
        #expect(f["neg"] == "0" && f["late_250ms"] == "0" && f["no_offset"] == "0")
        #expect(f["offset_rtt_us"] == "2000" && f["clock_unc_us"] == "1000")
    }

    @Test("AGE-2 KEY, POINTER_REL/ABS, SCROLL and PINCH ages from time_us, each in its class")
    func timeUsClasses() {
        let offset: Int64 = -1_000_000
        var t = tracker(offset: offset)
        let recv = 30 * sec
        func at(_ ageUs: UInt64) -> UInt64 { UInt64(Int64(recv - ageUs) + offset) }
        t.record(key(at(3 * ms)), receivedUs: recv)
        t.record(.pointerRel(PointerRel(timeUs: at(4 * ms), dx: 1, dy: 1, buttons: [])), receivedUs: recv)
        t.record(.pointerAbs(PointerAbs(timeUs: at(5 * ms), x: 1, y: 1, buttons: [], source: .touch)),
                 receivedUs: recv)
        t.record(.scroll(Scroll(timeUs: at(6 * ms), dx: 0, dy: 1, phase: .changed)), receivedUs: recv)
        t.record(.pinch(Pinch(timeUs: at(8 * ms), scale: 1, x: 1, y: 1, phase: .changed, source: .touch)),
                 receivedUs: recv)
        // Not aged: control and gesture messages.
        t.record(.releaseAll(.user), receivedUs: recv)
        t.record(.penGesture(PenGesture(timeUs: at(1 * ms), gesture: PenGestureKind(rawValue: 1))), receivedUs: recv)
        let f = fields(t.takeReport(now: recv, force: true) ?? "")
        #expect(f["key_n"] == "1" && f["key_max_us"] == "3000")
        #expect(f["pointer_n"] == "2" && f["pointer_max_us"] == "5000")
        #expect(f["scroll_n"] == "2" && f["scroll_max_us"] == "8000")
        #expect(f["pen_n"] == "0" && f["pen_p50_us"] == nil)
    }

    @Test("AGE-3 negative ages are kept: counted in neg and part of the distribution, never clamped")
    func negativeAges() {
        var t = tracker(offset: 0)
        let recv = 40 * sec
        for _ in 0..<3 { t.record(key(recv + 2 * ms), receivedUs: recv) }  // the client claims the future
        t.record(key(recv - 300 * ms), receivedUs: recv)  // late
        let f = fields(t.takeReport(now: recv, force: true) ?? "")
        #expect(f["neg"] == "3" && f["late_250ms"] == "1" && f["key_n"] == "4")
        #expect(f["key_p50_us"].flatMap { Int64($0) }.map { $0 < 0 } == true)
        #expect(f["key_max_us"] == "300000")
    }

    @Test("AGE-4 input before the first clock sample has no age: counted as no_offset, not in the distribution")
    func noOffsetYet() {
        var t = InputAgeTracker()
        t.record(key(5), receivedUs: 1 * sec)
        let f = fields(t.takeReport(now: 1 * sec, force: true) ?? "")
        #expect(f["no_offset"] == "1" && f["key_n"] == "0")
        #expect(f["offset_rtt_us"] == "none" && f["clock_unc_us"] == "none")
    }
}

@Suite struct AgeHistogramTests {
    @Test("HIST-1 fixed size: the storage never grows, whatever is recorded, and reset keeps it")
    func fixedSize() {
        var h = AgeHistogram()
        let size = h.storageCountForTesting
        #expect(size == 2 * AgeHistogram.bucketsPerSign)
        for v: Int64 in [0, 1, 15, 16, 1_000, 250_000, Int64(Int32.max), Int64.max, -1, -16, -1_000_000, Int64.min] {
            h.record(v)
        }
        #expect(h.storageCountForTesting == size && h.count == 12 && h.negative == 4 && h.max == Int64.max)
        h.reset()
        #expect(h.storageCountForTesting == size && h.count == 0 && h.max == nil && h.percentile(permille: 500) == nil)
    }

    @Test("HIST-2 every value lies inside its bucket, and the bucket error is at most 1/16")
    func bucketBounds() {
        var v: UInt64 = 0
        while v < (UInt64(1) << 31) {
            let b = AgeHistogram.bucket(magnitude: v)
            let lo = AgeHistogram.lowerBound(b), hi = AgeHistogram.upperBound(b)
            #expect(lo <= v && v <= hi)
            #expect(hi - lo <= lo / 16)
            v = v < 64 ? v + 1 : v + v / 7
        }
        #expect(AgeHistogram.bucket(magnitude: UInt64.max) == AgeHistogram.bucketsPerSign - 1)
    }

    @Test("HIST-3 percentiles: within one bucket of the truth, never above the exact max")
    func percentiles() {
        var h = AgeHistogram()
        for v in 1...1_000 { h.record(Int64(v) * 100) }  // 100 µs ... 100 ms
        for (permille, truth) in [(500, 50_000.0), (950, 95_000.0), (990, 99_000.0)] {
            let p = Double(h.percentile(permille: permille) ?? 0)
            #expect(p >= truth && p <= truth * 1.0625)
        }
        #expect(h.percentile(permille: 1000) == 100_000 && h.max == 100_000)
        var one = AgeHistogram()
        one.record(1_234_567)
        #expect(one.percentile(permille: 500) == 1_234_567)  // capped at the exact max
    }
}

@Suite struct InputAgeReportTests {
    @Test("REP-1 one input_age report per second while input flows, none while it does not")
    func cadence() {
        var t = tracker()
        let idle = t.takeReport(now: 100 * sec)
        #expect(idle == nil)  // no input, no line
        t.record(key(1), receivedUs: 100 * sec)
        let early = t.takeReport(now: 100 * sec + 999 * ms)
        #expect(early == nil)
        t.record(key(1), receivedUs: 100 * sec + 999 * ms)
        let first = t.takeReport(now: 101 * sec)
        #expect(first.map { fields($0)["key_n"] } == "2")
        #expect(first.map { fields($0)["interval_ms"] } == "1000")
        let quiet = t.takeReport(now: 105 * sec)
        #expect(quiet == nil)  // nothing flowed since
        t.record(key(1), receivedUs: 106 * sec)  // a new window opens with the next sample
        let half = t.takeReport(now: 106 * sec + 500 * ms)
        #expect(half == nil)
        let second = t.takeReport(now: 107 * sec)
        #expect(second.map { fields($0)["key_n"] } == "1")
    }

    @Test("REP-2 session totals cover every window and the clock samples")
    func sessionTotals() {
        var t = tracker(offset: 0)
        for s in 0..<3 {
            let recv = UInt64(200 + s) * sec
            t.record(key(recv - 1 * ms), receivedUs: recv)
            t.record(key(recv - 400 * ms), receivedUs: recv)
            _ = t.takeReport(now: recv + sec)
        }
        let f = fields(t.sessionFields)
        #expect(f["age_key_n"] == "6" && f["age_late_250ms"] == "3" && f["age_key_max_us"] == "400000")
        #expect(f["age_pongs"] == "1" && f["age_offset_rtt_us"] == "2000")
        t.reset()
        let r = fields(t.sessionFields)
        #expect(r["age_key_n"] == "0" && r["age_pongs"] == "0" && r["age_offset_rtt_us"] == "none")
    }

    @Test("REP-3 no key, character or coordinate in either line: only the documented fields")
    func privacy() {
        var t = tracker(offset: 0)
        let recv = 300 * sec
        t.record(.pen(PenBatch(tool: .pen, baseTimeUs: recv - 3 * ms, samples: [
            PenSample(dtUs: 0, x: 54_321, y: 43_210, pressure: 999, tiltX: 12, tiltY: -12, flags: [])])),
                 receivedUs: recv)
        t.record(.key(KeyEvent(timeUs: recv - 2 * ms, scanCode: 0x1E, androidKeyCode: 29, action: .down,
                               capsLockOn: true)), receivedUs: recv)
        t.record(.pointerAbs(PointerAbs(timeUs: recv - 1 * ms, x: 31_337, y: 27_182, buttons: [], source: .mouse)),
                 receivedUs: recv)
        let report = t.takeReport(now: recv, force: true) ?? ""
        var allowed: Set<String> = ["interval_ms", "late_250ms", "neg", "no_offset", "offset_rtt_us", "clock_unc_us"]
        for c in ["pen", "pointer", "key", "scroll"] {
            for s in ["n", "p50_us", "p95_us", "p99_us", "max_us"] { allowed.insert("\(c)_\(s)") }
        }
        let sessionAllowed = Set(allowed.subtracting(["interval_ms"]).map { "age_" + $0 } + ["age_pongs"])
        for (line, names) in [(report, allowed), (t.sessionFields, sessionAllowed)] {
            #expect(!line.isEmpty)
            for part in line.split(separator: " ") {
                let kv = part.split(separator: "=", maxSplits: 1).map(String.init)
                #expect(kv.count == 2 && names.contains(kv[0]), "unexpected field \(part)")
                #expect(kv.count == 2 && (Int64(kv[1]) != nil || kv[1] == "none"), "non-numeric value \(part)")
            }
            for secret in ["54321", "43210", "31337", "27182", "999"] { #expect(!line.contains(secret)) }
        }
    }
}
