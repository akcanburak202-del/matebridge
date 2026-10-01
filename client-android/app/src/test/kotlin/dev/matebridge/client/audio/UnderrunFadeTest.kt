package dev.matebridge.client.audio

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.roundToInt
import kotlin.math.sin
import org.junit.Test

/**
 * T-108: when the jitter buffer runs dry (a network stall: late packets, continuous sample index), [PlayoutCore] must
 * not cut the output hard. It fades the last frames it has to zero ([PlayoutCore.FADE_OUT_MS]), plays silence, and
 * fades back in ([PlayoutCore.FADE_IN_MS]). Checked as the largest step between consecutive output samples: a hard cut
 * of a full-scale signal would jump by the whole amplitude.
 */
class UnderrunFadeTest {
    private val amp = 16_000

    /** 10 ms packets; the host sends packet k when its last frame is captured, the network adds [transit] frames. */
    private class Result(val out: IntArray, val underruns: Long)

    private fun run(burst: Int, signal: (Long) -> Int, stallAt: Long, stallFrames: Long, totalFrames: Long): Result {
        val core = PlayoutCore()
        val transit = 96L
        val pkt = 480
        val bytes = ByteArray(pkt * 4)
        val out = ShortArray(burst * 2)
        val collected = ArrayList<Int>()
        var nextPkt = 0L
        var now = 0L
        while (now < totalFrames) {
            while (true) {
                val sent = (nextPkt + 1) * pkt + transit
                val arrival = if (sent in stallAt until stallAt + stallFrames) stallAt + stallFrames else sent
                if (arrival > now) break
                for (f in 0 until pkt) {
                    val v = signal(nextPkt * pkt + f)
                    for (c in 0 until 2) {
                        val i = (f * 2 + c) * 2
                        bytes[i] = (v and 0xFF).toByte()
                        bytes[i + 1] = (v shr 8).toByte()
                    }
                }
                core.buffer.write(nextPkt * pkt, nextPkt * pkt * 1_000_000L / 48_000, bytes, pkt)
                nextPkt++
            }
            core.render(out, burst)
            for (f in 0 until burst) {
                assertEquals("channels stay equal", out[f * 2], out[f * 2 + 1])
                collected += out[f * 2].toInt()
            }
            now += burst
        }
        return Result(collected.toIntArray(), core.drift.underruns)
    }

    private fun maxStep(o: IntArray): Int = (1 until o.size).maxOf { abs(o[it] - o[it - 1]) }

    /** Indexes of the first silent run of at least [minRun] samples after [from], or null. */
    private fun silentRun(o: IntArray, from: Int, minRun: Int): IntRange? {
        var start = -1
        for (i in from until o.size) {
            if (o[i] == 0) {
                if (start < 0) start = i
                if (i - start + 1 >= minRun) {
                    var end = i
                    while (end + 1 < o.size && o[end + 1] == 0) end++
                    return start..end
                }
            } else start = -1
        }
        return null
    }

    private fun checkFadesAround(o: IntArray, burst: Int, sound: Boolean) {
        val playing = 48_000 / 2 // well after the start
        val hole = silentRun(o, playing, minRun = burst)
        assertTrue("the stall produced a silent hole", hole != null)
        hole!!
        // Before the hole the output fades over ~3 ms rather than dropping: the samples just before it are small...
        val fadeOut = PlayoutCore.FADE_OUT_MS * 48
        val before = o.copyOfRange(hole.first - fadeOut, hole.first)
        if (!sound) {
            assertTrue("full level ${fadeOut} frames before the hole", abs(o[hole.first - fadeOut - 1]) > amp * 9 / 10)
            assertTrue("fade-out is monotonic", (1 until before.size).all { before[it] <= before[it - 1] })
        }
        assertTrue("last sample before the hole is near zero", abs(before.last()) <= amp / 100)
        // ...and comes back with a fade-in.
        val fadeIn = PlayoutCore.FADE_IN_MS * 48
        val after = o.copyOfRange(hole.last + 1, hole.last + 1 + fadeIn)
        assertTrue("first sample after the hole is near zero", abs(after.first()) <= amp / 100)
        if (!sound) assertTrue("fade-in is monotonic", (1 until after.size).all { after[it] >= after[it - 1] })
    }

    @Test fun dcSignalFadesOutAndInWithoutAJumpAaudioBurst() = dcCase(burst = 240)

    @Test fun dcSignalFadesOutAndInWithoutAJumpTrackBurst() = dcCase(burst = 960)

    private fun dcCase(burst: Int) {
        val r = run(burst, { amp }, stallAt = 48_000, stallFrames = 4_800, totalFrames = 96_000)
        assertEquals("the stall is a real underrun", 1L, r.underruns)
        checkFadesAround(r.out, burst, sound = false)
        // A hard cut would step by the whole amplitude; the ramps step by at most amp / fade length.
        val limit = amp / (PlayoutCore.FADE_OUT_MS * 48) + 2
        assertTrue("max step ${maxStep(r.out)} <= $limit", maxStep(r.out) <= limit)
    }

    @Test fun sineFadesOutAndInWithoutAJumpAaudioBurst() = sineCase(burst = 240)

    @Test fun sineFadesOutAndInWithoutAJumpTrackBurst() = sineCase(burst = 960)

    private fun sineCase(burst: Int) {
        val hz = 1_000.0
        val sine = { i: Long -> (amp * sin(2 * PI * hz * i / 48_000)).roundToInt() }
        val r = run(burst, sine, stallAt = 48_000, stallFrames = 4_800, totalFrames = 96_000)
        assertEquals(1L, r.underruns)
        checkFadesAround(r.out, burst, sound = true)
        // Steepest slope of the sine itself (slightly more under the drift resampler) plus the ramp's own step.
        val natural = 2 * PI * hz * amp / 48_000
        val limit = (natural * 1.02 + amp / (PlayoutCore.FADE_OUT_MS * 48) + 4).toInt()
        assertTrue("max step ${maxStep(r.out)} <= $limit", maxStep(r.out) <= limit)
    }
}
