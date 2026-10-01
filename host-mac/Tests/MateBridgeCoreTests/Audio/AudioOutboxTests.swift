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
}
