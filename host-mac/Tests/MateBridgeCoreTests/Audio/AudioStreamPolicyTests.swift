import Testing
@testable import MateBridgeCore

/// Session rules of PROTOCOL.md 0x30 (host side), decision 0011.
@Suite struct AudioStreamPolicyTests {
    typealias A = AudioStreamPolicy.Action

    private func nonLog(_ actions: [A]) -> [A] {
        actions.filter { if case .log = $0 { return false } else { return true } }
    }

    private func logs(_ actions: [A]) -> [String] {
        actions.compactMap { if case .log(_, let ev, let f) = $0 { return "\(ev) \(f)" } else { return nil } }
    }

    private func running(sid: UInt32 = 7) -> AudioStreamPolicy {
        var p = AudioStreamPolicy(disabled: false)
        _ = p.sessionStarted(sessionID: sid, clientSupportsAudio: true)
        _ = p.prefs(sessionID: sid, enabled: true)
        _ = p.captureStarted(streamID: 1)
        return p
    }

    @Test func startsOnlyAfterPrefsEnabledAndSendsStartedOnceCaptureRuns() {
        var p = AudioStreamPolicy(disabled: false)
        #expect(nonLog(p.sessionStarted(sessionID: 7, clientSupportsAudio: true)) == [])
        #expect(nonLog(p.prefs(sessionID: 7, enabled: true)) == [.startCapture(streamID: 1)])
        #expect(p.runningStreamID == nil)
        let started = p.captureStarted(streamID: 1)
        #expect(nonLog(started) == [.send(sessionID: 7, AudioStreamPolicy.startedConfig(streamID: 1))])
        #expect(logs(started) == ["audio_started stream_id=1"])
        #expect(p.runningStreamID == 1)
        let config = AudioStreamPolicy.startedConfig(streamID: 1)
        #expect(config == AudioConfig(streamID: 1, state: .started, format: .pcmS16LE, sampleRate: 48_000, channels: 2,
                                      framesPerPacket: 480))
    }

    @Test func nothingWithoutAudioCapability() {
        var p = AudioStreamPolicy(disabled: false)
        _ = p.sessionStarted(sessionID: 7, clientSupportsAudio: false)
        #expect(nonLog(p.prefs(sessionID: 7, enabled: true)) == [])
    }

    @Test func nothingBeforeASession() {
        var p = AudioStreamPolicy(disabled: false)
        #expect(p.prefs(sessionID: 7, enabled: true) == [])
        #expect(p.captureStarted(streamID: 1) == [])
    }

    @Test func prefsOfAnotherSessionIgnored() {
        var p = AudioStreamPolicy(disabled: false)
        _ = p.sessionStarted(sessionID: 7, clientSupportsAudio: true)
        #expect(p.prefs(sessionID: 8, enabled: true) == [])
    }

    @Test func envKillSwitchNeverStartsAndLogsOnce() {
        var p = AudioStreamPolicy(disabled: true)
        _ = p.sessionStarted(sessionID: 7, clientSupportsAudio: true)
        let first = p.prefs(sessionID: 7, enabled: true)
        #expect(nonLog(first) == [])
        #expect(logs(first) == ["audio_unavailable reason=disabled_by_env"])
        _ = p.prefs(sessionID: 7, enabled: false)
        #expect(p.prefs(sessionID: 7, enabled: true) == [])
    }

    @Test func disableStopsAtOnceAndSendsStopped() {
        var p = running()
        let actions = p.prefs(sessionID: 7, enabled: false)
        #expect(nonLog(actions) == [.stopCapture(streamID: 1), .send(sessionID: 7, .stopped(streamID: 1))])
        #expect(logs(actions) == ["audio_stopped stream_id=1 reason=prefs"])
        #expect(p.runningStreamID == nil)
    }

    @Test func reEnableStartsANewStream() {
        var p = running()
        _ = p.prefs(sessionID: 7, enabled: false)
        #expect(nonLog(p.prefs(sessionID: 7, enabled: true)) == [.startCapture(streamID: 2)])
        #expect(nonLog(p.captureStarted(streamID: 2)) == [.send(sessionID: 7, AudioStreamPolicy.startedConfig(streamID: 2))])
    }

    @Test func repeatedEnableIsIdempotent() {
        var p = running()
        #expect(nonLog(p.prefs(sessionID: 7, enabled: true)) == [])
        var q = AudioStreamPolicy(disabled: false)
        _ = q.sessionStarted(sessionID: 7, clientSupportsAudio: true)
        _ = q.prefs(sessionID: 7, enabled: true)
        #expect(nonLog(q.prefs(sessionID: 7, enabled: true)) == [])  // still starting
    }

    @Test func sessionEndStopsAtOnceWithoutStopped() {
        var p = running()
        let actions = p.sessionEnded()
        #expect(nonLog(actions) == [.stopCapture(streamID: 1)])
        #expect(logs(actions) == ["audio_stopped stream_id=1 reason=session_end"])
        #expect(p.sessionEnded() == [])
        #expect(p.prefs(sessionID: 7, enabled: true) == [])
    }

    @Test func disableWhileStartingStopsWithoutAnyMessage() {
        var p = AudioStreamPolicy(disabled: false)
        _ = p.sessionStarted(sessionID: 7, clientSupportsAudio: true)
        _ = p.prefs(sessionID: 7, enabled: true)
        #expect(p.prefs(sessionID: 7, enabled: false) == [.stopCapture(streamID: 1)])
        #expect(p.captureStarted(streamID: 1) == [])  // late start of the stopped capture: no STARTED
        #expect(p.captureFailed(streamID: 1, reason: "x", status: 1) == [])
    }

    @Test func sessionEndWhileStartingThenLateEventsIgnored() {
        var p = AudioStreamPolicy(disabled: false)
        _ = p.sessionStarted(sessionID: 7, clientSupportsAudio: true)
        _ = p.prefs(sessionID: 7, enabled: true)
        #expect(nonLog(p.sessionEnded()) == [.stopCapture(streamID: 1)])
        #expect(p.captureStarted(streamID: 1) == [])
        #expect(p.captureInterrupted(streamID: 1, reason: "x") == [])
    }

    @Test func newSessionEndsThePreviousOne() {
        var p = running(sid: 7)
        let actions = p.sessionStarted(sessionID: 9, clientSupportsAudio: true)
        #expect(nonLog(actions) == [.stopCapture(streamID: 1)])
        #expect(p.runningStreamID == nil)
        #expect(nonLog(p.prefs(sessionID: 9, enabled: true)) == [.startCapture(streamID: 2)])
    }

    @Test func failureLogsOnceSendsNothingAndSessionGoesOn() {
        var p = AudioStreamPolicy(disabled: false)
        _ = p.sessionStarted(sessionID: 7, clientSupportsAudio: true)
        _ = p.prefs(sessionID: 7, enabled: true)
        let failed = p.captureFailed(streamID: 1, reason: "ioproc_create", status: -50)
        #expect(nonLog(failed) == [.stopCapture(streamID: 1)])
        #expect(logs(failed) == ["audio_unavailable reason=ioproc_create status=-50 stream_id=1"])
        #expect(nonLog(p.prefs(sessionID: 7, enabled: true)) == [])  // no retry while still enabled
        // An explicit re-enable retries; a second failure is not logged again in this session.
        _ = p.prefs(sessionID: 7, enabled: false)
        #expect(nonLog(p.prefs(sessionID: 7, enabled: true)) == [.startCapture(streamID: 2)])
        #expect(logs(p.captureFailed(streamID: 2, reason: "ioproc_create", status: -50)) == [])
        // A new session logs again.
        _ = p.sessionStarted(sessionID: 8, clientSupportsAudio: true)
        _ = p.prefs(sessionID: 8, enabled: true)
        #expect(logs(p.captureFailed(streamID: 3, reason: "tap_create", status: 1)).count == 1)
    }

    @Test func failureWhileRunningSendsStopped() {
        var p = running()
        let actions = p.captureFailed(streamID: 1, reason: "device_start", status: 3)
        #expect(nonLog(actions) == [.stopCapture(streamID: 1), .send(sessionID: 7, .stopped(streamID: 1))])
    }

    @Test func interruptionSendsStoppedThenRebuildsAsANewStream() {
        var p = running()
        let actions = p.captureInterrupted(streamID: 1, reason: "default_output_changed")
        #expect(nonLog(actions) == [.stopCapture(streamID: 1), .send(sessionID: 7, .stopped(streamID: 1)),
                                    .startCapture(streamID: 2)])
        #expect(logs(actions) == ["audio_rebuild reason=default_output_changed stream_id=1"])
        #expect(nonLog(p.captureStarted(streamID: 2)) == [.send(sessionID: 7, AudioStreamPolicy.startedConfig(streamID: 2))])
        #expect(p.captureInterrupted(streamID: 1, reason: "stale") == [])
    }

    @Test func interruptionWhileStartingSendsNoStopped() {
        var p = AudioStreamPolicy(disabled: false)
        _ = p.sessionStarted(sessionID: 7, clientSupportsAudio: true)
        _ = p.prefs(sessionID: 7, enabled: true)
        #expect(nonLog(p.captureInterrupted(streamID: 1, reason: "wake")) == [.stopCapture(streamID: 1),
                                                                             .startCapture(streamID: 2)])
    }

    @Test func failedRebuildRetriesTwiceASecondApartThenGivesUp() {
        var p = running()
        _ = p.captureInterrupted(streamID: 1, reason: "wake")  // starts stream 2
        let first = p.captureFailed(streamID: 2, reason: "aggregate_create", status: -1)
        #expect(nonLog(first) == [.stopCapture(streamID: 2), .scheduleRetry(token: 1, delayUs: 1_000_000)])
        #expect(!logs(first).contains { $0.hasPrefix("audio_unavailable") })
        #expect(nonLog(p.retryDue(token: 1)) == [.startCapture(streamID: 3)])
        #expect(nonLog(p.captureFailed(streamID: 3, reason: "aggregate_create", status: -1))
            == [.stopCapture(streamID: 3), .scheduleRetry(token: 2, delayUs: 1_000_000)])
        #expect(p.retryDue(token: 1) == [])  // stale timer
        #expect(nonLog(p.retryDue(token: 2)) == [.startCapture(streamID: 4)])
        let last = p.captureFailed(streamID: 4, reason: "aggregate_create", status: -1)
        #expect(nonLog(last) == [.stopCapture(streamID: 4)])
        #expect(logs(last) == ["audio_unavailable reason=aggregate_create status=-1 stream_id=4"])
        #expect(nonLog(p.prefs(sessionID: 7, enabled: true)) == [])  // failed for good (until re-enabled)
    }

    @Test func successfulRebuildResetsRetries() {
        var p = running()
        _ = p.captureInterrupted(streamID: 1, reason: "wake")
        _ = p.captureFailed(streamID: 2, reason: "x", status: 1)
        _ = p.retryDue(token: 1)
        _ = p.captureStarted(streamID: 3)
        // A later failure of a fresh start (not a rebuild) is final at once.
        _ = p.prefs(sessionID: 7, enabled: false)
        _ = p.prefs(sessionID: 7, enabled: true)  // stream 4
        #expect(nonLog(p.captureFailed(streamID: 4, reason: "x", status: 1)) == [.stopCapture(streamID: 4)])
    }

    @Test func disableOrSessionEndDuringRetryWaitCancelsIt() {
        var p = running()
        _ = p.captureInterrupted(streamID: 1, reason: "wake")
        _ = p.captureFailed(streamID: 2, reason: "x", status: 1)
        #expect(p.prefs(sessionID: 7, enabled: false) == [])  // STOPPED already went out at the interruption
        #expect(p.retryDue(token: 1) == [])
        var q = running()
        _ = q.captureInterrupted(streamID: 1, reason: "wake")
        _ = q.captureFailed(streamID: 2, reason: "x", status: 1)
        #expect(nonLog(q.sessionEnded()) == [])
        #expect(q.retryDue(token: 1) == [])
    }

    @Test func streamIDsSkipZeroOnWrap() {
        var p = AudioStreamPolicy(disabled: false)
        _ = p.sessionStarted(sessionID: 7, clientSupportsAudio: true)
        var last: UInt16 = 0
        for _ in 0..<65_536 {
            _ = p.prefs(sessionID: 7, enabled: true)
            let actions = p.prefs(sessionID: 7, enabled: false)
            guard case .stopCapture(let id)? = actions.first else { Issue.record("no stop"); return }
            #expect(id != 0)
            last = id
        }
        #expect(last == 1)  // 65535 then wrapped past 0 to 1
    }
}
