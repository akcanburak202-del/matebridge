/// Producer side of one audio stream: cuts IOProc callbacks (any length, typically 240 frames) into packets of
/// `framesPerPacket` frames written straight into the ring slot (decision 0011: 10 ms = 480 frames).
///
/// Called only from the Core Audio real-time thread, one callback at a time: no allocation, no locks, no logging.
/// - `sample_index` counts frames from the start of the stream. When the device reports a jump in its sample time
///   (the HAL skipped frames), the partial packet is published as is and the index advances by the gap, so the
///   client hears silence for exactly the missing time.
/// - A packet's time is the host time of the callback that delivered its first frame plus that frame's offset.
public final class AudioPacketizer: @unchecked Sendable {
    public let ring: AudioPacketRing

    private var fill = 0
    private var nextSampleIndex: UInt64 = 0
    private var expectedSampleTime: Double?
    private var pendingCallbackMaxTicks: UInt64 = 0
    private var slotData: UnsafeMutableRawPointer?
    private var slotMeta: UnsafeMutablePointer<AudioSlotMeta>?

    public init(ring: AudioPacketRing) {
        self.ring = ring
    }

    /// One IOProc callback: `frames` stereo frames from `source`.
    /// - Parameters:
    ///   - hostTime: host time (mach ticks) of the first frame.
    ///   - sampleTime: the device's sample time of the first frame, when valid.
    public func ingest(_ source: PCMSource, frames: Int, hostTime: UInt64, sampleTime: Double?) {
        guard frames > 0 else { return }
        if let sampleTime {
            if let expected = expectedSampleTime {
                let gap = (sampleTime - expected).rounded()
                if gap >= 1, gap < 1e12 {
                    if fill > 0 { publishCurrent() }
                    nextSampleIndex &+= UInt64(gap)
                }
            }
            expectedSampleTime = sampleTime + Double(frames)
        }
        let perPacket = ring.framesPerPacket
        var offset = 0
        while offset < frames {
            if fill == 0 { beginPacket(hostTime: hostTime, offset: offset) }
            let n = min(frames - offset, perPacket - fill)
            let squares = PCMConvert.convertStereo(source, offset: offset, frames: n, into: slotData! + fill * 4)
            slotMeta!.pointee.sumSquares += squares
            fill += n
            offset += n
            nextSampleIndex &+= UInt64(n)
            if fill == perPacket { publishCurrent() }
        }
    }

    /// Duration of the callback that just finished (mach ticks); reported with the next published packet.
    public func recordCallback(ticks: UInt64) {
        pendingCallbackMaxTicks = max(pendingCallbackMaxTicks, ticks)
    }

    private func beginPacket(hostTime: UInt64, offset: Int) {
        let slot = ring.producerSlot()
        slotData = slot.data
        slotMeta = slot.meta
        slot.meta.pointee.sampleIndex = nextSampleIndex
        slot.meta.pointee.hostTime = hostTime
        slot.meta.pointee.hostOffsetFrames = UInt32(offset)
        slot.meta.pointee.frameCount = 0
        slot.meta.pointee.sumSquares = 0
        slot.meta.pointee.callbackMaxTicks = 0
    }

    private func publishCurrent() {
        slotMeta!.pointee.frameCount = UInt32(fill)
        slotMeta!.pointee.callbackMaxTicks = pendingCallbackMaxTicks
        pendingCallbackMaxTicks = 0
        ring.publish()
        fill = 0
        slotData = nil
        slotMeta = nil
    }
}
