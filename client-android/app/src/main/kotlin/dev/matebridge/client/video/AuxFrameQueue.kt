package dev.matebridge.client.video

import dev.matebridge.client.protocol.KeyframeRequest
import dev.matebridge.client.protocol.VideoFrame
import java.util.concurrent.locks.ReentrantLock
import kotlin.concurrent.withLock

/**
 * Bounded input queue of the auxiliary stream (decision 0034, PROTOCOL.md section 5 "Paketlenmiş tam renk"). Pure
 * Kotlin, thread-safe, one consumer ([AuxDecoder]). Same rules as the main [FrameQueue] but with its own, simpler
 * accounting so a bad auxiliary stream never touches the main stream's statistics or `video_health`:
 *  - at most [depth] non-config frames wait; on overflow every pending frame and the incoming one are dropped (the
 *    reference chain is broken) and `KEYFRAME_REQUEST(FRAMES_DROPPED, view = 1)` is due;
 *  - until a keyframe arrives, non-keyframes are dropped; a keyframe flushes older pending frames;
 *  - the latest CODEC_CONFIG is kept (replayed after a decoder rebuild);
 *  - at most one request per [HOLDOFF_MS] except [reset] (STARTUP / DECODE_ERROR go out at once); a suppressed request
 *    is held and goes out with the first frame offered after the hold-off while the gate is closed ([takeRetry] too).
 */
class AuxFrameQueue(
    depth: Int,
    private val clockNs: () -> Long = System::nanoTime,
) {
    companion object {
        const val HOLDOFF_MS = FrameQueue.HOLDOFF_MS
    }

    @Volatile var depth: Int = depth.coerceAtLeast(1)

    data class Counters(val received: Long, val dropped: Long, val overflows: Long, val kfRequests: Long)

    private val lock = ReentrantLock()
    private val nonEmpty = lock.newCondition()
    private val pending = ArrayDeque<VideoFrame>()
    private var config: VideoFrame? = null
    private var waitingKeyframe = true
    private var heldRequest = false
    private var hasRequested = false
    private var lastRequestNs = 0L
    private var received = 0L
    private var dropped = 0L
    private var overflows = 0L
    private var kfRequests = 0L

    /** Returns the KEYFRAME_REQUEST reason to send (with `view = 1`) now, or null. */
    fun offer(frame: VideoFrame): Int? {
        var request: Int? = null
        lock.withLock {
            val now = clockNs()
            received++
            when {
                frame.isCodecConfig -> {
                    config = frame
                    pending.removeAll { it.isCodecConfig }
                    pending.addFirst(frame)
                }
                frame.isKeyframe -> {
                    dropped += pending.count { !it.isCodecConfig }
                    pending.removeAll { !it.isCodecConfig }
                    pending.addLast(frame)
                    waitingKeyframe = false
                    heldRequest = false
                }
                waitingKeyframe -> {
                    dropped++
                    if (heldRequest && mayRequest(now)) {
                        heldRequest = false
                        record(now)
                        request = KeyframeRequest.FRAMES_DROPPED
                    }
                }
                else -> {
                    pending.addLast(frame)
                    if (pending.count { !it.isCodecConfig } > depth) {
                        overflows++
                        dropped += pending.count { !it.isCodecConfig }
                        pending.removeAll { !it.isCodecConfig }
                        waitingKeyframe = true
                        if (mayRequest(now)) {
                            record(now)
                            request = KeyframeRequest.FRAMES_DROPPED
                        } else {
                            heldRequest = true
                        }
                    }
                }
            }
            nonEmpty.signalAll()
        }
        return request
    }

    /** Next frame for the decoder (CODEC_CONFIG first), waiting up to [timeoutNs]; null on timeout. */
    fun awaitNext(timeoutNs: Long): VideoFrame? = lock.withLock {
        if (pending.isEmpty() && timeoutNs > 0) {
            nonEmpty.awaitNanos(timeoutNs)
        }
        pending.removeFirstOrNull()
    }

    /**
     * Decoder (re)built or failed: drops pending frames, keeps the stored CODEC_CONFIG at the front, closes the keyframe
     * gate and returns [reason] (always due at once, restarts the hold-off).
     */
    fun reset(reason: Int): Int = lock.withLock {
        dropped += pending.count { !it.isCodecConfig }
        pending.clear()
        config?.let { pending.addFirst(it) }
        waitingKeyframe = true
        heldRequest = false
        record(clockNs())
        reason
    }

    /** Periodic retry while gated: true when the gate is closed and no request went out for [HOLDOFF_MS]. */
    fun takeRetry(): Boolean = lock.withLock {
        val now = clockNs()
        if (!waitingKeyframe || !mayRequest(now)) return false
        record(now)
        true
    }

    fun isWaitingKeyframe(): Boolean = lock.withLock { waitingKeyframe }
    fun pendingFrames(): Int = lock.withLock { pending.count { !it.isCodecConfig } }

    fun counters(reset: Boolean = false): Counters = lock.withLock {
        val c = Counters(received, dropped, overflows, kfRequests)
        if (reset) { received = 0; dropped = 0; overflows = 0; kfRequests = 0 }
        c
    }

    /** Wakes a waiting consumer (shutdown). */
    fun wake() = lock.withLock { nonEmpty.signalAll() }

    private fun mayRequest(now: Long) = !hasRequested || now - lastRequestNs >= HOLDOFF_MS * 1_000_000

    private fun record(now: Long) {
        hasRequested = true
        lastRequestNs = now
        kfRequests++
    }
}
