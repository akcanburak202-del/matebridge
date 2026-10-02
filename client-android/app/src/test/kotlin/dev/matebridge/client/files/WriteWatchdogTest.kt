package dev.matebridge.client.files

import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** T-139: the write-stall timeout. */
class WriteWatchdogTest {
    private var now = 0L
    private val ms = 1_000_000L

    @Test fun aWriteRunningForTheTimeoutExpiresAndAFinishedOneNever() {
        val wd = WriteWatchdog(30_000) { now }
        val a = wd.Watch {}
        val b = wd.Watch {}
        a.begin()
        now = 10_000 * ms
        b.begin()
        now = 29_999 * ms
        assertEquals(listOf<Any>(), wd.expire(now))
        now = 30_000 * ms
        assertEquals(listOf(a), wd.expire(now)) // only the one stuck for the whole timeout
        b.end()
        now = 100_000 * ms
        assertEquals(listOf<Any>(), wd.expire(now)) // b finished in time
        assertEquals(0, wd.runningCount())
    }

    @Test fun eachWriteGetsAFreshDeadlineSoSteadyProgressNeverExpires() {
        val wd = WriteWatchdog(1_000) { now }
        val a = wd.Watch {}
        val b = wd.Watch {}
        a.begin()
        b.begin()
        repeat(100) {
            // a makes progress every 0.6 s (with rate-cap waits in between, outside begin/end); b is stuck.
            now += 600 * ms
            a.end()
            val due = wd.expire(now)
            if (now < 1_000 * ms) assertEquals(listOf<Any>(), due)
            assertFalse(due.contains(a))
            a.begin()
        }
        assertEquals(1, wd.runningCount()) // b expired once and was removed; a is running
    }

    @Test fun theThreadFiresOnlyStalledWritesAndStops() {
        val wd = WriteWatchdog(150)
        val fired = AtomicInteger()
        val stalled = CountDownLatch(1)
        val t = Thread { wd.runLoop() }.also { it.isDaemon = true; it.start() }
        val quick = wd.Watch { fired.incrementAndGet() }
        repeat(20) { quick.begin(); Thread.sleep(10); quick.end() } // 200 ms of short writes: never 150 ms in one
        val stuck = wd.Watch { stalled.countDown() }
        val start = System.nanoTime()
        stuck.begin()
        assertTrue(stalled.await(2, TimeUnit.SECONDS))
        assertTrue((System.nanoTime() - start) / ms >= 140)
        assertEquals(0, fired.get())
        wd.stop()
        t.join(2000)
        assertFalse(t.isAlive)
    }
}
