package dev.matebridge.client.cursor

import dev.matebridge.client.protocol.CursorShape
import dev.matebridge.client.protocol.CursorState
import dev.matebridge.client.protocol.Message

/**
 * The reader-thread side of the local cursor (decision 0036, T-276): cursor messages of the armed control connection go
 * straight here (never through the session engine queue), shapes into the cache, states into the newest-wins slot, and
 * [onFrame] asks the layer to redraw. Everything here is non-blocking and allocation-light.
 *
 * - A message of another connection generation than the armed one is dropped ([beginSession] arms, [endSession]
 *   disarms): a reader can outlive its connection.
 * - Shapes are cached even while the layer is off (the host believes we have them); states are used only while
 *   [enabled] (the host was told to leave the cursor to us).
 * - [lastStateMs] is the arrival time of the latest ACCEPTED (newest-seq) state of an enabled session; the timeout in [CursorPrefsPolicy] reads it.
 *
 * [nowMs] is the client clock (`SystemClock.elapsedRealtime`).
 */
class CursorLink<B : Any>(
    val shapes: CursorShapes<B>,
    val stats: CursorStats,
    private val nowMs: () -> Long,
    /** T-278: the local prediction (v2); fed every accepted state, switched with [enable], emptied with the session. */
    val predictor: CursorPredictor? = null,
    /** Client monotonic clock in microseconds (the PING/PONG clock) for [predictor]. */
    private val nowUs: () -> Long = { System.nanoTime() / 1000 },
    private val onFrame: (CursorFrame?) -> Unit,
) {
    val slot = CursorStateSlot()
    private val lock = Any()

    @Volatile private var armedGen = -1

    /** The host was told `CURSOR_PREFS(1)` and states are wanted ([enable]). */
    @Volatile var enabled = false
        private set

    @Volatile var lastStateMs = 0L
        private set

    /** A new control connection [gen] starts (or takes over): states and shapes of the previous one are gone. */
    fun beginSession(gen: Int) = synchronized(lock) {
        armedGen = gen
        reset()
    }

    /** The control connection ended: nothing is drawn or accepted until the next [beginSession]. */
    fun endSession() = synchronized(lock) {
        armedGen = -1
        reset()
    }

    /** The layer turns off or on: forgets the held state (the next one starts fresh), keeps shapes. */
    fun enable(on: Boolean) = synchronized(lock) {
        enabled = on
        predictor?.setLayerOn(on)
        predictor?.reset() // the next state starts a fresh anchor
        slot.clear()
        lastStateMs = 0L
        if (!on) onFrame(null)
    }

    private fun reset() {
        predictor?.reset()
        slot.clear()
        shapes.clear()
        lastStateMs = 0L
        onFrame(null)
    }

    /**
     * Reader thread. The generation and [enabled] checks and everything the message changes happen under one lock with
     * [beginSession], [endSession] and [enable]: a handler of an old connection that was paused between its checks and its
     * offer can never put its old (high) seq into the slot of the new session, which would reject the new session's
     * seqs (they start at 1) and freeze the cursor.
     */
    fun onMessage(msg: Message, gen: Int) {
        synchronized(lock) { accept(msg, gen) }
    }

    private fun accept(msg: Message, gen: Int) {
        if (gen != armedGen) return
        when (msg) {
            is CursorShape -> {
                stats.onShape()
                shapes.onShape(msg)
            }
            is CursorState -> {
                if (!enabled) return
                stats.onState()
                shapes.use(msg.shapeId)
                val now = nowMs()
                if (slot.offer(msg, now)) {
                    lastStateMs = now // only an accepted state keeps the timeout away: a frozen cursor must time out
                    predictor?.onState(msg, nowUs())
                    onFrame(slot.latest())
                } else {
                    stats.onStale()
                }
            }
            else -> Unit
        }
    }
}
