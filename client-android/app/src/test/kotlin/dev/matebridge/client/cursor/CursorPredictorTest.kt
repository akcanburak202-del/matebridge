package dev.matebridge.client.cursor

import dev.matebridge.client.protocol.CursorState
import dev.matebridge.client.protocol.Pen
import dev.matebridge.client.protocol.PenSample
import dev.matebridge.client.protocol.PointerAbs
import dev.matebridge.client.protocol.PointerRel
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * T-278: the stream is 1000 x 500 pt here, so one point is 65.535 normalized units. The host clock is the client clock plus
 * [OFFSET]; the one-way delay is 5 ms. Times are client-clock microseconds.
 */
class CursorPredictorTest {
    private companion object {
        const val W = 1000
        const val H = 500
        const val OFFSET = 7_000_000L
        const val OW = 5_000L
    }

    private class Rig(offset: Long? = OFFSET, oneWay: Long? = OW, predict: Boolean = true) {
        val stats = CursorStats()
        val p = CursorPredictor({ h -> offset?.let { h - it } }, { oneWay }, stats)
        val out = CursorPredictor.Result()
        var seq = 0L

        init {
            p.setStream(W, H)
            p.setAllowed(predict)
            p.setLayerOn(true)
        }

        fun nx(xPt: Float) = (xPt / W * 65535f).toInt()
        fun ny(yPt: Float) = (yPt / H * 65535f).toInt()

        /** A state at ([xPt], [yPt]) that the host sampled at client time [sampleUs] and that arrived at [rxUs]. */
        fun state(xPt: Float, yPt: Float, sampleUs: Long, rxUs: Long, visible: Boolean = true): Long {
            seq++
            p.onState(CursorState(seq, nx(xPt), ny(yPt), visible, 1, sampleUs + OFFSET), rxUs)
            return seq
        }

        fun rel(dx: Float, dy: Float, atUs: Long) = p.onSent(PointerRel(atUs, dx, dy, 0), atUs)

        /** The predicted x, y in points, or null when there is no prediction. */
        fun at(seq: Long, nowUs: Long): Pair<Float, Float>? {
            if (!p.advance(seq, nowUs, out)) return null
            return out.xNorm / 65535f * W to out.yNorm / 65535f * H
        }
    }

    private fun assertPt(expected: Float, actual: Float?) {
        assertTrue("expected $expected, got $actual", actual != null && Math.abs(actual - expected) < 0.1f)
    }

    @Test fun deltasTheHostHasNotSeenYetAreAddedToTheLastState() {
        val r = Rig()
        r.state(500f, 250f, sampleUs = 50_000, rxUs = 55_000)
        r.rel(10f, 0f, 90_000) // arrives 95_000: already inside the next state
        r.rel(3f, -1f, 98_000) // arrives 103_000: after the sample
        r.rel(2f, 0f, 101_000)
        val s = r.state(510f, 250f, sampleUs = 100_000, rxUs = 105_000)
        val pos = r.at(s, 102_000)!!
        assertPt(515f, pos.first)
        assertPt(249f, pos.second)
    }

    @Test fun anEventIsNotCountedBeforeItWasSent() {
        val r = Rig()
        val s = r.state(500f, 250f, sampleUs = 50_000, rxUs = 55_000)
        r.rel(4f, 0f, 60_000)
        r.rel(4f, 0f, 70_000)
        assertPt(504f, r.at(s, 65_000)?.first)
        assertPt(508f, r.at(s, 75_000)?.first)
    }

    @Test fun relativeMotionIsClampedToTheScreenAtEveryStep() {
        val r = Rig()
        val s = r.state(995f, 2f, sampleUs = 50_000, rxUs = 55_000)
        r.rel(10f, -5f, 60_000) // against the right and top edge
        r.rel(-3f, 1f, 61_000)
        val pos = r.at(s, 62_000)!!
        assertPt(997f, pos.first) // 1000 - 3, not 995 + 10 - 3
        assertPt(1f, pos.second) // 0 + 1
    }

    @Test fun anAbsolutePointReplacesThePositionAndLaterDeltasAddToIt() {
        val r = Rig()
        val s = r.state(100f, 100f, sampleUs = 50_000, rxUs = 55_000)
        val touch = PointerAbs(60_000, r.nx(400f), r.ny(200f), 0, PointerAbs.SOURCE_TOUCH)
        assertTrue(r.p.onSent(touch, 60_000))
        assertPt(400f, r.at(s, 61_000)?.first)
        r.rel(5f, 5f, 62_000)
        val pos = r.at(s, 63_000)!!
        assertPt(405f, pos.first)
        assertPt(205f, pos.second)
    }

    @Test fun aPenSampleInRangeIsAnAbsolutePointAndTheLastOneWins() {
        val r = Rig()
        val s = r.state(100f, 100f, sampleUs = 50_000, rxUs = 55_000)
        fun sample(x: Float, y: Float, flags: Int) = PenSample(0, r.nx(x), r.ny(y), 0, 0, 0, flags)
        val pen = Pen(Pen.TOOL_PEN, 60_000, listOf(sample(300f, 300f, PenSample.IN_RANGE), sample(320f, 310f, PenSample.IN_RANGE or PenSample.CONTACT)))
        assertTrue(r.p.onSent(pen, 60_000))
        val pos = r.at(s, 61_000)!!
        assertPt(320f, pos.first)
        assertPt(310f, pos.second)
        // A pen out of range (flags 0) is not a position.
        val gone = Pen(Pen.TOOL_PEN, 62_000, listOf(sample(10f, 10f, 0)))
        assertFalse(r.p.onSent(gone, 62_000))
    }

    @Test fun aMessageThatDoesNotMoveTheCursorIsNotRecorded() {
        val r = Rig()
        r.state(100f, 100f, sampleUs = 50_000, rxUs = 55_000)
        assertFalse(r.p.onSent(PointerRel(60_000, 0f, 0f, 1), 60_000)) // a button change only
    }

    @Test fun whenTheHostStopsThePredictionSettlesOnItsPositionWithinTheSettleTime() {
        val r = Rig()
        val s = r.state(500f, 250f, sampleUs = 50_000, rxUs = 55_000)
        r.rel(20f, 0f, 60_000) // the host never reports it (clamped there, or ignored)
        assertPt(520f, r.at(s, 100_000)?.first)
        assertPt(500f, r.at(s, 60_000 + CursorPredictor.SETTLE_US + 1_000)?.first)
    }

    @Test fun aSmallDisagreementIsEasedInAndThenGone() {
        val r = Rig()
        val s1 = r.state(500f, 250f, sampleUs = 50_000, rxUs = 55_000)
        r.rel(10f, 0f, 60_000)
        assertPt(510f, r.at(s1, 62_000)?.first)
        // The state that contains the delta says 512 (the host moved 2 pt more than guessed).
        val s2 = r.state(512f, 250f, sampleUs = 70_000, rxUs = 75_000)
        assertPt(510f, r.at(s2, 80_000)?.first) // what was on screen stays: no visible step
        val later = r.at(s2, 90_000)!!.first // 10 ms later: most of the 2 pt has eased in
        assertTrue("eased: $later", later > 510.9f && later < 511.9f)
        assertPt(512f, r.at(s2, 200_000)?.first)
        assertFalse(r.out.animating)
    }

    @Test fun aLargeDisagreementJumpsAtOnce() {
        val r = Rig()
        val s1 = r.state(500f, 250f, sampleUs = 50_000, rxUs = 55_000)
        assertPt(500f, r.at(s1, 56_000)?.first)
        val s2 = r.state(700f, 100f, sampleUs = 70_000, rxUs = 75_000) // an app warped the cursor
        val pos = r.at(s2, 76_000)!!
        assertPt(700f, pos.first)
        assertPt(100f, pos.second)
    }

    @Test fun anAnimationIsRequestedOnlyWhileSomethingStillMoves() {
        val r = Rig()
        val s = r.state(500f, 250f, sampleUs = 50_000, rxUs = 55_000)
        r.at(s, 56_000)
        assertFalse(r.out.animating) // nothing sent, nothing to ease
        r.rel(5f, 0f, 60_000)
        r.at(s, 61_000)
        assertTrue(r.out.animating) // sent, not in a state yet
        r.at(s, 60_000 + CursorPredictor.SETTLE_US + 5_000)
        assertFalse(r.out.animating) // settled
    }

    @Test fun noPredictionWhenHiddenSwitchedOffOrTheLayerIsOff() {
        val hidden = Rig()
        val s = hidden.state(500f, 250f, sampleUs = 50_000, rxUs = 55_000, visible = false)
        assertEquals(null, hidden.at(s, 56_000))

        val off = Rig(predict = false)
        assertFalse(off.p.active)
        off.state(500f, 250f, sampleUs = 50_000, rxUs = 55_000)
        assertFalse(off.rel(5f, 5f, 60_000))
        assertEquals(null, off.at(off.seq, 61_000))

        val layerOff = Rig()
        val s2 = layerOff.state(500f, 250f, sampleUs = 50_000, rxUs = 55_000)
        layerOff.p.setLayerOn(false)
        assertFalse(layerOff.rel(5f, 5f, 60_000))
        assertEquals(null, layerOff.at(s2, 61_000))
    }

    @Test fun anOldStateSeqIsNotPredicted() {
        val r = Rig()
        val s1 = r.state(500f, 250f, sampleUs = 50_000, rxUs = 55_000)
        r.state(510f, 250f, sampleUs = 60_000, rxUs = 65_000)
        assertEquals(null, r.at(s1, 66_000)) // the layer draws the newest state; an older frame gets the plain v1 position
    }

    @Test fun inputBeforeAnyStateAndAfterAResetIsNotKept() {
        val r = Rig()
        assertFalse(r.rel(5f, 5f, 40_000)) // nothing is drawn yet
        val s = r.state(500f, 250f, sampleUs = 50_000, rxUs = 55_000)
        r.rel(5f, 0f, 60_000)
        r.p.reset()
        assertEquals(null, r.at(s, 61_000))
    }

    @Test fun theRingKeepsTheNewestEventsOnly() {
        val r = Rig()
        val s = r.state(100f, 250f, sampleUs = 50_000, rxUs = 55_000)
        repeat(2_000) { r.rel(0.1f, 0f, 60_000L + it) } // 1.9 ms: all inside the settle time
        val pos = r.at(s, 62_000)!!.first
        assertPt(100f + CursorPredictor.CAP * 0.1f, pos) // only the newest CAP survive
    }

    @Test fun anUnknownClockOffsetFallsBackToArrivalMinusTheOneWayDelay() {
        val r = Rig(offset = null)
        r.state(500f, 250f, sampleUs = 0, rxUs = 55_000) // the host stamp means nothing without an offset
        r.rel(10f, 0f, 40_000) // arrives 45_000 <= 50_000 (= rx - one way): inside the next state
        r.rel(3f, 0f, 48_000) // arrives 53_000 > 50_000: still ahead of the state
        val s2 = r.state(510f, 250f, sampleUs = 0, rxUs = 55_000)
        assertPt(513f, r.at(s2, 56_000)?.first)
    }

    @Test fun aHostStampMappedAfterTheArrivalIsHeldBackByTheOneWayDelay() {
        val r = Rig()
        r.state(500f, 250f, sampleUs = 10_000, rxUs = 12_000)
        r.rel(3f, 0f, 48_000) // arrives 53_000
        // The offset is rough: the stamp maps to 70_000, after the arrival at 55_000. A state cannot be younger than rx - one way.
        val s = r.state(510f, 250f, sampleUs = 70_000, rxUs = 55_000)
        assertPt(513f, r.at(s, 56_000)?.first) // 53_000 > 50_000 (rx - one way): not in the state yet
    }

    @Test fun theForecastErrorAndTheHoldErrorAreMeasuredAtEachState() {
        val r = Rig()
        r.state(500f, 250f, sampleUs = 50_000, rxUs = 55_000)
        r.rel(10f, 0f, 90_000)
        r.state(510f, 250f, sampleUs = 100_000, rxUs = 105_000) // the forecast was exact
        r.rel(10f, 0f, 140_000)
        r.state(530f, 250f, sampleUs = 150_000, rxUs = 155_000) // the host moved 10 pt more than the delta says
        r.rel(10f, 0f, 190_000)
        r.state(540f, 250f, sampleUs = 200_000, rxUs = 205_000) // exact again
        val s = r.stats.take()
        assertEquals(3, s.predN)
        assertEquals(0f, s.predErrP50Pt, 0.1f)
        assertEquals(10f, s.predErrP95Pt, 0.1f)
        assertEquals(10f, s.holdErrP50Pt, 0.1f)
        assertEquals(20f, s.holdErrP95Pt, 0.1f)
    }

    @Test fun aStateThatChangesNothingIsNotAMeasurement() {
        val r = Rig()
        r.state(500f, 250f, sampleUs = 50_000, rxUs = 55_000)
        r.state(500f, 250f, sampleUs = 600_000, rxUs = 605_000) // the 500 ms keepalive
        assertEquals(0, r.stats.take().predN)
    }
}
