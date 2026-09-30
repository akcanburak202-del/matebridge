package dev.matebridge.client.input

import dev.matebridge.client.protocol.Codec
import dev.matebridge.client.protocol.Message
import dev.matebridge.client.protocol.Pen
import dev.matebridge.client.protocol.PenGesture
import dev.matebridge.client.protocol.PenSample
import dev.matebridge.client.protocol.PointerAbs
import dev.matebridge.client.protocol.ReleaseAll
import dev.matebridge.client.protocol.Scroll
import dev.matebridge.client.stream.VideoViewport

/** 1:1 viewport: view pixels equal video pixels, 2800x1840 like the MatePad. */
val VP = VideoViewport.ofRect(0, 0, 2800, 1840)

/** A pen sample at [tMs] milliseconds. */
fun pt(
    tMs: Long, x: Float = 1400f, y: Float = 920f, pressure: Float = 0.5f,
    tilt: Float = 0.3f, ori: Float = 1f, button: Boolean = false,
) = PenPoint(tMs * 1000, x, y, pressure, tilt, ori, button)

fun penFrame(action: PenAction, vararg pts: PenPoint, eraser: Boolean = false, device: Int = 1, pointerId: Int = 0) =
    PenFrame(action, eraser, pts.toList(), device, pointerId)

/**
 * A pen DOWN that is confirmed by the timer (T-029): the DOWN, then a tick [PenTracker.CONFIRM_MS] later. Returns what the
 * DOWN and the tick sent (the contact's STROKE_START sample, plus the end of an old contact when there was one).
 */
fun PenTracker.downConfirmed(f: PenFrame, nowMs: Long): List<Outgoing> =
    onFrame(f, nowMs) + tick(nowMs + PenTracker.CONFIRM_MS)

/** Same on the capture level: DOWN, then a tick [PenTracker.CONFIRM_MS] later. */
fun InputCapture.downConfirmed(f: PenFrame, nowMs: Long) {
    onPen(f, nowMs)
    tick(nowMs + PenTracker.CONFIRM_MS)
}

fun finger(id: Int, x: Float, y: Float) = Finger(id, x, y)

fun touchFrame(action: TouchAction, tMs: Long, actingId: Int, vararg fingers: Finger, device: Int = 2) =
    TouchFrame(action, actingId, fingers.toList(), tMs * 1000, device)

/** The MatePad's real layout: the pen digitizer and the touchscreen are different input devices; both count pointers from 0. */
const val PEN_DEVICE = 1
const val TOUCH_DEVICE = 2

/**
 * What `MotionEventAdapter` does with an `ACTION_UP` / `ACTION_POINTER_UP`, on the MotionEvent-independent layer: the
 * decision is [ReleaseRouting.routeUp]; the frame handed to the tracker is what the adapter builds. [fingers] is the
 * finger list of the event (without the acting pointer when the platform no longer calls it a finger).
 */
fun InputCapture.androidUp(
    kind: ToolKind, deviceId: Int, pointerId: Int, nowMs: Long,
    fingers: List<Finger> = emptyList(), point: PenPoint = pt(nowMs),
) {
    when (ReleaseRouting.routeUp(kind, deviceId, pointerId, this)) {
        Route.PEN -> onPen(PenFrame(PenAction.UP, false, listOf(point), deviceId, pointerId), nowMs)
        Route.TOUCH -> onTouch(TouchFrame(TouchAction.UP, pointerId, fingers, nowMs * 1000, deviceId), nowMs)
        Route.NONE -> Unit
    }
}

/** What the adapter does with an `ACTION_CANCEL` of device [deviceId]; decisions from [ReleaseRouting]. */
fun InputCapture.androidCancel(
    deviceId: Int, penPointerInEvent: Boolean, fingerPointerInEvent: Boolean, nowMs: Long,
    fingers: List<Finger> = emptyList(), point: PenPoint = pt(nowMs),
) {
    if (ReleaseRouting.cancelReachesPen(deviceId, penPointerInEvent, this)) {
        onPen(PenFrame(PenAction.CANCEL, false, listOf(point), deviceId, penContactPointerId.coerceAtLeast(0)), nowMs)
    }
    if (ReleaseRouting.cancelReachesTouch(deviceId, fingerPointerInEvent, this)) {
        onTouch(TouchFrame(TouchAction.CANCEL, -1, fingers, nowMs * 1000, deviceId), nowMs)
    }
}

/** Flattens all pen samples of the given messages. */
fun penSamples(msgs: List<Message>): List<PenSample> = msgs.filterIsInstance<Pen>().flatMap { it.samples }

fun List<Outgoing>.messages(): List<Message> = map { it.msg }

/**
 * Reference model of the real host (Kotlin port of host-mac `InputStateMachine`, branch task/T-022, pen, touch and
 * scroll parts; PROTOCOL.md sections 4 and 7). One instance is one host session: a new session starts from
 * scratch with both pen tools latched, whatever the previous connection left behind.
 *
 * What it models that a naive "buttons up/down" counter cannot:
 *  - the pointer lock: the reported touch button state survives release-all, so a press is only an edge against
 *    what the client reported last (a stale "still LEFT" never looks like a fresh press);
 *  - the finger gate: new touch presses are refused while the pen is in range and for 1 s after the last PEN
 *    message received (release-all does not clear that time);
 *  - the 500 ms pen and scroll watchdogs, measured from message receipt, applied before every message;
 *  - the single left-button owner (pen priority) and the latch after session start and release-all;
 *  - eraser mode via PEN_GESTURE, tool changes closing the old tool.
 * It does not model: keyboard, POINTER_REL / mouse, right/middle buttons, the injector, inertia, or wall-clock
 * skew between client and host (messages are delivered instantly at the test clock).
 * If it and the Swift code disagree, the Swift code and PROTOCOL.md win.
 */
class HostModel {
    companion object {
        /** The host's finger gate: 1 s from the moment a PEN message is RECEIVED (PROTOCOL.md section 7). */
        const val GATE_HOLD_US = 1_000_000L
    }

    private enum class Owner { PEN, TOUCH }

    private var penTool = 0
    private var penAnchorUs = 0L
    private var lastPenAtUs: Long? = null
    private val latched = mutableSetOf(Pen.TOOL_PEN, Pen.TOOL_ERASER)
    private var owner: Owner? = null
    private var touchHeld = 0
    private var lastScrollUs = 0L
    private var eraserMode = false

    var penActive = false
        private set
    var penContact = false
        private set
    var scrollOpen = false
        private set
    var penWatchdogFires = 0
        private set
    var scrollWatchdogFires = 0
        private set
    var pressesAccepted = 0
        private set
    var pressesRejected = 0
        private set
    val violations = ArrayList<String>()

    val penInRange get() = penActive
    val touchDown get() = owner == Owner.TOUCH
    val touchReportedHeld get() = touchHeld and 1 != 0

    /** Nothing pressed or open (hover proximity is not "held" in this sense). */
    val clear get() = !penContact && owner == null && !scrollOpen

    /** Anything at all still entered: proximity, a button, an open scroll. */
    val hasHeld get() = penActive || owner != null || scrollOpen

    fun gateActive(nowUs: Long): Boolean {
        if (penActive) return true
        val l = lastPenAtUs ?: return false
        return (if (nowUs >= l) nowUs - l else 0) < GATE_HOLD_US
    }

    fun tick(nowUs: Long) {
        if (penActive) {
            if (penAnchorUs > nowUs) penAnchorUs = nowUs
            if (nowUs - penAnchorUs >= 500_000) { penWatchdogFires++; closePen() }
        }
        if (scrollOpen) {
            if (lastScrollUs > nowUs) lastScrollUs = nowUs
            if (nowUs - lastScrollUs >= 500_000) { scrollWatchdogFires++; scrollOpen = false }
        }
    }

    fun handle(m: Message, nowUs: Long) {
        tick(nowUs)
        when (m) {
            is Pen -> {
                lastPenAtUs = nowUs
                penAnchorUs = nowUs
                val tool = if (eraserMode || m.tool == Pen.TOOL_ERASER) Pen.TOOL_ERASER else Pen.TOOL_PEN
                for (s in m.samples) sample(tool, s)
            }
            is PointerAbs -> if (m.source == PointerAbs.SOURCE_TOUCH) pointer(m.buttons, nowUs)
            is Scroll -> scroll(m, nowUs)
            is PenGesture -> if (m.gesture == PenGesture.DOUBLE_TAP) eraserMode = !eraserMode
            is ReleaseAll -> releaseAll()
            else -> Unit
        }
    }

    fun releaseAll() {
        owner = null
        penActive = false
        penContact = false
        scrollOpen = false
        eraserMode = false
        latched.clear()
        latched += Pen.TOOL_PEN
        latched += Pen.TOOL_ERASER
        // touchHeld and lastPenAtUs are deliberately kept (pointer lock, the palm is still on the glass).
    }

    private fun closePen() {
        if (!penActive) return
        if (penContact && owner == Owner.PEN) owner = null
        penActive = false
        penContact = false
    }

    private fun sample(tool: Int, s: PenSample) {
        var flags = s.flags
        if (flags and PenSample.CONTACT != 0 && flags and PenSample.IN_RANGE == 0) flags = 0
        val inRange = flags and PenSample.IN_RANGE != 0
        var wants = inRange && flags and PenSample.CONTACT != 0
        val stroke = wants && flags and PenSample.STROKE_START != 0
        // The client rule under test: a contact sample that is not a stroke start only continues a contact the host holds.
        if (wants && !stroke && !penContact) violations += "contact sample without STROKE_START and no open contact"
        if (penActive && penTool != tool) {
            val wasContact = penContact
            closePen()
            if (wasContact) latched += tool
        }
        if (tool in latched) {
            if (wants && !stroke) wants = false else latched -= tool
        }
        if (!inRange) {
            closePen()
            return
        }
        if (!penActive) { penActive = true; penTool = tool; penContact = false }
        when {
            !penContact && wants -> {
                owner = Owner.PEN // pen priority: a touch owner is released first
                penContact = true
            }
            penContact && !wants -> { penContact = false; if (owner == Owner.PEN) owner = null }
            else -> Unit
        }
    }

    /** POINTER_ABS source TOUCH with the full reported button state. Returns true when a left press was accepted. */
    private fun pointer(buttonsRaw: Int, nowUs: Long): Boolean {
        val buttons = buttonsRaw and 0x1F
        val previous = touchHeld
        val pressed = buttons and 1 != 0 && previous and 1 == 0
        val released = buttons and 1 == 0 && previous and 1 != 0
        val accept = pressed && owner == null && !gateActive(nowUs)
        if (accept) { owner = Owner.TOUCH; pressesAccepted++ }
        else if (pressed) pressesRejected++
        else if (released && owner == Owner.TOUCH) owner = null
        touchHeld = buttons
        return accept
    }

    private fun scroll(m: Scroll, nowUs: Long) {
        when (m.phase) {
            Scroll.BEGAN -> { scrollOpen = true; lastScrollUs = nowUs }
            Scroll.CHANGED -> if (scrollOpen) lastScrollUs = nowUs else violations += "SCROLL CHANGED without BEGAN"
            Scroll.ENDED, Scroll.CANCELLED -> scrollOpen = false
        }
    }
}

/**
 * Sink that validates every message with the real codec, feeds one [HostModel] per connection, and can refuse
 * (connection down: the host releases everything, a reconnect starts a fresh host session) or report congestion.
 * [nowMs] is the test clock the host measures message receipt with; drive it together with the capture's `nowMs`.
 */
class FakeSink : InputSink {
    var host = HostModel()
        private set
    val sent = ArrayList<Message>()

    /** Test-clock time at which each message in [sent] was delivered. */
    val sentAt = ArrayList<Long>()
    var accept = true
    var congestedNow = false
    var nowMs = 0L
    var closeCalls = 0
    var throwOnSend = false

    /** Extra network delay of PEN messages only: the host receives them this many ms after they were sent. */
    var penDelayMs = 0L

    private var retiredWatchdogFires = 0
    private var retiredRejected = 0

    val nowUs get() = nowMs * 1000
    val watchdogFires get() = retiredWatchdogFires + host.penWatchdogFires + host.scrollWatchdogFires
    val pressesRejected get() = retiredRejected + host.pressesRejected

    override fun send(msg: Message): Boolean {
        if (throwOnSend) throw IllegalStateException("boom")
        if (!accept) return false
        Codec.encode(msg) // every message the trackers produce must be encodable
        if (msg is Pen) {
            var prev = -1L
            for (x in msg.samples) {
                require(x.dtUs >= prev) { "dt decreasing" }; prev = x.dtUs
                if (x.flags and PenSample.STROKE_START != 0) require(x.flags and PenSample.CONTACT != 0) { "SS without contact" }
                if (x.flags and PenSample.CONTACT == 0) require(x.pressure == 0) { "pressure without contact" }
            }
        }
        sent += msg
        sentAt += nowMs
        host.handle(msg, if (msg is Pen) nowUs + penDelayMs * 1000 else nowUs)
        return true
    }

    override fun congested() = congestedNow

    override fun closeConnection() {
        closeCalls++
        disconnect()
    }

    /** Runs the host's watchdogs at the current test time. */
    fun tickHost() = host.tick(nowUs)

    /** Connection drops: the host releases everything (PROTOCOL.md section 7). */
    fun disconnect() {
        accept = false
        host.releaseAll()
    }

    /** A new control connection: the host starts a fresh session (latched, nothing reported). */
    fun reconnect() {
        retiredWatchdogFires += host.penWatchdogFires + host.scrollWatchdogFires
        retiredRejected += host.pressesRejected
        host = HostModel()
        accept = true
    }

    fun clearSent() { sent.clear(); sentAt.clear() }
}

/** Settable [PenPresence] for tracker tests. */
class FakePresence(override var inRange: Boolean = false, override var lastSentMs: Long = NEVER_MS) : PenPresence

/** Fixed [PointerFollowers] for pure routing tests. */
class FakeFollowers(
    private val pen: Pair<Int, Int>? = null,
    private val finger: Pair<Int, Int>? = null,
) : PointerFollowers {
    override fun followsPen(deviceId: Int, pointerId: Int) = pen == deviceId to pointerId
    override fun followsFinger(deviceId: Int, pointerId: Int) = finger == deviceId to pointerId
    override val penContactDevice get() = pen?.first ?: NO_DEVICE
    override val touchDevice get() = finger?.first ?: NO_DEVICE
}

/**
 * After two fingers went down at (1000, 900) and (1200, 900): both slide [dy] px down. Two-finger gestures are classified at
 * the first meaningful movement (T-037), so this is what opens the scroll (BEGAN, then CHANGED); 30 px is beyond the slop.
 */
fun TouchTracker.slide(ms: Long, dy: Float = 30f) =
    onFrame(touchFrame(TouchAction.MOVE, ms, -1, finger(1, 1000f, 900f + dy), finger(2, 1200f, 900f + dy)), ms)
