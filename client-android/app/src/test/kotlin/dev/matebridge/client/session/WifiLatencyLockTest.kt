package dev.matebridge.client.session

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** T-388: the `wifi_ll` lock state machine with a fake platform lock. */
class WifiLatencyLockTest {
    private class FakeHandle(var grants: Boolean = true, var throws: Boolean = false) : WifiLatencyLock.Handle {
        var acquires = 0
        var releases = 0
        override fun acquire(): Boolean { acquires++; if (throws) throw SecurityException(); return grants }
        override fun release() { releases++ }
    }

    private val states = ArrayList<String>()

    @Test fun heldThenReleasedIdempotent() {
        val h = FakeHandle()
        val l = WifiLatencyLock(h) { states.add(it) }
        l.acquire(); l.acquire()
        assertTrue(l.isHeld)
        l.release(); l.release()
        assertFalse(l.isHeld)
        assertEquals(listOf("held", "released"), states)
        assertEquals(1, h.acquires)
        assertEquals(1, h.releases)
    }

    @Test fun reacquireAfterRelease() {
        val l = WifiLatencyLock(FakeHandle()) { states.add(it) }
        l.acquire(); l.release(); l.acquire()
        assertEquals(listOf("held", "released", "held"), states)
    }

    @Test fun unsupportedIsReportedOnceAndNothingHeld() {
        val l = WifiLatencyLock(null) { states.add(it) }
        l.acquire(); l.acquire(); l.release()
        assertEquals(listOf("unsupported"), states)
        assertFalse(l.isHeld)
    }

    @Test fun throwingOrRefusedAcquireIsUnsupported() {
        WifiLatencyLock(FakeHandle(throws = true)) { states.add(it) }.acquire()
        WifiLatencyLock(FakeHandle(grants = false)) { states.add(it) }.acquire()
        assertEquals(listOf("unsupported", "unsupported"), states)
    }
}
