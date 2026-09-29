package dev.matebridge.client.protocol

import kotlin.math.cos
import kotlin.math.sin

/** Pure conversions for PROTOCOL.md section 1 and section 4 (PEN "Egim yonu"). */
object Coords {
    /**
     * Normalized axis coordinate: `round(clamp((px - origin) / size, 0, 1) * 65535)`.
     * [origin]/[size] describe the video surface on that axis (excluding letterbox bands).
     */
    fun normalize(px: Float, origin: Float, size: Float): Int {
        if (size <= 0f || px.isNaN()) return 0
        val t = ((px - origin).toDouble() / size).coerceIn(0.0, 1.0)
        return Math.round(t * 65535.0).toInt()
    }

    /** Pressure 0..1 to u16. */
    fun pressure(p: Float): Int {
        if (p.isNaN()) return 0
        return Math.round(p.toDouble().coerceIn(0.0, 1.0) * 65535.0).toInt()
    }

    /** Signed -1..1 to i16 `round(v * 32767)`; the result is within -32767..32767. */
    fun signed(v: Float): Int {
        if (v.isNaN()) return 0
        return Math.round(v.toDouble().coerceIn(-1.0, 1.0) * 32767.0).toInt()
    }

    /** Inverse of [signed], for decoding. */
    fun signedToFloat(v: Int): Float = v.coerceAtLeast(-32767) / 32767f

    /** Inverse of [pressure]. */
    fun pressureToFloat(v: Int): Float = v / 65535f

    /**
     * Provisional Android to protocol tilt (to be calibrated on the device).
     * [tiltRad] = AXIS_TILT (0 = upright), [orientationRad] = AXIS_ORIENTATION (0 = up, clockwise positive).
     * Returns (tilt_x, tilt_y) as floats in -1..1: x = sin(t) sin(o), y = -sin(t) cos(o).
     */
    fun penTilt(tiltRad: Float, orientationRad: Float): Pair<Float, Float> {
        val s = sin(tiltRad.toDouble())
        val x = s * sin(orientationRad.toDouble())
        val y = -s * cos(orientationRad.toDouble())
        return x.coerceIn(-1.0, 1.0).toFloat() to y.coerceIn(-1.0, 1.0).toFloat()
    }
}
