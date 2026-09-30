package dev.matebridge.client.input

import dev.matebridge.client.protocol.Message
import dev.matebridge.client.protocol.Pen
import dev.matebridge.client.protocol.PenSample
import dev.matebridge.client.protocol.PointerAbs
import dev.matebridge.client.protocol.ReleaseAll
import dev.matebridge.client.protocol.Scroll

/**
 * The one ordered exit for input messages (PROTOCOL.md sections 5 and 7). Everything goes to [sink]
 * in the order it was produced. While the sink reports congestion, a [Outgoing.mergeable] message is
 * held at the tail and merged with the next mergeable message of the same kind (hover PEN keeps the
 * newest sample, SCROLL CHANGED sums the deltas). Any other message first flushes the held one and is
 * then sent immediately, so a release, a stroke start, a button change or RELEASE_ALL is never merged,
 * dropped, delayed behind held data or reordered.
 *
 * When the sink refuses a message (no accepted session, or the bounded queue overflowed and the
 * connection is being reset), [onRefused] runs so the owner forgets its held-input model: the host
 * releases everything when the connection drops (PROTOCOL.md section 5).
 * UI thread only.
 */
class InputOutbox(
    private val sink: InputSink,
    private val counters: InputCounters = InputCounters(),
    private val onRefused: () -> Unit,
) {
    private var held: Outgoing? = null

    val hasHeld get() = held != null

    /** Returns false when the sink refused a message; [onRefused] has run and the rest of a batch should be dropped. */
    fun send(o: Outgoing): Boolean {
        if (o.mergeable && sink.congested()) {
            val h = held
            if (h != null) {
                val merged = merge(h.msg, o.msg)
                if (merged != null) {
                    held = Outgoing(merged, true)
                    counters.merged++
                    return true
                }
                if (!flush()) return false
            }
            held = o
            return true
        }
        if (!flush()) return false
        return transmit(o.msg)
    }

    /** Sends the held message now (order-preserving). */
    fun flush(): Boolean {
        val h = held ?: return true
        held = null
        return transmit(h.msg)
    }

    /** Periodic: releases a held message as soon as the queue has drained. */
    fun tick() {
        if (held != null && !sink.congested()) flush()
    }

    fun dropHeld() {
        held = null
    }

    private fun transmit(msg: Message): Boolean {
        var invalid = false
        val ok = try {
            sink.send(msg)
        } catch (e: IllegalArgumentException) {
            // The codec rejected our own message: a bug, but it must not crash the UI thread mid-stroke.
            invalid = true
            false
        }
        if (ok) {
            when (msg) {
                is Pen -> counters.penMsgs++
                is PointerAbs, is Scroll -> counters.touchMsgs++
                else -> counters.otherMsgs++
            }
            return true
        }
        held = null
        counters.refused++
        if (invalid) {
            // Earlier messages may have left state on the host that this one was meant to change: release it.
            counters.invalid++
            try { sink.send(ReleaseAll(ReleaseAll.USER)) } catch (_: IllegalArgumentException) {}
        }
        onRefused()
        return false
    }

    companion object {
        /** Merge two adjacent mergeable messages, or null when they are not of the same mergeable kind. */
        fun merge(a: Message, b: Message): Message? {
            if (a is Pen && b is Pen && a.tool == b.tool && a.isPlainHover() && b.isPlainHover()) {
                val newest = b.samples.last()
                // The newest hover sample stands for the whole run: same flags, only the position moved on.
                return Pen(b.tool, b.baseTimeUs + newest.dtUs, listOf(newest.copy(dtUs = 0)))
            }
            if (a is Scroll && b is Scroll && a.phase == Scroll.CHANGED && b.phase == Scroll.CHANGED) {
                return Scroll(b.timeUs, a.dx + b.dx, a.dy + b.dy, Scroll.CHANGED)
            }
            return null
        }

        private fun Pen.isPlainHover() = samples.isNotEmpty() && samples.all { it.flags == PenSample.IN_RANGE }
    }
}
