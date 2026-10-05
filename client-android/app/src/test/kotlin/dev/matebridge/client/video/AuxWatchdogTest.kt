package dev.matebridge.client.video

import dev.matebridge.client.session.KeyValueStore
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class AuxWatchdogTest {
    private val s = 1_000_000_000L

    @Test fun idleStreamIsNeverStalled() {
        val w = AuxWatchdog(2 * s)
        w.reset(0)
        assertFalse(w.stalled(100 * s, waiting = false))
        // a frame appearing after a long idle time is not "waiting for 100 s"
        assertFalse(w.stalled(100 * s + 1, waiting = true))
    }

    @Test fun framesWaitingForAnInputBufferTooLongStall() {
        val w = AuxWatchdog(2 * s)
        w.reset(0)
        assertFalse(w.stalled(10 * s, waiting = true))
        assertFalse(w.stalled(11 * s, waiting = true))
        assertTrue(w.stalled(13 * s, waiting = true))
    }

    @Test fun progressResetsTheWait() {
        val w = AuxWatchdog(2 * s)
        w.reset(0)
        w.stalled(1 * s, waiting = true)
        w.onInput(2 * s)
        assertFalse(w.stalled(4 * s - 1, waiting = true))
    }

    @Test fun inputsWithoutOutputsStallOnlyWhenTheyPileUp() {
        val w = AuxWatchdog(2 * s)
        w.reset(0)
        w.onInput(1); w.onInput(2)
        assertFalse(w.stalled(10 * s, waiting = false)) // one or two frames may sit in a decoder (idle screen)
        w.onInput(3)
        assertTrue(w.stalled(10 * s, waiting = false))
        w.onOutput(10 * s)
        assertFalse(w.stalled(10 * s + 1, waiting = false))
    }

    @Test fun selfTestIsSingleFlightAndReusesAStoredResult() {
        val kv = object : KeyValueStore {
            val m = HashMap<String, String>()
            override fun getString(key: String) = m[key]
            override fun putString(key: String, value: String) { m[key] = value }
        }
        val cap = FullChromaCapability(kv, "b")
        cap.recordPass()
        // already decided: no native call, no second run
        assertEquals(FullChromaSelfTest.Outcome.Pass, FullChromaSelfTest.runAndRecord(cap) {})
        cap.recordFail("x")
        assertEquals(FullChromaSelfTest.Outcome.Fail("x"), FullChromaSelfTest.runAndRecord(cap) {})
    }

    @Test fun outputBeforeTheInputCallReturnsLeavesNoPhantomInput() {
        // The input is registered before queueInputBuffer, so an output racing the call cannot be missed.
        val w = AuxWatchdog(2 * s)
        w.reset(0)
        repeat(5) { i ->
            w.onInput(i.toLong())   // registered first
            w.onOutput(i.toLong())  // the codec answers before queueInputBuffer returns
        }
        assertFalse(w.stalled(100 * s, waiting = false)) // idle desktop: nothing in flight
    }

    @Test fun aFailedQueueRollsTheInputBack() {
        val w = AuxWatchdog(2 * s)
        w.reset(0)
        repeat(3) { w.onInput(it.toLong()); w.onInputFailed() }
        assertFalse(w.stalled(100 * s, waiting = false))
        repeat(3) { w.onInput(it.toLong()) } // three real ones that never come back
        assertTrue(w.stalled(100 * s, waiting = false))
    }

    @Test fun watchdogsOfTwoCodecGenerationsAreIndependent() {
        val old = AuxWatchdog(2 * s).also { it.reset(0) }
        repeat(3) { old.onInput(it.toLong()) }
        val fresh = AuxWatchdog(2 * s).also { it.reset(50 * s) }
        assertTrue(old.stalled(60 * s, waiting = false))
        assertFalse(fresh.stalled(60 * s, waiting = false))
        fresh.onOutput(60 * s) // a late output of the OLD codec must not touch the new generation's counters
        assertEquals(false, fresh.stalled(61 * s, waiting = false))
    }

    @Test fun leakListReleasesOnlyWhenNoThreadIsAliveAndOnlyOnce() {
        val list = LeakList()
        var alive = true
        var released = 0
        list.add(object : Reapable {
            override fun alive() = alive
            override fun release() { released++ }
        })
        assertEquals(0, list.reap())
        assertFalse(list.isEmpty())
        alive = false
        assertEquals(1, list.reap())
        assertEquals(0, list.reap())
        assertEquals(1, released)
        assertTrue(list.isEmpty())
    }
}
