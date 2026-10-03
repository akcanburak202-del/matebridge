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

/// `MATEBRIDGE_SERVICE_CLASS=off|video|signaling` (T-088, default flipped to `signaling` in T-124). `signaling` (the
/// default) puts the control connection (input, BYE, AUDIO_FRAME) in Wi-Fi's voice access category and video in the
/// video one; on Wi-Fi it removed the > 100 ms audio gaps under load (NOTES 2026-10-02). `off` leaves the service
/// class of both listeners unset, which is the behaviour before T-088. Over USB (adb tunnel, loopback) it has no
/// effect.
public enum ServiceClassKnob: String, Equatable, Sendable, CaseIterable {
    case off
    /// Video `.interactiveVideo`, control `.responsiveData`.
    case video
    /// Video `.interactiveVideo`, control `.interactiveVoice` (the control connection carries input, BYE and audio).
    case signaling

    public static let defaultValue = ServiceClassKnob.signaling

    /// Case-insensitive; anything else (or nil) is `defaultValue` (`.signaling`). Only an explicit `off` leaves the
    /// classes unset.
    public static func parse(_ text: String?) -> ServiceClassKnob {
        guard let t = text?.trimmingCharacters(in: .whitespaces).lowercased(), let k = ServiceClassKnob(rawValue: t)
        else { return defaultValue }
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

/// `MATEBRIDGE_NOTSENT_LOWAT_KB` (T-091): the `TCP_NOTSENT_LOWAT` of a `bsd` video connection, in KiB. While the
/// kernel holds at least this many bytes not yet sent, the socket is not writable and no new frame is taken.
public enum NotSentLowatKnob {
    public static let defaultKB = 128
    public static let minKB = 16
    public static let maxKB = 4096

    /// Whole KiB within `minKB...maxKB`; anything else (or nil) is `defaultKB`.
    public static func parseKB(_ text: String?) -> Int {
        guard let t = text?.trimmingCharacters(in: .whitespaces), let kb = Int(t), (minKB...maxKB).contains(kb)
        else { return defaultKB }
        return kb
    }

    public static func parseKB(_ env: [String: String]) -> Int { parseKB(env["MATEBRIDGE_NOTSENT_LOWAT_KB"]) }
}

/// The video socket settings, read once at start. The video and control connections are always kernel BSD sockets
/// (`BsdTcpListener`/`BsdTcpConnection`): the Network.framework (`nw`) stack and its `MATEBRIDGE_VIDEO_SOCKET` /
/// `MATEBRIDGE_CONTROL_SOCKET` knobs were retired in T-186 (decision 0026; `nw` capped at ~27 Mbps with retransmits
/// on Wi-Fi, T-091). Those variables are no longer read.
public struct VideoSocketSettings: Equatable, Sendable {
    public var notSentLowatKB: Int

    public init(notSentLowatKB: Int = NotSentLowatKnob.defaultKB) {
        self.notSentLowatKB = notSentLowatKB
    }

    public static func parse(_ env: [String: String]) -> VideoSocketSettings {
        VideoSocketSettings(notSentLowatKB: NotSentLowatKnob.parseKB(env))
    }

    public var notSentLowatBytes: Int { notSentLowatKB * 1024 }

    /// For `ev=listening`: `video_socket=bsd notsent_lowat_kb=128` (default). `video_socket` is constant since T-186.
    public var logFields: String { "video_socket=bsd notsent_lowat_kb=\(notSentLowatKB)" }
}
