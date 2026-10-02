import Testing
@testable import MateBridgeCore

/// T-116: audio send timing (queue lag, capture to write, write intervals and gaps) on the session server.
@Suite struct AudioSendTimingTests {
    private let base: UInt64 = 5_000_000

    private func write(at endUs: UInt64, lag: UInt64 = 100, capToWrite: UInt64 = 1_000, call: UInt64 = 20,
                       pending: Int = 0) -> AudioSendTiming.Write {
        AudioSendTiming.Write(queueLagUs: lag, captureToWriteUs: capToWrite, writeCallUs: call, pendingBytes: pending,
                              endUs: endUs)
    }

    @Test func steadyTenMsWritesHaveNoGap() {
        var t = AudioSendTiming()
        for i in 0..<50 {
            #expect(t.recordWrite(write(at: base + UInt64(i) * 10_000)) == nil)
        }
        #expect(t.writes == 50)
        #expect(t.logFields.contains("write_int_ms_max=10.0 "))
        #expect(t.logFields.contains("gaps=0"))
    }

    @Test func windowFieldsMedianAndMax() {
        var t = AudioSendTiming()
        let lags: [UInt64] = [100, 300, 200, 5_000, 400]
        let caps: [UInt64] = [2_000, 1_000, 3_000, 9_500, 4_000]
        for i in 0..<5 {
            _ = t.recordWrite(write(at: base + UInt64(i) * 10_000, lag: lags[i], capToWrite: caps[i],
                                    call: UInt64(i) * 100, pending: i == 3 ? 1_234 : 0))
        }
        #expect(t.logFields == "writes=5 queue_lag_ms_p50_max=0.30/5.00 cap_to_write_ms_p50_max=3.00/9.50 "
            + "write_int_ms_max=10.0 write_block_ms_max=0.40 partial_writes=1 pending_bytes_max=1234 gaps=0")
    }

    @Test func gapAboveTwentyMsCarriesTheReceivedMessageTypes() {
        var t = AudioSendTiming()
        _ = t.recordWrite(write(at: base))
        t.noteReceived(.pen, startUs: base + 1_000, endUs: base + 1_200)
        t.noteReceived(.key, startUs: base + 2_000, endUs: base + 27_000)  // 25 ms in the handler
        t.noteReceived(.pointerAbs, startUs: base + 27_500, endUs: base + 27_600)
        let gap = t.recordWrite(write(at: base + 30_000, lag: 26_000, pending: 64))
        #expect(gap == AudioSendTiming.Gap(intervalUs: 30_000, queueLagUs: 26_000, pendingBytes: 64,
                                           lastReceived: .pointerAbs, lastReceivedAgoUs: 2_400,
                                           slowestReceived: .key, slowestReceivedUs: 25_000))
        #expect(gap?.logFields == "int_ms=30.0 queue_lag_ms=26.0 pending_bytes=64 last_rx=pointerAbs "
            + "last_rx_ago_ms=2.4 slow_rx=key slow_rx_ms=25.0")
        #expect(t.logFields.contains("write_int_ms_max=30.0 "))
        #expect(t.logFields.contains("gaps=1"))
    }

    @Test func exactlyTwentyMsIsNotAGap() {
        var t = AudioSendTiming()
        _ = t.recordWrite(write(at: base))
        #expect(t.recordWrite(write(at: base + 20_000)) == nil)
        #expect(t.recordWrite(write(at: base + 40_001)) != nil)
    }

    @Test func slowestReceivedIsPerInterval() {
        var t = AudioSendTiming()
        _ = t.recordWrite(write(at: base))
        t.noteReceived(.key, startUs: base + 1_000, endUs: base + 9_000)
        _ = t.recordWrite(write(at: base + 10_000))
        let gap = t.recordWrite(write(at: base + 40_000))
        #expect(gap?.slowestReceived == nil)
        #expect(gap?.lastReceived == .key)
        #expect(gap?.logFields.contains("slow_rx=na slow_rx_ms=0.0") == true)
    }

    @Test func noReceivedMessageIsNa() {
        var t = AudioSendTiming()
        _ = t.recordWrite(write(at: base))
        let gap = t.recordWrite(write(at: base + 50_000))
        #expect(gap?.logFields.contains("last_rx=na last_rx_ago_ms=0.0") == true)
    }

    @Test func atMostFiveGapLinesPerSecondButAllCounted() {
        var t = AudioSendTiming()
        var now = base
        _ = t.recordWrite(write(at: now))
        var reported = 0
        for _ in 0..<8 {  // 8 gaps of 30 ms, all within one second
            now += 30_000
            if t.recordWrite(write(at: now)) != nil { reported += 1 }
        }
        #expect(reported == 5)
        #expect(t.logFields.contains("gaps=8"))
        now += 1_000_000  // a new rate window
        #expect(t.recordWrite(write(at: now)) != nil)
    }

    @Test func reportOncePerSecondThenTheWindowRestarts() {
        var t = AudioSendTiming()
        #expect(t.takeReportIfDue(nowUs: base) == nil)  // empty
        _ = t.recordWrite(write(at: base))
        _ = t.recordWrite(write(at: base + 50_000))
        #expect(t.takeReportIfDue(nowUs: base + 999_999) == nil)
        let fields = t.takeReportIfDue(nowUs: base + 1_000_000)
        #expect(fields?.hasPrefix("writes=2 ") == true)
        #expect(fields?.contains("gaps=1") == true)
        #expect(t.writes == 0)
        #expect(t.takeReportIfDue(nowUs: base + 3_000_000) == nil)
        // The interval to the previous write survives the window change.
        _ = t.recordWrite(write(at: base + 1_010_000))
        #expect(t.logFields.contains("write_int_ms_max=960.0 "))
        #expect(t.logFields.contains("gaps=1"))
    }

    @Test func streamBoundaryFlushesAndDoesNotCountTheIntervalAcrossIt() {
        var t = AudioSendTiming()
        _ = t.recordWrite(write(at: base))
        #expect(t.flush()?.hasPrefix("writes=1 ") == true)
        #expect(t.flush() == nil)
        t.resetInterval()
        #expect(t.recordWrite(write(at: base + 3_000_000)) == nil)  // no gap across a stop/start
        #expect(t.logFields.contains("write_int_ms_max=0.0 "))
    }

    @Test func clockGoingBackwardsIsIgnored() {
        var t = AudioSendTiming()
        _ = t.recordWrite(write(at: base))
        #expect(t.recordWrite(write(at: base - 50_000)) == nil)
        #expect(t.takeReportIfDue(nowUs: base - 100) == nil)
    }

    @Test func outboxStampsPushTime() {
        var box = AudioOutbox()
        _ = box.push(sessionID: 7, .audioConfig(.stopped(streamID: 1)), nowUs: 1_234)
        _ = box.push(sessionID: 7, .audioConfig(.stopped(streamID: 2)))
        #expect(box.take().map(\.pushedUs) == [1_234, 0])
    }
}
