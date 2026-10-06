import Foundation
import Testing
@testable import MateBridgeCore

/// `AudioStreamer` with a fake capture backend and a fake sink: no Core Audio, no permission prompt.
@Suite struct AudioStreamerTests {
    final class FakeBackend: AudioCaptureBackend, @unchecked Sendable {
        private let lock = NSLock()
        private var _calls: [String] = []
        private var _packetizers: [UInt16: AudioPacketizer] = [:]
        private var _events: [UInt16: @Sendable (AudioCaptureEvent) -> Void] = [:]

        var calls: [String] { lock.withLock { _calls } }
        func packetizer(_ id: UInt16) -> AudioPacketizer? { lock.withLock { _packetizers[id] } }

        func start(streamID: UInt16, packetizer: AudioPacketizer,
                   events: @escaping @Sendable (AudioCaptureEvent) -> Void) {
            lock.withLock {
                _calls.append("start \(streamID)")
                _packetizers[streamID] = packetizer
                _events[streamID] = events
            }
        }

        func stop(streamID: UInt16) { lock.withLock { _calls.append("stop \(streamID)") } }

        func emit(_ event: AudioCaptureEvent, for id: UInt16) {
            let handler = lock.withLock { _events[id] }
            handler?(event)
        }
    }

    final class FakeSink: AudioSink, @unchecked Sendable {
        private let lock = NSLock()
        private var _sent: [(UInt32, Message)] = []
        private var _wireDrops = 0
        var sent: [(UInt32, Message)] { lock.withLock { _sent } }
        func sendAudio(sessionID: UInt32, _ message: Message) { lock.withLock { _sent.append((sessionID, message)) } }
        func takeAudioWireDrops() -> Int { lock.withLock { defer { _wireDrops = 0 }; return _wireDrops } }
        func addWireDrops(_ n: Int) { lock.withLock { _wireDrops += n } }

        /// Compact view: "cfg+1" (STARTED stream 1), "cfg-1" (STOPPED), "f1#0@480" (frame of stream 1, seq 0, index 480).
        var summary: [String] {
            sent.map { _, m in
                switch m {
                case .audioConfig(let c): return "cfg\(c.state == .started ? "+" : "-")\(c.streamID)"
                case .audioFrame(let f): return "f\(f.streamID)#\(f.seq)@\(f.sampleIndex)"
                default: return "other"
                }
            }
        }
    }

    final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var _now: UInt64 = 0
        private var _logs: [String] = []
        var now: UInt64 {
            get { lock.withLock { _now } }
            set { lock.withLock { _now = newValue } }
        }
        var logs: [String] { lock.withLock { _logs } }
        func log(_ s: String) { lock.withLock { _logs.append(s) } }
    }

    private struct Harness {
        let backend = FakeBackend()
        let sink = FakeSink()
        let box = Box()
        let streamer: AudioStreamer

        init(disabled: Bool = false) {
            var options = AudioStreamer.Options()
            options.drainInterval = nil
            options.retryDelay = .milliseconds(5)
            let box = self.box
            // 1 tick = 1 us keeps the arithmetic readable.
            streamer = AudioStreamer(backend: backend, disabled: disabled,
                                     clock: .init(nowUs: { box.now }, hostTicksToUs: { $0 }), options: options,
                                     log: { level, ev, sid, fields in box.log("\(level.rawValue) sid=\(sid) \(ev) \(fields)") })
            streamer.attach(sink: sink)
        }

        func feed(_ id: UInt16, packets: Int, hostTime: UInt64 = 1_000) {
            guard let p = backend.packetizer(id) else { return }
            let samples = [Float](repeating: 0.25, count: 480 * 2)
            for k in 0..<packets {
                samples.withUnsafeBufferPointer {
                    p.ingest(.interleaved($0.baseAddress!), frames: 480, hostTime: hostTime + UInt64(k) * 10_000,
                             sampleTime: nil)
                }
            }
        }

        func started(_ id: UInt16) {
            backend.emit(.started(streamID: id), for: id)
            streamer.sync()
        }
    }

    @Test func fullLifecycleStartedFramesStopped() {
        let h = Harness()
        h.streamer.sessionStarted(sessionID: 7, clientSupportsAudio: true)
        h.streamer.prefs(sessionID: 7, enabled: true)
        h.streamer.sync()
        #expect(h.backend.calls == ["start 1"])
        h.feed(1, packets: 1)  // captured before STARTED went out: still sent after it
        h.started(1)
        h.feed(1, packets: 2, hostTime: 50_000)
        h.streamer.drainNow()
        #expect(h.sink.summary == ["cfg+1", "f1#0@0", "f1#1@480", "f1#2@960"])
        #expect(h.sink.sent.allSatisfy { $0.0 == 7 })
        guard case .audioFrame(let f) = h.sink.sent[2].1 else { Issue.record("no frame"); return }
        #expect(f.captureTimeUs == 50_000)
        #expect(f.frameCount == 480 && f.data.count == 1920)
        h.streamer.prefs(sessionID: 7, enabled: false)
        h.feed(1, packets: 1)
        h.streamer.drainNow()
        #expect(h.sink.summary.suffix(1) == ["cfg-1"])  // nothing of the stream after STOPPED
        #expect(h.backend.calls == ["start 1", "stop 1"])
    }

    @Test func frameTimeIncludesOffsetIntoCallback() {
        let h = Harness()
        h.streamer.sessionStarted(sessionID: 7, clientSupportsAudio: true)
        h.streamer.prefs(sessionID: 7, enabled: true)
        h.streamer.sync()
        h.started(1)
        let p = h.backend.packetizer(1)!
        let samples = [Float](repeating: 0, count: 720 * 2)
        samples.withUnsafeBufferPointer {
            p.ingest(.interleaved($0.baseAddress!), frames: 240, hostTime: 0, sampleTime: nil)
            p.ingest(.interleaved($0.baseAddress!), frames: 720, hostTime: 100_000, sampleTime: nil)
        }
        h.streamer.drainNow()
        let times = h.sink.sent.compactMap { if case .audioFrame(let f) = $0.1 { return f.captureTimeUs } else { return nil } }
        #expect(times == [0, 100_000 + 5_000])  // second packet starts 240 frames (5 ms) into the second callback
    }

    @Test func sessionEndStopsImmediatelyWithoutStopped() {
        let h = Harness()
        h.streamer.sessionStarted(sessionID: 7, clientSupportsAudio: true)
        h.streamer.prefs(sessionID: 7, enabled: true)
        h.streamer.sync()
        h.started(1)
        h.streamer.sessionEnded()
        h.feed(1, packets: 3)
        h.streamer.drainNow()
        #expect(h.sink.summary == ["cfg+1"])
        #expect(h.backend.calls == ["start 1", "stop 1"])
    }

    @Test func noAudioWithoutCapabilityOrPrefs() {
        let h = Harness()
        h.streamer.sessionStarted(sessionID: 7, clientSupportsAudio: false)
        h.streamer.prefs(sessionID: 7, enabled: true)
        h.streamer.sessionStarted(sessionID: 8, clientSupportsAudio: true)
        h.streamer.sync()
        #expect(h.backend.calls.isEmpty)
        #expect(h.sink.sent.isEmpty)
    }

    @Test func envKillSwitch() {
        let h = Harness(disabled: true)
        h.streamer.sessionStarted(sessionID: 7, clientSupportsAudio: true)
        h.streamer.prefs(sessionID: 7, enabled: true)
        h.streamer.sync()
        #expect(h.backend.calls.isEmpty)
        #expect(h.box.logs.contains { $0.contains("audio_unavailable reason=disabled_by_env") })
    }

    @Test func failedCaptureLogsAndSendsNothing() {
        let h = Harness()
        h.streamer.sessionStarted(sessionID: 7, clientSupportsAudio: true)
        h.streamer.prefs(sessionID: 7, enabled: true)
        h.streamer.sync()
        h.backend.emit(.failed(streamID: 1, reason: "ioproc_create", status: -1), for: 1)
        h.streamer.sync()
        #expect(h.sink.sent.isEmpty)
        #expect(h.box.logs.filter { $0.contains("audio_unavailable") }
            == ["W sid=7 audio_unavailable reason=ioproc_create status=-1 stream_id=1"])
    }

    @Test func interruptionRebuildsWithNewStreamAndFreshSeq() {
        let h = Harness()
        h.streamer.sessionStarted(sessionID: 7, clientSupportsAudio: true)
        h.streamer.prefs(sessionID: 7, enabled: true)
        h.streamer.sync()
        h.started(1)
        h.feed(1, packets: 2)
        h.streamer.drainNow()
        h.backend.emit(.interrupted(streamID: 1, reason: "default_output_changed"), for: 1)
        h.streamer.sync()
        #expect(h.backend.calls == ["start 1", "stop 1", "start 2"])
        h.feed(1, packets: 1)  // old run still delivering: nobody reads it any more
        h.started(2)
        h.feed(2, packets: 1)
        h.streamer.drainNow()
        #expect(h.sink.summary == ["cfg+1", "f1#0@0", "f1#1@480", "cfg-1", "cfg+2", "f2#0@0"])
    }

    @Test func failedRebuildIsRetriedAfterTheDelay() async throws {
        let h = Harness()
        h.streamer.sessionStarted(sessionID: 7, clientSupportsAudio: true)
        h.streamer.prefs(sessionID: 7, enabled: true)
        h.streamer.sync()
        h.started(1)
        h.backend.emit(.interrupted(streamID: 1, reason: "wake"), for: 1)
        h.streamer.sync()
        h.backend.emit(.failed(streamID: 2, reason: "no_output_device", status: 0), for: 2)
        h.streamer.sync()
        #expect(h.backend.calls == ["start 1", "stop 1", "start 2", "stop 2"])
        for _ in 0..<200 where h.backend.calls.count < 5 { try await Task.sleep(for: .milliseconds(5)) }
        #expect(h.backend.calls == ["start 1", "stop 1", "start 2", "stop 2", "start 3"])
        h.started(3)
        #expect(h.sink.summary == ["cfg+1", "cfg-1", "cfg+3"])
        #expect(!h.box.logs.contains { $0.contains("audio_unavailable") })
    }

    @Test func transientStartFailureAfterATakeoverIsRetriedAfterTheDelay() async throws {
        let h = Harness()
        h.streamer.sessionStarted(sessionID: 7, clientSupportsAudio: true)
        h.streamer.prefs(sessionID: 7, enabled: true)
        h.streamer.sync()
        h.started(1)
        h.streamer.sessionStarted(sessionID: 8, clientSupportsAudio: true)  // takeover
        h.streamer.prefs(sessionID: 8, enabled: true)
        h.streamer.sync()
        #expect(h.backend.calls == ["start 1", "stop 1", "start 2"])
        h.backend.emit(.failed(streamID: 2, reason: "tap_create", status: 0), for: 2)
        h.streamer.sync()
        #expect(h.backend.calls == ["start 1", "stop 1", "start 2", "stop 2"])
        for _ in 0..<200 where h.backend.calls.count < 5 { try await Task.sleep(for: .milliseconds(5)) }
        #expect(h.backend.calls == ["start 1", "stop 1", "start 2", "stop 2", "start 3"])
        h.started(3)
        #expect(h.sink.sent.map(\.0) == [7, 8])
        #expect(h.sink.summary == ["cfg+1", "cfg+3"])
        #expect(h.box.logs.contains("I sid=8 audio_retry reason=tap_create attempt=1 delay_ms=100 status=0 stream_id=2"))
        #expect(!h.box.logs.contains { $0.contains("audio_unavailable") })
    }

    @Test func sessionEndWhileATransientRetryWaitsStartsNothing() async throws {
        let h = Harness()
        h.streamer.sessionStarted(sessionID: 7, clientSupportsAudio: true)
        h.streamer.prefs(sessionID: 7, enabled: true)
        h.streamer.sync()
        h.backend.emit(.failed(streamID: 1, reason: "tap_create", status: 0), for: 1)
        h.streamer.sync()
        h.streamer.sessionEnded()
        h.streamer.sync()
        try await Task.sleep(for: .milliseconds(50))  // well past the 5 ms test delay
        h.streamer.sync()
        #expect(h.backend.calls == ["start 1", "stop 1"])
        #expect(h.sink.sent.isEmpty)
    }

    @Test func backlogOverHundredMsDropsOldest() {
        let h = Harness()
        h.streamer.sessionStarted(sessionID: 7, clientSupportsAudio: true)
        h.streamer.prefs(sessionID: 7, enabled: true)
        h.streamer.sync()
        h.started(1)
        h.feed(1, packets: 13)
        h.streamer.drainNow()
        let frames = h.sink.summary.dropFirst()
        #expect(frames.count == 10)
        #expect(frames.first == "f1#0@1440")  // packets 0...2 dropped; seq stays contiguous, sample_index jumps
        #expect(frames.last == "f1#9@5760")
    }

    @Test func statsOncePerSecondOnlyWhileStreaming() {
        let h = Harness()
        h.streamer.sessionStarted(sessionID: 7, clientSupportsAudio: true)
        h.streamer.prefs(sessionID: 7, enabled: true)
        h.streamer.sync()
        h.box.now = 10_000_000
        h.started(1)
        h.feed(1, packets: 3)
        h.sink.addWireDrops(2)
        h.box.now = 10_500_000
        h.streamer.drainNow()
        #expect(!h.box.logs.contains { $0.contains(" stats ") })
        h.box.now = 11_000_000
        h.streamer.drainNow()
        let stats = h.box.logs.filter { $0.contains(" stats ") }
        #expect(stats.count == 1)
        #expect(stats.first?.hasPrefix("I sid=7 stats packets=3 dropped=2 ring_ms_max=30 ") == true)
        #expect(stats.first?.contains("rms_dbfs=-12.0 wire_dropped=2") == true)
        h.streamer.prefs(sessionID: 7, enabled: false)
        h.box.now = 20_000_000
        h.streamer.drainNow()
        #expect(h.box.logs.filter { $0.contains(" stats ") }.count == 1)
    }

    // MARK: Silence gate (T-279)

    /// Feeds `packets` packets of the constant `value`, packet `k` of this call at `hostTime + k * 10_000`.
    private func feedConstant(_ h: Harness, _ id: UInt16, value: Float, packets: Int, hostTime: UInt64) {
        guard let p = h.backend.packetizer(id) else { return }
        let samples = [Float](repeating: value, count: 480 * 2)
        for k in 0..<packets {
            samples.withUnsafeBufferPointer {
                p.ingest(.interleaved($0.baseAddress!), frames: 480, hostTime: hostTime + UInt64(k) * 10_000,
                         sampleTime: nil)
            }
        }
    }

    private func startedHarness() -> Harness {
        let h = Harness()
        h.streamer.sessionStarted(sessionID: 7, clientSupportsAudio: true)
        h.streamer.prefs(sessionID: 7, enabled: true)
        h.streamer.sync()
        h.started(1)
        return h
    }

    /// Feeds and drains in chunks of 8 packets, like the sender timer would (the ring holds 16 packets).
    private func pump(_ h: Harness, value: Float, packets: Int, hostTime: UInt64) {
        var done = 0
        while done < packets {
            let n = min(8, packets - done)
            feedConstant(h, 1, value: value, packets: n, hostTime: hostTime + UInt64(done) * 10_000)
            h.streamer.drainNow()
            done += n
        }
    }

    private func frames(_ h: Harness) -> [AudioFrame] {
        h.sink.sent.compactMap { if case .audioFrame(let f) = $0.1 { return f } else { return nil } }
    }

    @Test func zeroPacketsAreSkippedAfterFiftyAndSoundResumesWithContiguousSeq() {
        let h = startedHarness()
        pump(h, value: 0, packets: 80, hostTime: 0)
        #expect(frames(h).count == 50)  // 500 ms of zeros went out, the next 30 did not
        #expect(frames(h).last?.sampleIndex == 49 * 480)
        pump(h, value: 0.25, packets: 2, hostTime: 800_000)
        let f = frames(h)
        #expect(f.count == 52)
        #expect(f.map(\.seq) == Array(0..<52))  // seq counts sent packets
        #expect(f[50].sampleIndex == 80 * 480)  // the skipped 30 packets are a sample_index jump
        #expect(f[50].captureTimeUs == 800_000)
        #expect(f[51].sampleIndex == 81 * 480)
    }

    @Test func shortSilenceIsSentAsIs() {
        let h = startedHarness()
        pump(h, value: 0.25, packets: 5, hostTime: 0)
        pump(h, value: 0, packets: 49, hostTime: 50_000)
        pump(h, value: 0.25, packets: 5, hostTime: 540_000)
        pump(h, value: 0, packets: 50, hostTime: 590_000)
        #expect(frames(h).count == 109)
        #expect(frames(h).map(\.sampleIndex) == (0..<109).map { UInt64($0) * 480 })
    }

    @Test func silenceRunRestartsAfterSound() {
        let h = startedHarness()
        pump(h, value: 0, packets: 60, hostTime: 0)  // 10 skipped
        pump(h, value: 0.25, packets: 1, hostTime: 600_000)
        pump(h, value: 0, packets: 60, hostTime: 610_000)  // a fresh run: 50 sent, 10 skipped
        #expect(frames(h).count == 50 + 1 + 50)
    }

    @Test func firstPacketOfAStreamIsSentEvenIfZero() {
        let h = startedHarness()
        pump(h, value: 0, packets: 1, hostTime: 0)
        #expect(h.sink.summary == ["cfg+1", "f1#0@0"])
    }

    @Test func oneLsbPacketIsNotSilence() {
        let h = startedHarness()
        pump(h, value: 0, packets: 60, hostTime: 0)
        #expect(frames(h).count == 50)
        // 1/32767 converts to s16 value 1 (-90 dBFS); 0.4/32767 rounds to 0.
        pump(h, value: 1.0 / 32767, packets: 1, hostTime: 600_000)
        #expect(frames(h).count == 51)
        pump(h, value: 0.4 / 32767, packets: 1, hostTime: 610_000)
        pump(h, value: 0, packets: 50, hostTime: 620_000)
        #expect(frames(h).count == 51 + 1 + 49)  // the sub-LSB packet counted as zero: the run started after the LSB one
    }

    @Test func newStreamStartsOpenAfterInterruption() {
        let h = startedHarness()
        pump(h, value: 0, packets: 60, hostTime: 0)
        #expect(frames(h).count == 50)
        h.backend.emit(.interrupted(streamID: 1, reason: "default output changed"), for: 1)
        h.streamer.sync()
        h.started(2)
        feedConstant(h, 2, value: 0, packets: 3, hostTime: 1_000_000)
        h.streamer.drainNow()
        let f = frames(h).filter { $0.streamID == 2 }
        #expect(f.map(\.seq) == [0, 1, 2])
    }

    @Test func statsCountSkippedAndLevelCoversSentPacketsOnly() {
        let h = startedHarness()
        h.box.now = 0
        pump(h, value: 0, packets: 80, hostTime: 0)
        h.box.now = 1_000_000
        h.streamer.drainNow()
        let stats = h.box.logs.filter { $0.contains(" stats ") }
        #expect(stats.count == 1)
        #expect(stats.first?.hasPrefix("I sid=7 stats packets=50 ") == true)
        #expect(stats.first?.hasSuffix("rms_dbfs=-120.0 wire_dropped=0 silent_skipped=30") == true)
    }

    @Test func prefsBurstCoalescesAndSessionEndIsNotDelayed() {
        let h = Harness()
        h.streamer.sessionStarted(sessionID: 7, clientSupportsAudio: true)
        h.streamer.prefs(sessionID: 7, enabled: true)
        h.streamer.sync()
        h.started(1)
        h.streamer.suspendForTesting()  // a stalled streamer queue
        for k in 0..<10_000 { h.streamer.prefs(sessionID: 7, enabled: k % 2 == 0) }
        h.streamer.sessionEnded()
        h.streamer.resumeForTesting()
        h.streamer.sync()
        #expect(h.backend.calls == ["start 1", "stop 1"])  // one pass: the session is gone, nothing restarts
        #expect(h.sink.summary == ["cfg+1"])
    }

    @Test func latestPrefsWinsAndOffOnStillRetriesAFailure() {
        let h = Harness()
        h.streamer.sessionStarted(sessionID: 7, clientSupportsAudio: true)
        h.streamer.prefs(sessionID: 7, enabled: true)
        h.streamer.sync()
        h.backend.emit(.failed(streamID: 1, reason: "ioproc_create", status: -1), for: 1)
        h.streamer.sync()
        h.streamer.suspendForTesting()
        h.streamer.prefs(sessionID: 7, enabled: false)
        h.streamer.prefs(sessionID: 7, enabled: true)
        h.streamer.resumeForTesting()
        h.streamer.sync()
        #expect(h.backend.calls == ["start 1", "stop 1", "start 2"])
    }

    @Test func sessionsCoalescedToTheLatest() {
        let h = Harness()
        h.streamer.suspendForTesting()
        h.streamer.sessionStarted(sessionID: 7, clientSupportsAudio: true)
        h.streamer.prefs(sessionID: 7, enabled: true)
        h.streamer.sessionEnded()
        h.streamer.sessionStarted(sessionID: 9, clientSupportsAudio: true)
        h.streamer.prefs(sessionID: 9, enabled: true)
        h.streamer.resumeForTesting()
        h.streamer.sync()
        #expect(h.backend.calls == ["start 1"])
        h.started(1)
        #expect(h.sink.sent.map(\.0) == [9])
    }

    @Test func inboxQueuesOnePassUntilTaken() {
        var inbox = AudioControlInbox()
        let first = inbox.sessionStarted(sessionID: 7, clientSupportsAudio: true)
        let second = inbox.prefs(sessionID: 7, enabled: false)
        let third = inbox.prefs(sessionID: 7, enabled: true)
        #expect(first && !second && !third)
        let snap = inbox.take()
        #expect(snap.session?.sessionID == 7)
        #expect(snap.prefs == .init(sessionID: 7, enabled: true, sawDisable: true))
        let again = inbox.take()
        #expect(again.prefs == nil)
        let requeued = inbox.prefs(sessionID: 7, enabled: true)  // queued again after the pass started
        let ended = inbox.sessionEnded()
        #expect(requeued && !ended)
        let last = inbox.take()
        #expect(last == .init(session: nil, prefs: nil))
    }

    @Test func shutdownStopsSynchronously() {
        let h = Harness()
        h.streamer.sessionStarted(sessionID: 7, clientSupportsAudio: true)
        h.streamer.prefs(sessionID: 7, enabled: true)
        h.streamer.sync()
        h.started(1)
        h.streamer.shutdown()
        #expect(h.backend.calls == ["start 1", "stop 1"])
    }
}
