package dev.matebridge.client.video

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class PresentStatsTest {
    private val p = 16_666_667L

    @Test fun countsMissedVsyncsOnlyForLargeGaps() {
        val s = PresentStats()
        s.onVsync(0, p); s.onVsync(p, p); s.onVsync(p * 2 + 2_000_000, p) // jitter, not a miss
        s.onVsync(p * 5, p) // two vsyncs skipped
        val snap = s.snapshot()
        assertEquals(4, snap.vsyncs)
        assertEquals(2, snap.missed)
    }

    @Test fun breakSequenceSuppressesGap() {
        val s = PresentStats()
        s.onVsync(0, p)
        s.breakSequence()
        s.onVsync(p * 100, p)
        assertEquals(0, s.snapshot().missed)
    }

    @Test fun drawAveragesAndReset() {
        val s = PresentStats()
        s.onDraw(4_000_000, 1_000_000, 0)
        s.onDraw(8_000_000, 3_000_000, 2)
        val snap = s.snapshot(reset = true)
        assertEquals(2, snap.drawn)
        assertEquals(2, snap.coalesced)
        assertEquals(6_000, snap.waitAvgUs)
        assertEquals(8_000, snap.waitMaxUs)
        assertEquals(2_000, snap.swapAvgUs)
        assertEquals(3_000, snap.swapMaxUs)
        assertTrue(snap.fields().contains("gl_wait_avg_ms=6.00"))
        assertEquals(0, s.snapshot().drawn)
    }
}
