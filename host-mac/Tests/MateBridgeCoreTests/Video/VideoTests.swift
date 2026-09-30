import XCTest
@testable import MateBridgeCore

final class BoundedFrameQueueTests: XCTestCase {
    private func delta(_ n: UInt8) -> EncodedVideoFrame { .init(flags: [], captureTimeUs: UInt64(n), data: [n]) }
    private func key(_ n: UInt8) -> EncodedVideoFrame { .init(flags: .keyframe, captureTimeUs: UInt64(n), data: [n]) }
    private func config() -> EncodedVideoFrame { .init(flags: .codecConfig, captureTimeUs: 0, data: [9]) }

    func testFifoWithinCapacity() {
        var q = BoundedFrameQueue()
        XCTAssertEqual(q.push(delta(1)), 0)
        XCTAssertEqual(q.push(delta(2)), 0)
        XCTAssertEqual(q.pop()?.data, [1])
        XCTAssertEqual(q.pop()?.data, [2])
        XCTAssertNil(q.pop())
        XCTAssertFalse(q.takeKeyframeRequest())
    }

    func testOverflowDropsOldestDeltaAndRequestsKeyframe() {
        var q = BoundedFrameQueue()
        q.push(delta(1)); q.push(delta(2))
        XCTAssertEqual(q.push(delta(3)), 3, "delta 1 dropped, its dependents 2 and 3 purged")
        XCTAssertTrue(q.isEmpty)
        XCTAssertTrue(q.takeKeyframeRequest())
        XCTAssertFalse(q.takeKeyframeRequest(), "request is consumed once")
        XCTAssertEqual(q.droppedCount, 3)
    }

    /// T-058: after a dropped delta the dependents must not reach the client before the requested keyframe.
    func testDeltasAreRefusedAfterADropUntilKeyframe() {
        var q = BoundedFrameQueue()
        q.push(delta(1)); q.push(delta(2)); q.push(delta(3))   // delta 1 dropped, 2 and 3 purged
        XCTAssertTrue(q.takeKeyframeRequest())
        XCTAssertTrue(q.isEmpty)
        XCTAssertEqual(q.push(delta(4)), 1, "dependent delta refused")
        XCTAssertEqual(q.push(delta(5)), 1)
        XCTAssertTrue(q.isEmpty)
        XCTAssertEqual(q.push(key(6)), 0)
        XCTAssertEqual(q.push(delta(7)), 0, "deltas pass again once the keyframe is in")
        XCTAssertEqual(q.pop()?.data, [6]); XCTAssertEqual(q.pop()?.data, [7])
    }

    func testCodecConfigDoesNotLiftTheRefusal() {
        var q = BoundedFrameQueue()
        q.push(delta(1)); q.push(delta(2)); q.push(delta(3))
        q.push(config())
        XCTAssertEqual(q.push(delta(4)), 1)
        q.push(key(5))
        _ = q.pop()   // make room: the config leaves
        XCTAssertEqual(q.push(delta(6)), 0, "a keyframe has lifted the refusal")
    }

    func testKeyframeSurvivesOverflow() {
        var q = BoundedFrameQueue()
        q.push(key(1)); q.push(delta(2))
        q.push(delta(3))
        XCTAssertEqual(q.pop()?.data, [1], "keyframe kept")
        XCTAssertNil(q.pop(), "oldest delta dropped, the dependent delta purged")
        XCTAssertTrue(q.takeKeyframeRequest())
    }

    func testSurvivingNewerKeyframeSatisfiesRecovery() {
        var q = BoundedFrameQueue(capacity: 2)
        q.push(delta(1)); q.push(delta(2))
        XCTAssertEqual(q.push(key(3)), 2, "delta 1 dropped, delta 2 purged, keyframe 3 survives")
        XCTAssertFalse(q.takeKeyframeRequest(), "the queued keyframe is the recovery")
        XCTAssertEqual(q.push(delta(4)), 0, "deltas that reference keyframe 3 are accepted")
        XCTAssertEqual(q.pop()?.data, [3]); XCTAssertEqual(q.pop()?.data, [4])
    }

    func testPurgeStopsAtTheNextKeyframeAndKeepsLaterDeltas() {
        var q = BoundedFrameQueue(capacity: 4)
        q.push(delta(1)); q.push(delta(2)); q.push(key(3)); q.push(delta(4))
        XCTAssertEqual(q.push(delta(5)), 2, "delta 1 dropped, delta 2 purged; keyframe 3 and later deltas stay")
        XCTAssertEqual([q.pop()?.data, q.pop()?.data, q.pop()?.data], [[3], [4], [5]])
        XCTAssertFalse(q.takeKeyframeRequest())
    }

    func testDroppedDeltaPurgesLaterQueuedDeltasKeepsKeyframeAndConfig() {
        var q = BoundedFrameQueue(capacity: 4)
        q.push(config()); q.push(key(1)); q.push(delta(2)); q.push(delta(3))
        XCTAssertEqual(q.push(delta(4)), 3, "delta 2 dropped, 3 and 4 purged")
        XCTAssertEqual(q.pop()?.isCodecConfig, true)
        XCTAssertEqual(q.pop()?.data, [1])
        XCTAssertNil(q.pop())
        XCTAssertTrue(q.takeKeyframeRequest())
        XCTAssertEqual(q.push(delta(5)), 1, "refused until a keyframe")
    }

    func testCodecConfigSurvivesAndNewKeyframeSupersedesOldOne() {
        var q = BoundedFrameQueue()
        q.push(config()); q.push(key(1))
        XCTAssertEqual(q.push(key(2)), 1)
        XCTAssertEqual(q.pop()?.isCodecConfig, true)
        XCTAssertEqual(q.pop()?.data, [2])
        XCTAssertFalse(q.takeKeyframeRequest(), "dropping a superseded keyframe needs no request")
    }

    func testNeverExceedsCapacity() {
        var q = BoundedFrameQueue()
        for i in 0..<50 {
            q.push(i % 7 == 0 ? key(UInt8(i)) : delta(UInt8(i)))
            XCTAssertLessThanOrEqual(q.count, 2)
        }
    }
}

final class AnnexBTests: XCTestCase {
    func testConvertLengthPrefixed() {
        let data: [UInt8] = [0, 0, 0, 2, 0x40, 0x01, 0, 0, 0, 3, 0x26, 0x01, 0xAA]
        XCTAssertEqual(AnnexB.convert(lengthPrefixed: data),
                       [0, 0, 0, 1, 0x40, 0x01, 0, 0, 0, 1, 0x26, 0x01, 0xAA])
    }

    func testConvertRejectsMalformed() {
        XCTAssertNil(AnnexB.convert(lengthPrefixed: [0, 0, 0, 9, 1, 2]))
        XCTAssertNil(AnnexB.convert(lengthPrefixed: [0, 0]))
        XCTAssertNil(AnnexB.convert(lengthPrefixed: [0, 0, 0, 0]))
        XCTAssertEqual(AnnexB.convert(lengthPrefixed: []), [])
    }

    func testTwoByteLengthPrefix() {
        XCTAssertEqual(AnnexB.convert(lengthPrefixed: [0, 2, 7, 8], lengthSize: 2), [0, 0, 0, 1, 7, 8])
    }

    func testParameterSetsAndSplit() {
        let vps: [UInt8] = [0x40, 0x01, 0x0C], sps: [UInt8] = [0x42, 0x01, 0x01], pps: [UInt8] = [0x44, 0x01]
        let blob = AnnexB.parameterSets([vps, sps, pps])
        XCTAssertEqual(AnnexB.nalUnits(blob), [vps, sps, pps])
        XCTAssertEqual(AnnexB.hevcNALType(vps), 32)
        XCTAssertEqual(AnnexB.hevcNALType(sps), 33)
        XCTAssertEqual(AnnexB.hevcNALType(pps), 34)
    }
}

final class VideoSettingsTests: XCTestCase {
    func testStreamConfigColorsAndSizes() {
        let c = VideoSettings.tabletDefault.streamConfig(configID: 3)
        XCTAssertEqual(c.configID, 3)
        XCTAssertEqual(c.codec, .hevc)
        XCTAssertEqual([c.widthPx, c.heightPx, c.widthPt, c.heightPt], [2800, 1840, 1400, 920])
        XCTAssertEqual([c.colorPrimaries, c.transfer, c.matrix], [1, 13, 1])
        XCTAssertTrue(c.fullRange)
    }
}

final class VideoStatsTests: XCTestCase {
    func testRecordsFramesKeyframesAndIgnoresConfigInFrameCount() {
        var s = VideoStats()
        s.record(.init(flags: .codecConfig, captureTimeUs: 0, data: [UInt8](repeating: 0, count: 10)), encodeTimeUs: 0)
        s.record(.init(flags: .keyframe, captureTimeUs: 1, data: [UInt8](repeating: 0, count: 100)), encodeTimeUs: 4000)
        s.record(.init(flags: [], captureTimeUs: 2, data: [UInt8](repeating: 0, count: 20)), encodeTimeUs: 2000)
        XCTAssertEqual(s.frames, 2)
        XCTAssertEqual(s.keyframes, 1)
        XCTAssertEqual(s.bytes, 130)
        XCTAssertEqual(s.averageEncodeTimeUs, 3000)
        XCTAssertEqual(s.maxFrameBytes, 100)
    }
}

final class HEVCSPSTests: XCTestCase {
    /// SPS emitted by the Apple VideoToolbox HEVC encoder (2800x1840, Main, 2 sub-layers, sRGB/BT.709 full range).
    private let appleSPS: [UInt8] = [
        0x42, 0x01, 0x03, 0x01, 0x60, 0x00, 0x00, 0x03, 0x00, 0xB0, 0x00, 0x00, 0x03, 0x00, 0x00, 0x03, 0x00,
        0x96, 0x00, 0x00, 0xA0, 0x01, 0x5E, 0x20, 0x07, 0x31, 0x62, 0x02, 0x39, 0x24, 0x52, 0x10, 0xB9, 0xF8,
        0x4F, 0x42, 0xFA, 0x86, 0xF5, 0x43, 0xFA, 0xA8, 0x23, 0xD5, 0x52, 0x9B, 0x80, 0x86, 0x80, 0x81, 0xFC,
        0x20, 0x10, 0x40,
    ]

    func testParsesAppleSPSVui() {
        XCTAssertEqual(HEVCSPS.vuiColor(sps: appleSPS),
                       HEVCVUIColor(fullRange: true, colourPrimaries: 1, transferCharacteristics: 13,
                                    matrixCoefficients: 1, colourDescriptionPresent: true))
    }

    func testRejectsNonSPSAndTruncated() {
        XCTAssertNil(HEVCSPS.vuiColor(sps: [0x40, 0x01, 0x0C, 0x03]))   // VPS
        XCTAssertNil(HEVCSPS.vuiColor(sps: Array(appleSPS.prefix(30))))
        XCTAssertNil(HEVCSPS.vuiColor(sps: []))
    }

    func testUnescapeRemovesEmulationPrevention() {
        XCTAssertEqual(HEVCSPS.unescape([0, 0, 3, 1, 0, 0, 3]), [0, 0, 1, 0, 0])
    }
}

final class NewConsumerTests: XCTestCase {
    private func delta(_ n: UInt8) -> EncodedVideoFrame { .init(flags: [], captureTimeUs: UInt64(n), data: [n]) }
    private func key(_ n: UInt8) -> EncodedVideoFrame { .init(flags: .keyframe, captureTimeUs: UInt64(n), data: [n]) }
    private func config() -> EncodedVideoFrame { .init(flags: .codecConfig, captureTimeUs: 0, data: [9]) }

    func testPolicyNewConsumerSeesConfigThenKeyframeOnly() {
        var q = BoundedFrameQueue()
        q.push(delta(1)); q.push(delta(2))
        q.startNewConsumer(config: config())
        q.push(delta(3))                 // stale in-flight delta: refused
        q.push(key(4))
        XCTAssertEqual(q.pop()?.isCodecConfig, true)
        XCTAssertEqual(q.pop()?.isKeyframe, true)
        XCTAssertNil(q.pop())
        XCTAssertFalse(q.takeKeyframeRequest())
    }

    func testAsyncQueueDeliversConfigThenKeyframeToNewConsumer() async {
        let q = VideoFrameQueue(keyframeNeeded: {})
        q.push(delta(1))
        q.startNewConsumer(config: config())
        q.push(delta(2))
        q.push(key(3))
        let a = await q.next(), b = await q.next()
        XCTAssertEqual(a?.isCodecConfig, true)
        XCTAssertEqual(b?.isKeyframe, true)
    }

    func testCancelledWaiterIsReleasedSoNextConsumerCanAttach() async {
        let q = VideoFrameQueue(keyframeNeeded: {})
        let first = Task { await q.next() }
        try? await Task.sleep(nanoseconds: 50_000_000)
        first.cancel()
        let r = await first.value
        XCTAssertNil(r)
        let second = Task { await q.next() }
        try? await Task.sleep(nanoseconds: 50_000_000)
        q.push(key(7))
        let f = await second.value
        XCTAssertEqual(f?.data, [7])
    }

    func testDetachConsumerReleasesWaiterWithoutFinishingQueue() async {
        let q = VideoFrameQueue(keyframeNeeded: {})
        let waiting = Task { await q.next() }
        try? await Task.sleep(nanoseconds: 50_000_000)
        q.detachConsumer()
        let r = await waiting.value
        XCTAssertNil(r)
        q.push(key(1))
        let f = await q.next()
        XCTAssertEqual(f?.data, [1], "queue still usable after detach")
    }

    func testKeyframeCallbackFiresOnDeltaDrop() {
        final class Flag: @unchecked Sendable { var n = 0 }
        let flag = Flag()
        let q = VideoFrameQueue(keyframeNeeded: { flag.n += 1 })
        q.push(delta(1)); q.push(delta(2)); q.push(delta(3))
        XCTAssertEqual(flag.n, 1)
    }
}
