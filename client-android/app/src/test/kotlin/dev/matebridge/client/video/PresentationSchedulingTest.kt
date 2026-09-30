package dev.matebridge.client.video

import dev.matebridge.client.stream.StatsFormat
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class SlotReleaserTest {
    private class Rec : SlotReleaser.Sink {
        val released = ArrayList<Pair<Int, Long>>()
        val discarded = ArrayList<Int>()
        override fun release(idx: Int, renderNs: Long) { released.add(idx to renderNs) }
        override fun discard(idx: Int) { discarded.add(idx) }
    }

    private val counters = PresentCounters()
    private val rec = Rec()
    private val r = SlotReleaser(rec, counters)

    @Test fun laterSlotReleasesThePendingOne() {
        r.submit(1, slotNs = 100, renderNs = 90, deadlineNs = 1000, nowNs = 0)
        assertEquals(1, r.held)
        r.submit(2, 200, 190, 1000, 0)
        assertEquals(listOf(1 to 90L), rec.released)
        assertEquals(1, r.held) // the new one waits
        r.flushDue(1000)
        assertEquals(listOf(1 to 90L, 2 to 190L), rec.released)
        assertEquals(0, r.held)
    }

    @Test fun sameSlotReplacesPendingAndOnlyTheNewestIsReleased() {
        r.submit(1, 100, 90, 1000, 0)
        r.submit(2, 100, 90, 1000, 10)
        r.submit(3, 100, 90, 1000, 20)
        assertEquals(listOf(1, 2), rec.discarded)
        assertEquals(2, counters.snapshot().slotDups)
        r.flushDue(1000)
        assertEquals(listOf(3 to 90L), rec.released)
    }

    @Test fun alreadyReleasedSlotRefusesASecondRelease() {
        r.submit(1, 100, 90, deadlineNs = 50, nowNs = 60) // deadline passed: released at once
        assertEquals(listOf(1 to 90L), rec.released)
        r.submit(2, 100, 90, 1000, 70) // same slot, cannot undo
        assertEquals(listOf(2), rec.discarded)
        assertEquals(1, rec.released.size)
        assertEquals(1, counters.snapshot().slotDups)
        assertEquals(0, r.held)
    }

    @Test fun atMostOneBufferIsHeld() {
        for (i in 1..10) r.submit(i, i * 100L, i * 100L - 10, 1_000_000, 0)
        assertEquals(1, r.held)
        assertEquals(9, rec.released.size)
        // Every slot released once, in order.
        assertEquals((1..9).map { it * 100L - 10 }, rec.released.map { it.second })
    }

    @Test fun deadlineBoundsTheHold() {
        r.submit(1, 100, 90, deadlineNs = 500, nowNs = 0)
        assertEquals(500L, r.untilDeadlineNs(0))
        assertEquals(100L, r.untilDeadlineNs(400))
        r.flushDue(499)
        assertTrue(rec.released.isEmpty())
        r.flushDue(500)
        assertEquals(1, rec.released.size)
        assertNull(r.untilDeadlineNs(500))
    }

    @Test fun flushAllReleasesNow() {
        r.submit(1, 100, 90, 1000, 0)
        r.flushAll()
        assertEquals(1, rec.released.size)
        r.flushAll()
        assertEquals(1, rec.released.size)
    }

    @Test fun anEarlierSlotThanPendingIsDiscarded() {
        r.submit(1, 200, 190, 1000, 0)
        r.submit(2, 100, 90, 1000, 0)
        assertEquals(listOf(2), rec.discarded)
        r.flushAll()
        assertEquals(listOf(1 to 190L), rec.released)
    }
}

class InFlightGaugeTest {
    private val ms = 1_000_000L

    @Test fun countsQueuedMinusDone() {
        val g = InFlightGauge()
        g.onQueued(0); g.onQueued(0); g.onQueued(0)
        assertEquals(3, g.current())
        g.onDone(1)
        assertEquals(2, g.current())
        g.onDone(1); g.onDone(1); g.onDone(1) // never negative
        assertEquals(0, g.current())
    }

    @Test fun limitBlocksUntilAnOutputCompletes() {
        val g = InFlightGauge()
        g.onQueued(0); g.onQueued(0)
        assertFalse(g.canQueue(2, 1 * ms))
        assertTrue(g.canQueue(3, 1 * ms))
        assertTrue(g.canQueue(0, 1 * ms)) // unlimited
        g.onDone(2 * ms)
        assertTrue(g.canQueue(2, 3 * ms))
    }

    @Test fun stalledDecoderDoesNotDeadlock() {
        val g = InFlightGauge()
        g.onQueued(0); g.onQueued(0)
        assertFalse(g.canQueue(2, InFlightGauge.STALL_NS / 2))
        assertTrue(g.canQueue(2, InFlightGauge.STALL_NS + 1))
    }

    @Test fun p95OfSampledCount() {
        val g = InFlightGauge()
        repeat(90) { g.onQueued(0); g.onDone(0) } // sampled as 1
        repeat(10) { g.onQueued(0) } // 1..10 -> the tail
        val p = g.p95AndReset()!!
        assertTrue("p95 $p", p in 2..10)
        assertNull(g.p95AndReset())
    }

    @Test fun heldFrameCountsAsOneMore() {
        val g = InFlightGauge()
        g.onQueued(0); g.onQueued(0)
        g.onHeld()
        assertEquals(3, g.p95AndReset())
    }

    @Test fun presentFieldsFormat() {
        val f = StatsFormat.presentFields(3, 2, 4, 4_166_666, 9_500, 0)
        assertEquals("slot_dups=3 late_drops=2 in_codec_p95=4 lead_ms=4.17 d_us=9500 inflight_limit=0 phase_lock=0 rephase=0", f)
        val g = StatsFormat.presentFields(0, 0, 2, 6_000_000, 100, 0, true, 3)
        assertTrue(g, g.endsWith("phase_lock=1 rephase=3"))
        assertTrue(StatsFormat.presentFields(0, 0, null, 0, 0, 3).contains("in_codec_p95=-"))
    }
}

class VsyncClockGridTest {
    private val p120 = 1_000_000_000L / 120
    private val p60 = 1_000_000_000L / 60

    private fun feed(v: VsyncClock, from: Long, period: Long, n: Int): Long {
        var t = from
        repeat(n) { t += period; v.onVsync(t) }
        return t
    }

    @Test fun missedCallbackIsNotARateChange() {
        val v = VsyncClock(120f).also { it.onVsync(0) }
        var t = feed(v, 0, p120, 20)
        val e = v.grid().epoch
        t += 2 * p120; v.onVsync(t) // one callback missed
        t = feed(v, t, p120, 20)
        assertEquals(e, v.grid().epoch)
        assertTrue(Math.abs(v.periodNs - p120) < 50_000)
    }

    @Test fun repeatedMissedCallbacksDoNotReseedQuickly() {
        val v = VsyncClock(120f).also { it.onVsync(0) }
        var t = feed(v, 0, p120, 10)
        repeat(VsyncClock.RESEED_AFTER + 2) { t += 2 * p120; v.onVsync(t) } // a run of double gaps (busy UI thread)
        assertEquals(p120, v.periodNs)
        assertEquals(0, v.grid().epoch)
    }

    @Test fun realSwitchToSixtyReseedsAndBumpsEpoch() {
        val v = VsyncClock(120f).also { it.onVsync(0) }
        var t = feed(v, 0, p120, 10)
        repeat(VsyncClock.RESEED_AFTER_MULTIPLE + 1) { t += p60; v.onVsync(t) }
        assertEquals(p60, v.periodNs)
        assertEquals(1, v.grid().epoch)
    }

    @Test fun displayListenerSwitchIsImmediateAndSameRateKeepsEpoch() {
        val v = VsyncClock(120f).also { it.onVsync(0) }
        v.setNominalHz(120f)
        assertEquals(0, v.grid().epoch)
        v.setNominalHz(60f)
        assertEquals(p60, v.periodNs)
        assertEquals(1, v.grid().epoch)
        v.setNominalHz(60f)
        assertEquals(1, v.grid().epoch)
    }

    @Test fun appVsyncOffsetShiftsTheGridToDisplayTime() {
        val v = VsyncClock(120f)
        v.setDisplayTiming(appVsyncOffsetNs = 2_000_000, presentationDeadlineNs = 1_000_000)
        v.onVsync(10_000_000)
        val g = v.grid()
        assertEquals(8_000_000L, g.lastNs)
        assertEquals(1_000_000L, g.deadlineNs)
        // Changing the offset keeps the display-time phase consistent with the same callback.
        v.setDisplayTiming(3_000_000, 1_000_000)
        assertEquals(7_000_000L, v.grid().lastNs)
    }

    @Test fun leadDefaultsToHalfPeriodAndIsOverridable() {
        val v = VsyncClock(120f)
        assertEquals((p120 * VsyncClock.FAST_PANEL_LEAD_FRACTION).toLong(), v.leadNs())
        assertEquals(6_000_000.0, v.leadNs().toDouble(), 10_000.0) // 6.0 ms at 120 Hz
        assertEquals(p60 / 2, VsyncClock(60f).leadNs()) // 60 Hz keeps P/2
        v.leadOverrideNs = 2_000_000
        assertEquals(2_000_000L, v.leadNs())
        v.leadOverrideNs = 50_000_000
        assertEquals(p120, v.leadNs()) // never more than a period
    }
}

class PacerLatencyBoundTest {
    private val ms = 1_000_000L
    private val p120 = 1_000_000_000L / 120
    private val p60 = 1_000_000_000L / 60

    private fun clock(period: Long) = VsyncClock(1e9f / period).also { it.onVsync(0) }

    @Test fun finalSlotNeverMoreThanOneVsyncAfterEarliest() {
        val v = clock(p120)
        val pacer = AdaptivePacer(v, p120)
        var seed = 5L
        fun rnd(): Double { seed = seed * 6364136223846793005L + 1442695040888963407L; return ((seed ushr 33) % 10_000) / 10_000.0 }
        var lateDrops = 0
        for (k in 0 until 3000) {
            val cap = 1_000_000_000L + k * p120
            // heavy jitter plus bursts: several frames ready at once
            val ready = cap + 9 * ms + (rnd() * 12 * ms).toLong()
            val d = pacer.schedule(cap / 1000, ready)!!
            val earliest = v.slotAtOrAfter(ready, 0.0)
            assertTrue("slot ${d.slotNs - earliest} vs $p120", d.slotNs - earliest <= p120)
            assertTrue(d.slotNs >= earliest || d.collided)
            if (d.lateDrop) lateDrops++
            assertTrue("D ${pacer.lastDNs}", pacer.lastDNs <= p120 * 3 / 2)
        }
    }

    @Test fun burstBeyondBoundCollidesInsteadOfQueueing() {
        val v = clock(p120)
        val pacer = AdaptivePacer(v, p120)
        val now = 1_000_000_000L
        var prevSlot = Long.MIN_VALUE
        var lateDrops = 0
        for (k in 0 until 10) { // 10 frames ready at the same instant
            val d = pacer.schedule(k * p120 / 1000, now)!!
            assertTrue(d.slotNs <= v.slotAtOrAfter(now, 0.0) + p120)
            assertTrue(prevSlot == Long.MIN_VALUE || d.slotNs >= prevSlot)
            prevSlot = d.slotNs
            if (d.lateDrop) { lateDrops++; assertTrue(d.collided) }
        }
        assertTrue(lateDrops >= 8)
    }

    @Test fun surplusContentDropsAreNotLateDrops() {
        val v = clock(p60)
        val pacer = AdaptivePacer(v, p120)
        var collided = 0
        for (k in 0 until 240) {
            val cap = 1_000_000_000L + k * p120
            val d = pacer.schedule(cap / 1000, cap + 9 * ms)!!
            if (d.collided) { collided++; assertFalse(d.lateDrop) }
        }
        assertTrue(collided in 100..140)
    }

    @Test fun presentationDeadlineMovesTheEarliestSlot() {
        val v = clock(p120)
        v.setDisplayTiming(0, 3 * ms)
        val pacer = AdaptivePacer(v, p120)
        val now = 1_000_000_000L
        val d = pacer.schedule(now / 1000 - 9_000, now)!!
        assertTrue("slot ${d.slotNs - now}", d.slotNs >= now + 3 * ms)
    }

    @Test fun dSlewsInsteadOfJumping() {
        val v = clock(p120)
        val pacer = AdaptivePacer(v, p120)
        for (k in 0 until 200) { val cap = 1_000_000_000L + k * p120; pacer.schedule(cap / 1000, cap + 9 * ms) }
        val before = pacer.lastDNs
        // One 6 ms outlier in 256 samples is below p99, but sustained jitter must ramp D by bounded steps.
        var last = before
        for (k in 200 until 260) {
            val cap = 1_000_000_000L + k * p120
            pacer.schedule(cap / 1000, cap + 9 * ms + (if (k % 2 == 0) 6 * ms else 0))
            assertTrue("D step ${pacer.lastDNs - last}", pacer.lastDNs - last <= AdaptivePacer.D_SLEW_UP_NS)
            assertTrue("D step down ${last - pacer.lastDNs}", last - pacer.lastDNs <= AdaptivePacer.D_SLEW_DOWN_NS)
            last = pacer.lastDNs
        }
        assertTrue(last > before)
    }

    @Test fun baselineFallSlewsSoTargetsDoNotJumpEarly() {
        val v = clock(p120)
        val pacer = AdaptivePacer(v, p120)
        for (k in 0 until 100) { val cap = 1_000_000_000L + k * p120; pacer.schedule(cap / 1000, cap + 12 * ms) }
        // Pipeline suddenly 4 ms faster: slots must not move earlier by more than a vsync step at a time.
        var prev = Long.MIN_VALUE
        for (k in 100 until 140) {
            val cap = 1_000_000_000L + k * p120
            val d = pacer.schedule(cap / 1000, cap + 8 * ms)!!
            assertTrue(prev == Long.MIN_VALUE || d.slotNs - prev <= 2 * p120)
            assertTrue(prev == Long.MIN_VALUE || d.slotNs >= prev)
            prev = d.slotNs
        }
    }

    @Test fun idleGapReanchorsButKeepsFeedbackLevel() {
        val v = clock(p120)
        val pacer = AdaptivePacer(v, p120)
        for (k in 0 until 100) { val cap = 1_000_000_000L + k * p120; pacer.schedule(cap / 1000, cap + 9 * ms) }
        repeat(AdaptivePacer.HIGH_WINDOWS) { pacer.onSkipWindow(20.0) }
        assertEquals(1, pacer.level)
        // 3 s of static screen, then a frame whose pipeline delay is 15 ms instead of 9 ms.
        val cap = 1_000_000_000L + 100 * p120 + 3_000_000_000L
        val d = pacer.schedule(cap / 1000, cap + 15 * ms)!!
        assertNotNull(d)
        assertEquals(1, pacer.level)
        assertFalse("first frame after idle is not a skip", d.skipped)
        assertFalse(d.collided)
    }

    @Test fun panelSwitchUsesEpochNotPeriodComparison() {
        val v = VsyncClock(120f).also { it.onVsync(0) }
        val pacer = AdaptivePacer(v, p120)
        for (k in 0 until 100) { val cap = 1_000_000_000L + k * p120; pacer.schedule(cap / 1000, cap + 9 * ms) }
        repeat(AdaptivePacer.HIGH_WINDOWS) { pacer.onSkipWindow(20.0) }
        assertEquals(1, pacer.level)
        // A small period wobble (EMA) is no reset ...
        v.onVsync(10_000_000_000L); v.onVsync(10_000_000_000L + p120 + 20_000)
        pacer.schedule(0, 2_000_000_000L)
        assertEquals(1, pacer.level)
        // ... the display listener's rate change is.
        v.setNominalHz(60f)
        pacer.schedule(0, 2_000_000_000L + p60)
        assertEquals(0, pacer.level)
    }

    @Test fun sixtyFpsContentOn120HzStaysOneSlotPerFrame() {
        val v = clock(p120)
        val pacer = AdaptivePacer(v, p60)
        var prev = Long.MIN_VALUE
        for (k in 0 until 300) {
            val cap = 1_000_000_000L + k * p60
            val d = pacer.schedule(cap / 1000, cap + 10 * ms + (k % 3) * ms)!!
            if (prev != Long.MIN_VALUE) assertTrue("slots ${d.slotNs - prev}", d.slotNs > prev)
            assertFalse(d.lateDrop)
            prev = d.slotNs
        }
    }
}
