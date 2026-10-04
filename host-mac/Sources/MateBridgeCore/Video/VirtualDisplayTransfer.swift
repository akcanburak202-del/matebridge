import Foundation

/// T-232 developer knob `MATEBRIDGE_VD_TRANSFER=0|1`: create the virtual display's mode with a transfer function
/// (`CGVirtualDisplayMode initWithWidth:height:refreshRate:transferFunction:`, `1` = the value Sidecar Reference Mode
/// uses, T-226) so macOS may offer HDR/EDR on it. The stream stays SDR. Pure; `VirtualDisplay` (the only place that
/// touches the private API) asks these functions what to do and reports the outcome in `ev=vd_transfer`.
///
/// Default (unset, `0`, or any invalid value) is the legacy `initWithWidth:height:refreshRate:` call, unchanged.
public enum VirtualDisplayTransfer {
    public static let envKey = "MATEBRIDGE_VD_TRANSFER"

    /// The parsed knob: `requested` is the transfer function to ask for (0 = legacy path). `invalid` is true when the
    /// variable was set to something other than `0`/`1` (treated as 0).
    public struct Knob: Equatable, Sendable {
        public let requested: UInt32
        public let invalid: Bool
        public init(requested: UInt32, invalid: Bool) {
            self.requested = requested
            self.invalid = invalid
        }
    }

    /// nil or empty -> 0; "0" -> 0; "1" -> 1 (surrounding whitespace ignored); anything else -> 0, `invalid`.
    public static func parse(_ raw: String?) -> Knob {
        let t = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        switch t {
        case "": return Knob(requested: 0, invalid: false)
        case "0": return Knob(requested: 0, invalid: false)
        case "1": return Knob(requested: 1, invalid: false)
        default: return Knob(requested: 0, invalid: true)
        }
    }

    public static func parse(env: [String: String]) -> Knob { parse(env[envKey]) }

    /// Why a requested transfer function was not applied (the legacy mode was used instead).
    public enum FallbackReason: String, Equatable, Sendable {
        /// `CGVirtualDisplayMode` does not respond to the `transferFunction:` initializer.
        case selectorMissing = "selector_missing"
        /// The `transferFunction:` initializer returned nil.
        case modeNil = "mode_nil"
        /// `applySettings:` rejected the modes created with a transfer function.
        case settingsRejected = "settings_rejected"
    }

    public enum Decision: Equatable, Sendable {
        /// The legacy `initWithWidth:height:refreshRate:` initializer (default path).
        case legacy
        /// The `transferFunction:` initializer with this value.
        case transfer(UInt32)
        /// A transfer function was requested but cannot be used: legacy initializer, logged with the reason.
        case fallback(FallbackReason)
    }

    /// Which mode initializer to use, before any mode is created.
    public static func decide(requested: UInt32, selectorAvailable: Bool) -> Decision {
        guard requested != 0 else { return .legacy }
        return selectorAvailable ? .transfer(requested) : .fallback(.selectorMissing)
    }

    /// After trying the `transferFunction:` modes: nil when they were created and accepted (applied), otherwise the
    /// reason to retry once with the legacy modes. A nil mode is checked first (settings were then never applied).
    public static func fallbackAfterAttempt(modeCreated: Bool, settingsAccepted: Bool) -> FallbackReason? {
        if !modeCreated { return .modeNil }
        if !settingsAccepted { return .settingsRejected }
        return nil
    }

    /// What the display was created with, for `ev=vd_transfer`.
    public struct Outcome: Equatable, Sendable {
        public let requested: UInt32
        /// The transfer function actually in the display's mode (0 = legacy).
        public let applied: UInt32
        public let fallback: FallbackReason?
        /// The knob had an invalid value (treated as 0).
        public let invalidKnob: Bool

        public init(requested: UInt32, applied: UInt32, fallback: FallbackReason?, invalidKnob: Bool = false) {
            self.requested = requested
            self.applied = applied
            self.fallback = fallback
            self.invalidKnob = invalidKnob
        }

        /// The default path: nothing requested, nothing applied.
        public static let legacy = Outcome(requested: 0, applied: 0, fallback: nil)

        /// `W` when the knob was invalid or a requested transfer function fell back; `I` otherwise.
        public var logLevel: LogLevel { fallback != nil || invalidKnob ? .warning : .info }
    }

    /// `requested=<n> applied=<n> [reason=<fallback>|invalid_value] edr_max=<x.xx|na> edr_potential=<x.xx|na>`.
    /// `edr_max` is `NSScreen.maximumExtendedDynamicRangeColorComponentValue` (current headroom), `edr_potential` the
    /// `maximumPotential…` value; `na` when the display's screen was not found.
    public static func logFields(_ outcome: Outcome, edr: EDRHeadroom?) -> String {
        var f = "requested=\(outcome.requested) applied=\(outcome.applied)"
        if let r = outcome.fallback {
            f += " reason=\(r.rawValue)"
        } else if outcome.invalidKnob {
            f += " reason=invalid_value"
        }
        f += " edr_max=\(format(edr?.current)) edr_potential=\(format(edr?.potential))"
        return f
    }

    static func format(_ v: Double?) -> String {
        guard let v, v.isFinite else { return "na" }
        return String(format: "%.2f", v)
    }
}

/// A screen's EDR headroom (`NSScreen` values; 1.0 = SDR, no headroom).
public struct EDRHeadroom: Equatable, Sendable {
    /// `maximumExtendedDynamicRangeColorComponentValue`.
    public let current: Double
    /// `maximumPotentialExtendedDynamicRangeColorComponentValue`.
    public let potential: Double
    public init(current: Double, potential: Double) {
        self.current = current
        self.potential = potential
    }
}
