package dev.matebridge.client.input

import dev.matebridge.client.protocol.Buttons
import dev.matebridge.client.protocol.Key
import dev.matebridge.client.protocol.PenSample
import dev.matebridge.client.protocol.PointerRel
import dev.matebridge.client.protocol.ReleaseAll
import dev.matebridge.client.settings.SettingsPanelState
import dev.matebridge.client.settings.SettingsPanelState.KeyResult
import dev.matebridge.client.settings.SettingsPanelState.Via
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * T-105: the in-stream settings panel as an input gate. Mirrors MainActivity: input is active only when
 * [SettingsPanelState.inputAllowed] says so, and keyboard events go to [SettingsPanelState.keyWhileOpen] instead of the
 * capture while the panel is open. Nothing may stay pressed on the host across open/close.
 */
class SettingsPanelGateTest {
    private val sink = FakeSink()
    private val cap = InputCapture(sink, { VP })
    private val log = ArrayList<String>()
    private val panel = SettingsPanelState { ev, f -> log += "$ev $f" }
    private val kb = 7
    private var t = 0L

    init {
        sync()
        cap.setStreamGeometry(1400, 920)
    }

    /** MainActivity.syncInputActive with the stream visible. */
    private fun sync() { sink.nowMs = t; cap.setActive(panel.inputAllowed(true), t) }

    private fun open(via: Via = Via.SHORTCUT) { if (panel.open(via, streaming = true)) sync() }
    private fun close(via: Via = Via.ESC) { if (panel.close(via)) sync() }

    private fun frame(scan: Int, code: Int, down: Boolean, repeat: Int = 0, ctrl: Boolean = false, shift: Boolean = false) =
        KeyFrame(kb, scan, code, down, repeat, ctrl, shift, false, t * 1000)

    /** MainActivity.dispatchKeyEvent for a physical keyboard. */
    private fun key(scan: Int, code: Int, down: Boolean, repeat: Int = 0, ctrl: Boolean = false, shift: Boolean = false) {
        t += 10
        sink.nowMs = t
        val f = frame(scan, code, down, repeat, ctrl, shift)
        if (panel.isOpen) {
            when (SettingsPanelState.keyWhileOpen(f)) {
                KeyResult.Close -> close(if (KeyTracker.localChord(f) == LocalAction.SETTINGS) Via.SHORTCUT else Via.ESC)
                else -> Unit
            }
            return
        }
        val d = cap.onKey(f)
        if (d.local == LocalAction.SETTINGS) {
            if (panel.isOpen) close(Via.SHORTCUT) else open(Via.SHORTCUT)
        }
    }

    private fun keys() = sink.sent.filterIsInstance<Key>()

    /** Keys the host holds after replaying KEY and RELEASE_ALL in order (the host releases all keys on RELEASE_ALL). */
    private fun hostKeysHeld(): Set<Int> {
        val held = HashSet<Int>()
        for (m in sink.sent) when (m) {
            is Key -> if (m.action == Key.DOWN) held += m.scanCode else held -= m.scanCode
            is ReleaseAll -> held.clear()
            else -> Unit
        }
        return held
    }

    @Test fun ctrlShift6IsTheSettingsChordByScanCode() {
        assertEquals(LocalAction.SETTINGS, KeyTracker.localChord(frame(7, 13, true, ctrl = true, shift = true)))
        // by physical position: the key code of a layout does not matter
        assertEquals(LocalAction.SETTINGS, KeyTracker.localChord(frame(7, 0, true, ctrl = true, shift = true)))
        assertEquals(LocalAction.NONE, KeyTracker.localChord(frame(7, 13, true, ctrl = true)))
        assertEquals(LocalAction.NONE, KeyTracker.localChord(frame(7, 13, true)))
        assertEquals(LocalAction.STREAM_MODE, KeyTracker.localChord(frame(8, 14, true, ctrl = true, shift = true)))
    }

    @Test fun openingReleasesEverythingHeldThenReleaseAllUser() {
        // held: a key (Cmd on the Mac), a pen contact and a mouse button
        key(29, 113, true)
        t = 100
        cap.onPen(penFrame(PenAction.HOVER_ENTER, pt(t)), t)
        cap.downConfirmed(penFrame(PenAction.DOWN, pt(t + 1)), t + 1)
        cap.onMouse(MouseFrame((t + 20) * 1000, 0f, 0f, Buttons.LEFT, Buttons.LEFT, deviceId = 8), t + 20)
        assertTrue(sink.host.penContact)
        assertEquals(Buttons.LEFT, sink.sent.filterIsInstance<PointerRel>().last().buttons)
        assertEquals(setOf(29), hostKeysHeld())
        sink.clearSent()

        t = 130
        open()

        assertTrue(panel.isOpen)
        assertFalse(cap.isActive)
        val last = sink.sent.last()
        assertTrue("RELEASE_ALL comes last", last is ReleaseAll)
        assertEquals(ReleaseAll.USER, (last as ReleaseAll).reason)
        // the natural releases come before it: pen flags 0, buttons 0
        val before = sink.sent.dropLast(1)
        assertTrue(before.filterIsInstance<dev.matebridge.client.protocol.Pen>().flatMap { it.samples }.last().flags and PenSample.CONTACT == 0)
        assertEquals(0, before.filterIsInstance<PointerRel>().last().buttons)
        assertFalse(sink.host.penContact)
        assertEquals(listOf("settings_panel action=open via=shortcut"), log)
    }

    @Test fun nothingReachesTheHostWhileOpen() {
        open(Via.HOST)
        sink.clearSent()
        key(30, 29, true)
        key(30, 29, false)
        key(28, 66, true) // Enter: goes to the panel's views
        cap.onPen(penFrame(PenAction.HOVER_ENTER, pt(t)), t)
        cap.onPen(penFrame(PenAction.DOWN, pt(t + 1)), t + 1)
        cap.onTouch(touchFrame(TouchAction.DOWN, t + 2, 0, finger(0, 100f, 100f)), t + 2)
        cap.onMouse(MouseFrame((t + 3) * 1000, 5f, 5f, Buttons.LEFT, Buttons.LEFT, deviceId = 8), t + 3)
        cap.onPad(PadFrame(PadAction.DOWN, 0, listOf(finger(0, 10f, 10f)), (t + 4) * 1000, 9, extent = 1000f), t + 4)
        cap.onGestureKeyDown(t + 5)
        cap.tick(t + 50)
        assertTrue(sink.sent.isEmpty())
    }

    @Test fun shortcutOpenAndCloseLeaveNoKeyStuckAndNoStrayUp() {
        // open: Ctrl, Shift reach the Mac; 6 is local
        key(29, 113, true)
        key(42, 59, true, ctrl = true)
        key(7, 13, true, ctrl = true, shift = true)
        assertTrue(panel.isOpen)
        assertEquals(ReleaseAll.USER, sink.sent.filterIsInstance<ReleaseAll>().single().reason)
        assertTrue(hostKeysHeld().isEmpty())
        // repeats and releases while open: nothing is sent, the panel stays open
        key(7, 13, true, repeat = 1, ctrl = true, shift = true)
        assertTrue(panel.isOpen)
        key(7, 13, false, ctrl = true, shift = true)
        key(42, 59, false, ctrl = true)
        key(29, 113, false)
        // close with the same chord: its DOWNs go to the panel, the UPs after closing are not sent (no DOWN for them)
        key(29, 113, true)
        key(42, 59, true, ctrl = true)
        key(7, 13, true, ctrl = true, shift = true)
        assertFalse(panel.isOpen)
        assertTrue(cap.isActive)
        key(7, 13, false, ctrl = true, shift = true)
        key(42, 59, false, ctrl = true)
        key(29, 113, false)
        assertEquals(listOf(Key.DOWN, Key.DOWN), keys().map { it.action }) // only the two before opening
        assertTrue(hostKeysHeld().isEmpty())
        // typing works again, paired
        key(30, 29, true)
        key(30, 29, false)
        assertEquals(listOf(Key.DOWN, Key.UP), keys().drop(2).map { it.action })
        assertTrue(hostKeysHeld().isEmpty())
        assertEquals(listOf("settings_panel action=open via=shortcut", "settings_panel action=close via=shortcut"), log)
    }

    @Test fun escClosesAndItsUpIsNotSent() {
        open()
        key(1, 111, true)
        assertFalse(panel.isOpen)
        key(1, 111, true, repeat = 1)
        key(1, 111, false)
        assertTrue(keys().isEmpty())
        assertEquals("settings_panel action=close via=esc", log.last())
    }

    @Test fun escArrivingAsBackAlsoClosesAndBackNeverPasses() {
        open()
        assertEquals(KeyResult.Close, SettingsPanelState.keyWhileOpen(frame(1, 4, true)))
        assertEquals(KeyResult.Consume, SettingsPanelState.keyWhileOpen(frame(1, 4, false)))
        assertEquals(KeyResult.Consume, SettingsPanelState.keyWhileOpen(frame(0, 4, true))) // BACK without scan code
    }

    @Test fun keyResultsWhileOpen() {
        assertEquals(KeyResult.Close, SettingsPanelState.keyWhileOpen(frame(7, 13, true, ctrl = true, shift = true)))
        assertEquals(KeyResult.Consume, SettingsPanelState.keyWhileOpen(frame(7, 13, true, repeat = 2, ctrl = true, shift = true)))
        assertEquals(KeyResult.Consume, SettingsPanelState.keyWhileOpen(frame(7, 13, false, ctrl = true, shift = true)))
        assertEquals(KeyResult.Close, SettingsPanelState.keyWhileOpen(frame(1, 111, true)))
        assertEquals(KeyResult.Consume, SettingsPanelState.keyWhileOpen(frame(1, 111, false)))
        // other tablet chords keep working
        assertEquals(KeyResult.Local(LocalAction.STATS), SettingsPanelState.keyWhileOpen(frame(9, 15, true, ctrl = true, shift = true)))
        assertEquals(KeyResult.Local(LocalAction.BACKGROUND), SettingsPanelState.keyWhileOpen(frame(1, 111, true, ctrl = true, shift = true)))
        assertEquals(KeyResult.Consume, SettingsPanelState.keyWhileOpen(frame(9, 15, false, ctrl = true, shift = true)))
        // plain keys (focus navigation, Enter, letters) go to the views
        assertEquals(KeyResult.Pass, SettingsPanelState.keyWhileOpen(frame(15, 61, true)))
        assertEquals(KeyResult.Pass, SettingsPanelState.keyWhileOpen(frame(30, 29, true, ctrl = true)))
        assertEquals(KeyResult.Pass, SettingsPanelState.keyWhileOpen(frame(29, 113, false)))
    }

    @Test fun closingRestoresInputAndAPenStrokeNeedsAFreshDown() {
        cap.onPen(penFrame(PenAction.HOVER_ENTER, pt(t)), t)
        cap.downConfirmed(penFrame(PenAction.DOWN, pt(t + 1)), t + 1)
        assertTrue(sink.host.penContact)
        t = 20
        open(Via.HOST)
        assertFalse(sink.host.penContact)
        close(Via.TAP_OUTSIDE)
        assertTrue(cap.isActive)
        sink.clearSent()
        // the stroke that was going on before opening continues as hover only
        cap.onPen(penFrame(PenAction.MOVE, pt(t + 30)), t + 30)
        assertFalse(sink.host.penContact)
        cap.downConfirmed(penFrame(PenAction.DOWN, pt(t + 40)), t + 40)
        assertTrue(sink.host.penContact)
        cap.onPen(penFrame(PenAction.UP, pt(t + 50)), t + 50)
        assertFalse(sink.host.penContact)
    }

    @Test fun openIsIgnoredWithoutStreamAndWhenAlreadyOpen() {
        assertFalse(panel.open(Via.HOST, streaming = false))
        assertFalse(panel.isOpen)
        assertEquals("settings_panel action=ignored via=host reason=not_streaming", log.single())
        assertTrue(panel.open(Via.HOST, streaming = true))
        sync()
        val sent = sink.sent.size
        assertFalse(panel.open(Via.HOST, streaming = true)) // already open: nothing happens, no second RELEASE_ALL
        sync()
        assertEquals(sent, sink.sent.size)
        assertTrue(panel.close(Via.BACKGROUND))
        assertFalse(panel.close(Via.STREAM_END))
        assertEquals("settings_panel action=close via=background", log.last())
    }

    @Test fun openThenCloseGatesInput() {
        assertTrue(panel.open(Via.SHORTCUT, streaming = true))
        assertTrue(panel.isOpen)
        assertTrue(panel.close(Via.SHORTCUT))
        assertFalse(panel.isOpen)
        assertFalse(panel.inputAllowed(false))
        assertTrue(panel.inputAllowed(true))
    }
}
