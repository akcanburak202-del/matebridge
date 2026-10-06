package dev.matebridge.client.cursor

/**
 * Cheap, allocation-free look at a PNG's header: a compressed 60 KB image can decode to a huge bitmap, so the size is
 * checked **before** any decoder runs (decision 0036: shapes are at most 128 x 128 pixels).
 */
object PngInfo {
    private val SIGNATURE = byteArrayOf(0x89.toByte(), 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A)

    /** Width and height from the IHDR chunk, or null when [data] does not start with a PNG signature and an IHDR chunk. */
    fun dimensions(data: ByteArray): Pair<Int, Int>? {
        if (data.size < 24) return null
        for (i in SIGNATURE.indices) if (data[i] != SIGNATURE[i]) return null
        // chunk length (4) must be 13, type "IHDR"
        if (u32(data, 8) != 13L) return null
        if (data[12] != 'I'.code.toByte() || data[13] != 'H'.code.toByte() || data[14] != 'D'.code.toByte() || data[15] != 'R'.code.toByte()) return null
        val w = u32(data, 16)
        val h = u32(data, 20)
        if (w <= 0 || h <= 0 || w > Int.MAX_VALUE || h > Int.MAX_VALUE) return null
        return w.toInt() to h.toInt()
    }

    private fun u32(b: ByteArray, o: Int): Long =
        ((b[o].toLong() and 0xFF) shl 24) or ((b[o + 1].toLong() and 0xFF) shl 16) or
            ((b[o + 2].toLong() and 0xFF) shl 8) or (b[o + 3].toLong() and 0xFF)
}
