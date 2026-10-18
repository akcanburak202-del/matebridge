import Testing
@testable import MateBridgeCore

// Usage detection around the fact measured 2026-10-18: our own sink writing keeps DeviceIsRunningSomewhere at 1.
// Probes start only on request (idle audit, sleep), never on a timer.

private let sec: UInt64 = 1_000_000

@Suite struct CameraUsageTrackerTests {
    @Test func notWritingUsageIsTheRawProperty() {
        var t = CameraUsageTracker()
        #expect(!t.inUse)
        _ = t.running(true, now: 0)
        #expect(t.inUse)
        _ = t.running(false, now: sec)
        #expect(!t.inUse)
        #expect(t.nextDeadline == nil)
    }

    @Test func whileWritingUsageIsAssumedAndNoProbeRunsOnItsOwn() {
        var t = CameraUsageTracker()
        _ = t.running(true, now: 0)
        _ = t.sinkWriting(true, now: 0)
        _ = t.running(false, now: sec)  // a blip of our own start/stop must not end the usage
        #expect(t.inUse)
        #expect(t.nextDeadline == nil)
        #expect(t.tick(now: 10_000 * sec).isEmpty)
        #expect(t.canProbe)
    }

    @Test func aProbeThatFindsAnotherClientResumesTheSinkAfterTheSettleTime() {
        var t = CameraUsageTracker()
        _ = t.running(true, now: 0)
        _ = t.sinkWriting(true, now: 0)
        #expect(t.startProbe(now: 15 * sec) == [.pauseSink])
        #expect(t.isProbing && t.inUse && !t.canProbe)
        #expect(t.startProbe(now: 15 * sec).isEmpty)
        #expect(t.nextDeadline == 15 * sec + 500_000)
        #expect(t.tick(now: 15 * sec + 499_999).isEmpty)
        // Our stop dropped nothing: the other client keeps the property at 1.
        #expect(t.tick(now: 15 * sec + 500_000) == [.resumeSink])
        #expect(!t.isProbing && t.inUse && t.canProbe)
        #expect(t.nextDeadline == nil)
    }

    @Test func theRawPropertyFallingEndsTheProbeAtOnce() {
        var t = CameraUsageTracker()
        _ = t.running(true, now: 0)
        _ = t.sinkWriting(true, now: 0)
        _ = t.startProbe(now: 15 * sec)
        _ = t.running(false, now: 15 * sec + 5_000)  // the property fell because we stopped
        #expect(t.isParked && !t.inUse)
        #expect(t.nextDeadline == nil)
        #expect(t.tick(now: 15 * sec + 500_000).isEmpty)
        // The app comes back before the controller's filter ended: write again at once.
        #expect(t.running(true, now: 16 * sec) == [.resumeSink])
        #expect(t.inUse && !t.isParked)
    }

    @Test func aProbeThatFindsNoClientAtTheDeadlineParks() {
        var t = CameraUsageTracker()
        _ = t.sinkWriting(true, now: 0)
        _ = t.startProbe(now: 15 * sec)
        #expect(t.tick(now: 16 * sec).isEmpty)
        #expect(t.isParked && !t.inUse)
        // The host stopping the writer for good clears the parked state.
        _ = t.sinkWriting(false, now: 17 * sec)
        #expect(!t.isParked && !t.inUse)
    }

    @Test func noProbeWhileNotWriting() {
        var t = CameraUsageTracker()
        _ = t.running(true, now: 0)
        #expect(t.startProbe(now: 1).isEmpty)
        _ = t.sinkWriting(true, now: 100 * sec)
        _ = t.sinkWriting(false, now: 101 * sec)
        #expect(t.startProbe(now: 102 * sec).isEmpty && t.nextDeadline == nil)
    }

    @Test func manualHoldsUsageOnAndDisablesTheProbes() {
        var t = CameraUsageTracker()
        _ = t.sinkWriting(true, now: 0)
        #expect(t.setManual(true, now: 1 * sec).isEmpty)
        #expect(t.inUse && t.nextDeadline == nil)
        #expect(t.startProbe(now: 100 * sec).isEmpty)
        _ = t.running(false, now: 2 * sec)
        #expect(t.inUse)
        _ = t.setManual(false, now: 120 * sec)
        #expect(t.inUse && t.canProbe)
    }

    @Test func manualOnWhileProbingOrParkedResumesTheSink() {
        var t = CameraUsageTracker()
        _ = t.sinkWriting(true, now: 0)
        _ = t.startProbe(now: 15 * sec)
        #expect(t.setManual(true, now: 15 * sec + 1) == [.resumeSink])
        var p = CameraUsageTracker()
        _ = p.sinkWriting(true, now: 0)
        _ = p.startProbe(now: 15 * sec)
        _ = p.tick(now: 16 * sec)
        #expect(p.isParked)
        #expect(p.setManual(true, now: 17 * sec) == [.resumeSink])
        #expect(p.inUse && !p.isParked)
    }
}
