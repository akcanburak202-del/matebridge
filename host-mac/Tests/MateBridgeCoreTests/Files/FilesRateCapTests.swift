import Testing
@testable import MateBridgeCore

// Wi-Fi share of tablet files (decision 0035): the same numbers as the client's `filesCapBytesPerSec` / `TokenBucket`
// (T-266, WifiProfileTest).

private let ms: UInt64 = 1_000_000
private let sec: UInt64 = 1_000_000_000

@Suite struct FilesRateCapTests {
    @Test func capFormulaTable() {
        #expect(FilesRateCap.capBytesPerSec(videoKbps: 30_000) == 2_250_000)
        #expect(FilesRateCap.capBytesPerSec(videoKbps: 15_000) == 3_000_000)
        #expect(FilesRateCap.capBytesPerSec(videoKbps: 60_000) == 500_000)
        #expect(FilesRateCap.capBytesPerSec(videoKbps: 1) == 3_000_000)  // clamped at the top
        #expect(FilesRateCap.capBytesPerSec(videoKbps: 24_000) == 3_000_000)  // exactly 3.0
        #expect(FilesRateCap.capBytesPerSec(videoKbps: 100_000) == 500_000)  // clamped at the bottom
        #expect(FilesRateCap.capBytesPerSec(videoKbps: 44_000) == 500_000)  // exactly 0.5
        #expect(FilesRateCap.capBytesPerSec(videoKbps: 40_000) == 1_000_000)
        #expect(FilesRateCap.capBytesPerSec(videoKbps: 48_000) == 500_000)
        #expect(FilesRateCap.capBytesPerSec(videoKbps: UInt32.max) == 500_000)
        #expect(FilesRateCap.capBytesPerSec(videoKbps: 0) == 2_000_000)  // unknown: 2 MB/s, not the lowest
    }

    @Test func capNeverLeavesItsBoundsAndFallsAsVideoRises() {
        var last = UInt64.max
        for kbps in stride(from: UInt32(1), through: 80_000, by: 250) {
            let cap = FilesRateCap.capBytesPerSec(videoKbps: kbps)
            #expect((500_000...3_000_000).contains(cap))
            #expect(cap <= last)
            last = cap
        }
    }

    @Test func wifiProfileConstantsMatchTheClient() {
        #expect(FilesRateCap.burstBytes == 64 * 1024)
        #expect(FilesRateCap.smallLaneBytes == 32 * 1024)
        #expect(FilesRateCap.smallBurstBytes == 32 * 1024)
        #expect(FilesRateCap.smallRateBytesPerSec == 256_000)
    }

    // MARK: Bucket

    @Test func withinTheBurstNothingWaits() {
        var b = FilesTokenBucket(rateBytesPerSec: 1_000_000, burstBytes: 64 * 1024, now: 0)
        #expect(b.reserve(64 * 1024, now: 0) == 0)
        #expect(b.available(now: 0) == 0)
    }

    @Test func debtIsPaidAtTheRate() {
        var b = FilesTokenBucket(rateBytesPerSec: 1_000_000, burstBytes: 1000, now: 0)
        #expect(b.reserve(1000, now: 0) == 0)
        #expect(b.reserve(500, now: 0) == 500 * 1000)  // 500 B at 1 MB/s = 0.5 ms
        #expect(b.reserve(500, now: 0) == 1000 * 1000)  // debts add up
        // Time pays it back: after 2 ms (2000 B) the 1000 B debt is gone and 1000 B are free again (depth 1000).
        #expect(b.available(now: 2 * ms) == 1000)
    }

    @Test func idleTimeSavesUpOnlyTheDepth() {
        var b = FilesTokenBucket(rateBytesPerSec: 1_000_000, burstBytes: 4096, now: 0)
        _ = b.reserve(4096, now: 0)
        #expect(b.available(now: 3600 * sec) == 4096)
        #expect(b.reserve(8192, now: 3600 * sec) == UInt64(4096) * 1000)
    }

    @Test func aRaisedRateEndsTheDebtSoonerAndACutExtendsIt() {
        var b = FilesTokenBucket(rateBytesPerSec: 1_000_000, burstBytes: 1000, now: 0)
        _ = b.reserve(1000, now: 0)
        #expect(b.reserve(1000, now: 0) == 1_000_000)  // 1 ms
        b.setRate(2_000_000, now: 0)
        #expect(b.reserve(0, now: 0) == 500_000)  // the same 1000 B debt now takes 0.5 ms
        b.setRate(500_000, now: 0)
        #expect(b.reserve(0, now: 0) == 2_000_000)
        #expect(b.rate == 500_000)
    }

    @Test func timeBeforeARateChangeIsCreditedAtTheOldRate() {
        var b = FilesTokenBucket(rateBytesPerSec: 1_000_000, burstBytes: 100_000, now: 0)
        _ = b.reserve(100_000, now: 0)
        b.setRate(10_000_000, now: ms)  // 1 ms at 1 MB/s = 1000 B, not 10 000
        #expect(b.available(now: ms) == 1000)
    }

    @Test func aClockThatRunsBackwardsCreditsNothing() {
        var b = FilesTokenBucket(rateBytesPerSec: 1_000_000, burstBytes: 1000, now: 10 * sec)
        _ = b.reserve(1000, now: 10 * sec)
        #expect(b.available(now: 5 * sec) == 0)
        #expect(b.reserve(1000, now: 5 * sec) == 1_000_000)
    }

    // MARK: Lanes

    @Test func smallExchangesSkipTheBulkDebt() {
        var cap = FilesRateLimiter(videoKbps: 30_000, now: 0)
        #expect(cap.mainBytesPerSec == 2_250_000)
        // A big transfer runs up a debt on the main lane (one lane, many bursts).
        var bulk = FilesRateLane()
        _ = cap.reserve(FilesRateCap.smallLaneBytes, lane: &bulk, now: 0)  // its own small start
        var debt: UInt64 = 0
        for _ in 0..<8 { debt = cap.reserve(64 * 1024, lane: &bulk, now: 0) }
        #expect(debt > 200 * ms)  // ~250 ms behind the debt of eight bursts
        // A small PROPFIND on another connection goes through the small lane (here it is empty after the transfer's
        // own 32 KiB start, so it waits for its 256 KB/s refill): ~16 ms, nowhere near the ~200 ms debt of the bulk.
        var propfind = FilesRateLane()
        let wait = cap.reserve(4 * 1024, lane: &propfind, now: 0)
        #expect(wait == UInt64(4 * 1024) * 1_000_000_000 / 256_000)
        #expect(wait < debt / 10)
        #expect(propfind.used == 4 * 1024)
        // Once the small lane has refilled (after 200 ms) the same request does not wait at all.
        var later = FilesRateLane()
        #expect(cap.reserve(4 * 1024, lane: &later, now: 400 * ms) == 0)
    }

    @Test func theFirstThirtyTwoKiBOfAnExchangeUseTheSmallLaneThenTheMainOne() {
        var cap = FilesRateLimiter(videoKbps: 30_000, now: 0)
        var lane = FilesRateLane()
        #expect(cap.reserve(32 * 1024, lane: &lane, now: 0) == 0)  // exactly the small burst
        // The next bytes are main-lane bytes: within its 64 KiB burst nothing waits either.
        #expect(cap.reserve(64 * 1024, lane: &lane, now: 0) == 0)
        // A new exchange starts small again.
        lane.reset()
        #expect(lane.used == 0)
        // The small lane is now empty: another small exchange has to wait for its 256 KB/s refill.
        var other = FilesRateLane()
        #expect(cap.reserve(32 * 1024, lane: &other, now: 0) == UInt64(32 * 1024) * 1_000_000_000 / 256_000)
    }

    @Test func aStraddlingRecordWaitsForBothLanesInTurn() {
        var cap = FilesRateLimiter(videoKbps: 30_000, now: 0)
        var lane = FilesRateLane()
        _ = cap.reserve(64 * 1024, lane: &lane, now: 0)  // 32 KiB small + 32 KiB main
        var next = FilesRateLane()
        _ = cap.reserve(16 * 1024, lane: &next, now: 0)
        // The small lane has run dry (32 KiB + 16 KiB booked, 48 KiB of debt after the next 32 KiB): a 64 KiB record
        // is 32 KiB small (waits for the refill) + 32 KiB main (within its burst).
        var third = FilesRateLane()
        let wait = cap.reserve(64 * 1024, lane: &third, now: 0)
        #expect(wait > 0)
        #expect(wait < 1000 * ms)
    }

    @Test func theVideoTargetChangesTheMainRateButNotTheSmallLane() {
        var cap = FilesRateLimiter(videoKbps: 30_000, now: 0)
        cap.setVideoKbps(60_000, now: 0)
        #expect(cap.videoKbps == 60_000)
        #expect(cap.mainBytesPerSec == 500_000)
        cap.setVideoKbps(0, now: 0)
        #expect(cap.mainBytesPerSec == 2_000_000)
        // The small lane's wait for 32 KiB past its burst is unchanged by the video rate.
        var a = FilesRateLimiter(videoKbps: 15_000, now: 0), b = FilesRateLimiter(videoKbps: 60_000, now: 0)
        var la = FilesRateLane(), lb = FilesRateLane()
        _ = a.reserve(32 * 1024, lane: &la, now: 0)
        _ = b.reserve(32 * 1024, lane: &lb, now: 0)
        var la2 = FilesRateLane(), lb2 = FilesRateLane()
        #expect(a.reserve(8 * 1024, lane: &la2, now: 0) == b.reserve(8 * 1024, lane: &lb2, now: 0))
    }
}
