import Foundation

/// One encoder configuration tried by `--encode-bench` (pure data; the host maps it to VideoToolbox properties).
public struct EncodeBenchConfig: Equatable, Sendable {
    public var name: String
    /// nil = do not set the property.
    public var realTime: Bool? = true
    public var maximizePowerEfficiency: Bool? = nil
    public var lowLatencyRateControl = true
    public var prioritizeSpeed = true
    public var expectedFps: Int? = nil   // nil = the bench fps
    public var main10 = false
    public var bitrateKbps = 30_000
    public var sessions = 1
    /// Frames allowed inside one session at a time.
    public var inFlight = 3
    /// Set a DataRateLimits cap of 2x the average (what `HEVCEncoder` does today).
    public var dataRateLimits = true
    /// `kVTCompressionPropertyKey_Quality` instead of `AverageBitRate` (T-086; the DataRateLimits cap stays).
    public var quality: Double? = nil

    public init(name: String) { self.name = name }

    /// Named catalog. "baseline" mirrors `HEVCEncoder` today.
    public static let catalog: [EncodeBenchConfig] = {
        var all: [EncodeBenchConfig] = []
        func add(_ n: String, _ f: (inout EncodeBenchConfig) -> Void) {
            var c = EncodeBenchConfig(name: n); f(&c); all.append(c)
        }
        add("baseline") { _ in }
        // T-053: the two app profiles at the app's in-flight depth.
        add("llrc") { $0.inFlight = 2 }
        add("fast") { $0.lowLatencyRateControl = false; $0.realTime = false; $0.inFlight = 2 }
        add("realtime-off") { $0.realTime = false }
        add("realtime-unset") { $0.realTime = nil }
        add("power-off") { $0.maximizePowerEfficiency = false }
        add("no-lowlat") { $0.lowLatencyRateControl = false }
        add("fps120") { $0.expectedFps = 120 }
        add("main10") { $0.main10 = true }
        add("no-prioritize") { $0.prioritizeSpeed = false }
        add("no-ratelimit") { $0.dataRateLimits = false }
        add("br20") { $0.bitrateKbps = 20_000 }
        add("br50") { $0.bitrateKbps = 50_000 }
        add("dual") { $0.sessions = 2 }
        add("dual-fps120") { $0.sessions = 2; $0.expectedFps = 120 }
        add("combo") {
            $0.realTime = false; $0.maximizePowerEfficiency = false; $0.expectedFps = 120; $0.lowLatencyRateControl = false
        }
        add("nolat-fps120") { $0.lowLatencyRateControl = false; $0.expectedFps = 120 }
        add("nolat-rtoff") { $0.lowLatencyRateControl = false; $0.realTime = false }
        // T-086: `.fast` (the app profile) with the quality knobs.
        add("nolat-rtoff-noprio") { $0.lowLatencyRateControl = false; $0.realTime = false; $0.prioritizeSpeed = false }
        add("nolat-rtoff-q80") { $0.lowLatencyRateControl = false; $0.realTime = false; $0.quality = 0.8 }
        add("nolat-power-off") { $0.lowLatencyRateControl = false; $0.maximizePowerEfficiency = false }
        add("nolat-fps120-rtoff") { $0.lowLatencyRateControl = false; $0.expectedFps = 120; $0.realTime = false }
        add("nolat-fps120-inflight1") { $0.lowLatencyRateControl = false; $0.expectedFps = 120; $0.inFlight = 1 }
        add("nolat-fps120-inflight6") { $0.lowLatencyRateControl = false; $0.expectedFps = 120; $0.inFlight = 6 }
        add("nolat-rtoff-inflight2") { $0.lowLatencyRateControl = false; $0.realTime = false; $0.inFlight = 2 }
        add("baseline-inflight1") { $0.inFlight = 1 }
        add("baseline-inflight6") { $0.inFlight = 6 }
        return all
    }()

    public static func named(_ name: String) -> EncodeBenchConfig? { catalog.first { $0.name == name } }
}

public enum EncodeBenchContent: String, Equatable, Sendable { case scroll, patch }

/// Colour tags on the bench's synthetic frames (T-113). `none`: untagged (the bench before T-113). `sck`: what
/// ScreenCaptureKit attaches (BT.709 primaries/transfer/matrix plus an sRGB `CGColorSpace`), which the app's
/// session (sRGB transfer) does not match, so VideoToolbox colour-converts them unless they are retagged.
public enum EncodeBenchInputTags: String, Equatable, Sendable { case none, sck }

/// Arguments of `MateBridgeApp --encode-bench [--fps N] [--seconds S] [--content scroll|patch]
/// [--input-tags none|sck] [--config NAME]...`.
public struct EncodeBenchOptions: Equatable, Sendable {
    public var fps = 120
    public var seconds = 5.0
    public var configs: [EncodeBenchConfig] = []
    /// `scroll`: whole frame moves every frame (worst case). `patch`: static screen with a small changing region
    /// (pen/typing-like, closer to typical use).
    public var content = EncodeBenchContent.scroll
    /// `MATEBRIDGE_CODEC` / `MATEBRIDGE_H264_PROFILE` (T-086).
    public var codec = Codec.hevc
    public var h264Profile = H264Profile.high
    /// `MATEBRIDGE_BITRATE_KBPS` (T-086): replaces every config's bitrate when set.
    public var bitrateOverrideKbps: Int?
    /// `--input-tags none|sck` (T-113).
    public var inputTags = EncodeBenchInputTags.none
    /// `MATEBRIDGE_INPUT_RETAG` (T-113): retag the frames to the session's colour tags before encoding, as the app does.
    public var retagInput = true

    public struct ParseError: Error, Equatable, Sendable { public let message: String }

    /// The codec knobs of the app (T-086): `MATEBRIDGE_CODEC`, `MATEBRIDGE_H264_PROFILE`, and
    /// `MATEBRIDGE_BITRATE_KBPS`, which replaces every config's bitrate.
    public func applyingEnvironment(_ env: [String: String]) -> EncodeBenchOptions {
        var o = self
        o.codec = VideoSettings.parseCodec(env["MATEBRIDGE_CODEC"])
        o.h264Profile = H264Profile.parse(env["MATEBRIDGE_H264_PROFILE"])
        o.bitrateOverrideKbps = VideoSettings.parseBitrateKbps(env["MATEBRIDGE_BITRATE_KBPS"])
        o.retagInput = InputRetag.isEnabled(env)
        if let b = o.bitrateOverrideKbps { for i in o.configs.indices { o.configs[i].bitrateKbps = b } }
        return o
    }

    /// nil when `--encode-bench` is absent. No `--config` means the whole catalog.
    public static func parse(_ args: [String]) -> Result<EncodeBenchOptions, ParseError>? {
        guard args.contains("--encode-bench") else { return nil }
        var o = EncodeBenchOptions()
        var j = 0
        while j < args.count {
            switch args[j] {
            case "--fps":
                guard j + 1 < args.count, let v = Int(args[j + 1]), (1...240).contains(v) else {
                    return .failure(ParseError(message: "--fps needs an integer 1...240"))
                }
                o.fps = v; j += 1
            case "--seconds":
                guard j + 1 < args.count, let v = Double(args[j + 1]), v > 0, v <= 600 else {
                    return .failure(ParseError(message: "--seconds needs a number in (0, 600]"))
                }
                o.seconds = v; j += 1
            case "--content":
                guard j + 1 < args.count, let v = EncodeBenchContent(rawValue: args[j + 1]) else {
                    return .failure(ParseError(message: "--content needs scroll|patch"))
                }
                o.content = v; j += 1
            case "--input-tags":
                guard j + 1 < args.count, let v = EncodeBenchInputTags(rawValue: args[j + 1]) else {
                    return .failure(ParseError(message: "--input-tags needs none|sck"))
                }
                o.inputTags = v; j += 1
            case "--config":
                guard j + 1 < args.count else { return .failure(ParseError(message: "--config needs a name")) }
                guard let c = EncodeBenchConfig.named(args[j + 1]) else {
                    return .failure(ParseError(message: "unknown config '\(args[j + 1])'"))
                }
                o.configs.append(c); j += 1
            default: break
            }
            j += 1
        }
        if o.configs.isEmpty { o.configs = EncodeBenchConfig.catalog }
        return .success(o)
    }
}
