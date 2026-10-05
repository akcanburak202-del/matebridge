package dev.matebridge.yuv444probe

import java.util.Locale

/** Nearest-rank percentile of [values] (any order); 0 for an empty array. */
fun percentile(values: LongArray, p: Double): Long {
    if (values.isEmpty()) return 0
    val s = values.sortedArray()
    val rank = Math.ceil(p / 100.0 * s.size).toInt().coerceIn(1, s.size)
    return s[rank - 1]
}

/** Growable primitive long list (no boxing in the decode callbacks). Writers must be a single thread. */
class LongList(capacity: Int = 1024) {
    private var a = LongArray(capacity)
    var size = 0
        private set

    fun add(v: Long) {
        if (size == a.size) a = a.copyOf(a.size * 2)
        a[size++] = v
    }

    fun addAll(values: LongArray) {
        for (v in values) add(v)
    }

    fun toArray(): LongArray = a.copyOf(size)
}

/** `p50/p95/p99/max` of nanosecond values in milliseconds (`-` when empty). */
fun msDist(ns: LongArray): String {
    if (ns.isEmpty()) return "-"
    fun ms(v: Long) = v / 1e6
    return String.format(
        Locale.US, "%.2f/%.2f/%.2f/%.2f",
        ms(percentile(ns, 50.0)), ms(percentile(ns, 95.0)), ms(percentile(ns, 99.0)), ms(ns.max()),
    )
}

/** Mean of nanosecond values in milliseconds (0 when empty). */
fun meanMs(ns: LongArray): Double = if (ns.isEmpty()) 0.0 else ns.average() / 1e6

/** Result of pairing the main and auxiliary decoder outputs of the same frame number. */
class PairResult(
    /** max(main out, aux out) minus the scheduled arrival of the frame (ns). */
    val pairNs: LongArray,
    /** aux out minus main out (ns, negative when aux came first). */
    val auxAfterMainNs: LongArray,
    /** Main out minus scheduled arrival (ns). */
    val mainNs: LongArray,
    /** Aux out minus scheduled arrival (ns). */
    val auxNs: LongArray,
    val mainOnly: Int,
    val auxOnly: Int,
    val neither: Int,
)

object PairLatency {
    /**
     * Frame k arrives at `t0Ns + k * periodNs` (the pacing tick that owes it). [outMain] / [outAux] hold the
     * `System.nanoTime()` at which the decoder produced frame k, 0 when it never did. [outAux] null = single stream.
     * Frames `from until to` are considered.
     */
    fun compute(t0Ns: Long, periodNs: Long, outMain: LongArray, outAux: LongArray?, from: Int, to: Int): PairResult {
        val pair = LongList()
        val auxAfter = LongList()
        val main = LongList()
        val aux = LongList()
        var mainOnly = 0
        var auxOnly = 0
        var neither = 0
        val end = minOf(to, outMain.size, outAux?.size ?: Int.MAX_VALUE)
        for (k in from.coerceAtLeast(0) until end) {
            val sched = t0Ns + k * periodNs
            val m = outMain[k]
            val a = outAux?.get(k) ?: 0L
            if (m != 0L) main.add(m - sched)
            if (a != 0L) aux.add(a - sched)
            when {
                outAux == null -> if (m != 0L) pair.add(m - sched) else neither++
                m != 0L && a != 0L -> {
                    pair.add(maxOf(m, a) - sched)
                    auxAfter.add(a - m)
                }
                m != 0L -> mainOnly++
                a != 0L -> auxOnly++
                else -> neither++
            }
        }
        return PairResult(pair.toArray(), auxAfter.toArray(), main.toArray(), aux.toArray(), mainOnly, auxOnly, neither)
    }
}

/** Per-frame compositor timestamps resolved by `eglGetFrameTimestampsANDROID` (quads from the native side). */
class PresentResult(
    /** Latch time minus the time the decoder image arrived (ns). */
    val arrivalToLatchNs: LongArray,
    /** Display present time minus arrival (ns). */
    val arrivalToPresentNs: LongArray,
    /** Gaps between consecutive display present times (ns). */
    val presentGapNs: LongArray,
    /** Gaps larger than 1.5 feed periods: a frame period passed with no new frame shown. */
    val skippedGaps: Int,
    /** Frames whose timestamps were invalid or pending. */
    val unresolved: Int,
)

object PresentStats {
    private const val INVALID_BELOW = 1L  // EGL_TIMESTAMP_INVALID_ANDROID (-1) / PENDING (-2) / unset (0)

    /** [quads]: `[arrival, latch, present, renderComplete]` per frame, in submission order. */
    fun analyze(quads: LongArray, feedPeriodNs: Long): PresentResult {
        val latch = LongList()
        val present = LongList()
        val gaps = LongList()
        var skipped = 0
        var unresolved = 0
        var lastPresent = 0L
        var i = 0
        while (i + 3 < quads.size) {
            val arrival = quads[i]
            val l = quads[i + 1]
            val p = quads[i + 2]
            i += 4
            if (l < INVALID_BELOW || p < INVALID_BELOW) {
                unresolved++
                continue
            }
            latch.add(l - arrival)
            present.add(p - arrival)
            if (lastPresent > 0) {
                val g = p - lastPresent
                gaps.add(g)
                if (g > feedPeriodNs * 3 / 2) skipped++
            }
            lastPresent = p
        }
        return PresentResult(latch.toArray(), present.toArray(), gaps.toArray(), skipped, unresolved)
    }
}
