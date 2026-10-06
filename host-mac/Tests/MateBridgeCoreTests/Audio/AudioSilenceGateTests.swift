import Testing
@testable import MateBridgeCore

@Suite struct AudioSilenceGateTests {
    @Test func sendsFiftyZeroPacketsThenSkips() {
        var gate = AudioSilenceGate()
        var sent: [Bool] = []
        for _ in 0..<80 { sent.append(gate.shouldSend(sumSquares: 0)) }
        #expect(sent.prefix(50).allSatisfy { $0 })
        #expect(sent.suffix(30).allSatisfy { !$0 })
    }

    @Test func nonZeroPacketAlwaysSentAndReopens() {
        var gate = AudioSilenceGate()
        for _ in 0..<60 { _ = gate.shouldSend(sumSquares: 0) }
        let closed = gate.shouldSend(sumSquares: 0)
        #expect(!closed)
        let reopened = gate.shouldSend(sumSquares: 1e-9)
        #expect(reopened)
        #expect(gate.zeroRun == 0)
        var sent = 0
        for _ in 0..<60 where gate.shouldSend(sumSquares: 0) { sent += 1 }
        #expect(sent == 50)
    }

    @Test func oneLsbIsNotZero() {
        // One s16 LSB in a stereo packet, as the level meter sees it (PCMConvert).
        let lsb = Double(1) / 32767
        var gate = AudioSilenceGate()
        for _ in 0..<60 { _ = gate.shouldSend(sumSquares: 0) }
        let sent = gate.shouldSend(sumSquares: lsb * lsb)
        #expect(sent)
    }
}
