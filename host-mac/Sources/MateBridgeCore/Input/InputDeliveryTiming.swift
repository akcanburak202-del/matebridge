import Foundation

// Input delivery timing (T-175): diagnostics only. Nothing here changes how or when input is applied.
//
// Every input message is handed from the session queue to the input queue with a synchronous hop, so whatever the
// input side spends per message, the session queue (control reads, PONG replies, the heartbeat tick, the audio drain)
// waits for too. Three times are kept per message:
//
//   deliver  the caller-side duration of `InputController.deliver`, around the `queue.sync` hop: it includes the wait
//            for the input queue while its watchdog or 1 s poll runs, which is what blocks the session queue.
//   env      the environment lookups on the input queue (Accessibility, virtual display geometry, caps lock for KEY).
//   post     posting the message's events (`CGEventPoster.post`, plus the fresh permission check before a release).

/// Per-session cost of delivering input messages on the host, for `input_session_end`, plus a rate-limited warning
/// when one call is slow. Fixed size: recording and `reset()` never allocate. Confined to one context by its owner.
/// Times only, never anything about the message's content.
public struct InputDeliveryTiming: Sendable {
    /// Which call was slow. `deliver`: neither inner call was, so the time went to waiting for the input queue or to
    /// the pipeline itself.
    public enum Stage: String, Sendable {
        case env, post, deliver
    }

    /// One slow call to log (`ev=input_slow_call stage= us=`).
    public struct SlowCall: Equatable, Sendable {
        public var stage: Stage
        public var us: UInt64
    }

    /// A call slower than this (strictly) is a slow call.
    public static let defaultSlowThresholdUs: UInt64 = 20_000
    /// At most one warning per this interval; the others are only counted (`slow_calls`).
    public static let defaultWarningIntervalUs: UInt64 = 10_000_000

    public let slowThresholdUs: UInt64
    public let warningIntervalUs: UInt64
    /// Messages recorded this session.
    public private(set) var count = 0
    /// Messages of this session with a slow call, logged or not.
    public private(set) var slowCalls = 0

    /// Caller-side delivery, in microseconds.
    private var deliver = AgeHistogram()
    private var deliverSumNs: UInt64 = 0
    private var envSumNs: UInt64 = 0
    private var envMaxNs: UInt64 = 0
    private var postSumNs: UInt64 = 0
    private var postMaxNs: UInt64 = 0
    /// Host time of the last warning. Survives `reset()`: a reconnect storm must not become a warning storm.
    private var lastWarningUs: UInt64?

    public init(slowThresholdUs: UInt64 = InputDeliveryTiming.defaultSlowThresholdUs,
                warningIntervalUs: UInt64 = InputDeliveryTiming.defaultWarningIntervalUs) {
        self.slowThresholdUs = slowThresholdUs
        self.warningIntervalUs = warningIntervalUs
    }

    /// Test hook: the storage never grows.
    var storageCountForTesting: Int { deliver.storageCountForTesting }

    /// One delivered message (times in nanoseconds, `nowUs` on the host clock). Returns the slow call to log, if one
    /// of its calls exceeded the threshold and no warning was logged in the last `warningIntervalUs`. At most one per
    /// message: the slower inner call (env or post) if either was slow, else the caller-side delivery.
    @discardableResult
    public mutating func record(deliverNs: UInt64, envNs: UInt64, postNs: UInt64, nowUs: UInt64) -> SlowCall? {
        let deliverUs = deliverNs / 1_000
        count += 1
        deliver.record(Int64(clamping: deliverUs))
        deliverSumNs = Self.add(deliverSumNs, deliverNs)
        envSumNs = Self.add(envSumNs, envNs)
        envMaxNs = max(envMaxNs, envNs)
        postSumNs = Self.add(postSumNs, postNs)
        postMaxNs = max(postMaxNs, postNs)

        let envUs = envNs / 1_000, postUs = postNs / 1_000
        let slow: SlowCall
        if envUs > slowThresholdUs || postUs > slowThresholdUs {
            slow = postUs >= envUs ? SlowCall(stage: .post, us: postUs) : SlowCall(stage: .env, us: envUs)
        } else if deliverUs > slowThresholdUs {
            slow = SlowCall(stage: .deliver, us: deliverUs)
        } else {
            return nil
        }
        slowCalls += 1
        if let last = lastWarningUs, nowUs >= last, nowUs - last < warningIntervalUs { return nil }
        lastWarningUs = nowUs
        return slow
    }

    /// A new session: no samples. The warning rate limit carries over.
    public mutating func reset() {
        count = 0
        slowCalls = 0
        deliver.reset()
        deliverSumNs = 0
        envSumNs = 0
        envMaxNs = 0
        postSumNs = 0
        postMaxNs = 0
    }

    /// Session totals for `input_session_end` (fields start with a space). Averages in microseconds with two
    /// decimals, the p99 as its histogram bucket's upper bound (at most 6.25 % high, capped at the exact max), maxima
    /// exact in whole microseconds.
    public var sessionFields: String {
        " deliver_us_avg=\(average(deliverSumNs)) deliver_us_p99=\(deliver.percentile(permille: 990) ?? 0)"
            + " deliver_us_max=\(deliver.max ?? 0)"
            + " env_us_avg=\(average(envSumNs)) env_us_max=\(envMaxNs / 1_000)"
            + " post_us_avg=\(average(postSumNs)) post_us_max=\(postMaxNs / 1_000)"
            + " slow_calls=\(slowCalls)"
    }

    private func average(_ sumNs: UInt64) -> String {
        guard count > 0 else { return "0" }
        return String(format: "%.2f", Double(sumNs) / Double(count) / 1_000)
    }

    private static func add(_ a: UInt64, _ b: UInt64) -> UInt64 {
        let (sum, overflow) = a.addingReportingOverflow(b)
        return overflow ? .max : sum
    }
}
