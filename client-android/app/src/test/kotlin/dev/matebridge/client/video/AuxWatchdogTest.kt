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
}
