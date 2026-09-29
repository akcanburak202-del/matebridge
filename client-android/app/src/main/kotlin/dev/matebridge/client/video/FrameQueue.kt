package dev.matebridge.client.video

import dev.matebridge.client.protocol.KeyframeRequest
import dev.matebridge.client.protocol.VideoFrame

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

    private val lock = Object()
    private val queue = ArrayDeque<VideoFrame>()
    private var waitingKeyframe = true
    private var lastConfig: VideoFrame? = null

    /** Returns the KEYFRAME_REQUEST reason to send now, or null. */
    fun offer(frame: VideoFrame): Int? {
        var request: Int? = null
        synchronized(lock) {
            stats.onReceived(frame.data.size)
            when {
                frame.isCodecConfig -> {
                    queue.removeAll { it.isCodecConfig }
                    queue.addFirst(frame)
                    lastConfig = frame
                }
                frame.isKeyframe -> {
                    dropPending()
                    queue.addLast(frame)
                    waitingKeyframe = false
                }
                waitingKeyframe -> stats.onDropped(1)
                else -> {
                    queue.addLast(frame)
                    if (pendingCount() > MAX_PENDING) {
                        stats.onDropped(1) // the incoming frame counts among the dropped
                        queue.removeLast()
                        dropPending()
                        waitingKeyframe = true
                        request = KeyframeRequest.FRAMES_DROPPED
                    }
                }
            }
            lock.notifyAll()
        }
        return request
    }

    /** Next frame for the decoder, waiting up to [timeoutMs]. Null on timeout. */
    fun poll(timeoutMs: Long): VideoFrame? = synchronized(lock) {
        if (queue.isEmpty() && timeoutMs > 0) lock.wait(timeoutMs)
        queue.removeFirstOrNull()
    }

    fun pending(): Int = synchronized(lock) { queue.size }

    /** Decoder error: drops pending frames and closes the gate; returns the request reason. */
    fun onDecoderError(): Int = synchronized(lock) {
        dropPending()
        waitingKeyframe = true
        KeyframeRequest.DECODE_ERROR
    }

    /**
     * Restart (surface came back, codec recreated): clears frames, closes the gate, replays the last
     * CODEC_CONFIG. Returns [reason] (the request to send).
     */
    fun reset(reason: Int = KeyframeRequest.STARTUP): Int = synchronized(lock) {
        queue.clear()
        waitingKeyframe = true
        lastConfig?.let { queue.addLast(it) }
        reason
    }

    fun isWaitingKeyframe(): Boolean = synchronized(lock) { waitingKeyframe }

    private fun pendingCount() = queue.count { !it.isCodecConfig }

    private fun dropPending() {
        val n = pendingCount()
        if (n > 0) {
            stats.onDropped(n)
            queue.removeAll { !it.isCodecConfig }
        }
    }
}
