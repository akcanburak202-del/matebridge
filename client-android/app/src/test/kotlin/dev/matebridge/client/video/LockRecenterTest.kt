package dev.matebridge.client.video

import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * T-067: the phase lock must not stay on a wrong (too early) slot, and an idle gap must not erase what is known
 * about the pipeline's jitter. 60 Hz panel, 60 fps stream, ready = capture + 16 ms + jitter (mostly 0..4 ms,
 * 1 percent spikes of 6..12 ms).
 */
class LockRecenterTest {
    private val ms = 1_000_000L

    private class Lcg(var seed: Long) {
        fun next(): Double { seed = seed * 6364136223846793005L + 1442695040888963407L; return ((seed ushr 33) % 10_000) / 10_000.0 }
    }

    private class Stat(var frames: Int = 0, var late: Int = 0) {
        val pct get() = if (frames == 0) 0.0 else 100.0 * late / frames
        fun add(late: Boolean) { frames++; if (late) this.late++ }
    }

    private class Sim(val pacer: AdaptivePacer, val fiNs: Long, val rnd: Lcg, phaseNs: Long) {
        var capNs = 1_000_000_000L
        // Jitter-free ready time falls phaseNs after a vsync boundary (the panel period equals the nominal one).
        val readyBase = 16 * 1_000_000L + ((phaseNs - (capNs + 16 * 1_000_000L)) % 16_666_666L + 16_666_666L) % 16_666_666L

        fun feed(n: Int, onFrame: (Int, Boolean) -> Unit) {
            for (i in 0 until n) {
                val r = rnd.next()
                val jit = if (rnd.next() < 0.01) 6 * 1_000_000L + (rnd.next() * 6 * 1_000_000L).toLong()
                else (r * 4 * 1_000_000L).toLong()
                val d = pacer.schedule(capNs / 1000, capNs + readyBase + jit)!!
                onFrame(i, d.lateDrop)
                capNs += fiNs
            }
        }
        fun gap(ns: Long) { capNs += ns }
    }

    private fun clock() = VsyncClock(60f).also { it.onVsync(0); it.keepJitter = true; it.recenter = true }
    private val phases = longArrayOf(0, 3 * ms, 6 * ms, 9 * ms, 12 * ms, 15 * ms)

    @Test fun coldStartSettlesToFewLateFrames() {
        var worst = 0.0
        for ((i, ph) in phases.withIndex()) {
            val clk = clock(); val p = AdaptivePacer(clk, clk.grid().periodNs)
            val sim = Sim(p, clk.grid().periodNs, Lcg(7L + i), ph)
            val s = Stat()
            val perSec = IntArray(62)
            sim.feed(60 * 62) { k, late -> if (late) perSec[k / 60]++; if (k >= 120) s.add(late) }
            println("cold phase=$ph perSecond=${perSec.take(20)}")
            println("cold phase=$ph late%=${"%.2f".format(s.pct)} rephases=${p.rephases}")
            worst = maxOf(worst, s.pct)
        }
        assertTrue("late $worst%", worst <= 1.0)
    }

    @Test fun earlyLockIsRecentredByTheLateFrameRate() {
        // Worst phase: the first frames are lucky, the lock lands just after the ideal time and the real jitter misses it.
        val clk = clock(); val p = AdaptivePacer(clk, clk.grid().periodNs)
        val sim = Sim(p, clk.grid().periodNs, Lcg(12L), 15 * ms)
        val first = Stat()
        sim.feed(60 * 10) { k, late -> if (k < 60) first.add(late) }
        println("recentre first1s late=${first.late} recenters=${p.recenters}")
        assertTrue("late in first second ${first.late}", first.late <= 6)
        assertTrue("recenters ${p.recenters}", p.recenters in 1L..3L)
    }

    @Test fun gapKeepsJitterHistory() {
        var cold = 0.0; var after = 0.0
        for ((i, ph) in phases.withIndex()) {
            val clk = clock(); val p = AdaptivePacer(clk, clk.grid().periodNs)
            val sim = Sim(p, clk.grid().periodNs, Lcg(100L + i), ph)
            val c = Stat(); val a = Stat()
            sim.feed(60 * 10) { k, late -> if (k < 60) c.add(late) }
            sim.gap(1_500_000_000L)
            sim.feed(60 * 10) { k, late -> if (k < 60) a.add(late) }
            println("gap phase=$ph cold1s%=${"%.2f".format(c.pct)} after1s%=${"%.2f".format(a.pct)} rephases=${p.rephases}")
            cold += c.pct; after += a.pct
        }
        val n = phases.size
        assertTrue("after-gap first second ${after / n}% vs cold ${cold / n}%", after / n <= 1.0 && after <= cold * 0.5)
    }

    @Test fun hundredPpmDriftFiveMinutes() {
        var worst = 0.0; var worstReph = 0L
        for ((i, ph) in phases.withIndex()) {
            val clk = clock(); val period = clk.grid().periodNs
            val fi = (period * 1.0001).toLong() // stream interval 100 ppm off the panel period
            val p = AdaptivePacer(clk, fi)
            val sim = Sim(p, fi, Lcg(300L + i), ph)
            val s = Stat()
            sim.feed(60 * 300) { k, late -> if (k >= 120) s.add(late) }
            println("drift phase=$ph late%=${"%.2f".format(s.pct)} rephases=${p.rephases}")
            worst = maxOf(worst, s.pct); worstReph = maxOf(worstReph, p.rephases)
        }
        assertTrue("late $worst%", worst <= 1.0)
        assertTrue("rephases $worstReph in 5 min", worstReph <= 20)
    }
}
