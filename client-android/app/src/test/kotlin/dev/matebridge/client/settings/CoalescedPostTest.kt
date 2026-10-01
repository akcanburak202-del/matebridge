package dev.matebridge.client.settings

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/** T-105 review: a flood of SETTINGS_OPEN queues at most one UI runnable. */
class CoalescedPostTest {
    private val queue = ArrayDeque<Runnable>()
    private var runs = 0
    private val post = CoalescedPost({ queue.addLast(it) }) { runs++ }

    private fun drain() { while (queue.isNotEmpty()) queue.removeFirst().run() }

    @Test fun burstQueuesOneRunnable() {
        assertTrue(post.request())
        repeat(1000) { assertFalse(post.request()) }
        assertEquals(1, queue.size)
        drain()
        assertEquals(1, runs)
    }

    @Test fun aRequestAfterTheRunPostsAgain() {
        post.request()
        drain()
        assertTrue(post.request())
        assertEquals(1, queue.size)
        drain()
        assertEquals(2, runs)
    }

    @Test fun aRequestDuringTheActionIsNotLost() {
        val q = ArrayDeque<Runnable>()
        var n = 0
        lateinit var p: CoalescedPost
        p = CoalescedPost({ q.addLast(it) }) { n++; if (n == 1) assertTrue(p.request()) }
        p.request()
        while (q.isNotEmpty()) q.removeFirst().run()
        assertEquals(2, n)
    }

    @Test fun aFailedPostDoesNotBlockLaterRequests() {
        var fail = true
        val q = ArrayDeque<Runnable>()
        val p = CoalescedPost({ if (fail) throw IllegalStateException("looper gone") else q.addLast(it) }) {}
        try { p.request() } catch (_: IllegalStateException) {}
        fail = false
        assertTrue(p.request())
        assertEquals(1, q.size)
    }

    @Test fun concurrentRequestsQueueOne() {
        val q = java.util.concurrent.ConcurrentLinkedQueue<Runnable>()
        val p = CoalescedPost({ q.add(it) }) {}
        val pool = Executors.newFixedThreadPool(8)
        val start = CountDownLatch(1)
        repeat(8) { pool.execute { start.await(); repeat(500) { p.request() } } }
        start.countDown()
        pool.shutdown()
        assertTrue(pool.awaitTermination(10, TimeUnit.SECONDS))
        assertEquals(1, q.size)
    }
}
