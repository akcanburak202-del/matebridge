package dev.matebridge.client.session

import dev.matebridge.client.protocol.PointerRel
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class SendQueueStampTest {
    @Test fun takeStampedReturnsTheStampInFifoOrderAndTakeStillWorks() {
        val q = SendQueue()
        q.offer(byteArrayOf(1), 0, cls = 2, eventTimeUs = 111L)
        q.offer(byteArrayOf(2), 0) // unstamped
        q.offer(byteArrayOf(3), 0, cls = 0, eventTimeUs = 333L)
        val a = q.takeStamped()!!
        assertEquals(2, a.cls)
        assertEquals(111L, a.eventTimeUs)
        assertEquals(1, a.bytes[0].toInt())
        val b = q.takeStamped()!!
        assertEquals(-1, b.cls)
        assertEquals(0L, b.eventTimeUs)
        assertEquals(3, q.take()!![0].toInt())
    }

    @Test fun moreEventsStillMeetTheSameBound() {
        // T-322: unbuffered dispatch can raise the event rate; the queue bound (bytes) is unchanged and still trips once.
        val q = SendQueue(maxBytes = 1000, maxAgeMs = 1000)
        var accepted = 0
        repeat(100) { if (q.offer(ByteArray(40), 0, cls = 1, eventTimeUs = 5L)) accepted++ }
        assertEquals(25, accepted) // 25 * 40 = 1000 bytes
        assertTrue(q.isOverflowed())
        assertFalse(q.offer(ByteArray(1), 0)) // once a message was lost nothing slips through
        assertTrue(q.queuedBytes() <= 1000)
    }

    @Test fun controlLinkStampsInputMessagesWithClassAndEventTime() {
        val q = SendQueue()
        val link = ControlLink(q, { 0L }) {}
        assertTrue(link.send(PointerRel(4_000_000L, 1f, 1f, 0)))
        val s = q.takeStamped()!!
        assertEquals(1, s.cls) // POINTER
        assertEquals(4_000_000L, s.eventTimeUs)
    }
}
