import Darwin
import XCTest
@testable import MateBridgeCore

/// T-126: per-second TCP state of the control and video sockets (`net ev=tcp`).
final class TcpInfoLogTests: XCTestCase {
    private func snap(retx: UInt64 = 0, rxmit: UInt64 = 0, ooo: UInt64 = 0, tx: UInt64 = 0, sb: UInt32 = 0,
                      cwnd: UInt32 = 64_000, wnd: UInt32 = 128_000, pending: Int? = nil) -> TcpConnectionSnapshot {
        TcpConnectionSnapshot(rtoMs: 230, srttMs: 12, rttVarMs: 4, rttCurMs: 9, congestionWindowBytes: cwnd,
                              sendWindowBytes: wnd, slowStartThresholdBytes: 1_073_725_440, sendBufferBytes: sb,
                              txPackets: tx, retransmitPackets: retx, retransmitBytes: rxmit, outOfOrderBytes: ooo,
                              lossRecovery: false, userPendingBytes: pending)
    }

    // MARK: Snapshot

    func testSnapshotMapsConnectionInfo() {
        var info = tcp_connection_info()
        info.tcpi_rto = 300
        info.tcpi_srtt = 15
        info.tcpi_rttvar = 6
        info.tcpi_rttcur = 11
        info.tcpi_snd_cwnd = 40_000
        info.tcpi_snd_wnd = 131_072
        info.tcpi_snd_ssthresh = 20_000
        info.tcpi_snd_sbbytes = 5_000
        info.tcpi_txpackets = 1_000
        info.tcpi_txretransmitpackets = 3
        info.tcpi_txretransmitbytes = 4_200
        info.tcpi_rxoutoforderbytes = 77
        info.tcpi_flags = UInt32(TCPCI_FLAG_LOSSRECOVERY)
        let s = TcpConnectionSnapshot(info, userPendingBytes: 12)
        XCTAssertEqual(s, TcpConnectionSnapshot(rtoMs: 300, srttMs: 15, rttVarMs: 6, rttCurMs: 11,
                                                congestionWindowBytes: 40_000, sendWindowBytes: 131_072,
                                                slowStartThresholdBytes: 20_000, sendBufferBytes: 5_000,
                                                txPackets: 1_000, retransmitPackets: 3, retransmitBytes: 4_200,
                                                outOfOrderBytes: 77, lossRecovery: true, userPendingBytes: 12))
        info.tcpi_flags = UInt32(TCPCI_FLAG_REORDERING_DETECTED)
        XCTAssertFalse(TcpConnectionSnapshot(info).lossRecovery)
        XCTAssertNil(TcpConnectionSnapshot(info).userPendingBytes)
    }

    func testUnackedAndNotSentEstimates() {
        // Everything fits in the windows: all of it is in flight, nothing waits unsent.
        let small = snap(sb: 3_000, cwnd: 64_000, wnd: 128_000)
        XCTAssertEqual(small.unackedBytesEstimate, 3_000)
        XCTAssertEqual(small.notSentBytesEstimate, 0)
        // The congestion window binds.
        let cwndBound = snap(sb: 100_000, cwnd: 30_000, wnd: 128_000)
        XCTAssertEqual(cwndBound.unackedBytesEstimate, 30_000)
        XCTAssertEqual(cwndBound.notSentBytesEstimate, 70_000)
        // The peer's receive window binds.
        let wndBound = snap(sb: 100_000, cwnd: 64_000, wnd: 10_000)
        XCTAssertEqual(wndBound.unackedBytesEstimate, 10_000)
        XCTAssertEqual(wndBound.notSentBytesEstimate, 90_000)
        // Zero window: nothing can be in flight.
        let zero = snap(sb: 500, cwnd: 64_000, wnd: 0)
        XCTAssertEqual(zero.unackedBytesEstimate, 0)
        XCTAssertEqual(zero.notSentBytesEstimate, 500)
        XCTAssertEqual(snap().unackedBytesEstimate, 0)
        XCTAssertEqual(snap().notSentBytesEstimate, 0)
    }

    // MARK: Meter

    func testFirstWindowCountsFromConnectionStart() {
        var meter = TcpInfoMeter()
        let r = meter.take(snap(retx: 2, rxmit: 2_800, ooo: 100, tx: 500))
        XCTAssertEqual(r.retransmitPacketsDelta, 2)
        XCTAssertEqual(r.retransmitBytesDelta, 2_800)
        XCTAssertEqual(r.outOfOrderBytesDelta, 100)
        XCTAssertEqual(r.txPacketsDelta, 500)
    }

    func testTakeMovesBaseAndPeekDoesNot() {
        var meter = TcpInfoMeter()
        _ = meter.take(snap(retx: 2, rxmit: 2_800, ooo: 100, tx: 500))
        // A snapshot between windows: deltas since the last window, base unchanged.
        let p = meter.peek(snap(retx: 3, rxmit: 4_200, ooo: 100, tx: 560))
        XCTAssertEqual(p.retransmitPacketsDelta, 1)
        XCTAssertEqual(p.retransmitBytesDelta, 1_400)
        XCTAssertEqual(p.outOfOrderBytesDelta, 0)
        XCTAssertEqual(p.txPacketsDelta, 60)
        let w = meter.take(snap(retx: 5, rxmit: 7_000, ooo: 150, tx: 600))
        XCTAssertEqual(w.retransmitPacketsDelta, 3)
        XCTAssertEqual(w.retransmitBytesDelta, 4_200)
        XCTAssertEqual(w.outOfOrderBytesDelta, 50)
        XCTAssertEqual(w.txPacketsDelta, 100)
        // Quiet second.
        let q = meter.take(snap(retx: 5, rxmit: 7_000, ooo: 150, tx: 600))
        XCTAssertEqual([q.retransmitPacketsDelta, q.retransmitBytesDelta, q.outOfOrderBytesDelta, q.txPacketsDelta],
                       [0, 0, 0, 0])
    }

    func testCounterGoingDownCountsZero() {
        var meter = TcpInfoMeter()
        _ = meter.take(snap(retx: 9, rxmit: 9_000, ooo: 900, tx: 9_000))
        let r = meter.take(snap(retx: 1, rxmit: 100, ooo: 0, tx: 10))
        XCTAssertEqual([r.retransmitPacketsDelta, r.retransmitBytesDelta, r.outOfOrderBytesDelta, r.txPacketsDelta],
                       [0, 0, 0, 0])
        // The base follows the new counters.
        XCTAssertEqual(meter.take(snap(retx: 2, rxmit: 100, ooo: 0, tx: 20)).retransmitPacketsDelta, 1)
    }

    // MARK: Format

    func testLogFields() {
        var meter = TcpInfoMeter()
        let r = meter.take(snap(retx: 2, rxmit: 2_800, ooo: 100, tx: 500, sb: 100_000, cwnd: 30_000, pending: 0))
        XCTAssertEqual(r.logFields(role: .control, connectionID: 7),
                       "conn=control conn_id=7 retx_pkts_delta=2 rxmit_bytes_delta=2800 ooo_bytes_delta=100 "
                       + "tx_pkts_delta=500 srtt_ms=12 rttvar_ms=4 rttcur_ms=9 rto_ms=230 snd_cwnd=30000 "
                       + "snd_wnd=128000 ssthresh=1073725440 sndbuf_bytes=100000 unacked_bytes=30000 "
                       + "notsent_bytes=70000 user_pending_bytes=0 loss_recovery=0")
        var lossy = snap()
        lossy.lossRecovery = true
        let v = TcpInfoMeter().peek(lossy).logFields(role: .video, connectionID: 8)
        XCTAssertTrue(v.hasPrefix("conn=video conn_id=8 "), v)
        XCTAssertTrue(v.contains(" user_pending_bytes=na "), v)
        XCTAssertTrue(v.hasSuffix(" loss_recovery=1"), v)
    }

    // MARK: Knob

    func testKnobParse() {
        XCTAssertEqual(TcpInfoLogKnob.parse([:]), .auto)
        XCTAssertEqual(TcpInfoLogKnob.parse(["MATEBRIDGE_TCP_LOG": "0"]), .off)
        XCTAssertEqual(TcpInfoLogKnob.parse(["MATEBRIDGE_TCP_LOG": " 1 "]), .on)
        XCTAssertEqual(TcpInfoLogKnob.parse(["MATEBRIDGE_TCP_LOG": "yes"]), .auto)
        XCTAssertEqual(TcpInfoLogKnob.parse(["MATEBRIDGE_TCP_LOG": ""]), .auto)
    }

    func testKnobDecision() {
        // Default: Wi-Fi only; USB needs the send-queue log.
        XCTAssertTrue(TcpInfoLogKnob.auto.isEnabled(transport: .network, sendQueueLog: false))
        XCTAssertFalse(TcpInfoLogKnob.auto.isEnabled(transport: .usb, sendQueueLog: false))
        XCTAssertTrue(TcpInfoLogKnob.auto.isEnabled(transport: .usb, sendQueueLog: true))
        for transport in [SessionTransport.usb, .network] {
            for sendq in [false, true] {
                XCTAssertTrue(TcpInfoLogKnob.on.isEnabled(transport: transport, sendQueueLog: sendq))
                XCTAssertFalse(TcpInfoLogKnob.off.isEnabled(transport: transport, sendQueueLog: sendq))
            }
        }
    }

    func testKnobFollowsSendQueueKnobForUsb() {
        let env = ["MATEBRIDGE_SENDQ_LOG": "1"]
        XCTAssertTrue(TcpInfoLogKnob.parse(env).isEnabled(transport: .usb,
                                                          sendQueueLog: SendQueueLogKnob.isEnabled(env)))
        XCTAssertFalse(TcpInfoLogKnob.parse([:]).isEnabled(transport: .usb,
                                                           sendQueueLog: SendQueueLogKnob.isEnabled([:])))
    }
}
