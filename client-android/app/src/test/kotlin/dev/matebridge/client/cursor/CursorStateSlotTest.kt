package dev.matebridge.client.cursor

import dev.matebridge.client.protocol.CursorState
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class CursorStateSlotTest {
    private fun s(seq: Long, x: Int = 0) = CursorState(seq, x, 0, true, 1, 0)

    @Test fun firstStateIsAcceptedWhateverItsSeq() {
        val slot = CursorStateSlot()
        assertNull(slot.latest())
        assertTrue(slot.offer(s(4_000_000_000L), 5))
        assertEquals(4_000_000_000L, slot.latest()!!.seq)
        assertEquals(5L, slot.latest()!!.rxMs)
    }

    @Test fun onlyANewerSeqReplacesTheHeldOne() {
        val slot = CursorStateSlot()
        assertTrue(slot.offer(s(10, x = 1), 0))
        assertFalse(slot.offer(s(10, x = 2), 0)) // duplicate
        assertFalse(slot.offer(s(9, x = 3), 0)) // older
        assertTrue(slot.offer(s(11, x = 4), 0))
        assertTrue(slot.offer(s(15, x = 5), 0)) // gaps are fine (the host coalesces)
        assertEquals(5, slot.latest()!!.x)
    }

    @Test fun theU32WrapStillCountsAsNewer() {
        val slot = CursorStateSlot()
        assertTrue(slot.offer(s(0xFFFFFFFEL), 0))
        assertTrue(slot.offer(s(0xFFFFFFFFL), 0))
        assertTrue(slot.offer(s(0), 0)) // after the wrap
        assertFalse(slot.offer(s(0xFFFFFFFFL), 0)) // the old one is now older
        assertTrue(slot.offer(s(1), 0))
    }

    @Test fun halfTheSpaceAwayCountsAsOlder() {
        assertTrue(CursorStateSlot.isNewer(0x7FFFFFFFL + 10, 10))
        assertFalse(CursorStateSlot.isNewer(0x80000000L + 10, 10))
        assertFalse(CursorStateSlot.isNewer(5, 5))
    }

    @Test fun clearForgetsTheSeq() {
        val slot = CursorStateSlot()
        slot.offer(s(100), 0)
        slot.clear()
        assertNull(slot.latest())
        assertTrue(slot.offer(s(1), 0))
    }
}
