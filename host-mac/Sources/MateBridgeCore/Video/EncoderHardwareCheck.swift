import Foundation

/// Did VideoToolbox pick the hardware encoder (T-187)? The host asks for it with
/// `EnableHardwareAcceleratedVideoEncoder` (not `Require`, see NOTES T-046: the media engine can be shared), so a
/// software fallback is possible. This maps the session's `UsingHardwareAcceleratedVideoEncoder` read-back to the
/// `video ev=encoder_hw` log line and the menu warning.
public enum EncoderHardwareCheck: Equatable, Sendable {
    /// The session reports the hardware encoder.
    case hardware
    /// The session reports a software encoder: latency and CPU will be higher.
    case software
    /// The property could not be read: `status` is the `VTSessionCopyProperty` result (`0` when the call succeeded
    /// but returned no boolean value).
    case unknown(status: Int32)

    /// Log event name (`docs/LOGGING.md`).
    public static let event = "encoder_hw"

    /// - Parameters:
    ///   - usingHardware: the read-back value; nil when it was unreadable (non-`noErr` status or a missing value).
    ///   - status: the read's `OSStatus`, used only when `usingHardware` is nil.
    public init(usingHardware: Bool?, status: Int32) {
        switch usingHardware {
        case true?: self = .hardware
        case false?: self = .software
        case nil: self = .unknown(status: status)
        }
    }

    /// Info for the hardware encoder; a warning otherwise, so a slow session can be explained at a glance.
    public var logLevel: LogLevel {
        self == .hardware ? .info : .warning
    }

    /// `using_hw=1`, `using_hw=0` or `using_hw=unknown status=<OSStatus>`.
    public var logFields: String {
        switch self {
        case .hardware: return "using_hw=1"
        case .software: return "using_hw=0"
        case .unknown(let status): return "using_hw=unknown status=\(status)"
        }
    }

    /// Short warning for the menu summary line; nil for the hardware encoder (nothing to show).
    public var menuText: String? {
        switch self {
        case .hardware: return nil
        case .software: return "yazılım kodlayıcı"
        case .unknown: return "kodlayıcı türü bilinmiyor"
        }
    }
}
