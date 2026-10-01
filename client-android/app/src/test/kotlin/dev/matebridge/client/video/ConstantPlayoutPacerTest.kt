package dev.matebridge.client.video

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

private const val MS = 1_000_000L

/**
 * T-080: constant playout delay. The offline equivalence test replays `tools/pacing/trace7_120hz_excerpt.csv` (read in
 * place) and compares with `tools/pacing/sim.py --hz 120` (values below, from the same trace and parameters).
 */
class ConstantPlayoutPacerTest {
    private class Row(val captureUs: Long, val readyNs: Long, val vsyncNs: Long, val periodNs: Long)

    private fun trace(): List<Row> {
        val f = listOf("../../tools/pacing/trace7_120hz_excerpt.csv", "tools/pacing/trace7_120hz_excerpt.csv")
            .map(::File).first { it.exists() }
        val lines = f.readLines()
        val h = lines[0].split(',')
        fun col(n: String) = h.indexOf(n).also { require(it >= 0) { n } }
        val cCap = col("capture_us"); val cRdy = col("ready_ns"); val cVs = col("now_vsync_last_ns"); val cP = col("period_ns")
        return lines.drop(1).filter { it.isNotBlank() }.map { it.split(',') }.filter { it[cP].startsWith("833") }
            .map { Row(it[cCap].toLong(), it[cRdy].toLong(), it[cVs].toLong(), it[cP].toLong()) }
    }

    private class Result(val latP50Ms: Double, val gapPct: Double, val gaps: Int, val drops: Int, val cont: Int)

    /** Same metrics as sim.py: latency = slot - ready of shown frames, planned gap = > 1.5 P between shown slots of continuous captures. */
    private fun replay(rows: List<Row>, qPermille: Int, idleNs: Long): Result {
        val clk = VsyncClock(120f)
        val p = ConstantPlayoutPacer(clk, CpdConfig(qPermille, 2 * MS), idleNs = idleNs)
        var prev = Long.MIN_VALUE
        val lat = ArrayList<Double>()
        var gaps = 0; var drops = 0; var cont = 0
        for ((i, r) in rows.withIndex()) {
            val continuous = i > 0 && Math.abs((r.captureUs - rows[i - 1].captureUs) * 1000 - 8_333_333L) < 1_000_000L
            if (continuous) cont++
            val d = p.scheduleOn(VsyncClock.Grid(r.vsyncNs, r.periodNs, 0, 6 * MS), r.captureUs, r.readyNs, 0)
            assertFalse(d.lateDrop)
            if (prev != Long.MIN_VALUE) {
                if (d.collided) { assertEquals(prev, d.slotNs); drops++; continue }
                if (d.slotNs - prev > r.periodNs * 3 / 2 && continuous) gaps++
            }
            assertTrue(d.slotNs >= r.readyNs + 6 * MS)
            prev = d.slotNs
            lat.add((d.slotNs - r.readyNs) / 1e6)
        }
        lat.sort()
        val m = lat.size / 2
        val p50 = if (lat.size % 2 == 1) lat[m] else (lat[m - 1] + lat[m]) / 2
        return Result(p50, 100.0 * gaps / cont, gaps, drops, cont)
    }

    private fun assertSim(label: String, r: Result, latMs: Double, gapPct: Double) {
        println("$label: lat p50 ${"%.4f".format(r.latP50Ms)} ms (sim $latMs), gaps ${r.gaps}/${r.cont} = ${"%.4f".format(r.gapPct)}% (sim $gapPct), drops ${r.drops}")
        assertEquals("$label latency p50", latMs, r.latP50Ms, 0.5)
        assertEquals("$label planned gaps", gapPct, r.gapPct, 0.2)
    }

    @Test fun traceReplayMatchesSimWithoutIdleRule() {
        val rows = trace()
        assertEquals(2868, rows.size)
        // python3 tools/pacing/sim.py tools/pacing/trace7_120hz_excerpt.csv --hz 120 --q Q
        assertSim("q=0.95", replay(rows, 950, Long.MAX_VALUE), 18.0738, 0.4765)
        assertSim("q=0.90", replay(rows, 900, Long.MAX_VALUE), 13.2816, 1.0630)
        assertSim("q=0.99", replay(rows, 990, Long.MAX_VALUE), 20.3970, 0.1833)
    }

    @Test fun traceReplayMatchesSimWithIdleRule() {
        val rows = trace()
        // ... --hz 120 --q Q --idle-ms 1000 (refill 32)
        assertSim("idle q=0.95", replay(rows, 950, ConstantPlayoutPacer.IDLE_NS), 15.6266, 0.4765)
        assertSim("idle q=0.90", replay(rows, 900, ConstantPlayoutPacer.IDLE_NS), 12.9593, 1.0630)
        assertSim("idle q=0.99", replay(rows, 990, ConstantPlayoutPacer.IDLE_NS), 19.7933, 0.2199)
    }

    // --- unit behaviour ------------------------------------------------------------------------------------------

    private val period = 8_333_333L
    /** Capture step in whole microseconds (capture times travel in us), so x has no sub-us residue. */
    private val CAP_STEP = 8_333_000L
    private fun grid(epoch: Int = 0, p: Long = period) = VsyncClock.Grid(0, p, epoch, 6 * MS)

    /** Feeds [n] frames at 120 fps from [startCap]; ready = capture + 10 ms + delay(k). Returns the next capture time. */
    private fun feed(pacer: ConstantPlayoutPacer, startCap: Long, n: Int, epoch: Int = 0, delay: (Int) -> Long): Long {
        var cap = startCap
        for (k in 0 until n) { pacer.scheduleOn(grid(epoch), cap / 1000, cap + 10 * MS + delay(k), 0); cap += CAP_STEP }
        return cap
    }

    private fun cOf(probe: PaceProbe) = probe.lockSlotNs - 10 * MS // C minus the fixed part of x

    @Test fun playoutDelayFollowsTheJitterQuantileWithHold() {
        val p = ConstantPlayoutPacer(VsyncClock(120f), CpdConfig(950, 2 * MS))
        val probe = PaceProbe().also { p.probe = it }
        // every 10th frame is 6 ms late: 10% > 5%, so the 0.95 quantile is 6 ms
        var cap = feed(p, 1_000_000_000L, 256) { if (it % 10 == 0) 6 * MS else 0 }
        assertEquals(6 * MS, cOf(probe))
        assertEquals(PaceProbe.PATH_CPD, probe.path)
        // now every 10th frame is 7.5 ms late: within the 2 ms hold, C stays
        cap = feed(p, cap, 256) { if (it % 10 == 0) 7_500_000L else 0 }
        assertEquals(6 * MS, cOf(probe))
        // 9 ms late: beyond the hold, C follows
        feed(p, cap, 256) { if (it % 10 == 0) 9 * MS else 0 }
        assertEquals(9 * MS, cOf(probe))
    }

    @Test fun targetIsCapturePlusDelayPlusDeadlineNeverBeforeReadyPlusDeadline() {
        val p = ConstantPlayoutPacer(VsyncClock(120f), CpdConfig(950, 2 * MS))
        var cap = feed(p, 1_000_000_000L, 256) { if (it % 10 == 0) 6 * MS else 0 }
        // on-time frame: slot = first vsync >= capture + 16 ms (C) + 6 ms (L)
        val d = p.scheduleOn(grid(), cap / 1000, cap + 10 * MS, 0)
        assertEquals(grid().gridSlotAtOrAfter(cap + 22 * MS), d.slotNs)
        assertFalse(d.lateDrop)
        cap += CAP_STEP
        // a frame later than C: ready + L, never dropped as late
        val late = p.scheduleOn(grid(), cap / 1000, cap + 30 * MS, 0)
        assertEquals(grid().gridSlotAtOrAfter(cap + 36 * MS), late.slotNs)
        assertFalse(late.lateDrop)
    }

    @Test fun sameSlotTakesThePreviousSlotNewestWins() {
        val p = ConstantPlayoutPacer(VsyncClock(60f), CpdConfig())
        val g = VsyncClock.Grid(0, 16_666_667L, 0, 6 * MS)
        val cap = 1_000_000_000L
        val a = p.scheduleOn(g, cap / 1000, cap + 10 * MS, 0)
        val b = p.scheduleOn(g, (cap + period) / 1000, cap + period + 10 * MS, 0) // 120 fps on a 60 Hz panel
        assertTrue(b.collided || b.slotNs > a.slotNs)
        // frames 8.3 ms apart on a 16.7 ms grid: every other one shares a slot
        var collided = 0
        var c = cap + 2 * period
        repeat(40) { if (p.scheduleOn(g, c / 1000, c + 10 * MS, 0).collided) collided++; c += period }
        assertEquals(20, collided)
    }

    @Test fun epochChangeResetsEverything() {
        val p = ConstantPlayoutPacer(VsyncClock(120f), CpdConfig())
        val probe = PaceProbe().also { p.probe = it }
        val cap = feed(p, 1_000_000_000L, 256) { if (it % 10 == 0) 8 * MS else 0 }
        assertEquals(8 * MS, cOf(probe))
        val d = p.scheduleOn(grid(epoch = 1, p = 16_666_667L), cap / 1000, cap + 10 * MS, 0)
        assertEquals(0L, cOf(probe)) // one sample, no jitter: C = x
        assertEquals(1L, probe.k)
        assertEquals(grid(1, 16_666_667L).gridSlotAtOrAfter(cap + 16 * MS), d.slotNs)
    }

    @Test fun idleGapRefillsTheWindowButKeepsTheDelay() {
        val p = ConstantPlayoutPacer(VsyncClock(120f), CpdConfig())
        val probe = PaceProbe().also { p.probe = it }
        var cap = feed(p, 1_000_000_000L, 256) { if (it % 10 == 0) 8 * MS else 0 }
        assertEquals(8 * MS, cOf(probe))
        cap += 1_500_000_000L
        // after the gap: on-time frames only. C is kept while the window refills, then falls to the new quantile.
        val d = p.scheduleOn(grid(), cap / 1000, cap + 10 * MS, 0)
        assertEquals(1L, probe.k)
        assertEquals(8 * MS, cOf(probe))
        assertEquals(grid().gridSlotAtOrAfter(cap + 24 * MS), d.slotNs)
        cap += CAP_STEP
        cap = feed(p, cap, ConstantPlayoutPacer.REFILL_MIN - 2) { 0 }
        assertEquals(8 * MS, cOf(probe))
        feed(p, cap, 1) { 0 }
        assertEquals(0L, cOf(probe))
    }

    @Test fun idleRefillStillRaisesTheDelay() {
        val p = ConstantPlayoutPacer(VsyncClock(120f), CpdConfig())
        val probe = PaceProbe().also { p.probe = it }
        var cap = feed(p, 1_000_000_000L, 256) { 0 }
        assertEquals(0L, cOf(probe))
        cap += 1_500_000_000L
        cap = feed(p, cap, 4) { 0 }
        feed(p, cap, 1) { 9 * MS } // with 5 samples the 0.95 quantile is the maximum
        assertEquals(9 * MS, cOf(probe))
    }

    // --- T-065 invariant with CPD: pacer + SlotReleaser end to end -----------------------------------------------

    private class Lcg(var seed: Long = 777L) {
        fun next(): Double { seed = seed * 6364136223846793005L + 1442695040888963407L; return ((seed ushr 33) % 10_000) / 10_000.0 }
    }

    private class Sim(panelHz: Int) {
        val clk = VsyncClock(panelHz.toFloat()).also { it.onVsync(0); it.setDisplayTiming(0, 13_330_000L) }
        val pacer = ConstantPlayoutPacer(clk, CpdConfig())
        var current = -1
        val releasedAt = HashMap<Int, Long>()
        val selfDiscarded = ArrayList<Int>()
        val replaced = ArrayList<Int>()
        val rel = SlotReleaser(object : SlotReleaser.Sink {
            override fun release(idx: Int, renderNs: Long) { releasedAt[idx] = renderNs }
            override fun discard(idx: Int) { if (idx == current) selfDiscarded.add(idx) else replaced.add(idx) }
        }, PresentCounters())
        var now = 0L

        fun advanceTo(t: Long) {
            val period = clk.grid().periodNs
            var v = clk.grid().lastNs
            while (v + period <= t) { v += period; clk.onVsync(v) }
            rel.flushDue(t)
            now = t
        }

        fun frame(k: Int, captureNs: Long, readyNs: Long) {
            advanceTo(readyNs)
            current = k
            val d = pacer.schedule(captureNs / 1000, readyNs)!!
            assertFalse(d.lateDrop)
            rel.submit(k, d.slotNs, d.renderNs, d.slotNs - (clk.grid().deadlineNs + 1 * MS), readyNs, clk.periodNs)
            current = -1
        }

        fun finish() { advanceTo(now + 300 * MS) }
    }

    private fun run(panelHz: Int, gapMinMs: Int, gapMaxMs: Int, n: Int = 300, switchTo: Int? = null): Sim {
        val s = Sim(panelHz)
        val rnd = Lcg()
        val hostTick = 1_000_000_000L / 120
        var cap = 1_000_000_000L
        for (k in 0 until n) {
            cap += (gapMinMs + (rnd.next() * (gapMaxMs - gapMinMs)).toInt()) * MS
            cap = (cap / hostTick) * hostTick
            if (switchTo != null && k == n / 2) s.clk.setNominalHz(switchTo.toFloat())
            s.frame(k, cap, cap + 15 * MS + (rnd.next() * 8 * MS).toLong())
        }
        s.finish()
        return s
    }

    private fun check(label: String, s: Sim, n: Int) {
        assertTrue("$label: frames dropped without a newer one: ${s.selfDiscarded}", s.selfDiscarded.isEmpty())
        assertTrue("$label: newest frame never released", s.releasedAt.containsKey(n - 1))
        for (k in 0 until n) assertTrue("$label: frame $k vanished", s.releasedAt.containsKey(k) || k in s.replaced)
    }

    @Test fun sparseFramesAreNeverDroppedOnCpd() {
        for (panel in listOf(60, 120)) for ((lo, hi) in listOf(100 to 600, 20 to 60, 1100 to 3000, 4 to 12)) {
            check("cpd panel=$panel gaps=$lo..$hi", run(panel, lo, hi), 300)
        }
    }

    @Test fun panelSwitchOnCpdLosesNoNewestFrame() {
        for ((from, to) in listOf(60 to 120, 120 to 60)) for ((lo, hi) in listOf(100 to 600, 8 to 9, 20 to 60)) {
            check("cpd switch $from->$to gaps=$lo..$hi", run(from, lo, hi, switchTo = to), 300)
        }
    }

    @Test fun continuousStreamAtPanelRateShowsEveryFrame() {
        for (panel in listOf(60, 120)) {
            val s = Sim(panel)
            val step = 1_000_000_000L / panel
            var cap = 1_000_000_000L
            val rnd = Lcg(5)
            for (k in 0 until 600) { s.frame(k, cap, cap + 12 * MS + (rnd.next() * 3 * MS).toLong()); cap += step }
            s.finish()
            // jitter (3 ms) is inside the playout delay: one frame per slot, nothing replaced after warm-up
            assertTrue("panel=$panel replaced ${s.replaced.size}", s.replaced.count { it > 10 } == 0)
        }
    }
}
