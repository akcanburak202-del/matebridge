package dev.matebridge.client.cursor

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class RedrawGateTest {
    @Test fun manyStatesDuringAStalledUiScheduleExactlyOneRedrawWithTheMergedRectangle() {
        val gate = RedrawGate()
        var scheduled = 0
        for (i in 0 until 10_000) { // the UI thread never runs the task meanwhile
            if (gate.request(intArrayOf(i, 2 * i, i + 20, 2 * i + 40))) scheduled++
        }
        assertEquals(1, scheduled)
        assertTrue(gate.isPending)
        val d = gate.take()!!
        assertFalse(d.full)
        assertEquals(listOf(0, 0, 9_999 + 20, 2 * 9_999 + 40), listOf(d.left, d.top, d.right, d.bottom))
        assertFalse(gate.isPending)
        assertNull(gate.take()) // one task, one invalidate
    }

    @Test fun afterTheTaskRanTheNextRequestSchedulesAgain() {
        val gate = RedrawGate()
        assertTrue(gate.request(intArrayOf(1, 2, 3, 4)))
        gate.take()
        assertTrue(gate.request(intArrayOf(50, 60, 70, 80)))
        val d = gate.take()!!
        assertEquals(listOf(50, 60, 70, 80), listOf(d.left, d.top, d.right, d.bottom)) // the old area did not leak in
    }

    @Test fun aFullRepaintWinsOverRectanglesUntilTheTaskRuns() {
        val gate = RedrawGate()
        assertTrue(gate.request(intArrayOf(1, 2, 3, 4)))
        assertFalse(gate.request(null, full = true))
        assertFalse(gate.request(intArrayOf(5, 6, 7, 8)))
        assertTrue(gate.take()!!.full)
        assertTrue(gate.request(intArrayOf(1, 2, 3, 4)))
        assertFalse(gate.take()!!.full) // the flag was consumed
    }

    @Test fun nothingToRedrawSchedulesNothing() {
        val gate = RedrawGate()
        assertFalse(gate.request(null))
        assertFalse(gate.isPending)
        assertNull(gate.take())
    }

    @Test fun aFullRequestAloneSchedulesOnce() {
        val gate = RedrawGate()
        assertTrue(gate.request(null, full = true))
        assertFalse(gate.request(null, full = true))
        assertNotNull(gate.take())
    }

    @Test fun aRecomputeRequestSchedulesOnceAndCarriesNoRectangle() {
        val gate = RedrawGate()
        assertTrue(gate.requestRecompute())
        assertFalse(gate.requestRecompute())
        assertFalse(gate.request(null)) // nothing to merge, one is already pending
        val d = gate.take()!!
        assertFalse(d.full)
        assertFalse(d.hasRect)
        assertNull(gate.take())
        // A rectangle merged into the pending recompute is kept.
        assertTrue(gate.requestRecompute())
        gate.request(intArrayOf(1, 2, 3, 4))
        val e = gate.take()!!
        assertTrue(e.hasRect)
        assertEquals(listOf(1, 2, 3, 4), listOf(e.left, e.top, e.right, e.bottom))
    }

    @Test fun concurrentRequestersScheduleExactlyOne() {
        val gate = RedrawGate()
        val scheduled = java.util.concurrent.atomic.AtomicInteger()
        val threads = (0 until 4).map { n ->
            Thread { repeat(5_000) { i -> if (gate.request(intArrayOf(i, n, i + 1, n + 1))) scheduled.incrementAndGet() } }
        }
        threads.forEach { it.start() }
        threads.forEach { it.join() }
        assertEquals(1, scheduled.get())
    }
}
