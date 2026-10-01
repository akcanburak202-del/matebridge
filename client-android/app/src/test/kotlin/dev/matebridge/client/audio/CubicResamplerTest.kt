package dev.matebridge.client.audio

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.sin
import kotlin.math.sqrt

class CubicResamplerTest {
    private fun sine(frames: Int, hz: Double, amp: Double): ShortArray = ShortArray(frames * 2) {
        val f = it / 2
        (amp * sin(2 * PI * hz * f / 48_000.0)).toInt().toShort()
    }

    /** Resamples [input] at [step] in bursts; returns the output (left channel). */
    private fun run(input: ShortArray, step: Double, outFrames: Int, burst: Int = 96): DoubleArray {
        val r = CubicResampler()
        val out = DoubleArray(outFrames)
        val buf = ShortArray(burst * 2)
        var pos = 0
        var done = 0
        val inFrames = input.size / 2
        while (done < outFrames) {
            val need = r.inputNeeded(burst, step)
            val n = minOf(need, inFrames - pos)
            val chunk = input.copyOfRange(pos * 2, (pos + n) * 2)
            pos += r.process(buf, burst, step, chunk, n)
            for (j in 0 until burst) if (done + j < outFrames) out[done + j] = buf[j * 2].toDouble()
            done += burst
        }
        return out
    }

    private fun relRmsError(hz: Double, step: Double): Double {
        val amp = 20_000.0
        val out = run(sine(60_000, hz, amp), step, 48_000)
        var err = 0.0
        var n = 0
        for (j in 100 until out.size) {
            // 3 frames of window delay (see CubicResampler)
            val expected = amp * sin(2 * PI * hz * (j * step - 3) / 48_000.0)
            err += (out[j] - expected) * (out[j] - expected)
            n++
        }
        return sqrt(err / n) / amp
    }

    @Test fun unitStepIsADelayedCopy() {
        val input = ShortArray(2000) { (it * 37 % 2000 - 1000).toShort() }
        val r = CubicResampler()
        val out = ShortArray(1000 * 2)
        val used = r.process(out, 1000, 1.0, input, 1000)
        assertEquals(1000, used)
        for (j in 3 until 1000) {
            assertEquals(input[(j - 3) * 2], out[j * 2])
            assertEquals(input[(j - 3) * 2 + 1], out[j * 2 + 1])
        }
    }

    @Test fun sineAtDriftRatiosHasLowDistortion() {
        for (step in doubleArrayOf(0.995, 0.999, 1.0, 1.001, 1.005)) {
            val e1k = relRmsError(1000.0, step)
            assertTrue("1 kHz step=$step err=$e1k", e1k < 1e-3) // better than -60 dB
            val e5k = relRmsError(5000.0, step)
            assertTrue("5 kHz step=$step err=$e5k", e5k < 1e-2)
        }
    }

    @Test fun consumptionFollowsTheRatio() {
        val r = CubicResampler()
        val input = ShortArray(200_000)
        val out = ShortArray(96 * 2)
        var used = 0L
        repeat(1000) { used += r.process(out, 96, 1.001, input, r.inputNeeded(96, 1.001)) }
        assertEquals(96_000 * 1.001, used.toDouble(), 2.0)
    }

    @Test fun exhaustedInputPullsZerosWithoutCountingThem() {
        val r = CubicResampler()
        val out = ShortArray(100 * 2)
        val used = r.process(out, 100, 1.0, ShortArray(20) { 1000 }, 10)
        assertEquals(10, used)
        assertTrue(abs(out[99 * 2].toInt()) == 0)
    }
}
