package dev.matebridge.client.input

import dev.matebridge.client.protocol.ReleaseAll
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.Random

/**
 * Randomised end-to-end checks of the "input never stuck" rule. A simulated Android event source drives
 * [InputCapture] over a [FakeSink] whose reference [HostModel] mirrors what the Mac would hold.
 *
 * Two invariants are checked after every single step while the connection is up:
 *  1. the host holds exactly what the client believes it holds (pen contact, pen in range, pressed
 *     finger, open scroll), so a release can never be lost or reordered;
 *  2. the host never sees a stroke middle it did not start (`HostModel.violations` stays empty).
 * At the end, all gestures are completed normally, with NO explicit RELEASE_ALL, and the host must be clear.
 */
class InputFuzzTest {
    private class World(seed: Long, private val chaos: Boolean) {
        val rnd = Random(seed)
        val sink = FakeSink()
        val cap = InputCapture(sink, { VP })
        var now = 1000L
        private var nextTickAt = 1000L

        // What Android believes: 0 = pen away, 1 = hovering, 2 = touching.
        var penState = 0
        var penEraser = false
        val fingers = LinkedHashMap<Int, Pair<Float, Float>>()
        private var nextFingerId = 0
        private var wantResume = false

        init {
            cap.setActive(true, now)
            cap.setStreamGeometry(1400, 920)
        }

        private fun px() = 50f + rnd.nextInt(2700)
        private fun py() = 50f + rnd.nextInt(1700)

        private fun points(n: Int): Array<PenPoint> {
            val base = now - n
            return Array(n) { i ->
                val tilt = if (rnd.nextInt(4) == 0) 0f else rnd.nextFloat() * 1.2f
                pt(base + i, px(), py(), rnd.nextFloat(), tilt, rnd.nextFloat() * 6f)
            }
        }

        private fun pen(action: PenAction, n: Int = 1) = cap.onPen(penFrame(action, *points(n), eraser = penEraser), now)

        /**
         * Android delivers every event of a gesture while the window has focus. Events are lost only while the
         * capture is suspended or inactive (its state was released at that moment), so only then do we drop.
         */
        private fun drop() = chaos && (cap.isSuspended || !cap.isActive) && rnd.nextInt(3) == 0

        fun penStep() {
            when (penState) {
                0 -> if (rnd.nextInt(6) == 0) {
                    penEraser = rnd.nextInt(8) == 0
                    penState = 1
                    if (!drop()) pen(PenAction.HOVER_ENTER)
                }
                1 -> when (rnd.nextInt(10)) {
                    in 0..3 -> if (!drop()) pen(PenAction.HOVER_MOVE, 1 + rnd.nextInt(3))
                    4, 5 -> { penState = 0; if (!drop()) pen(PenAction.HOVER_EXIT) }
                    else -> { // touches down: Android sends HOVER_EXIT right before DOWN
                        penState = 2
                        if (!drop()) pen(PenAction.HOVER_EXIT)
                        if (!drop()) pen(PenAction.DOWN)
                        if (chaos && rnd.nextInt(15) == 0) pen(PenAction.DOWN) // duplicate
                    }
                }
                2 -> when (rnd.nextInt(10)) {
                    in 0..6 -> if (!drop()) pen(PenAction.MOVE, 1 + rnd.nextInt(8))
                    7, 8 -> {
                        if (!drop()) pen(PenAction.UP)
                        if (rnd.nextInt(10) < 7) { penState = 1; if (!drop()) pen(PenAction.HOVER_ENTER) } else penState = 0
                    }
                    else -> { penState = 0; if (!drop()) pen(PenAction.CANCEL) }
                }
            }
        }

        private fun fingerFrame(action: TouchAction, acting: Int): TouchFrame =
            TouchFrame(action, acting, fingers.map { Finger(it.key, it.value.first, it.value.second) }, now * 1000, 2)

        fun fingerStep() {
            when (rnd.nextInt(10)) {
                0, 1 -> if (fingers.size < 3) {
                    val id = nextFingerId++
                    fingers[id] = px() to py()
                    if (!drop()) cap.onTouch(fingerFrame(TouchAction.DOWN, id), now)
                }
                in 2..6 -> if (fingers.isNotEmpty()) {
                    for (k in fingers.keys.toList()) fingers[k] = fingers[k]!!.let { (x, y) -> (x + rnd.nextInt(41) - 20) to (y + rnd.nextInt(41) - 20) }
                    if (!drop()) cap.onTouch(fingerFrame(TouchAction.MOVE, -1), now)
                }
                in 7..8 -> if (fingers.isNotEmpty()) {
                    val id = fingers.keys.elementAt(rnd.nextInt(fingers.size))
                    val f = fingerFrame(TouchAction.UP, id)
                    fingers.remove(id)
                    if (!drop()) cap.onTouch(f, now)
                }
                else -> if (fingers.isNotEmpty() && rnd.nextInt(3) == 0) {
                    val f = fingerFrame(TouchAction.CANCEL, -1)
                    fingers.clear()
                    if (!drop()) cap.onTouch(f, now)
                }
            }
        }

        private fun chaosStep() {
            when (rnd.nextInt(100)) {
                0, 1 -> {
                    val reason = intArrayOf(ReleaseAll.BACKGROUND, ReleaseAll.FOCUS_LOST, ReleaseAll.DEVICE_DETACHED, ReleaseAll.USER)[rnd.nextInt(4)]
                    cap.releaseAll(reason, now)
                    wantResume = true
                }
                2 -> cap.setActive(false, now)
                3 -> cap.setActive(true, now)
                4 -> cap.onDeviceRemoved(1 + rnd.nextInt(2), now)
                6 -> if (sink.accept) sink.disconnect()
                7 -> cap.onGestureKeyDown(now)
            }
            if (!sink.accept && rnd.nextInt(10) == 0) {
                sink.reconnect()
                cap.onSessionReset() // MainActivity does this on every new control connection
            }
            if (wantResume && rnd.nextInt(3) == 0) { cap.resume(); wantResume = false }
        }

        fun advance(ms: Int) {
            now += ms
            while (nextTickAt <= now) {
                cap.tick(nextTickAt)
                nextTickAt += 25
            }
        }

        fun step() {
            advance(1 + rnd.nextInt(40))
            if (rnd.nextInt(20) == 0) sink.congestedNow = !sink.congestedNow
            if (rnd.nextInt(5) < 2) penStep() else fingerStep()
            if (chaos) chaosStep()
        }

        /** Host and model must agree on everything that needs a release. Only meaningful while connected. */
        fun checkConsistent(label: String) {
            assertTrue("$label: violations ${sink.host.violations}", sink.host.violations.isEmpty())
            if (!sink.accept) return
            assertEquals("$label: pen contact", cap.penInContact, sink.host.penContact)
            assertEquals("$label: pen in range", cap.penInRange, sink.host.penInRange)
            assertEquals("$label: finger pressed", cap.fingerPressed, sink.host.touchDown)
            assertEquals("$label: scroll open", cap.scrollOpen, sink.host.scrollOpen)
        }

        /** Finish every gesture the way Android would and let the ticks run; no RELEASE_ALL is sent. */
        fun quiesce() {
            if (!sink.accept) { sink.reconnect(); cap.onSessionReset() }
            sink.congestedNow = false
            cap.resume()
            cap.setActive(true, now)
            when (penState) {
                2 -> { pen(PenAction.UP) }
                else -> Unit
            }
            if (penState >= 1) pen(PenAction.HOVER_EXIT)
            penState = 0
            for (id in fingers.keys.toList()) {
                val f = fingerFrame(TouchAction.UP, id)
                fingers.remove(id)
                cap.onTouch(f, now)
            }
            var waited = 0
            while (waited < 3000) { advance(25); waited += 25 }
        }
    }

    private fun run(seed: Long, chaos: Boolean, steps: Int) {
        val w = World(seed, chaos)
        for (i in 0 until steps) {
            w.step()
            w.checkConsistent("seed=$seed step=$i")
        }
        w.quiesce()
        assertTrue("seed=$seed: host still holds input: contact=${w.sink.host.penContact} touch=${w.sink.host.touchDown} scroll=${w.sink.host.scrollOpen}", w.sink.host.clear)
        assertTrue("seed=$seed: pen still in range", !w.sink.host.penInRange)
        assertTrue("seed=$seed: violations ${w.sink.host.violations}", w.sink.host.violations.isEmpty())
    }

    @Test fun wellFormedAndroidEventsNeverLeaveTheHostHoldingAnything() {
        for (seed in 1L..2000L) run(seed, chaos = false, steps = 500)
    }

    @Test fun lifecycleLossesDroppedEventsAndConnectionDropsNeverLeaveTheHostHoldingAnything() {
        for (seed in 1000L..3000L) run(seed, chaos = true, steps = 500)
    }
}
