package dev.matebridge.client.input

import dev.matebridge.client.protocol.Key
import dev.matebridge.client.protocol.Message
import dev.matebridge.client.protocol.Pen
import dev.matebridge.client.protocol.Pinch
import dev.matebridge.client.protocol.PointerAbs
import dev.matebridge.client.protocol.PointerRel
import dev.matebridge.client.protocol.Scroll

/**
 * T-322 (EN1): how long an input message waited on the tablet. Age = the moment the socket write of the message's
 * frame returned minus the message's event time, both on the tablet clock (`MotionEvent.eventTime` is uptime, the same
 * base as `System.nanoTime`). Counts and durations only: no coordinates, no key data.
 *
 * Recorded by the control writer thread ([record]); read and cleared by the UI thread ([takeFields]). Fixed memory:
 * a histogram of [BUCKET_US] buckets per class, so recording never allocates and a busy window cannot grow.
 */
class SendAgeStats {
    enum class Cls(val id: String) { PEN("pen"), POINTER("pointer"), KEY("key"), SCROLL("scroll") }

    private val lock = Any()
    private val hist = Array(Cls.values().size) { IntArray(BUCKETS) }
    private val maxUs = LongArray(Cls.values().size)
    private val count = IntArray(Cls.values().size)

    /** Records one sent message of class ordinal [cls] ([Cls.ordinal]) produced at [eventTimeUs] and written at [nowUs]. */
    fun record(cls: Int, eventTimeUs: Long, nowUs: Long) {
        if (cls < 0 || cls >= hist.size || eventTimeUs <= 0L) return
        val age = (nowUs - eventTimeUs).coerceAtLeast(0L)
        val b = (age / BUCKET_US).toInt().coerceAtMost(BUCKETS - 1)
        synchronized(lock) {
            hist[cls][b]++
            count[cls]++
            if (age > maxUs[cls]) maxUs[cls] = age
        }
    }

    /**
     * The window since the last call as log fields, then cleared; "" when nothing was recorded. Per class with data:
     * `<cls>_send_n= <cls>_send_age_ms_p50= _p95= _max=` (milliseconds, one decimal).
     */
    fun takeFields(): String {
        val sb = StringBuilder()
        synchronized(lock) {
            for (c in Cls.values()) {
                val i = c.ordinal
                val n = count[i]
                if (n == 0) continue
                if (sb.isNotEmpty()) sb.append(' ')
                sb.append(c.id).append("_send_n=").append(n)
                sb.append(' ').append(c.id).append("_send_age_ms_p50=").append(ms(percentileUs(hist[i], n, 50)))
                sb.append(' ').append(c.id).append("_send_age_ms_p95=").append(ms(percentileUs(hist[i], n, 95)))
                sb.append(' ').append(c.id).append("_send_age_ms_max=").append(ms(maxUs[i]))
                hist[i].fill(0)
                count[i] = 0
                maxUs[i] = 0
            }
        }
        return sb.toString()
    }

    companion object {
        const val BUCKET_US = 250L
        const val BUCKETS = 4096 // up to ~1 s; the last bucket collects the rest (the exact maximum is kept apart)

        /** The stats class ordinal of [m], or -1 for messages that are not input events (never recorded). */
        fun classOf(m: Message): Int = when (m) {
            is Pen -> Cls.PEN.ordinal
            is PointerAbs, is PointerRel -> Cls.POINTER.ordinal
            is Key -> Cls.KEY.ordinal
            is Scroll, is Pinch -> Cls.SCROLL.ordinal // as the host InputAge: pinch counts with scroll
            else -> -1
        }

        /** Event time of [m] in microseconds on the tablet uptime clock (a PEN message: its newest sample), 0 when unknown. */
        fun eventTimeUs(m: Message): Long = when (m) {
            is Pen -> m.baseTimeUs + (m.samples.lastOrNull()?.dtUs ?: 0)
            is PointerAbs -> m.timeUs
            is PointerRel -> m.timeUs
            is Pinch -> m.timeUs
            is Key -> m.timeUs
            is Scroll -> m.timeUs
            else -> 0L
        }

        /** Upper edge of the bucket holding the [pct]th percentile (nearest rank). */
        internal fun percentileUs(h: IntArray, n: Int, pct: Int): Long {
            val rank = ((n.toLong() * pct + 99) / 100).coerceIn(1L, n.toLong())
            var seen = 0L
            for (b in h.indices) {
                seen += h[b]
                if (seen >= rank) return (b + 1) * BUCKET_US
            }
            return BUCKETS * BUCKET_US
        }

        private fun ms(us: Long): String {
            val tenths = (us + 50) / 100
            return "${tenths / 10}.${tenths % 10}"
        }
    }
}
