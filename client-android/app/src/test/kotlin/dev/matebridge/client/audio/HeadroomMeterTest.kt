package dev.matebridge.client.audio

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class HeadroomMeterTest {
    private val ms = 1_000_000L

    /** Steady 5 ms writes that each block 4.9 ms; headroom values from [h]. Returns the next start time. */
    private fun HeadroomMeter.feed(h: List<Long>, startNs: Long = 0L): Long {
        var t = startNs
        for (v in h) {
            onWriteStart(v, t)
            onWriteEnd(t + 4_900_000L)
            t += 5 * ms
        }
        return t
    }

    @Test fun minP5AndUnderflowFromFakeCounters() {
        val m = HeadroomMeter()
        // 100 writes: written - read from fake counters. 95 at a full ring (480), five low ones.
        val values = MutableList(95) { 480L } + listOf(300L, 200L, 100L, 0L, -40L)
        m.feed(values.shuffled(java.util.Random(7)))
        val w = m.window()
        assertEquals(100, w.writes)
        assertEquals(-40L, w.headroomMinFrames)
        assertEquals(300L, w.headroomP5Frames) // nearest rank ceil(0.05 × 100) = 5: the 5th lowest
        assertEquals(2, w.underflowEst) // 0 and -40
    }

    @Test fun p5IsTheNearestRank() {
        val m = HeadroomMeter()
        m.feed((1L..200L).toList().reversed())
        val w = m.window()
        assertEquals(1L, w.headroomMinFrames)
        assertEquals(10L, w.headroomP5Frames) // ceil(0.05 × 200) = 10th lowest
        assertEquals(0, w.underflowEst)
    }

    @Test fun headroomIsWrittenMinusRead() {
        // The sink reports frames written - frames read; a writer away 7 ms from a full 480-frame ring leaves 144.
        val written = 100_000L
        val read = written - 480 + 336
        val m = HeadroomMeter()
        m.onWriteStart(written - read, 0)
        assertEquals(144L, m.window().headroomMinFrames)
    }

    @Test fun gapAndBusyTimes() {
        val m = HeadroomMeter()
        m.onWriteStart(480, 0); m.onWriteEnd(4 * ms)
        m.onWriteStart(480, 5 * ms); m.onWriteEnd(9 * ms)
        // The writer is away for 8 ms (render + a preemption) before the next write.
        m.onWriteStart(100, 17 * ms); m.onWriteEnd(18 * ms)
        val w = m.window()
        assertEquals(12 * ms, w.gapMaxNs)
        assertEquals(8 * ms, w.busyMaxNs)
    }

    @Test fun windowResetsFiguresButTimesCarryOver() {
        val m = HeadroomMeter()
        val next = m.feed(listOf(10L, -5L))
        m.window()
        val empty = m.window()
        assertEquals(0, empty.writes)
        assertNull(empty.headroomMinFrames)
        assertNull(empty.headroomP5Frames)
        assertEquals(0, empty.underflowEst)
        assertEquals(0L, empty.gapMaxNs)
        // A gap that spans the window boundary is counted in the new window.
        m.onWriteStart(480, next + 20 * ms)
        assertEquals(25 * ms, m.window().gapMaxNs)
    }

    @Test fun resetForgetsTheOldOutputsTimes() {
        val m = HeadroomMeter()
        m.feed(listOf(480L, 480L))
        m.reset()
        m.onWriteStart(480, 10_000 * ms)
        val w = m.window()
        assertEquals(0L, w.gapMaxNs)
        assertEquals(0L, w.busyMaxNs)
        assertEquals(1, w.writes)
    }

    @Test fun unknownHeadroomKeepsOnlyTiming() {
        val m = HeadroomMeter()
        m.feed(List(10) { AudioSink.HEADROOM_UNKNOWN })
        val w = m.window()
        assertEquals(10, w.writes)
        assertNull(w.headroomMinFrames)
        assertNull(w.headroomP5Frames)
        assertEquals(0, w.underflowEst)
        assertEquals(5 * ms, w.gapMaxNs)
    }

    @Test fun overflowKeepsMinAndUnderflow() {
        val m = HeadroomMeter(capacity = 8)
        m.feed(List(20) { 480L } + listOf(-1L))
        val w = m.window()
        assertEquals(21, w.writes)
        assertEquals(-1L, w.headroomMinFrames)
        assertEquals(1, w.underflowEst)
        assertEquals(480L, w.headroomP5Frames) // only the first 8 samples were kept for the percentile
    }
}
