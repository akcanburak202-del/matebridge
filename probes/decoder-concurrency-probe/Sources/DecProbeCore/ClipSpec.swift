import Foundation

/// Bit depth and colour signalling of a clip.
public enum ClipDepth: String, Sendable, CaseIterable {
    /// HEVC Main 8-bit, BT.709 (what MateBridge streams today).
    case b8 = "8"
    /// HEVC Main10, BT.709 (SDR with 10-bit precision).
    case sdr10 = "10sdr"
    /// HEVC Main10, BT.2020 / SMPTE ST 2084 PQ, with mastering-display and content-light-level SEI (HDR10).
    case pq10 = "10pq"

    public var bitDepth: Int { self == .b8 ? 8 : 10 }
    /// `general_profile_idc` the SPS must carry (1 = Main, 2 = Main10).
    public var profileIdc: Int { self == .b8 ? 1 : 2 }
    /// VUI colour description (ISO 23091-2 code points): primaries, transfer, matrix.
    public var colour: (primaries: Int, transfer: Int, matrix: Int) {
        self == .pq10 ? (9, 16, 9) : (1, 1, 1)
    }
}

/// One test clip: a crop of the full 2800x1840 scene, encoded on its own. The half and quarter clips are crops of the
/// same frames, so decoding `half` + `half_right` side by side is exactly the "split the screen in two" scenario.
public struct ClipSpec: Equatable, Sendable {
    /// Short id the Android probe uses in scenario names (`full`, `half`, `half_right`, `quarter`).
    public let id: String
    /// Crop origin in the full scene, in pixels.
    public let x: Int
    public let y: Int
    public let width: Int
    public let height: Int
    public let bitrateKbps: Int
    public let depth: ClipDepth
    /// IDR every N frames; 0 = a single IDR at frame 0.
    public let idrInterval: Int

    public init(id: String, x: Int, y: Int, width: Int, height: Int, bitrateKbps: Int, depth: ClipDepth = .b8,
                idrInterval: Int = 0) {
        self.id = id
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.bitrateKbps = bitrateKbps
        self.depth = depth
        self.idrInterval = idrInterval
    }

    /// `<id>_<W>x<H>_<depth>_<N>m[_idr<K>].h265`, e.g. `full_2800x1840_10pq_100m.h265`. The Android probe reads the
    /// decode size, depth, bitrate and IDR interval from this name; its scenario clip id is the name without the size
    /// (`full_10pq_100m`).
    public var fileName: String {
        var n = "\(id)_\(width)x\(height)_\(depth.rawValue)_\(Int((Double(bitrateKbps) / 1000).rounded()))m"
        if idrInterval > 0 { n += "_idr\(idrInterval)" }
        return n + ".h265"
    }

    public static let sceneWidth = 2800
    public static let sceneHeight = 1840

    /// The clip set for a full-frame bitrate (MateBridge's 120 fps default is 60 Mbps). Crops get the bitrate in
    /// proportion to their area, i.e. the same bits per pixel as the full clip.
    public static func standard(fullBitrateKbps: Int = 60_000, depth: ClipDepth = .b8, idrInterval: Int = 0)
        -> [ClipSpec] {
        let w = sceneWidth, h = sceneHeight
        func spec(_ id: String, _ x: Int, _ y: Int, _ cw: Int, _ ch: Int) -> ClipSpec {
            let kbps = Int((Double(fullBitrateKbps) * Double(cw * ch) / Double(w * h)).rounded())
            return ClipSpec(id: id, x: x, y: y, width: cw, height: ch, bitrateKbps: kbps, depth: depth,
                            idrInterval: idrInterval)
        }
        return [
            spec("full", 0, 0, w, h),
            spec("half", 0, 0, w / 2, h),
            spec("half_right", w / 2, 0, w / 2, h),
            spec("quarter", 0, 0, w / 2, h / 2),
        ]
    }
}

/// One encoding variant of a crop: depth, full-frame bitrate, optional IDR interval. Text form `DEPTH@MBPS[/idrN]`
/// (`10pq@100`, `8@60/idr60`).
public struct ClipVariant: Equatable, Sendable {
    public let depth: ClipDepth
    public let mbps: Int
    public let idrInterval: Int

    public init(depth: ClipDepth, mbps: Int, idrInterval: Int = 0) {
        self.depth = depth
        self.mbps = mbps
        self.idrInterval = idrInterval
    }

    public static func parse(_ token: String) -> ClipVariant? {
        let t = token.trimmingCharacters(in: .whitespaces)
        let parts = t.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count <= 2 else { return nil }
        let head = parts[0].split(separator: "@", omittingEmptySubsequences: false).map(String.init)
        guard head.count == 2, let depth = ClipDepth(rawValue: head[0]), let mbps = Int(head[1]), mbps > 0
        else { return nil }
        var idr = 0
        if parts.count == 2 {
            guard parts[1].hasPrefix("idr"), let n = Int(parts[1].dropFirst(3)), n > 0 else { return nil }
            idr = n
        }
        return ClipVariant(depth: depth, mbps: mbps, idrInterval: idr)
    }

    /// Default set (T-249): full frame in 8 / 10sdr / 10pq at 60 Mbps, 8 and 10pq at 80 / 100 / 150 Mbps, and the 8-bit
    /// 60 Mbps clip with an IDR every 60 frames.
    public static let defaultSet: [ClipVariant] = [
        ClipVariant(depth: .b8, mbps: 60), ClipVariant(depth: .sdr10, mbps: 60), ClipVariant(depth: .pq10, mbps: 60),
        ClipVariant(depth: .b8, mbps: 80), ClipVariant(depth: .b8, mbps: 100), ClipVariant(depth: .b8, mbps: 150),
        ClipVariant(depth: .pq10, mbps: 80), ClipVariant(depth: .pq10, mbps: 100), ClipVariant(depth: .pq10, mbps: 150),
        ClipVariant(depth: .b8, mbps: 60, idrInterval: 60),
    ]

    /// Comma list; nil if any token is malformed.
    public static func parseList(_ s: String) -> [ClipVariant]? {
        var out: [ClipVariant] = []
        for tok in s.split(separator: ",") {
            guard let v = ClipVariant.parse(String(tok)) else { return nil }
            out.append(v)
        }
        return out.isEmpty ? nil : out
    }
}

/// Bit-rate bookkeeping for generated clips.
public enum Realized {
    /// Realized Mbps of a clip of `bytes` bytes and `frames` frames at the rate-control frame rate `fps`.
    public static func mbps(bytes: Int, frames: Int, fps: Int) -> Double {
        guard frames > 0 else { return 0 }
        return Double(bytes) * 8 * Double(fps) / Double(frames) / 1e6
    }

    /// Relative deviation from the target (0.1 = 10 % above).
    public static func deviation(actualMbps: Double, targetKbps: Int) -> Double {
        guard targetKbps > 0 else { return 0 }
        return actualMbps / (Double(targetKbps) / 1000) - 1
    }

    /// Clips further than this from their target are flagged OFF-TARGET.
    public static let tolerance = 0.15
    public static func isOffTarget(_ deviation: Double) -> Bool { abs(deviation) > tolerance }
}

/// HEVC SEI payloads for HDR10 (`kVTCompressionPropertyKey_MasteringDisplayColorVolume` / `ContentLightLevelInfo`).
/// Same values as the hdr-probe (Display P3 D65 mastering, 1000 nits).
public enum HDR10SEI {
    /// `mastering_display_colour_volume`: 24 bytes big endian, primaries in G, B, R order (0.00002 units), white
    /// point, max / min luminance (0.0001 cd/m^2).
    public static func mdcv() -> [UInt8] {
        func c(_ v: Double) -> UInt16 { UInt16((v / 0.00002).rounded()) }
        var d: [UInt8] = []
        func u16(_ v: UInt16) { d += [UInt8(v >> 8), UInt8(v & 0xff)] }
        func u32(_ v: UInt32) { d += [UInt8(v >> 24), UInt8((v >> 16) & 0xff), UInt8((v >> 8) & 0xff), UInt8(v & 0xff)] }
        for p in [(0.265, 0.690), (0.150, 0.060), (0.680, 0.320), (0.3127, 0.3290)] { u16(c(p.0)); u16(c(p.1)) }
        u32(10_000_000)   // 1000 nits
        u32(1)            // 0.0001 nits
        return d
    }

    /// `content_light_level_info`: MaxCLL 1000, MaxFALL 400.
    public static func cll() -> [UInt8] { [0x03, 0xE8, 0x01, 0x90] }

    /// Prefix SEI NAL units (type 39, header 0x4E 0x01, emulation prevention applied; no start codes) carrying the two
    /// messages. VideoToolbox keeps HDR10 metadata in the format description, not in the sample data, so the clip
    /// writer puts these in front of every IDR (as a live HDR10 stream would carry them).
    public static func nalUnits() -> [[UInt8]] {
        func nal(type: UInt8, payload: [UInt8]) -> [UInt8] {
            [0x4E, 0x01] + AnnexB.escapeEmulation([type, UInt8(payload.count)] + payload + [0x80])
        }
        return [nal(type: 137, payload: mdcv()), nal(type: 144, payload: cll())]
    }
}

/// `--key value` / `--flag` command-line options.
public struct ProbeArgs {
    public let options: [String: String]
    public let flags: Set<String>

    public init(_ argv: [String]) {
        var o: [String: String] = [:]
        var f: Set<String> = []
        var i = 0
        while i < argv.count {
            let a = argv[i]
            if a.hasPrefix("--") {
                let key = String(a.dropFirst(2))
                if i + 1 < argv.count, !argv[i + 1].hasPrefix("--") {
                    o[key] = argv[i + 1]
                    i += 2
                    continue
                }
                f.insert(key)
            }
            i += 1
        }
        options = o
        flags = f
    }

    public func int(_ key: String, _ def: Int) -> Int { options[key].flatMap { Int($0) } ?? def }
    public func string(_ key: String, _ def: String) -> String { options[key] ?? def }
    public func flag(_ key: String) -> Bool { flags.contains(key) }
}
