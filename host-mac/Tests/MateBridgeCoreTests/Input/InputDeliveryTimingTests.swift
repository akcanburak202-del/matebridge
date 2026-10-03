import Foundation
import Testing
@testable import MateBridgeCore

// T-175: per-session input delivery timing (deliver / environment / post), the rate-limited slow-call warning, fixed
// size and per-session reset. Diagnostics only: nothing here touches how input is applied.

private let us: UInt64 = 1_000  // nanoseconds per microsecond
private let sec: UInt64 = 1_000_000  // microseconds per second

/// Parses `k=v k=v` into a dictionary (the log line's fields).
private func fields(_ s: String) -> [String: String] {
    var d: [String: String] = [:]
    for part in s.split(separator: " ") {
        let kv = part.split(separator: "=", maxSplits: 1).map(String.init)
        if kv.count == 2 { d[kv[0]] = kv[1] }
    }
    return d
}

private let expectedKeys: Set<String> = [
    "deliver_us_avg", "deliver_us_p99", "deliver_us_max", "env_us_avg", "env_us_max", "post_us_avg", "post_us_max",
    "slow_calls",
]

/// One ordinary message: ~30 µs environment, ~20 µs post, 60 µs at the caller (10 µs of hop and pipeline).
@discardableResult
private func normal(_ t: inout InputDeliveryTiming, at now: UInt64) -> InputDeliveryTiming.SlowCall? {
    t.record(deliverNs: 60 * us, envNs: 30 * us, postNs: 20 * us, nowUs: now)
}

/// The same message with a 25 ms post: the caller waits for it too.
@discardableResult
private func slowPost(_ t: inout InputDeliveryTiming, at now: UInt64) -> InputDeliveryTiming.SlowCall? {
    t.record(deliverNs: 25_060 * us, envNs: 30 * us, postNs: 25_000 * us, nowUs: now)
}

@Suite struct InputDeliveryTimingTests {
    /// The R-tag scenario (card T-175): N messages at ~30 µs env and ~20 µs post, one 25 ms post. Expected fields and
    /// exactly one warning; a second slow call inside the 10 s window yields no second warning.
    @Test func syntheticSessionWithOneSlowPost() {
        var t = InputDeliveryTiming()
        var warnings: [InputDeliveryTiming.SlowCall] = []
        let start: UInt64 = 1_000 * sec
        for i in 0..<100 {
            let now = start + UInt64(i) * 10_000
            let slow = i == 50 ? slowPost(&t, at: now) : normal(&t, at: now)
            if let slow { warnings.append(slow) }
        }
        #expect(warnings == [InputDeliveryTiming.SlowCall(stage: .post, us: 25_000)])
        #expect(t.count == 100)

        let f = fields(t.sessionFields)
        #expect(Set(f.keys) == expectedKeys)
        #expect(f["deliver_us_avg"] == "310.00")  // (99 · 60 + 25 060) / 100
        // Rank 99 of 100 is an ordinary message: 60 µs, reported as its histogram bucket's upper bound (60…61).
        #expect(f["deliver_us_p99"] == "61")
        #expect(f["deliver_us_max"] == "25060")
        #expect(f["env_us_avg"] == "30.00")
        #expect(f["env_us_max"] == "30")
        #expect(f["post_us_avg"] == "269.80")  // (99 · 20 + 25 000) / 100
        #expect(f["post_us_max"] == "25000")
        #expect(f["slow_calls"] == "1")

        // A second slow call 5 s later: inside the window, counted but not logged.
        let firstWarning = start + 50 * 10_000
        #expect(slowPost(&t, at: firstWarning + 5 * sec) == nil)
        #expect(t.slowCalls == 2)
        // Once the window is over, the next one is logged again.
        #expect(slowPost(&t, at: firstWarning + 10 * sec) == InputDeliveryTiming.SlowCall(stage: .post, us: 25_000))
        #expect(t.slowCalls == 3)
    }

    @Test func sessionFieldsStartWithASpaceAndAreZeroWhenEmpty() {
        let t = InputDeliveryTiming()
        #expect(t.sessionFields.hasPrefix(" "))
        let f = fields(t.sessionFields)
        #expect(Set(f.keys) == expectedKeys)
        #expect(f["deliver_us_avg"] == "0")
        #expect(f["deliver_us_p99"] == "0")
        #expect(f["deliver_us_max"] == "0")
        #expect(f["env_us_avg"] == "0")
        #expect(f["env_us_max"] == "0")
        #expect(f["post_us_avg"] == "0")
        #expect(f["post_us_max"] == "0")
        #expect(f["slow_calls"] == "0")
    }

    @Test func stageIsTheSlowInnerCallElseTheCallerSideWait() {
        var t = InputDeliveryTiming(warningIntervalUs: 0)  // every slow call is reported
        // The environment lookup stalled.
        #expect(t.record(deliverNs: 21_100 * us, envNs: 21_000 * us, postNs: 20 * us, nowUs: 1)
            == InputDeliveryTiming.SlowCall(stage: .env, us: 21_000))
        // Neither inner call was slow: the caller waited for the input queue (watchdog, poll) or the pipeline.
        #expect(t.record(deliverNs: 30_000 * us, envNs: 30 * us, postNs: 20 * us, nowUs: 2)
            == InputDeliveryTiming.SlowCall(stage: .deliver, us: 30_000))
        // Both inner calls were slow: the larger one is named, still one warning.
        #expect(t.record(deliverNs: 60_000 * us, envNs: 22_000 * us, postNs: 35_000 * us, nowUs: 3)
            == InputDeliveryTiming.SlowCall(stage: .post, us: 35_000))
        #expect(t.record(deliverNs: 60_000 * us, envNs: 36_000 * us, postNs: 21_000 * us, nowUs: 4)
            == InputDeliveryTiming.SlowCall(stage: .env, us: 36_000))
        // Exactly at the threshold is not slow ("exceeds 20 ms").
        #expect(t.record(deliverNs: 20_000 * us, envNs: 20_000 * us, postNs: 20_000 * us, nowUs: 5) == nil)
        #expect(t.slowCalls == 4)
    }

    @Test func fixedSizeAndResetPerSession() {
        var t = InputDeliveryTiming()
        let size = t.storageCountForTesting
        #expect(size > 0)
        for i in 0..<100_000 {
            normal(&t, at: UInt64(i) * 100)
        }
        slowPost(&t, at: 10 * sec)
        #expect(t.storageCountForTesting == size)
        #expect(t.count == 100_001)

        t.reset()
        #expect(t.storageCountForTesting == size)
        #expect(t.count == 0)
        #expect(t.slowCalls == 0)
        let f = fields(t.sessionFields)
        #expect(f["deliver_us_max"] == "0")
        #expect(f["post_us_max"] == "0")
        #expect(f["slow_calls"] == "0")

        // The next session's numbers are its own.
        normal(&t, at: 11 * sec)
        let g = fields(t.sessionFields)
        #expect(g["deliver_us_avg"] == "60.00")
        #expect(g["deliver_us_max"] == "60")
        #expect(g["env_us_max"] == "30")
        #expect(g["post_us_max"] == "20")
    }

    /// A reconnect storm must not turn into a warning storm: the rate limit outlives the per-session reset.
    @Test func rateLimitOutlivesReset() {
        var t = InputDeliveryTiming()
        #expect(slowPost(&t, at: 100 * sec) != nil)
        t.reset()
        #expect(slowPost(&t, at: 101 * sec) == nil)
        #expect(t.slowCalls == 1)  // still counted in the new session
        #expect(slowPost(&t, at: 110 * sec) != nil)
    }

    /// Sub-microsecond and enormous values neither trap nor go negative.
    @Test func extremeValuesDoNotTrap() {
        var t = InputDeliveryTiming()
        t.record(deliverNs: 0, envNs: 0, postNs: 0, nowUs: 0)
        t.record(deliverNs: UInt64.max, envNs: UInt64.max / 2, postNs: UInt64.max / 2, nowUs: 1)
        let f = fields(t.sessionFields)
        #expect(Set(f.keys) == expectedKeys)
        #expect(f.values.allSatisfy { !$0.hasPrefix("-") })
    }
}
