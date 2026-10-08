import Foundation

/// Transfer function of the virtual display's mode (T-232; the `MATEBRIDGE_VD_TRANSFER` knob was removed in T-304).
/// An HDR10 stream asks for `1` (the value Sidecar Reference Mode uses, T-226) via `VideoSettings.displayTransfer`;
/// an SDR stream never does (legacy `initWithWidth:height:refreshRate:`). Pure; `VirtualDisplay` (the only place that
/// touches the private API) asks these functions what to do and reports the outcome in `ev=vd_transfer`.
public enum VirtualDisplayTransfer {
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
        /// T-281: the primaries the descriptor was created with (`default` = none set).
        public let primaries: VirtualDisplayPrimaries.Applied

        public init(requested: UInt32, applied: UInt32, fallback: FallbackReason?,
                    primaries: VirtualDisplayPrimaries.Applied = .none) {
            self.requested = requested
            self.applied = applied
            self.fallback = fallback
            self.primaries = primaries
        }

        /// The default path: nothing requested, nothing applied.
        public static let legacy = Outcome(requested: 0, applied: 0, fallback: nil)

        /// `W` when a requested transfer function or primaries fell back; `I` otherwise.
        public var logLevel: LogLevel {
            fallback != nil || primaries.fallback != nil || primaries.invalidKnob ? .warning : .info
        }
    }

    /// `requested=<n> applied=<n> [reason=<fallback>] edr_max=<x.xx|na> edr_potential=<x.xx|na>
    /// primaries=<default|p3> [primaries_fallback=<r>] [primaries_reason=invalid_value] wide_gamut=<0|1|na>`.
    /// `edr_max` is `NSScreen.maximumExtendedDynamicRangeColorComponentValue` (current headroom), `edr_potential` the
    /// `maximumPotential…` value; `na` when the display's screen was not found. `wide_gamut` (T-281) is
    /// `CGColorSpaceIsWideGamutRGB(CGDisplayCopyColorSpace(id))` read once shortly after creation; `na` when it was
    /// not read.
    public static func logFields(_ outcome: Outcome, edr: EDRHeadroom?, wideGamut: Bool? = nil) -> String {
        var f = "requested=\(outcome.requested) applied=\(outcome.applied)"
        if let r = outcome.fallback {
            f += " reason=\(r.rawValue)"
        }
        f += " edr_max=\(format(edr?.current)) edr_potential=\(format(edr?.potential))"
        f += " \(VirtualDisplayPrimaries.logFields(outcome.primaries))"
        f += " wide_gamut=\(wideGamut.map { $0 ? "1" : "0" } ?? "na")"
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
