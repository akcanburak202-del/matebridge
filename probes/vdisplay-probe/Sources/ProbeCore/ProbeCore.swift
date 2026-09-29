import Foundation

public struct ProbeOptions: Equatable, Sendable {
    public var width = 2800
    public var height = 1840
    public var hidpi = false
    public var seconds = 30

    public init() {}

    public enum ParseError: Error, Equatable, CustomStringConvertible {
        case unknownArgument(String)
        case missingValue(String)
        case invalidValue(String, String)

        public var description: String {
            switch self {
            case .unknownArgument(let a): return "unknown argument: \(a)"
            case .missingValue(let a): return "missing value for \(a)"
            case .invalidValue(let a, let v): return "invalid value '\(v)' for \(a)"
            }
        }
    }

    public static let usage = "usage: vdisplay-probe [--width N] [--height N] [--hidpi] [--seconds N]"

    /// Parses arguments excluding the program name.
    public static func parse(_ args: [String]) throws -> ProbeOptions {
        var o = ProbeOptions()
        var i = 0
        func intValue(_ flag: String) throws -> Int {
            i += 1
            guard i < args.count else { throw ParseError.missingValue(flag) }
            guard let v = Int(args[i]), v > 0 else { throw ParseError.invalidValue(flag, args[i]) }
            return v
        }
        while i < args.count {
            switch args[i] {
            case "--width": o.width = try intValue("--width")
            case "--height": o.height = try intValue("--height")
            case "--seconds": o.seconds = try intValue("--seconds")
            case "--hidpi": o.hidpi = true
            default: throw ParseError.unknownArgument(args[i])
            }
            i += 1
        }
        return o
    }
}

public struct DisplayModeInfo: Equatable, Sendable {
    public var width: Int        // points
    public var height: Int       // points
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var refreshRate: Double

    public init(width: Int, height: Int, pixelWidth: Int, pixelHeight: Int, refreshRate: Double) {
        self.width = width; self.height = height
        self.pixelWidth = pixelWidth; self.pixelHeight = pixelHeight
        self.refreshRate = refreshRate
    }

    public var isHiDPI: Bool { pixelWidth > width }
}

public enum ModeSelector {
    /// Picks the mode with the wanted pixel size. With `hidpi`, requires a 2x mode
    /// (points = pixels / 2); otherwise requires a 1x mode. Highest refresh rate wins.
    public static func select(from modes: [DisplayModeInfo], pixelWidth: Int, pixelHeight: Int, hidpi: Bool) -> DisplayModeInfo? {
        modes
            .filter { $0.pixelWidth == pixelWidth && $0.pixelHeight == pixelHeight && $0.isHiDPI == hidpi }
            .max { $0.refreshRate < $1.refreshRate }
    }
}

/// Counts frames in windows. `takeWindow` returns the count since the previous call.
public struct FrameCounter: Sendable {
    public private(set) var total = 0
    public private(set) var windowCount = 0

    public init() {}

    public mutating func record() {
        total += 1
        windowCount += 1
    }

    public mutating func takeWindow() -> Int {
        defer { windowCount = 0 }
        return windowCount
    }

    public static func fps(frames: Int, seconds: Double) -> Double {
        seconds > 0 ? Double(frames) / seconds : 0
    }
}
