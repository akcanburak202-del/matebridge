package dev.matebridge.client.input

import dev.matebridge.client.protocol.Message
import dev.matebridge.client.protocol.Pen
import dev.matebridge.client.protocol.PenSample
import dev.matebridge.client.protocol.PointerAbs
import dev.matebridge.client.protocol.ReleaseAll
import dev.matebridge.client.protocol.Scroll
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class InputOutboxTest {
    private val sink = FakeSink()
    private var refused = 0
    private val counters = InputCounters()
    private val outbox = InputOutbox(sink, counters) { refused++ }

    private fun hover(x: Int, t: Long = 0, mergeable: Boolean = true) =
        Outgoing(Pen(Pen.TOOL_PEN, t, listOf(PenSample(0, x, x, 0, 0, 0, PenSample.IN_RANGE))), mergeable)

    private fun pen(flags: Int, x: Int = 1, t: Long = 0) =
        Outgoing(Pen(Pen.TOOL_PEN, t, listOf(PenSample(0, x, x, 0, 0, 0, flags))))

    private fun scroll(phase: Int, dx: Float = 0f, dy: Float = 0f, mergeable: Boolean = phase == Scroll.CHANGED) =
        Outgoing(Scroll(0, dx, dy, phase), mergeable)

    private fun xs(msgs: List<Message>) = penSamples(msgs).map { it.x }

    @Test fun withoutCongestionEverythingIsSentAtOnceInOrder() {
        outbox.send(hover(1)); outbox.send(hover(2)); outbox.send(pen(0, 3))
        assertEquals(listOf(1, 2, 3), xs(sink.sent))
        assertFalse(outbox.hasHeld)
    }

    @Test fun congestedHoverSamplesMergeKeepingTheNewest() {
        sink.congestedNow = true
        outbox.send(hover(1, t = 10)); outbox.send(hover(2, t = 20)); outbox.send(hover(3, t = 30))
        assertTrue(sink.sent.isEmpty())
        assertTrue(outbox.hasHeld)
        sink.congestedNow = false
        outbox.tick()
        assertEquals(1, sink.sent.size)
        val p = sink.sent[0] as Pen
        assertEquals(listOf(3), xs(sink.sent))
        assertEquals(30L, p.baseTimeUs)
        assertEquals(0L, p.samples[0].dtUs)
        assertEquals(2L, counters.merged)
    }

    @Test fun congestedScrollChangedSumsTheDeltas() {
        sink.congestedNow = true
        outbox.send(scroll(Scroll.CHANGED, 1f, 2f)); outbox.send(scroll(Scroll.CHANGED, 3f, -1f))
        sink.congestedNow = false
        outbox.tick()
        val s = sink.sent.single() as Scroll
        assertEquals(4f, s.dx, 0f)
        assertEquals(1f, s.dy, 0f)
    }

    @Test fun releaseIsNeverMergedAndFlushesTheHeldMessageFirst() {
        sink.congestedNow = true
        outbox.send(hover(5))
        outbox.send(pen(0, 6)) // flags = 0: leave (release)
        assertEquals(2, sink.sent.size)
        assertEquals(listOf(5, 6), xs(sink.sent))
        assertEquals(PenSample.IN_RANGE, penSamples(sink.sent)[0].flags)
        assertEquals(0, penSamples(sink.sent)[1].flags)
    }

    @Test fun stateTransitionsAreSentImmediatelyEvenWhenCongested() {
        sink.congestedNow = true
        outbox.send(pen(PenSample.IN_RANGE or PenSample.CONTACT or PenSample.STROKE_START))
        outbox.send(Outgoing(PointerAbs(0, 1, 1, 1, PointerAbs.SOURCE_TOUCH)))
        outbox.send(scroll(Scroll.BEGAN))
        outbox.send(scroll(Scroll.ENDED))
        outbox.send(Outgoing(ReleaseAll(ReleaseAll.BACKGROUND)))
        assertEquals(5, sink.sent.size)
        assertFalse(outbox.hasHeld)
    }

    @Test fun releaseAllGoesOutBehindHeldDataNotAheadOfIt() {
        sink.congestedNow = true
        outbox.send(scroll(Scroll.CHANGED, 1f, 1f))
        outbox.send(Outgoing(ReleaseAll(ReleaseAll.FOCUS_LOST)))
        assertEquals(listOf<Class<*>>(Scroll::class.java, ReleaseAll::class.java), sink.sent.map { it.javaClass })
    }

    @Test fun differentKindsAreNotMergedAndKeepTheirOrder() {
        sink.congestedNow = true
        outbox.send(hover(1))
        outbox.send(scroll(Scroll.CHANGED, 1f, 1f)) // flushes the held hover, holds the scroll
        assertEquals(1, sink.sent.size)
        assertTrue(sink.sent[0] is Pen)
        sink.congestedNow = false
        outbox.tick()
        assertTrue(sink.sent[1] is Scroll)
    }

    @Test fun aHeldMessageStaysHeldWhileCongestedAndGoesOutWhenItClears() {
        sink.congestedNow = true
        outbox.send(hover(1))
        outbox.tick()
        assertTrue(sink.sent.isEmpty())
        sink.congestedNow = false
        outbox.tick()
        assertEquals(1, sink.sent.size)
        assertFalse(outbox.hasHeld)
    }

    @Test fun refusalDropsHeldDataAndReportsOnce() {
        sink.congestedNow = true
        outbox.send(hover(1))
        sink.accept = false
        assertFalse(outbox.send(pen(0))) // flushes held, refused
        assertEquals(1, refused)
        assertFalse(outbox.hasHeld)
        assertEquals(1L, counters.refused)
    }

    @Test fun anInvalidMessageDoesNotCrashAndTriggersAReleaseAttempt() {
        val sent = ArrayList<Message>()
        var refusedCount = 0
        val throwing = object : InputSink {
            override fun send(msg: Message): Boolean {
                if (msg is Pen) throw IllegalArgumentException("bad")
                sent += msg
                return true
            }
            override fun congested() = false
        }
        val ob = InputOutbox(throwing, counters) { refusedCount++ }
        assertFalse(ob.send(pen(0)))
        assertEquals(1, refusedCount)
        assertEquals(1L, counters.invalid)
        assertTrue(sent.single() is ReleaseAll)
    }

    @Test fun mergeRefusesNonHoverAndMismatchedInput() {
        assertNull(InputOutbox.merge(hover(1).msg, pen(PenSample.IN_RANGE or PenSample.CONTACT).msg))
        assertNull(InputOutbox.merge(scroll(Scroll.CHANGED).msg, scroll(Scroll.ENDED).msg))
        assertNull(InputOutbox.merge(hover(1).msg, scroll(Scroll.CHANGED).msg))
        val eraser = Outgoing(Pen(Pen.TOOL_ERASER, 0, listOf(PenSample(0, 1, 1, 0, 0, 0, PenSample.IN_RANGE))), true)
        assertNull(InputOutbox.merge(hover(1).msg, eraser.msg))
    }
}
