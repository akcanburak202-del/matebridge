import Testing
@testable import MateBridgeCore

// Usage detection around the fact measured 2026-10-18: our own sink writing keeps DeviceIsRunningSomewhere at 1.

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

    @Test func whileWritingUsageIsAssumedAndTheRawPropertyIsIgnored() {
        var t = CameraUsageTracker()
        _ = t.running(true, now: 0)
        _ = t.sinkWriting(true, now: 0)
        _ = t.running(false, now: sec)  // a blip of our own start/stop must not end the usage
        #expect(t.inUse)
        #expect(t.nextDeadline == 15 * sec)
    }

    @Test func aProbeThatFindsAnotherClientResumesTheSink() {
        var t = CameraUsageTracker()
        _ = t.running(true, now: 0)
        _ = t.sinkWriting(true, now: 0)
        #expect(t.tick(now: 14 * sec).isEmpty)
        #expect(t.tick(now: 15 * sec) == [.pauseSink])
        #expect(t.isProbing && t.inUse)
        #expect(t.nextDeadline == 15 * sec + 600_000)
        // Our stop dropped nothing: the other client keeps the property at 1.
        #expect(t.tick(now: 15 * sec + 600_000) == [.resumeSink])
        #expect(!t.isProbing && t.inUse)
        #expect(t.nextDeadline == 30 * sec + 600_000)
    }

    @Test func aProbeThatFindsNoClientEndsTheUsageAndKeepsTheSinkStopped() {
        var t = CameraUsageTracker()
        _ = t.running(true, now: 0)
        _ = t.sinkWriting(true, now: 0)
        _ = t.tick(now: 15 * sec)  // pause
        _ = t.running(false, now: 15 * sec + 5_000)  // the property fell because we stopped
        #expect(t.tick(now: 15 * sec + 600_000).isEmpty)
        #expect(t.isParked && !t.inUse)
        #expect(t.nextDeadline == nil)
        // The app comes back before the controller's filter ended: write again at once.
        #expect(t.running(true, now: 16 * sec) == [.resumeSink])
        #expect(t.inUse && !t.isParked)
        // The host stopping the writer for good clears the parked state.
        var u = CameraUsageTracker()
        _ = u.sinkWriting(true, now: 0)
        _ = u.tick(now: 15 * sec)
        _ = u.tick(now: 16 * sec)
        #expect(u.isParked)
        _ = u.sinkWriting(false, now: 17 * sec)
        #expect(!u.isParked && !u.inUse)
        #expect(u.nextDeadline == nil)
    }

    @Test func noProbeRunsWhileNotWriting() {
        var t = CameraUsageTracker()
        _ = t.running(true, now: 0)
        #expect(t.tick(now: 100 * sec).isEmpty)
        _ = t.sinkWriting(true, now: 100 * sec)
        _ = t.sinkWriting(false, now: 101 * sec)
        #expect(t.nextDeadline == nil)
        #expect(t.tick(now: 200 * sec).isEmpty)
    }

    @Test func manualHoldsUsageOnAndDisablesTheProbes() {
        var t = CameraUsageTracker()
        _ = t.sinkWriting(true, now: 0)
        #expect(t.setManual(true, now: 1 * sec).isEmpty)
        #expect(t.inUse && t.nextDeadline == nil)
        #expect(t.tick(now: 100 * sec).isEmpty)
        _ = t.running(false, now: 2 * sec)
        #expect(t.inUse)
        // Off again while writing: assumed usage until the next probe.
        _ = t.setManual(false, now: 120 * sec)
        #expect(t.inUse && t.nextDeadline == 135 * sec)
    }

    @Test func manualOnWhileProbingOrParkedResumesTheSink() {
        var t = CameraUsageTracker()
        _ = t.sinkWriting(true, now: 0)
        _ = t.tick(now: 15 * sec)
        #expect(t.setManual(true, now: 15 * sec + 1) == [.resumeSink])
        var p = CameraUsageTracker()
        _ = p.sinkWriting(true, now: 0)
        _ = p.tick(now: 15 * sec)
        _ = p.tick(now: 16 * sec)
        #expect(p.isParked)
        #expect(p.setManual(true, now: 17 * sec) == [.resumeSink])
        #expect(p.inUse && !p.isParked)
    }
}
