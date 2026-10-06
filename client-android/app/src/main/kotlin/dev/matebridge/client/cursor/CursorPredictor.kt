package dev.matebridge.client.cursor

import dev.matebridge.client.protocol.CursorState
import dev.matebridge.client.protocol.Message
import dev.matebridge.client.protocol.Pen
import dev.matebridge.client.protocol.PenSample
import dev.matebridge.client.protocol.PointerAbs
import dev.matebridge.client.protocol.PointerRel
import dev.matebridge.client.protocol.ReleaseAll
import kotlin.math.exp
import kotlin.math.hypot
import kotlin.math.min
import kotlin.math.roundToInt

/**
 * Local cursor v2 (decision 0036, T-278): the tablet guesses where the Mac cursor is going from the input it just sent, so
 * the drawn cursor does not wait for the round trip. Drawing only: nothing here feeds the input path, and the host's
 * `CURSOR_STATE` stays the truth.
 *
 * Model. The newest accepted state is the [Anchor]: a position plus the moment the host sampled it, on the client clock.
 * Every input message that went out is kept in a bounded ring with its send time: relative motion (points) from
 * `POINTER_REL`, absolute points from `POINTER_ABS` and the newest in-range sample of a `PEN`. An event reaches the host at
 * `send + oneWay`; the anchor already contains it when that is not after the anchor's sample time. The prediction at time `t`
 * is the anchor position, then every event that is not in the anchor yet and was sent at or before `t`, in order: a relative
 * delta adds (clamped to the screen after each step, as the Mac clamps at the edge), an absolute point replaces the position.
 * Events older than [SETTLE_US] are treated as settled, so when the host stops (or never moved: clamped, ignored) the
 * prediction falls back to the host's position within that time.
 *
 * Reconciling (draw thread). A new state moves the anchor; the shown position must not jump for a small disagreement, so the
 * difference between the old forecast and the new one becomes a correction that decays within a frame or two, and a
 * disagreement beyond [SMOOTH_PT] (an app moved or warped the cursor) is shown at once.
 *
 * Measuring. When a state arrives, the previous anchor's forecast for that state's sample time is compared with the state:
 * `pred_err` (and `hold_err`, what staying at the previous state would have missed by) go to [CursorStats].
 *
 * Threads: [onSent] and [advance] run on the UI thread, [onState] on the control reader thread; one lock guards everything
 * (every critical section is a few hundred array steps at most). Clock: `nowUs` values are the client monotonic clock in
 * microseconds (`System.nanoTime() / 1000`, the same one PING/PONG uses). [hostToClientUs] maps a host time to that clock
 * (null while the offset is unknown); [oneWayUs] is the one-way delay estimate (best RTT / 2, null while unknown).
 */
class CursorPredictor(
    private val hostToClientUs: (Long) -> Long?,
    private val oneWayUs: () -> Long?,
    private val stats: CursorStats? = null,
) {
    /** The newest accepted state: normalized position, visibility and the host sample time as client-clock microseconds. */
    class Anchor(val seq: Long, val xNorm: Int, val yNorm: Int, val visible: Boolean, val sampleUs: Long)

    /** A predicted position (normalized like `CURSOR_STATE`) and whether more frames are needed to finish moving. */
    class Result {
        var xNorm = 0
        var yNorm = 0

        /** True while the correction still decays or sent input is not in a state yet: ask for another frame. */
        var animating = false
    }

    private val lock = Any()

    // Event ring (oldest at [head]); parallel arrays, no allocation per event.
    private val sendUs = LongArray(CAP)
    private val kind = ByteArray(CAP)
    private val v0 = FloatArray(CAP)
    private val v1 = FloatArray(CAP)
    private var head = 0
    private var count = 0
    private var lastSendUs = 0L

    private var anchor: Anchor? = null

    // Mirror of the host's left-button owner (see [onSent]); guarded by [lock].
    private var owner = NO_OWNER
    private var penContact = false
    private val heldLeft = BooleanArray(4)

    // Reconciliation state (draw thread).
    private var shown: Anchor? = null
    private var corrX = 0f
    private var corrY = 0f
    private var lastAdvanceUs = 0L

    private val tmp = FloatArray(2)
    private val tmp2 = FloatArray(2)

    @Volatile private var widthPt = 0
    @Volatile private var heightPt = 0

    /** The developer switch (`cursor_predict`): false = never predict, the layer draws the host's position (v1). */
    @Volatile private var allowed = true

    /** The cursor layer is on (the host was told to leave the cursor to us). */
    @Volatile private var layerOn = false

    val active: Boolean get() = allowed && layerOn

    fun setAllowed(on: Boolean) {
        allowed = on
        if (!on) reset()
    }

    fun setLayerOn(on: Boolean) {
        layerOn = on
        if (!on) reset()
    }

    /** The stream's size in Mac points (`STREAM_CONFIG`); 0 = unknown, which switches the prediction off. */
    fun setStream(widthPt: Int, heightPt: Int) {
        this.widthPt = widthPt
        this.heightPt = heightPt
    }

    /** Forgets events, anchor and correction (session end, layer off). */
    fun reset() = synchronized(lock) {
        head = 0
        count = 0
        anchor = null
        shown = null
        corrX = 0f
        corrY = 0f
        lastAdvanceUs = 0L
    }

    /**
     * UI thread, after [msg] was handed to the connection at [nowUs]. Returns true when it moves the cursor, i.e. the layer
     * should redraw.
     *
     * Only the source the host listens to is predicted from (T-278 review). The host has one left-button owner
     * (`InputStateMachine`: OWN-1..4, PEN-6, GATE): while a source holds the left button (a drag) other sources' motion does
     * not move the Mac cursor, a pen contact takes the button from a pointer source, a pen hover moves the cursor only when
     * nobody holds the button, and a finger that does not hold the button never moves it (palm rejection). This class
     * mirrors that owner from the same messages (always, even while the layer is off, so a layer that turns on mid-drag is
     * only briefly wrong) and records an event only when the host would act on it. The finger gate is not mirrored: a press
     * the host gates out is assumed accepted.
     */
    fun onSent(msg: Message, nowUs: Long): Boolean = synchronized(lock) {
        when (msg) {
            is ReleaseAll -> { clearOwnership(); false }
            is PointerRel -> {
                val moves = pointer(SRC_REL, msg.buttons, msg.dx != 0f || msg.dy != 0f)
                moves && active && add(KIND_REL, msg.dx, msg.dy, nowUs)
            }
            is PointerAbs -> {
                val moves = pointer(if (msg.source == PointerAbs.SOURCE_TOUCH) SRC_TOUCH else SRC_MOUSE, msg.buttons, true)
                moves && active && add(KIND_ABS, msg.x.toFloat(), msg.y.toFloat(), nowUs)
            }
            is Pen -> {
                var last: PenSample? = null
                for (s in msg.samples) if (pen(s)) last = s
                last != null && active && add(KIND_ABS, last.x.toFloat(), last.y.toFloat(), nowUs)
            }
            else -> false
        }
    }

    /** Host rules for one pointer message of [src] (`handlePointer`). Returns whether the Mac cursor moves. */
    private fun pointer(src: Int, buttons: Int, hasMotion: Boolean): Boolean {
        val left = buttons and BUTTON_LEFT != 0
        val pressed = left && !heldLeft[src]
        val released = !left && heldLeft[src]
        val accept = pressed && owner == NO_OWNER
        val moves = hasMotion && when {
            owner == src || accept -> true
            owner != NO_OWNER -> false
            else -> src != SRC_TOUCH
        }
        if (accept) owner = src else if (released && owner == src) owner = NO_OWNER
        heldLeft[src] = left
        return moves
    }

    /** Host rules for one pen sample (`handlePen`). Returns whether the Mac cursor moves to it. */
    private fun pen(s: PenSample): Boolean {
        val inRange = s.flags and (PenSample.IN_RANGE or PenSample.CONTACT) != 0
        val contact = s.flags and PenSample.CONTACT != 0
        if (!inRange) { // leaving: a touching pen lifts first (the position it lifts at is not predicted)
            endPenContact()
            return false
        }
        return when {
            contact -> { // the pen always gets the left button (OWN-2)
                penContact = true
                owner = SRC_PEN
                true
            }
            penContact -> { // CONTACT 1 -> 0: the lift happens at this sample
                endPenContact()
                true
            }
            else -> owner == NO_OWNER // hover: the Mac ignores it while a pointer source owns the button (OWN-9)
        }
    }

    private fun endPenContact() {
        penContact = false
        if (owner == SRC_PEN) owner = NO_OWNER
    }

    private fun clearOwnership() {
        owner = NO_OWNER
        penContact = false
        heldLeft.fill(false)
    }

    /** The control connection ended or a new one began: the host released everything ([reset] plus the owner mirror). */
    fun endSession(): Unit = synchronized(lock) {
        clearOwnership()
        reset()
    }

    private fun add(k: Int, a: Float, b: Float, nowUs: Long): Boolean = synchronized(lock) {
        if (anchor == null) return false // no state yet: nothing is drawn, nothing to predict from
        val t = maxOf(nowUs, lastSendUs)
        lastSendUs = t
        pruneBefore(t - KEEP_US)
        if (count == CAP) { head = (head + 1) % CAP; count-- }
        val i = (head + count) % CAP
        sendUs[i] = t
        kind[i] = k.toByte()
        v0[i] = a
        v1[i] = b
        count++
        true
    }

    private fun pruneBefore(us: Long) {
        while (count > 0 && sendUs[head] < us) { head = (head + 1) % CAP; count-- }
    }

    /**
     * Reader thread: [s] was accepted as the newest state and arrived at [rxUs]. Measures the forecast of the previous anchor
     * against it, then makes it the anchor.
     */
    fun onState(s: CursorState, rxUs: Long): Unit = synchronized(lock) {
        if (!active) {
            anchor = null
            return
        }
        val ow = oneWay()
        val sample = sampleOf(s.hostTimeUs, rxUs, ow)
        val prev = anchor
        if (stats != null && prev != null && prev.visible && s.visible && widthPt > 0 && heightPt > 0) {
            positionAt(prev, sample - ow, ow, tmp)
            val nx = s.x / NORM * widthPt
            val ny = s.y / NORM * heightPt
            val err = hypot(tmp[0] - nx, tmp[1] - ny)
            val hold = hypot(prev.xNorm / NORM * widthPt - nx, prev.yNorm / NORM * heightPt - ny)
            if (err > 0f || hold > 0f) stats.onPred(err, hold)
        }
        anchor = Anchor(s.seq, s.x, s.y, s.visible, sample)
        pruneBefore(rxUs - KEEP_US)
    }

    /**
     * UI thread: where to draw the cursor of the state [seq] at [nowUs], written to [out]. Returns false when there is no
     * prediction (switched off, hidden, stream size unknown, or the anchor is not [seq]): the caller draws the state's own
     * position, as in v1.
     */
    fun advance(seq: Long, nowUs: Long, out: Result): Boolean = synchronized(lock) {
        val a = anchor
        if (!active || a == null || a.seq != seq || !a.visible || widthPt <= 0 || heightPt <= 0) {
            shown = null
            corrX = 0f
            corrY = 0f
            return false
        }
        val ow = oneWay()
        val pending = positionAt(a, nowUs, ow, tmp)
        if (lastAdvanceUs != 0L && (corrX != 0f || corrY != 0f)) {
            val dt = (nowUs - lastAdvanceUs).coerceIn(0L, 100_000L)
            val f = exp(-dt / TAU_US).toFloat()
            corrX *= f
            corrY *= f
            if (hypot(corrX, corrY) < EPS_PT) { corrX = 0f; corrY = 0f }
        }
        val prev = shown
        if (prev == null) {
            corrX = 0f
            corrY = 0f
        } else if (prev !== a) {
            // Keep what is on screen: old forecast + its correction, now expressed against the new forecast.
            positionAt(prev, nowUs, ow, tmp2)
            val dx = tmp2[0] + corrX - tmp[0]
            val dy = tmp2[1] + corrY - tmp[1]
            if (hypot(dx, dy) <= SMOOTH_PT) { corrX = dx; corrY = dy } else { corrX = 0f; corrY = 0f }
        }
        shown = a
        lastAdvanceUs = nowUs
        val px = (tmp[0] + corrX).coerceIn(0f, widthPt.toFloat())
        val py = (tmp[1] + corrY).coerceIn(0f, heightPt.toFloat())
        out.xNorm = (px / widthPt * NORM).roundToInt().coerceIn(0, 65535)
        out.yNorm = (py / heightPt * NORM).roundToInt().coerceIn(0, 65535)
        out.animating = corrX != 0f || corrY != 0f || pending > 0
        true
    }

    /**
     * The forecast of [a] at [evalUs] (events sent after that are not counted, events older than [SETTLE_US] before it are
     * settled), in Mac points into [out]. Returns how many events were applied (not in the anchor yet and not settled).
     * Caller holds the lock.
     */
    private fun positionAt(a: Anchor, evalUs: Long, ow: Long, out: FloatArray): Int {
        val w = widthPt.toFloat()
        val h = heightPt.toFloat()
        var x = a.xNorm / NORM * w
        var y = a.yNorm / NORM * h
        var applied = 0
        for (n in 0 until count) {
            val i = (head + n) % CAP
            val s = sendUs[i]
            if (s > evalUs) break
            if (evalUs - s > SETTLE_US) continue
            if (s + ow <= a.sampleUs) continue // the state already contains it
            if (kind[i].toInt() == KIND_REL) {
                x = (x + v0[i]).coerceIn(0f, w)
                y = (y + v1[i]).coerceIn(0f, h)
            } else {
                x = v0[i] / NORM * w
                y = v1[i] / NORM * h
            }
            applied++
        }
        out[0] = x
        out[1] = y
        return applied
    }

    private fun oneWay(): Long = (oneWayUs() ?: DEFAULT_ONE_WAY_US).coerceIn(0L, MAX_ONE_WAY_US)

    /**
     * The client-clock time a state was sampled at. The host stamp mapped through the clock offset when that is plausible,
     * but never later than the arrival minus the one-way delay (a state cannot travel faster than the best round trip);
     * otherwise that bound itself.
     */
    private fun sampleOf(hostUs: Long, rxUs: Long, ow: Long): Long {
        val bound = rxUs - ow
        val mapped = hostToClientUs(hostUs) ?: return bound
        return if (mapped >= rxUs - MAX_STATE_AGE_US) min(mapped, bound) else bound
    }

    companion object {
        const val CAP = 512
        private const val NO_OWNER = -1
        private const val SRC_PEN = 0
        private const val SRC_REL = 1
        private const val SRC_MOUSE = 2
        private const val SRC_TOUCH = 3
        private const val BUTTON_LEFT = 1
        private const val KIND_REL = 0
        private const val KIND_ABS = 1
        private const val NORM = 65535f

        /** Events older than this are dropped from the ring. */
        const val KEEP_US = 500_000L

        /** An event this old is considered to be in the host's position already (the prediction "settles", at most this long). */
        const val SETTLE_US = 100_000L

        /** A disagreement up to this many Mac points is eased in; larger is shown at once. */
        const val SMOOTH_PT = 4f

        /** Decay time constant of the correction (about one to two frames at 144 Hz). */
        private const val TAU_US = 10_000.0
        private const val EPS_PT = 0.05f
        private const val DEFAULT_ONE_WAY_US = 5_000L
        private const val MAX_ONE_WAY_US = 100_000L

        /** A host stamp mapped to more than this before the arrival is not believed (offset still rough): use the arrival. */
        private const val MAX_STATE_AGE_US = 250_000L
    }
}
