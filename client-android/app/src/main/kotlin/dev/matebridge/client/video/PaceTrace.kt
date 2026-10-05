package dev.matebridge.client.video

import dev.matebridge.client.security.OpenStamps
import dev.matebridge.client.security.Records
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
        /**
         * T-080 constant playout delay ([ConstantPlayoutPacer]). Columns then mean: dev_ns = x - b, d_ns = C - b,
         * jitter_ns = J (q-quantile, before the hold), acquire_ns = target t = capture + C + L (unsnapped),
         * lock_slot_ns = C (ready - capture domain), k = window samples, bad_run = 1 when C changed on this frame.
         */
        const val PATH_CPD = 7
        /**
         * T-115 lone frames on the phase-lock path, scheduled on the earliest slot without hold and without forming a
         * lock: after a capture gap ([PATH_EARLY_SPARSE]) or with no previous frame ([PATH_EARLY_FIRST]: session start, idle
         * re-anchor, panel-rate change). acquire_ns = the slot the hold would have chosen (gain = acquire_ns - slot_ns),
         * lock_slot_ns = 0. [PATH_SPARSE] then only appears with the A/B switch off (and in older traces).
         */
        const val PATH_EARLY_SPARSE = 8
        const val PATH_EARLY_FIRST = 9
        /** T-115: a locked frame was late (missed its slot, or beyond the latency bound) while the jitter history was thin; the lock was re-acquired from it. */
        const val PATH_WARMUP = 10
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
    /** T-251: the skip-feedback level at this frame. */
    var level = 0

    fun clear() {
        path = PATH_NONE; nowVsyncLastNs = 0; periodNs = 0; epoch = 0; deadlineNs = 0; devNs = 0; dNs = 0
        jitterNs = 0; earliestNs = 0; lockSlotNs = 0; k = 0; acquireNs = 0; badRun = 0; level = 0
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
            "released_slot_ns,release_ns,render_ns,action,own_slot_ns,recv_ns,decrypted_ns,queued_ns,input_ns,bytes,rx_action," +
            "open_start_ns,open_init_ns,open_final_ns,taken_ns,inbuf_ns,copied_ns,inbuf_pre,latch_slot_ns,latch_period_ns,cb_ns,cb_period_ns,level"
        const val COLS = 24
        /** T-225: rows [onCallback] searches back for the frame (a callback comes a few frames after its release). */
        const val CB_LOOKBACK = 64L
        /** Receive-path CSV columns after the presentation ones: six from T-073, seven from T-077. */
        private const val RX_CSV = 13
        /**
         * CSV columns: the [COLS] presentation columns, the receive-path columns, then T-220's `latch_slot_ns` and
         * `latch_period_ns` (the vsync the release-time latch model attributed the release to and its panel period,
         * [HoldMeter.releasedSlot]; 0 = not released), then T-225's `cb_ns` and `cb_period_ns`, then T-251's `level` (the pacer's skip-feedback level).
         */
        const val CSV_COLS = COLS + RX_CSV + 5
        /**
         * Columns of the receive ring: seq, capture_us, bytes, recv, decrypted, queued, input, action (T-073), then the
         * record open stamps and the decoder input steps (T-077).
         */
        private const val RX_COLS = 15
        private const val R_SEQ = 0; private const val R_CAPTURE = 1; private const val R_BYTES = 2
        private const val R_RECV = 3; private const val R_DEC = 4; private const val R_QUEUED = 5
        private const val R_INPUT = 6; private const val R_ACTION = 7
        private const val R_OPEN0 = 8; private const val R_INIT = 9; private const val R_FINAL = 10
        private const val R_TAKEN = 11; private const val R_INBUF = 12; private const val R_COPIED = 13; private const val R_PRE = 14

        /** Receive-path fates of a frame ([onRxAction]); [RX_QUEUED] is the normal one. */
        const val RX_RECEIVED = 0 // read and decrypted, not yet offered to the queue
        const val RX_QUEUED = 1
        const val RX_CONFIG = 2 // codec config, queued
        const val RX_QUEUE_DROP = 3 // overflow: the incoming frame was refused
        const val RX_PENDING_DROP = 4 // queued, then flushed by an overflow, keyframe or error
        const val RX_GATE_DROP = 5 // non-key frame while waiting for a keyframe
        const val RX_RESET_DROP = 6 // cleared by a queue reset
        private val RX_ACTIONS = arrayOf("received", "queued", "config", "queue_drop", "pending_drop", "gate_drop", "reset_drop")

        /**
         * The trace the video connection thread stamps receive times into; set together with the renderer's trace so
         * the session code needs no wiring. Null = tracing off (the hot path then costs one volatile read).
         */
        @Volatile var active: PaceTrace? = null
        private val PATHS = arrayOf("none", "unlocked", "locked", "acquire", "sparse", "rephase", "recenter", "cpd", "early_sparse", "early_first", "warmup")
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
    /** T-220: release-time vsync and period of each row ([onLatch]), two per row, same index as [data]'s rows. */
    private val latch = LongArray(capacity * 2)
    /** T-225: `nanoTime` of each row's frame-rendered callback ([onCallback]), 0 = none (yet); same index as [data]'s rows. */
    private val cb = LongArray(capacity)
    /** T-225 review: the panel period the callback was judged with (the one current at its delivery), per row. */
    private val cbPeriod = LongArray(capacity)
    /** T-251: the pacer's feedback level per row. */
    private val lvl = IntArray(capacity)
    // Receive ring (T-073), slot = frameSeq % capacity, valid when R_SEQ matches. Written by the video connection
    // thread (onRecv), the queue (onRx*) and the decoder input thread (onInput); joined to the rows above by seq.
    private val rx = LongArray(capacity * RX_COLS).also { for (i in 0 until capacity) it[i * RX_COLS + R_SEQ] = -1 }
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
        latch[(id % capacity).toInt() * 2] = 0; latch[(id % capacity).toInt() * 2 + 1] = 0
        cb[(id % capacity).toInt()] = 0; cbPeriod[(id % capacity).toInt()] = 0
        lvl[(id % capacity).toInt()] = probe?.level ?: 0
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

    /**
     * T-220: the frame was handed to the codec and the presentation metric attributed it to the vsync at [slotNs] on a
     * panel of [periodNs] (after the release call returned, on the grid of that moment). `sim.py --holds` uses them.
     */
    fun onLatch(id: Long, slotNs: Long, periodNs: Long) {
        if (base(id) < 0) return
        val i = (id % capacity).toInt() * 2
        latch[i] = slotNs; latch[i + 1] = periodNs
    }

    /**
     * T-225: the codec's frame-rendered callback for frame [seq] came with [cbNs] (its own `nanoTime`, the time the
     * presentation metric `skip_pct` uses; `sim.py --holds` prefers it) and [periodNs] the panel period the metric used for it. Main looper; looks back over the last
     * [CB_LOOKBACK] rows (a callback follows its release by a few frames), so a frame that is no longer there is ignored.
     */
    fun onCallback(seq: Long, cbNs: Long, periodNs: Long = 0) {
        val n = count
        var id = n - 1
        val stop = maxOf(n - CB_LOOKBACK, n - capacity, 0L)
        while (id >= stop) {
            val r = (id % capacity).toInt()
            if (data[r * COLS + C_SEQ] == seq) { cb[r] = cbNs; cbPeriod[r] = periodNs; return }
            id--
        }
    }

    private fun rxBase(seq: Long): Int {
        val b = (seq % capacity).toInt() * RX_COLS
        return if (rx[b + R_SEQ] == seq) b else -1
    }

    /**
     * A VIDEO_FRAME record was read from the socket at [recvNs] and decrypted/parsed at [decryptedNs]. Starts the frame's
     * receive row. Called on the thread that opened the record, right after it: the open stamps (T-077) are that
     * thread's [OpenStamps] when [Records.stampOpens] is on, else zero.
     */
    fun onRecv(seq: Long, captureUs: Long, bytes: Int, recvNs: Long, decryptedNs: Long) {
        val st = if (Records.stampOpens) OpenStamps.current() else null
        onRecv(seq, captureUs, bytes, recvNs, decryptedNs, st?.startNs ?: 0, st?.initNs ?: 0, st?.finalNs ?: 0)
    }

    fun onRecv(
        seq: Long, captureUs: Long, bytes: Int, recvNs: Long, decryptedNs: Long, openStartNs: Long, openInitNs: Long, openFinalNs: Long,
    ) {
        val b = (seq % capacity).toInt() * RX_COLS
        val r = rx
        r[b + R_SEQ] = seq; r[b + R_CAPTURE] = captureUs; r[b + R_BYTES] = bytes.toLong(); r[b + R_RECV] = recvNs
        r[b + R_DEC] = decryptedNs; r[b + R_QUEUED] = 0; r[b + R_INPUT] = 0; r[b + R_ACTION] = RX_RECEIVED.toLong()
        r[b + R_OPEN0] = openStartNs; r[b + R_INIT] = openInitNs; r[b + R_FINAL] = openFinalNs
        r[b + R_TAKEN] = 0; r[b + R_INBUF] = 0; r[b + R_COPIED] = 0; r[b + R_PRE] = 0
    }

    /** The frame went through [FrameQueue.offer] at [nowNs] with fate [action] (an RX_* code). */
    fun onRxAction(seq: Long, nowNs: Long, action: Int) {
        val b = rxBase(seq); if (b < 0) return
        if (action == RX_QUEUED || action == RX_CONFIG || rx[b + R_QUEUED] == 0L) rx[b + R_QUEUED] = nowNs
        rx[b + R_ACTION] = action.toLong()
    }

    /**
     * The frame was handed to the codec (queueInputBuffer) at [nowNs]. T-077 steps before it: taken from the queue at
     * [takenNs], input buffer index in hand at [inbufNs] ([prefetched] = taken ahead of the frame), data copied at [copiedNs].
     */
    fun onInput(seq: Long, nowNs: Long, takenNs: Long = 0, inbufNs: Long = 0, copiedNs: Long = 0, prefetched: Boolean = false) {
        val b = rxBase(seq); if (b < 0) return
        val r = rx
        r[b + R_INPUT] = nowNs
        r[b + R_TAKEN] = takenNs; r[b + R_INBUF] = inbufNs; r[b + R_COPIED] = copiedNs; r[b + R_PRE] = if (prefetched) 1 else 0
    }

    private fun appendRx(out: Appendable, b: Int, c: Int) {
        // c = 0..12: recv_ns, decrypted_ns, queued_ns, input_ns, bytes, rx_action,
        //            open_start_ns, open_init_ns, open_final_ns, taken_ns, inbuf_ns, copied_ns, inbuf_pre
        when (c) {
            0 -> out.append(rx[b + R_RECV].toString())
            1 -> out.append(rx[b + R_DEC].toString())
            2 -> out.append(rx[b + R_QUEUED].toString())
            3 -> out.append(rx[b + R_INPUT].toString())
            4 -> out.append(rx[b + R_BYTES].toString())
            5 -> out.append(RX_ACTIONS.getOrElse(rx[b + R_ACTION].toInt()) { "?" })
            else -> out.append(rx[b + R_OPEN0 + (c - 6)].toString())
        }
    }

    /** CSV text, oldest row first: header then one line per row. */
    fun writeCsv(out: Appendable) {
        out.append(HEADER_LINE).append('\n')
        val n = count
        val first = maxOf(0L, n - capacity)
        val used = BooleanArray(capacity)
        for (id in first until n) {
            val b = (id % capacity).toInt() * COLS
            val rb = rxBase(data[b + C_SEQ])
            if (rb >= 0) used[rb / RX_COLS] = true
            for (c in 0 until COLS) {
                if (c > 0) out.append(',')
                val v = data[b + c]
                when (c) {
                    C_PATH -> out.append(PATHS.getOrElse(v.toInt()) { "?" })
                    C_ACTION -> out.append(ACTIONS.getOrElse(v.toInt()) { "?" })
                    else -> out.append(v.toString())
                }
            }
            for (c in 0 until RX_CSV) { out.append(','); if (rb >= 0) appendRx(out, rb, c) else out.append(if (c == 5) "none" else "0") }
            val li = (id % capacity).toInt() * 2 // T-220
            out.append(',').append(latch[li].toString()).append(',').append(latch[li + 1].toString())
            out.append(',').append(cb[(id % capacity).toInt()].toString()) // T-225
            out.append(',').append(cbPeriod[(id % capacity).toInt()].toString())
            out.append(',').append(lvl[(id % capacity).toInt()].toString()) // T-251
            out.append('\n')
        }
        // Frames that were received but never decoded/presented (dropped, gated, still queued): one row each, the
        // action column carries the receive-path fate, presentation columns are zero.
        for (slot in 0 until capacity) {
            val rb = slot * RX_COLS
            val seq = rx[rb + R_SEQ]
            if (seq < 0 || used[slot]) continue
            out.append(seq.toString()).append(',').append(rx[rb + R_CAPTURE].toString()).append(',')
            for (c in 2 until COLS) {
                out.append(if (c == C_PATH) "none" else if (c == C_ACTION) RX_ACTIONS.getOrElse(rx[rb + R_ACTION].toInt()) { "?" } else "0").append(',')
            }
            for (c in 0 until RX_CSV) { if (c > 0) out.append(','); appendRx(out, rb, c) }
            out.append(",0,0,0,0,0\n") // T-220 latch_slot_ns, latch_period_ns, T-225 cb_ns, cb_period_ns: never released

        }
    }

    /** Writes the CSV to [file] via a temp file (replaced, never appended). */
    fun dumpTo(file: File) {
        val tmp = File(file.parentFile, file.name + ".tmp")
        tmp.bufferedWriter().use { writeCsv(it) }
        if (!tmp.renameTo(file)) { file.delete(); tmp.renameTo(file) }
    }
}
