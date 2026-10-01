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
/// - The producer (the Core Audio IOProc) never waits and never allocates. It fills the slot of the next index in
///   place and publishes it with one atomic store. When the consumer lags it reuses the oldest slots.
/// - The consumer reads at most `maxPending` packets behind the newest one and skips anything older (the oldest audio
///   is dropped, `sample_index` jumps).
/// - **Slot ownership:** the two sides never touch the same slot at the same time. Before copying index `r` the
///   consumer claims it (`reading = r + 1`); before filling index `i` the producer announces it (`writing = i`). Both are
///   sequentially consistent stores followed by a load of the other side's value (Dekker), so at least one side sees
///   the conflict when they meet on a slot:
///   - the producer then drops the packet it was about to write (the newest: `producerDrops`, a `sample_index` gap)
///     and tries the slot again for its next packet;
///   - the consumer then gives up on index `r` (it is being reused, i.e. it is old) and counts it dropped.
///
/// All storage is allocated once in `init`.
public final class AudioPacketRing: @unchecked Sendable {
    public let capacity: Int
    public let framesPerPacket: Int
    public let channels = 2
    public var bytesPerPacket: Int { framesPerPacket * channels * 2 }

    /// Packets published so far. The slot of index `i` is `i % capacity`.
    private let published = Atomic<UInt64>(0)
    /// Index the producer is filling, or filled last (written before the slot is touched).
    private let writing = Atomic<UInt64>(0)
    /// `r + 1` while the consumer copies index `r`; 0 otherwise.
    private let reading = Atomic<UInt64>(0)
    /// Packets the producer dropped because the consumer held their slot.
    private let producerDropCount = Atomic<Int>(0)
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

    /// Takes the slot of the next index for writing. nil: the consumer is copying that slot right now; drop this
    /// packet (counted) and call again for the next one. Lock-free, no allocation.
    @inline(__always)
    public func beginWrite() -> (data: UnsafeMutableRawPointer, meta: UnsafeMutablePointer<AudioSlotMeta>)? {
        let index = published.load(ordering: .relaxed)
        writing.store(index, ordering: .sequentiallyConsistent)
        let held = reading.load(ordering: .sequentiallyConsistent)
        let slot = Int(index % UInt64(capacity))
        if held != 0, Int((held - 1) % UInt64(capacity)) == slot {
            producerDropCount.add(1, ordering: .relaxed)
            return nil
        }
        return (storage + slot * bytesPerPacket, metas + slot)
    }

    /// Makes the slot taken by the last successful `beginWrite()` visible to the consumer.
    @inline(__always)
    public func publish() {
        published.add(1, ordering: .releasing)
    }

    // MARK: Consumer

    public struct Read: Equatable, Sendable {
        public var packet: AudioRingPacket?
        /// Packets skipped (too old, or reused by the producer) before `packet`.
        public var dropped: Int
        /// Packets that were waiting when the read started (including the one returned).
        public var backlog: Int
    }

    /// Next packet, at most `maxPending` behind the newest. `packet == nil` when nothing is waiting.
    public func next(maxPending: Int) -> Read {
        precondition(maxPending >= 1 && maxPending < capacity)
        var dropped = 0
        let backlog = Int(published.load(ordering: .acquiring) &- readIndex)
        while true {
            let w = published.load(ordering: .acquiring)
            guard w > readIndex else { return Read(packet: nil, dropped: dropped, backlog: backlog) }
            if w - readIndex > UInt64(maxPending) {
                dropped += Int(w - readIndex - UInt64(maxPending))
                readIndex = w - UInt64(maxPending)
            }
            let index = readIndex
            readIndex += 1
            guard claim(index) else {
                dropped += 1  // the producer is already reusing this (old) slot
                continue
            }
            let slot = Int(index % UInt64(capacity))
            let meta = metas[slot]
            let count = min(Int(meta.frameCount), framesPerPacket)
            let data = [UInt8](UnsafeRawBufferPointer(start: storage + slot * bytesPerPacket, count: count * 4))
            release()
            return Read(packet: AudioRingPacket(meta: meta, data: data), dropped: dropped, backlog: backlog)
        }
    }

    /// Claims published index `index` for copying. false: the producer has started reusing its slot (an index at
    /// least `capacity` newer), so the copy must not happen.
    func claim(_ index: UInt64) -> Bool {
        reading.store(index + 1, ordering: .sequentiallyConsistent)
        if writing.load(ordering: .sequentiallyConsistent) >= index + UInt64(capacity) {
            reading.store(0, ordering: .sequentiallyConsistent)
            return false
        }
        return true
    }

    func release() {
        reading.store(0, ordering: .releasing)
    }

    /// Packets the producer dropped since the last call (its slot was being read).
    public func takeProducerDrops() -> Int { producerDropCount.exchange(0, ordering: .relaxed) }

    /// Packets published so far (diagnostics and tests).
    public var publishedCount: UInt64 { published.load(ordering: .acquiring) }
}
