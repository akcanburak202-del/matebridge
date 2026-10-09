import Darwin
import Foundation
import MateBridgeCore

/// Runs Wi-Fi congestion control (T-328, `MATEBRIDGE_WIFI_ADAPT=1`, network sessions only) for one video connection:
/// a `WifiAdaptation` on the link's frame gate, a 100 ms timer that feeds it the connection's TCP state and the host
/// queue's drop count, and the controller's target bit rate applied to the live encoder (no restart, no keyframe).
///
/// Tick source. The coordinator's per-second cadence tick is too slow (a decrease one second late is 7 MB of queue at
/// 60 Mbps) and the session server's 100 ms tick has no pipeline; this timer owns both, so it needs nothing from the
/// session queue. It reads `TCP_CONNECTION_INFO` ten times a second with its own `TcpInfoMeter`, independent of the
/// per-second `net ev=tcp` meter (that one's window base never moves). The per-frame admission reads the send buffer
/// on its own, at most every 2 ms (`WifiAdaptation.sampleFreshUs`).
///
/// Encoder rate. A lower target is applied at once, so is the ceiling (idle recovery jumps there); other higher ones at most every `WifiAdaptation.upApplyIntervalUs`, because the
/// controller climbs in 250 kbps steps several times a second and every apply reconfigures the VideoToolbox session.
/// `stop()` puts the encoder back at the ceiling: the next connection starts a new controller there.
final class WifiAdaptationDriver: @unchecked Sendable {
    static let tickMs = 100
    static let logEveryTicks = 10

    let adaptation: WifiAdaptation
    private let link: VideoLink
    private weak var pipeline: VideoPipeline?
    private let logger: SessionLogger
    private let sessionID: UInt32
    private let configID: UInt16
    private let queue = DispatchQueue(label: "matebridge.wifi_adapt", qos: .userInteractive)

    private let lock = NSLock()
    private var timer: DispatchSourceTimer?
    private var stopped = false
    // Timer queue only (and `start`, before the timer runs).
    private var meter = TcpInfoMeter()
    private var ticks = 0
    private var appliedKbps: Int
    private var lastUpApplyUs: UInt64 = 0

    init(link: VideoLink, pipeline: VideoPipeline, logger: SessionLogger) {
        self.link = link
        self.pipeline = pipeline
        self.logger = logger
        sessionID = link.sessionID
        configID = link.configID
        let ceiling = pipeline.settings.bitrateKbps
        appliedKbps = ceiling
        adaptation = WifiAdaptation(
            config: .init(ceilingKbps: ceiling, framesPerSecond: pipeline.settings.fps),
            readSendBuffer: { [weak link] in link?.sendBufferBytes() },
            nowUs: { HostClock.nowUs() })
    }

    /// Puts the gate on the link and starts the timer. The encoder is set to the ceiling first: an earlier connection
    /// of this pipeline may have left it lower.
    func start() {
        pipeline?.setTargetBitrate(kbps: adaptation.ceilingKbps)
        link.attachAdaptation(adaptation)
        logger.log(.info, "adapt_start", sessionID: sessionID, generation: configID,
                   fields: "ceiling_kbps=\(adaptation.ceilingKbps) floor_kbps=\(CongestionController.defaultFloorKbps) "
                       + "tick_ms=\(Self.tickMs)")
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + .milliseconds(Self.tickMs), repeating: .milliseconds(Self.tickMs))
        t.setEventHandler { [weak self] in self?.tick() }
        lock.withLock { timer = t }
        t.resume()
    }

    /// Stops the timer and the gate; the encoder goes back to the ceiling. Idempotent, never blocks.
    func stop() {
        let t: DispatchSourceTimer? = lock.withLock {
            guard !stopped else { return nil }
            stopped = true
            defer { timer = nil }
            return timer
        }
        t?.cancel()
        adaptation.stop()
        pipeline?.setTargetBitrate(kbps: adaptation.ceilingKbps)
    }

    private func tick() {
        // `stopped` is checked under the lock that `stop()` takes, so no step is applied after the restore above.
        lock.lock()
        defer { lock.unlock() }
        guard !stopped, let pipeline, let info = link.tcpConnectionInfo() else { return }
        let report = meter.take(TcpConnectionSnapshot(info))
        let result = adaptation.tick(report: report, queueDropsTotal: pipeline.frames.droppedCount)
        ticks += 1
        let now = HostClock.nowUs()
        if result.targetKbps != appliedKbps {
            let down = result.targetKbps < appliedKbps
            if WifiAdaptation.shouldApply(target: result.targetKbps, applied: appliedKbps,
                                          ceiling: adaptation.ceilingKbps, nowUs: now, lastUpApplyUs: lastUpApplyUs) {
                logger.log(down ? .info : .debug, "adapt_step", sessionID: sessionID, generation: configID,
                           fields: "from_kbps=\(appliedKbps) to_kbps=\(result.targetKbps) "
                               + "trigger=\(result.trigger?.rawValue ?? (down ? "other" : "up"))")
                appliedKbps = result.targetKbps
                if !down { lastUpApplyUs = now }
                pipeline.setTargetBitrate(kbps: result.targetKbps)
            }
        }
        if ticks % Self.logEveryTicks == 0 {
            logger.log(.info, "adapt", sessionID: sessionID, generation: configID,
                       fields: adaptation.takeLogWindow().logFields)
        }
    }
}
