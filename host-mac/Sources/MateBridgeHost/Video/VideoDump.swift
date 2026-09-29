import Foundation
import MateBridgeCore

/// `MateBridgeApp --dump-video <file> --seconds N [--fps F] [--bitrate-kbps K]`: runs the video
/// pipeline (creates the virtual display), writes the Annex-B HEVC stream to `<file>` and prints stats.
public enum VideoDump {
    public struct Options: Sendable {
        public var path: String
        public var seconds: Double = 5
        public var fps: Int?
        public var bitrateKbps: Int?
    }

    public struct ParseError: Error, Sendable { public let message: String }

    /// nil when `--dump-video` is absent; a string error for malformed arguments.
    public static func parse(_ args: [String]) -> Result<Options, ParseError>? {
        guard let i = args.firstIndex(of: "--dump-video") else { return nil }
        guard i + 1 < args.count, !args[i + 1].hasPrefix("--") else { return .failure(ParseError(message: "--dump-video needs a file path")) }
        var o = Options(path: args[i + 1])
        var j = 0
        while j < args.count {
            switch args[j] {
            case "--seconds":
                guard j + 1 < args.count, let v = Double(args[j + 1]), v > 0 else { return .failure(ParseError(message: "--seconds needs a positive number")) }
                o.seconds = v; j += 1
            case "--fps":
                guard j + 1 < args.count, let v = Int(args[j + 1]), v > 0 else { return .failure(ParseError(message: "--fps needs a positive integer")) }
                o.fps = v; j += 1
            case "--bitrate-kbps":
                guard j + 1 < args.count, let v = Int(args[j + 1]), v > 0 else { return .failure(ParseError(message: "--bitrate-kbps needs a positive integer")) }
                o.bitrateKbps = v; j += 1
            default: break
            }
            j += 1
        }
        return .success(o)
    }

    /// Returns the process exit code.
    public static func run(_ o: Options) async -> Int32 {
        var settings = VideoSettings.tabletDefault
        if let f = o.fps { settings.fps = f }
        if let b = o.bitrateKbps { settings.bitrateKbps = b }

        let path = (o.path as NSString).expandingTildeInPath
        guard FileManager.default.createFile(atPath: path, contents: nil),
              let file = FileHandle(forWritingAtPath: path) else {
            print("error: cannot write \(path)")
            return 2
        }
        defer { try? file.close() }

        let stats = LockedBox(VideoStats())
        let pipeline = VideoPipeline(settings: settings, tap: { frame, us in
            stats.mutate { $0.record(frame, encodeTimeUs: us) }
        }, onFailure: { print("capture stopped: \($0)") })

        do { try await pipeline.start() } catch {
            print("error: \(error)")
            return 1
        }
        print("dumping \(o.seconds)s of \(settings.widthPx)x\(settings.heightPx) HEVC @ \(settings.fps) fps, \(settings.bitrateKbps) kbps to \(path)")

        let cfg = settings.streamConfig(configID: 0)
        print("STREAM_CONFIG colour (H.273): primaries=\(cfg.colorPrimaries) transfer=\(cfg.transfer) matrix=\(cfg.matrix) "
              + "range=\(cfg.fullRange ? "full" : "limited") (capture pixel format 420f = full range)")
        print("encoder session colour: \(pipeline.encoderColorReadback)")

        let deadline = Date().addingTimeInterval(o.seconds)
        let stopper = Task {
            try? await Task.sleep(nanoseconds: UInt64(o.seconds * 1_000_000_000))
            await pipeline.stop()
        }
        while let frame = await pipeline.frames.next() {
            try? file.write(contentsOf: Data(frame.data))
            if Date() > deadline { break }
        }
        await stopper.value
        await pipeline.stop()

        let s = stats.value
        print("frames: \(s.frames), keyframes: \(s.keyframes), bytes: \(s.bytes)")
        print(String(format: "avg frame: %.0f B, max frame: %d B, avg bitrate: %.0f kbps",
                     s.averageFrameBytes, s.maxFrameBytes, s.bitrateKbps(overSeconds: o.seconds)))
        print(String(format: "encode time: avg %.2f ms, max %.2f ms; queue drops: %d",
                     s.averageEncodeTimeUs / 1000, Double(s.maxEncodeTimeUs) / 1000, pipeline.frames.droppedCount))
        if s.frames == 0 { print("warning: no frames captured (a static screen produces few frames; move something)") }
        return 0
    }
}

private final class LockedBox<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T
    init(_ v: T) { _value = v }
    var value: T { lock.lock(); defer { lock.unlock() }; return _value }
    func mutate(_ f: (inout T) -> Void) { lock.lock(); f(&_value); lock.unlock() }
}
