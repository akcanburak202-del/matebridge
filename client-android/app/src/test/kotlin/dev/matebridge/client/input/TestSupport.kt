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

fun finger(id: Int, x: Float, y: Float) = Finger(id, x, y)

fun touchFrame(action: TouchAction, tMs: Long, actingId: Int, vararg fingers: Finger, device: Int = 2) =
    TouchFrame(action, actingId, fingers.toList(), tMs * 1000, device)

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
        return (if (nowUs >= l) nowUs - l else 0) < 1_000_000
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
        host.handle(msg, nowUs)
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
