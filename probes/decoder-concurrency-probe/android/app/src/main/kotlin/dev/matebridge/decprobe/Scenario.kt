package dev.matebridge.decprobe

/**
 * A run: N decoder sessions started together, each looping one clip.
 *
 * Notation (`--es scenarios`, comma separated): `NxCLIP` repeats a clip N times, except `half` clips, which alternate
 * the left and right halves (`2xhalf` = half + half_right, the real split-screen case; `3xhalf` = half + half_right +
 * half). An explicit list uses `+` (`full+quarter`). Clip ids are the file names without the size: `full` for the
 * T-248 files (`full_2800x1840.h265`), `full_10pq_100m` / `full_8_60m_idr60` for the T-249 files
 * (`full_2800x1840_10pq_100m.h265`).
 */
data class Scenario(val name: String, val clips: List<String>) {
    companion object {
        const val DEFAULT = "1xfull,2xfull,1xhalf,2xhalf,3xhalf"
        private val REPEAT = Regex("""^(\d+)x([a-z][a-z0-9_]*)$""")
        private val ID = Regex("""^[a-z][a-z0-9_]*$""")

        /** The right-half partner of a left-half clip id (`half` -> `half_right`, `half_10pq_30m` -> `half_right_10pq_30m`). */
        fun rightHalf(id: String): String =
            if (id == "half" || (id.startsWith("half_") && !id.startsWith("half_right"))) "half_right" + id.removePrefix("half")
            else id

        private fun isLeftHalf(id: String) = rightHalf(id) != id

        fun parse(token: String): Scenario? {
            val t = token.trim()
            REPEAT.matchEntire(t)?.let { m ->
                val n = m.groupValues[1].toInt()
                val id = m.groupValues[2]
                if (n !in 1..8) return null
                val clips = List(n) { i -> if (i % 2 == 1 && isLeftHalf(id)) rightHalf(id) else id }
                return Scenario(t, clips)
            }
            val parts = t.split('+')
            if (parts.isEmpty() || parts.size > 8 || parts.any { !ID.matches(it) }) return null
            return Scenario(t, parts)
        }

        /** Parses a comma list; unknown tokens are returned in the second list. */
        fun parseList(spec: String): Pair<List<Scenario>, List<String>> {
            val ok = ArrayList<Scenario>()
            val bad = ArrayList<String>()
            for (tok in spec.split(',').map { it.trim() }.filter { it.isNotEmpty() }) {
                parse(tok)?.let { ok.add(it) } ?: bad.add(tok)
            }
            return ok to bad
        }
    }
}

/**
 * A clip file. T-248 names are `<id>_<W>x<H>.h265`; T-249 names are `<id>_<W>x<H>_<depth>_<N>m[_idr<K>].h265` with
 * depth `8`, `10sdr` or `10pq`, N the target Mbps of the clip and K the IDR interval in frames. The decode size comes
 * from the name. [id] is what scenarios use: the name without the size (`full_10pq_100m`).
 */
data class ClipFile(
    val id: String,
    val fileName: String,
    val width: Int,
    val height: Int,
    /** Crop name (`full`, `half`, `half_right`, `quarter`). */
    val base: String = id,
    /** `8`, `10sdr` or `10pq`; legacy files are 8-bit. */
    val depth: String = "8",
    /** Target Mbps from the name; 0 for legacy files. */
    val mbps: Int = 0,
    /** IDR every N frames; 0 = a single IDR. */
    val idrInterval: Int = 0,
) {
    val bitDepth: Int get() = if (depth == "8") 8 else 10

    /** HEVC profile this clip needs from the decoder. */
    val profileName: String
        get() = when (depth) { "10pq" -> "Main10HDR10"; "10sdr" -> "Main10"; else -> "Main" }

    companion object {
        private val NAME = Regex("""^([a-z][a-z_]*?)_(\d+)x(\d+)(?:_(8|10sdr|10pq)_(\d+)m(?:_idr(\d+))?)?\.h265$""")

        fun parse(fileName: String): ClipFile? {
            val m = NAME.matchEntire(fileName) ?: return null
            val base = m.groupValues[1]
            val depth = m.groupValues[4]
            val mbps = m.groupValues[5].toIntOrNull() ?: 0
            val idr = m.groupValues[6].toIntOrNull() ?: 0
            val id = if (depth.isEmpty()) base else base + "_" + depth + "_" + mbps + "m" + (if (idr > 0) "_idr$idr" else "")
            return ClipFile(id, fileName, m.groupValues[2].toInt(), m.groupValues[3].toInt(), base,
                depth.ifEmpty { "8" }, mbps, idr)
        }

        fun find(fileNames: Collection<String>, id: String): ClipFile? =
            fileNames.mapNotNull { parse(it) }.firstOrNull { it.id == id }
    }
}

/** HEVC profile names for `MediaCodecInfo.CodecProfileLevel.profile` values (the constants are plain ints). */
object HevcProfiles {
    fun name(profile: Int): String = when (profile) {
        0x01 -> "Main"
        0x02 -> "Main10"
        0x04 -> "MainStill"
        0x1000 -> "Main10HDR10"
        0x2000 -> "Main10HDR10Plus"
        else -> "0x" + Integer.toHexString(profile)
    }

    /** Distinct names in a stable order (Main, Main10, Main10HDR10, ...). */
    fun names(profiles: Collection<Int>): List<String> = profiles.toSortedSet().map { name(it) }

    /** The profile constant to ask the decoder for (`MediaFormat.KEY_PROFILE`) for a clip depth. */
    fun forClip(file: ClipFile): Int = when (file.depth) { "10pq" -> 0x1000; "10sdr" -> 0x02; else -> 0x01 }
}

/** `--es imgfmt`: the ImageReader pixel format of the `image` output (default PRIVATE, like a SurfaceView buffer). */
object ImgFormat {
    const val PRIVATE = 0x22          // ImageFormat.PRIVATE
    const val YCBCR_P010 = 54         // ImageFormat.YCBCR_P010 (API 33)
    const val RGBA_1010102 = 0x2b     // HardwareBuffer.RGBA_1010102
    const val RGBA_8888 = 1           // HardwareBuffer.RGBA_8888

    fun parse(s: String?): Pair<String, Int>? = when (s?.trim()?.lowercase() ?: "private") {
        "private" -> "private" to PRIVATE
        "p010" -> "p010" to YCBCR_P010
        "rgba1010102" -> "rgba1010102" to RGBA_1010102
        "rgba8888" -> "rgba8888" to RGBA_8888
        else -> null
    }
}
