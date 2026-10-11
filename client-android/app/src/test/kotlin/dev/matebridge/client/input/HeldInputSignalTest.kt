package dev.matebridge.client.input

import dev.matebridge.client.protocol.ReleaseAll
import dev.matebridge.client.session.RemoteTimings
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * T-339 (decision 0038 section 6): the held-input signal that keeps a remote session's PING at 500 ms. A key, a pen in
 * range or an open touch must read as held until its release went out; AGENTS.md: a thinned PING may never leave an input
 * stuck on the host.
 */
class HeldInputSignalTest {
    private val sink = FakeSink()
    private val cap = InputCapture(sink, { VP })

    init {
        sink.nowMs = 0
        cap.setActive(true, 0)
        cap.setStreamGeometry(1400, 920)
    }

    private fun key(scan: Int, down: Boolean, t: Long) {
        sink.nowMs = t
        cap.onKey(KeyFrame(7, scan, 29, down, 0, false, false, false, t * 1000))
    }

    @Test fun nothingHeldAtStart() {
        assertFalse(cap.holdsInput)
        assertEquals(0L, cap.lastInputUs)
    }

    @Test fun aHeldKeyReadsAsHeldUntilItsUp() {
        key(30, true, 100)
        assertTrue(cap.holdsInput)
        assertTrue(cap.lastInputUs > 0)
        cap.tick(5_000) // a long hold: the tick keeps the flag
        assertTrue(cap.holdsInput)
        key(30, false, 5_100)
        assertFalse(cap.holdsInput)
    }

    @Test fun aPenInRangeAndInContactReadsAsHeld() {
        sink.nowMs = 10
        cap.onPen(penFrame(PenAction.HOVER_ENTER, pt(10), device = PEN_DEVICE), 10)
        assertTrue(cap.holdsInput)
        sink.nowMs = 20
        cap.onPen(penFrame(PenAction.DOWN, pt(20), device = PEN_DEVICE), 20)
        assertTrue(cap.holdsInput)
        cap.tick(3_000)
        assertTrue(cap.holdsInput)
        sink.nowMs = 3_010
        cap.onPen(penFrame(PenAction.UP, pt(3_010), device = PEN_DEVICE), 3_010)
        cap.onPen(penFrame(PenAction.HOVER_EXIT, pt(3_020), device = PEN_DEVICE), 3_020)
        cap.tick(3_100)
        assertFalse(cap.holdsInput)
    }

    @Test fun anOpenTouchReadsAsHeldAndReleaseAllClearsIt() {
        sink.nowMs = 10
        cap.onTouch(touchFrame(TouchAction.DOWN, 10, 0, finger(0, 1000f, 900f), device = TOUCH_DEVICE), 10)
        cap.tick(40)
        assertTrue(cap.holdsInput)
        cap.releaseAll(ReleaseAll.USER, 50)
        assertFalse(cap.holdsInput)
    }

    /** The PING gate, end to end: held input is never idle, whatever the clock says. */
    @Test fun heldInputKeepsTheFastPingEvenLongAfterTheLastEvent() {
        key(30, true, 100)
        cap.tick(60_000)
        val lastUs = cap.lastInputUs
        val longAfterUs = lastUs + 60_000_000L
        assertTrue(RemoteTimings.inputActive(cap.holdsInput, lastUs, longAfterUs))
        assertEquals(RemoteTimings.PING_FAST_US, RemoteTimings.pingIntervalUs(RemoteTimings.inputActive(cap.holdsInput, lastUs, longAfterUs)))
        key(30, false, 60_100)
        assertFalse(RemoteTimings.inputActive(cap.holdsInput, lastUs, longAfterUs))
    }
}
