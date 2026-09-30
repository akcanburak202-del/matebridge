package dev.matebridge.client.input

import dev.matebridge.client.protocol.Coords
import dev.matebridge.client.protocol.Limits
import dev.matebridge.client.protocol.Pen
import dev.matebridge.client.protocol.PenSample
import dev.matebridge.client.stream.VideoViewport

/**
 * Pen capture state machine (PROTOCOL.md section 4 PEN, section 7 client duties). Pure Kotlin.
 *
 * States: OUT (last sample sent had flags 0), HOVER (IN_RANGE only), CONTACT (IN_RANGE|CONTACT).
 * Rules that keep the host from ever holding a stuck pen:
 *  - a contact sample is only produced after an `ACTION_DOWN` was seen ([State.CONTACT]); a MOVE that
 *    arrives without one (stroke in progress when input resumed after RELEASE_ALL, or when the model was
 *    reset) goes out as hover, so a stroke middle never starts a drag;
 *  - `STROKE_START` only on the first sample of the DOWN (any history the DOWN carries follows as ordinary
 *    contact); a DOWN while already in contact first ends the old contact;
 *  - `ACTION_CANCEL` and hover exit produce a `flags = 0` sample; a tool change first sends `flags = 0` for the old tool;
 *  - a release (UP / CANCEL) ends the active tool whatever tool type the frame reports, and the contact remembers
 *    the (device, pointer id) pair that opened it ([followsPointer]) so the adapter can route the release by pair
 *    (pointer ids repeat across devices: the pen and the touchscreen both start at 0);
 *  - [lastSentMs] (time of the last emitted PEN message, repeats and synthetic `flags = 0` included) is the clock of
 *    the host's finger gate; [lastEventMs] (last real Android event) only drives the stale guards below;
 *  - liveness: while in range a sample is repeated every [LIVENESS_MS] (host watchdog is 500 ms);
 *  - the client never repeats forever on stale belief: hover with no real event for [HOVER_STALE_MS]
 *    (Android did not report the exit, e.g. a fast lift after `ACTION_UP`) and contact with no event for
 *    [CONTACT_STALE_MS] (Android always ends a gesture with UP or CANCEL; this is a last-resort guard)
 *    are closed with a `flags = 0` sample;
 *  - exact-duplicate filter (T-026): a real Android sample that is identical to the last SENT sample in time, position,
 *    pressure, tilt and flags is not sent (`dup_exact`). Only samples of real events go through it; a sample whose
 *    flags differ, a `STROKE_START` sample, a `flags = 0` sample, a liveness repeat and the synthetic closing samples
 *    never do (they use [emit] directly), so no state change can be lost to it. A same-position sample with a
 *    different time is sent and only counted (`dup_pos`);
 *  - contact confirmation (T-029, decision 0007): an `ACTION_DOWN` is not sent at once. It is held ([pending]) and
 *    confirmed by the first of: a second real sample of the same contact (a MOVE, or more than one sample in the DOWN
 *    itself), or an event or a [tick] at least [CONFIRM_MS] after the DOWN. Confirming sends the held samples with their
 *    original times, `STROKE_START` on the first. A contact that ends while held (UP, cancel, a hover event, a tool
 *    change, [release], [reset]) is dropped and never reaches the host (pen tip bounce: one DOWN sample, UP ~8 ms later,
 *    the real stroke ~20 ms after that); UP, cancel and hover endings are counted as `bounce_dropped`. The host is never
 *    told about a held contact, so dropping needs no release. While held the pen counts as in range ([inRange], so a
 *    finger press cannot start) and the contact's (device, pointer) pair is followed. An UP or hover event at least
 *    [CONFIRM_MS] after the DOWN (by event time) confirms it first, so a short real contact still goes out whole; a
 *    cancel always drops it. Events are timed by event time, [tick] by the dispatch clock;
 *  - Android dispatches `HOVER_EXIT` right before every `ACTION_DOWN`; an exit that is followed by a DOWN
 *    of the same tool within [EXIT_DEFER_MS] is dropped so a stroke does not flap proximity leave/enter.
 *    A deferred exit is always sent by [tick], [release] or the next non-DOWN frame. An exit swallowed by a DOWN whose
 *    contact is then dropped stays swallowed while the pen is still there (UP: a hover sample follows); otherwise it is
 *    answered by the `flags = 0` sample of a cancel, [release] or a hover exit.
 *
 * All coordinates are normalized through [viewport] (T-015 `VideoViewport`, the only conversion).
 * Not thread-safe: UI thread only.
 */
class PenTracker(
    private val viewport: () -> VideoViewport,
    private val counters: InputCounters = InputCounters(),
) : PenPresence {
    enum class State { OUT, HOVER, CONTACT }

    var state = State.OUT
        private set
    /** In hover range or touching, a held (unconfirmed) contact included: the finger gate must not open. */
    override val inRange get() = state != State.OUT || pending != null

    /** Uptime ms of the last real Android pen event (hover exit and cancel included); drives the stale guards. */
    var lastEventMs = NEVER_MS
        private set

    /** Uptime ms of the last emitted PEN message: the host's finger-gate clock. */
    override val lastSentMs get() = lastEmitMs

    /** Android pointer id of the contact the host holds, or -1. Together with [contactDeviceId] it identifies the contact. */
    var contactPointerId = -1
        private set

    /** Input device that opened the contact, or [NO_DEVICE]. Pointer ids are only unique within one device. */
    var contactDeviceId = NO_DEVICE
        private set

    /** True while a pen contact is open on the host (or held, see [pending]) and (device, pointer) is exactly the pair that opened it. */
    fun followsPointer(deviceId: Int, pointerId: Int) =
        (state == State.CONTACT || pending != null) && contactDeviceId == deviceId && contactPointerId == pointerId

    private class S(
        val timeUs: Long, val x: Int, val y: Int, val pressure: Int,
        val tiltX: Int, val tiltY: Int, val flags: Int,
    )

    /** A DOWN held back until confirmed: raw points (converted on confirmation), DOWN event time and dispatch time. */
    private class Pending(val points: List<PenPoint>, val downTimeUs: Long, val downNowMs: Long)

    private class PendingExit(val point: PenPoint, val atMs: Long)

    private var tool = Pen.TOOL_PEN
    private var last: S? = null // last emitted sample: repeat source and leave position
    private var lastFlags = 0 // flags of the last emitted sample, 0 after a reset
    private var lastTimeUs = 0L
    private var lastEmitMs = NEVER_MS
    private var lastTilt: Pair<Int, Int>? = null
    private var pendingExit: PendingExit? = null
    private var pending: Pending? = null

    /** True while a DOWN is held back and not yet confirmed (T-029). */
    val contactHeld get() = pending != null

    /** Feeds one pen MotionEvent (see [PenFrame]); [nowMs] is uptime at dispatch. */
    fun onFrame(f: PenFrame, nowMs: Long): List<Outgoing> {
        if (f.points.isEmpty()) return emptyList()
        val out = ArrayList<Outgoing>(2)
        lastEventMs = nowMs
        // A release ends whichever tool is active, whatever tool type the platform reports for it now (PROTOCOL.md section 4).
        val releaseFrame = f.action == PenAction.UP || f.action == PenAction.CANCEL
        val newTool = if (releaseFrame && (state != State.OUT || pending != null)) tool else if (f.eraser) Pen.TOOL_ERASER else Pen.TOOL_PEN
        settlePendingExit(absorb = f.action == PenAction.DOWN && newTool == tool, nowMs, out)
        if (newTool != tool) dropPending(count = false) // never sent: nothing to close for it
        if (state != State.OUT && newTool != tool) leaveAtLast(f.points.first().timeUs, nowMs, out)
        tool = newTool
        val pts = f.points
        if (resolvePending(f, nowMs, out)) return out
        when (f.action) {
            PenAction.DOWN -> {
                // Missed UP: the host still holds the old contact, so end it now (that one is never held back).
                if (state == State.CONTACT) {
                    state = State.HOVER
                    emitReal(listOf(sample(pts.first(), IN_RANGE)), nowMs, out)
                }
                // Hold the new contact. Android batches only moves, but any history a DOWN carries is more than one
                // real sample and confirms it at once: STROKE_START rides on the first (oldest) sample only.
                pending = Pending(pts, pts.first().timeUs, nowMs)
                contactPointerId = f.pointerId
                contactDeviceId = f.deviceId
                if (pts.size > 1) confirmPending(emptyList(), nowMs, out)
            }
            PenAction.MOVE -> {
                val contact = state == State.CONTACT
                val flags = if (contact) IN_RANGE or CONTACT else IN_RANGE
                if (!contact) state = State.HOVER
                emitReal(pts.map { sample(it, flags) }, nowMs, out)
            }
            PenAction.UP -> {
                val contact = state == State.CONTACT
                val s = ArrayList<S>(pts.size)
                for (i in 0 until pts.size - 1) s += sample(pts[i], if (contact) IN_RANGE or CONTACT else IN_RANGE)
                s += sample(pts.last(), IN_RANGE) // contact ended; the pen may still hover
                state = State.HOVER
                clearContactIds()
                emitReal(s, nowMs, out)
            }
            PenAction.CANCEL -> leaveAt(pts.last(), nowMs, out)
            PenAction.HOVER_ENTER, PenAction.HOVER_MOVE -> {
                state = State.HOVER
                emitReal(pts.map { sample(it, IN_RANGE) }, nowMs, out)
            }
            PenAction.HOVER_EXIT -> {
                // Samples batched into the exit event are real hover positions: keep them, then close.
                if (state != State.OUT && pts.size > 1) {
                    state = State.HOVER
                    clearContactIds()
                    emitReal(pts.dropLast(1).map { sample(it, IN_RANGE) }, nowMs, out)
                }
                if (state == State.HOVER) pendingExit = PendingExit(pts.last(), nowMs) else leaveAt(pts.last(), nowMs, out)
            }
        }
        return out
    }

    /** Periodic work: deferred exit, liveness repeat, stale guards. Call every ~25 ms. */
    fun tick(nowMs: Long): List<Outgoing> {
        val out = ArrayList<Outgoing>(1)
        val held = pending
        if (held != null) {
            if (nowMs - held.downNowMs >= CONFIRM_MS) confirmPending(emptyList(), nowMs, out)
            return out // the host knows nothing of a held contact: no liveness repeat and no stale guard for it
        }
        val pe = pendingExit
        if (pe != null) {
            if (nowMs - pe.atMs >= EXIT_DEFER_MS) {
                pendingExit = null
                leaveAt(pe.point, nowMs, out)
            }
            return out // no liveness repeat behind a pending exit
        }
        when (state) {
            State.OUT -> Unit
            State.HOVER ->
                if (nowMs - lastEventMs >= HOVER_STALE_MS) {
                    counters.hoverStale++
                    leaveAtLast(nowMs * 1000, nowMs, out)
                } else if (nowMs - lastEmitMs >= LIVENESS_MS) {
                    repeatLast(IN_RANGE, nowMs, out)
                }
            State.CONTACT ->
                if (nowMs - lastEventMs >= CONTACT_STALE_MS) {
                    counters.contactStale++
                    leaveAtLast(nowMs * 1000, nowMs, out)
                } else if (nowMs - lastEmitMs >= LIVENESS_MS) {
                    repeatLast(IN_RANGE or CONTACT, nowMs, out)
                }
        }
        return out
    }

    /**
     * Natural end of everything the host may believe about the pen (background, focus loss, device
     * removal, deactivation): a `flags = 0` sample when anything was in range. Drops a deferred exit
     * (this sample covers it).
     */
    fun release(nowMs: Long): List<Outgoing> {
        pendingExit = null
        dropPending(count = false) // the host was never told about it: no release to send
        if (state == State.OUT) return emptyList()
        val out = ArrayList<Outgoing>(1)
        leaveAtLast(nowMs * 1000, nowMs, out)
        return out
    }

    /**
     * Forget everything without sending: the host has released the pen (RELEASE_ALL sent, or connection
     * lost). The next contact MOVE without a DOWN is hover only, and the next hover sample is an enter.
     */
    fun reset() {
        state = State.OUT
        clearContactIds()
        pendingExit = null
        pending = null
        last = null
        lastFlags = 0
        lastTilt = null
    }

    // ---- contact confirmation (T-029) ----

    /**
     * Decides the fate of a held contact when [f] arrives. Returns true when the frame was consumed: a MOVE is the second
     * real sample, so the contact is confirmed with it. A cancel drops the contact. Any other frame (UP, hover, a second
     * DOWN) confirms it when at least [CONFIRM_MS] passed since the DOWN by event time and drops it (a bounce) otherwise;
     * the frame is then handled as usual on top of that state.
     */
    private fun resolvePending(f: PenFrame, nowMs: Long, out: MutableList<Outgoing>): Boolean {
        val p = pending ?: return false
        when (f.action) {
            PenAction.MOVE -> {
                confirmPending(f.points, nowMs, out)
                return true
            }
            PenAction.CANCEL -> dropPending(count = true)
            else ->
                if (f.points.last().timeUs - p.downTimeUs >= CONFIRM_MS * 1000) confirmPending(emptyList(), nowMs, out)
                else dropPending(count = true)
        }
        return false
    }

    /** The held contact becomes real: held samples plus [extra], `STROKE_START` on the very first one. */
    private fun confirmPending(extra: List<PenPoint>, nowMs: Long, out: MutableList<Outgoing>) {
        val p = pending ?: return
        pending = null
        val pts = p.points + extra
        val s = ArrayList<S>(pts.size)
        s += sample(pts.first(), IN_RANGE or CONTACT or STROKE_START)
        for (i in 1 until pts.size) s += sample(pts[i], IN_RANGE or CONTACT)
        state = State.CONTACT
        emitReal(s, nowMs, out)
    }

    /** Forgets a held contact; nothing was sent for it, so there is nothing to release. */
    private fun dropPending(count: Boolean) {
        if (pending == null) return
        pending = null
        clearContactIds()
        if (count) counters.bounceDropped++
    }

    // ---- sample construction ----

    private fun sample(p: PenPoint, flags: Int): S {
        val vp = viewport()
        val contact = flags and CONTACT != 0
        val (tx, ty) = tilt(p, contact)
        val t = maxOf(p.timeUs, lastTimeUs)
        lastTimeUs = t
        val f = if (flags != 0 && p.button) flags or BUTTON else flags
        return S(
            t, vp.normX(p.x), vp.normY(p.y),
            if (contact) Coords.pressure(p.pressure) else 0,
            tx, ty, f,
        )
    }

    /**
     * Provisional tilt conversion (PROTOCOL.md section 4). HarmonyOS updates tilt sparsely during contact,
     * so an unreported value (non-finite, or exactly 0/0 while touching) repeats the last known one.
     */
    private fun tilt(p: PenPoint, contact: Boolean): Pair<Int, Int> {
        val t = p.tiltRad
        val o = p.orientationRad
        val unreported = !t.isFinite() || !o.isFinite() || (contact && t == 0f && o == 0f)
        val prev = lastTilt
        if (unreported) {
            if (prev == null) return 0 to 0
            if (prev.first != 0 || prev.second != 0) counters.tiltHeld++
            return prev
        }
        val (fx, fy) = Coords.penTilt(t, o)
        return (Coords.signed(fx) to Coords.signed(fy)).also { lastTilt = it }
    }

    /**
     * Emits samples that come from real Android events (T-026): drops exact duplicates of the last SENT sample and
     * counts same-position samples, then sends the rest in order through [emit]. Compares against the last sample
     * actually sent (a dropped sample is identical to it, so the reference does not move). The synthetic paths
     * (liveness repeat, closing samples) call [emit] directly and are never filtered.
     */
    private fun emitReal(samples: List<S>, nowMs: Long, out: MutableList<Outgoing>) {
        var prev = last
        val kept = ArrayList<S>(samples.size)
        for ((i, s) in samples.withIndex()) {
            if (prev != null) {
                if (isExactDuplicate(s, prev)) {
                    counters.dupExact++
                    continue
                }
                if (s.x == prev.x && s.y == prev.y && s.timeUs != prev.timeUs) {
                    counters.dupPos++
                    if (i == 0) counters.dupPosFirst++
                }
            }
            kept += s
            prev = s
        }
        emit(kept, nowMs, out)
    }

    /**
     * Only a plain in-range or in-contact sample can be a duplicate: a `flags = 0` sample and a `STROKE_START` sample
     * carry a state change and are always sent, and a sample whose flags differ from the last sent one is never equal.
     */
    private fun isExactDuplicate(a: S, b: S) =
        a.flags == b.flags && a.flags != 0 && a.flags and STROKE_START == 0 &&
            a.timeUs == b.timeUs && a.x == b.x && a.y == b.y && a.pressure == b.pressure &&
            a.tiltX == b.tiltX && a.tiltY == b.tiltY

    private fun emit(samples: List<S>, nowMs: Long, out: MutableList<Outgoing>) {
        if (samples.isEmpty()) return
        var i = 0
        while (i < samples.size) {
            val chunk = samples.subList(i, minOf(i + Limits.PEN_MAX_SAMPLES, samples.size))
            val base = chunk[0].timeUs
            if (chunk.size > counters.maxBatch) counters.maxBatch = chunk.size.toLong()
            // Mergeable only if it repeats an already-sent plain hover state (no transition inside or before).
            val mergeable = lastFlags == IN_RANGE && chunk.all { it.flags == IN_RANGE }
            out += Outgoing(
                Pen(tool, base, chunk.map { PenSample(it.timeUs - base, it.x, it.y, it.pressure, it.tiltX, it.tiltY, it.flags) }),
                mergeable,
            )
            lastFlags = chunk.last().flags
            i += chunk.size
        }
        last = samples.last()
        lastEmitMs = nowMs
        counters.penSamples += samples.size
    }

    private fun settlePendingExit(absorb: Boolean, nowMs: Long, out: MutableList<Outgoing>) {
        val pe = pendingExit ?: return
        pendingExit = null
        if (absorb && nowMs - pe.atMs <= EXIT_DEFER_MS) {
            counters.exitAbsorbed++
            return
        }
        leaveAt(pe.point, nowMs, out)
    }

    private fun toOut() {
        state = State.OUT
        lastTilt = null
        clearContactIds()
    }

    private fun clearContactIds() {
        contactPointerId = -1
        contactDeviceId = NO_DEVICE
    }

    private fun leaveAt(p: PenPoint, nowMs: Long, out: MutableList<Outgoing>) {
        val s = sample(p, 0)
        toOut()
        emit(listOf(s), nowMs, out)
    }

    private fun leaveAtLast(timeUs: Long, nowMs: Long, out: MutableList<Outgoing>) {
        val l = last
        val t = maxOf(timeUs, lastTimeUs)
        lastTimeUs = t
        val s = if (l == null) S(t, 0, 0, 0, 0, 0, 0) else S(t, l.x, l.y, 0, l.tiltX, l.tiltY, 0)
        toOut()
        emit(listOf(s), nowMs, out)
    }

    private fun repeatLast(flags: Int, nowMs: Long, out: MutableList<Outgoing>) {
        val l = last ?: return
        val t = maxOf(nowMs * 1000, lastTimeUs)
        lastTimeUs = t
        val contact = flags and CONTACT != 0
        emit(
            listOf(S(t, l.x, l.y, if (contact) l.pressure else 0, l.tiltX, l.tiltY, flags or (l.flags and BUTTON))),
            nowMs, out,
        )
    }

    companion object {
        const val LIVENESS_MS = 100L
        const val HOVER_STALE_MS = 2000L
        const val CONTACT_STALE_MS = 10_000L
        const val EXIT_DEFER_MS = 40L

        /**
         * A contact is confirmed after this long without a second sample (T-029). A real contact's second sample comes
         * after ~2.8 ms (M-Pencil, 360 Hz) and the measured bounce lasts ~8 ms. The timer is only the fallback for a
         * pen that then sends nothing more; it is checked by every event and by [tick] (25 ms period in MainActivity).
         */
        const val CONFIRM_MS = 10L

        private const val IN_RANGE = PenSample.IN_RANGE
        private const val CONTACT = PenSample.CONTACT
        private const val BUTTON = PenSample.BUTTON
        private const val STROKE_START = PenSample.STROKE_START
    }
}
