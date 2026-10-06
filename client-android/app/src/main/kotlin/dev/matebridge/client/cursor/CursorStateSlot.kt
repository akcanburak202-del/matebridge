package dev.matebridge.client.cursor

import dev.matebridge.client.protocol.CursorState

/** One accepted `CURSOR_STATE` plus the client clock time ([rxMs], `SystemClock.elapsedRealtime`) it arrived at. Immutable. */
class CursorFrame(
    val seq: Long,
    val x: Int,
    val y: Int,
    val visible: Boolean,
    val shapeId: Long,
    val hostTimeUs: Long,
    val rxMs: Long,
)

/**
 * The newest cursor state (decision 0036, PROTOCOL.md 0x0D: "the client draws the newest `seq`, older ones are ignored").
 * One writer at a time is the normal case (the control reader thread), the drawing thread only reads. `seq` is a u32
 * that grows by one per state; the comparison uses serial-number arithmetic, so a wrap at 2^32 still counts as newer.
 */
class CursorStateSlot {
    @Volatile private var current: CursorFrame? = null
    private val lock = Any()

    /** Stores [s] when it is newer than the held one (or nothing is held). Returns false for a stale or duplicate seq. */
    fun offer(s: CursorState, rxMs: Long): Boolean = synchronized(lock) {
        val held = current
        if (held != null && !isNewer(s.seq, held.seq)) return false
        current = CursorFrame(s.seq, s.x, s.y, s.visible, s.shapeId, s.hostTimeUs, rxMs)
        true
    }

    fun latest(): CursorFrame? = current

    fun clear() = synchronized(lock) { current = null }

    companion object {
        /** True when [a] is after [b] in u32 serial order (a distance of 1 until 2^31 - 1 counts as newer). */
        fun isNewer(a: Long, b: Long): Boolean {
            val d = (a - b) and 0xFFFFFFFFL
            return d in 1..0x7FFFFFFFL
        }
    }
}
