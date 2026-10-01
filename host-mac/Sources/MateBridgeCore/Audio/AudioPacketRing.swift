import Synchronization

/// Metadata of one ring slot, written by the producer before the slot is published.
public struct AudioSlotMeta: Equatable, Sendable {
    /// Stream index of the packet's first frame.
    public var sampleIndex: UInt64 = 0
    /// Host time (mach ticks) of the IOProc callback that delivered the first frame...
    public var hostTime: UInt64 = 0
    /// ...plus this many frames into that callback.
    public var hostOffsetFrames: UInt32 = 0
    public var frameCount: UInt32 = 0
    /// Sum of squares of the packet's samples (normalized), for the level meter only.
    public var sumSquares: Double = 0
    /// Longest IOProc callback (mach ticks) finished since the previous packet was published.
    public var callbackMaxTicks: UInt64 = 0

    public init() {}
}

/// One packet read out of the ring. `data` is PCM s16le interleaved; never log it.
public struct AudioRingPacket: Equatable, Sendable {
    public var meta: AudioSlotMeta
    public var data: [UInt8]
}

/// Bounded single-producer/single-consumer packet ring (decision 0011, PROTOCOL.md 5: at most 100 ms pending).
///
/// - The producer (the Core Audio IOProc) never waits and never allocates: it fills the slot of the next index in
///   place and publishes it with one atomic store. When the consumer lags it simply overwrites the oldest slots.
/// - The consumer reads at most `maxPending` packets behind the newest one and skips anything older (the oldest audio
///   is dropped, `sample_index` jumps). After copying a slot it re-checks the published count: if the producer may have
///   started overwriting that slot meanwhile, the copy is discarded and counted as dropped (seqlock-style).
///
/// All storage is allocated once in `init`.
public final class AudioPacketRing: @unchecked Sendable {
    public let capacity: Int
    public let framesPerPacket: Int
    public let channels = 2
    public var bytesPerPacket: Int { framesPerPacket * channels * 2 }

    /// Packets published so far. Slot of index `i` is `i % capacity`.
    private let published = Atomic<UInt64>(0)
    private let metas: UnsafeMutablePointer<AudioSlotMeta>
    private let storage: UnsafeMutableRawPointer
    /// Consumer-only.
    private var readIndex: UInt64 = 0

    public init(capacity: Int = 16, framesPerPacket: Int = 480) {
        precondition(capacity >= 2 && framesPerPacket > 0)
        self.capacity = capacity
        self.framesPerPacket = framesPerPacket
        metas = .allocate(capacity: capacity)
        metas.initialize(repeating: AudioSlotMeta(), count: capacity)
        storage = .allocate(byteCount: capacity * framesPerPacket * 4, alignment: 16)
        storage.initializeMemory(as: UInt8.self, repeating: 0, count: capacity * framesPerPacket * 4)
    }

    deinit {
        metas.deinitialize(count: capacity)
        metas.deallocate()
        storage.deallocate()
    }

    // MARK: Producer (real-time thread)

    /// The slot the next `publish()` makes visible. Not visible to the consumer before that.
    @inline(__always)
    public func producerSlot() -> (data: UnsafeMutableRawPointer, meta: UnsafeMutablePointer<AudioSlotMeta>) {
        let slot = Int(published.load(ordering: .relaxed) % UInt64(capacity))
        return (storage + slot * bytesPerPacket, metas + slot)
    }

    /// Makes the current producer slot visible. The fence afterwards orders this store before any write to the
    /// next slot, so a consumer that saw such a write also sees the new count (and discards its copy).
    @inline(__always)
    public func publish() {
        let next = published.load(ordering: .relaxed) &+ 1
        published.store(next, ordering: .releasing)
        atomicMemoryFence(ordering: .releasing)
    }

    // MARK: Consumer

    public struct Read: Equatable, Sendable {
        public var packet: AudioRingPacket?
        /// Packets skipped (too old, or overwritten while copying) before `packet`.
        public var dropped: Int
        /// Packets that were waiting when the read started (including the one returned).
        public var backlog: Int
    }

    /// Next packet, at most `maxPending` behind the newest. `packet == nil` when nothing is waiting.
    public func next(maxPending: Int) -> Read {
        precondition(maxPending >= 1 && maxPending < capacity)
        var dropped = 0
        let newest = published.load(ordering: .acquiring)
        let backlog = Int(newest &- readIndex)
        while true {
            let w = published.load(ordering: .acquiring)
            guard w > readIndex else { return Read(packet: nil, dropped: dropped, backlog: backlog) }
            if w - readIndex > UInt64(maxPending) {
                dropped += Int(w - readIndex - UInt64(maxPending))
                readIndex = w - UInt64(maxPending)
            }
            let slot = Int(readIndex % UInt64(capacity))
            let meta = metas[slot]
            let count = min(Int(meta.frameCount), framesPerPacket)
            let data = [UInt8](UnsafeRawBufferPointer(start: storage + slot * bytesPerPacket, count: count * 4))
            atomicMemoryFence(ordering: .acquiring)
            let after = published.load(ordering: .relaxed)
            let index = readIndex
            readIndex += 1
            if after >= index + UInt64(capacity) {
                dropped += 1  // the producer reached this slot again while we copied it: torn
                continue
            }
            return Read(packet: AudioRingPacket(meta: meta, data: data), dropped: dropped, backlog: backlog)
        }
    }

    /// Packets published so far (diagnostics and tests).
    public var publishedCount: UInt64 { published.load(ordering: .acquiring) }
}
