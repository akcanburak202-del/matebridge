import Foundation

extension SessionTransport {
    /// Name used in logs (`transport=usb|wifi`). Every non-loopback peer is reported as `wifi` (T-088).
    public var logName: String {
        switch self {
        case .usb: return "usb"
        case .network: return "wifi"
        }
    }
}

/// Network service class of a connection, independent of Network.framework (the host maps it to
/// `NWParameters.ServiceClass`). On Wi-Fi it selects the WMM access category of the outgoing packets.
public enum TrafficClass: String, Equatable, Sendable {
    case interactiveVideo
    case interactiveVoice
    case responsiveData
}

/// `MATEBRIDGE_SERVICE_CLASS=off|video|signaling` (T-088). `off` (the default) leaves the service class of both
/// listeners unset, which is the behaviour before T-088.
public enum ServiceClassKnob: String, Equatable, Sendable, CaseIterable {
    case off
    /// Video `.interactiveVideo`, control `.responsiveData`.
    case video
    /// Video `.interactiveVideo`, control `.interactiveVoice` (the control connection carries input and BYE).
    case signaling

    /// Case-insensitive; anything else (or nil) is `.off`.
    public static func parse(_ text: String?) -> ServiceClassKnob {
        guard let t = text?.trimmingCharacters(in: .whitespaces).lowercased(), let k = ServiceClassKnob(rawValue: t)
        else { return .off }
        return k
    }

    public static func parse(_ env: [String: String]) -> ServiceClassKnob { parse(env["MATEBRIDGE_SERVICE_CLASS"]) }

    /// Service class of the video listener (nil: leave unset).
    public var videoClass: TrafficClass? {
        switch self {
        case .off: return nil
        case .video, .signaling: return .interactiveVideo
        }
    }

    /// Service class of the control listener (nil: leave unset).
    public var controlClass: TrafficClass? {
        switch self {
        case .off: return nil
        case .video: return .responsiveData
        case .signaling: return .interactiveVoice
        }
    }

    /// Log fields: `service_class=off` or `service_class=video video_class=interactiveVideo control_class=…`.
    public var logFields: String {
        guard self != .off else { return "service_class=off" }
        return "service_class=\(rawValue) video_class=\(videoClass?.rawValue ?? "unset") "
            + "control_class=\(controlClass?.rawValue ?? "unset")"
    }
}

/// Whether the video connection's kernel send queue is sampled and logged (`ev=sendq`, T-088):
/// `MATEBRIDGE_SENDQ_LOG=1` or `MATEBRIDGE_LAT_TRACE=1`.
public enum SendQueueLogKnob {
    public static func isEnabled(_ env: [String: String]) -> Bool {
        func on(_ key: String) -> Bool { env[key]?.trimmingCharacters(in: .whitespaces) == "1" }
        return on("MATEBRIDGE_SENDQ_LOG") || on("MATEBRIDGE_LAT_TRACE")
    }
}
