import Foundation
import MateBridgeCore

/// Optional per-frame trace file (T-070), enabled by `MATEBRIDGE_LAT_TRACE=1`:
/// `~/Library/Logs/MateBridge/latency.csv`, one `FrameTrace` per line (host-clock microseconds, numbers only).
/// Bounded: 8 MiB per file, two files kept (`latency.csv`, `latency.1.csv`); lines are dropped, never queued without
/// limit, if the disk is slow.
final class LatencyCsv: Sendable {
    private let file: RotatingLogFile

    /// nil unless the environment variable is `1`.
    init?(environment: [String: String] = ProcessInfo.processInfo.environment) {
        guard environment["MATEBRIDGE_LAT_TRACE"] == "1" else { return nil }
        file = RotatingLogFile(fileName: "latency.csv", maxBytes: 8 * 1024 * 1024, keep: 2, maxPendingLines: 1024)
        file.append(FrameTrace.csvHeader)
    }

    func append(_ trace: FrameTrace) { file.append(trace.csvLine) }
}
