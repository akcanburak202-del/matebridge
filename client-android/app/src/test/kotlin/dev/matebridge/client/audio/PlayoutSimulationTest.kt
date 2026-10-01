package dev.matebridge.client.audio

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.abs
import kotlin.random.Random

/**
 * End-to-end playout simulation (pure): a host producing 10 ms packets on its own clock (+-[driftPpm] against the
 * tablet's audio clock), TCP-ordered arrivals with random jitter, and the tablet consuming fixed bursts through
 * [PlayoutCore]. Times are in tablet seconds.
 */
class PlayoutSimulationTest {
    private class Sim(
        val driftPpm: Double,
        val jitterMs: Double,
        val burst: Int = 96,
        seed: Int = 1,
        val core: PlayoutCore = PlayoutCore(),
    ) {
        private val rnd = Random(seed)
        private val packet = ByteArray(480 * 4) { 0x10 }
        private var nextPacket = 0L
        private var lastArrival = 0.0
        private var pendingArrival = Double.NaN
        private var t = 0.0
        val out = ShortArray(burst * 2)

        /** Host send time of packet k: the host clock runs (1 + drift) times as fast, so it produces more samples. */
        private fun sendTime(k: Long) = k * 480 / (48_000.0 * (1 + driftPpm * 1e-6))

        private fun arrival(k: Long): Double {
            val a = maxOf(lastArrival, sendTime(k) + 0.002 + rnd.nextDouble() * jitterMs / 1000)
            lastArrival = a
            return a
        }

        /** Runs [seconds]; calls [each] after every burst. */
        fun run(seconds: Double, each: (Sim) -> Unit = {}) {
            val end = t + seconds
            while (t < end) {
                while (true) {
                    if (pendingArrival.isNaN()) pendingArrival = arrival(nextPacket)
                    if (pendingArrival > t) break
                    core.buffer.write(nextPacket * 480, 0, packet, 480)
                    nextPacket++
                    pendingArrival = Double.NaN
                }
                core.render(out, burst)
                t += burst / 48_000.0
                each(this)
            }
        }
    }

    private fun converges(driftPpm: Double, jitterMs: Double) {
        val sim = Sim(driftPpm, jitterMs)
        sim.run(60.0) // settle (initial underruns grow the safety margin)
        val d = sim.core.drift
        val underrunsBefore = d.underruns
        var minRemaining = Int.MAX_VALUE
        var ppmSum = 0.0
        var ppmMin = Double.MAX_VALUE
        var ppmMax = -Double.MAX_VALUE
        var n = 0
        sim.run(120.0) {
            minRemaining = minOf(minRemaining, it.core.lastRemainingFrames)
            ppmSum += d.ratioPpm; n++
            ppmMin = minOf(ppmMin, d.ratioPpm); ppmMax = maxOf(ppmMax, d.ratioPpm)
        }
        assertEquals("no underrun after settling (drift=$driftPpm)", underrunsBefore, d.underruns)
        assertEquals(0L, d.resyncs)
        assertEquals(PlayoutCore.State.PLAYING, sim.core.state)
        // on average the ratio equals the clock difference; it wanders by far less than an audible pitch change (0.3 %)
        val mean = ppmSum / n
        assertTrue("mean ratio $mean ppm for drift $driftPpm", abs(mean - driftPpm) < 20)
        assertTrue("ratio range $ppmMin..$ppmMax ppm", ppmMax - ppmMin < 500) // 0.05 %: far below audible
        // the floor sits at the target (within 3 ms), the level never ran dry
        val floorErrMs = (d.lastFloorFrames - d.targetFrames) / 48.0
        assertTrue("floor err $floorErrMs ms", abs(floorErrMs) < 3.0)
        assertTrue(minRemaining > 0)
    }

    @Test fun piConvergesWithHostClockFast() = converges(+200.0, 4.0)

    @Test fun piConvergesWithHostClockSlow() = converges(-200.0, 4.0)

    @Test fun piConvergesWithoutJitter() = converges(+200.0, 0.0)

    @Test fun startsAfterPrimingWithFadeIn() {
        val sim = Sim(0.0, 0.0)
        var firstNonZero = -1
        var bursts = 0
        sim.run(0.5) {
            bursts++
            if (firstNonZero < 0 && it.out.any { s -> s != 0.toShort() }) firstNonZero = bursts
        }
        assertTrue(firstNonZero > 1) // silence while priming
        assertEquals(PlayoutCore.State.PLAYING, sim.core.state)
    }

    @Test fun stalledProducerUnderrunsWithFadeThenRefills() {
        val core = PlayoutCore()
        val packet = ByteArray(480 * 4) { 0x40 }
        var idx = 0L
        val out = ShortArray(96 * 2)
        // fill and play
        repeat(4) { core.buffer.write(idx, 0, packet, 480); idx += 480 }
        core.render(out, 96)
        assertEquals(PlayoutCore.State.PLAYING, core.state)
        // starve: keep rendering without new packets
        var prevLast = Int.MAX_VALUE
        var sawFade = false
        repeat(40) {
            core.render(out, 96)
            if (core.state == PlayoutCore.State.FADING_OUT) {
                sawFade = true
                for (f in 0 until 95) assertTrue(out[(f + 1) * 2] <= out[f * 2]) // monotonic fade, no click
                prevLast = out[95 * 2].toInt()
            }
        }
        assertTrue(sawFade)
        assertTrue(prevLast < 0x4040)
        assertEquals(PlayoutCore.State.PRIMING, core.state)
        assertEquals(1L, core.drift.underruns)
        assertTrue(out.all { it == 0.toShort() })
        // packets again: playback restarts once the (raised) target plus span is buffered
        while (core.state == PlayoutCore.State.PRIMING) {
            core.buffer.write(idx, 0, packet, 480); idx += 480
            core.render(out, 96)
        }
        assertTrue(core.buffer.level + 96 >= core.drift.refillThresholdFrames() - 480)
        assertEquals(10 * 48, core.drift.safetyFrames) // 5 ms + 5 ms after one underrun
    }

    @Test fun excessAboveHardLimitIsResynced() {
        val core = PlayoutCore()
        val packet = ByteArray(480 * 4) { 0x10 }
        var idx = 0L
        val out = ShortArray(96 * 2)
        // 250 ms buffered at once (e.g. after a stall), then a steady flow
        repeat(25) { core.buffer.write(idx, 0, packet, 480); idx += 480 }
        var produced = 0
        repeat(2 * 500) {
            core.render(out, 96)
            produced += 96
            while (produced >= 480) { core.buffer.write(idx, 0, packet, 480); idx += 480; produced -= 480 }
        }
        assertEquals(1L, core.drift.resyncs)
        assertTrue(core.buffer.level < 30 * 48)
    }

    /**
     * Runs [seconds] in 1 s steps, feeding the drift controller an A/V offset that follows the buffer: the audio is
     * [av0Us] off while the floor is [floor0], and every extra frame of floor makes it later by one frame.
     */
    private fun runWithAv(sim: Sim, seconds: Int, av0Us: Long, floor0: Int): Long {
        val d = sim.core.drift
        var av = av0Us
        repeat(seconds) {
            sim.run(1.0)
            av = av0Us + (d.lastFloorFrames - floor0) * 1000L / 48
            d.onAvOffset(av)
        }
        return av
    }

    @Test fun avAlignmentRaisesTargetGraduallyWhenAudioIsEarly() {
        val sim = Sim(0.0, 2.0)
        sim.run(5.0)
        val d = sim.core.drift
        assertEquals(0, d.avFloorFrames)
        val floor = d.lastFloorFrames
        // audio 30 ms ahead of the video: the floor must rise by about 35 ms, at most 10 ms per window
        assertTrue(d.onAvOffset(-30_000))
        assertEquals(10 * 48, d.avFloorFrames)
        val underruns = d.underruns
        val av = runWithAv(sim, 40, -30_000, floor)
        assertEquals(0L, d.rebuffers) // slewed by the PI, no audible rebuffer
        assertEquals(underruns, d.underruns)
        assertTrue("final av $av us", abs(av - DriftController.AV_TARGET_US) < 8_000)
    }

    @Test fun largeAvRaiseSlewsWithoutRebuffer() {
        val sim = Sim(0.0, 2.0)
        sim.run(5.0)
        val d = sim.core.drift
        val floor = d.lastFloorFrames
        val av = runWithAv(sim, 60, -55_000, floor) // 55 ms early
        assertEquals(0L, d.rebuffers)
        assertEquals(0L, d.underruns)
        assertTrue("final av $av us", abs(av - DriftController.AV_TARGET_US) < 8_000)
    }

    @Test fun avAlignmentLowersTargetAtOnceWhenAudioIsLate() {
        val sim = Sim(0.0, 2.0)
        sim.run(3.0)
        val d = sim.core.drift
        runWithAv(sim, 30, -60_000, d.lastFloorFrames)
        val raised = d.targetFrames
        assertTrue(raised > 50 * 48)
        d.onAvOffset(+50_000) // audio now 50 ms late: back down in one step
        assertTrue(d.targetFrames < raised - 40 * 48)
    }

    @Test fun primingHoldsForAvThenSeedsTheAvFloor() {
        val core = PlayoutCore()
        val packet = ByteArray(480 * 4) { 0x10 }
        var idx = 0L
        val out = ShortArray(96 * 2)
        core.primingHoldUs = 20_000 // starting now would be 20 ms early
        repeat(6) { core.buffer.write(idx, 0, packet, 480); idx += 480 } // 60 ms: well above the refill threshold
        core.render(out, 96)
        assertEquals(PlayoutCore.State.PRIMING, core.state)
        assertTrue(out.all { it == 0.toShort() })
        core.primingHoldUs = 0 // the read head is old enough now
        core.render(out, 96)
        assertEquals(PlayoutCore.State.PLAYING, core.state)
        // the level it started at, minus half the arrival span, is the new A/V floor
        assertEquals(6 * 480 - core.drift.lastSpanFrames / 2, core.drift.avFloorFrames)
    }

    @Test fun primingHoldNeverExceedsTheMaxRefillLevel() {
        val core = PlayoutCore()
        val packet = ByteArray(480 * 4) { 0x10 }
        var idx = 0L
        val out = ShortArray(96 * 2)
        core.primingHoldUs = 1_000_000
        while (core.state == PlayoutCore.State.PRIMING && idx < 20_000L) {
            core.buffer.write(idx, 0, packet, 480); idx += 480
            core.render(out, 96)
        }
        assertEquals(PlayoutCore.State.PLAYING, core.state)
        assertTrue(core.buffer.level <= core.drift.maxRefillFrames + 480)
    }

    @Test fun largeNativeBurstStartsWithoutUnderrun() {
        // 20 ms bursts (a non-FAST track): the refill level covers a whole burst plus the fade reserve
        val sim = Sim(0.0, 2.0, burst = 960)
        sim.run(10.0)
        assertEquals(PlayoutCore.State.PLAYING, sim.core.state)
        assertEquals(0L, sim.core.drift.underruns)
    }

    @Test fun mutedOutputFadesToSilenceButKeepsConsuming() {
        val sim = Sim(0.0, 0.0)
        sim.run(1.0)
        sim.core.muted = true
        sim.run(0.1)
        assertTrue(sim.out.all { it == 0.toShort() })
        assertEquals(PlayoutCore.State.PLAYING, sim.core.state)
    }
}
