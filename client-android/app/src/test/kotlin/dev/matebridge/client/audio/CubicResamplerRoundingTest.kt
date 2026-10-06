package dev.matebridge.client.audio

import org.junit.Assert.assertEquals
import org.junit.Test
import java.util.Random
import kotlin.math.roundToInt

/** T-284: the inlined rounding and clamping is bit-identical to the former `roundToInt().coerceIn()` formula. */
class CubicResamplerRoundingTest {
    private fun reference(y: Float): Short =
        y.roundToInt().coerceIn(Short.MIN_VALUE.toInt(), Short.MAX_VALUE.toInt()).toShort()

    private fun check(y: Float) = assertEquals("y=$y", reference(y), toS16(y))

    @Test fun halfBoundariesAndEdges() {
        val specials = floatArrayOf(
            0f, -0f, 0.5f, -0.5f, 1.5f, -1.5f, 2.5f, -2.5f, 0.49999997f, -0.49999997f, 0.50000006f, -0.50000006f,
            32766.5f, 32766.4990f, 32766.502f, 32767f, 32767.5f, 32768f, 40000f, 1e9f, Float.MAX_VALUE,
            Float.POSITIVE_INFINITY, -32767.5f, -32768f, -32768.5f, -32768.49f, -32768.51f, -32769f, -40000f, -1e9f,
            -Float.MAX_VALUE, Float.NEGATIVE_INFINITY, Float.MIN_VALUE, -Float.MIN_VALUE,
        )
        for (y in specials) check(y)
        // Every float within a few ulps of each half-integer in the s16 range and just beyond it.
        for (k in -32770..32770) {
            val half = k + 0.5f
            var lo = half
            var hi = half
            for (i in 0 until 4) {
                lo = Math.nextDown(lo)
                hi = Math.nextUp(hi)
                check(lo)
                check(hi)
            }
            check(half)
            check(k.toFloat())
            check(Math.nextUp(k.toFloat()))
            check(Math.nextDown(k.toFloat()))
        }
    }

    @Test fun randomValues() {
        val rnd = Random(284)
        repeat(1_000_000) {
            // Mix of uniform values over a range wider than s16 and values on a 1/4 grid (many exact halves).
            val y = if (it % 2 == 0) (rnd.nextFloat() * 2f - 1f) * 33_000f else (rnd.nextInt(280_000) - 140_000) / 4f
            check(y)
        }
    }

    @Test fun processMatchesFormerImplementation() {
        val rnd = Random(2840)
        val ch = 2
        val inFrames = 60_000
        val input = ShortArray(inFrames * ch) {
            when (rnd.nextInt(4)) {
                0 -> Short.MAX_VALUE
                1 -> Short.MIN_VALUE
                else -> (rnd.nextInt(65536) - 32768).toShort()
            }
        }
        for (step in doubleArrayOf(1.0, 0.995, 1.005, 1.0013)) {
            val fast = CubicResampler(ch)
            val ref = ReferenceResampler(ch)
            val a = ShortArray(480 * ch)
            val b = ShortArray(480 * ch)
            var pos = 0
            var total = 0
            while (total < 100_000) {
                val need = fast.inputNeeded(480, step)
                val n = minOf(need, inFrames - pos)
                val chunk = input.copyOfRange(pos * ch, (pos + n) * ch)
                val ua = fast.process(a, 480, step, chunk, n)
                val ub = ref.process(b, 480, step, chunk, n)
                assertEquals(ub, ua)
                for (i in a.indices) assertEquals("step=$step total=$total i=$i", b[i], a[i])
                pos += ua
                total += 480
                if (inFrames - pos < 1000) pos = 0
            }
        }
    }

    /** The resampler as it was before T-284 (stdlib rounding), as the oracle. */
    private class ReferenceResampler(private val channels: Int) {
        private val w = FloatArray(4 * channels)
        private var frac = 0.0

        fun process(out: ShortArray, outFrames: Int, step: Double, input: ShortArray, inFrames: Int): Int {
            var consumed = 0
            val ch = channels
            for (j in 0 until outFrames) {
                val t = frac.toFloat()
                for (c in 0 until ch) {
                    val xm1 = w[c]
                    val x0 = w[ch + c]
                    val x1 = w[2 * ch + c]
                    val x2 = w[3 * ch + c]
                    val c1 = 0.5f * (x1 - xm1)
                    val c2 = xm1 - 2.5f * x0 + 2f * x1 - 0.5f * x2
                    val c3 = 0.5f * (x2 - xm1) + 1.5f * (x0 - x1)
                    val y = ((c3 * t + c2) * t + c1) * t + x0
                    out[j * ch + c] =
                        y.roundToInt().coerceIn(Short.MIN_VALUE.toInt(), Short.MAX_VALUE.toInt()).toShort()
                }
                frac += step
                while (frac >= 1.0) {
                    System.arraycopy(w, ch, w, 0, 3 * ch)
                    if (consumed < inFrames) {
                        for (c in 0 until ch) w[3 * ch + c] = input[consumed * ch + c].toFloat()
                        consumed++
                    } else {
                        for (c in 0 until ch) w[3 * ch + c] = 0f
                    }
                    frac -= 1.0
                }
            }
            return consumed
        }
    }
}
