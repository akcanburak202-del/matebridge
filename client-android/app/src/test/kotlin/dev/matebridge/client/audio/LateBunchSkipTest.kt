package dev.matebridge.client.audio

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.abs

/**
 * T-125: after an underrun the held packets may arrive at catch-up speed, mostly after playback restarted. The level
 * must not stay far above the target for the ~20 s the PI needs; the excess is skipped once, with a crossfade.
 * Time is counted in tablet output frames (48 kHz); packet k carries frames [k * 480, k * 480 + 480) of the host's
 * clock (a jump in k is a jump in capture time, i.e. the host captured nothing in between).
 */
class LateBunchSkipTest {
    private class Sim(val burst: Int, safetyMs: Int, floorMs: Int = safetyMs, maxMs: Int = 70) {
        val core = PlayoutCore()
        private val packet = ByteArray(480 * 4) { 0x20 }
        private val arrivals = ArrayList<Pair<Long, Long>>() // arrival, packet number
        private var next = 0
        var t = 0L
            private set
        private val out = ShortArray(burst * 2)
        var maxPpm = 0.0
            private set
        var hold: () -> Long = { 0L }

        init {
            core.drift.resetSafety(safetyMs, floorMs, maxMs)
        }

        /** Packets [from, to) arrive at [arrival] (must not decrease: TCP). */
        fun send(from: Long, to: Long, arrival: (Long) -> Long = { it * 480 + 96 }) {
            for (k in from until to) arrivals += arrival(k) to k
        }

        fun run(frames: Long, each: () -> Unit = {}) {
            val end = t + frames
            while (t < end) {
                while (next < arrivals.size && arrivals[next].first <= t) {
                    val k = arrivals[next++].second
                    core.buffer.write(k * 480, k * 10_000, packet, 480)
                }
                if (core.state == PlayoutCore.State.PRIMING) core.primingHoldUs = hold()
                core.render(out, burst)
                t += burst
                maxPpm = maxOf(maxPpm, abs(core.drift.ratioPpm))
                each()
            }
        }

        /** Lowest and highest level over the next [frames]. */
        fun levelRange(frames: Long): Pair<Int, Int> {
            var lo = Int.MAX_VALUE
            var hi = Int.MIN_VALUE
            run(frames) {
                val l = core.lastRemainingFrames
                if (l < lo) lo = l
                if (l > hi) hi = l
            }
            return lo to hi
        }
    }

    private val ms = 48

    /**
     * Steady until [stallAt], then nothing for [stallMs]; the held packets and those after them come [catchUp] times
     * faster than real time until they are back on schedule. Returns the time the catch-up ends.
     */
    private fun stallWithCatchUp(sim: Sim, stallAt: Long, stallMs: Int, catchUp: Int, total: Long, normal: (Long) -> Long = { it * 480 + 96 }): Long {
        var k0 = 0L // first packet due during the stall
        while (normal(k0) < stallAt) k0++
        val stallEnd = stallAt + stallMs * ms
        var caughtUp = 0L
        sim.send(0, total) { k ->
            if (k < k0) normal(k) else {
                val a = maxOf(normal(k), stallEnd + (k - k0) * 480 / catchUp)
                if (a > normal(k)) caughtUp = a
                a
            }
        }
        return caughtUp
    }

    private fun lateBunchRecovers(burst: Int, peakMs: Int = 25, normal: (Long) -> Long = { it * 480 + 96 }) {
        val sim = Sim(burst, safetyMs = 40)
        val stallAt = 10 * 48_000L
        val bunchEnd = stallWithCatchUp(sim, stallAt, stallMs = 80, catchUp = 4, total = 3_000, normal = normal)
        sim.run(stallAt)
        val d = sim.core.drift
        assertEquals(0L, d.underruns)
        assertEquals(0L, sim.core.skipTrims)
        sim.run(bunchEnd - sim.t)
        assertEquals("one underrun", 1L, d.underruns)
        assertTrue(
            "the bunch came after the restart: ${sim.core.state} t=${sim.t} stallAt=$stallAt bunchEnd=$bunchEnd " +
                "level=${sim.core.buffer.level / ms} target=${d.targetFrames / ms} skips=${sim.core.skipTrims} trims=${sim.core.refillTrims}",
            sim.core.state == PlayoutCore.State.PLAYING,
        )
        // 1 s after the bunch: the level is back at the target (floor within 10 ms, sawtooth on top)
        sim.run(48_000L - 200 * ms)
        val (lo, hi) = sim.levelRange(200L * ms)
        val target = d.targetFrames
        assertEquals("one skip", 1L, sim.core.skipTrims)
        assertTrue("floor ${(lo - target) / ms} ms from the target", abs(lo - target) <= 10 * ms)
        assertTrue("peak ${(hi - target) / ms} ms above the target", hi <= target + peakMs * ms)
        // and it stays playable: no further underrun, no further skip, pitch within 0.5 %
        sim.run(5 * 48_000L)
        assertEquals(1L, d.underruns)
        assertEquals(1L, sim.core.skipTrims)
        assertTrue("ratio ${sim.maxPpm} ppm", sim.maxPpm <= 5_000.0)
    }

    // T-125 (a)
    @Test fun lateBunchIsSkippedWithinOneSecond5msBursts() = lateBunchRecovers(240)

    @Test fun lateBunchIsSkippedWithinOneSecond2msBursts() = lateBunchRecovers(96)

    /** Wi-Fi-like arrivals: four packets together every 40 ms. */
    @Test fun lateBunchIsSkippedWithBurstyArrivals() = lateBunchRecovers(240, peakMs = 50) { k -> (k / 4 + 1) * 1920 + 96 }

    @Test fun atMostOneSkipPerUnderrunWindow() {
        val sim = Sim(240, safetyMs = 40)
        val stallAt = 10 * 48_000L
        // 1 s after the stall, still inside the window, the host delivers 4 packets (40 ms) ahead of time
        val extraAt = 11 * 48_000L
        val bunchEnd = stallWithCatchUp(sim, stallAt, stallMs = 80, catchUp = 4, total = 3_000) { k ->
            if (k < extraAt / 480) k * 480 + 96 else maxOf(extraAt, (k - 4) * 480 + 96)
        }
        assertTrue(bunchEnd < extraAt)
        sim.run(extraAt)
        assertEquals(1L, sim.core.skipTrims)
        sim.run(600L * ms)
        val (lo, _) = sim.levelRange(200L * ms)
        assertEquals("no second skip in the window", 1L, sim.core.skipTrims)
        assertTrue(
            "the second excess is there: floor ${(lo - sim.core.drift.targetFrames) / ms} ms above",
            lo > sim.core.drift.targetFrames + 25 * ms,
        )
    }

    // T-125 (b): a new sound after silence, its first packets bunched, is not cut
    @Test fun newSoundAfterSilenceIsNotCut() {
        val sim = Sim(240, safetyMs = 40)
        sim.send(0, 500) // 5 s of sound
        val k6 = 600L // 1 s of silence: the capture time jumps
        val soundAt = k6 * 480 + 80 * ms
        sim.send(k6, 1_400) { k -> maxOf(k * 480 + 96, soundAt + (k - k6) * 120) }
        sim.run(soundAt)
        assertEquals(PlayoutCore.State.PRIMING, sim.core.state)
        val dropsBefore = sim.core.buffer.dropFrames
        sim.run(2_900L * ms)
        assertTrue(sim.core.idleGaps >= 1)
        assertEquals(0L, sim.core.drift.underruns)
        assertEquals(0L, sim.core.refillTrims)
        assertEquals("the start of the new sound is not skipped", 0L, sim.core.skipTrims)
        assertEquals(dropsBefore, sim.core.buffer.dropFrames)
    }

    // T-125 (c): a start held for A/V after an underrun keeps its (intended) level
    @Test fun avHoldLevelIsKept() {
        val sim = Sim(240, safetyMs = 40)
        val stallAt = 10 * 48_000L
        stallWithCatchUp(sim, stallAt, stallMs = 80, catchUp = 4, total = 3_000)
        sim.run(stallAt)
        sim.hold = { if (sim.core.buffer.level < 110 * ms) 60_000L else 0L } // audio would be early: wait to 110 ms
        var restartAt = -1L
        sim.run(2 * 48_000L) {
            if (restartAt < 0 && sim.t > stallAt && sim.core.state == PlayoutCore.State.PLAYING) restartAt = sim.t
        }
        assertTrue(restartAt > 0)
        assertEquals(1L, sim.core.drift.underruns)
        val target = sim.core.drift.targetFrames
        assertTrue("A/V floor is the target (${target / ms} ms)", target >= 90 * ms)
        sim.run(5 * 48_000L)
        assertEquals(0L, sim.core.skipTrims)
        val (lo, _) = sim.levelRange(48_000L)
        assertTrue("floor ${lo / ms} ms kept near ${target / ms} ms", abs(lo - target) <= 10 * ms)
    }

    /** Steady, then at [at] the host delivers [extra] packets ahead of time (the level stays [extra] * 10 ms higher). */
    private fun excessSim(extra: Int, at: Long): Sim {
        val sim = Sim(240, safetyMs = 40)
        val kAt = at / 480
        sim.send(0, 4_000) { k -> if (k < kAt) k * 480 + 96 else maxOf(at, (k - extra) * 480 + 96) }
        return sim
    }

    // T-125: outside the window, a sustained high level is skipped once, after 3 s
    @Test fun sustainedExcessIsSkippedOnceAfterThreeSeconds() {
        val at = 10 * 48_000L
        val sim = excessSim(extra = 10, at = at)
        sim.run(at + 3 * 48_000L - 240)
        assertEquals("not before three windows", 0L, sim.core.skipTrims)
        sim.run(2 * 48_000L)
        assertEquals(1L, sim.core.skipTrims)
        assertEquals(0L, sim.core.drift.underruns)
        assertEquals(0L, sim.core.drift.resyncs)
        val target = sim.core.drift.targetFrames
        val (lo, _) = sim.levelRange(48_000L)
        assertTrue("floor ${(lo - target) / ms} ms from the target", abs(lo - target) <= 10 * ms)
        sim.run(10 * 48_000L)
        assertEquals("once", 1L, sim.core.skipTrims)
    }

    @Test fun moderateExcessStaysWithThePi() {
        val at = 10 * 48_000L
        val sim = excessSim(extra = 5, at = at)
        sim.run(at + 15 * 48_000L)
        assertEquals(0L, sim.core.skipTrims)
        assertTrue("ratio ${sim.maxPpm} ppm", sim.maxPpm <= 5_000.0)
    }

    @Test fun steadyPlaybackNeverSkips() {
        val sim = Sim(240, safetyMs = 40)
        sim.send(0, 3_000) { k -> (k / 4 + 1) * 1920 + 96 }
        sim.run(25 * 48_000L)
        assertEquals(0L, sim.core.skipTrims)
        assertEquals(0L, sim.core.drift.underruns)
    }
}
