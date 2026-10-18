import Testing
@testable import MateBridgeCore

// Bounded decode queue of the camera stream (PROTOCOL.md section 5 "Kamera").

private let ms: UInt64 = 1_000

@Suite struct CameraStreamGateTests {
    @Test func nothingIsDecodedBeforeAKeyframe() {
        var g = CameraStreamGate()
        _ = g.codecConfig()
        #expect(g.frame(keyframe: false, now: 0) == .dropAwaitingKeyframe)
        #expect(g.counters.dropped == 1 && g.pending == 0)
        #expect(g.frame(keyframe: true, now: 0) == .submit(epoch: 1))
        #expect(!g.awaitingKeyframe)
        #expect(g.frame(keyframe: false, now: 33 * ms) == .submit(epoch: 1))
    }

    @Test func atMostTwoFramesWaitAndTheOverflowDropsEverythingAndAsksForAKeyframe() {
        var g = CameraStreamGate()
        _ = g.frame(keyframe: true, now: 0)
        _ = g.frame(keyframe: false, now: 33 * ms)
        #expect(g.pending == 2)
        let over = g.frame(keyframe: false, now: 66 * ms)
        #expect(over == .overflow(request: .framesDropped))
        #expect(g.pending == 0 && g.awaitingKeyframe)
        #expect(g.epoch == 1)  // work queued before is void
        #expect(g.frame(keyframe: false, now: 70 * ms) == .dropAwaitingKeyframe)
    }

    @Test func finishedWorkOfAVoidEpochDoesNotCount() {
        var g = CameraStreamGate()
        _ = g.frame(keyframe: true, now: 0)
        _ = g.frame(keyframe: false, now: 1)
        _ = g.frame(keyframe: false, now: 2)  // overflow, epoch 1
        _ = g.frame(keyframe: true, now: 600 * ms)  // pending 1 (epoch 1)
        g.finished(epoch: 0, decoded: true)
        g.finished(epoch: 0, decoded: true)
        #expect(g.pending == 1 && g.counters.decoded == 0)
        g.finished(epoch: 1, decoded: true)
        #expect(g.pending == 0 && g.counters.decoded == 1)
    }

    @Test func requestsAreSpacedByFiveHundredMilliseconds() {
        var g = CameraStreamGate()
        #expect(g.startupRequest(now: 0) == .startup)
        _ = g.frame(keyframe: true, now: 0)
        _ = g.frame(keyframe: false, now: 1)
        // Overflow inside the 500 ms after the STARTUP request: no new request, still waiting for a keyframe.
        #expect(g.frame(keyframe: false, now: 100 * ms) == .overflow(request: nil))
        // The wait repeats the request once the interval ran out (and not before one second after the last).
        #expect(g.tick(now: 600 * ms) == nil)
        #expect(g.tick(now: 1_100 * ms) == .framesDropped)
        #expect(g.tick(now: 1_200 * ms) == nil)
        // A keyframe ends the wait.
        _ = g.frame(keyframe: true, now: 1_300 * ms)
        #expect(g.tick(now: 9_000 * ms) == nil)
    }

    @Test func aDecodeErrorVoidsTheQueueAndAsksForAKeyframe() {
        var g = CameraStreamGate()
        _ = g.frame(keyframe: true, now: 0)
        let epoch = g.epoch
        #expect(g.decodeFailed(epoch: epoch, now: sec) == .decodeError)
        #expect(g.awaitingKeyframe && g.pending == 0 && g.counters.decodeErrors == 1)
        // A failure of work that was already void is old news.
        #expect(g.decodeFailed(epoch: epoch, now: 2 * sec) == nil)
        #expect(g.counters.decodeErrors == 1)
    }

    @Test func aNewCodecConfigWaitsForTheNextKeyframe() {
        var g = CameraStreamGate()
        _ = g.frame(keyframe: true, now: 0)
        g.finished(epoch: 0, decoded: true)
        #expect(!g.awaitingKeyframe)
        #expect(g.codecConfig() == .submit(epoch: 1))  // frames queued before the config are void
        #expect(g.awaitingKeyframe && g.pending == 0)
    }

    @Test func resetStartsAFreshConnection() {
        var g = CameraStreamGate()
        _ = g.frame(keyframe: true, now: 0)
        g.reset()
        #expect(g.pending == 0 && g.awaitingKeyframe && g.epoch == 1)
        #expect(g.startupRequest(now: 0) == .startup)
    }

    @Test func countersAreTakenAndCleared() {
        var g = CameraStreamGate()
        _ = g.frame(keyframe: true, now: 0)
        g.finished(epoch: 0, decoded: true)
        let c = g.takeCounters()
        #expect(c.received == 1 && c.decoded == 1)
        #expect(g.takeCounters() == CameraStreamGate.Counters())
    }

    @Test func aCodecConfigVoidsFramesQueuedBeforeIt() {
        var g = CameraStreamGate()
        _ = g.frame(keyframe: true, now: 0)
        _ = g.frame(keyframe: false, now: 1)
        #expect(g.pending == 2)
        #expect(g.codecConfig() == .submit(epoch: 1))
        g.finished(epoch: 0, decoded: true)  // old work finishing changes nothing
        #expect(g.pending == 0)
    }

    @Test func camFramePayloadBoundary() throws {
        #expect(CamFrame.maxDataBytes == 4_194_284)  // 4 194 304 - 20 (PROTOCOL.md 0x60)
        var sealer = RecordSealer(key: SecretBytes([UInt8](repeating: 7, count: 32)), maxPayload: ProtocolConstants.maxCameraPayload)
        _ = try Message.camFrame(CamFrame(frameSeq: 0, captureTimeUs: 0, flags: .keyframe,
                                          data: [UInt8](repeating: 0, count: CamFrame.maxDataBytes))).sealed(using: &sealer)
        #expect(throws: ProtocolError.invalidField("frame_size")) {
            try Message.camFrame(CamFrame(frameSeq: 0, captureTimeUs: 0, flags: [],
                                          data: [UInt8](repeating: 0, count: CamFrame.maxDataBytes + 1))).sealed(using: &sealer)
        }
    }
}

private let sec: UInt64 = 1_000_000
