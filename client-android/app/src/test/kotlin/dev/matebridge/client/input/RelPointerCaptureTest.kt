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
}
