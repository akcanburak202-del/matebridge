package dev.matebridge.hdrprobe

import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * MediaFormat.KEY_HDR_STATIC_INFO payload: CTA-861.3 Static Metadata Descriptor Type 1, 25 bytes, little-endian.
 * Layout: u8 descriptor id (0), then u16 R.x R.y G.x G.y B.x B.y W.x W.y (units 0.00002),
 * u16 max mastering luminance (cd/m²), u16 min mastering luminance (0.0001 cd/m²), u16 MaxCLL, u16 MaxFALL.
 * Pure JVM so it is unit-testable.
 */
object HdrStaticInfo {
    data class Metadata(
        val rx: Double, val ry: Double, val gx: Double, val gy: Double,
        val bx: Double, val by: Double, val wx: Double, val wy: Double,
        val maxNits: Int, val minNits: Double, val maxCll: Int, val maxFall: Int,
    )

    /** Same values the Mac probe writes into the HEVC SEI (Display P3 D65, 1000 nits). */
    val P3_D65_1000 = Metadata(0.680, 0.320, 0.265, 0.690, 0.150, 0.060, 0.3127, 0.3290, 1000, 0.0001, 1000, 400)

    private fun chroma(v: Double): Short = Math.round(v / 0.00002).toInt().toShort()

    fun encode(m: Metadata): ByteArray {
        val b = ByteBuffer.allocate(25).order(ByteOrder.LITTLE_ENDIAN)
        b.put(0.toByte())
        for (v in listOf(m.rx, m.ry, m.gx, m.gy, m.bx, m.by, m.wx, m.wy)) b.putShort(chroma(v))
        b.putShort(m.maxNits.toShort())
        b.putShort(Math.round(m.minNits / 0.0001).toInt().toShort())
        b.putShort(m.maxCll.toShort())
        b.putShort(m.maxFall.toShort())
        return b.array()
    }
}
