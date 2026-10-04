package dev.matebridge.client.input

import dev.matebridge.client.idle.IdleDimPolicy
import dev.matebridge.client.idle.IdleDimPolicyTest
import dev.matebridge.client.idle.IdleStage
import dev.matebridge.client.idle.IdleTimeout
import dev.matebridge.client.protocol.Buttons
import dev.matebridge.client.protocol.Key
import dev.matebridge.client.protocol.Pen
import dev.matebridge.client.protocol.PenGesture
import dev.matebridge.client.protocol.PointerAbs
import dev.matebridge.client.protocol.ReleaseAll
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * T-234 (decision 0031) on the capture level: the first input while dimmed never reaches the Mac (the reference host
 * model sees nothing), the window comes back, and a release whose press went out is always sent.
 */
class IdleGateCaptureTest {
    private val sink = FakeSink()
    private val cap = InputCapture(sink, { VP })
    private val win = IdleDimPolicyTest.FakeWindow()
    private val idle = IdleDimPolicy(win, 0, IdleTimeout.MIN_2)
    private val kb = 7
    private val dim = 120_000L

    init {
        sink.nowMs = 0
        cap.setActive(true, 0)
        cap.setStreamGeometry(1400, 920)
        cap.idleGate = idle
    }

    private fun pen(action: PenAction, now: Long) { sink.nowMs = now; cap.onPen(penFrame(action, pt(now), device = PEN_DEVICE), now) }

    private fun touch(action: TouchAction, now: Long, acting: Int, vararg f: Finger) {
        sink.nowMs = now
        cap.onTouch(touchFrame(action, now, acting, *f, device = TOUCH_DEVICE), now)
    }

    private fun tap(t: Long) {
        touch(TouchAction.DOWN, t, 0, finger(0, 1000f, 900f))
        tick(t + 30)
        touch(TouchAction.UP, t + 60, 0, finger(0, 1000f, 900f))
        tick(t + 100)
    }

    private fun key(scan: Int, down: Boolean, t: Long, repeat: Int = 0, ctrl: Boolean = false, shift: Boolean = false): KeyDecision {
        sink.nowMs = t
        return cap.onKey(KeyFrame(kb, scan, 29, down, repeat, ctrl, shift, false, t * 1000))
    }

    private fun tick(t: Long) { sink.nowMs = t; sink.tickHost(); cap.tick(t) }

    private fun dimNow() {
        idle.tick(dim)
        assertEquals(IdleStage.DIM, idle.stage)
        assertTrue(win.dark)
    }

    private fun keys() = sink.sent.filterIsInstance<Key>()

    @Test fun aTapWhileDimmedOnlyWakesAndTheNextTapClicks() {
        dimNow()
        tap(130_000)
        assertTrue(sink.sent.none { it is PointerAbs })
        assertEquals(0, sink.host.pressesAccepted)
        assertEquals(IdleStage.ACTIVE, idle.stage)
        assertFalse(win.dark); assertTrue(win.keepOn)
        tap(131_000)
        assertEquals(1, sink.host.pressesAccepted)
        assertFalse(sink.host.touchDown)
    }

    @Test fun aTwoFingerTouchWhileDimmedIsSwallowedUntilBothFingersAreUp() {
        dimNow()
        touch(TouchAction.DOWN, 130_000, 0, finger(0, 1000f, 900f))
        touch(TouchAction.DOWN, 130_010, 1, finger(0, 1000f, 900f), finger(1, 1200f, 900f))
        touch(TouchAction.MOVE, 130_050, -1, finger(0, 1000f, 960f), finger(1, 1200f, 960f))
        touch(TouchAction.UP, 130_080, 1, finger(0, 1000f, 960f), finger(1, 1200f, 960f))
        touch(TouchAction.MOVE, 130_100, -1, finger(0, 1000f, 990f))
        touch(TouchAction.UP, 130_120, 0, finger(0, 1000f, 990f))
        tick(130_200)
        assertTrue(sink.sent.isEmpty())
        assertTrue(sink.host.clear)
    }

    @Test fun aPenStrokeWhileDimmedIsSwallowedFromHoverToLiftAndTheNextStrokeDraws() {
        dimNow()
        pen(PenAction.HOVER_ENTER, 130_000)
        pen(PenAction.HOVER_MOVE, 130_005)
        pen(PenAction.HOVER_EXIT, 130_010)
        cap.downConfirmed(penFrame(PenAction.DOWN, pt(130_012), device = PEN_DEVICE), 130_012)
        pen(PenAction.MOVE, 130_040)
        pen(PenAction.UP, 130_060)
        assertTrue(sink.sent.none { it is Pen })
        assertFalse(sink.host.penContact)
        // after the lift the pen is ordinary again
        pen(PenAction.HOVER_ENTER, 130_070)
        pen(PenAction.HOVER_EXIT, 130_080)
        cap.downConfirmed(penFrame(PenAction.DOWN, pt(130_082), device = PEN_DEVICE), 130_082)
        pen(PenAction.MOVE, 130_100)
        assertTrue(sink.host.penContact)
        pen(PenAction.UP, 130_120)
        assertFalse(sink.host.penContact)
        assertTrue(sink.host.violations.isEmpty())
    }

    @Test fun aKeyWhileDimmedIsSwallowedDownAndUpAndALocalChordDoesNothing() {
        dimNow()
        assertTrue(key(30, true, 130_000).consumed)
        assertTrue(key(30, true, 130_400, repeat = 1).consumed)
        assertTrue(key(30, false, 130_500).consumed)
        assertTrue(keys().isEmpty())
        assertTrue(key(30, true, 131_000).consumed)
        assertTrue(key(30, false, 131_100).consumed)
        assertEquals(listOf(Key.DOWN, Key.UP), keys().map { it.action })

        idle.tick(131_100 + dim)
        assertEquals(IdleStage.DIM, idle.stage)
        val d = key(7, true, 260_000, ctrl = true, shift = true) // Ctrl+Shift+6 (settings panel) while dimmed
        assertEquals(LocalAction.NONE, d.local)
        assertTrue(d.consumed)
    }

    @Test fun aKeyPressedBeforeTheDimIsReleasedOnTheMac() {
        // The gate did not see this press (it was attached later): its UP still reaches the Mac while dimmed.
        val c = InputCapture(sink, { VP })
        c.setActive(true, 0)
        sink.nowMs = 10
        c.onKey(KeyFrame(kb, 30, 29, true, 0, false, false, false, 10_000))
        assertEquals(listOf(Key.DOWN), keys().map { it.action })
        val late = IdleDimPolicy(IdleDimPolicyTest.FakeWindow(), 0, IdleTimeout.MIN_2)
        late.tick(dim)
        assertEquals(IdleStage.DIM, late.stage)
        c.idleGate = late
        sink.nowMs = 130_000
        c.onKey(KeyFrame(kb, 30, 29, false, 0, false, false, false, 130_000_000))
        assertEquals(listOf(Key.DOWN, Key.UP), keys().map { it.action })
        assertEquals(IdleStage.ACTIVE, late.stage)
    }

    @Test fun aKeyHeldWhileTheGateWatchesKeepsTheWindowAwakeAndItsUpIsSent() {
        key(30, true, 1_000)
        var t = 1_000L
        while (t < 10 * 60_000L) { tick(t); idle.tick(t); t += 1_000 } // a held key never expires, whatever the trackers do
        assertEquals(IdleStage.ACTIVE, idle.stage)
        key(30, false, t)
        assertEquals(listOf(Key.DOWN, Key.UP), keys().map { it.action })
    }

    @Test fun aGestureDoubleTapWhileDimmedIsSwallowed() {
        dimNow()
        sink.nowMs = 130_000
        cap.onGestureKeyDown(130_000)
        cap.onGestureKeyDown(130_100)
        assertTrue(sink.sent.none { it is PenGesture })
    }

    @Test fun releasePathsIgnoreTheGateAndForgetItsSwallows() {
        dimNow()
        touch(TouchAction.DOWN, 130_000, 0, finger(0, 1000f, 900f))
        assertTrue(idle.swallowingAny)
        sink.nowMs = 130_010
        cap.releaseAll(ReleaseAll.FOCUS_LOST, 130_010)
        assertEquals(listOf(ReleaseAll.FOCUS_LOST), sink.sent.filterIsInstance<ReleaseAll>().map { it.reason })
        assertFalse(idle.swallowingAny)
    }

    // ---- review fixes: detach and capture loss forget what they released; swallowed motions stay routable ----

    @Test fun aKeyboardDetachedWithAKeyDownLetsTheWindowDimAgain() {
        key(30, true, 1_000)
        assertTrue(idle.held)
        sink.nowMs = 2_000
        cap.onDeviceRemoved(kb, 2_000)
        assertEquals(listOf(Key.DOWN, Key.UP), keys().map { it.action })
        assertFalse(idle.held)
        idle.tick(2_000 + dim)
        assertEquals(IdleStage.DIM, idle.stage)
    }

    @Test fun aSwallowedKeyOfADetachedKeyboardIsForgotten() {
        dimNow()
        key(30, true, 130_000)
        assertTrue(idle.swallowingAny)
        sink.nowMs = 130_100
        cap.onDeviceRemoved(kb, 130_100)
        assertFalse(idle.swallowingAny)
        assertTrue(keys().isEmpty())
    }

    @Test fun pointerCaptureLostWithAMouseButtonHeldLetsTheWindowDimAgain() {
        sink.nowMs = 1_000
        cap.onMouse(MouseFrame(1_000_000, 0f, 0f, Buttons.LEFT, Buttons.LEFT, deviceId = 9), 1_000)
        assertTrue(idle.held)
        sink.nowMs = 2_000
        cap.onPointerCaptureLost(2_000)
        assertFalse(idle.held)
        idle.tick(2_000 + dim)
        assertEquals(IdleStage.DIM, idle.stage)
    }

    @Test fun aSwallowedPenContactIsEndedByAnUpReportedAsUnknownTool() {
        dimNow()
        pen(PenAction.DOWN, 130_000)
        assertTrue(idle.held)
        assertTrue(cap.followsPen(PEN_DEVICE, 0))
        cap.androidUp(ToolKind.OTHER, PEN_DEVICE, 0, 130_050) // the platform calls the lift UNKNOWN / PALM
        assertFalse(idle.swallowingAny)
        assertFalse(cap.followsPen(PEN_DEVICE, 0))
        assertTrue(sink.sent.none { it is Pen })
        idle.tick(130_050 + dim)
        assertEquals(IdleStage.DIM, idle.stage)
    }

    @Test fun aSwallowedPenContactIsEndedByACancelWithoutAPenPointer() {
        dimNow()
        pen(PenAction.DOWN, 130_000)
        assertEquals(PEN_DEVICE, cap.penContactDevice)
        cap.androidCancel(PEN_DEVICE, penPointerInEvent = false, fingerPointerInEvent = false, nowMs = 130_050)
        assertFalse(idle.swallowingAny)
        assertTrue(sink.sent.isEmpty())
    }

    @Test fun aSwallowedFingerIsEndedByAnUpReportedAsPalm() {
        dimNow()
        touch(TouchAction.DOWN, 130_000, 0, finger(0, 1000f, 900f))
        assertTrue(cap.followsFinger(TOUCH_DEVICE, 0))
        assertEquals(TOUCH_DEVICE, cap.touchDevice)
        cap.androidUp(ToolKind.OTHER, TOUCH_DEVICE, 0, 130_050) // not a finger any more: not in the finger list
        assertFalse(idle.swallowingAny)
        assertFalse(cap.followsFinger(TOUCH_DEVICE, 0))
        assertTrue(sink.sent.isEmpty())
        tap(131_000)
        assertEquals(1, sink.host.pressesAccepted)
    }

    @Test fun aSwallowedPalmCancelledWithoutFingerPointersStillEnds() {
        dimNow()
        touch(TouchAction.DOWN, 130_000, 0, finger(0, 1000f, 900f))
        cap.androidCancel(TOUCH_DEVICE, penPointerInEvent = false, fingerPointerInEvent = false, nowMs = 130_050)
        assertFalse(idle.swallowingAny)
    }

    // ---- review round 2: tracker-made releases end the hold; a stale swallow never leaks its continuation ----

    @Test fun aFingerPressReleasedByTheTrackersStaleGuardLetsTheWindowDim() {
        touch(TouchAction.DOWN, 1_000, 0, finger(0, 1000f, 900f))
        tick(1_200) // pressed on the host
        assertTrue(sink.host.touchDown)
        assertTrue(idle.held)
        tick(1_200 + TouchTracker.PRESS_STALE_MS + 100) // the UP was lost: the tracker releases the press itself
        assertFalse(sink.host.touchDown)
        assertFalse(idle.held)
        idle.tick(1_300 + TouchTracker.PRESS_STALE_MS + dim)
        assertEquals(IdleStage.DIM, idle.stage)
    }

    @Test fun aPenContactReleasedByTheTrackersStaleGuardLetsTheWindowDim() {
        cap.downConfirmed(penFrame(PenAction.DOWN, pt(1_000), device = PEN_DEVICE), 1_000)
        assertTrue(sink.host.penContact)
        assertTrue(idle.held)
        tick(1_000 + PenTracker.CONTACT_STALE_MS + 100)
        assertFalse(sink.host.penContact)
        assertFalse(idle.held)
    }

    private fun pad(action: PadAction, t: Long, acting: Int, vararg f: Finger, buttons: Int = 0, pressed: Int = 0) {
        sink.nowMs = t
        cap.onPad(PadFrame(action, acting, f.toList(), t * 1000, 5, buttons, pressed, 1000f), t)
    }

    @Test fun aStillTouchpadFingerThatWokeTheWindowNeverTapsAfterTheStaleBound() {
        dimNow()
        pad(PadAction.DOWN, 130_000, 0, finger(0, 500f, 500f))
        var t = 130_000L
        while (t < 130_000 + IdleDimPolicy.STALE_MS + 2_000) { t += 25; tick(t); idle.tick(t) }
        assertFalse(idle.held) // the counter may run again
        pad(PadAction.MOVE, t + 10, -1, finger(0, 502f, 500f)) // a little motion, then a quick lift: a "tap" shape
        pad(PadAction.UP, t + 60, 0, finger(0, 502f, 500f))
        tick(t + 400)
        assertTrue(sink.sent.isEmpty())
        // the next touch of the pad is ordinary: a tap clicks
        pad(PadAction.DOWN, t + 1_000, 0, finger(0, 500f, 500f))
        pad(PadAction.UP, t + 1_060, 0, finger(0, 500f, 500f))
        tick(t + 1_400)
        assertTrue(sink.sent.any { it is dev.matebridge.client.protocol.PointerRel })
    }

    @Test fun aMouseButtonHeldSinceTheWakeIsNeverReportedWhenMotionResumes() {
        dimNow()
        sink.nowMs = 130_000
        cap.onMouse(MouseFrame(130_000_000, 0f, 0f, Buttons.LEFT, Buttons.LEFT, deviceId = 9), 130_000)
        var t = 130_000L
        while (t < 130_000 + IdleDimPolicy.STALE_MS + 2_000) { t += 25; tick(t); idle.tick(t) }
        assertFalse(idle.held)
        sink.nowMs = t
        cap.onMouse(MouseFrame(t * 1000, 5f, 0f, Buttons.LEFT, deviceId = 9), t) // dragging on with the button down
        cap.onMouse(MouseFrame((t + 50) * 1000, 0f, 0f, 0, deviceId = 9), t + 50) // its release
        assertTrue(sink.sent.isEmpty())
        cap.onMouse(MouseFrame((t + 500) * 1000, 0f, 0f, Buttons.LEFT, Buttons.LEFT, deviceId = 9), t + 500) // a new click
        assertTrue(sink.sent.any { it is dev.matebridge.client.protocol.PointerRel && it.buttons == Buttons.LEFT })
    }

    @Test fun inGameModeTheFirstTapClicks() {
        idle.setGameMode(true, 0)
        idle.tick(30 * 60_000L)
        tap(30 * 60_000L)
        assertEquals(1, sink.host.pressesAccepted)
    }
}
