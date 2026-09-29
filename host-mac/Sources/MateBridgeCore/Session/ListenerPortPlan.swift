import Foundation

/// Default listener ports (PROTOCOL.md section 3.1). Fixed so `adb reverse` works without port discovery.
public enum DefaultPorts {
    public static let control: UInt16 = 47001
    public static let video: UInt16 = 47002
}

/// Port choice for one listener: the preferred port first, then a system-assigned port (0) when the
/// preferred one is taken. Pure so the fallback order is unit-testable without sockets.
public struct ListenerPortPlan: Equatable, Sendable {
    public let preferred: UInt16
    private var step = 0

    /// `preferred == 0` means "system-assigned only".
    public init(preferred: UInt16) { self.preferred = preferred }

    /// The next port to try, or nil when every option has failed. 0 means any port.
    public mutating func nextPort() -> UInt16? {
        defer { step += 1 }
        switch step {
        case 0: return preferred
        case 1 where preferred != 0: return 0
        default: return nil
        }
    }

    /// True when the most recently returned port was the preferred fixed one (a failure there falls back).
    public var lastWasPreferred: Bool { step == 1 && preferred != 0 }
}
