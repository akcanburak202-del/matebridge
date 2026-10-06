/// Decides which all-zero audio packets are not worth sending (decision 0011, 2026-10-06 update, T-279).
///
/// Some apps keep the output device open while they play silence, so the tap's IO never stops and the host would
/// send 100 packets/s of zeros (~1.5 Mbps). After `silentRunLimit` consecutive all-zero packets (500 ms) the gate
/// closes: further zero packets are skipped. The first packet with any non-zero sample reopens it and is sent.
/// Skipped packets leave a `sample_index` / `capture_time_us` jump, which the client treats like the IO stopping.
///
/// "Zero" means every sample is 0 after the s16 conversion: the producer's `sumSquares` is computed from the
/// converted samples, so `== 0` is exact and a single LSB (-90 dBFS) counts as sound. Not real-time code: it runs in
/// the sender (`AudioStreamer.drain`). One gate per stream.
public struct AudioSilenceGate: Equatable, Sendable {
    /// 50 packets of 10 ms.
    public static let silentRunLimit = 50

    public private(set) var zeroRun = 0

    public init() {}

    /// true: send the packet. Zero packets are sent until `silentRunLimit` of them arrived in a row, so the first
    /// packet of a stream always goes out.
    public mutating func shouldSend(sumSquares: Double) -> Bool {
        guard sumSquares == 0 else {
            zeroRun = 0
            return true
        }
        if zeroRun < Self.silentRunLimit {
            zeroRun += 1
            return true
        }
        return false
    }
}
