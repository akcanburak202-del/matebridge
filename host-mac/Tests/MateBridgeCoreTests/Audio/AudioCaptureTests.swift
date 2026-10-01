import Foundation
import Synchronization
import Testing
@testable import MateBridgeCore

/// Pure capture-path pieces of T-094: Float32 -> s16le, the packet ring, the packetizer, tap buffer layout, stats.
@Suite struct AudioCaptureTests {
    // MARK: PCMConvert

    @Test func s16ClampsAndRoundsHalfAwayFromZero() {
        #expect(PCMConvert.s16(0) == 0)
        #expect(PCMConvert.s16(1) == 32767)
        #expect(PCMConvert.s16(-1) == -32767)
        #expect(PCMConvert.s16(2.5) == 32767)
        #expect(PCMConvert.s16(-7) == -32767)
        #expect(PCMConvert.s16(.infinity) == 32767)
        #expect(PCMConvert.s16(-.infinity) == -32767)
        #expect(PCMConvert.s16(.nan) == 0)
        #expect(PCMConvert.s16(0.5) == 16384)  // 16383.5 rounds away from zero
        #expect(PCMConvert.s16(-0.5) == -16384)
        #expect(PCMConvert.s16(1 / 32767) == 1)
    }

    private func le16(_ bytes: [UInt8], _ i: Int) -> Int16 {
        Int16(bitPattern: UInt16(bytes[2 * i]) | UInt16(bytes[2 * i + 1]) << 8)
    }

    @Test func convertsInterleavedWithOffsetToLittleEndian() {
        let src: [Float] = [9, 9, 0.5, -0.5, 1, -1]  // frame 0 skipped by offset
        var out = [UInt8](repeating: 0xAA, count: 8)
        let squares = src.withUnsafeBufferPointer { s in
            out.withUnsafeMutableBytes { d in
                PCMConvert.convertStereo(.interleaved(s.baseAddress!), offset: 1, frames: 2, into: d.baseAddress!)
            }
        }
        #expect(out == [0x00, 0x40, 0x00, 0xC0, 0xFF, 0x7F, 0x01, 0x80])
        let half = Double(16384) / 32767
        #expect(abs(squares - (2 * half * half + 2)) < 1e-9)
    }

    @Test func convertsPlanarInterleavingChannels() {
        let left: [Float] = [0.25, 1]
        let right: [Float] = [-0.25, -2]
        var out = [UInt8](repeating: 0, count: 8)
        left.withUnsafeBufferPointer { l in
            right.withUnsafeBufferPointer { r in
                out.withUnsafeMutableBytes { d in
                    _ = PCMConvert.convertStereo(.planar(left: l.baseAddress!, right: r.baseAddress!), offset: 0,
                                                 frames: 2, into: d.baseAddress!)
                }
            }
        }
        #expect([le16(out, 0), le16(out, 1), le16(out, 2), le16(out, 3)] == [8192, -8192, 32767, -32767])
    }

    // MARK: Ring

    /// Tries to publish `count` packets whose samples all equal the packet's attempt index (mod 30000). Returns how
    /// many the ring refused (slot held by the consumer).
    @discardableResult
    private static func publish(_ ring: AudioPacketRing, count: Int, startIndex: UInt64 = 0) -> Int {
        var refused = 0
        for k in 0..<count {
            guard let slot = ring.beginWrite() else {
                refused += 1
                continue
            }
            let index = startIndex + UInt64(k)
            slot.meta.pointee.sampleIndex = index
            slot.meta.pointee.hostTime = 1000 + index
            slot.meta.pointee.frameCount = UInt32(ring.framesPerPacket)
            let v = Int16(index % 30000)
            for i in 0..<(ring.framesPerPacket * 2) {
                slot.data.storeBytes(of: v.littleEndian, toByteOffset: i * 2, as: Int16.self)
            }
            ring.publish()
        }
        return refused
    }

    @Test func ringReturnsPacketsInOrder() {
        let ring = AudioPacketRing(capacity: 16, framesPerPacket: 4)
        #expect(ring.next(maxPending: 10) == AudioPacketRing.Read(packet: nil, dropped: 0, backlog: 0))
        Self.publish(ring, count: 3)
        for i in 0..<3 {
            let r = ring.next(maxPending: 10)
            #expect(r.packet?.meta.sampleIndex == UInt64(i))
            #expect(r.packet?.data.count == 16)
            #expect(r.dropped == 0)
            #expect(r.backlog == 3 - i)
        }
        #expect(ring.next(maxPending: 10).packet == nil)
    }

    @Test func ringOverflowDropsOldestAndKeepsNewestHundredMs() {
        let ring = AudioPacketRing(capacity: 16, framesPerPacket: 4)
        Self.publish(ring, count: 14)  // consumer stalled for 140 ms
        let first = ring.next(maxPending: 10)
        #expect(first.dropped == 4)
        #expect(first.backlog == 14)
        #expect(first.packet?.meta.sampleIndex == 4)  // packets 0...3 (oldest) gone: the index jumps
        var last: UInt64 = 4
        while let p = ring.next(maxPending: 10).packet { last = p.meta.sampleIndex }
        #expect(last == 13)
    }

    @Test func ringSurvivesProducerLappingTheConsumer() {
        let ring = AudioPacketRing(capacity: 16, framesPerPacket: 4)
        Self.publish(ring, count: 40)  // reused every slot more than twice
        let r = ring.next(maxPending: 10)
        #expect(r.dropped == 30)
        #expect(r.packet?.meta.sampleIndex == 30)
        #expect(r.packet.map { le16($0.data, 0) } == 30)
    }

    @Test func ringPartialPacketCarriesOnlyItsFrames() {
        let ring = AudioPacketRing(capacity: 4, framesPerPacket: 8)
        let slot = ring.beginWrite()!
        slot.meta.pointee.frameCount = 3
        ring.publish()
        #expect(ring.next(maxPending: 2).packet?.data.count == 12)
    }

    /// The producer never writes a slot the consumer holds: it drops that (newest) packet and retries the slot next time.
    @Test func producerSkipsTheSlotTheConsumerHolds() {
        let ring = AudioPacketRing(capacity: 4, framesPerPacket: 2)
        Self.publish(ring, count: 1)  // index 0 in slot 0
        #expect(ring.claim(0))
        #expect(Self.publish(ring, count: 3, startIndex: 1) == 0)  // slots 1...3 are free
        #expect(ring.beginWrite() == nil)  // index 4 would reuse slot 0 while it is being copied
        #expect(ring.publishedCount == 4)
        #expect(ring.takeProducerDrops() == 1)
        #expect(ring.takeProducerDrops() == 0)
        ring.release()
        #expect(Self.publish(ring, count: 1, startIndex: 4) == 0)
        #expect(ring.publishedCount == 5)
    }

    /// The consumer never copies a slot the producer is (re)filling: that index is old and counted dropped.
    @Test func consumerGivesUpASlotTheProducerIsReusing() {
        let ring = AudioPacketRing(capacity: 4, framesPerPacket: 2)
        Self.publish(ring, count: 4)  // indices 0...3
        #expect(ring.beginWrite() != nil)  // the producer starts index 4 in slot 0, not yet published
        #expect(!ring.claim(0))
        #expect(ring.claim(1))  // slot 1 still holds index 1
        ring.release()
        let r = ring.next(maxPending: 3)
        #expect(r.dropped == 1)  // index 0: maxPending 3 skips it before any claim
        #expect(r.packet?.meta.sampleIndex == 1)
    }

    final class Flag: Sendable {
        let done = Atomic<Bool>(false)
        let refused = Atomic<Int>(0)
    }

    /// A real producer thread against a consumer: every returned packet is internally consistent, indices only grow,
    /// and every attempted packet is accounted for (received, dropped by the consumer, or refused by the producer).
    @Test func ringConcurrentProducerAndConsumerNeverShareASlot() async {
        let ring = AudioPacketRing(capacity: 16, framesPerPacket: 32)
        let total = 20_000
        let flag = Flag()
        let producer = Thread {
            flag.refused.store(Self.publish(ring, count: total), ordering: .relaxed)
            flag.done.store(true, ordering: .releasing)
        }
        producer.start()
        var lastIndex: Int64 = -1
        var received = 0
        var dropped = 0
        while true {
            let finished = flag.done.load(ordering: .acquiring)
            let r = ring.next(maxPending: 10)
            dropped += r.dropped
            if let p = r.packet {
                received += 1
                let v = le16(p.data, 0)
                #expect(Int64(p.meta.sampleIndex) > lastIndex)
                #expect(p.meta.hostTime == 1000 + p.meta.sampleIndex)
                #expect((0..<(p.data.count / 2)).allSatisfy { le16(p.data, $0) == v })
                #expect(UInt64(v) == p.meta.sampleIndex % 30000)
                lastIndex = Int64(p.meta.sampleIndex)
            } else if finished {
                break
            }
        }
        let refused = flag.refused.load(ordering: .relaxed)
        #expect(received + dropped + refused == total)
        #expect(ring.takeProducerDrops() == refused)
        #expect(received > 0)
    }

    @Test func packetizerDropsThePacketWhoseSlotIsHeld() {
        let ring = AudioPacketRing(capacity: 2, framesPerPacket: 480)
        let p = AudioPacketizer(ring: ring)
        ingest(p, frames: 480, value: 0, hostTime: 0, sampleTime: nil)  // index 0, slot 0
        #expect(ring.claim(0))
        ingest(p, frames: 480, value: 0, hostTime: 0, sampleTime: nil)  // slot 1
        ingest(p, frames: 480, value: 0, hostTime: 0, sampleTime: nil)  // slot 0 held: dropped
        ring.release()
        ingest(p, frames: 480, value: 0, hostTime: 0, sampleTime: nil)  // slot 0 again
        #expect(ring.publishedCount == 3)
        #expect(ring.takeProducerDrops() == 1)
        #expect(ring.next(maxPending: 1).packet?.meta.sampleIndex == 1440)  // 960...1439 lost: a gap
    }

    // MARK: Packetizer

    private func ingest(_ p: AudioPacketizer, frames: Int, value: Float, hostTime: UInt64, sampleTime: Double?) {
        let samples = [Float](repeating: value, count: frames * 2)
        samples.withUnsafeBufferPointer {
            p.ingest(.interleaved($0.baseAddress!), frames: frames, hostTime: hostTime, sampleTime: sampleTime)
        }
    }

    @Test func packetizerCutsTwoHundredFortyFrameCallbacksIntoTenMsPackets() {
        let ring = AudioPacketRing(capacity: 16, framesPerPacket: 480)
        let p = AudioPacketizer(ring: ring)
        for k in 0..<4 {
            ingest(p, frames: 240, value: 0.5, hostTime: UInt64(10_000 * k), sampleTime: Double(240 * k))
            p.recordCallback(ticks: UInt64(100 + k))
        }
        #expect(ring.publishedCount == 2)
        let a = ring.next(maxPending: 10).packet!
        let b = ring.next(maxPending: 10).packet!
        #expect(a.meta.sampleIndex == 0 && b.meta.sampleIndex == 480)
        #expect(a.meta.frameCount == 480 && a.data.count == 1920)
        #expect(a.meta.hostTime == 0 && a.meta.hostOffsetFrames == 0)
        #expect(b.meta.hostTime == 20_000)
        #expect(a.meta.callbackMaxTicks == 100)  // published inside callback 1, which had not finished yet
        #expect(b.meta.callbackMaxTicks == 102)
        #expect(le16(a.data, 0) == 16384 && le16(a.data, 959) == 16384)
        let rms = a.meta.sumSquares / 960
        #expect(abs(rms - pow(Double(16384) / 32767, 2)) < 1e-9)
    }

    @Test func packetizerRecordsOffsetWhenPacketStartsMidCallback() {
        let ring = AudioPacketRing(capacity: 16, framesPerPacket: 480)
        let p = AudioPacketizer(ring: ring)
        ingest(p, frames: 300, value: 0, hostTime: 5, sampleTime: 0)
        ingest(p, frames: 300, value: 0, hostTime: 7, sampleTime: 300)
        let a = ring.next(maxPending: 10).packet!
        #expect(a.meta.hostTime == 5 && a.meta.hostOffsetFrames == 0)
        ingest(p, frames: 400, value: 0, hostTime: 9, sampleTime: 600)
        let b = ring.next(maxPending: 10).packet!
        #expect(b.meta.sampleIndex == 480)
        #expect(b.meta.hostTime == 7 && b.meta.hostOffsetFrames == 180)  // frame 480 = 180 frames into callback 2
    }

    @Test func packetizerFlushesPartialPacketAndSkipsIndexOnSampleTimeGap() {
        let ring = AudioPacketRing(capacity: 16, framesPerPacket: 480)
        let p = AudioPacketizer(ring: ring)
        ingest(p, frames: 240, value: 0.1, hostTime: 0, sampleTime: 1000)
        ingest(p, frames: 240, value: 0.1, hostTime: 0, sampleTime: 1240 + 96)  // the HAL skipped 96 frames
        let partial = ring.next(maxPending: 10).packet!
        #expect(partial.meta.sampleIndex == 0)
        #expect(partial.meta.frameCount == 240 && partial.data.count == 960)
        ingest(p, frames: 240, value: 0.1, hostTime: 0, sampleTime: 1576)
        let next = ring.next(maxPending: 10).packet!
        #expect(next.meta.sampleIndex == 240 + 96)
        #expect(next.meta.frameCount == 480)
    }

    @Test func packetizerWithoutSampleTimeCountsFramesOnly() {
        let ring = AudioPacketRing(capacity: 16, framesPerPacket: 480)
        let p = AudioPacketizer(ring: ring)
        for _ in 0..<6 { ingest(p, frames: 160, value: 0, hostTime: 1, sampleTime: nil) }
        #expect(ring.next(maxPending: 10).packet?.meta.sampleIndex == 0)
        #expect(ring.next(maxPending: 10).packet?.meta.sampleIndex == 480)
        #expect(ring.next(maxPending: 10).packet == nil)
    }

    // MARK: Layout, stats, knob

    @Test func tapLayoutPicksTheLastStereoOrLastTwoMonoBuffers() {
        #expect(TapBufferLayout.choose(channelsPerBuffer: [2]) == .interleaved(buffer: 0))
        #expect(TapBufferLayout.choose(channelsPerBuffer: [1, 2]) == .interleaved(buffer: 1))
        #expect(TapBufferLayout.choose(channelsPerBuffer: [2, 1, 1]) == .planar(left: 1, right: 2))
        #expect(TapBufferLayout.choose(channelsPerBuffer: []) == nil)
        #expect(TapBufferLayout.choose(channelsPerBuffer: [1]) == nil)
        #expect(TapBufferLayout.choose(channelsPerBuffer: [6]) == nil)
        #expect(TapBufferLayout.planar(left: 1, right: 2).minimumBufferCount == 3)
    }

    @Test func statsFormatCountersAndLevel() {
        var s = AudioStatsWindow()
        #expect(s.isEmpty)
        #expect(s.rmsDbfs == -120)
        for us in [100, 200, 300, 400] as [UInt64] {
            s.addPacket(frames: 480, channels: 2, sumSquares: 960 * 0.25, callbackUs: us)
        }
        s.addDropped(3)
        s.addWireDropped(1)
        s.noteBacklog(packets: 4, packetMs: 10)
        s.noteBacklog(packets: 2, packetMs: 10)
        #expect(abs(s.rmsDbfs - 20 * log10(0.5)) < 1e-9)
        #expect(s.logFields == "packets=4 dropped=4 ring_ms_max=40 callback_ms_p50_95=0.20/0.40 rms_dbfs=-6.0 "
            + "wire_dropped=1")
    }

    @Test func audioKnobOffOnlyForOff() {
        #expect(AudioKnob.isDisabled(["MATEBRIDGE_AUDIO": "off"]))
        #expect(AudioKnob.isDisabled(["MATEBRIDGE_AUDIO": " OFF "]))
        #expect(!AudioKnob.isDisabled(["MATEBRIDGE_AUDIO": "on"]))
        #expect(!AudioKnob.isDisabled([:]))
    }
}
