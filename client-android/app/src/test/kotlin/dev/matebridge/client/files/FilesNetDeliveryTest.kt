package dev.matebridge.client.files

import dev.matebridge.client.protocol.FilesNet
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** T-269: FILES_NET reaches the UI thread through one slot and at most one queued run. */
class FilesNetDeliveryTest {
    private val open = FilesNet(FilesNet.STATE_OPEN, 47003, 2, 12)
    private val close = FilesNet(FilesNet.STATE_CLOSE, 0, 0, 0)

    private class Rig {
        val queue = ArrayDeque<Runnable>()
        val delivered = ArrayList<Pair<Int, FilesNet>>()
        val d = FilesNetDelivery({ queue.addLast(it) }) { g, m -> delivered += g to m }
        fun runAll() { while (queue.isNotEmpty()) queue.removeFirst().run() }
    }

    @Test fun aBurstOfRepeatsQueuesOneRunAndDeliversOnce() {
        val r = Rig()
        assertTrue(r.d.offer(3, open))
        repeat(10_000) { assertFalse(r.d.offer(3, open)) } // identical and already waiting
        assertEquals(1, r.queue.size)
        r.runAll()
        assertEquals(listOf(3 to open), r.delivered)
    }

    @Test fun onlyTheLatestStateSurvivesSoACloseIsNeverBehindRepeats() {
        val r = Rig()
        r.d.offer(3, open)
        repeat(1_000) { r.d.offer(3, open.copy(pool = 1 + it % 4)) } // other sizes: not identical, still one slot
        r.d.offer(3, close)
        assertEquals(1, r.queue.size)
        r.runAll()
        assertEquals(listOf(3 to close), r.delivered)
    }

    @Test fun aValueOfferedWhileTheRunIsExecutingPostsAgain() {
        val r = Rig()
        var rerun = false
        lateinit var d: FilesNetDelivery
        d = FilesNetDelivery({ r.queue.addLast(it) }) { g, m ->
            r.delivered += g to m
            if (!rerun) { rerun = true; d.offer(g, close) }
        }
        d.offer(1, open)
        r.runAll()
        assertEquals(listOf(1 to open, 1 to close), r.delivered)
    }

    @Test fun aFailedPostLeavesTheDeliveryUsable() {
        var fail = true
        val got = ArrayList<FilesNet>()
        val d = FilesNetDelivery({ if (fail) throw IllegalStateException("gone") else it.run() }) { _, m -> got += m }
        try { d.offer(1, open); org.junit.Assert.fail() } catch (e: IllegalStateException) { }
        fail = false
        d.offer(1, close)
        assertEquals(listOf(close), got)
    }
}
