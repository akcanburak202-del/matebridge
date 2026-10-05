package dev.matebridge.decprobe

/**
 * HEVC Annex-B parsing for the clips made by `decprobe-clips`: split into NAL units, group into access units (one
 * coded picture each, with any parameter sets / SEI that precede it), and extract the leading VPS/SPS/PPS as csd-0.
 * Pure Kotlin (JVM tests).
 */
object AnnexB {
    /** One NAL unit: [codeStart] = offset of its start code, [payload] = first byte after the start code. */
    data class Nal(val codeStart: Int, val payload: Int, val end: Int)

    /** Byte range of one access unit (start codes included), ready to queue into a decoder input buffer. */
    data class Unit(val offset: Int, val length: Int)

    fun nals(data: ByteArray): List<Nal> {
        val starts = ArrayList<IntArray>()
        var i = 0
        val n = data.size
        while (i + 2 < n) {
            if (data[i].toInt() == 0 && data[i + 1].toInt() == 0 && data[i + 2].toInt() == 1) {
                val code = if (i > 0 && data[i - 1].toInt() == 0) i - 1 else i
                starts.add(intArrayOf(code, i + 3))
                i += 3
            } else {
                i++
            }
        }
        val out = ArrayList<Nal>(starts.size)
        for (k in starts.indices) {
            val end = if (k + 1 < starts.size) starts[k + 1][0] else n
            if (end > starts[k][1]) out.add(Nal(starts[k][0], starts[k][1], end))
        }
        return out
    }

    /** `nal_unit_type` (bits 1..6 of the first header byte). */
    fun type(data: ByteArray, nal: Nal): Int = (data[nal.payload].toInt() shr 1) and 0x3F

    fun isVcl(type: Int) = type in 0..31

    /** VCL NAL with `first_slice_segment_in_pic_flag` (first bit after the 2-byte header) set. */
    fun isFirstSlice(data: ByteArray, nal: Nal): Boolean =
        nal.end - nal.payload >= 3 && isVcl(type(data, nal)) && (data[nal.payload + 2].toInt() and 0x80) != 0

    /** Non-VCL types that start a new access unit when they follow a picture (H.265 7.4.2.4.4). */
    private fun startsAu(type: Int) = type in 32..35 || type == 39 || type in 41..44 || type in 48..55

    fun accessUnits(data: ByteArray): List<Unit> {
        val all = nals(data)
        val units = ArrayList<Unit>()
        var auStart = -1
        var seenVcl = false
        for (nal in all) {
            val t = type(data, nal)
            val boundary = seenVcl && (startsAu(t) || isFirstSlice(data, nal))
            if (auStart < 0) {
                auStart = nal.codeStart
            } else if (boundary) {
                units.add(Unit(auStart, nal.codeStart - auStart))
                auStart = nal.codeStart
                seenVcl = false
            }
            if (isVcl(t)) seenVcl = true
        }
        if (auStart >= 0 && seenVcl) units.add(Unit(auStart, data.size - auStart))
        return units
    }

    /** The VPS/SPS/PPS NAL units before the first picture, with start codes (MediaFormat `csd-0`); null if none. */
    fun codecConfig(data: ByteArray): ByteArray? {
        val out = java.io.ByteArrayOutputStream()
        for (nal in nals(data)) {
            val t = type(data, nal)
            if (isVcl(t)) break
            if (t in 32..34) {
                out.write(byteArrayOf(0, 0, 0, 1))
                out.write(data, nal.payload, nal.end - nal.payload)
            }
        }
        return if (out.size() > 0) out.toByteArray() else null
    }
}
