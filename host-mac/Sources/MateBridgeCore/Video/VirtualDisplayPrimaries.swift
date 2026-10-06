import Foundation

/// T-281 (decision 0032 update): the colour primaries the virtual display is created with. A display created with
/// `transferFunction = 1` (HDR) but the descriptor's default Rec.709 primaries is not "wide gamut" to macOS, so
/// MediaToolbox's `MTShouldPlayHDRVideo` says SDR and Safari/YouTube offer no HDR (docs/research/2026-10-06-safari-hdr-
/// virtual-display.md). Apple's Sidecar gives its displays Display P3 primaries; an HDR display gets the same.
///
/// Developer knob `MATEBRIDGE_VD_PRIMARIES=default|p3`. Unset: P3 for an HDR display (`requested transfer == 1`),
/// the descriptor defaults for an SDR display (bit for bit the pre-T-281 creation). `default` switches P3 off. Any
/// other value counts as `p3` and is flagged (`primaries_reason=invalid_value`, warning). The primaries can only be
/// given at creation (`initWithDescriptor:`; `applySettings:` does not change them, [guess]), so `DisplayMode` carries
/// them and `DisplayReuse` never reuses a display whose primaries differ.
///
/// Pure; `VirtualDisplay` (the only place that touches the private API) asks these functions what to do.
public enum VirtualDisplayPrimaries {
    public static let envKey = "MATEBRIDGE_VD_PRIMARIES"

    /// The primaries the descriptor is given: `default` = none set (the descriptor's own Rec.709 values).
    public enum Choice: String, Equatable, Sendable {
        case `default`
        case p3
    }

    /// The parsed knob. `requested` is nil when the variable is unset (automatic: P3 for HDR). `invalid` is true when
    /// the variable held something other than `default`/`p3` (treated as `p3`).
    public struct Knob: Equatable, Sendable {
        public let requested: Choice?
        public let invalid: Bool
        public init(requested: Choice?, invalid: Bool) {
            self.requested = requested
            self.invalid = invalid
        }
    }

    /// nil or empty -> unset; `default` / `p3` (case-insensitive, surrounding whitespace ignored); anything else ->
    /// `p3`, `invalid`.
    public static func parse(_ raw: String?) -> Knob {
        let t = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        switch t {
        case "": return Knob(requested: nil, invalid: false)
        case "default": return Knob(requested: .default, invalid: false)
        case "p3": return Knob(requested: .p3, invalid: false)
        default: return Knob(requested: .p3, invalid: true)
        }
    }

    public static func parse(env: [String: String]) -> Knob { parse(env[envKey]) }

    /// The primaries a display is created with. Only an HDR display (`transferRequested != 0`) ever gets P3: an SDR
    /// display keeps the descriptor defaults whatever the knob says. `default` switches P3 off for HDR.
    public static func decide(transferRequested: UInt32, knob: Knob) -> Choice {
        guard transferRequested != 0 else { return .default }
        return knob.requested == .default ? .default : .p3
    }

    /// A CIE 1931 xy chromaticity.
    public struct Point: Equatable, Sendable {
        public let x: Double
        public let y: Double
        public init(x: Double, y: Double) {
            self.x = x
            self.y = y
        }
    }

    /// Display P3 (DCI-P3 primaries, D65 white): the values Sidecar's descriptor gets (research 2026-10-06 section 2b).
    public static let p3Red = Point(x: 0.68, y: 0.32)
    public static let p3Green = Point(x: 0.265, y: 0.69)
    public static let p3Blue = Point(x: 0.15, y: 0.06)
    public static let p3White = Point(x: 0.3127, y: 0.329)

    /// One descriptor property: the KVC key (`CGVirtualDisplayDescriptor`) and the value (a `CGPoint` of x/y).
    public struct Property: Equatable, Sendable {
        public let key: String
        public let value: Point
        /// The setter selector name KVC uses, e.g. `setRedPrimary:`.
        public var setterName: String { "set" + key.prefix(1).uppercased() + key.dropFirst() + ":" }
    }

    /// The four properties to set, in order, for `p3`; none for `default`.
    public static func properties(for choice: Choice) -> [Property] {
        switch choice {
        case .default:
            return []
        case .p3:
            return [Property(key: "redPrimary", value: p3Red), Property(key: "greenPrimary", value: p3Green),
                    Property(key: "bluePrimary", value: p3Blue), Property(key: "whitePoint", value: p3White)]
        }
    }

    /// Why requested primaries were not given to the descriptor (the display is created without them).
    public enum FallbackReason: String, Equatable, Sendable {
        /// The descriptor does not respond to one of the four setters.
        case selectorMissing = "selector_missing"
    }

    /// What the descriptor ends up with, for `ev=vd_transfer`.
    public struct Applied: Equatable, Sendable {
        /// The primaries given to the descriptor (`default` also when P3 was wanted but a setter is missing).
        public let choice: Choice
        public let fallback: FallbackReason?
        /// The knob held an invalid value (treated as `p3`).
        public let invalidKnob: Bool

        public init(choice: Choice, fallback: FallbackReason? = nil, invalidKnob: Bool = false) {
            self.choice = choice
            self.fallback = fallback
            self.invalidKnob = invalidKnob
        }

        /// The pre-T-281 creation: nothing set, nothing wrong.
        public static let none = Applied(choice: .default)
    }

    /// Resolves the wanted `choice` against the setters the descriptor has (`respondsTo` takes a setter selector
    /// name). All four must exist, otherwise the display is created without primaries.
    public static func resolve(choice: Choice, invalidKnob: Bool, respondsTo: (String) -> Bool) -> Applied {
        let missing = properties(for: choice).contains { !respondsTo($0.setterName) }
        return missing ? Applied(choice: .default, fallback: .selectorMissing, invalidKnob: invalidKnob)
            : Applied(choice: choice, invalidKnob: invalidKnob)
    }

    /// `primaries=<default|p3> [primaries_fallback=<r>] [primaries_reason=invalid_value]`.
    public static func logFields(_ applied: Applied) -> String {
        var f = "primaries=\(applied.choice.rawValue)"
        if let r = applied.fallback { f += " primaries_fallback=\(r.rawValue)" }
        if applied.invalidKnob { f += " primaries_reason=invalid_value" }
        return f
    }
}
