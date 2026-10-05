package dev.matebridge.client.video

/**
 * Decision 0034 / PROTOCOL.md 0x03 "packed full colour": the AVC444v2 sample layout (MS-RDPEGFX 3.3.8.3.3, FreeRDP
 * `prim_YUV.c`; host side `probes/yuv444-probe` `AVC444v2.pack`, main chroma mode `pick`). Pure Kotlin: this is the
 * reference of the GLSL merge pass in `cpp/mbfullchroma.cpp` (same expressions, same order) and is tested against a
 * Kotlin copy of the packer.
 *
 * Main view: an ordinary 4:2:0 picture, Y = Y444, Cb/Cr = the (even column, even row) chroma sample.
 * Auxiliary view (also 4:2:0, size W x H, W % 4 == 0, H % 2 == 0), q = W / 4:
 *  - aux Y, x < W/2:  Cb444[2x + 1, y];   x >= W/2: Cr444[2(x - W/2) + 1, y]      (every odd column, every row)
 *  - aux Cb, x < W/4: Cb444[4x, 2j + 1];  x >= W/4: Cr444[4(x - W/4), 2j + 1]      (odd rows, columns = 0 mod 4)
 *  - aux Cr, x < W/4: Cb444[4x + 2, 2j + 1]; x >= W/4: Cr444[4(x - W/4) + 2, 2j + 1] (odd rows, columns = 2 mod 4)
 * where aux Cb/Cr are the W/2 x H/2 chroma planes of the auxiliary picture.
 */
object Avc444v2 {
    /** Where a full-resolution chroma sample is stored. Coordinates are in that plane's own sample grid. */
    enum class Plane { MAIN_CHROMA, AUX_LUMA, AUX_CB, AUX_CR }

    /** One chroma sample's home: [plane], [x], [y] (main/aux chroma planes: W/2 x H/2; aux luma: W x H). */
    data class Home(val plane: Plane, val x: Int, val y: Int)

    fun isValid(w: Int, h: Int) = w > 0 && h > 0 && w % 4 == 0 && h % 2 == 0

    /**
     * Home of Cb ([cr] false) or Cr ([cr] true) at full-resolution pixel ([px], [py]) of a [w] wide picture. For
     * [Plane.MAIN_CHROMA] both Cb and Cr come from the main picture's own Cb/Cr planes at (x, y).
     */
    fun home(px: Int, py: Int, w: Int, cr: Boolean): Home {
        val half = w / 2
        return when {
            px and 1 == 1 -> { // odd column: auxiliary luma, left half Cb, right half Cr
                val ax = (px - 1) shr 1
                Home(Plane.AUX_LUMA, if (cr) ax + half else ax, py)
            }
            py and 1 == 0 -> Home(Plane.MAIN_CHROMA, px shr 1, py shr 1) // (even, even): the main picture
            else -> { // even column, odd row: auxiliary chroma planes
                val j = (py - 1) shr 1
                val second = px and 3 == 2 // columns = 2 mod 4 live in aux Cr, = 0 mod 4 in aux Cb
                val x = if (second) (px - 2) shr 2 else px shr 2
                val q = w shr 2
                Home(if (second) Plane.AUX_CR else Plane.AUX_CB, if (cr) x + q else x, j)
            }
        }
    }
}

/**
 * The YCbCr -> RGB conversion of the merge shader as uniforms (the shader works on raw decoder samples, so range and
 * matrix are applied here, from `STREAM_CONFIG.matrix` / `full_range`). `r = y' + crR * cr'`, `g = y' + cbG * cb' +
 * crG * cr'`, `b = y' + cbB * cb'` with `y' = (y - yOffset) * yScale`, `c' = (c - 128/255) * cScale`; samples in 0..1.
 */
data class YuvConversion(
    val yOffset: Float, val yScale: Float, val cScale: Float,
    val crR: Float, val cbG: Float, val crG: Float, val cbB: Float,
) {
    /** `[r, g, b]` for raw samples [y], [cb], [cr] in 0..1 (CPU reference of the shader; not clamped). */
    fun toRgb(y: Float, cb: Float, cr: Float): FloatArray {
        val yy = (y - yOffset) * yScale
        val u = (cb - CHROMA_MID) * cScale
        val v = (cr - CHROMA_MID) * cScale
        return floatArrayOf(yy + crR * v, yy + cbG * u + crG * v, yy + cbB * u)
    }

    /** The seven uniforms in the order of the native `setConversion` call. */
    fun toArray(): FloatArray = floatArrayOf(yOffset, yScale, cScale, crR, cbG, crG, cbB)

    companion object {
        const val CHROMA_MID = 128f / 255f

        /** H.273 matrix_coefficients: 1 = BT.709, 6 = BT.601, 9 = BT.2020 NCL. Anything else is treated as BT.709. */
        fun of(matrix: Int, fullRange: Boolean): YuvConversion {
            val (kr, kb) = when (matrix) {
                6 -> 0.299 to 0.114
                9 -> 0.2627 to 0.0593
                else -> 0.2126 to 0.0722
            }
            val kg = 1.0 - kr - kb
            val crR = 2.0 * (1.0 - kr)
            val cbB = 2.0 * (1.0 - kb)
            return YuvConversion(
                yOffset = if (fullRange) 0f else 16f / 255f,
                yScale = if (fullRange) 1f else 255f / 219f,
                cScale = if (fullRange) 1f else 255f / 224f,
                crR = crR.toFloat(),
                cbG = (-(kb / kg) * cbB).toFloat(),
                crG = (-(kr / kg) * crR).toFloat(),
                cbB = cbB.toFloat(),
            )
        }
    }
}
