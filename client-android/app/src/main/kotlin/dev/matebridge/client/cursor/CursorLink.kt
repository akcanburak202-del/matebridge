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
 * - [lastStateMs] is the arrival time of the latest state of an enabled session; the timeout in [CursorPrefsPolicy] reads it.
 *
 * [nowMs] is the client clock (`SystemClock.elapsedRealtime`).
 */
class CursorLink<B : Any>(
    val shapes: CursorShapes<B>,
    val stats: CursorStats,
    private val nowMs: () -> Long,
    private val onFrame: (CursorFrame?) -> Unit,
) {
    val slot = CursorStateSlot()

    @Volatile private var armedGen = -1

    /** The host was told `CURSOR_PREFS(1)` and states are wanted ([enable]). */
    @Volatile var enabled = false
        private set

    @Volatile var lastStateMs = 0L
        private set

    /** A new control connection [gen] starts (or takes over): states and shapes of the previous one are gone. */
    fun beginSession(gen: Int) {
        armedGen = gen
        reset()
    }

    /** The control connection ended: nothing is drawn or accepted until the next [beginSession]. */
    fun endSession() {
        armedGen = -1
        reset()
    }

    /** The layer turns off or on: forgets the held state (the next one starts fresh), keeps shapes. */
    fun enable(on: Boolean) {
        enabled = on
        slot.clear()
        lastStateMs = 0L
        if (!on) onFrame(null)
    }

    private fun reset() {
        slot.clear()
        shapes.clear()
        lastStateMs = 0L
        onFrame(null)
    }

    /** Reader thread. */
    fun onMessage(msg: Message, gen: Int) {
        if (gen != armedGen) return
        when (msg) {
            is CursorShape -> {
                stats.onShape()
                shapes.onShape(msg)
            }
            is CursorState -> {
                if (!enabled) return
                val now = nowMs()
                lastStateMs = now
                stats.onState()
                shapes.use(msg.shapeId)
                if (slot.offer(msg, now)) onFrame(slot.latest()) else stats.onStale()
            }
            else -> Unit
        }
    }
}
