package dev.matebridge.client.cursor

/**
 * One pending redraw of the cursor layer, however many states arrive (T-276 review). `View.postInvalidateOnAnimation(rect)`
 * queues one record per call, so a stalled UI thread would accumulate one per state without bound. Here the reader thread
 * only merges the dirty rectangle (old cursor rectangle united with every new one) and schedules at most one task: [request]
 * returns true only for the call that must schedule it; the task runs [take] once and invalidates once. Thread-safe.
 */
class RedrawGate {
    /** The merged dirty area: the whole layer when [full], else the rectangle (left, top, right, bottom). */
    class Dirty(val full: Boolean, val left: Int, val top: Int, val right: Int, val bottom: Int, val hasRect: Boolean = true)

    private var pending = false
    private var full = false
    private var l = 0
    private var t = 0
    private var r = 0
    private var b = 0
    private var hasRect = false

    /**
     * Merges [rect] ([CursorGeometry.dirty] form: left, top, right, bottom; null = nothing) or the whole layer ([full]) into
     * the pending redraw. Returns true when no redraw was pending, so the caller schedules exactly one task.
     */
    @Synchronized fun request(rect: IntArray?, full: Boolean = false): Boolean {
        if (rect == null && !full) return false
        if (full) this.full = true
        if (rect != null) {
            if (!hasRect) {
                l = rect[0]; t = rect[1]; r = rect[2]; b = rect[3]; hasRect = true
            } else {
                l = minOf(l, rect[0]); t = minOf(t, rect[1]); r = maxOf(r, rect[2]); b = maxOf(b, rect[3])
            }
        }
        if (pending) return false
        pending = true
        return true
    }

    /**
     * T-278: asks for a redraw task without any area (the cursor position is predicted from the input just sent, so the task
     * itself works out the area at vsync time). Returns true when no redraw was pending, so the caller schedules exactly one task.
     */
    @Synchronized fun requestRecompute(): Boolean {
        if (pending) return false
        pending = true
        return true
    }

    /** The scheduled task: the merged area, then nothing is pending (a later [request] schedules the next task). */
    @Synchronized fun take(): Dirty? {
        if (!pending) return null
        val d = Dirty(full, l, t, r, b, hasRect)
        pending = false
        full = false
        hasRect = false
        return d
    }

    val isPending: Boolean @Synchronized get() = pending
}

/**
 * Whether the position the redraw task fixed for [frozen] may still be painted (T-278 review): only while it is the newest
 * accepted state. [CursorFrame]s are immutable and one object per accepted state, so identity also covers a hide
 * (`visible = 0` is a newer frame), a newer seq and a session reset (the slot is cleared, a later state is another object).
 */
object FrozenFrame {
    fun usable(frozen: CursorFrame, latest: CursorFrame?, ageUs: Long, maxAgeUs: Long): Boolean =
        latest === frozen && frozen.visible && ageUs >= 0 && ageUs < maxAgeUs
}
