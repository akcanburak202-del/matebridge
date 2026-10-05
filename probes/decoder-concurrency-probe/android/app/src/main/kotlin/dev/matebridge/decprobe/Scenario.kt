package dev.matebridge.decprobe

/**
 * A run: N decoder sessions started together, each looping one clip.
 *
 * Notation (`--es scenarios`, comma separated): `NxCLIP` repeats a clip N times, except `half`, which alternates the
 * left and right halves (`2xhalf` = half + half_right, the real split-screen case; `3xhalf` = half + half_right +
 * half). An explicit list uses `+` (`full+quarter`). Clip ids are the file-name prefixes made by `decprobe-clips`.
 */
data class Scenario(val name: String, val clips: List<String>) {
    companion object {
        const val DEFAULT = "1xfull,2xfull,1xhalf,2xhalf,3xhalf"
        private val REPEAT = Regex("""^(\d+)x([a-z_]+)$""")
        private val ID = Regex("""^[a-z_]+$""")

        fun parse(token: String): Scenario? {
            val t = token.trim()
            REPEAT.matchEntire(t)?.let { m ->
                val n = m.groupValues[1].toInt()
                val id = m.groupValues[2]
                if (n !in 1..8) return null
                val clips = List(n) { i -> if (id == "half" && i % 2 == 1) "half_right" else id }
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

/** A clip file `<id>_<W>x<H>.h265` (the decode size comes from the name). */
data class ClipFile(val id: String, val fileName: String, val width: Int, val height: Int) {
    companion object {
        private val NAME = Regex("""^([a-z_]+?)_(\d+)x(\d+)\.h265$""")

        fun parse(fileName: String): ClipFile? {
            val m = NAME.matchEntire(fileName) ?: return null
            return ClipFile(m.groupValues[1], fileName, m.groupValues[2].toInt(), m.groupValues[3].toInt())
        }

        fun find(fileNames: Collection<String>, id: String): ClipFile? =
            fileNames.mapNotNull { parse(it) }.firstOrNull { it.id == id }
    }
}
