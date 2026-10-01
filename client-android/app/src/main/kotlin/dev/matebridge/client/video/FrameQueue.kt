package dev.matebridge.client.video

import dev.matebridge.client.protocol.KeyframeRequest
import dev.matebridge.client.protocol.VideoFrame
import java.util.concurrent.locks.LockSupport

/**
 * Bounded decoder input queue (PROTOCOL.md section 5). Pure Kotlin, thread-safe.
 *
 * Rules:
 *  - at most [MAX_PENDING] non-config frames wait for the decoder;
 *  - on overflow every pending non-config frame is dropped (the reference chain is broken anyway),
 *    the incoming frame is dropped too, and KEYFRAME_REQUEST(FRAMES_DROPPED) is produced;
 *  - until a keyframe arrives, non-keyframes are never queued (dropped and counted);
 *  - an arriving keyframe flushes older pending frames (stale) and re-opens the gate;
 *  - the latest CODEC_CONFIG is kept so it can be replayed after a codec restart.
 */
class FrameQueue(private val stats: VideoStats) {
    companion object {
        const val MAX_PENDING = 2
    }

    /** T-073 receive-path trace (null = off): stamps the fate of every offered frame. */
    @Volatile var trace: PaceTrace? = null

    private val lock = Object()
    private val queue = ArrayDeque<VideoFrame>()

    /** Consumer parked in [awaitNext] (T-077), unparked by [offer] after it releases the lock. */
    @Volatile private var waiter: Thread? = null
    private var waitingKeyframe = true
    private var lastConfig: VideoFrame? = null

    /** Returns the KEYFRAME_REQUEST reason to send now, or null. */
    fun offer(frame: VideoFrame): Int? {
        var request: Int? = null
        val tr = trace
        synchronized(lock) {
            val nowNs = if (tr != null) System.nanoTime() else 0L
            stats.onReceived(frame.data.size, isConfig = frame.isCodecConfig)
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
                }
                waitingKeyframe -> {
                    stats.onDropped(1)
                    tr?.onRxAction(frame.frameSeq, nowNs, PaceTrace.RX_GATE_DROP)
                }
                else -> {
                    queue.addLast(frame)
                    if (pendingCount() > MAX_PENDING) {
                        stats.onDropped(1) // the incoming frame counts among the dropped
                        queue.removeLast()
                        tr?.onRxAction(frame.frameSeq, nowNs, PaceTrace.RX_QUEUE_DROP)
                        dropPending(tr, nowNs)
                        waitingKeyframe = true
                        request = KeyframeRequest.FRAMES_DROPPED
                    } else {
                        tr?.onRxAction(frame.frameSeq, nowNs, PaceTrace.RX_QUEUED)
                    }
                }
            }
            lock.notifyAll()
        }
        waiter?.let(LockSupport::unpark) // outside the lock: the woken consumer never blocks on it
        return request
    }

    /**
     * Next frame for the decoder, parking up to [timeoutNs] (T-077). Same frames as [poll], with a direct hand-off:
     * [offer] unparks the waiting thread once it has left the lock, instead of `notifyAll` inside it. One consumer
     * thread at a time. No lost wake-ups: the waiter is published before the queue is re-checked, and an unpark that
     * comes before the park leaves a permit. Null on timeout (or a spurious/stale wake-up with nothing queued).
     */
    fun awaitNext(timeoutNs: Long): VideoFrame? {
        take()?.let { return it }
        if (timeoutNs <= 0) return null
        waiter = Thread.currentThread()
        try {
            take()?.let { return it }
            LockSupport.parkNanos(this, timeoutNs)
        } finally {
            waiter = null
        }
        return take()
    }

    private fun take(): VideoFrame? = synchronized(lock) { queue.removeFirstOrNull() }

    /** Next frame for the decoder, waiting up to [timeoutMs]. Null on timeout. */
    fun poll(timeoutMs: Long): VideoFrame? = synchronized(lock) {
        if (queue.isEmpty() && timeoutMs > 0) lock.wait(timeoutMs)
        queue.removeFirstOrNull()
    }

    fun pending(): Int = synchronized(lock) { queue.size }

    /** Decoder error: drops pending frames and closes the gate; returns the request reason. */
    fun onDecoderError(): Int = synchronized(lock) {
        dropPending(trace, System.nanoTime())
        waitingKeyframe = true
        KeyframeRequest.DECODE_ERROR
    }

    /**
     * Restart (surface came back, codec recreated): clears frames, closes the gate, replays the last
     * CODEC_CONFIG. Returns [reason] (the request to send).
     */
    fun reset(reason: Int = KeyframeRequest.STARTUP, keepConfig: Boolean = true): Int = synchronized(lock) {
        trace?.let { t -> val now = System.nanoTime(); for (f in queue) t.onRxAction(f.frameSeq, now, PaceTrace.RX_RESET_DROP) }
        queue.clear()
        stats.breakGaps()
        waitingKeyframe = true
        if (!keepConfig) lastConfig = null // new stream configuration: the old parameter sets are invalid
        lastConfig?.let { queue.addLast(it) }
        reason
    }

    fun isWaitingKeyframe(): Boolean = synchronized(lock) { waitingKeyframe }

    private fun pendingCount() = queue.count { !it.isCodecConfig }

    private fun dropPending(tr: PaceTrace? = null, nowNs: Long = 0L) {
        val n = pendingCount()
        if (n > 0) {
            if (tr != null) for (f in queue) if (!f.isCodecConfig) tr.onRxAction(f.frameSeq, nowNs, PaceTrace.RX_PENDING_DROP)
            stats.onDropped(n)
            queue.removeAll { !it.isCodecConfig }
        }
    }
}
