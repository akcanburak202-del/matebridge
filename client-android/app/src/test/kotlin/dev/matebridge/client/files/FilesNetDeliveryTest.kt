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
        var uiGen = 100
        val d = FilesNetDelivery({ queue.addLast(it) }, { uiGen }) { g, m -> delivered += g to m }
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
        d = FilesNetDelivery({ r.queue.addLast(it) }, { 100 }) { g, m ->
            r.delivered += g to m
            if (!rerun) { rerun = true; d.offer(g, close) }
        }
        d.offer(1, open)
        r.runAll()
        assertEquals(listOf(1 to open, 1 to close), r.delivered)
    }

    @Test fun aNewGenerationsOpenNeverRidesARunQueuedBeforeTheUiLearnedTheGeneration() {
        val r = Rig()
        r.uiGen = 4
        r.d.offer(4, open) // queued run R1
        // the engine posts the UI's own generation update (modelled as a queued task), then the new session's OPEN arrives
        r.queue.addLast(Runnable { r.uiGen = 5 })
        r.d.offer(5, open) // same slot, R1 still queued ahead of the update
        r.runAll()
        assertEquals(listOf(5 to open), r.delivered) // delivered once, after the update, not rejected by the gate
    }

    @Test fun aRunThatFindsANewerGenerationQueuesItselfBehindTheUpdateAndStaysBounded() {
        val r = Rig()
        r.uiGen = 4
        r.d.offer(5, open)
        repeat(5) { r.queue.removeFirst().run(); assertEquals(1, r.queue.size) } // waits, one run queued at all times
        assertTrue(r.delivered.isEmpty())
        r.uiGen = 5
        r.runAll()
        assertEquals(listOf(5 to open), r.delivered)
    }

    @Test fun aNewerOfferWhileWaitingReplacesTheWaitingMessage() {
        val r = Rig()
        r.uiGen = 4
        r.d.offer(5, open)
        r.queue.removeFirst().run() // waits for gen 5
        r.d.offer(5, close)
        r.uiGen = 5
        r.runAll()
        assertEquals(listOf(5 to close), r.delivered)
    }

    @Test fun anEjectCoalescedAwayIsStillDeliveredAsCloseBeforeTheNewerOpen() {
        val r = Rig()
        r.d.offer(3, open)
        r.runAll() // the gate has its OPEN
        r.delivered.clear()
        // the Mac ejects and reopens on the same port before the UI runs
        r.d.offer(3, close)
        r.d.offer(3, open)
        assertEquals(1, r.queue.size)
        r.runAll()
        assertEquals(listOf(3 to close, 3 to open), r.delivered) // stop (STANDBY), then a fresh start
    }

    @Test fun theTeardownFlagSurvivesRepeatsAndIsNotCarriedToAnotherGenerationOrADeliveredState() {
        val r = Rig()
        r.d.offer(3, close); r.d.offer(3, open); r.d.offer(3, open.copy(pool = 4)) // other sizes: still the same eject
        r.runAll()
        assertEquals(listOf(3 to close, 3 to open.copy(pool = 4)), r.delivered)
        r.delivered.clear()
        r.d.offer(3, open) // the CLOSE was delivered earlier: a plain OPEN now
        r.runAll()
        assertEquals(listOf(3 to open), r.delivered)
        r.delivered.clear()
        r.d.offer(3, close); r.d.offer(4, open) // a CLOSE of the old generation says nothing about generation 4
        r.runAll()
        assertEquals(listOf(4 to open), r.delivered)
    }

    @Test fun aCloseAloneIsDeliveredOnce() {
        val r = Rig()
        r.d.offer(3, open); r.d.offer(3, close); r.d.offer(3, close)
        r.runAll()
        assertEquals(listOf(3 to close), r.delivered)
    }

    @Test fun aFailedPostLeavesTheDeliveryUsable() {
        var fail = true
        val got = ArrayList<FilesNet>()
        val d = FilesNetDelivery({ if (fail) throw IllegalStateException("gone") else it.run() }, { 100 }) { _, m -> got += m }
        try { d.offer(1, open); org.junit.Assert.fail() } catch (e: IllegalStateException) { }
        fail = false
        d.offer(1, close)
        assertEquals(listOf(close), got)
    }
}
