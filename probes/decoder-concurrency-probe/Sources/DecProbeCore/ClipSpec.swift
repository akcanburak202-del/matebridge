import Foundation

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

    public init(id: String, x: Int, y: Int, width: Int, height: Int, bitrateKbps: Int) {
        self.id = id
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.bitrateKbps = bitrateKbps
    }

    /// `<id>_<W>x<H>.h265`; the Android probe reads the decode size from this name.
    public var fileName: String { "\(id)_\(width)x\(height).h265" }

    public static let sceneWidth = 2800
    public static let sceneHeight = 1840

    /// The clip set for a full-frame bitrate (MateBridge's 120 fps default is 60 Mbps). Crops get the bitrate in
    /// proportion to their area, i.e. the same bits per pixel as the full clip.
    public static func standard(fullBitrateKbps: Int = 60_000) -> [ClipSpec] {
        let w = sceneWidth, h = sceneHeight
        func spec(_ id: String, _ x: Int, _ y: Int, _ cw: Int, _ ch: Int) -> ClipSpec {
            let kbps = Int((Double(fullBitrateKbps) * Double(cw * ch) / Double(w * h)).rounded())
            return ClipSpec(id: id, x: x, y: y, width: cw, height: ch, bitrateKbps: kbps)
        }
        return [
            spec("full", 0, 0, w, h),
            spec("half", 0, 0, w / 2, h),
            spec("half_right", w / 2, 0, w / 2, h),
            spec("quarter", 0, 0, w / 2, h / 2),
        ]
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
