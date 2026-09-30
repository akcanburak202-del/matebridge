package dev.matebridge.client.input

import dev.matebridge.client.protocol.Pen
import dev.matebridge.client.protocol.PenSample
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * T-026: exact-duplicate filter and the duplicate / batch counters of [PenTracker]. The filter only ever drops a real
 * Android sample that is bit-identical (time, position, pressure, tilt, flags) to the last sample that was SENT; it
 * must never touch a state change (flags differ, STROKE_START, flags = 0) or a liveness repeat.
 */
class PenDedupeTest {
    private val IR = PenSample.IN_RANGE
    private val CT = PenSample.CONTACT
    private val SS = PenSample.STROKE_START

    private val counters = InputCounters()
    private val t = PenTracker({ VP }, counters)

    private fun sent(out: List<Outgoing>) = penSamples(out.messages())
    private fun xs(out: List<Outgoing>) = sent(out).map { it.x }
    private fun nx(x: Float) = VP.normX(x)

    // ---- what is dropped ----

    @Test fun anIdenticalSampleIsNotSentTwiceAndCountsAsDupExact() {
        assertEquals(1, sent(t.onFrame(penFrame(PenAction.HOVER_MOVE, pt(10, x = 300f)), 10)).size)
        val again = t.onFrame(penFrame(PenAction.HOVER_MOVE, pt(10, x = 300f)), 11)
        assertTrue(again.isEmpty())
        assertEquals(1, counters.dupExact)
        assertEquals(0, counters.dupPos)
    }

    @Test fun identicalContactSamplesInsideOneEventAreDroppedAndTheRestKeepsItsOrder() {
        t.downConfirmed(penFrame(PenAction.DOWN, pt(0, x = 100f)), 0)
        val out = t.onFrame(
            penFrame(PenAction.MOVE, pt(3, x = 110f), pt(3, x = 110f), pt(6, x = 120f), pt(6, x = 120f), pt(9, x = 130f)), 9,
        )
        assertEquals(1, out.size)
        assertEquals(listOf(nx(110f), nx(120f), nx(130f)), xs(out))
        assertEquals(listOf(0L, 3000L, 6000L), (out[0].msg as Pen).samples.map { it.dtUs })
        assertEquals(2, counters.dupExact)
    }

    @Test fun theReferenceIsTheLastSentSampleNotAnyEarlierOne() {
        t.onFrame(penFrame(PenAction.HOVER_MOVE, pt(10, x = 300f)), 10)
        t.onFrame(penFrame(PenAction.HOVER_MOVE, pt(13, x = 310f)), 13)
        // Looks like the FIRST sample sent, but it is not identical to the last one sent (and its time is clamped
        // forward to 13 ms anyway): goes out.
        val out = t.onFrame(penFrame(PenAction.HOVER_MOVE, pt(10, x = 300f)), 14)
        assertEquals(listOf(nx(300f)), xs(out))
        assertEquals(0, counters.dupExact)
    }

    @Test fun aChangeInPressureOrTiltAloneIsNotADuplicate() {
        t.downConfirmed(penFrame(PenAction.DOWN, pt(0, x = 100f, pressure = 0.5f, tilt = 0.3f)), 0)
        t.onFrame(penFrame(PenAction.MOVE, pt(3, x = 110f, pressure = 0.5f, tilt = 0.3f)), 3)
        assertEquals(1, sent(t.onFrame(penFrame(PenAction.MOVE, pt(3, x = 110f, pressure = 0.7f, tilt = 0.3f)), 4)).size)
        assertEquals(1, sent(t.onFrame(penFrame(PenAction.MOVE, pt(3, x = 110f, pressure = 0.7f, tilt = 0.4f)), 5)).size)
        assertEquals(0, counters.dupExact)
    }

    @Test fun anExactDuplicateAfterResetIsSentBecauseNothingWasSentInThisSession() {
        t.onFrame(penFrame(PenAction.HOVER_MOVE, pt(10, x = 300f)), 10)
        t.reset()
        assertEquals(1, sent(t.onFrame(penFrame(PenAction.HOVER_MOVE, pt(10, x = 300f)), 11)).size)
        assertEquals(0, counters.dupExact)
    }

    @Test fun anEventWhoseSamplesAreAllDuplicatesSendsNothingAndDoesNotFeedTheLivenessClock() {
        t.onFrame(penFrame(PenAction.HOVER_MOVE, pt(10, x = 300f)), 10)
        assertTrue(t.onFrame(penFrame(PenAction.HOVER_MOVE, pt(10, x = 300f)), 90).isEmpty())
        // The repeat still comes 100 ms after the last message that was really sent.
        assertEquals(1, t.tick(110).size)
    }

    // ---- what is never dropped ----

    @Test fun aSampleWithDifferentFlagsIsNeverADuplicateEvenIfEverythingElseMatches() {
        // Same time, position and tilt throughout (pressure is 0 while the pen is not in contact).
        val hover = t.onFrame(penFrame(PenAction.HOVER_MOVE, pt(10, x = 300f, pressure = 0f)), 10)
        assertEquals(listOf(IR), sent(hover).map { it.flags })
        val down = t.downConfirmed(penFrame(PenAction.DOWN, pt(10, x = 300f, pressure = 0f)), 11)
        assertEquals(listOf(IR or CT or SS), sent(down).map { it.flags })
        // Same again but without STROKE_START: the flags differ from the STROKE_START sample.
        val move = t.onFrame(penFrame(PenAction.MOVE, pt(10, x = 300f, pressure = 0f)), 12)
        assertEquals(listOf(IR or CT), sent(move).map { it.flags })
        // Contact ends at the very same place and time: IN_RANGE only, differs from contact.
        val up = t.onFrame(penFrame(PenAction.UP, pt(10, x = 300f, pressure = 0f)), 13)
        assertEquals(listOf(IR), sent(up).map { it.flags })
        assertEquals(0, counters.dupExact)
    }

    @Test fun everyStrokeStartIsSentEvenWhenARepeatedDownLooksIdentical() {
        val first = t.downConfirmed(penFrame(PenAction.DOWN, pt(0, x = 100f)), 0)
        assertEquals(listOf(IR or CT or SS), sent(first).map { it.flags })
        // A second DOWN without an UP (lost release): the old contact is ended, then the new stroke starts.
        val second = t.downConfirmed(penFrame(PenAction.DOWN, pt(0, x = 100f)), 1)
        assertEquals(listOf(IR, IR or CT or SS), sent(second).map { it.flags })
        assertEquals(0, counters.dupExact)
    }

    @Test fun flagsZeroSamplesAreNeverDropped() {
        t.downConfirmed(penFrame(PenAction.DOWN, pt(0, x = 100f)), 0)
        val c1 = t.onFrame(penFrame(PenAction.CANCEL, pt(0, x = 100f)), 1)
        val c2 = t.onFrame(penFrame(PenAction.CANCEL, pt(0, x = 100f)), 2) // nothing in range, same time, same place
        assertEquals(listOf(0), sent(c1).map { it.flags })
        assertEquals(listOf(0), sent(c2).map { it.flags })
        assertFalse(c1[0].mergeable)
        assertEquals(0, counters.dupExact)
    }

    @Test fun aLivenessRepeatIsSentEvenWhenItIsWireIdenticalToTheLastSample() {
        // The event is stamped 100 ms ahead of "now", so the repeat 100 ms later carries the very same time.
        val real = t.onFrame(penFrame(PenAction.HOVER_MOVE, pt(1100, x = 300f)), 1000)
        val rep = t.tick(1100)
        assertEquals(1, rep.size)
        assertEquals(sent(real)[0], sent(rep)[0])
        assertEquals(0, counters.dupExact)
        assertEquals(0, counters.dupPos) // synthetic samples are not counted either
    }

    @Test fun closingSamplesAreNotFiltered() {
        t.onFrame(penFrame(PenAction.HOVER_MOVE, pt(10, x = 300f)), 10)
        val rel = t.release(20)
        assertEquals(listOf(0), sent(rel).map { it.flags })
        assertEquals(0, counters.dupExact)
    }

    // ---- counters ----

    @Test fun samePositionWithADifferentTimeIsSentAndCountedAsDupPos() {
        t.downConfirmed(penFrame(PenAction.DOWN, pt(0, x = 100f)), 0)
        // The first sample repeats the previous event's last position (crosses the event boundary), then it moves,
        // then the current sample repeats the last historical one (inside the event).
        val out = t.onFrame(penFrame(PenAction.MOVE, pt(3, x = 100f), pt(6, x = 120f), pt(9, x = 120f)), 9)
        assertEquals(listOf(nx(100f), nx(120f), nx(120f)), xs(out))
        assertEquals(0, counters.dupExact)
        assertEquals(2, counters.dupPos)
        assertEquals(1, counters.dupPosFirst)
    }

    @Test fun aSingleSampleEventRepeatingThePreviousPositionCountsAsCrossingTheEventBoundary() {
        t.downConfirmed(penFrame(PenAction.DOWN, pt(0, x = 100f)), 0)
        t.onFrame(penFrame(PenAction.MOVE, pt(3, x = 110f)), 3)
        t.onFrame(penFrame(PenAction.MOVE, pt(6, x = 110f)), 6)
        assertEquals(1, counters.dupPos)
        assertEquals(1, counters.dupPosFirst)
    }

    @Test fun maxBatchIsTheLargestPenMessageOfTheInterval() {
        t.downConfirmed(penFrame(PenAction.DOWN, pt(0, x = 100f)), 0)
        assertEquals(1, counters.maxBatch)
        t.onFrame(penFrame(PenAction.MOVE, pt(3, x = 101f), pt(6, x = 102f), pt(9, x = 103f), pt(12, x = 104f)), 12)
        t.onFrame(penFrame(PenAction.MOVE, pt(15, x = 105f), pt(18, x = 106f)), 18)
        assertEquals(4, counters.maxBatch)
        assertTrue(counters.fields(1000).contains("max_batch=4"))
        counters.reset()
        assertEquals(0, counters.maxBatch)
        assertTrue(counters.fields(1000).endsWith("dup_exact=0 dup_pos=0 dup_pos_first=0 max_batch=0 bounce_dropped=0"))
    }

    @Test fun maxBatchCountsTheSentSamplesAfterSplittingAt64() {
        t.downConfirmed(penFrame(PenAction.DOWN, pt(0, x = 100f)), 0)
        val pts = Array(130) { pt(10L + it, x = 200f + it) }
        t.onFrame(penFrame(PenAction.MOVE, *pts), 200)
        assertEquals(64, counters.maxBatch)
    }

    @Test fun oneSampleEventsBecomeOneMessageEachWithNoBatching() {
        t.downConfirmed(penFrame(PenAction.DOWN, pt(0, x = 100f)), 0)
        var msgs = 0
        for (i in 1..30) msgs += t.onFrame(penFrame(PenAction.MOVE, pt(3L * i, x = 100f + i)), 3L * i).size
        assertEquals(30, msgs)
        assertEquals(1, counters.maxBatch)
    }

    @Test fun aBatchedEventStillTravelsAsOneMessageInOrderWithNothingDropped() {
        t.downConfirmed(penFrame(PenAction.DOWN, pt(0, x = 100f)), 0)
        val out = t.onFrame(penFrame(PenAction.MOVE, pt(3, x = 101f), pt(6, x = 102f), pt(9, x = 103f), pt(12, x = 104f)), 12)
        assertEquals(1, out.size)
        assertEquals(listOf(nx(101f), nx(102f), nx(103f), nx(104f)), xs(out))
        assertEquals(0, counters.dupExact)
    }
}
