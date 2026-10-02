package dev.matebridge.client.video

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * T-115: a lone frame on the phase-lock path (first frame, or a capture gap above LOCK_GAP_PERIODS periods) goes to the
 * earliest slot without hold, its delay stays out of the jitter history, and the lock forms on the next continuous frame.
 * Old/new comparisons use the A/B switch [AdaptivePacer.sparseEarly].
 */
class SparseFrameNoHoldTest {
    private val ms = 1_000_000L

    private class Lcg(var seed: Long) {
        fun next(): Double { seed = seed * 6364136223846793005L + 1442695040888963407L; return ((seed ushr 33) % 10_000) / 10_000.0 }
    }

    /** Pacer + SlotReleaser on a live vsync grid (6 ms deadline), like the decoder output thread. */
    private class Sim(panelHz: Int, sparseEarly: Boolean = true) {
        val clk = VsyncClock(panelHz.toFloat()).also { it.onVsync(0); it.setDisplayTiming(0, 13_330_000L) }
        val period = clk.grid().periodNs
        val pacer = AdaptivePacer(clk, period).also { it.sparseEarly = sparseEarly }
        val probe = PaceProbe().also { pacer.probe = it }
        val released = HashMap<Int, Long>()
        val discarded = ArrayList<Int>()
        val rel = SlotReleaser(object : SlotReleaser.Sink {
            override fun release(idx: Int, renderNs: Long) { released[idx] = renderNs }
            override fun discard(idx: Int) { discarded.add(idx) }
        }, PresentCounters())
        private var vsyncNs = 0L

        fun advanceTo(t: Long) {
            while (vsyncNs + period <= t) { vsyncNs += period; clk.onVsync(vsyncNs) }
            rel.flushDue(t)
        }

        fun frame(k: Int, captureNs: Long, readyNs: Long): FramePacer.Decision {
            advanceTo(readyNs)
            probe.clear()
            val d = pacer.schedule(captureNs / 1000, readyNs)!!
            rel.submit(k, d.slotNs, d.renderNs, d.slotNs - (clk.grid().deadlineNs + 1_000_000L), readyNs, period)
            return d
        }

        /** Base delay that puts the jitter-free ready time [phaseNs] before a vsync once the 6 ms deadline is added. */
        fun baseBefore(captureNs: Long, phaseNs: Long, minNs: Long = 15_000_000L): Long =
            minNs + Math.floorMod(-phaseNs - (captureNs + minNs + clk.grid().deadlineNs), period)
    }

    // --- (a) lone frames get no hold -----------------------------------------------------------------------------

    /** Lone frames 100 ms apart, cold decoder (base delay plus 0..[coldNs]); returns the mean pace_add. */
    private fun sparse(s: Sim, phaseNs: Long, coldNs: Long, seed: Long, n: Int = 120, check: Boolean = false): Long {
        val rnd = Lcg(seed)
        var cap = 1_000_000_000L
        val base = s.baseBefore(cap, phaseNs)
        var added = 0L
        for (k in 0 until n) {
            val d = s.frame(k, cap, cap + base + (rnd.next() * coldNs).toLong())
            added += d.addedNs
            if (check) {
                val label = "${s.period} phase=$phaseNs k=$k"
                assertEquals("$label pace_add", 0L, d.addedNs)
                assertEquals("$label on the earliest slot", s.probe.earliestNs, d.slotNs)
                assertFalse(d.collided); assertFalse(d.lateDrop); assertFalse(d.skipped)
                assertEquals("$label path", if (k == 0) PaceProbe.PATH_EARLY_FIRST else PaceProbe.PATH_EARLY_SPARSE, s.probe.path)
                assertTrue("$label probe shows the slot the hold would have chosen", s.probe.acquireNs >= d.slotNs)
                assertFalse(s.pacer.phaseLock)
            }
            cap += 100 * ms
        }
        s.advanceTo(cap + 100 * ms)
        if (check) assertEquals("every frame released", n, s.released.size)
        return added / n
    }

    @Test fun sparseFramesAt100msHaveNoAddedDelayAt60And120Hz() {
        for (hz in listOf(60, 120)) for (phase in 0 until 8) {
            val s = Sim(hz)
            sparse(s, s.period * phase / 8, 20 * ms, 5L + phase, check = true)
        }
    }

    @Test fun withTheSwitchOffSparseFramesAreHeldLikeBefore() {
        // A/B reference: the pre-T-115 acquisition holds these frames by up to a vsync (the reason for this task).
        for (hz in listOf(60, 120)) {
            var sum = 0L; var period = 0L
            for (phase in 0 until 8) {
                val s = Sim(hz, sparseEarly = false)
                period = s.period
                sum += sparse(s, s.period * phase / 8, 20 * ms, 5L + phase)
            }
            println("hz=$hz old mean pace_add ${sum / 8 / 1000} us (new: 0)")
            assertTrue("hz=$hz old mean pace_add ${sum / 8}", sum / 8 > period / 3)
        }
    }

    @Test fun loneFrameDelaysStayOutOfTheJitterHistory() {
        for (hz in listOf(60, 120)) {
            val dNs = HashMap<Boolean, Long>()
            for (early in listOf(true, false)) {
                val s = Sim(hz, early)
                val rnd = Lcg(9L)
                var cap = 1_000_000_000L
                var k = 0
                // Idle desktop: lone frames, cold (0..12 ms extra delay), 150 ms apart.
                repeat(300) { s.frame(k++, cap, cap + 15 * ms + (rnd.next() * 12 * ms).toLong()); cap += 150 * ms }
                // Then continuous motion at the panel rate with 0..2 ms of jitter.
                repeat(60) { s.frame(k++, cap, cap + 15 * ms + (rnd.next() * 2 * ms).toLong()); cap += s.period }
                dNs[early] = s.pacer.lastDNs
            }
            println("hz=$hz D half a second into the motion: new ${dNs[true]!! / 1000} us, old ${dNs[false]!! / 1000} us")
            assertTrue("hz=$hz D ${dNs[true]}", dNs[true]!! <= 3 * ms) // the motion's own jitter (2 ms) + margin
            assertTrue("hz=$hz old D ${dNs[false]} (reference)", dNs[false]!! >= dNs[true]!! + 3 * ms)
        }
    }

    // --- (b) lone -> continuous ----------------------------------------------------------------------------------

    @Test fun lockFormsOnTheSecondContinuousFrameWithoutDropOrDoubleSlot() {
        // Jitter-free stream after a lone frame, every phase: frame 2 acquires, frame 3 is locked, slots one period
        // apart after the transition, nothing dropped, at most one repeated vsync between the lone frame and frame 2.
        for (hz in listOf(60, 120)) for (phase in 0 until 16) {
            val s = Sim(hz)
            val label = "hz=$hz phase=$phase"
            var cap = 1_000_000_000L
            val base = s.baseBefore(cap, s.period * phase / 16)
            s.frame(0, cap, cap + base) // first frame of the session
            cap += 300 * ms
            val lone = s.frame(1, cap, cap + base)
            assertEquals(label, PaceProbe.PATH_EARLY_SPARSE, s.probe.path)
            assertEquals(label, 0L, lone.addedNs)
            assertFalse(s.pacer.phaseLock)
            var prev = lone.slotNs
            for (k in 2 until 120) {
                cap += s.period
                val d = s.frame(k, cap, cap + base)
                if (k == 2) { assertEquals(label, PaceProbe.PATH_ACQUIRE, s.probe.path); assertTrue(label, s.pacer.phaseLock) }
                if (k == 3) assertEquals(label, PaceProbe.PATH_LOCKED, s.probe.path)
                assertFalse("$label k=$k collided", d.collided)
                assertFalse("$label k=$k late", d.lateDrop)
                val step = d.slotNs - prev
                if (k == 2) assertTrue("$label transition step $step", step == s.period || step == 2 * s.period)
                else assertEquals("$label k=$k step", s.period, step)
                prev = d.slotNs
            }
            assertEquals(0L, s.pacer.rephases)
            s.advanceTo(cap + 100 * ms)
            assertTrue("$label discarded ${s.discarded}", s.discarded.isEmpty())
            assertEquals(label, 120, s.released.size)
        }
    }

    /** [loneReplaced]: the frame after a lone one took the lone frame's slot (collided right after it). */
    private class Counts(var collided: Int = 0, var lateDrop: Int = 0, var gaps: Int = 0, var doubleSlots: Int = 0, var loneReplaced: Int = 0)

    /**
     * [cycles] cycles of 8 lone frames followed by 120 continuous frames at the panel rate (0..2 ms jitter).
     * [coldFirstNs]: extra delay of the first frame of each motion (cold decoder).
     */
    private fun cycles(hz: Int, offsetNs: Long, seed: Long, early: Boolean, coldFirstNs: Long = 0, cycles: Int = 6): Counts {
        val s = Sim(hz, early)
        val rnd = Lcg(seed)
        val t = Counts()
        var cap = 1_000_000_000L
        var k = 0
        var prevSlot = Long.MIN_VALUE
        val slotsSeen = HashSet<Long>()
        var afterLone = false
        fun feed(capNs: Long, readyNs: Long, continuous: Boolean) {
            val d = s.frame(k++, capNs, readyNs)
            if (d.collided) { t.collided++; if (afterLone && continuous) t.loneReplaced++ }
            afterLone = !continuous
            if (d.lateDrop) t.lateDrop++
            if (!d.collided) {
                if (!slotsSeen.add(d.slotNs)) t.doubleSlots++
                if (continuous && prevSlot != Long.MIN_VALUE && d.slotNs - prevSlot > s.period * 3 / 2) t.gaps++
                prevSlot = d.slotNs
            }
        }
        repeat(cycles) {
            repeat(8) {
                cap += (120 + (rnd.next() * 400).toLong()) * ms
                feed(cap, cap + 15 * ms + offsetNs + (rnd.next() * 8 * ms).toLong(), false)
            }
            cap += 200 * ms
            feed(cap, cap + 15 * ms + offsetNs + coldFirstNs + (rnd.next() * 2 * ms).toLong(), false) // first of the motion
            repeat(120) {
                cap += s.period
                feed(cap, cap + 15 * ms + offsetNs + (rnd.next() * 2 * ms).toLong(), true)
            }
        }
        s.advanceTo(cap + 200 * ms)
        assertTrue("newest frame released", s.released.containsKey(k - 1))
        return t
    }

    private fun sweep(hz: Int, early: Boolean, coldFirstNs: Long): Counts {
        val sum = Counts()
        val p = 1_000_000_000L / hz
        for (i in 0 until 12) for (seed in 1L..10L) {
            val t = cycles(hz, p * i / 12, seed, early, coldFirstNs)
            sum.collided += t.collided; sum.lateDrop += t.lateDrop; sum.gaps += t.gaps; sum.doubleSlots += t.doubleSlots
            sum.loneReplaced += t.loneReplaced
        }
        return sum
    }

    private val motions = 12 * 10 * 6

    @Test fun sparseToContinuousWithJitterDropsNoMoreThanBefore() {
        for (hz in listOf(60, 120)) {
            val new = sweep(hz, true, 0)
            val old = sweep(hz, false, 0)
            println("hz=$hz $motions motions, collided/lateDrop/gaps: new ${new.collided}/${new.lateDrop}/${new.gaps}, old ${old.collided}/${old.lateDrop}/${old.gaps}")
            assertEquals("hz=$hz double slots", 0, new.doubleSlots)
            assertTrue("hz=$hz lone frames replaced ${new.loneReplaced}", new.loneReplaced * 100 <= motions)
            assertTrue("hz=$hz collided ${new.collided} vs old ${old.collided}", new.collided <= old.collided)
            assertTrue("hz=$hz late drops ${new.lateDrop} vs old ${old.lateDrop}", new.lateDrop <= old.lateDrop)
            assertTrue("hz=$hz collided ${new.collided} in $motions motions", new.collided * 25 <= motions) // <= 4 %
            assertTrue("hz=$hz gaps ${new.gaps}: at most the transition's repeated vsync", new.gaps <= motions)
        }
    }

    @Test fun coldFirstFrameOfAMotionCausesNoLateDropsOfLaterFrames() {
        // First frame of each motion 3 or 6 ms later than the rest. With the tighter hold (no lone-frame delays in the
        // history) that lone frame can sit on the slot the lock wants for the second frame: the second frame then
        // replaces it at the same vsync (newest wins, nothing shown later) and the lock stays centred. Later frames
        // of the motion are not dropped more often than before T-115.
        for (hz in listOf(60, 120)) for (cold in listOf(3 * ms, 6 * ms)) {
            val new = sweep(hz, true, cold)
            val old = sweep(hz, false, cold)
            println("hz=$hz cold first frame +${cold / ms} ms, $motions motions, replaced lone/collided/lateDrop/gaps: " +
                "new ${new.loneReplaced}/${new.collided}/${new.lateDrop}/${new.gaps}, old ${old.loneReplaced}/${old.collided}/${old.lateDrop}/${old.gaps}")
            assertTrue("hz=$hz late drops ${new.lateDrop}", new.lateDrop * 100 <= motions)
            assertTrue("hz=$hz lone frames replaced ${new.loneReplaced}", new.loneReplaced <= motions)
            val laterNew = new.collided - new.loneReplaced
            val laterOld = old.collided - old.loneReplaced
            assertTrue("hz=$hz later frames replaced $laterNew vs old $laterOld", laterNew <= laterOld)
        }
    }

    // --- warm-up: a lock on a thin history ---------------------------------------------------------------------

    @Test fun thinHistoryMissReacquiresInsteadOfDropping() {
        // Fresh session at 120 Hz; the lock forms on calm frames whose ready time is 1 ms before a vsync (+6 ms deadline),
        // then a frame comes 6 ms late: it re-acquires the lock (one repeated vsync) instead of being dropped.
        val s = Sim(120)
        var cap = 1_000_000_000L
        val base = s.baseBefore(cap, 1 * ms)
        for (k in 0 until 4) { s.frame(k, cap, cap + base); cap += s.period }
        assertEquals(PaceProbe.PATH_LOCKED, s.probe.path)
        val d = s.frame(4, cap, cap + base + 6 * ms)
        assertEquals(PaceProbe.PATH_WARMUP, s.probe.path)
        assertFalse(d.lateDrop); assertFalse(d.collided); assertTrue(d.skipped)
        cap += s.period
        val next = s.frame(5, cap, cap + base + 6 * ms)
        assertEquals(PaceProbe.PATH_LOCKED, s.probe.path)
        assertEquals(s.period, next.slotNs - d.slotNs)
        s.advanceTo(cap + 100 * ms)
        assertTrue(s.discarded.isEmpty())
    }

    @Test fun withAFullHistoryTheSameMissIsALateDrop() {
        // Reference: once the history holds WARMUP_SAMPLES frames the steady-state rule (unchanged) drops such a frame.
        val s = Sim(120)
        var cap = 1_000_000_000L
        val base = s.baseBefore(cap, 1 * ms)
        for (k in 0 until AdaptivePacer.WARMUP_SAMPLES + 4) { s.frame(k, cap, cap + base); cap += s.period }
        assertTrue(s.frame(99, cap, cap + base + 6 * ms).lateDrop)
    }

    // --- trace replay (tools/pacing/trace7_120hz_excerpt.csv) ---------------------------------------------------

    private class Row(val captureUs: Long, val readyNs: Long, val vsyncNs: Long, val periodNs: Long, val deadlineNs: Long)

    private fun trace(): List<Row> {
        val f = listOf("../../tools/pacing/trace7_120hz_excerpt.csv", "tools/pacing/trace7_120hz_excerpt.csv")
            .map(::File).first { it.exists() }
        val lines = f.readLines()
        val h = lines[0].split(',')
        fun col(n: String) = h.indexOf(n).also { require(it >= 0) { n } }
        val cCap = col("capture_us"); val cRdy = col("ready_ns"); val cVs = col("now_vsync_last_ns"); val cP = col("period_ns")
        val cDl = col("deadline_ns")
        return lines.drop(1).filter { it.isNotBlank() }.map { it.split(',') }.filter { it[cP].startsWith("833") }
            .map { Row(it[cCap].toLong(), it[cRdy].toLong(), it[cVs].toLong(), it[cP].toLong(), it[cDl].toLong()) }
    }

    private class Replay(
        val lone: Int, val loneLatP50Ms: Double, val loneLatMeanMs: Double, val loneAddMeanMs: Double,
        val cont: Int, val contGaps: Int, val contDrops: Int, val contLatP50Ms: Double,
    ) {
        override fun toString() = "lone $lone: latency p50 ${f(loneLatP50Ms)} mean ${f(loneLatMeanMs)} ms, pace_add mean ${f(loneAddMeanMs)} ms | " +
            "continuous $cont: gaps $contGaps (${f(100.0 * contGaps / cont)}%), dropped $contDrops (${f(100.0 * contDrops / cont)}%), " +
            "latency p50 ${f(contLatP50Ms)} ms"
        private fun f(v: Double) = String.format(java.util.Locale.ROOT, "%.2f", v)
    }

    private fun p50(v: MutableList<Double>): Double { v.sort(); return v[v.size / 2] }

    /** Lone = first row or capture gap above 3 periods; continuous = capture gap one period (+-1 ms), as in sim.py. */
    private fun replay(rows: List<Row>, sparseEarly: Boolean): Replay {
        val p = AdaptivePacer(VsyncClock(120f), rows[0].periodNs).also { it.sparseEarly = sparseEarly }
        var prev = Long.MIN_VALUE
        val loneLat = ArrayList<Double>(); var loneAdd = 0.0
        val contLat = ArrayList<Double>(); var gaps = 0; var drops = 0; var cont = 0
        for ((i, r) in rows.withIndex()) {
            val gapNs = if (i == 0) Long.MAX_VALUE else (r.captureUs - rows[i - 1].captureUs) * 1000
            val lone = gapNs > AdaptivePacer.LOCK_GAP_PERIODS * r.periodNs
            val continuous = Math.abs(gapNs - r.periodNs) < 1_000_000L
            val d = p.scheduleOn(VsyncClock.Grid(r.vsyncNs, r.periodNs, 0, r.deadlineNs), r.captureUs, r.readyNs)
            if (lone) { loneLat.add((d.slotNs - r.readyNs) / 1e6); loneAdd += d.addedNs / 1e6 }
            if (continuous) {
                cont++
                if (d.collided) drops++
                else {
                    if (prev != Long.MIN_VALUE && d.slotNs - prev > r.periodNs * 3 / 2) gaps++
                    contLat.add((d.slotNs - r.readyNs) / 1e6)
                }
            }
            if (!d.collided) prev = d.slotNs
        }
        return Replay(loneLat.size, p50(loneLat), loneLat.average(), loneAdd / loneLat.size, cont, gaps, drops, p50(contLat))
    }

    @Test fun traceReplayOldVersusNew() {
        val rows = trace()
        val old = replay(rows, sparseEarly = false)
        val new = replay(rows, sparseEarly = true)
        println("trace7 old (hold on lone frames): $old")
        println("trace7 new (T-115):               $new")
        assertEquals(old.lone, new.lone)
        assertEquals(0.0, new.loneAddMeanMs, 1e-9)
        assertTrue("lone latency", new.loneLatMeanMs < old.loneLatMeanMs && new.loneLatP50Ms <= old.loneLatP50Ms)
        // The continuous part keeps its smoothness: gaps and drops no worse than half a percent of continuous frames.
        assertTrue("gaps ${new.contGaps} vs ${old.contGaps}", new.contGaps - old.contGaps <= new.cont / 200)
        assertTrue("drops ${new.contDrops} vs ${old.contDrops}", new.contDrops <= old.contDrops + new.cont / 200)
        assertTrue("continuous latency", new.contLatP50Ms <= old.contLatP50Ms + 0.5)
    }
}
