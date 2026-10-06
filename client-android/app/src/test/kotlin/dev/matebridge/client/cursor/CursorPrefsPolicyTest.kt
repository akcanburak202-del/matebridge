package dev.matebridge.client.cursor

import dev.matebridge.client.stream.StreamMode
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class CursorPrefsPolicyTest {
    private fun on() = CursorPrefsPolicy().also { it.setWish(true, 0) }

    @Test fun wishFollowsTheModeAndTheSetting() {
        assertTrue(CursorPrefsPolicy.wishOf(StreamMode.DAILY, true))
        assertTrue(CursorPrefsPolicy.wishOf(StreamMode.DRAWING, true))
        assertFalse(CursorPrefsPolicy.wishOf(StreamMode.GAME, true)) // Oyun: always in the video
        assertFalse(CursorPrefsPolicy.wishOf(StreamMode.DAILY, false)) // "Görüntüde"
        assertFalse(CursorPrefsPolicy.wishOf(StreamMode.DRAWING, false))
    }

    @Test fun beforeASessionTheWireJustFollowsTheWish() {
        val p = CursorPrefsPolicy()
        assertFalse(p.wire)
        assertEquals(true, p.setWish(true, 0))
        assertNull(p.setWish(true, 0)) // nothing changed
        assertEquals(false, p.setWish(false, 0))
        assertFalse(p.layerOn)
        assertNull(p.tick(10_000, 0)) // not connected: no timeout
    }

    @Test fun theLayerIsOnOnlyInAnAcceptedSessionWithTheWireOn() {
        val p = on()
        assertFalse(p.layerOn)
        assertNull(p.onSession(true, 100))
        assertTrue(p.layerOn)
        assertNull(p.setWish(true, 100))
        p.setWish(false, 200)
        assertFalse(p.layerOn) // Oyun or "Görüntüde": hidden at once
    }

    @Test fun noStateFor1500MsAfterTheRequestFallsBack() {
        val p = on()
        p.onSession(true, 1_000)
        assertNull(p.tick(2_499, 0))
        val t = p.tick(2_500, 0)!!
        assertEquals(CursorPrefsPolicy.Tick(wire = false, fallback = true), t)
        assertFalse(p.wire)
        assertFalse(p.layerOn)
        assertNull(p.tick(3_000, 0)) // reported once
    }

    @Test fun statesKeepItAliveAndTheyMustNotStopFor1500Ms() {
        val p = on()
        p.onSession(true, 1_000)
        assertNull(p.tick(1_400, 1_300)) // first state arrived
        assertNull(p.tick(2_700, 1_300)) // 1 400 ms since the last one
        assertNull(p.tick(2_795, 1_300)) // just under
        assertEquals(true, p.tick(2_800, 1_300)!!.fallback) // 1 500 ms of silence after states
        assertEquals(1, p.fallbackCount)
    }

    @Test fun aStateOlderThanTheRequestDoesNotCount() {
        val p = on()
        p.onSession(true, 1_000)
        assertEquals(true, p.tick(2_500, 400)!!.fallback) // 400 was before this request
    }

    @Test fun retryWaitsAtLeastTenSecondsThenBacksOffUntilAStateIsSeen() {
        val p = on()
        p.onSession(true, 0)
        assertEquals(true, p.tick(1_500, 0)!!.fallback) // fallback at 1 500
        assertEquals(10_000L, p.retryDelayMs)
        assertNull(p.tick(11_499, 0))
        assertEquals(CursorPrefsPolicy.Tick(true, false), p.tick(11_500, 0)) // retry: the host is asked again
        assertTrue(p.layerOn)
        assertEquals(true, p.tick(13_000, 0)!!.fallback) // again nothing: second fallback
        assertEquals(20_000L, p.retryDelayMs)
        assertNull(p.tick(32_999, 0))
        assertEquals(true, p.tick(33_000, 0)!!.wire) // retried after 20 s
        assertEquals(true, p.tick(34_500, 0)!!.fallback)
        assertEquals(40_000L, p.retryDelayMs)
        p.tick(74_500, 0)
        assertEquals(true, p.tick(76_000, 0)!!.fallback)
        assertEquals(60_000L, p.retryDelayMs) // capped
        p.tick(136_000, 0)
        assertEquals(true, p.tick(137_500, 0)!!.fallback)
        assertEquals(60_000L, p.retryDelayMs)
    }

    @Test fun aSuccessfulRetryResetsTheBackoff() {
        val p = on()
        p.onSession(true, 0)
        p.tick(1_500, 0) // fallback 1
        p.tick(11_500, 0) // retry
        p.tick(13_000, 0) // fallback 2
        assertEquals(20_000L, p.retryDelayMs)
        p.tick(33_000, 0) // retry
        assertNull(p.tick(33_600, 33_550)) // the host answers
        assertEquals(0, p.fallbackCount)
        assertEquals(true, p.tick(35_100, 33_550)!!.fallback)
        assertEquals(10_000L, p.retryDelayMs)
    }

    @Test fun aChangeOfTheWishIsAppliedAtOnceNotAfterTheRetryDelay() {
        val p = on()
        p.onSession(true, 0)
        p.tick(1_500, 0) // fallen back
        assertNull(p.setWish(true, 2_000)) // wish unchanged: the retry delay applies
        assertNull(p.setWish(false, 2_100)) // the user chose "Görüntüde": the host already shows the video cursor
        assertEquals(true, p.setWish(true, 2_200)) // and back: asked again at once
        assertTrue(p.layerOn)
        assertEquals(true, p.tick(3_700, 0)!!.fallback) // the timeout starts from that request
    }

    @Test fun afterAFallbackNothingIsRetriedWhenTheWishIsOff() {
        val p = on()
        p.onSession(true, 0)
        p.tick(1_500, 0)
        p.setWish(false, 2_000)
        assertNull(p.tick(100_000, 0))
        assertFalse(p.wire)
    }

    @Test fun aSessionThatEndsAfterAFallbackStartsTheNextOneWithTheWish() {
        val p = on()
        p.onSession(true, 0)
        p.tick(1_500, 0)
        assertFalse(p.wire)
        assertEquals(true, p.onSession(false, 5_000)) // the machine remembers the wish for the next session
        assertTrue(p.wire)
        assertFalse(p.layerOn)
        assertNull(p.onSession(true, 6_000)) // the machine sent PREFS(1) on accept
        assertTrue(p.layerOn)
        assertEquals(0, p.fallbackCount)
        assertNull(p.tick(7_400, 0))
        assertEquals(true, p.tick(7_500, 0)!!.fallback) // the 1.5 s clock runs from the accept
    }

    @Test fun aMigrationSwitchRestartsTheClockOfALiveRequest() {
        val p = on()
        p.onSession(true, 0)
        assertNull(p.tick(1_000, 900))
        p.onNewConnection(2_000) // new connection: the host sends nothing until it applied PREFS again
        assertNull(p.tick(3_400, 900))
        assertEquals(true, p.tick(3_500, 900)!!.fallback)
    }

    @Test fun aMigrationSwitchDoesNotTouchAFallenBackWire() {
        val p = on()
        p.onSession(true, 0)
        p.tick(1_500, 0)
        p.onNewConnection(2_000)
        assertFalse(p.wire)
        assertNull(p.tick(3_000, 0))
    }

    @Test fun nothingHappensWithoutASession() {
        val p = on()
        assertNull(p.tick(1_000_000, 0))
        assertTrue(p.wire)
    }
}
