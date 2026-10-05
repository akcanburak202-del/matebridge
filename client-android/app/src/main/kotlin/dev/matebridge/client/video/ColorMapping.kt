package dev.matebridge.client.video

/**
 * Maps H.273 codes from STREAM_CONFIG to MediaFormat KEY_COLOR_* values. Constants are inlined
 * (android.media.MediaFormat.COLOR_*) so this stays JVM-testable. Null means "leave unset".
 */
object ColorMapping {
    const val STANDARD_BT709 = 1
    const val STANDARD_BT601_NTSC = 4
    const val STANDARD_BT2020 = 6
    const val TRANSFER_SDR_VIDEO = 3
    const val TRANSFER_ST2084 = 6
    const val TRANSFER_HLG = 7
    const val RANGE_FULL = 1
    const val RANGE_LIMITED = 2

    fun standard(matrix: Int): Int? = when (matrix) {
        1 -> STANDARD_BT709
        5, 6 -> STANDARD_BT601_NTSC
        9, 10 -> STANDARD_BT2020
        else -> null
    }

    /** Android has no sRGB transfer constant; sRGB (13) is treated as SDR video. */
    fun transfer(code: Int): Int? = when (code) {
        1, 6, 13 -> TRANSFER_SDR_VIDEO
        16 -> TRANSFER_ST2084
        18 -> TRANSFER_HLG
        else -> null
    }

    fun range(fullRange: Int): Int = if (fullRange == 1) RANGE_FULL else RANGE_LIMITED

    /**
     * MediaFormat has no primaries key: [primaries] is conveyed only where [standard] implies it, i.e. BT.709 (1) with
     * the BT.709 matrix, and BT.2020 (9, HDR10, decision 0032) with a BT.2020 matrix. Anything else (e.g. Display P3) is
     * decoded but not tagged.
     */
    fun primariesConveyed(primaries: Int, matrix: Int): Boolean = when (primaries) {
        1 -> true
        9 -> standard(matrix) == STANDARD_BT2020
        else -> false
    }
}
