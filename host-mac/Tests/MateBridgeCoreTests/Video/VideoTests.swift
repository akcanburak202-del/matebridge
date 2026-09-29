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
        XCTAssertEqual(q.push(delta(3)), 1)
        XCTAssertEqual(q.count, 2)
        XCTAssertEqual(q.pop()?.data, [2])
        XCTAssertEqual(q.pop()?.data, [3])
        XCTAssertTrue(q.takeKeyframeRequest())
        XCTAssertFalse(q.takeKeyframeRequest(), "request is consumed once")
        XCTAssertEqual(q.droppedCount, 1)
    }

    func testKeyframeSurvivesOverflow() {
        var q = BoundedFrameQueue()
        q.push(key(1)); q.push(delta(2))
        q.push(delta(3))
        XCTAssertEqual(q.pop()?.data, [1], "keyframe kept")
        XCTAssertEqual(q.pop()?.data, [3], "oldest delta dropped")
        XCTAssertTrue(q.takeKeyframeRequest())
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
