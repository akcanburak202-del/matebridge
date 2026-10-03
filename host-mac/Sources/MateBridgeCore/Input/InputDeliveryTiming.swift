// Input delivery timing (T-175): diagnostics only. Nothing here changes how or when input is applied.

/// Per-session cost of delivering input messages on the host. Skeleton: not implemented yet (red scenario first).
public struct InputDeliveryTiming: Sendable {
    public enum Stage: String, Sendable {
        case env, post, deliver
    }

    public struct SlowCall: Equatable, Sendable {
        public var stage: Stage
        public var us: UInt64
    }

    public static let defaultSlowThresholdUs: UInt64 = 20_000
    public static let defaultWarningIntervalUs: UInt64 = 10_000_000

    public let slowThresholdUs: UInt64
    public let warningIntervalUs: UInt64
    public private(set) var count = 0
    public private(set) var slowCalls = 0

    public init(slowThresholdUs: UInt64 = InputDeliveryTiming.defaultSlowThresholdUs,
                warningIntervalUs: UInt64 = InputDeliveryTiming.defaultWarningIntervalUs) {
        self.slowThresholdUs = slowThresholdUs
        self.warningIntervalUs = warningIntervalUs
    }

    var storageCountForTesting: Int { 0 }

    @discardableResult
    public mutating func record(deliverNs: UInt64, envNs: UInt64, postNs: UInt64, nowUs: UInt64) -> SlowCall? {
        nil
    }

    public mutating func reset() {}

    public var sessionFields: String { "" }
}
