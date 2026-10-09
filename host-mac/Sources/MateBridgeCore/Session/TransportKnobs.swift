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

/// `MATEBRIDGE_IP_TOS=off|ef|cs6|video=<v>,control=<v>` (T-326, default `off`): an explicit DSCP for the packets the
/// host sends, independent of `SO_NET_SERVICE_TYPE`. With `qosmarking mode: none` on the wired interface (the Mac on
/// Ethernet, `ifconfig -v en0`) the service type writes no DSCP, so a Wi-Fi access point sees video, audio and
/// control all as best effort. `ef` is video AF41 (0x88) and control EF (0xB8); `cs6` is video AF41 and control CS6
/// (0xC0). `video=` / `control=` take 0..255 (`0x..` hex or decimal); either may be left out (that listener stays
/// unset). The low two bits (ECN) are cleared. Anything unparsable falls back to `off` and sets `warning`.
public struct IpTosKnob: Equatable, Sendable {
    public static let videoAF41: UInt8 = 0x88
    public static let controlEF: UInt8 = 0xB8
    public static let controlCS6: UInt8 = 0xC0

    /// IP TOS byte (DSCP << 2) of the video listener's sockets; nil: unset.
    public var video: UInt8?
    /// IP TOS byte of the control listener's sockets (input, BYE, AUDIO_FRAME); nil: unset.
    public var control: UInt8?
    /// The rejected text (made log-safe) when the value could not be parsed.
    public var warning: String?

    public static let off = IpTosKnob(video: nil, control: nil, warning: nil)

    public init(video: UInt8?, control: UInt8?, warning: String? = nil) {
        self.video = video
        self.control = control
        self.warning = warning
    }

    public var isOff: Bool { video == nil && control == nil }

    public static func parse(_ env: [String: String]) -> IpTosKnob { parse(env["MATEBRIDGE_IP_TOS"]) }

    public static func parse(_ text: String?) -> IpTosKnob {
        guard let raw = text?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return .off }
        let t = raw.lowercased()
        switch t {
        case "off": return .off
        case "ef": return IpTosKnob(video: videoAF41, control: controlEF)
        case "cs6": return IpTosKnob(video: videoAF41, control: controlCS6)
        default: break
        }
        var video: UInt8?
        var control: UInt8?
        for part in t.split(separator: ",", omittingEmptySubsequences: false) {
            let kv = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard kv.count == 2, let v = parseByte(String(kv[1]).trimmingCharacters(in: .whitespaces)) else {
                return invalid(raw)
            }
            switch kv[0].trimmingCharacters(in: .whitespaces) {
            case "video" where video == nil: video = v & 0xFC
            case "control" where control == nil: control = v & 0xFC
            default: return invalid(raw)
            }
        }
        return IpTosKnob(video: video, control: control)
    }

    /// `off` plus the rejected text, reduced to `[A-Za-z0-9=,]` (anything else `_`) and cut to 40 characters.
    private static func invalid(_ raw: String) -> IpTosKnob {
        let safe = String(raw.unicodeScalars.prefix(40).map { c -> Character in
            let ch = Character(c)
            return c.isASCII && (ch.isLetter || ch.isNumber || ch == "=" || ch == ",") ? ch : "_"
        })
        return IpTosKnob(video: nil, control: nil, warning: safe)
    }

    /// Decimal or `0x` hex, 0...255.
    private static func parseByte(_ s: String) -> UInt8? {
        if s.hasPrefix("0x") { return UInt8(s.dropFirst(2), radix: 16) }
        return UInt8(s)
    }

    /// Log fields: `ip_tos=off`, `ip_tos=video=0x88,control=0xb8`, `ip_tos=video=0x88` (control unset), and
    /// ` ip_tos_invalid=<text>` after `ip_tos=off` when the value was rejected.
    public var logFields: String {
        var parts: [String] = []
        if let video { parts.append("video=0x" + Self.hex(video)) }
        if let control { parts.append("control=0x" + Self.hex(control)) }
        var out = "ip_tos=" + (parts.isEmpty ? "off" : parts.joined(separator: ","))
        if let warning { out += " ip_tos_invalid=\(warning)" }
        return out
    }

    private static func hex(_ v: UInt8) -> String {
        let h = String(v, radix: 16)
        return h.count == 1 ? "0" + h : h
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

    /// The setting in bytes.
    public static func bytes(_ env: [String: String]) -> Int { parseKB(env) * 1024 }
}

/// `MATEBRIDGE_WIFI_ADAPT=1` (T-328, decision 0023 branch (c)): the Wi-Fi video congestion controller (T-327) gates new
/// frames on the in-flight byte budget and follows its target bit rate live. Default off. Only `1` turns it on; absent
/// or anything else is off. Never active on USB: a `.usb` session never consults the knob.
public enum WifiAdaptKnob {
    public static let name = "MATEBRIDGE_WIFI_ADAPT"

    public static func isEnabled(_ env: [String: String]) -> Bool {
        env[name]?.trimmingCharacters(in: .whitespaces) == "1"
    }

    /// Whether a session over `transport` runs the controller: it is on the network and the knob is on.
    public static func isActive(_ env: [String: String], transport: SessionTransport) -> Bool {
        guard transport == .network else { return false }
        return isEnabled(env)
    }
}
