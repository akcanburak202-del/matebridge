import Foundation

/// Which frame the sender writes next in a packed full colour stream (decision 0034, PROTOCOL.md 0x05 / section 5).
/// Pure. The main picture always goes first; an auxiliary frame goes only with the `capture_time_us` of a main frame
/// that was actually sent (`mainSent`).
public struct PackedSendArbiter: Sendable {
    public enum Pick: Equatable, Sendable {
        case main
        case aux
        /// The auxiliary head belongs to a main frame that will never be sent (dropped, or the encoder failed): drop it
        /// and ask for an auxiliary keyframe (its reference chain now has a hole).
        case dropAux
        /// Nothing can be sent yet: the main frame of the auxiliary head is still on its way.
        case wait
    }

    /// Main capture times remembered (the auxiliary frame of a main frame sent a moment ago may still arrive).
    public static let memory = 8
    private var recent: [UInt64] = []
    private var latest: UInt64?

    public init() {}

    /// A main frame (not a CODEC_CONFIG) was handed to the transport.
    public mutating func mainSent(captureTimeUs: UInt64) {
        recent.append(captureTimeUs)
        if recent.count > Self.memory { recent.removeFirst(recent.count - Self.memory) }
        latest = max(latest ?? 0, captureTimeUs)
    }

    /// - Parameters:
    ///   - mainAvailable: the main queue holds a frame.
    ///   - aux: the auxiliary queue's head: its `captureTimeUs` and whether it is a CODEC_CONFIG; nil when empty.
    public func pick(mainAvailable: Bool, aux: (captureTimeUs: UInt64, isConfig: Bool)?) -> Pick {
        if mainAvailable { return .main }
        guard let aux else { return .wait }
        if aux.isConfig || recent.contains(aux.captureTimeUs) { return .aux }
        if let latest, aux.captureTimeUs < latest { return .dropAux }
        return .wait
    }
}

/// Decides when the auxiliary encoder cannot keep up (decision 0034 section 7). Pure; one window per second.
/// A window with at least `minFrames` offered auxiliary frames and more than 5 % lost counts as bad; `badWindows`
/// bad windows in a row, or any hard error (VideoToolbox, Metal), ask for the fallback to normal 4:2:0 once.
public struct PackedChromaMonitor: Sendable {
    public static let lossPercentLimit = 5
    public static let minFrames = 20
    public static let badWindows = 3

    public enum Decision: Equatable, Sendable {
        case fallback(reason: String)
    }

    private var offered = 0
    private var lost = 0
    private var bad = 0
    private var fired = false

    public init() {}

    public mutating func recordOffered() { offered += 1 }
    public mutating func recordLost() { lost += 1 }

    /// A hard error: fall back at once (once).
    public mutating func recordError(_ reason: String) -> Decision? {
        guard !fired else { return nil }
        fired = true
        return .fallback(reason: reason)
    }

    /// Closes the window; returns the fallback decision the first time the rule is met.
    public mutating func closeWindow() -> Decision? {
        defer { offered = 0; lost = 0 }
        guard !fired else { return nil }
        if offered >= Self.minFrames, lost * 100 > offered * Self.lossPercentLimit { bad += 1 } else { bad = 0 }
        guard bad >= Self.badWindows else { return nil }
        fired = true
        return .fallback(reason: "aux_loss")
    }
}

/// `video ev=chroma_stats` fields of the packed path, a 10 s window (T-258): packer GPU time, auxiliary encode time,
/// auxiliary / main byte ratio and the auxiliary frames lost. Samples are bounded like `ChromaStatsWindow`.
public struct PackedChromaStatsWindow: Sendable {
    public static let windowUs: UInt64 = 10_000_000
    public static let maxSamples = 4096

    private var startUs: UInt64
    private var packWallUs: [UInt64] = []
    private var packGpuUs: [UInt64] = []
    private var auxEncodeUs: [UInt64] = []
    private var mainFrames = 0
    private var mainBytes = 0
    private var auxBytes = 0
    private var auxFrames = 0
    private var auxLost = 0
    private var packFailures = 0

    public init(startUs: UInt64) { self.startUs = startUs }

    public mutating func recordPack(wallUs: UInt64, gpuUs: UInt64) {
        if packWallUs.count < Self.maxSamples { packWallUs.append(wallUs) }
        if packGpuUs.count < Self.maxSamples { packGpuUs.append(gpuUs) }
    }
    public mutating func recordPackFailure() { packFailures += 1 }
    public mutating func recordMain(bytes: Int) { mainFrames += 1; mainBytes += bytes }
    public mutating func recordAux(bytes: Int, encodeUs: UInt64) {
        auxFrames += 1
        auxBytes += bytes
        if auxEncodeUs.count < Self.maxSamples { auxEncodeUs.append(encodeUs) }
    }
    public mutating func recordAuxLost() { auxLost += 1 }

    /// `mode=packed444 frames=<main> aux_frames=<n> pack_ms_p50_95=a/b pack_gpu_ms_p50_95=a/b aux_enc_ms_p50_95=a/b
    /// aux_main_bytes=<ratio|-> aux_lost=<n> pack_fail=<n>` once `windowUs` has passed; nil before.
    public mutating func take(nowUs: UInt64) -> String? {
        guard nowUs >= startUs, nowUs - startUs >= Self.windowUs else { return nil }
        let ratio = mainBytes > 0 ? String(format: "%.2f", Double(auxBytes) / Double(mainBytes)) : "-"
        let f = "mode=packed444 frames=\(mainFrames) aux_frames=\(auxFrames) "
            + "pack_ms_p50_95=\(ChromaStatsWindow.pair(packWallUs)) pack_gpu_ms_p50_95=\(ChromaStatsWindow.pair(packGpuUs)) "
            + "aux_enc_ms_p50_95=\(ChromaStatsWindow.pair(auxEncodeUs)) aux_main_bytes=\(ratio) "
            + "aux_lost=\(auxLost) pack_fail=\(packFailures)"
        self = PackedChromaStatsWindow(startUs: nowUs)
        return f
    }
}

/// `video ev=chroma_fallback` fields (T-258).
public enum PackedChromaFallbackLog {
    public static let event = "chroma_fallback"

    /// `reason=<r> layout=packed444->420 config_id=<n>` (the user's choice is kept).
    public static func fields(reason: String, configID: UInt16) -> String {
        "reason=\(reason) layout=packed444->420 config_id=\(configID)"
    }
}
