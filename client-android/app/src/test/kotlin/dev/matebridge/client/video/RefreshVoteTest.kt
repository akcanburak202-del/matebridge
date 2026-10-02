package dev.matebridge.client.video

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class RefreshVoteTest {
    private var now = 0L
    private fun vote(min: Int = 70) = RefreshVote(min, { now })

    @Test fun turnsOnAtThreshold() {
        val v = vote()
        assertNull(v.update(true, 69.9))
        assertFalse(v.on)
        assertEquals(VoteChange(true, VoteReason.FPS), v.update(true, 70.0))
        assertTrue(v.on)
        assertNull(v.update(true, 90.0))
    }

    @Test fun hysteresisHoldsForOneSecond() {
        val v = vote()
        v.update(true, 100.0)
        now = 1000
        assertNull(v.update(true, 30.0))
        now = 1999
        assertNull(v.update(true, 30.0))
        now = 2000
        assertEquals(VoteChange(false, VoteReason.FPS), v.update(true, 30.0))
        assertFalse(v.on)
    }

    @Test fun recoveryResetsHysteresis() {
        val v = vote()
        v.update(true, 100.0)
        now = 1000
        v.update(true, 30.0)
        now = 1500
        assertNull(v.update(true, 100.0))
        now = 2400
        assertNull(v.update(true, 30.0)) // window restarts here
        now = 3300
        assertNull(v.update(true, 30.0))
        now = 3400
        assertEquals(VoteChange(false, VoteReason.FPS), v.update(true, 30.0))
    }

    @Test fun sessionEndTurnsOffAtOnce() {
        val v = vote()
        v.update(true, 100.0)
        assertEquals(VoteChange(false, VoteReason.SESSION), v.update(false, 100.0))
        assertNull(v.update(false, 100.0))
    }

    @Test fun backgroundStopIsImmediateAndIdempotent() {
        val v = vote()
        v.update(true, 100.0)
        assertEquals(VoteChange(false, VoteReason.BACKGROUND), v.stop(VoteReason.BACKGROUND))
        assertNull(v.stop(VoteReason.BACKGROUND))
        assertFalse(v.on)
    }

    @Test fun zeroMinFpsIsAlwaysOnWhileStreaming() {
        val v = vote(0)
        assertEquals(VoteChange(true, VoteReason.FPS), v.update(true, 0.0))
        now = 10_000
        assertNull(v.update(true, 0.0))
        assertTrue(v.on)
        assertEquals(VoteChange(false, VoteReason.SESSION), v.update(false, 0.0))
    }

    @Test fun staysOffBelowThresholdWithoutChange() {
        val v = vote()
        now = 5000
        assertNull(v.update(true, 10.0))
        assertNull(v.update(true, 10.0))
        assertFalse(v.on)
    }
}
