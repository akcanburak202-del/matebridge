import Foundation
import MateBridgeCore

/// `MateBridgeApp --dump-video <file> --seconds N [--fps F] [--bitrate-kbps K] [--refresh 60|120] [--frame-delay 0|1]`: runs the video
/// pipeline (creates the virtual display), writes the Annex-B HEVC stream to `<file>` and prints stats.
public enum VideoDump {
    public struct Options: Sendable {
        public var path: String
        public var seconds: Double = 5
        public var fps: Int?
        public var bitrateKbps: Int?
        /// Virtual display refresh rate (default 60); the stream stays at `fps`.
        public var refreshHz: Int = 60
        public var frameDelay: Int?
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
            case "--refresh":
                guard j + 1 < args.count, args[j + 1] == "60" || args[j + 1] == "120" else { return .failure(ParseError(message: "--refresh needs 60 or 120")) }
                o.refreshHz = Int(args[j + 1])!; j += 1
            case "--frame-delay":
                guard j + 1 < args.count, args[j + 1] == "0" || args[j + 1] == "1" else { return .failure(ParseError(message: "--frame-delay needs 0 or 1")) }
                o.frameDelay = Int(args[j + 1])!; j += 1
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
        settings.displayRefreshHz = o.refreshHz
        settings.maxFrameDelayCount = o.frameDelay

        let path = (o.path as NSString).expandingTildeInPath
        guard FileManager.default.createFile(atPath: path, contents: nil),
              let file = FileHandle(forWritingAtPath: path) else {
            print("error: cannot write \(path)")
            return 2
        }
        defer { try? file.close() }

        // The dump is written from the encoder tap (every frame, in order), never from the bounded queue.
        let state = LockedBox(DumpState())
        let pipeline = VideoPipeline(settings: settings, tap: { frame, us in
            state.mutate { st in
                st.stats.record(frame, encodeTimeUs: us)
                if frame.isCodecConfig, st.vui == nil {
                    st.vui = AnnexB.nalUnits(frame.data).lazy.compactMap { HEVCSPS.vuiColor(sps: $0) }.first
                }
                if st.writeError == nil {
                    do { try file.write(contentsOf: Data(frame.data)) } catch { st.writeError = "\(error)" }
                }
            }
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
        let failures = pipeline.encoderPropertyFailures
        if !failures.isEmpty { print("warning: VTSessionSetProperty failed: \(failures.joined(separator: ", "))") }

        print("cadence setup: \(pipeline.cadenceSetup)")

        // One cadence line per second, then a run total. "sent" here is frames drained from the queue.
        let drained = LockedBox(0)
        let totals = LockedBox(CadenceWindow(targetIntervalUs: 1_000_000 / UInt64(max(1, settings.fps))))
        let ticker = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                let w = pipeline.cadenceWindow(sentTotal: drained.value)
                guard w.durationUs > 0 else { continue }
                totals.mutate { $0.merge(w) }
                print("cadence \(w.logFields)")
            }
        }
        let stopper = Task {
            try? await Task.sleep(nanoseconds: UInt64(o.seconds * 1_000_000_000))
            await pipeline.stop()
        }
        // Drain the sink so the bounded queue never backs up; its content is not what gets written.
        while await pipeline.frames.next() != nil { drained.mutate { $0 += 1 } }
        await stopper.value
        ticker.cancel()
        await pipeline.stop()
        let total = totals.value
        print("cadence TOTAL (\(String(format: "%.1f", Double(total.durationUs) / 1e6)) s, refresh \(o.refreshHz) Hz): \(total.logFields)")

        let snap = state.value
        let s = snap.stats
        print("frames: \(s.frames), keyframes: \(s.keyframes), bytes: \(s.bytes)")
        print(String(format: "avg frame: %.0f B, max frame: %d B, avg bitrate: %.0f kbps",
                     s.averageFrameBytes, s.maxFrameBytes, s.bitrateKbps(overSeconds: o.seconds)))
        print(String(format: "encode time: avg %.2f ms, max %.2f ms; queue drops: %d",
                     s.averageEncodeTimeUs / 1000, Double(s.maxEncodeTimeUs) / 1000, pipeline.frames.droppedCount))
        var exit: Int32 = 0
        if let v = snap.vui {
            let match = v.colourDescriptionPresent && v.fullRange == cfg.fullRange && v.colourPrimaries == cfg.colorPrimaries
                && v.transferCharacteristics == cfg.transfer && v.matrixCoefficients == cfg.matrix
            print("SPS VUI (in the bitstream): full_range=\(v.fullRange) colour_description_present=\(v.colourDescriptionPresent) "
                  + "primaries=\(v.colourPrimaries) transfer=\(v.transferCharacteristics) matrix=\(v.matrixCoefficients) "
                  + (match ? "-> matches STREAM_CONFIG" : "-> MISMATCH with STREAM_CONFIG"))
            if !match { exit = 4 }
        } else {
            print("SPS VUI: not found or has no signal-type info (decoders will assume defaults)")
        }
        if let e = snap.writeError {
            print("error: writing the dump failed (\(e)); the file is incomplete")
            exit = 3
        }
        if s.frames == 0 { print("warning: no frames captured (a static screen produces few frames; move something)") }
        return exit
    }
}

private struct DumpState: Sendable {
    var stats = VideoStats()
    var vui: HEVCVUIColor?
    var writeError: String?
}

private final class LockedBox<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T
    init(_ v: T) { _value = v }
    var value: T { lock.lock(); defer { lock.unlock() }; return _value }
    func mutate(_ f: (inout T) -> Void) { lock.lock(); f(&_value); lock.unlock() }
}
