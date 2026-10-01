package dev.matebridge.client.audio

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.abs

class AudioRampTest {
    private fun full(frames: Int) = ShortArray(frames * 2) { 10_000 }

    @Test fun startsSilent() {
        val r = AudioRamp()
        assertTrue(r.isSilent)
        val b = full(10)
        r.apply(b, 10)
        assertTrue(b.all { it == 0.toShort() })
    }

    @Test fun fadeInIsMonotonicAndReachesUnity() {
        val r = AudioRamp()
        r.fadeIn(240)
        val b = full(300)
        r.apply(b, 300)
        for (f in 0 until 299) assertTrue(b[(f + 1) * 2] >= b[f * 2])
        // no step bigger than one ramp increment: no click
        for (f in 0 until 299) assertTrue(abs(b[(f + 1) * 2] - b[f * 2]) <= 10_000 / 240 + 1)
        assertEquals(10_000.toShort(), b[250 * 2])
        assertFalse(r.isRamping)
    }

    @Test fun fadeOutAcrossBurstsEndsSilent() {
        val r = AudioRamp()
        r.fadeIn(0)
        r.fadeOut(144)
        val a = full(96)
        r.apply(a, 96)
        assertFalse(r.isSilent)
        val b = full(96)
        r.apply(b, 96)
        assertTrue(r.isSilent)
        assertTrue(a[0] > b[0])
        assertEquals(0.toShort(), b[95 * 2])
        for (f in 0 until 95) assertTrue(a[(f + 1) * 2] <= a[f * 2])
    }

    @Test fun unityGainLeavesSamplesUntouched() {
        val r = AudioRamp()
        r.fadeIn(0)
        val b = ShortArray(20) { (it * 1000 - 9000).toShort() }
        val copy = b.copyOf()
        r.apply(b, 10)
        assertTrue(b.contentEquals(copy))
    }
}
