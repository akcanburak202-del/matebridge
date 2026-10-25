import Darwin
import Foundation
import MateBridgeCore

/// Runs Wi-Fi bit rate adaptation v2 (T-379, `MATEBRIDGE_WIFI_ADAPT=1`, network sessions only) for one video
/// connection: a 100 ms timer reads the connection's TCP state and the sender's write progress, feeds the pure
/// `WifiAdaptV2Controller`, and applies its target to the live encoder (no restart, no keyframe, no admission gate).
///
/// Where S is measured. `SocketVideoTransport.writeObservation` gives the bytes the kernel has accepted from the video
/// writes and when the record in progress started; `VideoFrameQueue.headEnqueuedUs` gives the age of the frame waiting
/// at the head of the send queue. `SendStallDetector` turns them into stall events (150 ms without byte progress).
/// Both are host-clock microseconds (`HostClock`), the clock the transport is created with.
///
/// Tick source. The coordinator's per-second cadence tick is too slow for a decrease and the session server's 100 ms
/// tick has no pipeline; this timer owns both. It reads `TCP_CONNECTION_INFO` with its own `TcpInfoMeter`, independent
/// of the per-second `net ev=tcp` meter.
///
/// The ceiling is the pipeline's configured bit rate, fixed for the pipeline's lifetime (a user change restarts the
/// stream, which builds a new driver). `stop()` puts the encoder back at the ceiling.
final class WifiAdaptationDriver: @unchecked Sendable {
    static let tickMs = WifiAdaptV2Controller.Constants.tickMs
    static let logEveryTicks = 10

    let ceilingKbps: Int
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
    private var controller: WifiAdaptV2Controller
    private var detector = SendStallDetector()
    private var meter = TcpInfoMeter()
    private var ticks = 0
    private var window = Window()

    /// One second of the books, for `video ev=adapt_state`.
    private struct Window {
        var sendBufferMax: UInt32 = 0
        var srttMax: UInt32 = 0
        var retx: UInt64 = 0
        var stallEvents = 0
        var stallMaxMs: UInt32 = 0
        var evidenceTicks = [Int](repeating: 0, count: 4)  // S, D, L, B
        var steps = 0
    }

    init(link: VideoLink, pipeline: VideoPipeline, logger: SessionLogger) {
        self.link = link
        self.pipeline = pipeline
        self.logger = logger
        sessionID = link.sessionID
        configID = link.configID
        ceilingKbps = pipeline.settings.bitrateKbps
        controller = WifiAdaptV2Controller(ceilingKbps: ceilingKbps)
    }

    /// Starts the timer. The encoder is set to the ceiling first: an earlier connection of this pipeline may have left
    /// it lower.
    func start() {
        pipeline?.setTargetBitrate(kbps: ceilingKbps)
        logger.log(.info, "adapt_start", sessionID: sessionID, generation: configID,
                   fields: "ceiling_kbps=\(ceilingKbps) floor_kbps=\(controller.floorKbps) tick_ms=\(Self.tickMs)")
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + .milliseconds(Self.tickMs), repeating: .milliseconds(Self.tickMs))
        t.setEventHandler { [weak self] in self?.tick() }
        lock.withLock { timer = t }
        t.resume()
    }

    /// Stops the timer; the encoder goes back to the ceiling. Idempotent, never blocks.
    func stop() {
        let t: DispatchSourceTimer? = lock.withLock {
            guard !stopped else { return nil }
            stopped = true
            defer { timer = nil }
            return timer
        }
        t?.cancel()
        pipeline?.setTargetBitrate(kbps: ceilingKbps)
    }

    private func tick() {
        // `stopped` is checked under the lock that `stop()` takes, so no step is applied after the restore above.
        lock.lock()
        defer { lock.unlock() }
        guard !stopped, let pipeline, let info = link.tcpConnectionInfo() else { return }
        let now = HostClock.nowUs()
        let report = meter.take(TcpConnectionSnapshot(info))
        let obs = link.writeObservation()
        let outstanding = [obs.writeStartedUs, pipeline.frames.headEnqueuedUs].compactMap { $0 }.min()
        let stall = detector.observe(.init(nowUs: now, progressBytes: obs.progressBytes, outstandingSinceUs: outstanding))
        let activeMs = UInt32(min(UInt64(UInt32.max), stall.activeUs / 1_000))
        let outcome = controller.tick(.init(nowUs: now, srttMs: report.snapshot.srttMs,
                                            sendBufferBytes: report.snapshot.sendBufferBytes,
                                            txPacketsDelta: report.txPacketsDelta,
                                            retransmitPacketsDelta: report.retransmitPacketsDelta,
                                            stallStarted: stall.newEvent, stallActiveMs: activeMs))
        ticks += 1
        window.sendBufferMax = max(window.sendBufferMax, report.snapshot.sendBufferBytes)
        window.srttMax = max(window.srttMax, report.snapshot.srttMs)
        window.retx += report.retransmitPacketsDelta
        if stall.newEvent { window.stallEvents += 1 }
        window.stallMaxMs = max(window.stallMaxMs, activeMs)
        for (i, flag) in [WifiAdaptV2Controller.Evidence.stall, .delay, .loss, .backlog].enumerated()
        where outcome.evidence.contains(flag) { window.evidenceTicks[i] += 1 }

        if let step = outcome.step {
            window.steps += 1
            logger.log(step.toKbps < step.fromKbps ? .info : .debug, "adapt", sessionID: sessionID, generation: configID,
                       fields: "from_kbps=\(step.fromKbps) to_kbps=\(step.toKbps) reason=\(step.reason.rawValue) "
                           + "evidence=\(step.evidence.logValue)")
            pipeline.setTargetBitrate(kbps: step.toKbps)
        }
        if ticks % Self.logEveryTicks == 0 {
            let w = window
            window = Window()
            logger.log(.info, "adapt_state", sessionID: sessionID, generation: configID,
                       fields: "target_kbps=\(controller.targetKbps) srtt_ms_max=\(w.srttMax) "
                           + "base_ms=\(controller.baselineMs.map { "\($0)" } ?? "na") sbbytes_max=\(w.sendBufferMax) "
                           + "retx_pkts=\(w.retx) stall_events=\(w.stallEvents) stall_max_ms=\(w.stallMaxMs) "
                           + "s_ticks=\(w.evidenceTicks[0]) d_ticks=\(w.evidenceTicks[1]) l_ticks=\(w.evidenceTicks[2]) "
                           + "b_ticks=\(w.evidenceTicks[3]) steps=\(w.steps)")
        }
    }
}
