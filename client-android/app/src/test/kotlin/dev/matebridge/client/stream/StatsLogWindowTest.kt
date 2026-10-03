package dev.matebridge.client.stream

import dev.matebridge.client.video.IntervalHistogram
import dev.matebridge.client.video.VideoStats
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** T-141: the video stats log lines summarize a 10 s (or 1 s) window built from the per-second STATS windows. */
class StatsLogWindowTest {

    /** One second of a 60 fps stream: [n] frames, 16.7 ms apart, decode [decUs] each, latency [latUs]. */
    private fun second(st: VideoStats, startUs: Long, n: Int, decUs: Long, latUs: Long, bytes: Int = 1000) {
        st.latencyOf = { _, _ -> latUs }
        for (k in 0 until n) {
            val t = startUs + k * 16_667L
            val pts = startUs + k
            st.onReceived(bytes, t)
            st.onInput(pts, t, captureTimeUs = 1)
            st.onOutput(pts, t + decUs)
            st.onPaceAdd(2_000)
            st.onScheduled(skipped = k == 0)
            st.onRendered()
        }
        st.onDropped(1)
    }

    @Test fun tenSecondLogWindowIsTheExactSumOfItsSeconds() {
        val st = VideoStats()
        val perSecond = ArrayList<VideoStats.Snapshot>()
        for (i in 0 until 10) {
            second(st, i * 1_000_000L, n = 60, decUs = if (i < 5) 8_000 else 12_000, latUs = if (i < 5) 30_000 else 50_000)
            perSecond += st.snapshot(reset = true) // what the STATS tick does each second
        }
        // The per-second windows are unchanged (STATS to the host).
        assertEquals(60L, perSecond[3].received)
        assertEquals(8_000L, perSecond[3].decodeTimeAvgUs)
        assertEquals(50_000L, perSecond[7].latencyAvgUs)

        val log = st.logSnapshot(reset = true)
        assertEquals(600L, log.received)
        assertEquals(600L, log.decoded)
        assertEquals(600L, log.rendered)
        assertEquals(10L, log.dropped)
        assertEquals(600_000L, log.bytesReceived)
        assertEquals("weighted decode average", 10_000L, log.decodeTimeAvgUs)
        assertEquals("weighted latency average", 40_000L, log.latencyAvgUs)
        assertEquals(2_000L, log.paceAddAvgUs)
        assertEquals("1 skip per 60 scheduled", 100.0 / 60, log.skipPct!!, 1e-9)
        // Percentiles over all 10 s: gaps within each second are 16.7 ms, between seconds 16.7 ms too (1 s = 60 x 16.67).
        assertEquals(599, log.network.count) // 600 frames, first gap needs a previous frame
        assertEquals(16_667L, log.network.p50Us)
        // Decode p95 over the window: half the frames 8 ms, half 12 ms.
        assertEquals(10 * 60 - 0, log.decode.count)
        assertEquals(12_000L, log.decode.p95Us)
        assertEquals(8_000L, log.decode.p50Us)
        // Reset: the next log window starts empty, and the still-open second is not in it.
        second(st, 20_000_000L, n = 5, decUs = 1_000, latUs = 1_000)
        assertEquals(0L, st.logSnapshot(reset = true).received)
        assertEquals(5L, st.snapshot(reset = true).received)
        assertEquals(5L, st.logSnapshot(reset = true).received)
    }

    @Test fun oneSecondLogWindowEqualsThePerSecondWindow() {
        val st = VideoStats()
        second(st, 0, n = 30, decUs = 9_000, latUs = 25_000)
        val s = st.snapshot(reset = true)
        val log = st.logSnapshot(reset = true)
        assertEquals(s, log)
    }

    @Test fun emptyWindowHasNoFramesAndUnknownAverages() {
        val st = VideoStats()
        repeat(10) { st.snapshot(reset = true) }
        val log = st.logSnapshot(reset = true)
        assertFalse(StatsLogWindow.hasFrames(log))
        assertNull(log.latencyAvgUs)
        assertNull(log.skipPct)
        assertEquals(0, log.network.count)
        second(st, 0, n = 1, decUs = 1, latUs = 1)
        st.snapshot(reset = true)
        assertTrue(StatsLogWindow.hasFrames(st.logSnapshot(reset = true)))
    }

    /**
     * Review P3: a stream that ends (or is reconfigured) 800 ms into a second. The boundary closes the unfinished second
     * into the log window, so its frames are logged with their stream and nothing leaks into the next stream.
     */
    @Test fun streamBoundaryClosesTheUnfinishedSecond() {
        val st = VideoStats()
        val w = StatsLogWindow()
        w.start(0)
        // Session A: only 800 ms of frames, no per-second tick ever ran.
        second(st, 0, n = 48, decUs = 9_000, latUs = 30_000)
        st.closeWindow() // what MainActivity.flushStatsLog does at the boundary
        val interval = w.close(800)
        val a = st.logSnapshot(reset = true)
        assertEquals(800L, interval)
        assertTrue(StatsLogWindow.hasFrames(a))
        assertEquals(48L, a.received)
        assertEquals(30_000L, a.latencyAvgUs)
        // Session B on the same (reused) renderer: its first STATS second and its log window hold only its own frames.
        w.start(5_000)
        second(st, 5_000_000L, n = 10, decUs = 9_000, latUs = 20_000)
        val firstStats = st.snapshot(reset = true)
        assertEquals(10L, firstStats.received)
        assertEquals(20_000L, firstStats.latencyAvgUs)
        val b = st.logSnapshot(reset = true)
        assertEquals(10L, b.received)
        assertEquals(1L, b.dropped)
    }

    @Test fun boundaryWithoutFramesLogsNothing() {
        val st = VideoStats()
        val w = StatsLogWindow()
        w.start(0)
        st.closeWindow()
        assertEquals(300L, w.close(300))
        assertFalse(StatsLogWindow.hasFrames(st.logSnapshot(reset = true)))
    }

    @Test fun histogramSummaryIntoMovesTheWindowExactly() {
        val sec = IntervalHistogram(10_000)
        val win = IntervalHistogram(10_000)
        for (v in 1L..100L) sec.record(v * 1_000)
        val s1 = sec.summaryInto(win)
        assertEquals(100, s1.count)
        assertEquals(90, s1.overThreshold)
        assertEquals(0, sec.summary().count) // the second is reset
        for (v in 101L..200L) sec.record(v * 1_000)
        sec.summaryInto(win)
        val w = win.summary(reset = true)
        assertEquals(200, w.count)
        assertEquals(190, w.overThreshold)
        assertEquals(100_000L, w.p50Us)
        assertEquals(190_000L, w.p95Us)
        assertEquals(0, win.summary().count)
    }

    @Test fun windowClosesOnTheTickNearItsEndAndReportsItsRealLength() {
        val w = StatsLogWindow()
        assertFalse(w.isOpen)
        assertFalse(w.due(50_000))
        assertEquals(-1L, w.close(50_000))
        w.start(1_000)
        // Ticks about a second apart, drifting late by a few ms.
        var t = 1_000L
        var closedAt = -1L
        for (i in 1..12) {
            t += 1_003
            if (w.due(t)) { closedAt = t; break }
        }
        assertEquals(1_000L + 10 * 1_003, closedAt)
        assertEquals(10_030L, w.close(closedAt))
        assertFalse(w.isOpen)
        // A tick slightly early still closes a 10 s window (no 11 s windows).
        w.start(0)
        assertFalse(w.due(9_700))
        assertTrue(w.due(9_760))
    }

    @Test fun fastWindowClosesOnEveryPerSecondTick() {
        val w = StatsLogWindow(StatsLogWindow.FAST_MS)
        w.start(0)
        assertFalse(w.due(500))
        assertTrue(w.due(1_000)) // per-second ticks are >= 1000 ms apart: each one closes the window
        assertEquals(1_000L, w.close(1_000))
        w.start(1_000)
        assertTrue(w.due(2_004))
        assertEquals(1_004L, w.close(2_004))
    }
}
