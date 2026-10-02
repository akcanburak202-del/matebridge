package dev.matebridge.client.audio

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.abs

/**
 * T-118: after a transport stall the held packets arrive together. The refill must not leave the level (and so the
 * audio latency) far above the new target for seconds. Time is counted in tablet output frames (48 kHz).
 */
class UnderrunRefillTest {
    /** Host sends a 10 ms packet every 480 frames, 2 ms transit; packets sent during [stall] all arrive at its end. */
    private class Sim(val burst: Int, val stall: LongRange?, safetyMs: Int) {
        val core = PlayoutCore()
        private val packet = ByteArray(480 * 4) { 0x20 }
        private var next = 0L
        var t = 0L
            private set
        private val out = ShortArray(burst * 2)

        init {
            core.drift.resetSafety(safetyMs, 20)
        }

        private fun arrival(k: Long): Long {
            val a = k * 480 + 96
            return if (stall != null && a in stall) stall.last + 1 else a
        }

        fun run(frames: Long, each: () -> Unit = {}) {
            val end = t + frames
            while (t < end) {
                while (arrival(next) <= t) {
                    core.buffer.write(next * 480, next * 10_000, packet, 480)
                    next++
                }
                core.render(out, burst)
                t += burst
                each()
            }
        }
    }

    private fun stallRecovers(burst: Int) {
        // learned 35 ms, steady for 10 s, then an 80 ms stall: deeper than the level, so a real underrun
        val stallStart = 10 * 48_000L
        val sim = Sim(burst, stallStart until stallStart + 80 * 48, safetyMs = 35)
        sim.run(stallStart)
        val d = sim.core.drift
        assertEquals(0L, d.underruns)
        val before = d.targetFrames
        var restartAt = -1L
        var wasPlaying = true
        var maxPpm = 0.0
        sim.run(5 * 48_000L) {
            val playing = sim.core.state == PlayoutCore.State.PLAYING
            if (playing && !wasPlaying && restartAt < 0) restartAt = sim.t
            wasPlaying = playing
            maxPpm = maxOf(maxPpm, abs(d.ratioPpm))
        }
        assertEquals("one underrun", 1L, d.underruns)
        assertTrue(restartAt > 0)
        assertEquals(before + d.safetyStepFrames, d.targetFrames) // +5 ms, nothing decayed yet
        assertEquals("the bunched excess was dropped once", 1L, sim.core.refillTrims)
        // run on to 3 s after the restart: the floor is back within 5 ms of the new target
        val left = restartAt + 3 * 48_000L - sim.t
        if (left > 0) sim.run(left) { maxPpm = maxOf(maxPpm, abs(d.ratioPpm)) }
        val errMs = (d.lastFloorFrames - d.targetFrames) / 48.0
        assertTrue("floor err $errMs ms 3 s after the restart", abs(errMs) <= 5.0)
        assertTrue("level ${sim.core.lastRemainingFrames / 48} ms", sim.core.lastRemainingFrames <= d.targetFrames + 25 * 48)
        // pitch never moved more than 0.5 %
        assertTrue("ratio $maxPpm ppm", maxPpm <= 5_000.0)
    }

    // T-118 (d)
    @Test fun levelReturnsToTargetWithinThreeSecondsAfterAStall5msBursts() = stallRecovers(240)

    @Test fun levelReturnsToTargetWithinThreeSecondsAfterAStall2msBursts() = stallRecovers(96)

    @Test fun steadyStartIsNotTrimmed() {
        val sim = Sim(240, null, safetyMs = 20)
        sim.run(5 * 48_000L)
        assertEquals(0L, sim.core.refillTrims)
        assertEquals(0L, sim.core.drift.underruns)
    }

    @Test fun startAfterAnAvHoldKeepsItsLevel() {
        val core = PlayoutCore()
        val packet = ByteArray(480 * 4) { 0x20 }
        val out = ShortArray(96 * 2)
        var idx = 0L
        core.primingHoldUs = 50_000 // audio would be early: wait above the refill level
        repeat(8) {
            core.buffer.write(idx, 0, packet, 480); idx += 480
            core.render(out, 96)
        }
        assertEquals(PlayoutCore.State.PRIMING, core.state)
        val level = core.buffer.level
        core.primingHoldUs = 0
        core.render(out, 96)
        assertEquals(PlayoutCore.State.PLAYING, core.state)
        assertEquals(0L, core.refillTrims)
        assertTrue(core.buffer.level > level - 2 * 96) // only the first burst was consumed
    }

    @Test fun bunchedFirstStartIsTrimmedToTheThreshold() {
        val core = PlayoutCore()
        val packet = ByteArray(480 * 4) { 0x20 }
        val out = ShortArray(96 * 2)
        repeat(10) { core.buffer.write(it * 480L, 0, packet, 480) } // 100 ms at once
        core.render(out, 96)
        assertEquals(PlayoutCore.State.PLAYING, core.state)
        assertEquals(1L, core.refillTrims)
        val threshold = core.drift.refillThresholdFrames(96, PlayoutCore.FADE_OUT_MS * 48)
        assertEquals(10 * 480L - threshold, core.refillTrimFrames)
        assertTrue(core.buffer.level <= threshold)
    }
}
