import Foundation
import Testing
@testable import MateBridgeCore

/// AAC-LC audio (decision 0038, T-340): codec choice in the policy, access unit timestamps, the real AudioConverter.
@Suite struct AACAudioTests {
    /// Fake encoder: one 100-byte unit per block, remembers resets.
    final class FakeConverter: AACConverting, @unchecked Sendable {
        let primingFrames: Int
        var blocks = 0
        var resets = 0
        var failAfter: Int?
        init(priming: Int = 2112) { primingFrames = priming }
        func encode(_ pcm: [UInt8]) throws -> [UInt8]? {
            if let failAfter, blocks >= failAfter { throw AudioToolboxAACConverter.Failure.encode(-1) }
            blocks += 1
            return [UInt8](repeating: UInt8(truncatingIfNeeded: blocks), count: 100)
        }
        func reset() { resets += 1 }
    }

    private func packet(frames: Int = 480) -> [UInt8] { [UInt8](repeating: 1, count: frames * 4) }

    // MARK: Policy

    private func start(_ p: inout AudioStreamPolicy, aacHello: Bool, codec: AudioCodecPreference) -> [AudioStreamPolicy.Action] {
        _ = p.sessionStarted(sessionID: 7, clientSupportsAudio: true, clientSupportsAAC: aacHello)
        return p.prefs(sessionID: 7, enabled: true, codec: codec)
    }

    @Test func codecChoiceFollowsHelloBitAndPrefs() {
        for (hello, codec, expected) in [
            (false, AudioCodecPreference.aac, AudioStreamPolicy.Codec.pcm),  // no bit14 -> PCM
            (true, .pcm, .pcm),  // codec 0 -> PCM
            (false, .pcm, .pcm),
            (true, .aac, .aac),
        ] {
            var p = AudioStreamPolicy(disabled: false)
            let actions = start(&p, aacHello: hello, codec: codec)
            #expect(actions.contains(.startCapture(streamID: 1)))
            #expect(p.activeCodec == expected)
            let started = p.captureStarted(streamID: 1)
            let cfg = started.compactMap { if case .send(_, let c) = $0 { return c } else { return nil } }.first
            #expect(cfg?.format == (expected == .aac ? .aacLC : .pcmS16LE))
            #expect(cfg?.framesPerPacket == (expected == .aac ? 1024 : 480))
            #expect(cfg?.sampleRate == 48_000 && cfg?.channels == 2)
        }
    }

    @Test func unknownCodecByteIsPCM() {
        #expect(AudioPrefs(enabled: true, codecWire: 9).codec == .pcm)
    }

    @Test func codecChangeRestartsWithNewStreamID() {
        var p = AudioStreamPolicy(disabled: false)
        _ = start(&p, aacHello: true, codec: .pcm)
        _ = p.captureStarted(streamID: 1)
        let actions = p.prefs(sessionID: 7, enabled: true, codec: .aac)
        #expect(actions.contains(.stopCapture(streamID: 1)))
        #expect(actions.contains(.send(sessionID: 7, .stopped(streamID: 1))))
        #expect(actions.contains(.startCapture(streamID: 2)))
        #expect(p.activeCodec == .aac)
        // Same codec again is a no-op.
        _ = p.captureStarted(streamID: 2)
        #expect(p.prefs(sessionID: 7, enabled: true, codec: .aac).isEmpty)
        // And back.
        let back = p.prefs(sessionID: 7, enabled: true, codec: .pcm)
        #expect(back.contains(.startCapture(streamID: 3)))
    }

    @Test func encoderFailureFallsBackToPCMAndLogsOnce() {
        var p = AudioStreamPolicy(disabled: false)
        _ = start(&p, aacHello: true, codec: .aac)
        let actions = p.aacEncoderFailed(streamID: 1, reason: "encoder_create")
        #expect(actions.contains(.stopCapture(streamID: 1)))
        #expect(actions.contains(.startCapture(streamID: 2)))
        #expect(p.activeCodec == .pcm)
        let logs = actions.filter { if case .log(_, "audio_aac_unavailable", _) = $0 { return true } else { return false } }
        #expect(logs.count == 1)
        // Later AAC requests stay PCM, with no second log.
        _ = p.captureStarted(streamID: 2)
        let again = p.prefs(sessionID: 7, enabled: true, codec: .aac)
        #expect(again.isEmpty && p.activeCodec == .pcm)
    }

    // MARK: Stage arithmetic

    @Test func unitTimestampsSubtractPrimingAndStepBy1024() throws {
        let fake = FakeConverter(priming: 2112)
        let stage = AACStage(converter: fake)
        var units: [AACUnit] = []
        // 7 packets of 480 = 3360 frames -> 3 blocks.
        for k in 0..<7 {
            units += try stage.feed(pcm: packet(), sampleIndex: UInt64(k * 480), captureTimeUs: 1_000_000 + UInt64(k * 10_000))
        }
        #expect(units.count == 3)
        #expect(units.map(\.sampleIndex) == [0, 1024, 2048])
        // unit k: 1_000_000 + (k*1024 - 2112) us at 48 kHz
        let expected = (0..<3).map { Int64(1_000_000) + (Int64($0) * 1024 - 2112) * 1_000_000 / 48_000 }
        #expect(units.map { Int64($0.captureTimeUs) } == expected)
    }

    @Test func smallGapIsZeroFilledAndLargeGapResets() throws {
        let fake = FakeConverter()
        let stage = AACStage(converter: fake)
        var units = try stage.feed(pcm: packet(), sampleIndex: 0, captureTimeUs: 1_000_000)
        // Gap of 960 frames (< 4096): filled with zeros; 480 + 960 + 480 = 1920 -> 1 block.
        units += try stage.feed(pcm: packet(), sampleIndex: 1440, captureTimeUs: 1_030_000)
        #expect(units.count == 1 && fake.resets == 0)
        // Large gap: partial block (896 pending) is completed and encoded, converter reset, new segment.
        units += try stage.feed(pcm: packet(), sampleIndex: 100_000, captureTimeUs: 3_000_000)
        #expect(units.count == 2 && fake.resets == 1)
        units += try stage.feed(pcm: packet(), sampleIndex: 100_480, captureTimeUs: 3_010_000)
        units += try stage.feed(pcm: packet(), sampleIndex: 100_960, captureTimeUs: 3_020_000)
        #expect(units.count == 3)
        #expect(units[2].sampleIndex == 100_000)  // new segment starts at its first packet
        #expect(Int64(units[2].captureTimeUs) == 3_000_000 - 2112 * 1_000_000 / 48_000)
    }

    // MARK: Real AudioConverter

    @Test func realConverterEncodesSineAtAbout96kbps() throws {
        let converter = try AudioToolboxAACConverter()
        #expect(converter.primingFrames > 0)
        let stage = AACStage(converter: converter)
        let seconds = 2
        let totalFrames = 48_000 * seconds
        var pcm = [UInt8](repeating: 0, count: totalFrames * 4)
        for i in 0..<totalFrames {
            let v = Int16(8000 * sin(2 * Double.pi * 440 * Double(i) / 48_000)
                + 3000 * sin(2 * Double.pi * 3100 * Double(i) / 48_000))
            let u = UInt16(bitPattern: v)
            for ch in 0..<2 {
                pcm[i * 4 + ch * 2] = UInt8(u & 0xFF)
                pcm[i * 4 + ch * 2 + 1] = UInt8(u >> 8)
            }
        }
        var units: [AACUnit] = []
        var index = 0
        while index + 480 <= totalFrames {
            units += try stage.feed(pcm: Array(pcm[(index * 4)..<((index + 480) * 4)]), sampleIndex: UInt64(index),
                                    captureTimeUs: UInt64(index) * 1_000_000 / 48_000)
            index += 480
        }
        let expectedUnits = index / 1024
        #expect(units.count == expectedUnits)
        #expect(units.allSatisfy { (1...1536).contains($0.data.count) })
        #expect(units.map(\.sampleIndex) == (0..<units.count).map { UInt64($0 * 1024) })
        let bits = units.reduce(0) { $0 + $1.data.count } * 8
        let kbps = Double(bits) / (Double(units.count * 1024) / 48_000) / 1000
        #expect(kbps > 80 && kbps < 112, "average \(kbps) kbps")
    }

    // MARK: Streamer

    private final class Env: @unchecked Sendable {
        let backend = AudioStreamerTests.FakeBackend()
        let sink = AudioStreamerTests.FakeSink()
        let streamer: AudioStreamer
        init(makeConverter: @escaping @Sendable () throws -> AACConverting) {
            var options = AudioStreamer.Options()
            options.drainInterval = nil
            options.makeConverter = makeConverter
            streamer = AudioStreamer(backend: backend, disabled: false,
                                     clock: .init(nowUs: { 0 }, hostTicksToUs: { $0 }), options: options,
                                     log: { _, _, _, _ in })
            streamer.attach(sink: sink)
        }

        func feed(_ id: UInt16, packets: Int, firstHostTime: UInt64 = 0) {
            guard let p = backend.packetizer(id) else { return }
            let samples = [Float](repeating: 0.25, count: 480 * 2)
            for k in 0..<packets {
                samples.withUnsafeBufferPointer {
                    p.ingest(.interleaved($0.baseAddress!), frames: 480, hostTime: firstHostTime + UInt64(k) * 10_000,
                             sampleTime: nil)
                }
            }
        }
    }

    @Test func streamerSendsAccessUnitsAsAudioFrames() {
        let env = Env(makeConverter: { FakeConverter() })
        env.streamer.sessionStarted(sessionID: 7, clientSupportsAudio: true, clientSupportsAAC: true)
        env.streamer.prefs(sessionID: 7, enabled: true, codec: .aac)
        env.streamer.sync()
        env.backend.emit(.started(streamID: 1), for: 1)
        env.streamer.sync()
        env.feed(1, packets: 5)  // 2400 frames -> 2 units
        env.streamer.drainNow()
        guard case .audioConfig(let cfg) = env.sink.sent[0].1 else { Issue.record("no config"); return }
        #expect(cfg.format == .aacLC && cfg.framesPerPacket == 1024)
        let frames = env.sink.sent.compactMap { m -> AudioFrame? in
            if case .audioFrame(let f) = m.1 { return f } else { return nil }
        }
        #expect(frames.count == 2)
        #expect(frames.map(\.frameCount) == [1024, 1024])
        #expect(frames.map(\.seq) == [0, 1])
        #expect(frames.map(\.sampleIndex) == [0, 1024])
        #expect(frames.allSatisfy { $0.data.count == 100 })
    }

    @Test func streamerFallsBackToPCMWhenEncoderCannotBeCreated() {
        let env = Env(makeConverter: { throw AudioToolboxAACConverter.Failure.create(-1) })
        env.streamer.sessionStarted(sessionID: 7, clientSupportsAudio: true, clientSupportsAAC: true)
        env.streamer.prefs(sessionID: 7, enabled: true, codec: .aac)
        env.streamer.sync()
        #expect(env.backend.calls.contains("start 2"))  // the AAC attempt (1) was replaced by a PCM stream
        env.backend.emit(.started(streamID: 2), for: 2)
        env.streamer.sync()
        guard case .audioConfig(let cfg) = env.sink.sent.first?.1 else { Issue.record("no config"); return }
        #expect(cfg.streamID == 2 && cfg.format == .pcmS16LE)
    }

    @Test func streamerCodecChangeUsesNewStreamID() {
        let env = Env(makeConverter: { FakeConverter() })
        env.streamer.sessionStarted(sessionID: 7, clientSupportsAudio: true, clientSupportsAAC: true)
        env.streamer.prefs(sessionID: 7, enabled: true, codec: .pcm)
        env.streamer.sync()
        env.backend.emit(.started(streamID: 1), for: 1)
        env.streamer.sync()
        env.streamer.prefs(sessionID: 7, enabled: true, codec: .aac)
        env.streamer.sync()
        env.backend.emit(.started(streamID: 2), for: 2)
        env.streamer.sync()
        #expect(env.sink.summary == ["cfg+1", "cfg-1", "cfg+2"])
        guard case .audioConfig(let cfg) = env.sink.sent[2].1 else { return }
        #expect(cfg.format == .aacLC)
    }
}
