import Testing
@testable import MateBridgeCore

private let sec: UInt64 = 1_000_000

@Suite struct CameraOutputStallPolicyTests {
    @Test func sendsOnlyWhenNothingIsPending() {
        var p = CameraOutputStallPolicy()
        #expect(p.request(pendingBytes: 0, now: 0) == .send)
        #expect(p.request(pendingBytes: 30, now: sec) == .skip)
        #expect(p.request(pendingBytes: 30, now: 2 * sec) == .skip)
    }

    @Test func closesAfterTheStallLimitAndADrainRestartsTheClock() {
        var p = CameraOutputStallPolicy()
        #expect(p.request(pendingBytes: 30, now: 0) == .skip)
        #expect(p.request(pendingBytes: 30, now: 4_999_999) == .skip)
        #expect(p.request(pendingBytes: 30, now: 5 * sec) == .close)
        // A drain in between restarts the clock.
        var q = CameraOutputStallPolicy()
        _ = q.request(pendingBytes: 30, now: 0)
        #expect(q.request(pendingBytes: 0, now: 4 * sec) == .send)
        #expect(q.request(pendingBytes: 30, now: 6 * sec) == .skip)
        #expect(q.request(pendingBytes: 30, now: 10 * sec) == .skip)
        #expect(q.request(pendingBytes: 30, now: 11 * sec) == .close)
    }

    @Test func resetForgetsTheStall() {
        var p = CameraOutputStallPolicy()
        _ = p.request(pendingBytes: 30, now: 0)
        p.reset()
        #expect(p.request(pendingBytes: 30, now: 9 * sec) == .skip)
    }
}
