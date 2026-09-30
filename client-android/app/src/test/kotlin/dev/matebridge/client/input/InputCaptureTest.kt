package dev.matebridge.client.input

import dev.matebridge.client.protocol.Pen
import dev.matebridge.client.protocol.PenGesture
import dev.matebridge.client.protocol.PenSample
import dev.matebridge.client.protocol.PointerAbs
import dev.matebridge.client.protocol.ReleaseAll
import dev.matebridge.client.protocol.Scroll
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Integration tests of the capture layer over a fake sink and a reference host model. Every path that
 * can leave input stuck (cancel, focus loss, background, device removal, backpressure, connection loss)
 * has a test here or in PenTrackerTest / TouchTrackerTest; see the mapping in the T-024 card handoff.
 */
class InputCaptureTest {
    private val IR = PenSample.IN_RANGE
    private val CT = PenSample.CONTACT
    private val SS = PenSample.STROKE_START

    private val sink = FakeSink()
    private val lines = ArrayList<String>()
    private val events = ArrayList<String>()
    private val cap = InputCapture(sink, { VP }, onEvent = { ev, f -> events += "$ev $f".trim() }) { lines += it }

    init {
        setActive(true, 0)
        cap.setStreamGeometry(1400, 920)
    }

    // Every call sets the host's receipt clock to the same test time the capture is given.
    private fun pen(action: PenAction, now: Long, vararg pts: PenPoint, eraser: Boolean = false, device: Int = 1) {
        sink.nowMs = now
        cap.onPen(penFrame(action, *pts, eraser = eraser, device = device), now)
    }

    private fun touch(action: TouchAction, now: Long, acting: Int, vararg f: Finger, device: Int = 2) {
        sink.nowMs = now
        cap.onTouch(touchFrame(action, now, acting, *f, device = device), now)
    }

    /** A pen DOWN that the confirmation timer (T-029) sends 10 ms later. */
    private fun penDown(now: Long, vararg pts: PenPoint, eraser: Boolean = false) {
        pen(PenAction.DOWN, now, *pts, eraser = eraser)
        tick(now + PenTracker.CONFIRM_MS)
    }

    private fun tick(t: Long) { sink.nowMs = t; sink.tickHost(); cap.tick(t) }
    private fun releaseAll(reason: Int, t: Long) { sink.nowMs = t; cap.releaseAll(reason, t) }
    private fun setActive(on: Boolean, t: Long) { sink.nowMs = t; cap.setActive(on, t) }
    private fun onDeviceRemoved(id: Int, t: Long) { sink.nowMs = t; cap.onDeviceRemoved(id, t) }
    private fun onGestureKeyDown(t: Long) { sink.nowMs = t; cap.onGestureKeyDown(t) }
    private fun setFingersDisabled(off: Boolean, t: Long) { sink.nowMs = t; cap.setFingersDisabled(off, t) }

    private fun flags() = penSamples(sink.sent).map { it.flags }
    private fun types() = sink.sent.map { it.javaClass.simpleName }
    private fun releaseAlls() = sink.sent.filterIsInstance<ReleaseAll>().map { it.reason }

    private fun startStroke(t: Long = 0) {
        pen(PenAction.HOVER_ENTER, t, pt(t))
        pen(PenAction.DOWN, t + 5, pt(t + 5))
        pen(PenAction.MOVE, t + 10, pt(t + 8), pt(t + 10))
    }

    @Test fun aStrokeReachesTheHostInOrderAndEndsClean() {
        pen(PenAction.HOVER_ENTER, 0, pt(0))
        pen(PenAction.HOVER_MOVE, 3, pt(3))
        pen(PenAction.HOVER_EXIT, 6, pt(6))
        pen(PenAction.DOWN, 7, pt(7))
        assertFalse("the DOWN is held until it is confirmed (T-029)", sink.host.penContact)
        assertTrue(cap.penInRange)
        pen(PenAction.MOVE, 12, pt(9), pt(12))
        assertTrue(sink.host.penContact)
        pen(PenAction.UP, 15, pt(15))
        assertFalse(sink.host.penContact)
        assertTrue(sink.host.penInRange)
        pen(PenAction.HOVER_EXIT, 18, pt(18))
        tick(100)
        assertFalse(sink.host.penInRange)
        assertTrue(sink.host.violations.isEmpty())
        assertTrue(sink.sent.all { it is Pen })
        assertEquals(listOf(IR, IR, IR or CT or SS, IR or CT, IR or CT, IR, 0), flags())
    }

    @Test fun actionCancelDuringAStrokeReleasesThePenOnTheHost() {
        startStroke()
        pen(PenAction.CANCEL, 20, pt(20))
        assertFalse(sink.host.penContact)
        assertFalse(sink.host.penInRange)
        assertEquals(0, flags().last())
        // and the rest of that stroke, should Android deliver any, is hover only
        pen(PenAction.MOVE, 25, pt(25))
        assertEquals(IR, flags().last())
    }

    @Test fun focusLossSendsTheNaturalReleasesThenReleaseAllAndSuspendsInput() {
        startStroke()
        releaseAll(ReleaseAll.FOCUS_LOST, 30)
        assertEquals(listOf(0), flags().takeLast(1))
        assertEquals(ReleaseAll.FOCUS_LOST, (sink.sent.last() as ReleaseAll).reason)
        assertTrue(sink.host.clear)
        assertTrue(cap.isSuspended)
        val n = sink.sent.size
        pen(PenAction.MOVE, 35, pt(35))
        pen(PenAction.UP, 40, pt(40))
        touch(TouchAction.DOWN, 45, 1, finger(1, 5f, 5f))
        tick(200)
        assertEquals(n, sink.sent.size) // nothing is sent while focus is away
    }

    @Test fun focusLossWithAPressedFingerReleasesItBeforeReleaseAll() {
        touch(TouchAction.DOWN, 0, 1, finger(1, 300f, 400f))
        tick(60) // held-back DOWN goes out
        assertTrue(sink.host.touchDown)
        releaseAll(ReleaseAll.FOCUS_LOST, 70)
        assertEquals(listOf("PointerAbs", "PointerAbs", "ReleaseAll"), types())
        assertEquals(0, (sink.sent[1] as PointerAbs).buttons)
        assertTrue(sink.host.clear)
    }

    @Test fun focusLossDuringATwoFingerScrollCancelsTheScroll() {
        touch(TouchAction.DOWN, 0, 1, finger(1, 1000f, 900f))
        touch(TouchAction.DOWN, 5, 2, finger(1, 1000f, 900f), finger(2, 1200f, 900f))
        touch(TouchAction.MOVE, 10, -1, finger(1, 1000f, 930f), finger(2, 1200f, 930f))
        assertTrue(sink.host.scrollOpen)
        releaseAll(ReleaseAll.FOCUS_LOST, 20)
        assertEquals(Scroll.CANCELLED, sink.sent.filterIsInstance<Scroll>().last().phase)
        assertTrue(sink.host.clear)
    }

    /**
     * MainActivity calls releaseAll(BACKGROUND) from onPause, before onStop() asks the controller to send BYE, so the
     * queue order is [... pen leave, RELEASE_ALL, BYE]. The BYE itself belongs to the session controller (not tested
     * here); what this pins down is that the capture side is complete and last when that call returns.
     */
    @Test fun backgroundingEndsThePenThenSendsReleaseAllAsTheLastMessageAndNothingFollows() {
        startStroke()
        releaseAll(ReleaseAll.BACKGROUND, 40)
        val tail = sink.sent.takeLast(2)
        assertTrue(tail[0] is Pen)
        assertTrue(penSamples(listOf(tail[0])).all { it.flags == 0 }) // the pen leaves first
        assertEquals(ReleaseAll.BACKGROUND, (tail[1] as ReleaseAll).reason)
        assertEquals(listOf(ReleaseAll.BACKGROUND), releaseAlls())
        assertTrue(sink.host.clear)
        assertFalse(sink.host.penInRange)
        assertTrue(cap.isSuspended)
        val n = sink.sent.size
        pen(PenAction.MOVE, 50, pt(50))
        touch(TouchAction.DOWN, 55, 1, finger(1, 5f, 5f))
        tick(500)
        assertEquals(n, sink.sent.size) // nothing follows RELEASE_ALL while backgrounded
    }

    @Test fun releaseAllIsSentEvenWhenNothingLooksHeld() {
        releaseAll(ReleaseAll.BACKGROUND, 10)
        assertEquals(listOf(ReleaseAll.BACKGROUND), releaseAlls())
    }

    @Test fun afterAReleaseTheMiddleOfTheOldStrokeIsHoverOnlyAndTheNextStrokeStartsNormally() {
        startStroke()
        releaseAll(ReleaseAll.FOCUS_LOST, 30)
        cap.resume()
        pen(PenAction.MOVE, 40, pt(40), pt(43)) // Android still reports the old stroke as touching
        assertEquals(listOf(IR, IR), flags().takeLast(2))
        assertTrue(sink.host.violations.isEmpty())
        pen(PenAction.UP, 46, pt(46))
        penDown(100, pt(100))
        assertEquals(IR or CT or SS, flags().last())
        assertTrue(sink.host.penContact)
    }

    @Test fun deviceRemovalReleasesOnlyDevicesWeWereReadingFrom() {
        startStroke()
        onDeviceRemoved(99, 50)
        assertTrue(releaseAlls().isEmpty())
        assertTrue(sink.host.penContact)
        onDeviceRemoved(1, 60)
        assertEquals(listOf(ReleaseAll.DEVICE_DETACHED), releaseAlls())
        assertTrue(sink.host.clear)
        assertFalse(cap.isSuspended) // input from other or returning devices keeps flowing
        pen(PenAction.HOVER_ENTER, 70, pt(70))
        assertEquals(IR, flags().last())
    }

    @Test fun aNewControlConnectionForgetsTheModelSoAStrokeMiddleIsHover() {
        startStroke()
        sink.disconnect()
        sink.reconnect()
        cap.onSessionReset()
        pen(PenAction.MOVE, 40, pt(40))
        assertEquals(IR, flags().last())
        assertTrue(sink.host.violations.isEmpty())
    }

    @Test fun aRefusedSendResetsTheModelAndTheStrokeMiddleStaysHoverAfterReconnect() {
        startStroke()
        sink.disconnect() // overflow or connection loss: the host released everything
        pen(PenAction.MOVE, 40, pt(40)) // refused
        assertFalse(cap.penInContact)
        sink.reconnect()
        pen(PenAction.MOVE, 50, pt(50))
        assertEquals(IR, flags().last())
        assertTrue(sink.host.violations.isEmpty())
        pen(PenAction.UP, 60, pt(60))
        penDown(70, pt(70))
        assertEquals(IR or CT or SS, flags().last())
    }

    @Test fun underBackpressureHoverIsMergedButTheReleaseIsNeverReorderedBehindIt() {
        pen(PenAction.HOVER_ENTER, 0, pt(0, x = 10f))
        sink.congestedNow = true
        pen(PenAction.HOVER_MOVE, 3, pt(3, x = 20f))
        pen(PenAction.HOVER_MOVE, 6, pt(6, x = 30f))
        pen(PenAction.HOVER_MOVE, 9, pt(9, x = 40f))
        assertEquals(1, penSamples(sink.sent).size) // only the enter is out, the rest is held and merged
        pen(PenAction.CANCEL, 12, pt(12, x = 50f))
        val xs = penSamples(sink.sent).map { it.x }
        assertEquals(listOf(VP.normX(10f), VP.normX(40f), VP.normX(50f)), xs) // newest hover, then the leave, in order
        assertEquals(0, flags().last())
        assertTrue(sink.host.clear && !sink.host.penInRange)
    }

    @Test fun underBackpressureStrokeSamplesAndTheirLiftAreNeverHeld() {
        sink.congestedNow = true
        pen(PenAction.DOWN, 0, pt(0))
        for (i in 1..20) pen(PenAction.MOVE, i * 3L, pt(i * 3L, x = 100f + i))
        pen(PenAction.UP, 70, pt(70))
        assertEquals(1 + 20 + 1, penSamples(sink.sent).size)
        assertEquals(IR, flags().last())
        assertFalse(sink.host.penContact)
    }

    @Test fun underBackpressureScrollDeltasMergeButEndedAndReleaseAllAreNeverHeld() {
        touch(TouchAction.DOWN, 0, 1, finger(1, 1000f, 900f))
        touch(TouchAction.DOWN, 5, 2, finger(1, 1000f, 900f), finger(2, 1200f, 900f))
        sink.congestedNow = true
        for (i in 1..5) touch(TouchAction.MOVE, 5L + i * 10, -1, finger(1, 1000f + i * 10, 900f), finger(2, 1200f + i * 10, 900f))
        assertEquals(1, sink.sent.size) // only BEGAN so far
        touch(TouchAction.UP, 100, 1, finger(1, 1050f, 900f), finger(2, 1250f, 900f))
        val sc = sink.sent.filterIsInstance<Scroll>()
        assertEquals(listOf(Scroll.BEGAN, Scroll.CHANGED, Scroll.ENDED), sc.map { it.phase })
        assertEquals(25f, sc[1].dx, 0.001f) // 5 steps of 10 px = 50 px = 25 pt, summed
        assertTrue(sink.host.clear)
    }

    @Test fun heldHoverIsFlushedByTheTickOnceTheQueueDrains() {
        pen(PenAction.HOVER_ENTER, 0, pt(0, x = 10f))
        sink.congestedNow = true
        pen(PenAction.HOVER_MOVE, 3, pt(3, x = 99f))
        assertEquals(1, sink.sent.size)
        tick(10)
        assertEquals(1, sink.sent.size)
        sink.congestedNow = false
        tick(35)
        assertEquals(VP.normX(99f), penSamples(sink.sent).last().x)
    }

    @Test fun overflowDuringAStrokeResetsTheModelSoNothingIsSentAsAStrokeMiddle() {
        startStroke()
        sink.disconnect()
        for (t in 40L..200L step 20L) pen(PenAction.MOVE, t, pt(t)) // every send refused, model already reset
        assertFalse(cap.penInContact)
        sink.reconnect()
        cap.onSessionReset()
        tick(300)
        // nothing but hover may follow, even though Android still reports contact
        pen(PenAction.MOVE, 310, pt(310))
        assertTrue(penSamples(sink.sent.takeLast(1)).all { it.flags == IR })
    }

    @Test fun deactivationReleasesEverythingAndIgnoresLaterEvents() {
        startStroke()
        setActive(false, 50)
        assertEquals(listOf(ReleaseAll.USER), releaseAlls())
        assertTrue(sink.host.clear)
        val n = sink.sent.size
        pen(PenAction.MOVE, 60, pt(60))
        touch(TouchAction.DOWN, 61, 1, finger(1, 1f, 1f))
        tick(300)
        assertEquals(n, sink.sent.size)
        assertFalse(cap.isSuspended)
        setActive(true, 400)
        pen(PenAction.HOVER_ENTER, 410, pt(410))
        assertEquals(IR, flags().last())
    }

    @Test fun doubleTapBecomesOnePenGestureAndFlushesHeldHoverFirst() {
        pen(PenAction.HOVER_ENTER, 0, pt(0))
        sink.congestedNow = true
        pen(PenAction.HOVER_MOVE, 3, pt(3, x = 77f))
        onGestureKeyDown(1000)
        onGestureKeyDown(1012)
        val gestures = sink.sent.filterIsInstance<PenGesture>()
        assertEquals(1, gestures.size)
        assertEquals(PenGesture.DOUBLE_TAP, gestures[0].gesture)
        assertEquals(1_012_000L, gestures[0].timeUs)
        val order = sink.sent.map { it.javaClass.simpleName }
        assertEquals(listOf("Pen", "Pen", "PenGesture"), order) // the held hover went out before the gesture
        assertEquals(1, events.count { it == "pen_gesture gesture=double_tap" })
    }

    @Test fun aSingleGestureKeyPairSendsNothing() {
        onGestureKeyDown(1000)
        assertTrue(sink.sent.isEmpty())
    }

    @Test fun palmRejectionBlocksFingerPressesWhileThePenIsNearAndForOneSecondAfter() {
        pen(PenAction.HOVER_MOVE, 0, pt(0))
        touch(TouchAction.DOWN, 100, 1, finger(1, 300f, 300f))
        tick(150)
        touch(TouchAction.UP, 160, 1, finger(1, 300f, 300f))
        assertTrue(sink.sent.none { it is PointerAbs })
        pen(PenAction.HOVER_EXIT, 200, pt(200))
        tick(260) // exit settles: pen out
        touch(TouchAction.DOWN, 1000, 2, finger(2, 300f, 300f)) // 800 ms after the last pen event
        tick(1100)
        assertTrue(sink.sent.none { it is PointerAbs })
        touch(TouchAction.UP, 1150, 2, finger(2, 300f, 300f))
        touch(TouchAction.DOWN, 1300, 3, finger(3, 300f, 300f)) // > 1 s but inside the client's 1200 ms gate
        tick(1350)
        assertTrue(sink.sent.none { it is PointerAbs })
        touch(TouchAction.UP, 1400, 3, finger(3, 300f, 300f))
        touch(TouchAction.DOWN, 1500, 4, finger(4, 300f, 300f)) // past the pen message (260) + 1200 ms
        tick(1550)
        assertTrue(sink.sent.any { it is PointerAbs && it.buttons == 1 })
    }

    @Test fun aPressedFingerIsStillReleasedWhilePenIsInRange() {
        touch(TouchAction.DOWN, 0, 1, finger(1, 300f, 300f))
        tick(60)
        assertTrue(sink.host.touchDown)
        pen(PenAction.HOVER_ENTER, 70, pt(70)) // pen arrives: the finger (palm?) is released
        assertFalse(sink.host.touchDown)
        // A later UP for that finger is ignored, it does not produce a stray click.
        val n = sink.sent.size
        touch(TouchAction.UP, 90, 1, finger(1, 300f, 300f))
        assertEquals(n, sink.sent.size)
    }

    @Test fun fingerTouchCanBeDisabledCompletely() {
        setFingersDisabled(true, 0)
        assertTrue(cap.fingersDisabled)
        touch(TouchAction.DOWN, 10, 1, finger(1, 300f, 300f))
        tick(100)
        touch(TouchAction.UP, 110, 1, finger(1, 300f, 300f))
        assertTrue(sink.sent.isEmpty())
        // The pen is unaffected.
        pen(PenAction.HOVER_ENTER, 200, pt(200))
        assertEquals(1, sink.sent.size)
        setFingersDisabled(false, 300)
        assertFalse(cap.fingersDisabled)
    }

    @Test fun disablingFingersWhileOneIsPressedReleasesIt() {
        touch(TouchAction.DOWN, 0, 1, finger(1, 300f, 300f))
        tick(60)
        setFingersDisabled(true, 70)
        assertFalse(sink.host.touchDown)
    }

    @Test fun eraserToolIsReportedAsToolOne() {
        penDown(0, pt(0), eraser = true)
        assertEquals(Pen.TOOL_ERASER, (sink.sent.last() as Pen).tool)
    }

    @Test fun livenessKeepsTheHostWatchdogFedWhileThePenIsStill() {
        pen(PenAction.HOVER_MOVE, 0, pt(0))
        var now = 0L
        val before = sink.sent.size
        while (now < 490) { now += 25; tick(now) }
        // one repeat per 100 ms, well inside the host's 500 ms window
        assertTrue(sink.sent.size - before >= 4)
    }

    @Test fun oneSummaryLinePerSecondWithCountersOnly() {
        tick(0)
        pen(PenAction.HOVER_ENTER, 10, pt(10, x = 123f, y = 456f))
        pen(PenAction.HOVER_MOVE, 13, pt(13, x = 124f, y = 457f))
        tick(500)
        assertTrue(lines.isEmpty())
        tick(1000)
        assertEquals(1, lines.size)
        assertTrue(lines[0], lines[0].startsWith("interval_ms=1000 pen_samples="))
        assertTrue(lines[0].contains("palm_reject=0"))
        assertFalse(lines[0].contains("123") || lines[0].contains("456"))
        tick(1500)
        tick(2000)
        assertEquals(2, lines.size) // the pen is still in range, so the summary continues
    }

    @Test fun theSummaryCarriesTheDuplicateAndBatchCountersAndOneSampleMessagesMatchOneToOne() {
        tick(0)
        pen(PenAction.HOVER_ENTER, 10, pt(10, x = 100f))
        pen(PenAction.HOVER_MOVE, 13, pt(13, x = 110f))
        pen(PenAction.HOVER_MOVE, 13, pt(13, x = 110f)) // exact duplicate of the last sent sample: not sent
        pen(PenAction.HOVER_MOVE, 16, pt(16, x = 110f)) // same position, later time: sent and counted
        tick(1000)
        val l = lines[0]
        val samples = Regex("pen_samples=(\\d+)").find(l)!!.groupValues[1]
        val msgs = Regex("pen_msgs=(\\d+)").find(l)!!.groupValues[1]
        assertEquals(l, samples, msgs) // single-sample events: one message per sample
        assertTrue(l, l.contains("dup_exact=1 dup_pos=1 dup_pos_first=1 max_batch=1"))
        assertEquals(samples.toInt(), penSamples(sink.sent).size) // the counter matches what really reached the sink
    }

    @Test fun lifecycleEventsAreLoggedWithoutAnyCoordinates() {
        startStroke()
        releaseAll(ReleaseAll.FOCUS_LOST, 30)
        cap.resume()
        cap.onSessionReset()
        assertTrue(events.toString(), events.contains("input_active on=1"))
        assertTrue(events.toString(), events.contains("release_all reason=2 contact=1 pressed=0 scroll=0 pinch=0"))
        assertTrue(events.toString(), events.contains("input_resume"))
        assertTrue(events.toString(), events.contains("session_reset contact=0 pressed=0 scroll=0 pinch=0"))
    }

    @Test fun invalidCodecInputIsNeverProduced() {
        // Every message the trackers produce passes Codec.encode inside FakeSink.send; exercise the extremes.
        pen(PenAction.DOWN, 0, pt(0, x = -1e9f, y = 1e9f, pressure = 5f, tilt = 9f, ori = -9f))
        pen(PenAction.MOVE, 3, pt(1, x = Float.NaN, y = Float.NaN, pressure = Float.NaN, tilt = Float.NaN, ori = Float.NaN))
        val many = Array(300) { pt(10L + it) }
        pen(PenAction.MOVE, 400, *many)
        touch(TouchAction.DOWN, 500, 1, finger(1, Float.MAX_VALUE, -Float.MAX_VALUE))
        touch(TouchAction.UP, 510, 1, finger(1, Float.MAX_VALUE, -Float.MAX_VALUE))
        assertTrue(sink.sent.isNotEmpty())
    }
}
