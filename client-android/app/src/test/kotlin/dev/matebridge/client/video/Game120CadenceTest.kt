package dev.matebridge.client.video

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * T-220: the content cadence is inferred from the measured captures, so a 60 fps game in Game 120 (a 120 fps stream) on
 * a 120 Hz panel gets the 2:1 lock of T-208; before, the stream interval made it one period. 120 fps content and the
 * 60 Hz panel resolve as before. Deterministic, no sleeps.
 */
class Game120CadenceTest {
    private val ms = 1_000_000L
    private val p60 = 1_000_000_000L / 60
    private val p120 = 1_000_000_000L / 120

    private fun feed(t: ArrivalTracker, startUs: Long, gapsUs: LongArray): Long {
        var us = startUs
        for (g in gapsUs) { us += g; t.onFrame(us) }
        return us
    }

    @Test fun trackerFindsTheStableCadenceWithHysteresis() {
        val t = ArrivalTracker()
        var us = feed(t, 0, LongArray(16) { 16_667 })
        assertEquals("16 gaps: not yet a full window", 0L, t.cadenceNs)
        us = feed(t, us, LongArray(1) { 16_667 })
        assertEquals(16_667_000.0, t.cadenceNs.toDouble(), 1_000.0)
        // A missed host frame now and then (33 ms) or a 40 ms one: kept.
        for (i in 0 until 10) us = feed(t, us, longArrayOf(16_667, 16_667, 33_333, 16_667, 16_666, 16_667, 25_000, 16_667))
        assertEquals(16_667_000.0, t.cadenceNs.toDouble(), 1_000.0)
        // The content goes to 120 fps: gone within ten frames, the new cadence within one window.
        var k = 0
        while (t.cadenceNs in 15_000_000L..18_000_000L && k < 100) { us = feed(t, us, longArrayOf(8_333)); k++ }
        assertTrue("left after $k frames", k <= 10)
        var k2 = 0
        while (t.cadenceNs == 0L && k2 < 100) { us = feed(t, us, longArrayOf(8_333)); k2++ }
        assertTrue("entered $k2 frames later", k + k2 <= 16)
        assertEquals(8_333_000.0, t.cadenceNs.toDouble(), 1_000.0)
        // A mix with no majority interval (90 fps-like 1-1-2 periods, then 1-3): none.
        val m = ArrivalTracker()
        feed(m, 0, LongArray(64) { if (it % 3 == 2) 16_667 else 8_333 })
        assertEquals(0L, m.cadenceNs)
        feed(m, 10_000_000, LongArray(64) { if (it % 2 == 0) 8_333 else 25_000 })
        assertEquals(0L, m.cadenceNs)
        m.reset()
        assertEquals(0L, m.cadenceNs)
    }

    @Test fun resolveGivesTwoPeriodsOnlyForSteadyHalfRateContentOnAFastPanel() {
        val s120 = p120
        val c60 = 16_667_000L
        assertEquals("Game 120, 120 Hz, 60 fps content", 2 * p120, FrameInterval.resolve(s120, p120, c60, c60))
        assertEquals("120 fps content: unchanged", s120, FrameInterval.resolve(s120, p120, p120, p120))
        assertEquals("no stable cadence: unchanged", s120, FrameInterval.resolve(s120, p120, c60, 0))
        assertEquals("Game 60 stream: already two periods", p60, FrameInterval.resolve(p60, p120, c60, c60))
        assertEquals("60 Hz panel, 30 fps content: unchanged (T-208 kept it)", p60, FrameInterval.resolve(s120, p60, 33_333_000L, 33_333_000L))
        assertEquals("60 Hz panel, thinned 60 fps: unchanged", p60, FrameInterval.resolve(s120, p60, c60, c60))
        assertEquals("144 Hz panel, 60 fps: no integer cadence", s120, FrameInterval.resolve(s120, 1_000_000_000L / 144, c60, c60))
        assertEquals("unknown arrivals", s120, FrameInterval.resolve(s120, p120, 0, c60))
    }

    /**
     * [frames] captures [intervalNs] apart, ready 22 ms later plus jitter: uniform in +-[jitterNs], or [bimodal]: -[jitterNs]
     * or +[jitterNs] (plus 0..1 ms), like the device's 12.5 / 20.8 ms buckets (NOTES 2026-10-04, T-208).
     */
    private fun stream(
        rig: PresentRig, frames: Int, intervalNs: Long, jitterNs: Long, seed: Long, startNs: Long = 1_000_000_000L,
        bimodal: Boolean = false, missEvery: Int = 0,
    ): Long {
        val rnd = Lcg(seed)
        var cap = startNs
        for (k in 0 until frames) {
            cap += if (k == 0) 0 else if (missEvery > 0 && k % missEvery == 0) 2 * intervalNs else intervalNs
            val j = if (bimodal) (if (rnd.next() < 0.5) -jitterNs else jitterNs) + (rnd.next() * ms).toLong()
            else ((rnd.next() * 2 - 1) * jitterNs).toLong()
            rig.frame(k, cap, cap + 22 * ms + j)
        }
        return cap + intervalNs
    }

    /** Shown intervals from [from] on, by hold minus the capture distance (both in vsyncs): 0 = held exactly its content. */
    private fun holdErrors(rig: PresentRig, from: Int): Map<Long, Int> {
        val shown = rig.shown()
        val h = HashMap<Long, Int>()
        for (i in maxOf(from, 1) until shown.size) {
            val hold = Math.round((shown[i][1] - shown[i - 1][1]).toDouble() / p120)
            val content = Math.round((shown[i][0] - shown[i - 1][0]) * 1000.0 / p120)
            h.merge(hold - content, 1, Int::plus)
        }
        return h
    }

    @Test fun game120With60FpsContentOn120HzLocksTwoToOne() {
        // Device-like content (NOTES 2026-10-04, Ori): two-bucket arrivals and a capture the game did not produce now and
        // then (a 33 ms gap). At one period (the 120 fps stream's interval) that gap is above the lone-frame limit of
        // three periods, so the frame after it goes to the earliest slot and the lock re-forms: uneven holds every time.
        // At two periods (inferred) it stays on the 2:1 lock (T-208 gap rule) and every frame holds its content time.
        var worstOld = 100.0
        for ((i, phase) in LongArray(9) { it * ms }.withIndex()) {
            val rig = PresentRig(120, p120, adaptive = true)
            val old = PresentRig(120, p120, adaptive = true, inferCadence = false)
            val end = stream(rig, 3600, p60, 4 * ms, 41L + i, 1_000_000_000L + phase, bimodal = true, missEvery = 97)
            stream(old, 3600, p60, 4 * ms, 41L + i, 1_000_000_000L + phase, bimodal = true, missEvery = 97)
            rig.finish(end + 100 * ms); old.finish(end + 100 * ms)
            val h = holdErrors(rig, 40); val ho = holdErrors(old, 40)
            val exact = (h[0L] ?: 0) * 100.0 / h.values.sum()
            val exactOld = (ho[0L] ?: 0) * 100.0 / ho.values.sum()
            val s = rig.stats.snapshot(reset = true); val so = old.stats.snapshot(reset = true)
            println("Game120 60 fps phase ${phase / ms} ms: new hold-content $h (${f(exact)}% exact) skip_pct ${f(s.skipPct!!)} " +
                "short ${s.holdShort}/${s.holdJudged} | before T-220 $ho (${f(exactOld)}% exact) skip_pct ${f(so.skipPct!!)} " +
                "short ${so.holdShort}/${so.holdJudged}, paths ${old.paths}")
            assertEquals(2 * p120, FrameInterval.resolve(p120, p120, rig.tracker.intervalNs, rig.tracker.cadenceNs))
            assertTrue(rig.pacer.phaseLock)
            assertTrue("paths ${rig.paths}", (rig.paths[PaceProbe.PATH_LOCKED] ?: 0) >= 3500)
            assertTrue("phase $phase holds $h", exact >= 99.0)
            assertTrue("skip_pct ${s.skipPct}", s.skipPct!! <= 1.0)
            assertTrue("short ${s.holdShort} of ${s.holdJudged}", s.holdShort * 100 <= s.holdJudged)
            worstOld = minOf(worstOld, exactOld)
        }
        assertTrue("without the inferred cadence the symptom shows: $worstOld", worstOld < 99.0)
    }

    @Test fun game120With120FpsContentIsUnchanged() {
        // 120 fps content: the inferred cadence is one period, so every decision is the one without inference.
        val a = PresentRig(120, p120, adaptive = true)
        val b = PresentRig(120, p120, adaptive = true, inferCadence = false)
        val rnd = Lcg(9L)
        for (k in 0 until 2400) {
            val cap = 1_000_000_000L + k * p120 + if (k % 300 in 200..240) 80 * ms else 0 // with a sparse stretch
            val ready = cap + 18 * ms + (rnd.next() * 3 * ms).toLong()
            assertEquals("frame $k", key(b.frame(k, cap, ready)!!), key(a.frame(k, cap, ready)!!))
        }
        assertEquals(p120.toDouble(), a.tracker.cadenceNs.toDouble(), 1_000.0)
        assertTrue(a.pacer.phaseLock)
    }

    @Test fun sixtyHzPanelIsUnchanged() {
        // Game 120 on a 60 Hz panel (host thins to 60): 60 fps arrivals, and 30 fps content. Same decisions as before.
        for (interval in longArrayOf(p60, 2 * p60)) {
            val a = PresentRig(60, p120, adaptive = true)
            val b = PresentRig(60, p120, adaptive = true, inferCadence = false)
            val rnd = Lcg(13L)
            for (k in 0 until 1200) {
                val cap = 1_000_000_000L + k * interval
                val ready = cap + 25 * ms + ((rnd.next() * 2 - 1) * 4 * ms).toLong()
                assertEquals("interval $interval frame $k", key(b.frame(k, cap, ready)!!), key(a.frame(k, cap, ready)!!))
            }
        }
    }

    private class RateRun(val perSwitch: List<Int>, val steady: Int, val drops: Int, val longestDropRun: Int, val locked: Boolean) {
        override fun toString() = "irregular per switch $perSwitch, steady $steady, late drops $drops (longest run $longestDropRun)"
    }

    /**
     * Game 120 on 120 Hz: content 60 -> 120 -> 60 fps (1200 frames each). The 60 fps parts have the device's two-bucket
     * jitter, the 120 fps part +-2 ms. A shown interval is irregular when its hold is not the capture distance in vsyncs;
     * counted within 2 s after each switch (the stream start too), and elsewhere.
     */
    private fun rateRun(infer: Boolean, phaseNs: Long, seed: Long): RateRun {
        val rig = PresentRig(120, p120, adaptive = true, inferCadence = infer)
        val rnd = Lcg(seed)
        val caps = LongArray(3600)
        var cap = 1_000_000_000L + phaseNs
        val switches = listOf(0, 1201, 2401) // the start too: the cadence is inferred after a window of frames
        for (k in 0 until 3600) {
            val fast = k in 1201..2400
            cap += if (k == 0) 0 else if (fast) p120 else p60
            caps[k] = cap
            val j = if (fast) ((rnd.next() * 2 - 1) * 2 * ms).toLong()
            else (if (rnd.next() < 0.5) -4 * ms else 4 * ms) + (rnd.next() * ms).toLong()
            rig.frame(k, cap, cap + 22 * ms + j)
        }
        rig.finish(cap + 100 * ms)
        var longestRun = 0; var run = 0; var drops = 0
        for (d in rig.decisions) { if (d.lateDrop) { run++; drops++; longestRun = maxOf(longestRun, run) } else run = 0 }
        val per = IntArray(switches.size)
        val shown = rig.shown()
        var steady = 0
        for (j in 1 until shown.size) {
            val gapNs = (shown[j][0] - shown[j - 1][0]) * 1000
            val hold = Math.round((shown[j][1] - shown[j - 1][1]).toDouble() / p120)
            if (hold == Math.round(gapNs.toDouble() / p120)) continue
            val w = switches.indexOfFirst { shown[j][0] * 1000 >= caps[it] && shown[j][0] * 1000 < caps[it] + 120 * p60 }
            if (w >= 0) per[w]++ else steady++
        }
        return RateRun(per.toList(), steady, drops, longestRun, rig.pacer.phaseLock)
    }

    @Test fun contentRateChangeOnOneGridIsNoWorseThanBefore() {
        // n changes 2 -> 1 -> 2 on one grid (and 1 -> 2 once the first window of the stream is in): the lock and D start
        // over (recadence). Before T-220 n stayed 1. A lock acquired while D still grows is re-phased REPHASE_FRAMES later
        // (one uneven pair of holds, as at any n = 2 stream start); otherwise no worse than before. A jitter rise under an
        // established lock (120 fps +-2 ms -> 60 fps two-bucket) costs up to REPHASE_FRAMES uneven holds in both.
        for ((i, phase) in LongArray(9) { it * ms }.withIndex()) {
            val r = rateRun(infer = true, phaseNs = phase, seed = 300L + i)
            val old = rateRun(infer = false, phaseNs = phase, seed = 300L + i)
            println("content 60->120->60 phase ${phase / ms} ms: new $r | before T-220 $old")
            assertTrue(r.locked)
            for (j in r.perSwitch.indices) assertTrue("phase $phase switch $j: $r vs $old", r.perSwitch[j] <= old.perSwitch[j] + 2)
            assertTrue("phase $phase: $r vs $old", r.steady <= old.steady)
            assertTrue("phase $phase: $r vs $old", r.drops <= old.drops && r.longestDropRun <= maxOf(old.longestDropRun, 1))
        }
    }

    @Test fun game120PanelSwitchKeepsTheStream() {
        // Game 120, 60 fps content, panel 120 -> 60 -> 120 (touch starts/stops): the interval is two periods at 120 Hz
        // (inferred) and one at 60 Hz (thinned), the same 16.7 ms, so T-208's same-stream re-grid applies.
        for ((i, phase) in longArrayOf(1 * ms, 5 * ms, 11 * ms).withIndex()) {
            val rig = PresentRig(120, p120, adaptive = true)
            val rnd = Lcg(900L + i)
            val start = 1_000_000_000L
            val switchNs = ArrayList<Long>()
            for (k in 0 until 1800) {
                val cap = start + k * p60
                val ready = cap + 22 * ms + ((rnd.next() * 2 - 1) * 3 * ms).toLong()
                if (k == 600 || k == 1200) {
                    val at = ready - 5 * ms
                    rig.switchPanel(if (k == 600) 60 else 120, at, phase.coerceAtMost(rig.period))
                    switchNs.add(at)
                }
                rig.frame(k, cap, ready)
            }
            rig.finish(start + 1800 * p60 + 100 * ms)
            val shown = rig.shown()
            val per = IntArray(2)
            var steady = 0
            for (j in 1 until shown.size) {
                val dt = shown[j][1] - shown[j - 1][1]
                if (Math.abs(dt - p60) <= 2 * ms) continue
                val w = switchNs.indexOfFirst { shown[j][1] >= it && shown[j][1] < it + 60 * p60 }
                if (w >= 0) per[w]++ else steady++
            }
            println("Game120 panel switch phase ${phase / ms} ms: irregular per switch ${per.toList()}, steady $steady")
            for ((j, n) in per.withIndex()) assertTrue("phase $phase switch $j: $n irregular", n <= 1)
            assertTrue("phase $phase steady $steady", steady <= 3)
            assertTrue(rig.pacer.phaseLock)
        }
    }

    private companion object {
        fun key(d: FramePacer.Decision) =
            "${d.renderNs} ${d.collided} ${d.addedNs} ${d.skipped} ${d.slotNs} ${d.lateDrop} ${d.ownSlotNs}"
        fun f(v: Double) = String.format(java.util.Locale.ROOT, "%.2f", v)
    }

    @Test fun inferenceNeedsAStableWindowFirst() {
        // The first frames of a Game 120 stream resolve to one period until 16 gaps agree.
        val rig = PresentRig(120, p120, adaptive = true)
        for (k in 0 until 10) rig.frame(k, 1_000_000_000L + k * p60, 1_000_000_000L + k * p60 + 22 * ms)
        assertFalse(rig.tracker.cadenceNs > 0)
    }
}
