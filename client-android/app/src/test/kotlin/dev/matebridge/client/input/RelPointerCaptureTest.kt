package dev.matebridge.client.input

import dev.matebridge.client.protocol.Buttons
import dev.matebridge.client.protocol.PointerRel
import dev.matebridge.client.protocol.ReleaseAll
import dev.matebridge.client.protocol.Scroll
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** T-034 on the capture level: release paths, merging and counters. */
class RelPointerCaptureTest {
    private val sink = FakeSink()
    private val lines = ArrayList<String>()
    private val cap = InputCapture(sink, { VP }) { lines += it }

    init {
        cap.setActive(true, 0)
        cap.setStreamGeometry(1000, 600)
    }

    private fun pad(action: PadAction, ms: Long, acting: Int, vararg fs: Finger, buttons: Int = 0, pressed: Int = 0) {
        sink.nowMs = ms
        cap.onPad(PadFrame(action, acting, fs.toList(), ms * 1000, 7, buttons, pressed, 1000f), ms)
    }

    private fun heldClick() {
        pad(PadAction.DOWN, 0, 0, Finger(0, 100f, 100f))
        pad(PadAction.BUTTON, 10, -1, Finger(0, 100f, 100f), buttons = Buttons.LEFT, pressed = Buttons.LEFT)
    }

    @Test fun captureLossReleasesReportedButtonAndKeepsInputRunning() {
        heldClick()
        sink.sent.clear()
        cap.onPointerCaptureLost(50)
        assertEquals(listOf(PointerRel(50_000, 0f, 0f, 0)), sink.sent)
        assertFalse(cap.isSuspended)
        assertTrue(sink.sent.none { it is ReleaseAll })
        // Nothing reported any more: a second loss sends nothing.
        sink.sent.clear()
        cap.onPointerCaptureLost(60)
        assertTrue(sink.sent.isEmpty())
    }

    @Test fun captureLossClosesOpenScroll() {
        pad(PadAction.DOWN, 0, 0, Finger(0, 100f, 100f))
        pad(PadAction.DOWN, 5, 1, Finger(0, 100f, 100f), Finger(1, 300f, 100f))
        pad(PadAction.MOVE, 30, -1, Finger(0, 100f, 140f), Finger(1, 300f, 140f))
        sink.sent.clear()
        cap.onPointerCaptureLost(40)
        assertEquals(listOf(Scroll.ENDED), sink.sent.filterIsInstance<Scroll>().map { it.phase })
    }

    @Test fun releaseAllSendsButtonsZeroImmediatelyBeforeReleaseAll() {
        heldClick()
        sink.sent.clear()
        cap.releaseAll(ReleaseAll.FOCUS_LOST, 70)
        assertEquals(listOf("PointerRel", "ReleaseAll"), sink.sent.map { it.javaClass.simpleName })
        assertEquals(0, (sink.sent[0] as PointerRel).buttons)
        // Suspended: pad input is ignored until resume.
        sink.sent.clear()
        pad(PadAction.BUTTON, 80, -1, Finger(0, 100f, 100f), buttons = Buttons.LEFT, pressed = Buttons.LEFT)
        assertTrue(sink.sent.isEmpty())
    }

    @Test fun inactiveCaptureIgnoresPadAndMouse() {
        cap.setActive(false, 5)
        sink.sent.clear()
        pad(PadAction.BUTTON, 10, -1, buttons = Buttons.LEFT, pressed = Buttons.LEFT)
        cap.onMouse(MouseFrame(10_000, 1f, 1f, 0), 10)
        assertTrue(sink.sent.isEmpty())
    }

    @Test fun congestedMotionMergesButButtonChangesNeverDo() {
        sink.congestedNow = true
        cap.onMouse(MouseFrame(1_000, 1f, 2f, 0, deviceId = 8), 1)
        cap.onMouse(MouseFrame(2_000, 3f, 4f, 0, deviceId = 8), 2)
        assertTrue(sink.sent.isEmpty()) // held
        // A press flushes the merged motion first, then is sent on its own.
        cap.onMouse(MouseFrame(3_000, 0f, 0f, Buttons.LEFT, Buttons.LEFT, deviceId = 8), 3)
        assertEquals(listOf(PointerRel(2_000, 4f, 6f, 0), PointerRel(3_000, 0f, 0f, Buttons.LEFT)), sink.sent)
        cap.onMouse(MouseFrame(4_000, 1f, 0f, Buttons.LEFT, deviceId = 8), 4)
        cap.onMouse(MouseFrame(5_000, 0f, 0f, 0, deviceId = 8), 5) // the release flushes the held motion, then goes out
        assertEquals(Buttons.LEFT, (sink.sent[2] as PointerRel).buttons)
        assertEquals(0, (sink.sent[3] as PointerRel).buttons)
    }

    @Test fun countersShowInStatsLine() {
        pad(PadAction.DOWN, 0, 0, Finger(0, 100f, 100f))
        pad(PadAction.UP, 60, 0, Finger(0, 100f, 100f))
        cap.tick(InputCapture.STATS_INTERVAL_MS + 100)
        cap.tick(2 * InputCapture.STATS_INTERVAL_MS + 200)
        val line = lines.first()
        assertTrue(line, "rel_msgs=2" in line && "taps=1" in line && "tp_scroll=0" in line)
    }

    @Test fun deviceRemovalOfThePadClosesItsButton() {
        heldClick()
        sink.sent.clear()
        cap.onDeviceRemoved(7, 90)
        assertEquals(listOf(0), sink.sent.filterIsInstance<PointerRel>().map { it.buttons })
    }

    private fun touch(action: TouchAction, ms: Long, acting: Int, vararg fs: Finger) {
        sink.nowMs = ms
        cap.onTouch(TouchFrame(action, acting, fs.toList(), ms * 1000, 2), ms)
    }

    private fun openPadScroll() {
        pad(PadAction.DOWN, 0, 0, Finger(0, 100f, 100f))
        pad(PadAction.DOWN, 5, 1, Finger(0, 100f, 100f), Finger(1, 300f, 100f))
        pad(PadAction.MOVE, 30, -1, Finger(0, 100f, 140f), Finger(1, 300f, 140f))
    }

    private fun phases() = sink.sent.filterIsInstance<Scroll>().map { it.phase }

    @Test fun touchscreenScrollIsIgnoredWhilePadOwnsTheHostScroll() {
        openPadScroll()
        sink.sent.clear()
        touch(TouchAction.DOWN, 100, 0, Finger(0, 500f, 500f))
        touch(TouchAction.DOWN, 110, 1, Finger(0, 500f, 500f), Finger(1, 700f, 500f)) // touch BEGAN: dropped
        touch(TouchAction.MOVE, 120, -1, Finger(0, 500f, 540f), Finger(1, 700f, 540f))
        touch(TouchAction.UP, 130, 1, Finger(0, 500f, 540f), Finger(1, 700f, 540f)) // touch ENDED: dropped
        assertTrue(phases().isEmpty())
        // The pad's gesture is still alive on the host and continues.
        pad(PadAction.MOVE, 140, -1, Finger(0, 100f, 160f), Finger(1, 300f, 160f))
        assertEquals(listOf(Scroll.CHANGED), phases())
        pad(PadAction.UP, 150, 1, Finger(0, 100f, 160f), Finger(1, 300f, 160f))
        assertEquals(listOf(Scroll.CHANGED, Scroll.ENDED), phases())
    }

    @Test fun padScrollIsIgnoredWhileTouchscreenOwnsTheHostScrollAndOwnershipIsFreedAfterwards() {
        touch(TouchAction.DOWN, 0, 0, Finger(0, 500f, 500f))
        touch(TouchAction.DOWN, 10, 1, Finger(0, 500f, 500f), Finger(1, 700f, 500f))
        assertEquals(listOf(Scroll.BEGAN), phases())
        sink.sent.clear()
        openPadScroll() // dropped entirely
        assertTrue(phases().isEmpty())
        touch(TouchAction.UP, 200, 1, Finger(0, 500f, 500f), Finger(1, 700f, 500f))
        assertEquals(listOf(Scroll.ENDED), phases())
        touch(TouchAction.UP, 210, 0, Finger(0, 500f, 500f))
        // Free again: a new pad scroll gets through once the pad fingers are fresh.
        pad(PadAction.UP, 300, 0)
        pad(PadAction.UP, 305, 1)
        sink.sent.clear()
        pad(PadAction.DOWN, 400, 0, Finger(0, 100f, 100f))
        pad(PadAction.DOWN, 405, 1, Finger(0, 100f, 100f), Finger(1, 300f, 100f))
        pad(PadAction.MOVE, 430, -1, Finger(0, 100f, 140f), Finger(1, 300f, 140f))
        assertEquals(listOf(Scroll.BEGAN, Scroll.CHANGED), phases())
    }
}
