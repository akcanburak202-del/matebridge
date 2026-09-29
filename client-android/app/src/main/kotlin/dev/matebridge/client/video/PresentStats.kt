package dev.matebridge.client.video

import java.util.Locale

/**
 * Counters of the GL presentation loop (T-018), one window per STATS second. Thread-safe.
 *
 * - vsyncs / missed: Choreographer callbacks seen; [Snapshot.missed] counts vsyncs that passed without a
 *   callback (gap > 1.5 periods), i.e. the render thread itself was late.
 * - drawn: frames drawn (at most one per vsync). coalesced: frames that became ready while an older one
 *   was still waiting for its vsync, so only the newest was drawn (newest wins).
 * - wait: time from a frame becoming available to the start of its draw (latency added by vsync alignment).
 * - swap: duration of eglSwapBuffers.
 */
class PresentStats {
    data class Snapshot(
        val vsyncs: Long, val missed: Long, val drawn: Long, val coalesced: Long,
        val waitAvgUs: Long, val waitMaxUs: Long, val swapAvgUs: Long, val swapMaxUs: Long,
    ) {
        fun fields(): String {
            fun ms(us: Long) = String.format(Locale.ROOT, "%.2f", us / 1000.0)
            return "gl_vsync=$vsyncs gl_missed=$missed gl_drawn=$drawn gl_coalesced=$coalesced " +
                "gl_wait_avg_ms=${ms(waitAvgUs)} gl_wait_max_ms=${ms(waitMaxUs)} " +
                "gl_swap_avg_ms=${ms(swapAvgUs)} gl_swap_max_ms=${ms(swapMaxUs)}"
        }
    }

    private var vsyncs = 0L
    private var missed = 0L
    private var drawn = 0L
    private var coalesced = 0L
    private var waitSum = 0L
    private var waitMax = 0L
    private var swapSum = 0L
    private var swapMax = 0L
    private var lastVsyncNs = -1L

    @Synchronized fun onVsync(frameTimeNs: Long, periodNs: Long) {
        vsyncs++
        if (lastVsyncNs >= 0 && periodNs > 0) {
            val gap = frameTimeNs - lastVsyncNs
            if (gap > periodNs * 3 / 2) missed += Math.round(gap.toDouble() / periodNs) - 1
        }
        lastVsyncNs = frameTimeNs
    }

    @Synchronized fun onDraw(waitNs: Long, swapNs: Long, coalescedFrames: Int) {
        drawn++
        coalesced += coalescedFrames.coerceAtLeast(0)
        val w = (waitNs / 1000).coerceAtLeast(0)
        val s = (swapNs / 1000).coerceAtLeast(0)
        waitSum += w; swapSum += s
        if (w > waitMax) waitMax = w
        if (s > swapMax) swapMax = s
    }

    /** The loop was paused or restarted: the next gap must not count as missed vsyncs. */
    @Synchronized fun breakSequence() { lastVsyncNs = -1 }

    @Synchronized fun snapshot(reset: Boolean = false): Snapshot {
        val s = Snapshot(
            vsyncs, missed, drawn, coalesced,
            if (drawn > 0) waitSum / drawn else 0, waitMax,
            if (drawn > 0) swapSum / drawn else 0, swapMax,
        )
        if (reset) {
            vsyncs = 0; missed = 0; drawn = 0; coalesced = 0
            waitSum = 0; waitMax = 0; swapSum = 0; swapMax = 0
        }
        return s
    }
}
