package dev.matebridge.client.video

/**
 * Pairs a main frame with its auxiliary frame by `capture_time_us` (PROTOCOL.md 0x41: the auxiliary frame carries the
 * main frame's value). Holds the newest [capacity] auxiliary items (decoded images); [T] is opaque here. Not
 * thread-safe: the GL thread owns it (the decoder side hands items over through a queue).
 *
 * [pair] never waits: a main frame without its auxiliary frame yet is shown main-only (counted as late). Items older
 * than a matched or an unmatched-but-newer main frame can never match again (main frames are presented in order) and are
 * evicted through [onEvict] so the owner can close them.
 */
class AuxPairing<T : Any>(private val capacity: Int, private val onEvict: (T) -> Unit) {
    private class Entry<T>(val captureUs: Long, val item: T)

    private val items = ArrayList<Entry<T>>()

    var paired = 0L
        private set
    var late = 0L
        private set

    /** Stores a freshly decoded auxiliary item; the oldest is evicted beyond [capacity]. */
    fun add(captureUs: Long, item: T) {
        items.add(Entry(captureUs, item))
        while (items.size > capacity) onEvict(items.removeAt(0).item)
    }

    /**
     * The auxiliary item of the main frame captured at [captureUs], or null (main-only). The match stays in the ring until
     * it is evicted: it is still being sampled by the draw that uses it. Items captured before [captureUs] are evicted.
     */
    fun pair(captureUs: Long): T? {
        val it = items.iterator()
        var match: T? = null
        while (it.hasNext()) {
            val e = it.next()
            if (e.captureUs == captureUs) {
                match = e.item
            } else if (e.captureUs < captureUs) {
                it.remove()
                onEvict(e.item)
            }
        }
        if (match != null) paired++ else late++
        return match
    }

    /** `aux_paired_pct` of the counts since the last [resetCounts]; null when no main frame was judged. */
    fun pairedPct(): Double? = if (paired + late == 0L) null else paired * 100.0 / (paired + late)

    fun resetCounts() { paired = 0; late = 0 }

    /** Evicts everything (decoder rebuilt, stream ended). */
    fun clear() {
        for (e in items) onEvict(e.item)
        items.clear()
    }

    val size: Int get() = items.size
}

/**
 * Window of GL pass durations (ms) for `gl_ms_p50` / `gl_ms_p95`. Thread-safe. Bounded: a window keeps the last
 * [MAX] samples.
 */
class GlTimings {
    companion object {
        const val MAX = 1024
    }

    private val samples = DoubleArray(MAX)
    private var count = 0
    private var next = 0

    @Synchronized fun add(ms: Double) {
        samples[next] = ms
        next = (next + 1) % MAX
        if (count < MAX) count++
    }

    /** p50 and p95 of the window, or null when empty; [reset] starts a new window. */
    @Synchronized fun percentiles(reset: Boolean = true): Pair<Double, Double>? {
        if (count == 0) return null
        val sorted = samples.copyOf(count).also { it.sort() }
        fun at(p: Int) = sorted[((count * p + 99) / 100 - 1).coerceIn(0, count - 1)]
        val r = at(50) to at(95)
        if (reset) { count = 0; next = 0 }
        return r
    }
}
