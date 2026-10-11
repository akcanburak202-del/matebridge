package dev.matebridge.client.video

import dev.matebridge.client.protocol.KeyframeRequest
import dev.matebridge.client.protocol.VideoFrame
import java.util.concurrent.locks.LockSupport

/**
 * Bounded decoder input queue (PROTOCOL.md section 5). Pure Kotlin, thread-safe.
 *
 * Rules:
 *  - at most [maxPending] non-config frames wait for the decoder. T-121: deep enough to absorb a short network bunch
 *    (one large IDR holding the link) instead of resetting the stream; presentation still shows only the newest frame;
 *  - on overflow every pending non-config frame is dropped (the reference chain is broken anyway),
 *    the incoming frame is dropped too, and KEYFRAME_REQUEST(FRAMES_DROPPED) is produced;
 *  - until a keyframe arrives, non-keyframes are never queued (dropped and counted);
 *  - an arriving keyframe flushes older pending frames (stale) and re-opens the gate;
 *  - the latest CODEC_CONFIG is kept so it can be replayed after a codec restart.
 *
 * T-252 catch-up: with [catchUpDepth] > 0 an overflow (pending > [maxPending]) up to [catchUpDepth] frames and
 * [catchUpMaxBytes] is NOT dropped and produces no keyframe request: the frames stay queued and are decoded in order
 * (the reference chain is intact). [awaitNext] marks each taken frame ([CatchUp]): SKIP while more frames are behind
 * it, TAIL for the last one, so the presentation shows only the newest. Beyond the bounds the old path (drop everything,
 * gate, request) applies. Keyframe gating and decoder errors are unchanged; a flush that ends a catch-up (keyframe
 * arrival, overflow beyond the bound) makes the next taken frame the TAIL, and [reset] / [onDecoderError] forget it.
 *
 * T-121 request limit: after any KEYFRAME_REQUEST, no FRAMES_DROPPED request goes out for [HOLDOFF_MS], even if a
 * keyframe arrived in between (that is what breaks the IDR -> overflow -> request chain). A suppressed request is
 * held and goes out on the first frame offered after the hold-off while the gate is still closed. STARTUP
 * ([reset]) and DECODE_ERROR ([onDecoderError]) always go out at once and restart the hold-off.
 *
 * T-219 consumer ownership: frames go only to the consumer generation that owns the queue ([assignConsumer]). A
 * retired generation ([revokeConsumer], or a newer owner) takes nothing: its [awaitNext] returns null at once and the
 * frames stay queued for the owner, so a decoder thread that outlives its generation can never consume (or, through
 * [resetIfOwner] / [onDecoderErrorIfOwner], drop) the next generation's startup frames. [ANY_CONSUMER] skips the check
 * (single-consumer users and tests).
 */
class FrameQueue(
    private val stats: VideoStats,
    maxPending: Int = DEFAULT_MAX_PENDING,
    /** Monotonic clock (ns); injectable for tests. */
    private val clockNs: () -> Long = System::nanoTime,
) {
    companion object {
        /** Depth used before the stream rate is known: [depthForFps] at 120 fps. */
        const val DEFAULT_MAX_PENDING = 8
        const val MIN_PENDING = 2
        const val MAX_PENDING = 8
        /** Network bunch the queue absorbs without a reset (T-121): about one large IDR's transfer time. */
        const val BURST_MS = 64
        /** Minimum time between keyframe requests (T-121); equals the activity's KEYFRAME_RETRY_MS. */
        const val HOLDOFF_MS = 500L
        /** Arrival gaps kept for the overflow diagnostic. */
        const val GAP_HISTORY = 8
        /** T-219: consumer id that takes frames regardless of the owner. Generation ids are > 0. */
        const val ANY_CONSUMER = -1
        /** T-219: no consumer owns the queue (frames wait, bounded as always). */
        const val NO_CONSUMER = 0

        /** Queue depth for a stream of [fps]: [BURST_MS] worth of frames, clamped to [MIN_PENDING]..[MAX_PENDING]. */
        fun depthForFps(fps: Int): Int {
            if (fps <= 0) return DEFAULT_MAX_PENDING
            val n = (fps.toLong() * BURST_MS + 999) / 1000
            return n.toInt().coerceIn(MIN_PENDING, MAX_PENDING)
        }
    }

    /** Where a KEYFRAME_REQUEST came from (logging). */
    enum class Source(val logName: String) {
        OVERFLOW("overflow"), DEFERRED("deferred"), RETRY("retry"), RESET("reset"), ERROR("error")
    }

    /** Snapshot of an overflow (T-121 root-cause line). */
    class Overflow(
        /** Non-config frames pending, the incoming one included. */
        val pending: Int,
        val limit: Int,
        /** Position of the incoming frame after the last keyframe (keyframe = 0), or -1 when none was seen. */
        val sinceKeyframe: Long,
        /** Last arrival gaps in microseconds, oldest first, the incoming frame's gap last. */
        val gapsUs: LongArray,
        /** True if FRAMES_DROPPED was produced; false if held by the request limit. */
        val requested: Boolean,
        /** Time since the previous request in milliseconds, or -1 when there was none. */
        val sinceRequestMs: Long,
    )

    /** Per-window counters (T-121), see [counters]. */
    data class Counters(
        val kfRequests: Long, val kfHeld: Long, val overflows: Long, val maxPending: Int,
        /** T-252: catch-ups started (each would have been a flush + keyframe request). */
        val catchUps: Long = 0,
    )

    /** T-073 receive-path trace (null = off): stamps the fate of every offered frame. */
    @Volatile var trace: PaceTrace? = null

    /** Called outside the lock on every overflow (any thread). */
    @Volatile var onOverflow: ((Overflow) -> Unit)? = null

    /** T-252: called outside the lock when a catch-up ends (the TAIL was taken): frames of the backlog, ms it took. */
    @Volatile var onCatchUp: ((frames: Int, ms: Long) -> Unit)? = null

    /**
     * T-252: a catch-up that ran out of time inside [awaitNext] produced this KEYFRAME_REQUEST (any thread, outside the
     * lock); the owner must send it (offer() returns its requests, take() cannot).
     */
    @Volatile var onExpired: ((reason: Int) -> Unit)? = null

    /** Called outside the lock with every request the queue produces or allows (any thread); for logging. */
    @Volatile var onRequest: ((reason: Int, source: Source) -> Unit)? = null

    private val lock = Object()
    private val queue = ArrayDeque<VideoFrame>()

    /** Consumer parked in [awaitNext] (T-077), unparked by [offer] after it releases the lock. */
    @Volatile private var waiter: Thread? = null

    /** T-219: generation whose consumer may take frames; written under [lock], volatile for the early exit. */
    @Volatile private var owner = NO_CONSUMER

    /** Tests only (T-219 barrier): runs in [awaitNext] on the consumer's thread right before each park. */
    @Volatile internal var parkHook: (() -> Unit)? = null
    private var waitingKeyframe = true
    private val retryBackoff = KeyframeRetryBackoff() // decision 0038 section 7
    private var lastConfig: VideoFrame? = null

    private var limit = maxPending.coerceAtLeast(1)

    // T-121 request limit and diagnostics (guarded by lock).
    private var lastRequestNs = 0L
    private var hasRequested = false
    private var heldRequest = false
    private var sinceKeyframe = -1L
    private val arrivals = LongArray(GAP_HISTORY + 1)
    private var arrivalCount = 0
    private var kfRequests = 0L
    private var kfHeld = 0L
    private var overflows = 0L
    private var maxSeen = 0

    // T-252 catch-up (guarded by lock).
    private var depthCatchUp = 0
    private var bytesCatchUp = CatchUp.MAX_BACKLOG_BYTES
    private var catchingUp = false
    /** Frames handed out as SKIP whose TAIL has not been taken yet. */
    private var skippedOut = 0
    private var catchStartNs = 0L
    private val maxCatchUpNs = CatchUp.MAX_CATCH_UP_MS * 1_000_000L
    private var catchUps = 0L

    /** Depth limit in non-config frames; applies from the next frame on. */
    var maxPending: Int
        get() = synchronized(lock) { limit }
        set(v) = synchronized(lock) { limit = v.coerceAtLeast(1) }

    /** T-252: most non-config frames a backlog may reach before it is dropped as before; 0 = catch-up off. */
    var catchUpDepth: Int
        get() = synchronized(lock) { depthCatchUp }
        set(v) = synchronized(lock) { depthCatchUp = v.coerceAtLeast(0) }

    /** T-252: payload bytes a backlog may reach before it is dropped as before. */
    var catchUpMaxBytes: Long
        get() = synchronized(lock) { bytesCatchUp }
        set(v) = synchronized(lock) { bytesCatchUp = v.coerceAtLeast(0) }

    /** True while a backlog is being caught up (pure query). */
    internal fun isCatchingUp(): Boolean = synchronized(lock) { catchingUp }

    /** Returns the KEYFRAME_REQUEST reason to send now, or null. */
    fun offer(frame: VideoFrame): Int? {
        var request: Int? = null
        var source = Source.OVERFLOW
        var overflow: Overflow? = null
        val tr = trace
        synchronized(lock) {
            val nowNs = clockNs()
            stats.onReceived(frame.data.size, isConfig = frame.isCodecConfig)
            if (!frame.isCodecConfig) markArrival(nowNs)
            when {
                frame.isCodecConfig -> {
                    queue.removeAll { it.isCodecConfig }
                    tr?.onRxAction(frame.frameSeq, nowNs, PaceTrace.RX_CONFIG)
                    queue.addFirst(frame)
                    lastConfig = frame
                }
                frame.isKeyframe -> {
                    dropPending(tr, nowNs)
                    endCatchUp(forgetSkipped = false) // if frames were skipped, the keyframe is the TAIL (shown at once)
                    tr?.onRxAction(frame.frameSeq, nowNs, PaceTrace.RX_QUEUED)
                    queue.addLast(frame)
                    waitingKeyframe = false
                    retryBackoff.reset() // decision 0038: a keyframe ends the STARTUP repeat backoff
                    heldRequest = false // the keyframe answers it
                    sinceKeyframe = 0
                    notePending()
                }
                waitingKeyframe -> {
                    stats.onDropped(1)
                    tr?.onRxAction(frame.frameSeq, nowNs, PaceTrace.RX_GATE_DROP)
                    if (heldRequest && mayRequest(nowNs)) {
                        heldRequest = false
                        request = KeyframeRequest.FRAMES_DROPPED
                        source = Source.DEFERRED
                        recordRequest(nowNs)
                    }
                }
                else -> {
                    if (sinceKeyframe >= 0) sinceKeyframe++
                    queue.addLast(frame)
                    val n = notePending()
                    // A catch-up that has not got the queue back under the normal depth in time is not shrinking.
                    val expired = catchingUp && nowNs - catchStartNs > maxCatchUpNs
                    if (n > limit && n <= depthCatchUp && !expired && pendingBytes() <= bytesCatchUp) {
                        // T-252: a backlog inside the bounds is decoded and caught up, not flushed.
                        if (!catchingUp) {
                            catchingUp = true
                            catchStartNs = nowNs // every episode gets its own deadline, whatever skippedOut is
                            catchUps++
                        }
                        tr?.onRxAction(frame.frameSeq, nowNs, PaceTrace.RX_QUEUED)
                    } else if (n > limit) {
                        overflows++
                        val sinceReqMs = if (hasRequested) (nowNs - lastRequestNs) / 1_000_000 else -1L
                        val send = mayRequest(nowNs)
                        overflow = Overflow(n, limit, sinceKeyframe, gapsUs(), send, sinceReqMs)
                        stats.onDropped(1) // the incoming frame counts among the dropped
                        queue.removeLast()
                        tr?.onRxAction(frame.frameSeq, nowNs, PaceTrace.RX_QUEUE_DROP)
                        dropPending(tr, nowNs)
                        endCatchUp(forgetSkipped = false)
                        waitingKeyframe = true
                        if (send) {
                            request = KeyframeRequest.FRAMES_DROPPED
                            recordRequest(nowNs)
                        } else {
                            heldRequest = true
                            kfHeld++
                        }
                    } else {
                        tr?.onRxAction(frame.frameSeq, nowNs, PaceTrace.RX_QUEUED)
                    }
                }
            }
        }
        waiter?.let(LockSupport::unpark) // outside the lock: the woken consumer never blocks on it
        overflow?.let { o -> onOverflow?.invoke(o) }
        request?.let { r -> onRequest?.invoke(r, source) }
        return request
    }

    /**
     * Next frame for the decoder, parking up to [timeoutNs] (T-077), with a direct hand-off:
     * [offer] unparks the waiting thread once it has left the lock. One consumer
     * thread at a time. No lost wake-ups: the waiter is published before the queue is re-checked, and an unpark that
     * comes before the park leaves a permit. Null on timeout, or at once if the thread is interrupted (flag kept).
     *
     * T-112: `parkNanos` may return early (spurious wake-up, or a stale permit left on the thread by an AQS lock or by
     * an [offer] that read [waiter] just before it was cleared), so the wait re-parks for the time left until the
     * deadline instead of giving up after the first wake-up.
     *
     * T-286: [abort] (consumer's thread) is checked after the waiter is published and before every park; true leaves
     * with null. The condition's writer must call [nudge] after making it true, so the consumer may park for long
     * (event-driven) and still leave at once; no lost wake-up (see [nudge]).
     */
    fun awaitNext(timeoutNs: Long, consumer: Int = ANY_CONSUMER, mark: TakeMark? = null, abort: (() -> Boolean)? = null): VideoFrame? {
        mark?.value = CatchUp.NONE
        take(consumer, mark)?.let { return it }
        if (timeoutNs <= 0 || !owns(consumer)) return null
        val deadline = System.nanoTime() + timeoutNs
        val self = Thread.currentThread()
        waiter = self
        try {
            while (true) {
                take(consumer, mark)?.let { return it }
                // T-219: retired while waiting: leave at once and leave the frames to the owner.
                if (!owns(consumer)) return null
                if (abort != null && abort()) return null
                val left = deadline - System.nanoTime()
                if (left <= 0 || self.isInterrupted) return null // interrupted: parkNanos would not block, never spin
                parkHook?.invoke()
                LockSupport.parkNanos(this, left)
            }
        } finally {
            if (waiter === self) waiter = null // never clear another consumer's registration
        }
    }

    /**
     * T-286: wakes a consumer parked in [awaitNext] so it re-evaluates its `abort` condition. Call it after the
     * condition became true (and was written with volatile/atomic semantics). No lost wake-up: the consumer publishes
     * [waiter] and only then reads the condition; this writes the condition and only then reads [waiter]. Either the
     * consumer sees the condition, or this sees the consumer (and the unpark leaves a permit if it is not parked yet).
     */
    fun nudge() { waiter?.let(LockSupport::unpark) }

    /** T-219: the ownership check and the removal are one step under [lock], so a revoked consumer takes nothing. */
    private fun take(consumer: Int, mark: TakeMark?): VideoFrame? {
        var frame: VideoFrame? = null
        var doneFrames = -1
        var doneMs = 0L
        var expiredRequest = -1
        synchronized(lock) {
            if (!owns(consumer)) return null
            // T-252 review 2: the catch-up deadline holds without new arrivals too (burst, then silence, slow decode).
            val nowNs = clockNs()
            // The deadline only fires while the backlog is still above the normal depth: one that has drained to
            // maxPending or less is never flushed, the catch-up just goes on skipping to the newest frame.
            if (catchingUp && nowNs - catchStartNs > maxCatchUpNs && pendingCount() > limit) {
                overflows++
                dropPending(trace, nowNs)
                endCatchUp(forgetSkipped = false) // the next frame is the keyframe: shown at once (TAIL)
                waitingKeyframe = true
                if (mayRequest(nowNs)) {
                    heldRequest = false
                    recordRequest(nowNs)
                    expiredRequest = KeyframeRequest.FRAMES_DROPPED
                } else {
                    heldRequest = true
                    kfHeld++
                }
                return@synchronized
            }
            val f = queue.removeFirstOrNull() ?: return null
            frame = f
            var m = CatchUp.NONE
            if (!f.isCodecConfig) {
                if (catchingUp && pendingCount() > 0) {
                    m = CatchUp.SKIP
                    skippedOut++
                } else if (catchingUp || skippedOut > 0) {
                    // The newest frame of the backlog (or the first one after a flush that ended the catch-up).
                    m = CatchUp.TAIL
                    doneFrames = skippedOut + 1
                    doneMs = ((clockNs() - catchStartNs) / 1_000_000).coerceAtLeast(0)
                    catchingUp = false
                    skippedOut = 0
                }
            }
            mark?.value = m
        }
        if (expiredRequest >= 0) {
            onRequest?.invoke(expiredRequest, Source.OVERFLOW)
            onExpired?.invoke(expiredRequest)
        }
        if (doneFrames >= 0) onCatchUp?.invoke(doneFrames, doneMs)
        return frame
    }

    /** T-252: a flush or restart ends the catch-up; [forgetSkipped] also forgets the frames already handed out as SKIP. */
    private fun endCatchUp(forgetSkipped: Boolean) {
        catchingUp = false
        if (forgetSkipped) skippedOut = 0
    }

    private fun owns(consumer: Int) = consumer == ANY_CONSUMER || consumer == owner

    /**
     * T-219: [gen] (> 0) owns the queue from now on; any other consumer takes nothing. Call before [gen]'s consumer
     * starts and before frames of its configuration are admitted. A consumer parked in [awaitNext] is woken (outside the
     * lock) so a revoked one leaves at once.
     */
    fun assignConsumer(gen: Int) {
        require(gen > 0) { "consumer generation must be > 0" }
        synchronized(lock) { owner = gen }
        waiter?.let(LockSupport::unpark)
    }

    /** T-219: [gen] is retired: if it still owns the queue, nobody does until the next [assignConsumer]. */
    fun revokeConsumer(gen: Int) {
        synchronized(lock) { if (owner == gen) owner = NO_CONSUMER }
        waiter?.let(LockSupport::unpark)
    }

    fun pending(): Int = synchronized(lock) { queue.size }

    /** Decoder error: drops pending frames and closes the gate; returns the request reason (always sent). */
    internal fun onDecoderError(): Int = onDecoderErrorIfOwner(ANY_CONSUMER)!!

    /**
     * T-219: [onDecoderError] from [consumer]'s decoder thread: only while it owns the queue. A retired consumer changes
     * nothing and produces no request (null): the frames belong to the next generation.
     */
    fun onDecoderErrorIfOwner(consumer: Int): Int? {
        synchronized(lock) {
            if (!owns(consumer)) return null
            val now = clockNs()
            dropPending(trace, now)
            endCatchUp(forgetSkipped = true)
            waitingKeyframe = true
            heldRequest = false
            recordRequest(now)
        }
        onRequest?.invoke(KeyframeRequest.DECODE_ERROR, Source.ERROR)
        return KeyframeRequest.DECODE_ERROR
    }

    /**
     * Restart (surface came back, codec recreated): clears frames, closes the gate, replays the last
     * CODEC_CONFIG. Returns [reason] (the request to send; always sent, restarts the hold-off).
     */
    fun reset(reason: Int = KeyframeRequest.STARTUP, keepConfig: Boolean = true): Int =
        resetIfOwner(ANY_CONSUMER, reason, keepConfig)!!

    /**
     * T-219: [reset] from [consumer]'s decoder thread (codec restart after a decode error): only while it owns the
     * queue. A retired consumer changes nothing and produces no request (null).
     */
    fun resetIfOwner(consumer: Int, reason: Int, keepConfig: Boolean = true): Int? {
        synchronized(lock) {
            if (!owns(consumer)) return null
            val now = clockNs()
            trace?.let { t -> for (f in queue) t.onRxAction(f.frameSeq, now, PaceTrace.RX_RESET_DROP) }
            queue.clear()
            endCatchUp(forgetSkipped = true)
            stats.breakGaps()
            waitingKeyframe = true
            heldRequest = false
            sinceKeyframe = -1
            arrivalCount = 0
            if (!keepConfig) lastConfig = null // new stream configuration: the old parameter sets are invalid
            lastConfig?.let { queue.addLast(it) }
            recordRequest(now)
        }
        onRequest?.invoke(reason, if (reason == KeyframeRequest.DECODE_ERROR) Source.ERROR else Source.RESET)
        return reason
    }

    internal fun isWaitingKeyframe(): Boolean = synchronized(lock) { waitingKeyframe }

    /**
     * Periodic retry while gated (T-121): true when the gate is closed and no request went out for [HOLDOFF_MS].
     * The caller must then send a request; this counts it as sent (it restarts the hold-off).
     */
    fun takeRetry(): Boolean {
        synchronized(lock) {
            val now = clockNs()
            if (!waitingKeyframe || !mayRequest(now)) return false
            // Decision 0038 section 7: the repeat waits 500, 1000, 2000, then 4000 ms after the previous request.
            if (hasRequested && now - lastRequestNs < retryBackoff.delayMs * 1_000_000) return false
            heldRequest = false
            val used = retryBackoff.delayMs
            recordRequest(now) // resets the backoff: any other request starts it over ...
            retryBackoff.restore(used)
            retryBackoff.onRepeat() // ... but a repeat continues the sequence
        }
        onRequest?.invoke(KeyframeRequest.STARTUP, Source.RETRY)
        return true
    }

    /** Counters of the window (requests produced or allowed, held, overflows, deepest queue); [reset] starts a new one. */
    fun counters(reset: Boolean = false): Counters = synchronized(lock) {
        val c = Counters(kfRequests, kfHeld, overflows, maxSeen, catchUps)
        if (reset) {
            kfRequests = 0; kfHeld = 0; overflows = 0; maxSeen = pendingCount(); catchUps = 0
        }
        c
    }

    private fun pendingCount() = queue.count { !it.isCodecConfig }

    private fun pendingBytes(): Long {
        var b = 0L
        for (f in queue) if (!f.isCodecConfig) b += f.data.size
        return b
    }

    private fun notePending(): Int {
        val n = pendingCount()
        if (n > maxSeen) maxSeen = n
        return n
    }

    private fun mayRequest(nowNs: Long) = !hasRequested || nowNs - lastRequestNs >= HOLDOFF_MS * 1_000_000

    private fun recordRequest(nowNs: Long) {
        retryBackoff.reset()
        hasRequested = true
        lastRequestNs = nowNs
        kfRequests++
    }

    private fun markArrival(nowNs: Long) {
        if (arrivalCount == arrivals.size) {
            System.arraycopy(arrivals, 1, arrivals, 0, arrivals.size - 1)
            arrivalCount--
        }
        arrivals[arrivalCount++] = nowNs
    }

    private fun gapsUs(): LongArray =
        LongArray((arrivalCount - 1).coerceAtLeast(0)) { i -> (arrivals[i + 1] - arrivals[i]) / 1000 }

    private fun dropPending(tr: PaceTrace? = null, nowNs: Long = 0L) {
        val n = pendingCount()
        if (n > 0) {
            if (tr != null) for (f in queue) if (!f.isCodecConfig) tr.onRxAction(f.frameSeq, nowNs, PaceTrace.RX_PENDING_DROP)
            stats.onDropped(n)
            queue.removeAll { !it.isCodecConfig }
        }
    }
}
