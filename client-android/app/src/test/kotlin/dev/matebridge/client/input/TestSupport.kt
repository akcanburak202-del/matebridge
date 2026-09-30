package dev.matebridge.client.input

import dev.matebridge.client.protocol.Codec
import dev.matebridge.client.protocol.Message
import dev.matebridge.client.protocol.Pen
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

fun penFrame(action: PenAction, vararg pts: PenPoint, eraser: Boolean = false, device: Int = 1) =
    PenFrame(action, eraser, pts.toList(), device)

fun finger(id: Int, x: Float, y: Float) = Finger(id, x, y)

fun touchFrame(action: TouchAction, tMs: Long, actingId: Int, vararg fingers: Finger, device: Int = 2) =
    TouchFrame(action, actingId, fingers.toList(), tMs * 1000, device)

/** Flattens all pen samples of the given messages. */
fun penSamples(msgs: List<Message>): List<PenSample> = msgs.filterIsInstance<Pen>().flatMap { it.samples }

fun List<Outgoing>.messages(): List<Message> = map { it.msg }

/**
 * Reference model of what the host does with the client's messages (PROTOCOL.md sections 4 and 7,
 * simplified). Used to assert the invariants that matter: nothing stays pressed, and the client never
 * continues a stroke the host does not know about.
 */
class HostModel {
    var penInRange = false
    var penContact = false
    var latched = false
    var touchDown = false
    var scrollOpen = false
    val violations = ArrayList<String>()

    val clear get() = !penContact && !touchDown && !scrollOpen

    fun releaseAll() {
        penInRange = false
        penContact = false
        touchDown = false
        scrollOpen = false
        latched = true
    }

    fun apply(m: Message) {
        when (m) {
            is Pen -> m.samples.forEach { sample(it) }
            is PointerAbs -> if (m.source == PointerAbs.SOURCE_TOUCH) touchDown = m.buttons and 1 != 0
            is Scroll -> when (m.phase) {
                Scroll.BEGAN -> scrollOpen = true
                Scroll.CHANGED -> if (!scrollOpen) violations += "SCROLL CHANGED without BEGAN"
                Scroll.ENDED, Scroll.CANCELLED -> scrollOpen = false
            }
            is ReleaseAll -> releaseAll()
            else -> Unit
        }
    }

    private fun sample(s: PenSample) {
        var flags = s.flags
        if (flags and PenSample.CONTACT != 0 && flags and PenSample.IN_RANGE == 0) flags = 0
        val contact = flags and PenSample.CONTACT != 0
        val stroke = flags and PenSample.STROKE_START != 0
        // The client rule: a contact sample that is not a stroke start only continues a contact the host knows.
        if (contact && !stroke && !penContact) violations += "contact sample without STROKE_START and no open contact"
        if (latched && (!contact || stroke)) latched = false
        if (contact && latched) {
            penInRange = true
            penContact = false
            return
        }
        penContact = contact
        penInRange = flags and PenSample.IN_RANGE != 0
    }
}

/**
 * Sink that validates every message with the real codec, feeds the [HostModel], and can refuse
 * (connection down: the host releases everything) or report congestion.
 */
class FakeSink(val host: HostModel = HostModel()) : InputSink {
    val sent = ArrayList<Message>()
    var accept = true
    var congestedNow = false

    override fun send(msg: Message): Boolean {
        if (!accept) return false
        Codec.encode(msg) // every message the tracker produces must be encodable
        sent += msg
        host.apply(msg)
        return true
    }

    override fun congested() = congestedNow

    /** Connection drops: the host releases everything (PROTOCOL.md section 7). */
    fun disconnect() {
        accept = false
        host.releaseAll()
    }

    fun reconnect() {
        accept = true
    }

    fun clearSent() = sent.clear()
}

/** Settable [PenPresence] for tracker tests. */
class FakePresence(override var inRange: Boolean = false, override var lastEventMs: Long = NEVER_MS) : PenPresence
