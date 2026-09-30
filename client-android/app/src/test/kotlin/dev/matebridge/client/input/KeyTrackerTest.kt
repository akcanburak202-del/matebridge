package dev.matebridge.client.input

import dev.matebridge.client.protocol.Key
import dev.matebridge.client.protocol.ReleaseAll
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class KeyTrackerTest {
    private val sink = FakeSink()
    private val cap = InputCapture(sink, { VP })
    private val kb = 7
    private var t = 0L

    init { cap.setActive(true, 0) }

    private fun key(
        scan: Int, code: Int = 29, down: Boolean = true, repeat: Int = 0, dev: Int = kb,
        ctrl: Boolean = false, shift: Boolean = false, caps: Boolean = false,
    ): KeyDecision {
        t += 10
        return cap.onKey(KeyFrame(dev, scan, code, down, repeat, ctrl, shift, caps, t * 1000))
    }

    private fun keys() = sink.sent.filterIsInstance<Key>()

    @Test fun downAndUpArePairedAndConsumed() {
        assertTrue(key(30, 29).consumed)
        assertTrue(key(30, 29, down = false, caps = true).consumed)
        val k = keys()
        assertEquals(listOf(Key.DOWN, Key.UP), k.map { it.action })
        assertEquals(30, k[0].scanCode); assertEquals(29, k[0].androidKeyCode)
        assertEquals(0, k[0].lockState); assertEquals(Key.LOCK_CAPS, k[1].lockState)
    }

    @Test fun repeatsAndDuplicateDownsAreDroppedButConsumed() {
        key(30)
        assertTrue(key(30, repeat = 1).consumed)
        assertTrue(key(30, repeat = 0).consumed) // second DOWN with repeat 0
        key(30, down = false)
        assertEquals(listOf(Key.DOWN, Key.UP), keys().map { it.action })
    }

    @Test fun upWithoutTrackedDownIsNotSent() {
        assertTrue(key(30, down = false).consumed)
        assertTrue(keys().isEmpty())
    }

    @Test fun backIsNeverSentButConsumed() {
        assertTrue(key(1, code = 4).consumed)
        assertTrue(key(1, code = 4, down = false).consumed)
        assertTrue(keys().isEmpty())
        key(1, code = 111); key(1, code = 111, down = false) // Esc itself goes
        assertEquals(2, keys().size)
    }

    @Test fun unknownScanUsesKeyCodeAndBothZeroIsNotSent() {
        key(0, code = 131)
        key(0, code = 131, down = false)
        assertEquals(listOf(131, 131), keys().map { it.androidKeyCode })
        assertEquals(0, keys()[0].scanCode)
        assertTrue(key(0, code = 0).consumed)
        assertEquals(2, keys().size)
    }

    @Test fun gestureKeyFilterStaysBeforeKey() {
        // The activity routes 718/190 to PEN_GESTURE before any KEY path; the predicate it relies on:
        assertTrue(DoubleTapDetector.isGestureKey(718, 190))
        assertFalse(DoubleTapDetector.isGestureKey(29, 30))
    }

    @Test fun releaseAllForgetsKeysAndLateUpIsNotSent() {
        key(30)
        cap.releaseAll(ReleaseAll.FOCUS_LOST, 100)
        val before = sink.sent.size
        cap.resume()
        assertTrue(key(30, down = false).consumed)
        assertEquals(before, sink.sent.size)
        assertEquals(ReleaseAll::class, sink.sent.last()::class)
    }

    @Test fun keysAreNotAcceptedWhileSuspended() {
        cap.releaseAll(ReleaseAll.BACKGROUND, 100)
        val n = sink.sent.size
        assertFalse(key(30).consumed)
        assertEquals(n, sink.sent.size)
    }

    @Test fun deviceRemovedReleasesOnlyThatDevicesKeys() {
        key(30, dev = kb); key(31, dev = kb); key(32, dev = 9)
        val n = sink.sent.size
        cap.onDeviceRemoved(kb, 500)
        val ups = sink.sent.drop(n)
        assertEquals(listOf(30, 31), ups.map { (it as Key).scanCode })
        assertTrue(ups.all { (it as Key).action == Key.UP })
        assertFalse(sink.sent.drop(n).any { it is ReleaseAll })
        // the other device's key is still tracked and gets its UP
        key(32, dev = 9, down = false)
        assertEquals(Key.UP, (sink.sent.last() as Key).action)
        assertEquals(32, (sink.sent.last() as Key).scanCode)
    }

    @Test fun sameKeyOnTwoKeyboardsSendsFirstDownAndLastUpOnly() {
        key(42, dev = 7); key(42, dev = 9)
        assertEquals(listOf(Key.DOWN), keys().map { it.action })
        key(42, dev = 7, down = false)
        assertEquals(1, keys().size) // the other keyboard still holds Shift
        key(42, dev = 9, down = false)
        assertEquals(listOf(Key.DOWN, Key.UP), keys().map { it.action })
    }

    @Test fun detachKeepsKeyWhileAnotherKeyboardHoldsIt() {
        key(42, dev = 7); key(42, dev = 9)
        cap.onDeviceRemoved(7, 500)
        assertEquals(1, keys().size)
        cap.onDeviceRemoved(9, 600)
        assertEquals(listOf(Key.DOWN, Key.UP), keys().map { it.action })
    }

    @Test fun localF3DuplicateDownAndUpStayLocalEvenAfterModifiersRelease() {
        assertTrue(key(61, code = 134, ctrl = true, shift = true).localToggle)
        val dup = key(61, code = 134) // modifiers already released, DOWN with repeat 0
        assertTrue(dup.consumed); assertFalse(dup.localToggle)
        assertTrue(key(61, code = 134, down = false).consumed)
        assertTrue(keys().isEmpty())
        // after the UP a fresh chord toggles again
        assertTrue(key(61, code = 134, ctrl = true, shift = true).localToggle)
    }

    @Test fun localF3SuppressionEndsOnDetachAndReset() {
        key(61, code = 134, ctrl = true, shift = true)
        cap.onDeviceRemoved(kb, 500)
        key(61, code = 134) // plain F3 now goes to the Mac
        assertEquals(1, keys().size)
        key(61, code = 134, down = false)
        assertEquals(2, keys().size)
        assertTrue(key(61, code = 134, ctrl = true, shift = true).localToggle)
        cap.releaseAll(ReleaseAll.USER, 900)
        key(61, code = 134) // reset cleared the suppression: plain F3 is sent again
        assertEquals(3, keys().size)
    }

    @Test fun deviceRemovedWithoutKeysSendsNothing() {
        cap.onDeviceRemoved(kb, 500)
        assertTrue(sink.sent.isEmpty())
    }

    @Test fun ctrlShiftF3TogglesLocallyAndIsNotSent() {
        key(29, code = 113) // Ctrl goes to the Mac (accepted)
        val d = key(61, code = 134, ctrl = true, shift = true)
        assertTrue(d.consumed); assertTrue(d.localToggle)
        val u = key(61, code = 134, down = false, ctrl = true, shift = true)
        assertTrue(u.consumed); assertFalse(u.localToggle)
        assertEquals(1, keys().size)
    }

    @Test fun plainF3GoesToTheMacAndHeldF3UpSurvivesCtrlShift() {
        val d = key(61, code = 134)
        assertFalse(d.localToggle)
        assertEquals(1, keys().size)
        key(61, code = 134, down = false, ctrl = true, shift = true)
        assertEquals(listOf(Key.DOWN, Key.UP), keys().map { it.action })
    }

    @Test fun withoutSessionF3IsLocalAndOtherKeysStayWithAndroid() {
        cap.setActive(false, 50)
        val n = sink.sent.size
        val f3 = key(61, code = 134)
        assertTrue(f3.consumed); assertTrue(f3.localToggle)
        assertTrue(key(61, code = 134, repeat = 1).consumed)
        assertFalse(key(61, code = 134, repeat = 1).localToggle)
        assertFalse(key(30).consumed)
        assertEquals(n, sink.sent.size)
    }

    @Test fun keyMessagesAreCountedAndNotMerged() {
        val lines = ArrayList<String>()
        val c = InputCapture(sink, { VP }, onStatsLine = { lines += it })
        c.setActive(true, 0)
        sink.congestedNow = true
        c.onKey(KeyFrame(kb, 30, 29, true, 0, false, false, false, 1000))
        c.onKey(KeyFrame(kb, 30, 29, false, 0, false, false, false, 2000))
        assertEquals(2, keys().size)
        c.tick(2000); c.tick(3500)
        assertTrue(lines.any { "key_msgs=2" in it })
    }

    @Test fun physicalKeyboardPredicate() {
        assertTrue(KeyTracker.isPhysicalKeyboard(false, 0x101, 2))
        assertFalse(KeyTracker.isPhysicalKeyboard(true, 0x101, 2))
        assertFalse(KeyTracker.isPhysicalKeyboard(false, 0x101, 1)) // volume/power keys: non-alphabetic
        assertFalse(KeyTracker.isPhysicalKeyboard(false, 0x1002, 2)) // touch/stylus source
        assertNull(KeyTracker.keyId(0, 0))
    }
}
