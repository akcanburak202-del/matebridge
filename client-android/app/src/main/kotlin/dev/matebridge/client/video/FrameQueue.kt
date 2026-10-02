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
 * T-121 request limit: after any KEYFRAME_REQUEST, no FRAMES_DROPPED request goes out for [HOLDOFF_MS], even if a
 * keyframe arrived in between (that is what breaks the IDR -> overflow -> request chain). A suppressed request is
 * held and goes out on the first frame offered after the hold-off while the gate is still closed. STARTUP
 * ([reset]) and DECODE_ERROR ([onDecoderError]) always go out at once and restart the hold-off.
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
    data class Counters(val kfRequests: Long, val kfHeld: Long, val overflows: Long, val maxPending: Int)

    /** T-073 receive-path trace (null = off): stamps the fate of every offered frame. */
    @Volatile var trace: PaceTrace? = null

    /** Called outside the lock on every overflow (any thread). */
    @Volatile var onOverflow: ((Overflow) -> Unit)? = null

    /** Called outside the lock with every request the queue produces or allows (any thread); for logging. */
    @Volatile var onRequest: ((reason: Int, source: Source) -> Unit)? = null

    private val lock = Object()
    private val queue = ArrayDeque<VideoFrame>()

    /** Consumer parked in [awaitNext] (T-077), unparked by [offer] after it releases the lock. */
    @Volatile private var waiter: Thread? = null
    private var waitingKeyframe = true
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

    /** Depth limit in non-config frames; applies from the next frame on. */
    var maxPending: Int
        get() = synchronized(lock) { limit }
        set(v) = synchronized(lock) { limit = v.coerceAtLeast(1) }

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
                    tr?.onRxAction(frame.frameSeq, nowNs, PaceTrace.RX_QUEUED)
                    queue.addLast(frame)
                    waitingKeyframe = false
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
                    if (n > limit) {
                        overflows++
                        val sinceReqMs = if (hasRequested) (nowNs - lastRequestNs) / 1_000_000 else -1L
                        val send = mayRequest(nowNs)
                        overflow = Overflow(n, limit, sinceKeyframe, gapsUs(), send, sinceReqMs)
                        stats.onDropped(1) // the incoming frame counts among the dropped
                        queue.removeLast()
                        tr?.onRxAction(frame.frameSeq, nowNs, PaceTrace.RX_QUEUE_DROP)
                        dropPending(tr, nowNs)
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
            lock.notifyAll()
        }
        waiter?.let(LockSupport::unpark) // outside the lock: the woken consumer never blocks on it
        overflow?.let { o -> onOverflow?.invoke(o) }
        request?.let { r -> onRequest?.invoke(r, source) }
        return request
    }

    /**
     * Next frame for the decoder, parking up to [timeoutNs] (T-077). Same frames as [poll], with a direct hand-off:
     * [offer] unparks the waiting thread once it has left the lock, instead of `notifyAll` inside it. One consumer
     * thread at a time. No lost wake-ups: the waiter is published before the queue is re-checked, and an unpark that
     * comes before the park leaves a permit. Null on timeout, or at once if the thread is interrupted (flag kept).
     *
     * T-112: `parkNanos` may return early (spurious wake-up, or a stale permit left on the thread by an AQS lock or by
     * an [offer] that read [waiter] just before it was cleared), so the wait re-parks for the time left until the
     * deadline instead of giving up after the first wake-up.
     */
    fun awaitNext(timeoutNs: Long): VideoFrame? {
        take()?.let { return it }
        if (timeoutNs <= 0) return null
        val deadline = System.nanoTime() + timeoutNs
        val self = Thread.currentThread()
        waiter = self
        try {
            while (true) {
                take()?.let { return it }
                val left = deadline - System.nanoTime()
                if (left <= 0 || self.isInterrupted) return null // interrupted: parkNanos would not block, never spin
                LockSupport.parkNanos(this, left)
            }
        } finally {
            waiter = null
        }
    }

    private fun take(): VideoFrame? = synchronized(lock) { queue.removeFirstOrNull() }

    /** Next frame for the decoder, waiting up to [timeoutMs]. Null on timeout. */
    fun poll(timeoutMs: Long): VideoFrame? = synchronized(lock) {
        if (queue.isEmpty() && timeoutMs > 0) lock.wait(timeoutMs)
        queue.removeFirstOrNull()
    }

    fun pending(): Int = synchronized(lock) { queue.size }

    /** Decoder error: drops pending frames and closes the gate; returns the request reason (always sent). */
    fun onDecoderError(): Int {
        synchronized(lock) {
            val now = clockNs()
            dropPending(trace, now)
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
    fun reset(reason: Int = KeyframeRequest.STARTUP, keepConfig: Boolean = true): Int {
        synchronized(lock) {
            val now = clockNs()
            trace?.let { t -> for (f in queue) t.onRxAction(f.frameSeq, now, PaceTrace.RX_RESET_DROP) }
            queue.clear()
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

    fun isWaitingKeyframe(): Boolean = synchronized(lock) { waitingKeyframe }

    /**
     * Periodic retry while gated (T-121): true when the gate is closed and no request went out for [HOLDOFF_MS].
     * The caller must then send a request; this counts it as sent (it restarts the hold-off).
     */
    fun takeRetry(): Boolean {
        synchronized(lock) {
            val now = clockNs()
            if (!waitingKeyframe || !mayRequest(now)) return false
            heldRequest = false
            recordRequest(now)
        }
        onRequest?.invoke(KeyframeRequest.STARTUP, Source.RETRY)
        return true
    }

    /** Counters of the window (requests produced or allowed, held, overflows, deepest queue); [reset] starts a new one. */
    fun counters(reset: Boolean = false): Counters = synchronized(lock) {
        val c = Counters(kfRequests, kfHeld, overflows, maxSeen)
        if (reset) {
            kfRequests = 0; kfHeld = 0; overflows = 0; maxSeen = pendingCount()
        }
        c
    }

    private fun pendingCount() = queue.count { !it.isCodecConfig }

    private fun notePending(): Int {
        val n = pendingCount()
        if (n > maxSeen) maxSeen = n
        return n
    }

    private fun mayRequest(nowNs: Long) = !hasRequested || nowNs - lastRequestNs >= HOLDOFF_MS * 1_000_000

    private fun recordRequest(nowNs: Long) {
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
