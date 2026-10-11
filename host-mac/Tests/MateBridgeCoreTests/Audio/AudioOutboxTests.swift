import Testing
@testable import MateBridgeCore

/// The session server's audio outbox: bounded, newest frames win, order kept, configs never dropped.
@Suite struct AudioOutboxTests {
    private func frame(_ seq: UInt32, capture: UInt64 = 0) -> Message {
        .audioFrame(AudioFrame(streamID: 1, seq: seq, sampleIndex: UInt64(seq) * 480, captureTimeUs: capture,
                               frameCount: 1, data: [0, 0, 0, 0]))
    }

    private func describe(_ items: [AudioOutbox.Item]) -> [String] {
        items.map {
            switch $0.message {
            case .audioFrame(let f): return "f\(f.seq)"
            case .audioConfig(let c): return "cfg\(c.state == .started ? "+" : "-")\(c.streamID)"
            default: return "other"
            }
        }
    }

    @Test func oneDrainPassPendingAtATime() {
        var box = AudioOutbox()
        #expect(box.push(sessionID: 7, frame(0)) == (true, 0))
        #expect(box.push(sessionID: 7, frame(1)) == (false, 0))
        #expect(describe(box.take()) == ["f0", "f1"])
        #expect(box.take().isEmpty)
        #expect(box.push(sessionID: 7, frame(2)).enqueueDrain)
    }

    @Test func stalledQueueKeepsTheNewestTenFrames() {
        var box = AudioOutbox()
        var dropped = 0
        for seq in 0..<25 { dropped += box.push(sessionID: 7, frame(UInt32(seq))).dropped }
        #expect(dropped == 15)
        #expect(describe(box.take()) == (15..<25).map { "f\($0)" })
    }

    @Test func configsKeepTheirPlaceAndAreNeverDropped() {
        var box = AudioOutbox()
        _ = box.push(sessionID: 7, .audioConfig(AudioStreamPolicy.startedConfig(streamID: 1)))
        for seq in 0..<10 { _ = box.push(sessionID: 7, frame(UInt32(seq))) }
        _ = box.push(sessionID: 7, .audioConfig(.stopped(streamID: 1)))
        _ = box.push(sessionID: 7, .audioConfig(AudioStreamPolicy.startedConfig(streamID: 2)))
        _ = box.push(sessionID: 7, frame(100))
        _ = box.push(sessionID: 7, frame(101))
        #expect(describe(box.take())
            == ["cfg+1"] + (2..<10).map { "f\($0)" } + ["cfg-1", "cfg+2", "f100", "f101"])
    }

    @Test func staleAfterHundredMs() {
        let f = AudioFrame(streamID: 1, seq: 0, sampleIndex: 0, captureTimeUs: 1_000_000, frameCount: 1,
                           data: [0, 0, 0, 0])
        #expect(!AudioOutbox.isStale(f, nowUs: 1_100_000))
        #expect(AudioOutbox.isStale(f, nowUs: 1_100_001))
        #expect(!AudioOutbox.isStale(f, nowUs: 900_000))  // a capture time ahead of now is never stale
    }

    private func aacFrame(_ seq: UInt32) -> Message {
        .audioFrame(AudioFrame(streamID: 1, seq: seq, sampleIndex: UInt64(seq) * 1024, captureTimeUs: 0,
                               frameCount: 1024, data: [UInt8](repeating: 0, count: 256)))
    }

    private func pcmFrame(_ seq: UInt32) -> Message {
        .audioFrame(AudioFrame(streamID: 1, seq: seq, sampleIndex: UInt64(seq) * 480, captureTimeUs: 0,
                               frameCount: 480, data: [UInt8](repeating: 0, count: 1920)))
    }

    @Test func aacBacklogIsAtMost100msOfAudio() {
        var box = AudioOutbox()
        for seq in 0..<25 { _ = box.push(sessionID: 7, aacFrame(UInt32(seq))) }
        // 4 units x 1024 = 4096 frames = 85 ms; a 5th would make 106 ms.
        #expect(describe(box.take()) == (21..<25).map { "f\($0)" })
        var pcm = AudioOutbox()
        for seq in 0..<25 { _ = pcm.push(sessionID: 7, pcmFrame(UInt32(seq))) }
        #expect(describe(pcm.take()) == (15..<25).map { "f\($0)" })  // PCM unchanged: 10 x 10 ms
        #expect(AudioOutbox.backlogFrames(frameCount: 1024) == 4 && AudioOutbox.backlogFrames(frameCount: 480) == 10)
    }

    @Test func aacStalenessAllowsTheEncoderDelay() {
        let aac = AudioFrame(streamID: 1, seq: 0, sampleIndex: 0, captureTimeUs: 1_000_000, frameCount: 1024,
                             data: [0])
        #expect(!AudioOutbox.isStale(aac, nowUs: 1_000_000 + 100_000 + AudioOutbox.aacAllowanceUs))
        #expect(AudioOutbox.isStale(aac, nowUs: 1_000_001 + 100_000 + AudioOutbox.aacAllowanceUs))
    }

    @Test func aacKernelMarkIsFarBelowThePCMMark() {
        let pcm = AudioStreamPolicy.startedConfig(streamID: 1)
        let aac = AudioStreamPolicy.startedConfig(streamID: 1, codec: .aac)
        let pcmMark = AudioOutbox.notSentLowatBytes(for: pcm, framingBytes: 49)
        let aacMark = AudioOutbox.notSentLowatBytes(for: aac, framingBytes: 49)
        #expect(pcmMark == 9 * (49 + 1920))
        #expect(aacMark == 3 * (49 + 256))  // under 100 ms of 96 kbps audio
    }
}
