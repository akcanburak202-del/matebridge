import Foundation

/// SMPTE ST 2084 (PQ). Signal 0...1 <-> absolute luminance 0...10000 cd/m².
public enum PQ {
    static let m1 = 2610.0 / 16384
    static let m2 = 2523.0 / 4096 * 128
    static let c1 = 3424.0 / 4096
    static let c2 = 2413.0 / 4096 * 32
    static let c3 = 2392.0 / 4096 * 32

    /// Inverse EOTF: luminance in nits -> non-linear signal 0...1.
    public static func encode(nits: Double) -> Double {
        let y = max(0, min(nits, 10_000)) / 10_000
        let p = pow(y, m1)
        return pow((c1 + c2 * p) / (1 + c3 * p), m2)
    }

    /// EOTF: non-linear signal 0...1 -> luminance in nits.
    public static func decode(_ signal: Double) -> Double {
        let e = pow(max(0, min(signal, 1)), 1 / m2)
        return pow(max(e - c1, 0) / (c2 - c3 * e), 1 / m1) * 10_000
    }
}

/// ARIB STD-B67 / BT.2100 HLG OETF (scene-referred, relative 0...1).
public enum HLG {
    static let a = 0.17883277
    static let b = 1 - 4 * a
    static let c = 0.5 - a * log(4 * a)

    public static func oetf(_ e: Double) -> Double {
        let x = max(0, min(e, 1))
        return x <= 1.0 / 12 ? (3 * x).squareRoot() : a * log(12 * x - b) + c
    }
}

/// 10-bit luma code helpers. CoreVideo stores 10-bit samples in the high bits of 16-bit words (value << 6).
public enum Luma10 {
    /// Video (limited) range: 64...940.
    public static func videoRange(_ signal: Double) -> UInt16 { UInt16((64 + 876 * max(0, min(signal, 1))).rounded()) }
    public static func signal(videoRange code: UInt16) -> Double { (Double(code) - 64) / 876 }
    /// Full range: 0...1023.
    public static func signal(fullRange code: UInt16) -> Double { Double(code) / 1023 }
    public static let chromaNeutral: UInt16 = 512
}

/// CIE 1931 xy chromaticity.
public struct XY: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public init(_ x: Double, _ y: Double) { self.x = x; self.y = y }
}

/// HDR10 static metadata (SMPTE ST 2086 mastering display + CTA-861.3 content light level).
public struct HDR10Static: Equatable, Sendable {
    public var red: XY
    public var green: XY
    public var blue: XY
    public var white: XY
    /// cd/m².
    public var maxMasteringNits: Double
    /// cd/m².
    public var minMasteringNits: Double
    public var maxCLL: UInt16
    public var maxFALL: UInt16

    public init(red: XY, green: XY, blue: XY, white: XY, maxMasteringNits: Double, minMasteringNits: Double,
                maxCLL: UInt16, maxFALL: UInt16) {
        self.red = red; self.green = green; self.blue = blue; self.white = white
        self.maxMasteringNits = maxMasteringNits; self.minMasteringNits = minMasteringNits
        self.maxCLL = maxCLL; self.maxFALL = maxFALL
    }

    /// Display P3 (D65) mastering, 1000 nits peak: a common HDR10 grading target and the tablet's gamut.
    public static let p3D65_1000 = HDR10Static(
        red: XY(0.680, 0.320), green: XY(0.265, 0.690), blue: XY(0.150, 0.060), white: XY(0.3127, 0.3290),
        maxMasteringNits: 1000, minMasteringNits: 0.0001, maxCLL: 1000, maxFALL: 400)

    private static func chroma(_ v: Double) -> UInt16 { UInt16((v / 0.00002).rounded()) }

    /// HEVC SEI `mastering_display_colour_volume` payload: 24 bytes big-endian, primaries in G, B, R order,
    /// chromaticity in 0.00002 units, luminance in 0.0001 cd/m². This is the layout VideoToolbox expects for
    /// `kVTCompressionPropertyKey_MasteringDisplayColorVolume`.
    public func mdcvSEI() -> Data {
        var d = Data()
        func u16(_ v: UInt16) { d.append(UInt8(v >> 8)); d.append(UInt8(v & 0xff)) }
        func u32(_ v: UInt32) { for s in [24, 16, 8, 0] { d.append(UInt8((v >> UInt32(s)) & 0xff)) } }
        for p in [green, blue, red] { u16(Self.chroma(p.x)); u16(Self.chroma(p.y)) }
        u16(Self.chroma(white.x)); u16(Self.chroma(white.y))
        u32(UInt32((maxMasteringNits * 10_000).rounded()))
        u32(UInt32((minMasteringNits * 10_000).rounded()))
        return d
    }

    /// HEVC SEI `content_light_level_info` payload: MaxCLL, MaxFALL as big-endian u16
    /// (`kVTCompressionPropertyKey_ContentLightLevelInfo`).
    public func cllSEI() -> Data {
        Data([UInt8(maxCLL >> 8), UInt8(maxCLL & 0xff), UInt8(maxFALL >> 8), UInt8(maxFALL & 0xff)])
    }
}

public enum Stats {
    /// Nearest-rank percentile (p in 0...100). Empty input -> 0.
    public static func percentile(_ values: [Double], _ p: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let s = values.sorted()
        let rank = Int((p / 100 * Double(s.count)).rounded(.up)) - 1
        return s[max(0, min(rank, s.count - 1))]
    }
}

/// `hdr-probe <command> [--key value | --flag]...`
public struct ProbeArgs: Equatable, Sendable {
    public var command: String
    public var options: [String: String]

    public init(_ argv: [String]) {
        command = argv.first ?? "help"
        options = [:]
        var i = 1
        while i < argv.count {
            let a = argv[i]
            if a.hasPrefix("--") {
                let key = String(a.dropFirst(2))
                if i + 1 < argv.count, !argv[i + 1].hasPrefix("--") {
                    options[key] = argv[i + 1]; i += 2
                } else {
                    options[key] = "1"; i += 1
                }
            } else {
                i += 1
            }
        }
    }

    public func int(_ key: String, _ def: Int) -> Int { options[key].flatMap(Int.init) ?? def }
    public func double(_ key: String, _ def: Double) -> Double { options[key].flatMap(Double.init) ?? def }
    public func flag(_ key: String) -> Bool { options[key] != nil }

    /// "2800x1840" -> (2800, 1840).
    public func size(_ key: String, _ def: (Int, Int)) -> (Int, Int) {
        guard let s = options[key] else { return def }
        let parts = s.lowercased().split(separator: "x").compactMap { Int($0) }
        return parts.count == 2 ? (parts[0], parts[1]) : def
    }
}
