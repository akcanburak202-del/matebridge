package dev.matebridge.client.video

import java.io.File

/**
 * Scratch fields the [AdaptivePacer] fills for the frame it just scheduled (T-069). Output thread only. All times
 * are System.nanoTime ns unless noted. [path] is one of the PATH_* codes.
 */
class PaceProbe {
    companion object {
        const val PATH_NONE = 0
        const val PATH_UNLOCKED = 1
        const val PATH_LOCKED = 2
        const val PATH_ACQUIRE = 3
        const val PATH_SPARSE = 4
        const val PATH_REPHASE = 5
        const val PATH_RECENTER = 6
    }

    var path = PATH_NONE
    var nowVsyncLastNs = 0L
    var periodNs = 0L
    var epoch = 0
    var deadlineNs = 0L
    var devNs = 0L
    var dNs = 0L
    var jitterNs = 0L
    var earliestNs = 0L
    var lockSlotNs = 0L
    var k = 0L
    var acquireNs = 0L
    var badRun = 0

    fun clear() {
        path = PATH_NONE; nowVsyncLastNs = 0; periodNs = 0; epoch = 0; deadlineNs = 0; devNs = 0; dNs = 0
        jitterNs = 0; earliestNs = 0; lockSlotNs = 0; k = 0; acquireNs = 0; badRun = 0
    }
}

/**
 * Per-frame presentation trace (T-069, experiment, default off): a pre-allocated ring of the last [capacity] decoded
 * frames, one row of [COLS] longs each. The output thread writes rows ([record] when a frame is scheduled, then
 * [onRelease]/[onDiscard]/[onMove] when its fate is known); a separate thread calls [writeCsv]/[dumpTo]. No
 * allocation on the write path. The reader takes no lock: a row being updated while it is dumped may show a
 * half-filled release (diagnostic data, accepted). Timing values only, no content.
 *
 * A frame is identified by the id [record] returns; ids older than [capacity] rows are ignored.
 */
class PaceTrace(val capacity: Int = DEFAULT_CAPACITY) {
    companion object {
        const val DEFAULT_CAPACITY = 20_000
        const val ACTION_PENDING = 0
        const val ACTION_RELEASE = 1
        const val ACTION_REPLACE = 2
        const val ACTION_MOVE = 3
        const val ACTION_DISCARD = 4
        /** Frame decoded but rendered at once, outside the pacing (no vsync/capture time known). */
        const val ACTION_NOW = 5

        const val HEADER_LINE = "seq,capture_us,ready_ns,now_vsync_last_ns,period_ns,epoch,deadline_ns,dev_ns," +
            "d_ns,jitter_ns,earliest_ns,slot_ns,lock_slot_ns,k,acquire_ns,bad_run,path,late_drop,collided," +
            "released_slot_ns,release_ns,render_ns,action,own_slot_ns"
        const val COLS = 24
        private val PATHS = arrayOf("none", "unlocked", "locked", "acquire", "sparse", "rephase", "recenter")
        private val ACTIONS = arrayOf("pending", "release", "replace", "move", "discard", "now")

        private const val C_SEQ = 0; private const val C_CAPTURE = 1; private const val C_READY = 2
        private const val C_VSYNC = 3; private const val C_PERIOD = 4; private const val C_EPOCH = 5
        private const val C_DEADLINE = 6; private const val C_DEV = 7; private const val C_D = 8
        private const val C_JITTER = 9; private const val C_EARLIEST = 10; private const val C_SLOT = 11
        private const val C_LOCK = 12; private const val C_K = 13; private const val C_ACQUIRE = 14
        private const val C_BAD = 15; private const val C_PATH = 16; private const val C_LATE = 17
        private const val C_COLL = 18; private const val C_RSLOT = 19; private const val C_RELNS = 20
        private const val C_RENDER = 21; private const val C_ACTION = 22; private const val C_OWN = 23
    }

    private val data = LongArray(capacity * COLS)
    @Volatile private var count = 0L // rows ever recorded

    /** Rows currently held (at most [capacity]). */
    val size: Int get() = minOf(count, capacity.toLong()).toInt()

    /** Starts a row for a scheduled frame; returns its id. Slots come from the pacer's decision. */
    fun record(
        seq: Long, captureUs: Long, readyNs: Long, probe: PaceProbe?, slotNs: Long, lateDrop: Boolean, collided: Boolean,
        ownSlotNs: Long, action: Int = ACTION_PENDING,
    ): Long {
        val id = count
        val b = (id % capacity).toInt() * COLS
        val d = data
        d[b + C_SEQ] = seq; d[b + C_CAPTURE] = captureUs; d[b + C_READY] = readyNs
        if (probe != null) {
            d[b + C_VSYNC] = probe.nowVsyncLastNs; d[b + C_PERIOD] = probe.periodNs; d[b + C_EPOCH] = probe.epoch.toLong()
            d[b + C_DEADLINE] = probe.deadlineNs; d[b + C_DEV] = probe.devNs; d[b + C_D] = probe.dNs
            d[b + C_JITTER] = probe.jitterNs; d[b + C_EARLIEST] = probe.earliestNs; d[b + C_LOCK] = probe.lockSlotNs
            d[b + C_K] = probe.k; d[b + C_ACQUIRE] = probe.acquireNs; d[b + C_BAD] = probe.badRun.toLong()
            d[b + C_PATH] = probe.path.toLong()
        } else {
            for (c in C_VSYNC..C_BAD) d[b + c] = 0
            d[b + C_PATH] = PaceProbe.PATH_NONE.toLong()
        }
        d[b + C_SLOT] = slotNs; d[b + C_LATE] = if (lateDrop) 1 else 0; d[b + C_COLL] = if (collided) 1 else 0
        d[b + C_RSLOT] = 0; d[b + C_RELNS] = 0; d[b + C_RENDER] = 0
        d[b + C_ACTION] = action.toLong(); d[b + C_OWN] = ownSlotNs
        count = id + 1
        return id
    }

    private fun base(id: Long): Int =
        if (id < 0 || id >= count || id < count - capacity) -1 else (id % capacity).toInt() * COLS

    /** The buffer was handed to the codec for [slotNs] with [renderNs]. A row already marked move keeps that mark. */
    fun onRelease(id: Long, slotNs: Long, nowNs: Long, renderNs: Long) {
        val b = base(id); if (b < 0) return
        data[b + C_RSLOT] = slotNs; data[b + C_RELNS] = nowNs; data[b + C_RENDER] = renderNs
        if (data[b + C_ACTION] != ACTION_MOVE.toLong()) data[b + C_ACTION] = ACTION_RELEASE.toLong()
    }

    /** The buffer was dropped without being shown ([action] = [ACTION_REPLACE] or [ACTION_DISCARD]). */
    fun onDiscard(id: Long, nowNs: Long, action: Int) {
        val b = base(id); if (b < 0) return
        data[b + C_RELNS] = nowNs; data[b + C_ACTION] = action.toLong()
    }

    /** The slot was already released; the frame moved one slot later. */
    fun onMove(id: Long) {
        val b = base(id); if (b < 0) return
        data[b + C_ACTION] = ACTION_MOVE.toLong()
    }

    /** CSV text, oldest row first: header then one line per row. */
    fun writeCsv(out: Appendable) {
        out.append(HEADER_LINE).append('\n')
        val n = count
        val first = maxOf(0L, n - capacity)
        for (id in first until n) {
            val b = (id % capacity).toInt() * COLS
            for (c in 0 until COLS) {
                if (c > 0) out.append(',')
                val v = data[b + c]
                when (c) {
                    C_PATH -> out.append(PATHS.getOrElse(v.toInt()) { "?" })
                    C_ACTION -> out.append(ACTIONS.getOrElse(v.toInt()) { "?" })
                    else -> out.append(v.toString())
                }
            }
            out.append('\n')
        }
    }

    /** Writes the CSV to [file] via a temp file (replaced, never appended). */
    fun dumpTo(file: File) {
        val tmp = File(file.parentFile, file.name + ".tmp")
        tmp.bufferedWriter().use { writeCsv(it) }
        if (!tmp.renameTo(file)) { file.delete(); tmp.renameTo(file) }
    }
}
