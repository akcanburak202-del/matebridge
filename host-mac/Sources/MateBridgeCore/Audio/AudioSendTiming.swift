import Foundation

/// Send-side timing of AUDIO_FRAMEs on the session server (T-116), for the `component=audio ev=send` line and the
/// rate-limited `ev=send_gap` debug line. Measurement only: it never changes what is sent.
///
/// Lives on the session queue (a plain value, no lock). Per packet it appends two numbers and updates a few maxima;
/// sorting for the percentiles happens once per report (about 100 values). Only message TYPES are kept, never
/// content (decision 0011, LOGGING.md privacy).
public struct AudioSendTiming: Sendable {
    /// One AUDIO_FRAME handed to the connection.
    public struct Write: Equatable, Sendable {
        /// `sendAudio` call to the start of the drain pass that took the frame.
        public var queueLagUs: UInt64
        /// Host capture time of the frame (`capture_time_us`) to the return of the write.
        public var captureToWriteUs: UInt64
        /// Duration of the seal + write call.
        public var writeCallUs: UInt64
        /// Bytes still queued in user space after the write (`bsd`: not yet in the kernel, i.e. EAGAIN or a partial
        /// write; `nw`: not yet processed by Network.framework).
        public var pendingBytes: Int
        /// Host clock when the write returned.
        public var endUs: UInt64

        public init(queueLagUs: UInt64, captureToWriteUs: UInt64, writeCallUs: UInt64, pendingBytes: Int,
                    endUs: UInt64) {
            self.queueLagUs = queueLagUs
            self.captureToWriteUs = captureToWriteUs
            self.writeCallUs = writeCallUs
            self.pendingBytes = pendingBytes
            self.endUs = endUs
        }
    }

    /// An audio write that came more than `gapThresholdUs` after the previous one.
    public struct Gap: Equatable, Sendable {
        public var intervalUs: UInt64
        public var queueLagUs: UInt64
        public var pendingBytes: Int
        /// The last control message handled on the session queue before this write, and how long before it ended.
        public var lastReceived: MessageType?
        public var lastReceivedAgoUs: UInt64
        /// The slowest control message handled since the previous audio write, and how long it took.
        public var slowestReceived: MessageType?
        public var slowestReceivedUs: UInt64

        /// `int_ms=… queue_lag_ms=… pending_bytes=… last_rx=<type>|na last_rx_ago_ms=… slow_rx=<type>|na slow_rx_ms=…`
        public var logFields: String {
            String(format: "int_ms=%.1f queue_lag_ms=%.1f pending_bytes=%d last_rx=%@ last_rx_ago_ms=%.1f "
                   + "slow_rx=%@ slow_rx_ms=%.1f",
                   ms(intervalUs), ms(queueLagUs), pendingBytes, name(lastReceived), ms(lastReceivedAgoUs),
                   name(slowestReceived), ms(slowestReceivedUs))
        }
    }

    /// A write later than this after the previous one is a gap (two packets' worth of audio).
    public static let gapThresholdUs: UInt64 = 20_000
    /// At most this many gaps are returned per `gapRateWindowUs`; the rest are only counted.
    public static let maxGapsPerWindow = 5
    public static let gapRateWindowUs: UInt64 = 1_000_000
    /// Length of one `ev=send` window.
    public static let reportIntervalUs: UInt64 = 1_000_000

    private var queueLagUs: [UInt64] = []
    private var captureToWriteUs: [UInt64] = []
    private var intervalMaxUs: UInt64 = 0
    private var writeCallMaxUs: UInt64 = 0
    private var partialWrites = 0
    private var pendingBytesMax = 0
    private var gaps = 0
    private var windowStartUs: UInt64?

    private var lastWriteUs: UInt64?
    private var gapRateStartUs: UInt64?
    private var gapsReported = 0

    private var lastReceived: MessageType?
    private var lastReceivedEndUs: UInt64 = 0
    private var slowestReceived: MessageType?
    private var slowestReceivedUs: UInt64 = 0

    public init() {
        queueLagUs.reserveCapacity(128)
        captureToWriteUs.reserveCapacity(128)
    }

    /// Number of writes in the current window.
    public var writes: Int { queueLagUs.count }

    /// A control message of type `type` was handled on the session queue from `startUs` to `endUs`.
    public mutating func noteReceived(_ type: MessageType, startUs: UInt64, endUs: UInt64) {
        lastReceived = type
        lastReceivedEndUs = endUs
        let took = endUs &- startUs
        if endUs >= startUs, slowestReceived == nil || took > slowestReceivedUs {
            slowestReceived = type
            slowestReceivedUs = took
        }
    }

    /// Records one AUDIO_FRAME write. Returns the gap to log when it came more than `gapThresholdUs` after the
    /// previous write and fewer than `maxGapsPerWindow` gaps were returned in the current rate window.
    public mutating func recordWrite(_ w: Write) -> Gap? {
        if windowStartUs == nil { windowStartUs = w.endUs }
        queueLagUs.append(w.queueLagUs)
        captureToWriteUs.append(w.captureToWriteUs)
        writeCallMaxUs = max(writeCallMaxUs, w.writeCallUs)
        pendingBytesMax = max(pendingBytesMax, w.pendingBytes)
        if w.pendingBytes > 0 { partialWrites += 1 }

        var gap: Gap?
        if let last = lastWriteUs, w.endUs > last {
            let interval = w.endUs - last
            intervalMaxUs = max(intervalMaxUs, interval)
            if interval > Self.gapThresholdUs {
                gaps += 1
                let inRateWindow = gapRateStartUs.map { w.endUs >= $0 && w.endUs - $0 < Self.gapRateWindowUs } ?? false
                if !inRateWindow {
                    gapRateStartUs = w.endUs
                    gapsReported = 0
                }
                if gapsReported < Self.maxGapsPerWindow {
                    gapsReported += 1
                    gap = Gap(intervalUs: interval, queueLagUs: w.queueLagUs, pendingBytes: w.pendingBytes,
                              lastReceived: lastReceived,
                              lastReceivedAgoUs: lastReceived == nil ? 0 : w.endUs &- min(lastReceivedEndUs, w.endUs),
                              slowestReceived: slowestReceived, slowestReceivedUs: slowestReceivedUs)
                }
            }
        }
        lastWriteUs = w.endUs
        slowestReceived = nil
        slowestReceivedUs = 0
        return gap
    }

    /// The window's `ev=send` fields once it is at least `reportIntervalUs` old at `nowUs` (the window restarts), else
    /// nil.
    public mutating func takeReportIfDue(nowUs: UInt64) -> String? {
        guard let start = windowStartUs, nowUs &- start >= Self.reportIntervalUs, nowUs >= start else { return nil }
        return flush()
    }

    /// The window's `ev=send` fields if it holds any write (the window restarts), else nil.
    public mutating func flush() -> String? {
        guard writes > 0 else { return nil }
        let fields = logFields
        queueLagUs.removeAll(keepingCapacity: true)
        captureToWriteUs.removeAll(keepingCapacity: true)
        intervalMaxUs = 0
        writeCallMaxUs = 0
        partialWrites = 0
        pendingBytesMax = 0
        gaps = 0
        windowStartUs = nil
        return fields
    }

    /// Stream boundary (AUDIO_CONFIG, session change): the next write starts a new interval. The window and the
    /// received-message history are kept; call `flush` first to close the window.
    public mutating func resetInterval() {
        lastWriteUs = nil
    }

    /// `writes=… queue_lag_ms_p50_max=a/b cap_to_write_ms_p50_max=a/b write_int_ms_max=… write_block_ms_max=…
    /// partial_writes=… pending_bytes_max=… gaps=…`
    public var logFields: String {
        String(format: "writes=%d queue_lag_ms_p50_max=%.2f/%.2f cap_to_write_ms_p50_max=%.2f/%.2f "
               + "write_int_ms_max=%.1f write_block_ms_max=%.2f partial_writes=%d pending_bytes_max=%d gaps=%d",
               writes, ms(Self.median(queueLagUs)), ms(queueLagUs.max() ?? 0),
               ms(Self.median(captureToWriteUs)), ms(captureToWriteUs.max() ?? 0),
               ms(intervalMaxUs), ms(writeCallMaxUs), partialWrites, pendingBytesMax, gaps)
    }

    /// Nearest-rank median (0 when empty).
    static func median(_ values: [UInt64]) -> UInt64 {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let rank = Int((0.5 * Double(sorted.count)).rounded(.up)) - 1
        return sorted[min(max(rank, 0), sorted.count - 1)]
    }
}

private func ms(_ us: UInt64) -> Double { Double(us) / 1000 }

private func name(_ type: MessageType?) -> String {
    guard let type else { return "na" }
    return String(describing: type)
}
