/// One AAC-LC encoder instance (decision 0038): 1024 PCM frames (s16le stereo, 48 kHz) in, one raw access unit out.
public protocol AACConverting: AnyObject {
    /// Encoder delay in frames: the first decoded frame of a stream is this many frames before the first input frame.
    var primingFrames: Int { get }
    /// Encodes exactly `AACStage.unitFrames` frames. nil: the encoder produced no unit for this block.
    func encode(_ pcm: [UInt8]) throws -> [UInt8]?
    /// Forgets the signal history (a new segment starts).
    func reset()
}

/// A raw AAC access unit with its wire timestamps (never log `data`).
public struct AACUnit: Equatable, Sendable {
    public var data: [UInt8]
    public var sampleIndex: UInt64
    public var captureTimeUs: UInt64
}

/// Turns the 10 ms PCM packets of the audio ring into 1024-frame AAC access units. Runs on the streamer queue, never
/// in the IOProc. Pure arithmetic around an `AACConverting`.
///
/// Segments: a run of PCM packets without a gap. Unit `k` of a segment (counted by units the encoder produced):
/// - `sampleIndex = segmentFirstIndex + k * 1024`. The index is the block's first input frame, not shifted by the
///   encoder delay, so it stays unsigned and grows by exactly 1024 per unit.
/// - `captureTimeUs = segmentFirstTime + (k * 1024 - priming) / 48000`: the unit's first decoded frame is `priming`
///   frames earlier than the block's first input frame (the encoder delay is subtracted).
///
/// Gaps (silence gate skipped packets, HAL gaps): up to `maxZeroFillFrames` are filled with zeros so the segment
/// goes on; a longer one completes the partial block with zeros, encodes it and resets the encoder, and the next
/// packet starts a new segment. Skipped silence therefore costs no data.
public final class AACStage {
    public static let unitFrames = 1024
    public static let sampleRate: UInt64 = 48_000
    public static let maxZeroFillFrames = 4096
    private static let bytesPerFrame = 4

    private let converter: AACConverting
    private var pending: [UInt8] = []
    private var segment: (firstIndex: UInt64, firstTimeUs: UInt64)?
    private var nextIndex: UInt64 = 0
    private var unitCount: UInt64 = 0

    public init(converter: AACConverting) {
        self.converter = converter
    }

    private var pendingFrames: Int { pending.count / Self.bytesPerFrame }

    /// One PCM packet (stereo s16le frames in `pcm`) that starts at stream frame `sampleIndex`.
    public func feed(pcm: [UInt8], sampleIndex: UInt64, captureTimeUs: UInt64) throws -> [AACUnit] {
        var units: [AACUnit] = []
        if segment != nil, sampleIndex != nextIndex {
            if sampleIndex > nextIndex, sampleIndex - nextIndex <= UInt64(Self.maxZeroFillFrames) {
                let gap = Int(sampleIndex - nextIndex)
                pending.append(contentsOf: [UInt8](repeating: 0, count: gap * Self.bytesPerFrame))
                try drainBlocks(into: &units)
            } else {
                try endSegment(into: &units)
            }
        }
        if segment == nil {
            segment = (sampleIndex, captureTimeUs)
            unitCount = 0
        }
        pending.append(contentsOf: pcm)
        nextIndex = sampleIndex &+ UInt64(pcm.count / Self.bytesPerFrame)
        try drainBlocks(into: &units)
        return units
    }

    private func endSegment(into units: inout [AACUnit]) throws {
        if pendingFrames > 0 {
            let pad = Self.unitFrames - pendingFrames
            pending.append(contentsOf: [UInt8](repeating: 0, count: pad * Self.bytesPerFrame))
            try drainBlocks(into: &units)
        }
        converter.reset()
        segment = nil
    }

    private func drainBlocks(into units: inout [AACUnit]) throws {
        let blockBytes = Self.unitFrames * Self.bytesPerFrame
        while pending.count >= blockBytes, let seg = segment {
            let block = Array(pending.prefix(blockBytes))
            pending.removeFirst(blockBytes)
            guard let data = try converter.encode(block) else { continue }
            units.append(AACUnit(data: data, sampleIndex: unitIndex(seg.firstIndex),
                                 captureTimeUs: unitTime(seg.firstTimeUs)))
            unitCount += 1
        }
    }

    private func unitIndex(_ first: UInt64) -> UInt64 { first &+ unitCount &* UInt64(Self.unitFrames) }

    private func unitTime(_ first: UInt64) -> UInt64 {
        let frames = Int64(unitCount) * Int64(Self.unitFrames) - Int64(converter.primingFrames)
        let us = frames * 1_000_000 / Int64(Self.sampleRate)
        return us >= 0 ? first &+ UInt64(us) : first &- UInt64(-us)
    }
}
