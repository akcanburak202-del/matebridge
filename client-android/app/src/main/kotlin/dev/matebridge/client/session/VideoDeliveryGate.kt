package dev.matebridge.client.session

import dev.matebridge.client.protocol.StreamConfig

/**
 * T-160: decides which video connection may hand frames to the renderer, and is the barrier behind
 * `VideoConn.abort()`. A frame is delivered only when all of these hold:
 *
 * - its connection is the open one ([SessionMachine.Action.OpenVideo]'s generation, not closed since): frames of a
 *   replaced or aborted connection (also complete records still buffered in its reader) never reach the decoder;
 * - its connection's `config_id` is the session's applied one (reset to -1 on CloseControl and on a migration's
 *   PromoteCandidate, i.e. at every session end; **not** on CloseVideo, because a STREAM_CONFIG is
 *   ApplyConfig → CloseVideo → OpenVideo and a video-only reconnect keeps the config);
 * - the renderer has installed exactly the applied config ([install] after its queue reset): until then frames of a
 *   new config are dropped instead of reaching the old codec (T-028 ordering). The check is by object identity, so the
 *   first config of every session (always `config_id` 1) is not mistaken for the previous session's. Dropped frames
 *   never enter the frame queue, so they cause no keyframe request and no decoder-health input.
 *
 * Threads: [onAction] on the session engine, [install] on the UI thread (from `VideoRenderer.reconfigure`), [deliver]
 * on video reader threads, [close] on the engine (`VideoConn.abort()`).
 *
 * Barrier: [deliver] runs its block under [lock], and [close] takes the same lock, so once [close] (or the CloseVideo /
 * OpenVideo that replaced the connection) returns, an in-flight delivery has finished and no later one starts.
 *
 * Lock order (why holding [lock] across the delivery cannot deadlock): the block is `SessionListener.onVideoFrame` →
 * `VideoRenderer.onFrame` → `FrameQueue.offer` (its own short lock; the decoder waits outside it) → a returned
 * KEYFRAME_REQUEST goes `trySend` → `ControlLink.send` → `SendQueue.offer` (its lock is never held while waiting:
 * `take()` waits in `lock.wait()`), and on the first overflow `ControlConn.abort()` (send queue abort, socket close,
 * key wipe) plus a non-blocking close-mailbox post; the vsync wake is a volatile write and a non-blocking `Handler.post`.
 * None of these waits for the engine or the UI thread, and neither of those holds any of these locks while it calls
 * [onAction], [close] or [install]. So [lock] is always the outermost lock and is held only for one short delivery.
 */
class VideoDeliveryGate {
    private val lock = Any()

    /** Generation of the video connection that may deliver (-1 = none). Guarded by [lock]. */
    private var openGen = -1
    private var appliedConfigId = -1
    /** The applied STREAM_CONFIG object (null after a session end) and the one the renderer installed. */
    private var applied: StreamConfig? = null
    private var installed: StreamConfig? = null

    /** config_id of the session's applied STREAM_CONFIG (-1 = none). */
    val currentConfigId: Int get() = synchronized(lock) { appliedConfigId }

    /** Engine thread: the gate's part of a machine action, before `SessionController` runs it. */
    fun onAction(a: SessionMachine.Action) {
        synchronized(lock) {
            when (a) {
                is SessionMachine.Action.ApplyConfig -> {
                    appliedConfigId = a.config.configId
                    applied = a.config
                }
                is SessionMachine.Action.CloseControl, is SessionMachine.Action.PromoteCandidate -> {
                    appliedConfigId = -1
                    applied = null
                }
                is SessionMachine.Action.OpenVideo -> openGen = a.gen
                SessionMachine.Action.CloseVideo -> openGen = -1
                else -> Unit
            }
        }
    }

    /** `VideoConn.abort()` of connection [gen]: no frame of it is delivered after this returns. A replaced gen is a no-op. */
    fun close(gen: Int) {
        synchronized(lock) { if (openGen == gen) openGen = -1 }
    }

    /** UI: the renderer has reset its queue for [config] (the object `onStreamConfig` carried) and feeds it from now on. */
    fun install(config: StreamConfig) {
        synchronized(lock) { installed = config }
    }

    /**
     * Reader thread: runs [block] (the delivery to the renderer) under the gate's lock when connection [gen], opened for
     * [configId], may deliver now; returns whether it ran. [block] must not block (see the class comment).
     */
    fun deliver(gen: Int, configId: Int, block: () -> Unit): Boolean {
        synchronized(lock) {
            val cfg = applied
            if (gen != openGen || configId != appliedConfigId || cfg == null || cfg !== installed) return false
            block()
            return true
        }
    }
}
