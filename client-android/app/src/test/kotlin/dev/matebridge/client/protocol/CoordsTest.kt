package dev.matebridge.client.protocol

import kotlin.math.PI
import org.junit.Assert.assertEquals
import org.junit.Test

class CoordsTest {
    @Test
    fun normalizeEdgesAndClamp() {
        assertEquals(0, Coords.normalize(0f, 0f, 2800f))
        assertEquals(65535, Coords.normalize(2800f, 0f, 2800f))
        assertEquals(32768, Coords.normalize(1400f, 0f, 2800f)) // 32767.5 rounds up
        assertEquals(0, Coords.normalize(-50f, 0f, 2800f))
        assertEquals(65535, Coords.normalize(5000f, 0f, 2800f))
    }

    @Test
    fun normalizeSubtractsLetterboxBand() {
        // surface occupies x = 100..900
        assertEquals(0, Coords.normalize(100f, 100f, 800f))
        assertEquals(0, Coords.normalize(50f, 100f, 800f))
        assertEquals(65535, Coords.normalize(900f, 100f, 800f))
        assertEquals(32768, Coords.normalize(500f, 100f, 800f))
    }

    @Test
    fun normalizeDegenerate() {
        assertEquals(0, Coords.normalize(10f, 0f, 0f))
        assertEquals(0, Coords.normalize(Float.NaN, 0f, 100f))
    }

    @Test
    fun pressure() {
        assertEquals(0, Coords.pressure(0f))
        assertEquals(65535, Coords.pressure(1f))
        assertEquals(65535, Coords.pressure(1.7f))
        assertEquals(0, Coords.pressure(-0.2f))
        assertEquals(32768, Coords.pressure(0.5f))
        assertEquals(0, Coords.pressure(Float.NaN))
    }

    @Test
    fun signedTilt() {
        assertEquals(32767, Coords.signed(1f))
        assertEquals(-32767, Coords.signed(-1f))
        assertEquals(-32767, Coords.signed(-3f))
        assertEquals(0, Coords.signed(0f))
        assertEquals(16384, Coords.signed(0.5f))
        assertEquals(-1f, Coords.signedToFloat(-32768), 0f)
    }

    @Test
    fun penTiltDirections() {
        val h = (PI / 2).toFloat()
        // upright pen: no tilt
        val (ux, uy) = Coords.penTilt(0f, 1.2f)
        assertEquals(0f, ux, 1e-6f); assertEquals(0f, uy, 1e-6f)
        // orientation 0 (up), tilted 90 deg: tilt_y = -1 (top end toward -y)
        val (x0, y0) = Coords.penTilt(h, 0f)
        assertEquals(0f, x0, 1e-6f); assertEquals(-1f, y0, 1e-6f)
        // orientation +90 deg (clockwise = right): tilt_x = +1
        val (x1, y1) = Coords.penTilt(h, h)
        assertEquals(1f, x1, 1e-6f); assertEquals(0f, y1, 1e-6f)
        // orientation 180: top end toward the user, tilt_y = +1
        val (x2, y2) = Coords.penTilt(h, PI.toFloat())
        assertEquals(0f, x2, 1e-6f); assertEquals(1f, y2, 1e-6f)
        // orientation -90: tilt_x = -1
        val (x3, _) = Coords.penTilt(h, -h)
        assertEquals(-1f, x3, 1e-6f)
    }

    @Test
    fun roundingIsHalfAwayFromZero() {
        assertEquals(3, Coords.roundHalfAway(2.5))
        assertEquals(-3, Coords.roundHalfAway(-2.5))
        assertEquals(1, Coords.roundHalfAway(0.5))
        assertEquals(-1, Coords.roundHalfAway(-0.5))
        assertEquals(0, Coords.roundHalfAway(0.49))
        assertEquals(-2, Coords.roundHalfAway(-1.5))
        assertEquals(0, Coords.roundHalfAway(-0.0))
    }

    @Test
    fun exactTiesInConversions() {
        // 0.5 * 32767 = 16383.5 -> 16384; negative mirrors (Math.round would give -16383)
        assertEquals(16384, Coords.signed(0.5f))
        assertEquals(-16384, Coords.signed(-0.5f))
        // 0.5 * 65535 = 32767.5 -> 32768
        assertEquals(32768, Coords.pressure(0.5f))
        // px 1 of 2 is exactly half: 32767.5 -> 32768
        assertEquals(32768, Coords.normalize(1f, 0f, 2f))
        // tilt of -0.5/32767 is a 0.5 tie in i16 units
        assertEquals(-1, Coords.roundHalfAway(-0.5 / 32767.0 * 32767.0))
    }
}
