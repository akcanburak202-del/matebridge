package dev.matebridge.aaudioprobe

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.abs

class ToneGenTest {
    @Test
    fun peakIsMinus40dBFSAndChannelsMatch() {
        val g = ToneGen(48_000, ToneGen.AMPLITUDE_M40_DBFS)
        val frames = 480 // 10 cycles of 1 kHz
        val buf = ShortArray(frames * 2)
        g.fill(buf, frames, 2)
        val peak = buf.maxOf { abs(it.toInt()) }
        assertEquals(328, peak) // 0.01 * 32767, rounded
        for (f in 0 until frames) assertEquals(buf[2 * f], buf[2 * f + 1])
    }

    @Test
    fun phaseContinuesAcrossCalls() {
        val g = ToneGen(48_000, 0.5f)
        val a = ShortArray(24)
        val b = ShortArray(24)
        g.fill(a, 24, 1) // half a cycle
        g.fill(b, 24, 1) // second half: negative lobe
        assertTrue(a.all { it >= 0 })
        assertTrue(b.all { it <= 0 })
    }
}
