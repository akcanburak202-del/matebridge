package dev.matebridge.client.video

import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference
import java.util.concurrent.locks.Condition
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

/** T-161: [GenerationHandoff] and the [RestartPolicy] backoff, pure. */
class GenerationHandoffTest {
    /** Every wait returns at once and advances the clock by its full length. */
    private class FakeTimer : HandoffTimer {
        var now = 0L
        val waits = CopyOnWriteArrayList<Long>()
        override fun nowMs() = now
        override fun await(condition: Condition, ms: Long) { waits.add(ms); now += ms }
    }

    private fun generation(h: GenerationHandoff, gen: Int, threads: Int = 1) =
        CodecGeneration(gen, Any()).also { g -> repeat(threads) { h.threadStarted(g) } }

    @Test fun aGenerationIsFinishedOnlyWhenItsDecoderAndOutputThreadsHaveExited() {
        val timer = FakeTimer()
        val h = GenerationHandoff(timer)
        val g1 = generation(h, 1, threads = 2) // decoder + output thread
        assertEquals(GenerationHandoff.Result.Ready, h.acquire(g1, 2_000))
        h.retire(g1)
        h.threadExited(g1) // the decoder thread left; its output thread is a straggler
        assertFalse(h.isFinished(g1))

        val g2 = generation(h, 2)
        val r = h.acquire(g2, 2_000)
        assertTrue(r is GenerationHandoff.Result.Stuck)
        assertSame(g1, (r as GenerationHandoff.Result.Stuck).previous)
        assertEquals(2_000L, r.waitedMs)
        assertEquals(listOf(2_000L), timer.waits)

        h.threadExited(g1) // the straggler is gone too
        assertTrue(h.isFinished(g1))
        h.retire(g2); h.threadExited(g2)
        // g2 never owned a codec, so the next generation waits for nobody.
        assertEquals(GenerationHandoff.Result.Ready, h.acquire(generation(h, 3), 2_000))
    }

    @Test fun theStuckOwnerStaysTheSingleReferenceForEveryLaterGeneration() {
        val timer = FakeTimer()
        val h = GenerationHandoff(timer)
        val g1 = generation(h, 1)
        h.acquire(g1, 2_000)
        h.retire(g1) // hangs: never exits
        for (gen in 2..4) {
            val g = generation(h, gen)
            val r = h.acquire(g, 2_000)
            assertSame("generation $gen", g1, (r as GenerationHandoff.Result.Stuck).previous)
            h.threadExited(g)
        }
        assertEquals(0, h.waitingThreads)
    }

    @Test fun retireWakesAWaitingThreadAtOnce() {
        val waiting = CountDownLatch(1)
        val h = GenerationHandoff(object : HandoffTimer { // real clock; signals when the wait begins
            override fun nowMs() = HandoffTimer.SYSTEM.nowMs()
            override fun await(condition: Condition, ms: Long) { waiting.countDown(); HandoffTimer.SYSTEM.await(condition, ms) }
        })
        val g1 = generation(h, 1)
        h.acquire(g1, 1_000)
        h.retire(g1) // never exits
        val g2 = generation(h, 2)
        val result = AtomicReference<GenerationHandoff.Result>()
        val done = CountDownLatch(1)
        val t = Thread { result.set(h.acquire(g2, 60_000)); done.countDown() }
        t.start()
        try {
            assertTrue("never waited", waiting.await(5, TimeUnit.SECONDS))
            assertEquals(1, h.waitingThreads) // blocks until the waiter released the lock inside its wait
            h.retire(g2)
            assertTrue("retire did not wake the waiter", done.await(5, TimeUnit.SECONDS))
            assertEquals(GenerationHandoff.Result.Retired, result.get())
            assertEquals(0, h.waitingThreads)
        } finally {
            h.retire(g2); t.join(5_000)
        }
    }

    @Test fun awaitOwnThreadsWaitsOnlyForTheGenerationsOtherThreads() {
        val timer = FakeTimer()
        val h = GenerationHandoff(timer)
        val g = generation(h, 1, threads = 2) // the calling decoder thread + a straggler output thread
        val r = h.acquire(g, 2_000)
        assertEquals(GenerationHandoff.Result.Ready, r)
        val stuck = h.awaitOwnThreads(g, 300)
        assertSame(g, (stuck as GenerationHandoff.Result.Stuck).previous)
        assertEquals(300L, stuck.waitedMs)
        h.threadExited(g) // the straggler left
        assertEquals(GenerationHandoff.Result.Ready, h.awaitOwnThreads(g, 300))
        h.retire(g)
        assertEquals(GenerationHandoff.Result.Retired, h.awaitOwnThreads(g, 300))
    }

    @Test fun retireWaitsForTheSharedLockOnlyBriefly() {
        val h = GenerationHandoff()
        val g = generation(h, 1)
        assertTrue("free lock", h.retire(g))

        val g2 = generation(h, 2)
        val held = CountDownLatch(1)
        val release = CountDownLatch(1)
        val holder = Thread { g2.sharedLock.lock(); try { held.countDown(); release.await(10, TimeUnit.SECONDS) } finally { g2.sharedLock.unlock() } }
        holder.start()
        try {
            assertTrue(held.await(5, TimeUnit.SECONDS))
            val startNs = System.nanoTime()
            assertFalse("the lock was held", h.retire(g2))
            val tookMs = TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - startNs)
            assertTrue("took $tookMs ms", tookMs < VideoRenderer.JOIN_MS)
            assertFalse("retired anyway", g2.active)
        } finally {
            release.countDown(); holder.join(5_000)
        }
    }

    @Test fun pauseWaitsItsFullLengthUnlessRetired() {
        val timer = FakeTimer()
        val h = GenerationHandoff(timer)
        val g = generation(h, 1)
        assertTrue(h.pause(g, 500))
        assertEquals(500L, timer.now)
        h.retire(g)
        assertFalse(h.pause(g, 1_000))
        assertEquals("a retired generation does not wait", 500L, timer.now)
    }

    @Test fun restartPolicyBacksOff100Then500Then1000AndKeepsThreePerTenSeconds() {
        val p = RestartPolicy()
        assertTrue(p.allow(0)); assertEquals(100L, p.delayMs())
        assertTrue(p.allow(200)); assertEquals(500L, p.delayMs())
        assertTrue(p.allow(800)); assertEquals(1_000L, p.delayMs())
        assertFalse("fourth restart within 10 s", p.allow(1_900))
        assertFalse(p.allow(9_999))
        assertTrue("the first restart left the window", p.allow(10_000)); assertEquals(1_000L, p.delayMs())
        assertTrue("a quiet window starts the backoff over", p.allow(40_000)); assertEquals(100L, p.delayMs())
    }
}
