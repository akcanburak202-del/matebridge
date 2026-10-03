package dev.matebridge.client.video

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * T-208: phase lock at an integer cadence (60 fps content on a 120 Hz panel: every frame held exactly 2 vsyncs).
 * Deterministic: fake vsync grid fed up to each ready time, LCG jitter, no sleeps. Old/new comparisons use the A/B
 * switch [AdaptivePacer.integerLock].
 */
class IntegerCadenceLockTest {
    private val ms = 1_000_000L
    private val p60 = 1_000_000_000L / 60

    private class Lcg(var seed: Long) {
        fun next(): Double { seed = seed * 6364136223846793005L + 1442695040888963407L; return ((seed ushr 33) % 10_000) / 10_000.0 }
    }

    /**
     * Pacer + SlotReleaser on a live vsync grid (6 ms deadline), like the decoder output thread. The content interval
     * comes from [FrameInterval.resolve] with a 60 fps stream that arrives at 60 fps, as in the renderer.
     */
    private class Sim(panelHz: Int, integerLock: Boolean = true, streamNs: Long = 1_000_000_000L / 60) {
        val clk = VsyncClock(panelHz.toFloat()).also { it.onVsync(0); it.setDisplayTiming(0, 13_330_000L) }
        var period = clk.grid().periodNs
        val pacer = AdaptivePacer(clk, streamNs).also {
            it.integerLock = integerLock
            it.intervalProvider = { p -> FrameInterval.resolve(streamNs, p, streamNs) }
        }
        val probe = PaceProbe().also { pacer.probe = it }
        val shown = ArrayList<Long>() // released slots (display time), in release order
        val paths = HashMap<Int, Int>()
        var latencySumNs = 0.0
        var latencyN = 0
        private val rel = SlotReleaser(object : SlotReleaser.Sink {
            override fun release(idx: Int, renderNs: Long) { shown.add(renderNs + clk.leadNs()) }
            override fun discard(idx: Int) {}
        }, PresentCounters())
        private var vsyncNs = 0L

        fun advanceTo(t: Long) {
            while (vsyncNs + period <= t) { vsyncNs += period; clk.onVsync(vsyncNs) }
            rel.flushDue(t)
        }

        /** The panel switches to [hz] at [atNs]; its next vsync comes [phaseNs] after the last one of the old rate. */
        fun switchPanel(hz: Int, atNs: Long, phaseNs: Long) {
            advanceTo(atNs)
            clk.setNominalHz(hz.toFloat())
            period = clk.grid().periodNs
            vsyncNs += phaseNs - period // the loop adds one period
        }

        fun frame(k: Int, captureNs: Long, readyNs: Long): FramePacer.Decision {
            advanceTo(readyNs)
            probe.clear()
            val d = pacer.schedule(captureNs / 1000, readyNs)!!
            paths.merge(probe.path, 1, Int::plus)
            if (!d.lateDrop && !d.collided) { latencySumNs += (d.slotNs - readyNs).toDouble(); latencyN++ }
            rel.submit(k, d.slotNs, d.renderNs, d.slotNs - (clk.grid().deadlineNs + 1_000_000L), readyNs, period)
            return d
        }

        fun finish(t: Long) { advanceTo(t); rel.flushAll() }

        val meanLatencyMs: Double get() = latencySumNs / latencyN / 1e6
    }

    /** Hold of each shown frame, in vsyncs of [periodNs] (rounded). */
    private fun holds(slots: List<Long>, periodNs: Long): Map<Long, Int> {
        val h = HashMap<Long, Int>()
        for (i in 1 until slots.size) h.merge(Math.round((slots[i] - slots[i - 1]).toDouble() / periodNs), 1, Int::plus)
        return h
    }

    /**
     * 60 fps for [frames] frames, ready = capture + base + uniform jitter in +-[jitterNs]; base puts the mean [phaseNs]
     * into a period. [bimodal]: the jitter is either -[jitterNs] or +[jitterNs] (plus 0..1 ms), like the 12.5 / 20.8 ms
     * buckets of the device measurement (NOTES 2026-10-04).
     */
    private fun stream60(
        s: Sim, frames: Int, phaseNs: Long, jitterNs: Long, seed: Long, startCap: Long = 1_000_000_000L, bimodal: Boolean = false,
    ) {
        val rnd = Lcg(seed)
        val base = 20 * ms + Math.floorMod(phaseNs - (startCap + 20 * ms), s.period)
        for (k in 0 until frames) {
            val cap = startCap + k * p60
            val j = if (bimodal) (if (rnd.next() < 0.5) -jitterNs else jitterNs) + (rnd.next() * ms).toLong()
            else ((rnd.next() * 2 - 1) * jitterNs).toLong()
            s.frame(k, cap, cap + base + j)
        }
        s.finish(startCap + frames * p60 + 100 * ms)
    }

    @Test fun bimodalArrivalsOn120HzHoldTwoVsyncs() {
        // Device-like arrivals: half the frames ~8 ms later than the others. Without the lock the slack D exceeds a
        // period and the latency bound pulls the early frames one vsync forward: holds of 1 and 3 vsyncs.
        val p120 = 1_000_000_000L / 120
        var worstOld = 100.0
        for ((i, phase) in LongArray(9) { it * ms }.withIndex()) {
            val s = Sim(120).also { stream60(it, 3600, phase, 4 * ms, seed = 51L + i, bimodal = true) }
            val old = Sim(120, integerLock = false).also { stream60(it, 3600, phase, 4 * ms, seed = 51L + i, bimodal = true) }
            val h = holds(s.shown, p120); val ho = holds(old.shown, p120)
            val two = (h[2L] ?: 0) * 100.0 / h.values.sum()
            val twoOld = (ho[2L] ?: 0) * 100.0 / ho.values.sum()
            println("bimodal phase ${phase / ms} ms: new holds $h (${f(two)}% at 2), latency ${f(s.meanLatencyMs)} ms | " +
                "old holds $ho (${f(twoOld)}% at 2), latency ${f(old.meanLatencyMs)} ms")
            assertTrue("phase $phase: holds $h", two >= 99.0)
            assertTrue("phase $phase: latency ${s.meanLatencyMs} vs ${old.meanLatencyMs}", s.meanLatencyMs <= old.meanLatencyMs + 2.0)
            worstOld = minOf(worstOld, twoOld)
        }
        assertTrue("the old schedule reproduces the device symptom: $worstOld", worstOld < 80.0)
    }

    @Test fun hostClockDriftOn120HzRephasesWithFewIrregularHolds() {
        // Host 59.95 Hz against a 120.00 Hz panel: 100 s drift about 10 periods.
        for (dir in intArrayOf(1, -1)) {
            val p120 = 1_000_000_000L / 120
            val s = Sim(120)
            val fi = if (dir > 0) (p60 * 60.0 / 59.95).toLong() else (p60 * 59.95 / 60.0).toLong()
            val rnd = Lcg(17L)
            for (k in 0 until 6000) {
                val cap = 1_000_000_000L + k * fi
                s.frame(k, cap, cap + 20 * ms + ((rnd.next() * 2 - 1) * 3 * ms).toLong())
            }
            s.finish(1_000_000_000L + 6000 * fi + 100 * ms)
            val h = holds(s.shown, p120)
            val irregular = h.values.sum() - (h[2L] ?: 0)
            println("drift ${if (dir > 0) "slow" else "fast"} host: holds $h, rephases ${s.pacer.rephases}")
            assertTrue("rephases ${s.pacer.rephases}", s.pacer.rephases in 1L..20L)
            assertTrue("irregular $irregular holds $h", irregular <= 2 * s.pacer.rephases + 4)
        }
    }

    @Test fun sixtyFpsWithFourMsJitterOn120HzHoldsTwoVsyncs() {
        val p120 = 1_000_000_000L / 120
        for ((i, phase) in longArrayOf(0, 2 * ms, 4 * ms, 6 * ms, 8 * ms).withIndex()) {
            val s = Sim(120)
            stream60(s, 3600, phase, 4 * ms, seed = 31L + i)
            val h = holds(s.shown, p120)
            val total = h.values.sum()
            val two = h[2L] ?: 0
            val old = Sim(120, integerLock = false).also { stream60(it, 3600, phase, 4 * ms, seed = 31L + i) }
            val ho = holds(old.shown, p120)
            println("phase ${phase / ms} ms: new holds $h (${pct(two, total)}% at 2), latency ${f(s.meanLatencyMs)} ms | " +
                "old holds $ho (${pct(ho[2L] ?: 0, ho.values.sum())}% at 2), latency ${f(old.meanLatencyMs)} ms")
            assertTrue("phase $phase: locked", s.pacer.phaseLock)
            assertTrue("phase $phase: paths ${s.paths}", (s.paths[PaceProbe.PATH_LOCKED] ?: 0) >= 3500)
            assertTrue("phase $phase: holds $h", two * 100.0 / total >= 99.0)
            assertTrue("phase $phase: latency ${s.meanLatencyMs} vs ${old.meanLatencyMs}", s.meanLatencyMs <= old.meanLatencyMs + 2.0)
            assertFalse(old.pacer.phaseLock)
        }
    }

    @Test fun sixtyFpsOn60HzIsUnchanged() {
        // n = 1: every decision with the integer lock is the one without it (the T-060 lock).
        for (jitter in longArrayOf(1 * ms, 4 * ms, 8 * ms)) {
            val a = Sim(60, integerLock = true)
            val b = Sim(60, integerLock = false)
            val rnd = Lcg(77L)
            for (k in 0 until 1500) {
                val cap = 1_000_000_000L + k * p60
                val ready = cap + 25 * ms + ((rnd.next() * 2 - 1) * jitter).toLong()
                val da = a.frame(k, cap, ready); val pa = a.probe.path
                val db = b.frame(k, cap, ready)
                assertEquals("jitter $jitter frame $k", key(db), key(da))
                assertEquals(b.probe.path, pa)
            }
            assertTrue(a.pacer.phaseLock)
        }
    }

    @Test fun oneTwentyOn120HzIsUnchanged() {
        val p120 = 1_000_000_000L / 120
        val a = Sim(120, integerLock = true, streamNs = p120)
        val b = Sim(120, integerLock = false, streamNs = p120)
        val rnd = Lcg(5L)
        for (k in 0 until 2400) {
            val cap = 1_000_000_000L + k * p120 + if (k % 300 in 200..240) 80 * ms else 0 // with a sparse stretch
            val ready = cap + 18 * ms + (rnd.next() * 3 * ms).toLong()
            assertEquals("frame $k", key(b.frame(k, cap, ready)), key(a.frame(k, cap, ready)))
        }
    }

    @Test fun panelSwitch120To60To120RelocksWithAtMostOneIrregularIntervalPerSwitch() {
        for ((i, phase) in longArrayOf(1 * ms, 5 * ms, 11 * ms).withIndex()) {
            val r = switchRun(integerLock = true, phaseNs = phase, seed = 900L + i)
            val old = switchRun(integerLock = false, phaseNs = phase, seed = 900L + i)
            println("switch phase ${phase / ms} ms: new irregular per switch ${r.perSwitch} (steady ${r.steady}), " +
                "old ${old.perSwitch} (steady ${old.steady})")
            for ((j, n) in r.perSwitch.withIndex()) assertTrue("phase $phase switch $j: $n irregular", n <= 1)
            assertTrue("phase $phase steady irregular ${r.steady}", r.steady <= 3)
            assertTrue(r.locked)
        }
    }

    private class SwitchRun(val perSwitch: List<Int>, val steady: Int, val locked: Boolean)

    /**
     * 60 fps, +-3 ms jitter; 600 frames at 120 Hz, 600 at 60 Hz, 600 at 120 Hz. An interval between shown frames is
     * irregular when it is not one content interval (+-2 ms). Counted within 60 frames after each switch, and elsewhere.
     */
    private fun switchRun(integerLock: Boolean, phaseNs: Long, seed: Long): SwitchRun {
        val s = Sim(120, integerLock)
        val rnd = Lcg(seed)
        val start = 1_000_000_000L
        val base = 22 * ms
        val switchAt = listOf(600, 1200)
        val switchNs = ArrayList<Long>()
        for (k in 0 until 1800) {
            val cap = start + k * p60
            val ready = cap + base + ((rnd.next() * 2 - 1) * 3 * ms).toLong()
            if (k in switchAt) {
                val at = ready - 5 * ms
                s.switchPanel(if (k == 600) 60 else 120, at, phaseNs.coerceAtMost(s.period))
                switchNs.add(at)
            }
            s.frame(k, cap, ready)
        }
        s.finish(start + 1800 * p60 + 100 * ms)
        val per = IntArray(switchNs.size)
        var steady = 0
        for (i in 1 until s.shown.size) {
            val dt = s.shown[i] - s.shown[i - 1]
            if (Math.abs(dt - p60) <= 2 * ms) continue
            val w = switchNs.indexOfFirst { s.shown[i] >= it && s.shown[i] < it + 60 * p60 }
            if (w >= 0) per[w]++ else steady++
        }
        return SwitchRun(per.toList(), steady, s.pacer.phaseLock)
    }

    @Test fun singleMissedCaptureAt120HzIsNoLoneFrame() {
        // A dropped host capture (33 ms gap) is 4 periods at 120 Hz: still the stream, not a lone frame (T-208 gap rule).
        val s = Sim(120)
        val rnd = Lcg(3L)
        var cap = 1_000_000_000L
        for (k in 0 until 400) {
            cap += if (k == 300) 2 * p60 else p60
            s.frame(k, cap, cap + 21 * ms + (rnd.next() * 2 * ms).toLong())
            if (k == 300) assertEquals(PaceProbe.PATH_LOCKED, s.probe.path)
        }
        assertEquals(0, s.paths[PaceProbe.PATH_EARLY_SPARSE] ?: 0)
    }

    // --- trace replay: trace7 (120 Hz drawing) thinned to every second capture = 60 fps content with real jitter --------

    private class Row(val captureUs: Long, val readyNs: Long, val vsyncNs: Long, val periodNs: Long, val deadlineNs: Long)

    private fun trace60(): List<Row> {
        val f = listOf("../../tools/pacing/trace7_120hz_excerpt.csv", "tools/pacing/trace7_120hz_excerpt.csv")
            .map(::File).first { it.exists() }
        val lines = f.readLines()
        val h = lines[0].split(',')
        fun col(n: String) = h.indexOf(n).also { require(it >= 0) { n } }
        val cCap = col("capture_us"); val cRdy = col("ready_ns"); val cVs = col("now_vsync_last_ns"); val cP = col("period_ns")
        val cDl = col("deadline_ns")
        val all = lines.drop(1).filter { it.isNotBlank() }.map { it.split(',') }.filter { it[cP].startsWith("833") }
            .map { Row(it[cCap].toLong(), it[cRdy].toLong(), it[cVs].toLong(), it[cP].toLong(), it[cDl].toLong()) }
        // Keep a capture when it is at least two periods (minus 1 ms) after the last kept one.
        val out = ArrayList<Row>()
        for (r in all) if (out.isEmpty() || (r.captureUs - out.last().captureUs) * 1000 >= 2 * r.periodNs - 1_000_000L) out.add(r)
        return out
    }

    private class Replay(val cont: Int, val two: Int, val one: Int, val three: Int, val drops: Int, val latMeanMs: Double) {
        override fun toString() = "continuous $cont: hold 2 = $two (${pct(two, cont)}%), 1 = $one, >=3 = $three, dropped $drops, " +
            "ready->slot mean ${f(latMeanMs)} ms"
    }

    /** Continuous = capture gap two periods (+-1 ms); hold = slot distance to the previous shown frame, in periods. */
    private fun replay(rows: List<Row>, integerLock: Boolean): Replay {
        val p = AdaptivePacer(VsyncClock(120f), p60).also {
            it.integerLock = integerLock
            it.intervalProvider = { period -> FrameInterval.resolve(p60, period, p60) }
        }
        var prev = Long.MIN_VALUE
        var cont = 0; var two = 0; var one = 0; var three = 0; var drops = 0
        var lat = 0.0; var latN = 0
        for ((i, r) in rows.withIndex()) {
            val gapNs = if (i == 0) Long.MAX_VALUE else (r.captureUs - rows[i - 1].captureUs) * 1000
            val continuous = Math.abs(gapNs - 2 * r.periodNs) < 1_000_000L
            val d = p.scheduleOn(VsyncClock.Grid(r.vsyncNs, r.periodNs, 0, r.deadlineNs), r.captureUs, r.readyNs)
            if (continuous) {
                cont++
                if (d.collided) drops++
                else if (prev != Long.MIN_VALUE) {
                    when (Math.round((d.slotNs - prev).toDouble() / r.periodNs)) { 2L -> two++; 1L, 0L -> one++; else -> three++ }
                }
            }
            if (!d.collided) { prev = d.slotNs; lat += (d.slotNs - r.readyNs) / 1e6; latN++ }
        }
        return Replay(cont, two, one, three, drops, lat / latN)
    }

    @Test fun traceReplayThinnedTo60FpsOldVersusNew() {
        val rows = trace60()
        val old = replay(rows, integerLock = false)
        val new = replay(rows, integerLock = true)
        println("trace7/2 old (no lock at 2 periods): $old")
        println("trace7/2 new (T-208):                $new")
        assertTrue("rows ${rows.size}", new.cont > 800)
        assertTrue("latency ${new.latMeanMs} vs ${old.latMeanMs}", new.latMeanMs <= old.latMeanMs + 2.0)
        assertTrue("hold 2: new ${new.two} old ${old.two}", new.two >= old.two)
        // A stress excerpt (decode under 120 fps load, jitter p99 above 1.5 periods): irregular holds at most half of before.
        assertTrue("irregular: $new vs $old", (new.one + new.three + new.drops) * 2 <= old.one + old.three + old.drops)
    }

    private companion object {
        fun key(d: FramePacer.Decision) =
            "${d.renderNs} ${d.collided} ${d.addedNs} ${d.skipped} ${d.slotNs} ${d.lateDrop} ${d.ownSlotNs}"
        fun pct(a: Int, b: Int) = f(a * 100.0 / b.coerceAtLeast(1))
        fun f(v: Double) = String.format(java.util.Locale.ROOT, "%.2f", v)
    }
}
