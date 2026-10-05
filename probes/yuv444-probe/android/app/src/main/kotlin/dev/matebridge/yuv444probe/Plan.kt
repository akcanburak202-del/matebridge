package dev.matebridge.yuv444probe

import java.nio.ByteBuffer

/** The tests the probe can run, in the order given by `--es test`. */
enum class TestKind(val key: String) {
    T2("t2"),
    T3("t3"),
    DIRECT("direct"),
    T1("t1"),
    T4("t4");

    companion object {
        const val DEFAULT = "t2,t1,direct,t3"

        /** Parses `t2,t3,...`; unknown tokens come back in the second list. */
        fun parseList(spec: String?): Pair<List<TestKind>, List<String>> {
            val ok = ArrayList<TestKind>()
            val bad = ArrayList<String>()
            for (tok in (spec ?: DEFAULT).split(',').map { it.trim().lowercase() }.filter { it.isNotEmpty() }) {
                val k = entries.firstOrNull { it.key == tok }
                if (k != null) ok.add(k) else bad.add(tok)
            }
            return ok to bad
        }
    }
}

/** GL pass of the presentation test (`--es gl`). */
enum class GlMode(val key: String, val native: Int) {
    OES("oes", 0),
    MAIN("main", 1),
    MERGE("merge", 2);

    companion object {
        fun parse(s: String?): GlMode? = entries.firstOrNull { it.key == (s?.trim()?.lowercase() ?: "merge") }
    }
}

/** Copies a stride-aware image plane into a tightly packed array. */
object PlaneCopy {
    fun tight(src: ByteBuffer, rowStride: Int, pixelStride: Int, width: Int, height: Int): ByteArray {
        val out = ByteArray(width * height)
        val base = src.duplicate()
        for (r in 0 until height) {
            val rowStart = r * rowStride
            if (pixelStride == 1) {
                base.position(rowStart)
                base.get(out, r * width, width)
            } else {
                for (c in 0 until width) out[r * width + c] = base.get(rowStart + c * pixelStride)
            }
        }
        return out
    }
}
