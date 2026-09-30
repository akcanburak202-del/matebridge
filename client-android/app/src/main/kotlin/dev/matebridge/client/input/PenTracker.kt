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
 *  - Android dispatches `HOVER_EXIT` right before every `ACTION_DOWN`; an exit that is followed by a DOWN
 *    of the same tool within [EXIT_DEFER_MS] is dropped so a stroke does not flap proximity leave/enter.
 *    A deferred exit is always sent by [tick], [release] or the next non-DOWN frame.
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
    override val inRange get() = state != State.OUT

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

    /** True while a pen contact is open on the host and (device, pointer) is exactly the pair that opened it. */
    fun followsPointer(deviceId: Int, pointerId: Int) =
        state == State.CONTACT && contactDeviceId == deviceId && contactPointerId == pointerId

    private class S(
        val timeUs: Long, val x: Int, val y: Int, val pressure: Int,
        val tiltX: Int, val tiltY: Int, val flags: Int,
    )

    private class PendingExit(val point: PenPoint, val atMs: Long)

    private var tool = Pen.TOOL_PEN
    private var last: S? = null // last emitted sample: repeat source and leave position
    private var lastFlags = 0 // flags of the last emitted sample, 0 after a reset
    private var lastTimeUs = 0L
    private var lastEmitMs = NEVER_MS
    private var lastTilt: Pair<Int, Int>? = null
    private var pendingExit: PendingExit? = null

    /** Feeds one pen MotionEvent (see [PenFrame]); [nowMs] is uptime at dispatch. */
    fun onFrame(f: PenFrame, nowMs: Long): List<Outgoing> {
        if (f.points.isEmpty()) return emptyList()
        val out = ArrayList<Outgoing>(2)
        lastEventMs = nowMs
        // A release ends whichever tool is active, whatever tool type the platform reports for it now (PROTOCOL.md section 4).
        val releaseFrame = f.action == PenAction.UP || f.action == PenAction.CANCEL
        val newTool = if (releaseFrame && state != State.OUT) tool else if (f.eraser) Pen.TOOL_ERASER else Pen.TOOL_PEN
        settlePendingExit(absorb = f.action == PenAction.DOWN && newTool == tool, nowMs, out)
        if (state != State.OUT && newTool != tool) leaveAtLast(f.points.first().timeUs, nowMs, out)
        tool = newTool
        val pts = f.points
        when (f.action) {
            PenAction.DOWN -> {
                // Android batches only moves, but any history a DOWN carries is kept: STROKE_START rides on the
                // first (oldest) sample only, the rest of the segment is ordinary contact.
                val s = ArrayList<S>(pts.size + 1)
                if (state == State.CONTACT) s += sample(pts.first(), IN_RANGE) // missed UP: end the old contact first
                s += sample(pts.first(), IN_RANGE or CONTACT or STROKE_START)
                for (i in 1 until pts.size) s += sample(pts[i], IN_RANGE or CONTACT)
                state = State.CONTACT
                contactPointerId = f.pointerId
                contactDeviceId = f.deviceId
                emit(s, nowMs, out)
            }
            PenAction.MOVE -> {
                val contact = state == State.CONTACT
                val flags = if (contact) IN_RANGE or CONTACT else IN_RANGE
                if (!contact) state = State.HOVER
                emit(pts.map { sample(it, flags) }, nowMs, out)
            }
            PenAction.UP -> {
                val contact = state == State.CONTACT
                val s = ArrayList<S>(pts.size)
                for (i in 0 until pts.size - 1) s += sample(pts[i], if (contact) IN_RANGE or CONTACT else IN_RANGE)
                s += sample(pts.last(), IN_RANGE) // contact ended; the pen may still hover
                state = State.HOVER
                clearContactIds()
                emit(s, nowMs, out)
            }
            PenAction.CANCEL -> leaveAt(pts.last(), nowMs, out)
            PenAction.HOVER_ENTER, PenAction.HOVER_MOVE -> {
                state = State.HOVER
                emit(pts.map { sample(it, IN_RANGE) }, nowMs, out)
            }
            PenAction.HOVER_EXIT -> {
                // Samples batched into the exit event are real hover positions: keep them, then close.
                if (state != State.OUT && pts.size > 1) {
                    state = State.HOVER
                    clearContactIds()
                    emit(pts.dropLast(1).map { sample(it, IN_RANGE) }, nowMs, out)
                }
                if (state == State.HOVER) pendingExit = PendingExit(pts.last(), nowMs) else leaveAt(pts.last(), nowMs, out)
            }
        }
        return out
    }

    /** Periodic work: deferred exit, liveness repeat, stale guards. Call every ~25 ms. */
    fun tick(nowMs: Long): List<Outgoing> {
        val out = ArrayList<Outgoing>(1)
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
        last = null
        lastFlags = 0
        lastTilt = null
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

    private fun emit(samples: List<S>, nowMs: Long, out: MutableList<Outgoing>) {
        if (samples.isEmpty()) return
        var i = 0
        while (i < samples.size) {
            val chunk = samples.subList(i, minOf(i + Limits.PEN_MAX_SAMPLES, samples.size))
            val base = chunk[0].timeUs
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

        private const val IN_RANGE = PenSample.IN_RANGE
        private const val CONTACT = PenSample.CONTACT
        private const val BUTTON = PenSample.BUTTON
        private const val STROKE_START = PenSample.STROKE_START
    }
}
