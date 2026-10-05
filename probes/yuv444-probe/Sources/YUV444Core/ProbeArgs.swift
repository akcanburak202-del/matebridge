import Foundation

/// `--key value` and `--flag` command line parsing (a value never starts with `--`).
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
    public func double(_ key: String, _ def: Double) -> Double { options[key].flatMap { Double($0) } ?? def }
    public func string(_ key: String, _ def: String) -> String { options[key] ?? def }
    public func flag(_ key: String) -> Bool { flags.contains(key) }
}

/// A `WIDTHxHEIGHT` frame size.
public struct FrameSize: Equatable, Sendable, CustomStringConvertible {
    public let width: Int
    public let height: Int
    public init(_ w: Int, _ h: Int) { width = w; height = h }
    public var description: String { "\(width)x\(height)" }
    public var pixels: Int { width * height }

    public static let full = FrameSize(2800, 1840)
    public static let reduced = FrameSize(1848, 1214)

    /// `"2800x1840,1848x1214"`; nil if any item is malformed or not packable (`AVC444v2.isValid`).
    public static func parseList(_ text: String) -> [FrameSize]? {
        var out: [FrameSize] = []
        for item in text.split(separator: ",") {
            let parts = item.split(separator: "x")
            guard parts.count == 2, let w = Int(parts[0]), let h = Int(parts[1]), AVC444v2.isValid(width: w, height: h)
            else { return nil }
            out.append(FrameSize(w, h))
        }
        return out.isEmpty ? nil : out
    }
}

/// The four sections of the test scene, in order; each is a quarter of the clip (`frames / 4`).
public enum ScenePhase: String, Sendable, CaseIterable {
    /// Nothing moves: the cost of holding a still desktop.
    case still
    /// One character appears per frame in the editor (small local changes, a caret).
    case typing
    /// The editor and the document panel scroll smoothly.
    case scroll
    /// A photo panel pans (sub-pixel motion), everything else is still.
    case video

    public static func of(frame: Int, frames: Int) -> ScenePhase {
        let q = max(1, frames / 4)
        return allCases[min(frame / q, 3)]
    }

    /// First frame of this phase in a clip of `frames` frames.
    public func start(frames: Int) -> Int { (ScenePhase.allCases.firstIndex(of: self) ?? 0) * max(1, frames / 4) }
}

/// File names and bitrates of the test clips (`main_<WxH>_<fps>.h265` / `aux_<WxH>_<fps>.h265`).
public enum ClipNaming {
    public static func mainName(_ s: FrameSize, fps: Int) -> String { "main_\(s)_\(fps).h265" }
    public static func auxName(_ s: FrameSize, fps: Int) -> String { "aux_\(s)_\(fps).h265" }
    public static func metaName(_ s: FrameSize, fps: Int) -> String { "yuv444_\(s)_\(fps).txt" }
    public static func referenceName(_ s: FrameSize, frame: Int) -> String { "ref_\(s)_f\(frame).png" }

    /// The main view at `mainMbps` for a full 2800x1840 frame (scaled by area for other sizes), the auxiliary at
    /// `auxRatio` of that.
    public static func bitrates(size: FrameSize, mainMbps: Double, auxRatio: Double) -> (mainKbps: Int, auxKbps: Int) {
        let scale = Double(size.pixels) / Double(FrameSize.full.pixels)
        let main = mainMbps * 1000 * scale
        return (Int(main.rounded()), Int((main * auxRatio).rounded()))
    }
}
