package dev.matebridge.client.cursor

import dev.matebridge.client.protocol.CursorState
import dev.matebridge.client.protocol.Message
import dev.matebridge.client.protocol.Pen
import dev.matebridge.client.protocol.PointerAbs
import dev.matebridge.client.protocol.PointerRel
import kotlin.math.exp
import kotlin.math.hypot
import kotlin.math.min
import kotlin.math.roundToInt

/**
 * Local cursor v2 (decision 0036, T-278): the tablet guesses where the Mac cursor is going from the relative motion it just
 * sent (mouse and trackpad), so the drawn cursor does not wait for the round trip. Drawing only: nothing here feeds the input
 * path, and the host's `CURSOR_STATE` stays the truth.
 *
 * One source only. The host decides who may move its cursor (left-button owner, pen proximity, finger gate, tool changes),
 * and mirroring that here kept diverging, so the prediction does not try: it predicts from `POINTER_REL` alone, and any
 * `PEN` sample or `POINTER_ABS` (finger, mouse outside capture) suspends it for [SUSPEND_US] after the last such sample. While
 * suspended the layer draws the host's reported position (v1). Holding a mouse or trackpad button changes nothing: the
 * relative motion is still the only source.
 *
 * Model. The newest accepted state is the [Anchor]: a position plus the moment the host sampled it, on the client clock.
 * Every `POINTER_REL` that went out is kept in a bounded ring with its send time and delta (points). A delta reaches the host
 * at `send + oneWay`; the anchor already contains it when that is not after the anchor's sample time. The prediction at time
 * `t` is the anchor position plus every delta that is not in the anchor yet and was sent at or before `t`, in order, clamped
 * to the screen after each step (the Mac stops at the edge). Deltas older than [SETTLE_US] are treated as settled, so when
 * the host stops (or never moved: clamped, ignored) the prediction falls back to the host's position within that time.
 *
 * Generations. Observations carry the generation of the control connection the input was sent on; one of a retired
 * generation (a migration or reconnect switched while the message was being observed) is ignored, and the ring is emptied at
 * [beginSession] and [endSession].
 *
 * Reconciling (draw thread). A new state moves the anchor; the shown position must not jump for a small disagreement, so the
 * difference between the old forecast and the new one becomes a correction that decays within a frame or two, and a
 * disagreement beyond [SMOOTH_PT] (an app moved or warped the cursor) is shown at once.
 *
 * Measuring. When a state arrives, the previous anchor's forecast for that state's sample time is compared with the state:
 * `pred_err` (and `hold_err`, what staying at the previous state would have missed by) go to [CursorStats]; states that
 * arrive while suspended are not measured.
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

    // Delta ring (oldest at [head]); parallel arrays, no allocation per event.
    private val sendUs = LongArray(CAP)
    private val dxPt = FloatArray(CAP)
    private val dyPt = FloatArray(CAP)
    private var head = 0
    private var count = 0
    private var lastSendUs = 0L

    private var anchor: Anchor? = null

    /** The control connection generation observations are accepted from; -1 = none. */
    private var armedGen = -1

    /** A pen sample or `POINTER_ABS` was sent: no prediction before this client-clock time. */
    private var suspendUntilUs = Long.MIN_VALUE

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

    /** Forgets deltas, anchor and correction (layer off, a session boundary). */
    fun reset(): Unit = synchronized(lock) {
        head = 0
        count = 0
        anchor = null
        shown = null
        corrX = 0f
        corrY = 0f
        lastAdvanceUs = 0L
        suspendUntilUs = Long.MIN_VALUE
    }

    /** A control connection of generation [gen] starts (or takes over): only its input is observed from now on. */
    fun beginSession(gen: Int): Unit = synchronized(lock) {
        armedGen = gen
        reset()
    }

    /** The control connection ended: nothing is observed until the next [beginSession]. */
    fun endSession(): Unit = synchronized(lock) {
        armedGen = -1
        reset()
    }

    /**
     * UI thread, after [msg] was handed to the connection of generation [gen] at [nowUs]. Returns true when the layer should
     * redraw because of it: a relative move, or the switch from predicting to suspended.
     *
     * - `POINTER_REL` with motion adds a delta (unless suspended).
     * - Any `PEN` sample or `POINTER_ABS` suspends the prediction until [SUSPEND_US] after this message and empties the ring.
     * - Everything else, and anything of another generation, is ignored.
     */
    fun onSent(msg: Message, nowUs: Long, gen: Int): Boolean = synchronized(lock) {
        if (gen != armedGen) return false
        when (msg) {
            is PointerRel ->
                (msg.dx != 0f || msg.dy != 0f) && active && nowUs >= suspendUntilUs && add(msg.dx, msg.dy, nowUs)
            is PointerAbs -> suspendPrediction(nowUs)
            is Pen -> suspendPrediction(nowUs)
            else -> false
        }
    }

    private fun suspendPrediction(nowUs: Long): Boolean {
        val was = active && anchor != null && nowUs >= suspendUntilUs
        suspendUntilUs = maxOf(suspendUntilUs, nowUs + SUSPEND_US)
        head = 0
        count = 0
        shown = null
        corrX = 0f
        corrY = 0f
        return was
    }

    private fun add(dx: Float, dy: Float, nowUs: Long): Boolean {
        if (anchor == null) return false // no state yet: nothing is drawn, nothing to predict from
        val t = maxOf(nowUs, lastSendUs)
        lastSendUs = t
        pruneBefore(t - KEEP_US)
        if (count == CAP) { head = (head + 1) % CAP; count-- }
        val i = (head + count) % CAP
        sendUs[i] = t
        dxPt[i] = dx
        dyPt[i] = dy
        count++
        return true
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
        if (stats != null && prev != null && prev.visible && s.visible && widthPt > 0 && heightPt > 0 && rxUs >= suspendUntilUs) {
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
     * prediction (switched off, hidden, suspended, stream size unknown, or the anchor is not [seq]): the caller draws the
     * state's own position, as in v1.
     */
    fun advance(seq: Long, nowUs: Long, out: Result): Boolean = synchronized(lock) {
        val a = anchor
        if (!active || a == null || a.seq != seq || !a.visible || widthPt <= 0 || heightPt <= 0 || nowUs < suspendUntilUs) {
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
     * The forecast of [a] at [evalUs] (deltas sent after that are not counted, deltas older than [SETTLE_US] before it are
     * settled), in Mac points into [out]. Returns how many deltas were applied (not in the anchor yet and not settled).
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
            x = (x + dxPt[i]).coerceIn(0f, w)
            y = (y + dyPt[i]).coerceIn(0f, h)
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
        private const val NORM = 65535f

        /** Deltas older than this are dropped from the ring. */
        const val KEEP_US = 500_000L

        /** A delta this old is considered to be in the host's position already (the prediction "settles", at most this long). */
        const val SETTLE_US = 100_000L

        /** After the last pen sample or `POINTER_ABS` the prediction stays off this long (the host-reported position is drawn). */
        const val SUSPEND_US = 300_000L

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
