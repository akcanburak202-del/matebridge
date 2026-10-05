package dev.matebridge.yuv444probe

/**
 * Clip file names. The probe plays any `*.h265` / `*.hevc` Annex-B clip whose name carries `<W>x<H>`
 * (T-248/T-249 names such as `full_2800x1840_8_60m.h265`, T-255 v2 clips likewise). [id] is the name without extension.
 */
data class ClipName(val id: String, val fileName: String, val width: Int, val height: Int) {
    companion object {
        private val SIZE = Regex("""(\d{3,5})x(\d{3,5})""")
        private val EXT = Regex("""\.(h265|hevc)$""")

        fun parse(fileName: String): ClipName? {
            if (!EXT.containsMatchIn(fileName)) return null
            val m = SIZE.find(fileName) ?: return null
            return ClipName(fileName.replace(EXT, ""), fileName, m.groupValues[1].toInt(), m.groupValues[2].toInt())
        }

        /** Resolves a user-given clip: exact file name, exact id, or (unique-first) prefix of the id. */
        fun find(fileNames: Collection<String>, spec: String): ClipName? {
            val all = fileNames.mapNotNull { parse(it) }.sortedBy { it.fileName }
            return all.firstOrNull { it.fileName == spec } ?: all.firstOrNull { it.id == spec }
                ?: all.firstOrNull { it.id.startsWith(spec) }
        }

        /** 10-bit T-249 clips (`_10pq_`, `_10sdr_`) are not usable here: the 4:4:4 packing is 8-bit Main. */
        fun is10Bit(c: ClipName) = c.id.contains("_10pq") || c.id.contains("_10sdr")

        /** The [index]-th 8-bit clip (sorted by name) of the given size, null if there are fewer. */
        fun ofSize(fileNames: Collection<String>, width: Int, height: Int, index: Int = 0): ClipName? =
            fileNames.mapNotNull { parse(it) }.filter { it.width == width && it.height == height && !is10Bit(it) }
                .sortedBy { it.fileName }.getOrNull(index)
    }
}

/** Test size shorthand: `full` = 2800x1840, `small` = 1848x1214 (the research's two sizes). */
object SizeSpec {
    fun parse(s: String?): Pair<Int, Int>? = when (s?.trim()?.lowercase() ?: "full") {
        "full" -> 2800 to 1840
        "small" -> 1848 to 1214
        else -> {
            val m = Regex("""^(\d{3,5})x(\d{3,5})$""").matchEntire(s!!.trim().lowercase())
            m?.let { it.groupValues[1].toInt() to it.groupValues[2].toInt() }
        }
    }
}
