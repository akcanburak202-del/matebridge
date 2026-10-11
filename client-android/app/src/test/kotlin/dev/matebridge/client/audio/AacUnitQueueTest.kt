package dev.matebridge.client.audio

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

class AacUnitQueueTest {
    private fun u(i: Long) = AacUnit(i, i, ByteArray(1))

    @Test fun fullQueueDropsTheOldestAndNeverBlocks() {
        val q = AacUnitQueue(3)
        val units = (1L..5L).map { u(it) }
        units.forEach { assertTrue(q.offer(it)) }
        assertEquals(2, q.dropped)
        assertEquals(3, q.size)
        assertSame(units[2], q.poll(0))
        assertSame(units[3], q.poll(0))
        assertSame(units[4], q.poll(0))
        assertNull(q.poll(0))
    }

    @Test fun closedQueueRefusesAndEmpties() {
        val q = AacUnitQueue()
        q.offer(u(1))
        q.close()
        assertFalse(q.offer(u(2)))
        assertNull(q.poll(10))
        assertEquals(0, q.size)
    }

    @Test fun pollWakesOnOffer() {
        val q = AacUnitQueue()
        var got: AacUnit? = null
        val t = Thread { got = q.poll(2000) }.also { it.start() }
        Thread.sleep(30)
        val x = u(7)
        q.offer(x)
        t.join(1000)
        assertSame(x, got)
    }
}
