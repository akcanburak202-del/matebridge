package dev.matebridge.client.audio

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.abs

/**
 * T-287: the writer pauses the output after 60 s of silence and starts it again on the next packet. Simulates the
 * host (480-frame packets, silence gate: nothing is sent while the Mac is silent, `sample_index` and capture time
 * jump over the gap) and the tablet rendering 240-frame bursts through [PlayoutCore] with an [IdlePause] on top, as
 * `AudioPlayout.loop` does: while paused no burst is rendered and no time is counted in output frames, the writer
 * wakes at the arrival of the next packet and the output needs [startFrames] to run again (packets keep arriving).
 * Time is in frames at 48 kHz.
 */
class IdlePauseSimulationTest {
    private class Pkt(val arrival: Long, val index: Long, val captureUs: Long)

    /** 480-frame packets for each sound range; the index and capture time follow the clock across the silences. */
    private fun host(sounds: List<LongRange>, transit: Long = 96): List<Pkt> {
        val out = ArrayList<Pkt>()
        for (s in sounds) {
            var t = s.first
            while (t + 480 <= s.last + 1) {
                out += Pkt(t + 480 + transit, t, t * 1_000_000L / 48_000)
                t += 480
            }
        }
        return out
    }

    private class Tablet(val burst: Int, private val pkts: List<Pkt>, mode: IdlePause.Mode, private val startFrames: Long) {
        val core = PlayoutCore()
        val pause = IdlePause(mode)
        val out = ShortArray(burst * 2)
        private val data = ByteArray(480 * 4).also { for (i in it.indices step 2) { it[i] = 0; it[i + 1] = 0x10 } }
        var now = 0L
        private var next = 0
        var pauses = 0
        /** Time the output was not running (frames of real time). */
        var pausedFrames = 0L
        /** Per sound start: packet arrival, and the real-time frame at which audio was first heard. */
        val starts = ArrayList<Pair<Long, Long>>()
        /** The first audible sample of each start (the fade-in must begin near zero). */
        val firstSamples = ArrayList<Int>()
        private var waitingSince = -1L
        private var heardPlaying = false
        /** Packets in the buffer when the last burst started (what its render could have seen). */
        private var packetsAtRender = 0L
        /** When false the "packets the last render did not see" guard is left out (the T-287 review's P2 bug). */
        var guardNewPackets = true

        private fun deliver() {
            while (next < pkts.size && pkts[next].arrival <= now) {
                val p = pkts[next++]
                if (!heardPlaying && waitingSince < 0) waitingSince = p.arrival
                core.buffer.write(p.index, p.captureUs, data, 480)
            }
        }

        fun run(until: Long) {
            while (now < until) {
                deliver()
                val newPackets = guardNewPackets && core.buffer.packets != packetsAtRender
                if (pause.shouldPause(core.state == PlayoutCore.State.PRIMING, core.framesSinceLastPacket, canPause = true, newPackets)) {
                    pause.onPaused()
                    pauses++
                    val before = now
                    if (next >= pkts.size) { pausedFrames += until - now; now = until; break }
                    now = maxOf(now, pkts[next].arrival) // parked until the next packet
                    deliver()
                    now += startFrames // requestStart; the output runs again after it
                    deliver()
                    pausedFrames += now - before
                    pause.onResumed()
                }
                packetsAtRender = core.buffer.packets
                core.render(out, burst)
                pause.onRendered()
                val first = (0 until burst).firstOrNull { out[it * 2] != 0.toShort() }
                if (first != null && !heardPlaying && waitingSince >= 0) {
                    starts += waitingSince to now + first
                    firstSamples += out[first * 2].toInt()
                    waitingSince = -1
                }
                heardPlaying = core.state != PlayoutCore.State.PRIMING
                now += burst
            }
        }
    }

    private val sec = 48_000L
    private val sounds = listOf(
        0L until 4_800L, // 100 ms
        63 * sec until 63 * sec + 4_800L, // after 62.9 s of silence
        64 * sec until 64 * sec + 4_800L, // after 0.9 s: too short to pause
        140 * sec until 140 * sec + 4_800L, // after 75 s
    )

    private fun runTablet(mode: IdlePause.Mode, startFrames: Long): Tablet {
        val tab = Tablet(240, host(sounds), mode, startFrames)
        tab.run(145 * sec)
        return tab
    }

    @Test fun silenceOfSixtySecondsPausesAndEachSoundResumesIt() {
        val tab = runTablet(IdlePause.Mode.PAUSE, startFrames = 48 * 30L) // 30 ms to start the output
        assertEquals("one pause per long silence", 2, tab.pauses)
        assertEquals(2L, tab.pause.pauses)
        assertEquals("every sound was heard", 4, tab.starts.size)
        val d = tab.core.drift
        assertEquals("no underruns", 0L, d.underruns)
        assertEquals("safety untouched", DriftController.SAFETY_MIN_MS * 48, d.safetyFrames)
        assertEquals("every silence after a sound is one idle gap", 3L, tab.core.idleGaps)
        assertEquals(PlayoutCore.State.PRIMING, tab.core.state)
        assertTrue("paused ${tab.pausedFrames} frames: ~3 s then ~16 s", tab.pausedFrames in 18 * sec..21 * sec)
    }

    @Test fun pausingCostsAtMostTheStartTimeOnTheFirstSound() {
        val startFrames = 48 * 30L
        val paused = runTablet(IdlePause.Mode.PAUSE, startFrames)
        val plain = runTablet(IdlePause.Mode.OFF, startFrames)
        assertEquals(0, plain.pauses)
        assertEquals(0L, plain.core.drift.underruns)
        assertEquals(3L, plain.core.idleGaps)
        assertEquals("same sounds heard", plain.starts.size, paused.starts.size)
        val burst = 240L
        for (i in plain.starts.indices) {
            val delayPlain = plain.starts[i].second - plain.starts[i].first
            val delayPaused = paused.starts[i].second - paused.starts[i].first
            // while the output starts the packets keep arriving, so the priming wait overlaps with the start
            assertTrue("sound $i: paused $delayPaused vs plain $delayPlain frames", delayPaused <= delayPlain + startFrames + burst)
        }
        // the sound after the long silence is not delayed by more than the start time (50 ms target of the A/B)
        val last = paused.starts.last()
        assertTrue("delay ${last.second - last.first}", last.second - last.first <= 48 * 50L + 4 * 240)
    }

    @Test fun theFadeInStartsNearZeroAfterAResume() {
        val tab = runTablet(IdlePause.Mode.PAUSE, 48 * 30L)
        for ((i, s) in tab.firstSamples.withIndex()) {
            assertTrue("sound $i first audible sample $s", abs(s) < 600) // full scale of the test tone is 4096
        }
    }

    @Test fun aSlowStartLooksLikeAnOrdinaryRestart() {
        // the output takes 400 ms to run again: packets pile up (<= 300 ms kept), the core still treats it as idle
        val tab = runTablet(IdlePause.Mode.PAUSE, 48 * 400L)
        assertEquals(0L, tab.core.drift.underruns)
        assertEquals(3L, tab.core.idleGaps)
        assertEquals(4, tab.starts.size)
    }

    @Test fun silenceFromTheStartOfTheStreamPausesToo() {
        val tab = Tablet(240, host(listOf(90 * sec until 90 * sec + 4_800L)), IdlePause.Mode.PAUSE, 48 * 30L)
        tab.run(95 * sec)
        assertEquals(1, tab.pauses)
        assertEquals(1, tab.starts.size)
        assertEquals(0L, tab.core.drift.underruns)
        assertEquals("nothing had played before: no idle gap to count", 0L, tab.core.idleGaps)
    }

    /**
     * Review P2: a sound whose first packet lands between the render that completes the 60 s and the pause decision
     * must be played at once, not left queued until a later packet wakes the writer. Sweeps the first packet's arrival
     * over one burst; returns the longest delay (frames) from that packet to the sound being heard.
     */
    private fun worstDelayAtTheThreshold(guard: Boolean): Long {
        var worst = 0L
        for (o in 0 until 240 step 4) {
            val second = 60 * sec + 4_400 + o // its first packet arrives around the render that completes 60 s of silence
            val tab = Tablet(240, host(listOf(0L until 4_800L, second until second + 4_800L)), IdlePause.Mode.PAUSE, 48 * 30L)
            tab.guardNewPackets = guard
            tab.run(second + 3 * sec)
            assertEquals(2, tab.starts.size)
            worst = maxOf(worst, tab.starts[1].second - tab.starts[1].first)
        }
        return worst
    }

    @Test fun aPacketQueuedJustBeforeThePauseDecisionIsPlayedAtOnce() {
        val worst = worstDelayAtTheThreshold(guard = true)
        assertTrue("worst delay $worst frames", worst <= 48 * 50L)
    }

    @Test fun withoutTheGuardThatPacketWaitsForTheNextOne() {
        // documents the race the guard closes: the writer parks with the packet queued and a later packet wakes it
        assertTrue(worstDelayAtTheThreshold(guard = false) > worstDelayAtTheThreshold(guard = true))
    }

    @Test fun noPauseWhileTheSoundContinues() {
        val tab = Tablet(240, host(listOf(0L until 90 * sec)), IdlePause.Mode.PAUSE, 48 * 30L)
        tab.run(90 * sec)
        assertEquals(0, tab.pauses)
        assertEquals(0L, tab.core.drift.underruns)
    }
}
