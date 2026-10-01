package dev.matebridge.client.audio

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * T-098: the Mac's audio IO stops while nothing plays, so AUDIO_FRAMEs stop too. Simulates the host packetizer
 * (AudioPacketizer: 240-frame IO callbacks, 480-frame packets, capture time of the first frame), a network with a
 * fixed transit delay (optionally a stall), and the tablet rendering fixed bursts through [PlayoutCore]. Host and
 * tablet clocks are equal here; time is counted in frames at 48 kHz.
 */
class SilenceGapSimulationTest {
    private class Pkt(val arrival: Long, val index: Long, val captureUs: Long, val frames: Int)

    /**
     * Host side. [sounds] are [start, end) frame ranges where the Mac plays something (multiples of 240 frames).
     * [indexFollowsClock]: the device sample time keeps running while IO is stopped, so `sample_index` jumps over the
     * silence (the partial packet is published at the restart). Otherwise the index is continuous and the partial
     * packet is completed with the restart's first frames under its old capture time.
     */
    private fun host(sounds: List<LongRange>, indexFollowsClock: Boolean, transit: Long = 96): List<Pkt> {
        val pkts = ArrayList<Pkt>()
        var fill = 0
        var pktIndex = 0L
        var pktCap = 0L
        var nextIndex = 0L
        var prevEnd = -1L
        for (s in sounds) {
            if (prevEnd >= 0 && indexFollowsClock) {
                if (fill > 0) { pkts += Pkt(s.first + transit, pktIndex, pktCap, fill); fill = 0 }
                nextIndex += s.first - prevEnd
            }
            var t = s.first
            while (t < s.last + 1) { // one 240-frame IO callback at a time
                var off = 0
                while (off < 240) {
                    if (fill == 0) { pktIndex = nextIndex; pktCap = (t + off) * 1_000_000L / 48_000 }
                    val n = minOf(240 - off, 480 - fill)
                    fill += n; off += n; nextIndex += n
                    if (fill == 480) { pkts += Pkt(t + 240 + transit, pktIndex, pktCap, 480); fill = 0 }
                }
                t += 240
            }
            prevEnd = s.last + 1
        }
        return pkts // in send order
    }

    /** TCP: a packet never arrives before the one sent ahead of it. */
    private fun tcp(pkts: List<Pkt>): List<Pkt> {
        var last = Long.MIN_VALUE
        return pkts.map { p -> if (p.arrival < last) Pkt(last, p.index, p.captureUs, p.frames) else p.also { last = it.arrival } }
    }

    /** Tablet side: delivers packets as they arrive and renders bursts of [burst] frames. */
    private class Tablet(val burst: Int, private val pkts: List<Pkt>) {
        val core = PlayoutCore()
        val out = ShortArray(burst * 2)
        private val data = ByteArray(480 * 4).also { for (i in it.indices step 2) { it[i] = 0; it[i + 1] = 0x10 } }
        var now = 0L
        private var next = 0
        /** Arrival time of each packet, and the output frame where audio was first heard after it. */
        val starts = ArrayList<Pair<Long, Long>>()
        private var waitingSince = -1L
        private var lastAudible = false

        fun run(until: Long) {
            while (now < until) {
                while (next < pkts.size && pkts[next].arrival <= now) {
                    val p = pkts[next++]
                    if (!lastAudible && waitingSince < 0) waitingSince = p.arrival
                    core.buffer.write(p.index, p.captureUs, data, p.frames)
                }
                core.render(out, burst)
                val first = (0 until burst).firstOrNull { out[it * 2] != 0.toShort() }
                if (first != null && !lastAudible && waitingSince >= 0) {
                    starts += waitingSince to now + first
                    waitingSince = -1
                }
                lastAudible = core.state != PlayoutCore.State.PRIMING
                now += burst
            }
        }
    }

    /** 100 ms (or [onMs]) of sound, 500 ms of silence, repeated [n] times. */
    private fun bursty(n: Int, onMs: Int = 100, offMs: Int = 500): List<LongRange> =
        (0 until n).map { k ->
            val start = k * (onMs + offMs) * 48L
            start until start + onMs * 48L
        }

    private fun intermittent(burst: Int, indexFollowsClock: Boolean, onMs: Int) {
        val n = 10
        val tab = Tablet(burst, host(bursty(n, onMs), indexFollowsClock))
        tab.run(n * (onMs + 500) * 48L)
        val core = tab.core
        val d = core.drift
        assertEquals("underruns", 0L, d.underruns)
        assertEquals("safety stays at its minimum", DriftController.SAFETY_MIN_MS * 48, d.safetyFrames)
        assertEquals("one idle gap per silence", n.toLong() - 1, core.idleGaps)
        assertEquals("every sound was heard", n, tab.starts.size)
        assertEquals(PlayoutCore.State.PRIMING, core.state)
        assertTrue(core.idle)
        // each sound after a silence starts once target + one burst + the fade-out reserve is buffered (packets arrive
        // in real time, so collecting it takes less than that level), plus one burst of render granularity
        val bound = d.targetFrames + burst + PlayoutCore.FADE_OUT_MS * 48 + burst
        for ((arrival, heard) in tab.starts.drop(1)) {
            val delay = heard - arrival
            assertTrue("start delay $delay frames (bound $bound)", delay in 0..bound)
        }
    }

    @Test fun intermittentAudioIsIdleNotUnderrunIndexJumps() = intermittent(96, indexFollowsClock = true, onMs = 100)

    @Test fun intermittentAudioIsIdleNotUnderrunPartialPacket() = intermittent(96, indexFollowsClock = false, onMs = 105)

    @Test fun intermittentAudioIsIdleNotUnderrunLargeBurst() = intermittent(960, indexFollowsClock = true, onMs = 100)

    @Test fun intermittentAudioIsIdleNotUnderrunLargeBurstPartialPacket() =
        intermittent(960, indexFollowsClock = false, onMs = 105)

    @Test fun soundStartIsHeardWithinTargetPlusFadeIn() {
        // 2 ms bursts: the first packet after the silence already covers target + burst + reserve
        val tab = Tablet(96, host(bursty(5), indexFollowsClock = true))
        tab.run(5 * 600 * 48L)
        val limit = tab.core.drift.targetFrames + PlayoutCore.FADE_IN_MS * 48
        for ((arrival, heard) in tab.starts.drop(1)) assertTrue("delay ${heard - arrival}", heard - arrival <= limit)
    }

    @Test fun networkStallIsAnUnderrun() {
        // continuous sound; the network holds everything sent in 2.000..2.080 s, then delivers it at once
        val pkts = host(listOf(0L until 5 * 48_000L), indexFollowsClock = true)
            .map { if (it.arrival in 96_000L until 99_840L) Pkt(99_840L, it.index, it.captureUs, it.frames) else it }
            .let(::tcp)
        val tab = Tablet(96, pkts)
        tab.run(2 * 48_000L)
        val before = tab.core.drift.underruns
        val safety = tab.core.drift.safetyFrames
        tab.run(5 * 48_000L)
        assertEquals(before + 1, tab.core.drift.underruns)
        assertEquals(safety + DriftController.SAFETY_STEP_MS * 48, tab.core.drift.safetyFrames)
        assertEquals(0L, tab.core.idleGaps)
    }

    @Test fun jitterUnderrunWithoutSilenceIsStillAnUnderrun() {
        // one packet arrives 15 ms late (no capture jump, gap under the idle threshold)
        val pkts = host(listOf(0L until 3 * 48_000L), indexFollowsClock = true)
            .map { if (it.index == 48_000L) Pkt(it.arrival + 720, it.index, it.captureUs, it.frames) else it }
            .let(::tcp)
        val tab = Tablet(96, pkts)
        tab.run(3 * 48_000L)
        assertEquals(1L, tab.core.drift.underruns)
        assertEquals(0L, tab.core.idleGaps)
    }

    @Test fun indexJumpAfterSilenceDoesNotAccumulateLatency() {
        // two long sounds 300 ms apart; the index jumps by the silence (device sample time kept running)
        val sounds = listOf(0L until 48_000L, 62_400L until 110_400L)
        val tab = Tablet(96, host(sounds, indexFollowsClock = true))
        tab.run(110_000L)
        val b = tab.core.buffer
        assertEquals(1L, b.jumpEvents)
        assertEquals(1L, tab.core.idleGaps)
        assertEquals(0L, tab.core.drift.underruns)
        // the level is back near the target, not 100 ms of filled silence above it
        assertTrue("level ${b.level}", b.level < tab.core.drift.targetFrames + 2 * 480)
    }

    @Test fun silenceWithoutAnyNewPacketCountsNothing() {
        val tab = Tablet(96, host(listOf(0L until 9_600L), indexFollowsClock = true))
        tab.run(5 * 48_000L)
        assertEquals(0L, tab.core.drift.underruns)
        assertEquals(0L, tab.core.idleGaps)
        assertTrue(tab.core.idle)
    }
}
