import Foundation

/// Encoded frame size distribution (T-053): keyframes are reported separately because their size is expected to
/// be large; burstiness of the delta frames is what causes Wi-Fi spikes.
public struct FrameSizeStats: Equatable, Sendable {
    public var deltaCount = 0
    public var keyCount = 0
    public var deltaMean = 0.0
    public var deltaP50 = 0
    public var deltaP99 = 0
    public var deltaMax = 0
    public var keyMax = 0
    /// Delta p99 divided by delta mean (1.0 = perfectly even).
    public var p99ToMean: Double { deltaMean > 0 ? Double(deltaP99) / deltaMean : 0 }

    /// Acceptance threshold from the T-053 card: delta p99 <= 4x the mean.
    public static let maxP99ToMean = 4.0

    public var isSmooth: Bool { deltaCount > 0 && p99ToMean <= Self.maxP99ToMean }

    public init() {}

    /// `frames`: (sizeBytes, isKey) per encoded frame.
    public init(frames: [(size: Int, isKey: Bool)]) {
        let deltas = frames.filter { !$0.isKey }.map(\.size).sorted()
        let keys = frames.filter(\.isKey).map(\.size)
        deltaCount = deltas.count
        keyCount = keys.count
        keyMax = keys.max() ?? 0
        guard !deltas.isEmpty else { return }
        deltaMean = Double(deltas.reduce(0, +)) / Double(deltas.count)
        func pick(_ p: Double) -> Int {
            let rank = Int((p / 100 * Double(deltas.count)).rounded(.up)) - 1
            return deltas[min(max(rank, 0), deltas.count - 1)]
        }
        deltaP50 = pick(50)
        deltaP99 = pick(99)
        deltaMax = deltas.last ?? 0
    }
}
