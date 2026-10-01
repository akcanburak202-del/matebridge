package dev.matebridge.client.video

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class PerfHintTest {
    private class FakeSession(val tids: IntArray, var target: Long) : PerfHint.Session {
        val reports = mutableListOf<Long>()
        var closed = false
        var throwOnReport = false
        override fun updateTargetWorkDuration(targetNs: Long) { check(!closed); target = targetNs }
        override fun reportActualWorkDuration(actualNs: Long) {
            check(!closed)
            if (throwOnReport) throw IllegalArgumentException()
            reports += actualNs
        }
        override fun close() { closed = true }
    }

    private class FakeBackend(var refuse: Boolean = false, var throwOnCreate: Boolean = false) : PerfHint.Backend {
        val sessions = mutableListOf<FakeSession>()
        override val preferredUpdateRateNs = 16_666_666L
        override fun createSession(tids: IntArray, targetNs: Long): PerfHint.Session? {
            if (throwOnCreate) throw SecurityException()
            if (refuse) return null
            return FakeSession(tids, targetNs).also { sessions += it }
        }
        fun open() = sessions.filter { !it.closed }
    }

    private val logs = mutableListOf<String>()
    private fun hint(b: PerfHint.Backend?) = PerfHint(b) { ev, f -> logs += "$ev $f" }

    private fun PerfHint.registerAll(net: Int = 11, inp: Int = 12, out: Int = 13) {
        register(PerfHint.ROLE_NET, net); register(PerfHint.ROLE_IN, inp); register(PerfHint.ROLE_OUT, out)
    }

    @Test fun sessionOnlyWithAllThreadsAndTarget() {
        val b = FakeBackend()
        val h = hint(b)
        h.register(PerfHint.ROLE_NET, 11)
        h.register(PerfHint.ROLE_IN, 12)
        h.setTargetNs(6_944_444)
        assertTrue(b.sessions.isEmpty())
        h.register(PerfHint.ROLE_OUT, 13)
        assertEquals(1, b.sessions.size)
        assertArrayEquals(intArrayOf(11, 12, 13), b.sessions[0].tids)
        assertEquals(6_944_444L, b.sessions[0].target)
        assertTrue(h.hasSession())
        assertTrue(logs.last().startsWith("perf_hint supported=1 session=1 target_us=6944 threads=3"))
    }

    @Test fun noTargetNoSessionUntilTargetArrives() {
        val b = FakeBackend()
        val h = hint(b)
        h.registerAll()
        assertTrue(b.sessions.isEmpty())
        h.setTargetNs(16_666_666)
        assertEquals(1, b.open().size)
    }

    @Test fun targetChangeUpdatesInPlace() {
        val b = FakeBackend()
        val h = hint(b)
        h.setTargetNs(16_666_666)
        h.registerAll()
        h.setTargetNs(6_944_444)
        assertEquals(1, b.sessions.size)
        assertEquals(6_944_444L, b.sessions[0].target)
        h.setTargetNs(6_944_444) // unchanged: nothing
        assertEquals(1, b.sessions.size)
    }

    @Test fun fixedTargetIgnoresPanelRate() {
        val b = FakeBackend()
        val h = hint(b)
        h.setFixedTargetNs(1_000_000)
        h.registerAll()
        h.setTargetNs(6_944_444)
        assertEquals(1_000_000L, b.sessions.single().target)
        assertEquals(1_000_000L, h.targetNs())
    }

    @Test fun threadChangeRebuildsAndRoleGoneCloses() {
        val b = FakeBackend()
        val h = hint(b)
        h.setTargetNs(6_944_444)
        h.registerAll()
        h.register(PerfHint.ROLE_OUT, 23) // codec restart: new output thread
        assertEquals(2, b.sessions.size)
        assertTrue(b.sessions[0].closed)
        assertArrayEquals(intArrayOf(11, 12, 23), b.sessions[1].tids)
        h.unregister(PerfHint.ROLE_OUT, 13) // the old thread exits late: ignored
        assertEquals(1, b.open().size)
        h.unregister(PerfHint.ROLE_NET, 11) // stream over
        assertTrue(b.open().isEmpty())
        assertFalse(h.hasSession())
    }

    @Test fun sameTidAgainIsNoChange() {
        val b = FakeBackend()
        val h = hint(b)
        h.setTargetNs(6_944_444)
        h.registerAll()
        h.register(PerfHint.ROLE_IN, 12)
        assertEquals(1, b.sessions.size)
    }

    @Test fun closeEndsSessionForGood() {
        val b = FakeBackend()
        val h = hint(b)
        h.setTargetNs(6_944_444)
        h.registerAll()
        h.close()
        assertTrue(b.open().isEmpty())
        h.report(1_000_000)
        assertTrue(b.sessions[0].reports.isEmpty())
    }

    @Test fun recvToInputIsReportedOnce() {
        val b = FakeBackend()
        val h = hint(b)
        h.setTargetNs(6_944_444)
        h.registerAll()
        h.onRecv(5, 1_000_000)
        h.onInput(5, 2_500_000)
        h.onInput(5, 3_000_000) // second fragment / repeat: already consumed
        h.onInput(6, 3_000_000) // never received
        assertEquals(listOf(1_500_000L), b.sessions[0].reports)
        assertEquals(1L, h.reportCount())
    }

    @Test fun ringSlotOfAnotherFrameIsNotPaired() {
        val b = FakeBackend()
        val h = hint(b)
        h.setTargetNs(6_944_444)
        h.registerAll()
        h.onRecv(3, 1_000)
        h.onRecv(3 + 64, 5_000) // same slot, newer frame
        h.onInput(3, 9_000)
        assertTrue(b.sessions[0].reports.isEmpty())
        h.onInput(3 + 64, 9_000)
        assertEquals(listOf(4_000L), b.sessions[0].reports)
    }

    @Test fun implausibleDurationsAreDropped() {
        val b = FakeBackend()
        val h = hint(b)
        h.setTargetNs(6_944_444)
        h.registerAll()
        h.report(0); h.report(-5); h.report(2_000_000_000)
        assertTrue(b.sessions[0].reports.isEmpty())
    }

    @Test fun reportWithoutSessionIsDropped() {
        val b = FakeBackend()
        val h = hint(b)
        h.onRecv(1, 0)
        h.onInput(1, 100)
        h.report(1_000)
        assertTrue(b.sessions.isEmpty())
    }

    @Test fun unsupportedPlatformIsANoOp() {
        val h = hint(null)
        h.setTargetNs(6_944_444)
        h.registerAll()
        h.onRecv(1, 0); h.onInput(1, 100)
        assertFalse(h.supported)
        assertFalse(h.hasSession())
        assertEquals("supported=0 session=0 target_us=6944 rate_us=0", h.describe())
    }

    @Test fun refusedOrThrowingCreateLeavesNoSession() {
        val refused = FakeBackend(refuse = true)
        val h1 = hint(refused)
        h1.setTargetNs(6_944_444)
        h1.registerAll()
        assertFalse(h1.hasSession())
        assertTrue(logs.last().startsWith("perf_hint supported=1 session=0"))

        val throwing = FakeBackend(throwOnCreate = true)
        val h2 = hint(throwing)
        h2.setTargetNs(6_944_444)
        h2.registerAll()
        assertFalse(h2.hasSession())
        assertTrue(logs.any { it.startsWith("perf_hint_error op=create err=SecurityException") })
    }

    @Test fun reportFailureIsLoggedNotThrown() {
        val b = FakeBackend()
        val h = hint(b)
        h.setTargetNs(6_944_444)
        h.registerAll()
        b.sessions[0].throwOnReport = true
        h.report(1_000)
        assertEquals(0L, h.reportCount())
        assertTrue(logs.last().startsWith("perf_hint_error op=report"))
    }

    @Test fun describeShowsRateAndSession() {
        val b = FakeBackend()
        val h = hint(b)
        h.setTargetNs(6_944_444)
        assertEquals("supported=1 session=0 target_us=6944 rate_us=16666", h.describe())
        h.registerAll()
        assertEquals("supported=1 session=1 target_us=6944 rate_us=16666", h.describe())
    }
}
