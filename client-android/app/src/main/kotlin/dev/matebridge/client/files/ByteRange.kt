package dev.matebridge.client.files

/**
 * `Range` header of a GET (RFC 9110 section 14). Only a single `bytes` range is served as 206; anything else that is
 * well-formed but not a single range (several ranges, another unit) and anything malformed is ignored, which per the
 * RFC means a full 200 response. Pure Kotlin.
 */
sealed interface ByteRange {
    /** Serve the whole entity (no header, or one we ignore). */
    data object Full : ByteRange

    /** Serve bytes [start]..[endInclusive] (206). */
    data class Part(val start: Long, val endInclusive: Long) : ByteRange {
        val length: Long get() = endInclusive - start + 1
        fun contentRange(total: Long) = "bytes $start-$endInclusive/$total"
    }

    /** 416 with `Content-Range: bytes * / total`. */
    data object Unsatisfiable : ByteRange

    companion object {
        fun parse(header: String?, total: Long): ByteRange {
            if (header == null) return Full
            val h = header.trim()
            if (!h.startsWith("bytes=", ignoreCase = true)) return Full
            val spec = h.substring(6).trim()
            if (spec.isEmpty() || spec.contains(',')) return Full
            val dash = spec.indexOf('-')
            if (dash < 0) return Full
            val a = spec.substring(0, dash).trim()
            val b = spec.substring(dash + 1).trim()
            if (!a.all { it in '0'..'9' } || !b.all { it in '0'..'9' } || (a.isEmpty() && b.isEmpty())) return Full
            if (a.isEmpty()) {
                // Suffix range: the last n bytes.
                val n = b.toLongOrNull() ?: Long.MAX_VALUE
                if (n == 0L || total == 0L) return Unsatisfiable
                val len = minOf(n, total)
                return Part(total - len, total - 1)
            }
            val start = a.toLongOrNull() ?: return Unsatisfiable // more digits than a Long: past any file
            val end = if (b.isEmpty()) Long.MAX_VALUE else b.toLongOrNull() ?: Long.MAX_VALUE
            if (end < start) return Full // invalid range-spec: ignore the header
            if (start >= total) return Unsatisfiable
            return Part(start, minOf(end, total - 1))
        }
    }
}
