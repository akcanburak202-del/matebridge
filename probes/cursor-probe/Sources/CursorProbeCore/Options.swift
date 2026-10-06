import Foundation

/// Command line of `cursor-probe`.
///
///     cursor-probe once   [--iterations N]
///     cursor-probe record --seconds N --out FILE [--hz 60|120] [--dump-dir DIR] [--no-position] [--no-windowlist]
public struct ProbeOptions: Equatable, Sendable {
    public enum Mode: String, Equatable, Sendable { case once, record }

    public var mode: Mode = .once
    public var iterations = 2000
    public var seconds = 30.0
    public var hz = 60
    public var outPath: String?
    public var dumpDir: String?
    /// Log pointer position samples (one line per changed position). Off for runs that only need shapes.
    public var recordPosition = true
    /// Also poll the public CGWindowList for the WindowServer cursor window (candidate source, see README).
    public var useWindowList = true

    public init() {}

    public enum ParseError: Error, Equatable, CustomStringConvertible {
        case unknownArgument(String)
        case missingValue(String)
        case badValue(String, String)
        case missingOut

        public var description: String {
            switch self {
            case .unknownArgument(let a): return "unknown argument \(a)"
            case .missingValue(let a): return "\(a) needs a value"
            case .badValue(let a, let v): return "bad value '\(v)' for \(a)"
            case .missingOut: return "record needs --out FILE"
            }
        }
    }

    public static func parse(_ args: [String]) -> Result<ProbeOptions, ParseError> {
        var o = ProbeOptions()
        var rest = args[...]
        if let first = rest.first, !first.hasPrefix("-") {
            guard let m = Mode(rawValue: first) else { return .failure(.unknownArgument(first)) }
            o.mode = m
            rest = rest.dropFirst()
        }
        while let a = rest.popFirst() {
            func value() -> String? { rest.popFirst() }
            switch a {
            case "--iterations":
                guard let v = value() else { return .failure(.missingValue(a)) }
                guard let n = Int(v), n > 0 else { return .failure(.badValue(a, v)) }
                o.iterations = n
            case "--seconds":
                guard let v = value() else { return .failure(.missingValue(a)) }
                guard let s = Double(v), s > 0, s <= 3600 else { return .failure(.badValue(a, v)) }
                o.seconds = s
            case "--hz":
                guard let v = value() else { return .failure(.missingValue(a)) }
                guard let h = Int(v), (1...240).contains(h) else { return .failure(.badValue(a, v)) }
                o.hz = h
            case "--out":
                guard let v = value() else { return .failure(.missingValue(a)) }
                o.outPath = v
            case "--dump-dir":
                guard let v = value() else { return .failure(.missingValue(a)) }
                o.dumpDir = v
            case "--no-position": o.recordPosition = false
            case "--no-windowlist": o.useWindowList = false
            default: return .failure(.unknownArgument(a))
            }
        }
        if o.mode == .record && o.outPath == nil { return .failure(.missingOut) }
        return .success(o)
    }
}
