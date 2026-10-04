/// 8-bit bi-planar 4:2:0 pixel formats the probe feeds the encoder and asks the decoder for.
public enum YUVFormat: String, CaseIterable, Sendable {
    /// `kCVPixelFormatType_420YpCbCr8BiPlanarFullRange` (what ScreenCaptureKit delivers to MateBridge).
    case full = "420f"
    /// `kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange`.
    case video = "420v"

    /// The decoder output format whose range matches the bitstream's VUI flag: in it, decoded luma equals the coded
    /// sample values (no range conversion in the decoder).
    public static func matching(vuiFullRange: Bool) -> YUVFormat { vuiFullRange ? .full : .video }
}

/// Colour attachments on the input buffer.
public enum InputTags: String, Sendable {
    /// ScreenCaptureKit's tags (709/709/709 + sRGB CGColorSpace), retagged to the session's 709/sRGB/709 before
    /// encoding, exactly like `HEVCEncoder.retagForSession` (T-113).
    case sckRetagged = "sck->retag"
    /// ScreenCaptureKit's tags left as they are (before T-113): VideoToolbox converts to the session's colour space.
    case sck = "sck"
    /// No colour attachments at all.
    case none = "none"
}

/// One encode configuration of the probe.
public struct ProbeConfig: Equatable, Sendable {
    public var name: String
    public var input: YUVFormat
    public var tags: InputTags
    public var note: String

    public init(name: String, input: YUVFormat, tags: InputTags, note: String) {
        self.name = name; self.input = input; self.tags = tags; self.note = note
    }

    public static let all: [ProbeConfig] = [
        ProbeConfig(name: "prod", input: .full, tags: .sckRetagged, note: "production today (420f + T-113 retag)"),
        ProbeConfig(name: "noretag", input: .full, tags: .sck, note: "420f, SCK tags kept (pre-T-113)"),
        ProbeConfig(name: "420v-retag", input: .video, tags: .sckRetagged, note: "420v input, retagged"),
        ProbeConfig(name: "420v-noretag", input: .video, tags: .sck, note: "420v input, SCK tags kept"),
        ProbeConfig(name: "420f-untagged", input: .full, tags: .none, note: "420f, no colour attachments"),
    ]

    public static func named(_ name: String) -> ProbeConfig? { all.first { $0.name == name } }
}

/// One-line reading of a configuration's result (T-230 acceptance sentence).
public enum Verdict {
    /// Coded values within this many levels of the input count as unchanged.
    public static let tolerance = 1

    /// Index of the band holding reference black for `input` (Y=0 in 420f, Y=16 in 420v).
    public static func blackBand(_ input: YUVFormat) -> Int { Bands.values.firstIndex(of: input == .full ? 0 : 16)! }

    /// - Parameters:
    ///   - input: the input buffer's pixel format.
    ///   - vuiFullRange: SPS `video_full_range_flag` (nil = no VUI signal type, decoders assume limited).
    ///   - coded: per-band luma as coded in the bitstream (decoded in the VUI-matching format, `YUVFormat.matching`).
    public static func classify(input: YUVFormat, vuiFullRange: Bool?, coded: [UInt8]) -> String {
        let flag = vuiFullRange.map { $0 ? "full=1" : "full=0" } ?? "no VUI range"
        guard coded.count == Bands.values.count else { return "no measurement" }
        let b = blackBand(input)
        let black = "black (in Y=\(Bands.values[b])) coded Y=\(coded[b])"
        let flagMatches = (vuiFullRange ?? false) == (input == .full)
        let passThrough = zip(coded, Bands.values).allSatisfy { abs(Int($0) - Int($1)) <= tolerance }
        let blackKept = abs(Int(coded[b]) - Int(Bands.values[b])) <= tolerance
        guard flagMatches else { return "WRONG: \(flag) for \(input.rawValue) input, \(black)" }
        if passThrough { return "OK, pass-through (coded = input codes): \(black), \(flag)" }
        if blackKept { return "black OK but values converted (colour conversion before encoding): \(black), \(flag)" }
        return "WRONG: values converted and black moved: \(black), \(flag)"
    }
}

/// Command-line options.
public struct ProbeOptions: Equatable, Sendable {
    public var width = 2800
    public var height = 1840
    public var frames = 3
    public var bitrateKbps = 30_000
    public var fps = 60
    /// Output directory for the `.hevc` files; nil = `~/.cache/matebridge-tools/data/color-probe`.
    public var outDir: String?
    public var configs: [ProbeConfig] = ProbeConfig.all

    public init() {}

    public enum ParseError: Error, Equatable { case unknown(String), badValue(String), unknownConfig(String) }

    public static func parse(_ args: [String]) -> Result<ProbeOptions, ParseError> {
        var o = ProbeOptions()
        var i = 0
        func value() -> String? { i + 1 < args.count ? args[i + 1] : nil }
        while i < args.count {
            let a = args[i]
            switch a {
            case "--size":
                let parts = value()?.split(separator: "x").compactMap { Int($0) } ?? []
                guard parts.count == 2, parts[0] > 0, parts[1] > 0, parts[0] % 2 == 0, parts[1] % 2 == 0 else {
                    return .failure(.badValue(a))
                }
                o.width = parts[0]; o.height = parts[1]; i += 2
            case "--frames", "--bitrate-kbps", "--fps":
                guard let v = value().flatMap({ Int($0) }), v > 0 else { return .failure(.badValue(a)) }
                if a == "--frames" { o.frames = v } else if a == "--fps" { o.fps = v } else { o.bitrateKbps = v }
                i += 2
            case "--out":
                guard let v = value() else { return .failure(.badValue(a)) }
                o.outDir = v; i += 2
            case "--only":
                guard let v = value() else { return .failure(.badValue(a)) }
                var picked: [ProbeConfig] = []
                for n in v.split(separator: ",") {
                    guard let c = ProbeConfig.named(String(n)) else { return .failure(.unknownConfig(String(n))) }
                    picked.append(c)
                }
                o.configs = picked; i += 2
            default:
                return .failure(.unknown(a))
            }
        }
        return .success(o)
    }
}
