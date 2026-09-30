package dev.matebridge.client.stream

import dev.matebridge.client.video.ArrivalTracker
import dev.matebridge.client.video.FrameInterval
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class DisplayRateTest {
    private val d = DisplayRateDebouncer()

    @Test fun firstValueGoesOutAtOnceAndUnknownIsIgnored() {
        assertNull(d.observe(0, 0))
        assertEquals(120, d.observe(120, 10))
        assertNull(d.observe(120, 20))
    }

    @Test fun riseIsImmediateFallNeedsHalfASecondOfStability() {
        d.observe(120, 0)
        assertNull(d.observe(60, 1000))
        assertNull(d.observe(60, 1400))
        assertEquals(60, d.observe(60, 1500))
        assertEquals(120, d.observe(120, 1760)) // rise: no waiting (beyond the spacing)
    }

    @Test fun aBlipBackUpResetsTheFallTimer() {
        d.observe(120, 0)
        assertNull(d.observe(60, 1000))
        assertNull(d.observe(120, 1300)) // same as reported: candidate cleared
        assertNull(d.observe(60, 1400))
        assertNull(d.observe(60, 1800)) // only 400 ms since the new candidate
        assertEquals(60, d.observe(60, 1900))
    }

    @Test fun atMostFourReportsPerSecondAndHeldValueIsReturnedLater() {
        assertEquals(60, d.observe(60, 0))
        assertNull(d.observe(120, 100)) // rise blocked by the 250 ms spacing
        assertEquals(120, d.observe(120, 250))
        var count = 0
        var t = 1000L
        var hz = 60
        // flapping up every tick: still at most 4 per 1000 ms
        while (t < 2000) {
            hz = if (hz == 60) 120 else 60
            if (d.observe(hz, t) != null) count++
            t += 10
        }
        assert(count <= 4) { "count=$count" }
    }

    @Test fun intervalFollowsThinnedArrivalsOnASlowPanel() {
        val stream = 8_333_333L
        val p60 = 16_666_667L
        assertEquals(stream, FrameInterval.resolve(stream, p60, 0)) // unknown: unchanged
        assertEquals(stream, FrameInterval.resolve(stream, p60, 8_333_333L)) // host has not thinned yet: surplus path
        assertEquals(p60, FrameInterval.resolve(stream, p60, 16_700_000L)) // thinned to the panel
        assertEquals(stream, FrameInterval.resolve(stream, 8_333_333L, 8_333_333L)) // fast panel: unchanged
        assertEquals(16_666_667L, FrameInterval.resolve(0, p60, 0)) // no stream interval: the period
    }

    @Test fun arrivalTrackerEstimatesAndIgnoresGapsAndResets() {
        val t = ArrivalTracker()
        var us = 1_000_000L
        for (i in 0 until 20) { t.onFrame(us); us += 16_667 }
        assertEquals(16_667_000.0, t.intervalNs.toDouble(), 100_000.0)
        us += 500_000 // static content: a long gap does not move the estimate
        t.onFrame(us)
        assertEquals(16_667_000.0, t.intervalNs.toDouble(), 100_000.0)
        t.reset()
        assertEquals(0L, t.intervalNs)
    }
}
