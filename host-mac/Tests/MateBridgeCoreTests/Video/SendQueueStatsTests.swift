import XCTest
@testable import MateBridgeCore

/// T-088: send-queue window statistics.
final class SendQueueStatsTests: XCTestCase {
    private func sample(_ kb: UInt64, retx: UInt64 = 0, srtt: UInt32 = 4) -> TcpSample {
        TcpSample(sendQueueBytes: kb * 1024, srttMs: srtt, rttVarMs: srtt / 2, retransmitPackets: retx,
                  congestionWindowBytes: 64 * 1024, sendWindowBytes: 128 * 1024)
    }

    func testEmptyWindowIsNil() {
        var m = SendQueueMeter()
        XCTAssertNil(m.take())
        m.record(sample(1))
        XCTAssertNotNil(m.take())
        XCTAssertNil(m.take())
    }

    func testPercentilesAndLatestFields() {
        var m = SendQueueMeter()
        for kb in 1...100 { m.record(sample(UInt64(kb), srtt: UInt32(kb))) }
        let w = m.take()!
        XCTAssertEqual(w.samples, 100)
        XCTAssertEqual(w.p50Bytes, 50 * 1024)
        XCTAssertEqual(w.p95Bytes, 95 * 1024)
        XCTAssertEqual(w.maxBytes, 100 * 1024)
        XCTAssertEqual(w.srttMs, 100)  // latest sample
        XCTAssertEqual(w.rttVarMs, 50)
        XCTAssertEqual(w.logFields,
                       "samples=100 sendq_kb_p50_95_max=50.0/95.0/100.0 rtt_ms=100 rttvar_ms=50 retx_pkts=0 "
                       + "cwnd_kb=64.0 snd_wnd_kb=128.0 source=tcp_info")
    }

    func testRetransmitDeltaPerWindow() {
        var m = SendQueueMeter()
        m.record(sample(0, retx: 10))  // baseline: retransmits before sampling started
        m.record(sample(0, retx: 13))
        XCTAssertEqual(m.take()?.retransmitPackets, 3)
        m.record(sample(0, retx: 13))
        XCTAssertEqual(m.take()?.retransmitPackets, 0)
        m.record(sample(0, retx: 20))
        XCTAssertEqual(m.take()?.retransmitPackets, 7)
        // A smaller cumulative count (new socket) never yields a huge wrapped delta.
        m.record(sample(0, retx: 2))
        XCTAssertEqual(m.take()?.retransmitPackets, 0)
        m.record(sample(0, retx: 5))
        XCTAssertEqual(m.take()?.retransmitPackets, 3)
    }

    func testSamplesAreBounded() {
        var m = SendQueueMeter()
        for _ in 0..<(SendQueueMeter.maxSamples + 5) { m.record(sample(1)) }
        let w = m.take()!
        XCTAssertEqual(w.samples, SendQueueMeter.maxSamples + 5)
        XCTAssertEqual(w.overflow, 5)
        XCTAssertTrue(w.logFields.hasSuffix(" overflow=5"))
        m.record(sample(1))
        XCTAssertEqual(m.take()?.overflow, 0)
    }
}
