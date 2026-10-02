package dev.matebridge.client.session

import java.io.Closeable
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ProbeGuardTest {
    private class FakeSocket : Closeable {
        var closed = 0
        override fun close() { closed++ }
    }

    private val g = ProbeGuard()

    @Test fun currentProbeMayConnect() {
        val gen = g.bump()
        assertTrue(g.isCurrent(gen))
        val s = FakeSocket()
        assertTrue(g.attach(gen, s))
        g.detach(gen)
        assertEquals(0, s.closed)
    }

    @Test fun queuedProbeDoesNotConnectAfterABump() {
        val gen = g.bump() // probe queued on the worker
        g.bump() // BYE(HOST_SLEEP), background, transport change, ...
        assertFalse(g.isCurrent(gen))
        assertFalse(g.attach(gen, FakeSocket())) // the worker must not connect
    }

    @Test fun bumpClosesAConnectingProbe() {
        val gen = g.bump()
        val s = FakeSocket()
        assertTrue(g.attach(gen, s))
        g.bump()
        assertEquals(1, s.closed)
        g.detach(gen) // late detach of the stale probe: harmless
        g.bump()
        assertEquals(1, s.closed) // closed once only
    }

    @Test fun detachedProbeIsNotClosedLater() {
        val gen = g.bump()
        val s = FakeSocket()
        g.attach(gen, s)
        g.detach(gen)
        g.bump()
        assertEquals(0, s.closed)
    }

    @Test fun staleDetachDoesNotDropTheCurrentProbe() {
        val old = g.bump()
        val cur = g.bump()
        val s = FakeSocket()
        assertTrue(g.attach(cur, s))
        g.detach(old)
        g.bump()
        assertEquals(1, s.closed)
    }
}
