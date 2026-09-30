package dev.matebridge.client.input

import dev.matebridge.client.protocol.Coords
import dev.matebridge.client.protocol.Pen
import dev.matebridge.client.protocol.PenSample
import dev.matebridge.client.stream.VideoViewport
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class PenTrackerTest {
    private val IR = PenSample.IN_RANGE
    private val CT = PenSample.CONTACT
    private val SS = PenSample.STROKE_START

    private fun tracker(vp: VideoViewport = VP, counters: InputCounters = InputCounters()) = PenTracker({ vp }, counters)

    private fun flagsOf(out: List<Outgoing>) = penSamples(out.messages()).map { it.flags }

    @Test fun hoverThenStrokeThenLiftFollowsSection4() {
        val t = tracker()
        assertEquals(listOf(IR), flagsOf(t.onFrame(penFrame(PenAction.HOVER_ENTER, pt(0)), 0)))
        assertEquals(listOf(IR), flagsOf(t.onFrame(penFrame(PenAction.HOVER_MOVE, pt(3)), 3)))
        // HarmonyOS sends HOVER_EXIT right before DOWN; it is absorbed, so the pen stays in range.
        assertTrue(t.onFrame(penFrame(PenAction.HOVER_EXIT, pt(6)), 6).isEmpty())
        // T-029: the DOWN is held until the second sample; both go out together, STROKE_START first.
        assertTrue(t.onFrame(penFrame(PenAction.DOWN, pt(7)), 7).isEmpty())
        assertEquals(listOf(IR or CT or SS, IR or CT, IR or CT), flagsOf(t.onFrame(penFrame(PenAction.MOVE, pt(9), pt(12)), 12)))
        assertEquals(listOf(IR), flagsOf(t.onFrame(penFrame(PenAction.UP, pt(15, pressure = 0f)), 15)))
        assertEquals(PenTracker.State.HOVER, t.state)
    }

    @Test fun strokeStartOnlyOnTheActionDownSample() {
        val t = tracker()
        val all = listOf(
            t.onFrame(penFrame(PenAction.DOWN, pt(0)), 0),
            t.onFrame(penFrame(PenAction.MOVE, pt(3), pt(6), pt(9)), 9),
            t.onFrame(penFrame(PenAction.MOVE, pt(12)), 12),
        ).flatMap { flagsOf(it) }
        assertEquals(1, all.count { it and SS != 0 })
        assertEquals(SS, all.first() and SS)
        assertTrue(all.all { it and CT != 0 && it and IR != 0 })
    }

    @Test fun allHistoricalSamplesTravelInOneMessageWithNonDecreasingDt() {
        val t = tracker()
        t.onFrame(penFrame(PenAction.DOWN, pt(90)), 90)
        t.onFrame(penFrame(PenAction.MOVE, pt(93)), 93) // confirms the contact
        val out = t.onFrame(penFrame(PenAction.MOVE, pt(100), pt(103), pt(106), pt(106, x = 1500f), pt(109)), 109)
        assertEquals(1, out.size)
        val pen = out[0].msg as Pen
        assertEquals(100_000L, pen.baseTimeUs)
        assertEquals(listOf(0L, 3000L, 6000L, 6000L, 9000L), pen.samples.map { it.dtUs })
    }

    @Test fun moreThan64SamplesAreSplitInOrderAndNothingIsDropped() {
        val t = tracker()
        t.onFrame(penFrame(PenAction.DOWN, pt(0)), 0)
        val pts = Array(130) { pt(10L + it, x = 100f + it) }
        val out = t.onFrame(penFrame(PenAction.MOVE, *pts), 200) // confirms the held DOWN: 131 samples in all
        val pens = out.map { it.msg as Pen }
        assertEquals(listOf(64, 64, 3), pens.map { it.samples.size })
        val xs = pens.flatMap { it.samples }.map { it.x }
        assertEquals((listOf(pt(0)) + pts).map { VP.normX(it.x) }, xs)
        // Each message has non-decreasing dt and a base not before the previous message's last sample.
        for (p in pens) assertEquals(p.samples.sortedBy { it.dtUs }, p.samples)
        assertTrue(pens[1].baseTimeUs >= pens[0].baseTimeUs + pens[0].samples.last().dtUs)
    }

    @Test fun actionCancelSendsFlagsZeroSample() {
        val t = tracker()
        t.onFrame(penFrame(PenAction.DOWN, pt(0)), 0)
        val out = t.onFrame(penFrame(PenAction.CANCEL, pt(5)), 5)
        assertEquals(listOf(0), flagsOf(out))
        assertFalse(out[0].mergeable)
        assertEquals(PenTracker.State.OUT, t.state)
        assertFalse(t.inRange)
    }

    @Test fun hoverExitSendsFlagsZeroAfterTheDeferral() {
        val t = tracker()
        t.onFrame(penFrame(PenAction.HOVER_MOVE, pt(0)), 0)
        assertTrue(t.onFrame(penFrame(PenAction.HOVER_EXIT, pt(3)), 3).isEmpty())
        assertTrue(t.inRange) // still believed in range until the exit is settled
        assertTrue(t.tick(30).isEmpty())
        assertEquals(listOf(0), flagsOf(t.tick(3 + PenTracker.EXIT_DEFER_MS)))
        assertFalse(t.inRange)
    }

    @Test fun deferredExitIsSentBeforeAnyNonDownFrame() {
        val t = tracker()
        t.onFrame(penFrame(PenAction.HOVER_MOVE, pt(0)), 0)
        t.onFrame(penFrame(PenAction.HOVER_EXIT, pt(3)), 3)
        val out = t.onFrame(penFrame(PenAction.HOVER_ENTER, pt(10)), 10)
        assertEquals(listOf(0, IR), flagsOf(out)) // leave first, then enter
    }

    @Test fun exitFollowedByDownOfAnotherToolIsNotAbsorbed() {
        val t = tracker()
        t.onFrame(penFrame(PenAction.HOVER_MOVE, pt(0)), 0)
        t.onFrame(penFrame(PenAction.HOVER_EXIT, pt(3)), 3)
        val out = t.onFrame(penFrame(PenAction.DOWN, pt(5), eraser = true), 5)
        // The old tool is closed at once; the eraser contact is held (T-029) and confirmed by its second sample.
        val pens = out.map { it.msg as Pen }
        assertEquals(listOf(Pen.TOOL_PEN), pens.map { it.tool })
        assertEquals(listOf(0), pens[0].samples.map { it.flags })
        val confirm = t.onFrame(penFrame(PenAction.MOVE, pt(8), eraser = true), 8).map { it.msg as Pen }
        assertEquals(listOf(Pen.TOOL_ERASER), confirm.map { it.tool })
        assertEquals(listOf(IR or CT or SS, IR or CT), confirm[0].samples.map { it.flags })
    }

    @Test fun exitFollowedByDownAfterTheDeferralWindowIsNotAbsorbed() {
        val t = tracker()
        t.onFrame(penFrame(PenAction.HOVER_MOVE, pt(0)), 0)
        t.onFrame(penFrame(PenAction.HOVER_EXIT, pt(3)), 3)
        val out = t.onFrame(penFrame(PenAction.DOWN, pt(60)), 60)
        assertEquals(listOf(0), flagsOf(out)) // the exit goes out; the contact is held (T-029)
        assertEquals(listOf(IR or CT or SS), flagsOf(t.tick(70)))
    }

    @Test fun eraserToolMapsToToolOne() {
        val t = tracker()
        t.onFrame(penFrame(PenAction.DOWN, pt(0), eraser = true), 0)
        val out = t.tick(10)
        assertEquals(Pen.TOOL_ERASER, (out[0].msg as Pen).tool)
        val hover = tracker().onFrame(penFrame(PenAction.HOVER_MOVE, pt(0)), 0)
        assertEquals(Pen.TOOL_PEN, (hover[0].msg as Pen).tool)
    }

    @Test fun toolChangeEndsTheOldToolFirst() {
        val t = tracker()
        t.onFrame(penFrame(PenAction.DOWN, pt(0)), 0)
        t.onFrame(penFrame(PenAction.MOVE, pt(3)), 3) // confirmed: the host holds the pen contact
        val out = t.onFrame(penFrame(PenAction.HOVER_ENTER, pt(5), eraser = true), 5)
        val pens = out.map { it.msg as Pen }
        assertEquals(listOf(Pen.TOOL_PEN, Pen.TOOL_ERASER), pens.map { it.tool })
        assertEquals(listOf(0), pens[0].samples.map { it.flags })
        assertEquals(listOf(IR), pens[1].samples.map { it.flags })
    }

    @Test fun tiltUsesTheProvisionalSection4Conversion() {
        val t = tracker()
        val s = penSamples(t.onFrame(penFrame(PenAction.HOVER_MOVE, pt(0, tilt = 0.5f, ori = 1.0f)), 0).messages())[0]
        val (fx, fy) = Coords.penTilt(0.5f, 1.0f)
        assertEquals(Coords.signed(fx), s.tiltX)
        assertEquals(Coords.signed(fy), s.tiltY)
        // tilt_x = sin(theta) sin(phi), tilt_y = -sin(theta) cos(phi)
        assertEquals(Math.sin(0.5) * Math.sin(1.0) * 32767, s.tiltX.toDouble(), 1.0)
        assertEquals(-Math.sin(0.5) * Math.cos(1.0) * 32767, s.tiltY.toDouble(), 1.0)
    }

    @Test fun unreportedTiltDuringContactRepeatsTheLastKnownValue() {
        val counters = InputCounters()
        val t = tracker(counters = counters)
        val hover = penSamples(t.onFrame(penFrame(PenAction.HOVER_MOVE, pt(0, tilt = 0.4f, ori = 2f)), 0).messages())[0]
        assertTrue(t.onFrame(penFrame(PenAction.DOWN, pt(5, tilt = 0f, ori = 0f)), 5).isEmpty())
        val down = penSamples(t.tick(15).messages())[0]
        assertEquals(hover.tiltX, down.tiltX)
        assertEquals(hover.tiltY, down.tiltY)
        val nan = penSamples(t.onFrame(penFrame(PenAction.MOVE, pt(8, tilt = Float.NaN, ori = Float.NaN)), 8).messages())[0]
        assertEquals(hover.tiltX, nan.tiltX)
        // A reported value replaces the held one.
        val fresh = penSamples(t.onFrame(penFrame(PenAction.MOVE, pt(11, tilt = 0.9f, ori = 0.5f)), 11).messages())[0]
        val (fx, _) = Coords.penTilt(0.9f, 0.5f)
        assertEquals(Coords.signed(fx), fresh.tiltX)
        assertEquals(2L, counters.tiltHeld)
    }

    @Test fun hoverReportsZeroTiltAsIs() {
        val t = tracker()
        t.onFrame(penFrame(PenAction.HOVER_MOVE, pt(0, tilt = 0.4f, ori = 2f)), 0)
        val s = penSamples(t.onFrame(penFrame(PenAction.HOVER_MOVE, pt(3, tilt = 0f, ori = 0f)), 3).messages())[0]
        assertEquals(0, s.tiltX)
        assertEquals(0, s.tiltY)
    }

    @Test fun pressureIsU16AndZeroWithoutContact() {
        val t = tracker()
        val hover = penSamples(t.onFrame(penFrame(PenAction.HOVER_MOVE, pt(0, pressure = 0.7f)), 0).messages())[0]
        assertEquals(0, hover.pressure)
        t.onFrame(penFrame(PenAction.DOWN, pt(5, pressure = 0.5f)), 5)
        val both = penSamples(t.onFrame(penFrame(PenAction.MOVE, pt(8, pressure = 1.5f)), 8).messages())
        assertEquals(Coords.pressure(0.5f), both[0].pressure) // the held DOWN sample
        assertEquals(65535, both[1].pressure)
        val up = penSamples(t.onFrame(penFrame(PenAction.UP, pt(10, pressure = 0.3f)), 10).messages())[0]
        assertEquals(0, up.pressure) // contact ended
    }

    @Test fun coordinatesGoThroughTheViewportOnly() {
        // 16:9 video in a 2800x1840 view: letterbox bands top and bottom, excluded from the normalization.
        val vp = VideoViewport(2800, 1840, 1600, 900)
        val t = tracker(vp)
        val s = penSamples(t.onFrame(penFrame(PenAction.HOVER_MOVE, pt(0, x = vp.left, y = vp.top)), 0).messages())[0]
        assertEquals(0, s.x)
        assertEquals(0, s.y)
        val e = penSamples(t.onFrame(penFrame(PenAction.HOVER_MOVE, pt(3, x = vp.left + vp.width, y = vp.top + vp.height)), 3).messages())[0]
        assertEquals(65535, e.x)
        assertEquals(65535, e.y)
        val out = penSamples(t.onFrame(penFrame(PenAction.HOVER_MOVE, pt(6, x = -50f, y = 5000f)), 6).messages())[0]
        assertEquals(0, out.x)
        assertEquals(65535, out.y)
        val mid = penSamples(t.onFrame(penFrame(PenAction.HOVER_MOVE, pt(9, x = 1234f, y = 700f)), 9).messages())[0]
        assertEquals(vp.normX(1234f), mid.x)
        assertEquals(vp.normY(700f), mid.y)
    }

    @Test fun buttonStateSetsTheButtonFlagWhileInRange() {
        val t = tracker()
        t.onFrame(penFrame(PenAction.DOWN, pt(0, button = true)), 0)
        val s = penSamples(t.tick(10).messages())[0]
        assertEquals(IR or CT or SS or PenSample.BUTTON, s.flags)
        val leave = penSamples(t.onFrame(penFrame(PenAction.CANCEL, pt(3, button = true)), 3).messages())[0]
        assertEquals(0, leave.flags)
    }

    @Test fun livenessRepeatsTheLastSampleEvery100msWithCurrentTime() {
        val t = tracker()
        t.onFrame(penFrame(PenAction.HOVER_MOVE, pt(1000, x = 200f, y = 300f)), 1000)
        assertTrue(t.tick(1050).isEmpty())
        val rep = t.tick(1100)
        assertEquals(1, rep.size)
        val pen = rep[0].msg as Pen
        assertEquals(1_100_000L, pen.baseTimeUs)
        assertEquals(PenSample(0, VP.normX(200f), VP.normY(300f), 0, pen.samples[0].tiltX, pen.samples[0].tiltY, IR), pen.samples[0])
        assertTrue(t.tick(1150).isEmpty())
        assertEquals(1, t.tick(1200).size)
    }

    @Test fun livenessDuringContactRepeatsPressureWithoutStrokeStart() {
        val t = tracker()
        t.onFrame(penFrame(PenAction.DOWN, pt(0, pressure = 0.6f)), 0)
        t.onFrame(penFrame(PenAction.MOVE, pt(3, pressure = 0.6f)), 3) // confirms the contact
        val rep = penSamples(t.tick(103).messages())
        assertEquals(1, rep.size)
        assertEquals(IR or CT, rep[0].flags)
        assertEquals(Coords.pressure(0.6f), rep[0].pressure)
    }

    @Test fun repeatTimestampsNeverGoBackwards() {
        val t = tracker()
        t.onFrame(penFrame(PenAction.HOVER_MOVE, pt(1000)), 1000)
        t.tick(1100) // repeat stamped 1_100_000 us
        val late = t.onFrame(penFrame(PenAction.HOVER_MOVE, pt(1099, x = 1500f)), 1101) // moved, so not a duplicate of the repeat
        assertTrue((late[0].msg as Pen).baseTimeUs >= 1_100_000L)
    }

    @Test fun hoverWithoutFurtherEventsIsClosedAfterTheStaleWindow() {
        val counters = InputCounters()
        val t = tracker(counters = counters)
        t.onFrame(penFrame(PenAction.UP, pt(0)), 0) // fast lift: Android sends no hover exit afterwards
        assertTrue(t.inRange)
        var closed = false
        var now = 0L
        while (now < 2500 && !closed) {
            now += 25
            closed = t.tick(now).any { (it.msg as Pen).samples.any { s -> s.flags == 0 } }
        }
        assertTrue(closed)
        assertTrue(now >= PenTracker.HOVER_STALE_MS)
        assertFalse(t.inRange)
        assertEquals(1L, counters.hoverStale)
        assertTrue(t.tick(now + 1000).isEmpty())
    }

    @Test fun contactWithoutAnyEventIsClosedByTheLastResortGuard() {
        val counters = InputCounters()
        val t = tracker(counters = counters)
        t.onFrame(penFrame(PenAction.DOWN, pt(0)), 0)
        var closed = false
        var now = 0L
        while (now < 11_000 && !closed) {
            now += 25
            closed = t.tick(now).any { (it.msg as Pen).samples.any { s -> s.flags == 0 } }
        }
        assertTrue(closed)
        assertTrue(now >= PenTracker.CONTACT_STALE_MS)
        assertEquals(1L, counters.contactStale)
        assertFalse(t.inRange)
    }

    @Test fun strokeMiddleWithoutDownIsHoverOnly() {
        // After RELEASE_ALL (reset), Android may still deliver MOVE events of the old stroke (section 7).
        val t = tracker()
        val out = t.onFrame(penFrame(PenAction.MOVE, pt(0, pressure = 0.8f), pt(3, pressure = 0.8f)), 3)
        assertEquals(listOf(IR, IR), flagsOf(out))
        assertTrue(penSamples(out.messages()).all { it.pressure == 0 })
        // The next real stroke starts normally.
        assertTrue(t.onFrame(penFrame(PenAction.DOWN, pt(10)), 10).isEmpty())
        assertEquals(listOf(IR or CT or SS, IR or CT), flagsOf(t.onFrame(penFrame(PenAction.MOVE, pt(13)), 13)))
    }

    @Test fun resetForgetsAContactSoTheMiddleOfThatStrokeIsHover() {
        val t = tracker()
        t.onFrame(penFrame(PenAction.DOWN, pt(0)), 0)
        t.reset()
        assertEquals(listOf(IR), flagsOf(t.onFrame(penFrame(PenAction.MOVE, pt(5)), 5)))
        // and the first hover after a reset is an enter, not mergeable
        val t2 = tracker()
        t2.onFrame(penFrame(PenAction.DOWN, pt(0)), 0)
        t2.reset()
        assertFalse(t2.onFrame(penFrame(PenAction.HOVER_MOVE, pt(5)), 5)[0].mergeable)
    }

    @Test fun downWhileAlreadyInContactEndsTheOldContactFirst() {
        val t = tracker()
        t.onFrame(penFrame(PenAction.DOWN, pt(0)), 0)
        t.onFrame(penFrame(PenAction.MOVE, pt(3)), 3) // confirmed: the host holds the contact
        val out = t.onFrame(penFrame(PenAction.DOWN, pt(20)), 20)
        assertEquals(listOf(IR), flagsOf(out)) // the old contact ends at once, the new one is held
        assertEquals(listOf(IR or CT or SS, IR or CT), flagsOf(t.onFrame(penFrame(PenAction.MOVE, pt(23)), 23)))
    }

    @Test fun downWhileHeldConfirmsOrDropsTheHeldContactByEventAge() {
        val counters = InputCounters()
        val t = tracker(counters = counters)
        t.onFrame(penFrame(PenAction.DOWN, pt(0)), 0)
        // 5 ms later: the first DOWN was a bounce, it is dropped without a trace; the new one is held.
        assertTrue(t.onFrame(penFrame(PenAction.DOWN, pt(5)), 5).isEmpty())
        assertEquals(1L, counters.bounceDropped)
        // 15 ms later: the held contact was long enough to be real; it goes out, ends, and the new one is held.
        assertEquals(listOf(IR or CT or SS, IR), flagsOf(t.onFrame(penFrame(PenAction.DOWN, pt(20)), 20)))
        assertEquals(1L, counters.bounceDropped)
    }

    @Test fun releaseSendsFlagsZeroOnlyWhenSomethingWasInRange() {
        val t = tracker()
        assertTrue(t.release(0).isEmpty())
        t.onFrame(penFrame(PenAction.DOWN, pt(0)), 0)
        t.onFrame(penFrame(PenAction.MOVE, pt(3)), 3)
        assertEquals(listOf(0), flagsOf(t.release(10)))
        assertEquals(PenTracker.State.OUT, t.state)
        assertTrue(t.release(20).isEmpty())
    }

    @Test fun releaseCoversADeferredExit() {
        val t = tracker()
        t.onFrame(penFrame(PenAction.HOVER_MOVE, pt(0)), 0)
        t.onFrame(penFrame(PenAction.HOVER_EXIT, pt(3)), 3)
        assertEquals(listOf(0), flagsOf(t.release(5)))
        assertTrue(t.tick(500).isEmpty())
    }

    @Test fun onlyRepeatedPlainHoverIsMergeable() {
        val t = tracker()
        // enter (transition)
        assertFalse(t.onFrame(penFrame(PenAction.HOVER_ENTER, pt(0)), 0)[0].mergeable)
        // repeated hover
        assertTrue(t.onFrame(penFrame(PenAction.HOVER_MOVE, pt(3)), 3)[0].mergeable)
        assertTrue(t.tick(103)[0].mergeable)
        // contact samples never
        assertTrue(t.onFrame(penFrame(PenAction.DOWN, pt(200)), 200).isEmpty()) // held (T-029)
        assertFalse(t.onFrame(penFrame(PenAction.MOVE, pt(203)), 203)[0].mergeable)
        assertFalse(t.onFrame(penFrame(PenAction.MOVE, pt(204)), 204)[0].mergeable)
        // the hover sample right after the lift is CONTACT 1->0: a transition
        assertFalse(t.onFrame(penFrame(PenAction.UP, pt(206)), 206)[0].mergeable)
        assertTrue(t.onFrame(penFrame(PenAction.HOVER_MOVE, pt(209)), 209)[0].mergeable)
        // leaving is never mergeable
        assertFalse(t.onFrame(penFrame(PenAction.CANCEL, pt(212)), 212)[0].mergeable)
    }

    @Test fun upWithHistoryKeepsTheContactSamplesThenLifts() {
        val t = tracker()
        t.onFrame(penFrame(PenAction.DOWN, pt(0)), 0)
        t.onFrame(penFrame(PenAction.MOVE, pt(2)), 2) // confirmed
        assertEquals(listOf(IR or CT, IR), flagsOf(t.onFrame(penFrame(PenAction.UP, pt(3), pt(6)), 6)))
    }

    @Test fun emptyFramesAreIgnored() {
        assertTrue(tracker().onFrame(PenFrame(PenAction.MOVE, false, emptyList()), 0).isEmpty())
    }
}
