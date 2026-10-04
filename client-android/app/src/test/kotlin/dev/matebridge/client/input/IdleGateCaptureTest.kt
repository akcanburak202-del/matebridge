package dev.matebridge.client.input

import dev.matebridge.client.idle.IdleDimPolicy
import dev.matebridge.client.idle.IdleDimPolicyTest
import dev.matebridge.client.idle.IdleStage
import dev.matebridge.client.idle.IdleTimeout
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
        while (t < 10 * 60_000L) { idle.tick(t); t += 1_000 }
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

    @Test fun inGameModeTheFirstTapClicks() {
        idle.setGameMode(true, 0)
        idle.tick(30 * 60_000L)
        tap(30 * 60_000L)
        assertEquals(1, sink.host.pressesAccepted)
    }
}
