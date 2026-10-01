package dev.matebridge.client.video

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class PaceTraceTest {
    private fun csv(t: PaceTrace) = StringBuilder().also { t.writeCsv(it) }.toString().trim().split("\n")

    @Test fun headerHasAllColumns() {
        val lines = csv(PaceTrace(4))
        assertEquals(1, lines.size)
        assertEquals(PaceTrace.COLS, lines[0].split(",").size)
        assertTrue(lines[0].startsWith("seq,capture_us,ready_ns,"))
        assertTrue(lines[0].contains(",path,late_drop,collided,released_slot_ns,release_ns,render_ns,action"))
    }

    @Test fun ringOverflowKeepsNewestRowsInOrder() {
        val t = PaceTrace(3)
        for (i in 1..5) t.record(i.toLong(), 0, 0, null, 0, false, false, 0)
        assertEquals(3, t.size)
        val lines = csv(t)
        assertEquals(4, lines.size)
        assertEquals(listOf("3", "4", "5"), lines.drop(1).map { it.substringBefore(',') })
    }

    @Test fun updatesOfEvictedFramesAreIgnored() {
        val t = PaceTrace(2)
        val old = t.record(1, 0, 0, null, 0, false, false, 0)
        t.record(2, 0, 0, null, 0, false, false, 0)
        t.record(3, 0, 0, null, 0, false, false, 0)
        t.onRelease(old, 5, 6, 7) // must not corrupt the row that reuses the slot
        val rows = csv(t).drop(1).map { it.split(",") }
        assertEquals(listOf("2", "3"), rows.map { it[0] })
        assertTrue(rows.all { it[22] == "pending" })
    }

    @Test fun releaserReportsActionsAndProbeValuesLandInTheRow() {
        val t = PaceTrace(8)
        val counters = PresentCounters()
        val rel = SlotReleaser(object : SlotReleaser.Sink {
            override fun release(idx: Int, renderNs: Long) {}
            override fun discard(idx: Int) {}
        }, counters)
        rel.trace = t
        val probe = PaceProbe().also { it.path = PaceProbe.PATH_LOCKED; it.k = 1; it.badRun = 3; it.periodNs = 8_333_333 }
        val a = t.record(1, 10, 100, probe, 1000, false, false, 0)
        rel.submit(1, 1000, 900, 10_000, 0, 100, a)
        val b = t.record(2, 20, 110, probe, 1000, false, true, 0)
        rel.submit(2, 1000, 900, 10_000, 0, 100, b) // same slot: replaces a
        rel.flushAll()
        val rows = csv(t).drop(1).map { it.split(",") }
        assertEquals("replace", rows[0][22])
        assertEquals("release", rows[1][22])
        assertEquals("locked", rows[1][16])
        assertEquals("3", rows[1][15])
        assertEquals("1000", rows[1][19])
        assertEquals("900", rows[1][21])
        val c = t.record(3, 30, 120, probe, 1000, false, false, 0)
        rel.submit(3, 1000, 900, 10_000, 0, 100, c) // slot already released: moves one slot later
        rel.flushAll()
        val last = csv(t).last().split(",")
        assertEquals("move", last[22])
        assertEquals("1100", last[19])
    }

    @Test fun pacerFillsTheProbe() {
        val v = VsyncClock(60f)
        for (i in 0..5) v.onVsync(i * 16_666_667L)
        val p = AdaptivePacer(v, 16_666_667L)
        val probe = PaceProbe()
        p.probe = probe
        for (i in 0 until 5) {
            probe.clear()
            p.schedule(i * 16_667L, 100_000_000L + i * 16_666_667L)
        }
        assertTrue(probe.path != PaceProbe.PATH_NONE)
        assertTrue(probe.periodNs > 0)
        assertTrue(probe.earliestNs > 0)
    }
}
