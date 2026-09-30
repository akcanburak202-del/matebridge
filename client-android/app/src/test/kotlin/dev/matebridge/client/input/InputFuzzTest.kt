package dev.matebridge.client.input

import dev.matebridge.client.protocol.ReleaseAll
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.Random

/**
 * Randomised end-to-end checks of the "input never stuck" rule. A simulated Android event source drives
 * [InputCapture] over a [FakeSink] whose [HostModel] is a port of the real host state machine (pointer lock,
 * finger gate, 500 ms watchdogs, per-session fresh latched state, single left-button owner).
 *
 * The harness never drops or delays Android events: a gesture in flight survives focus loss, background and
 * deactivation exactly like on a real window (the capture is what ignores it while suspended). Chaos mode adds
 * lifecycle releases, device removal, connection drops with a fresh host session, and malformed sequences:
 * duplicate DOWNs, stray UPs and MOVEs, a contact MOVE without DOWN, cancels with nothing down, repeated hover
 * exits, and finger releases whose tool type changed (the acting pointer is missing from the finger list).
 *
 * Checked after every step while connected:
 *  1. the host holds exactly what the client believes it holds (pen contact and range, pressed finger, open scroll);
 *  2. no press was refused by the host (gate or pointer lock disagreeing with the client), no host watchdog fired,
 *     and the host never saw a stroke middle it did not start.
 * At the end all gestures are completed the way Android would, with NO extra RELEASE_ALL, and the host must hold nothing.
 *
 * Not covered by the model: wall-clock skew between tablet and Mac, real TCP delivery delay (messages arrive
 * instantly), keyboard and mouse sources, right/middle buttons, injector behaviour.
 */
class InputFuzzTest {
    private class World(seed: Long, private val chaos: Boolean, private val congest: Boolean) {
        val rnd = Random(seed)
        val sink = FakeSink()
        val cap = InputCapture(sink, { VP })
        var now = 1000L
        private var nextTickAt = 1000L
        private var congestUntil = 0L

        // What Android believes: 0 = pen away, 1 = hovering, 2 = touching.
        var penState = 0
        var penEraser = false
        val fingers = LinkedHashMap<Int, Pair<Float, Float>>()
        private var nextFingerId = 10
        private var wantResume = false
        val trace = ArrayList<String>()
        private fun t(what: String) { trace += "t=$now $what" }

        init {
            sink.nowMs = now
            cap.setActive(true, now)
            cap.setStreamGeometry(1400, 920)
        }

        /**
         * Chaos only: the platform loses a release (a bug we must survive). Only the 10 s pressed-finger guard,
         * the 5 s scroll idle end and the pen's 2 s / 10 s guards can clear what the client then still believes.
         */
        private fun lostRelease() = chaos && rnd.nextInt(40) == 0

        private fun px() = 50f + rnd.nextInt(2700)
        private fun py() = 50f + rnd.nextInt(1700)

        private fun points(n: Int): Array<PenPoint> {
            val base = now - n
            return Array(n) { i ->
                val tilt = if (rnd.nextInt(4) == 0) 0f else rnd.nextFloat() * 1.2f
                pt(base + i, px(), py(), rnd.nextFloat(), tilt, rnd.nextFloat() * 6f)
            }
        }

        private fun pen(action: PenAction, n: Int = 1) {
            t("pen $action n=$n eraser=$penEraser")
            cap.onPen(penFrame(action, *points(n), eraser = penEraser), now)
        }

        private fun touch(f: TouchFrame) {
            t("finger ${f.action} acting=${f.actingId} down=${f.fingers.map { it.id }}")
            cap.onTouch(f, now)
        }

        fun penStep() {
            when (penState) {
                0 -> if (rnd.nextInt(6) == 0) {
                    penEraser = rnd.nextInt(8) == 0
                    penState = 1
                    pen(PenAction.HOVER_ENTER)
                }
                1 -> when (rnd.nextInt(10)) {
                    in 0..3 -> pen(PenAction.HOVER_MOVE, 1 + rnd.nextInt(3))
                    4, 5 -> { penState = 0; pen(PenAction.HOVER_EXIT) }
                    else -> { // touches down: Android sends HOVER_EXIT right before DOWN
                        penState = 2
                        pen(PenAction.HOVER_EXIT)
                        pen(PenAction.DOWN, if (chaos && rnd.nextInt(6) == 0) 1 + rnd.nextInt(3) else 1)
                        if (chaos && rnd.nextInt(15) == 0) pen(PenAction.DOWN) // duplicate
                    }
                }
                2 -> when (rnd.nextInt(10)) {
                    in 0..6 -> pen(PenAction.MOVE, 1 + rnd.nextInt(8))
                    7, 8 -> {
                        if (lostRelease()) t("pen UP lost by the platform") else pen(PenAction.UP, if (chaos && rnd.nextInt(6) == 0) 1 + rnd.nextInt(3) else 1)
                        if (rnd.nextInt(10) < 7) { penState = 1; pen(PenAction.HOVER_ENTER) } else penState = 0
                    }
                    else -> { penState = 0; pen(PenAction.CANCEL) }
                }
            }
        }

        private fun fingerFrame(action: TouchAction, acting: Int, hideActing: Boolean = false): TouchFrame =
            TouchFrame(
                action, acting,
                fingers.filter { !(hideActing && it.key == acting) }.map { Finger(it.key, it.value.first, it.value.second) },
                now * 1000, 2,
            )

        fun fingerStep() {
            when (rnd.nextInt(10)) {
                0, 1 -> if (fingers.size < 3) {
                    val id = nextFingerId++
                    fingers[id] = px() to py()
                    touch(fingerFrame(TouchAction.DOWN, id))
                }
                in 2..6 -> if (fingers.isNotEmpty()) {
                    for (k in fingers.keys.toList()) fingers[k] = fingers[k]!!.let { (x, y) -> (x + rnd.nextInt(41) - 20) to (y + rnd.nextInt(41) - 20) }
                    touch(fingerFrame(TouchAction.MOVE, -1))
                }
                in 7..8 -> if (fingers.isNotEmpty()) {
                    val id = fingers.keys.elementAt(rnd.nextInt(fingers.size))
                    // In chaos the platform sometimes reports the release with another tool type (PALM/UNKNOWN):
                    // the acting pointer is then missing from the finger list but the release must still count.
                    val f = fingerFrame(TouchAction.UP, id, hideActing = chaos && rnd.nextInt(4) == 0)
                    fingers.remove(id)
                    if (lostRelease()) t("finger UP $id lost by the platform") else touch(f)
                }
                else -> if (fingers.isNotEmpty() && rnd.nextInt(3) == 0) {
                    val f = fingerFrame(TouchAction.CANCEL, -1)
                    fingers.clear()
                    touch(f)
                }
            }
        }

        /** Malformed input the platform should not send but a robust client must survive. */
        private fun strayStep() {
            when (rnd.nextInt(9)) {
                0 -> if (penState != 2) pen(PenAction.UP)
                1 -> if (penState != 2) pen(PenAction.MOVE, 1 + rnd.nextInt(3)) // contact MOVE without DOWN
                2 -> if (penState == 0) pen(PenAction.CANCEL)
                3 -> if (penState == 0) pen(PenAction.HOVER_EXIT)
                4 -> touch(TouchFrame(TouchAction.UP, 900 + rnd.nextInt(5), fingers.map { Finger(it.key, it.value.first, it.value.second) } + Finger(999, 5f, 5f), now * 1000, 2))
                5 -> if (fingers.isNotEmpty()) touch(fingerFrame(TouchAction.DOWN, fingers.keys.first())) // duplicate DOWN
                6 -> touch(TouchFrame(TouchAction.MOVE, -1, listOf(Finger(777, px(), py())), now * 1000, 2)) // unknown pointer
                7 -> touch(TouchFrame(TouchAction.CANCEL, -1, emptyList(), now * 1000, 2))
                8 -> if (penState == 2) pen(PenAction.CANCEL).also { penState = 0 }
            }
        }

        private fun chaosStep() {
            when (rnd.nextInt(100)) {
                0, 1 -> {
                    val reason = intArrayOf(ReleaseAll.BACKGROUND, ReleaseAll.FOCUS_LOST, ReleaseAll.DEVICE_DETACHED, ReleaseAll.USER)[rnd.nextInt(4)]
                    t("releaseAll reason=$reason")
                    cap.releaseAll(reason, now)
                    wantResume = true
                }
                2 -> { t("setActive false"); cap.setActive(false, now) }
                3 -> { t("setActive true"); cap.setActive(true, now) }
                4 -> { t("deviceRemoved"); cap.onDeviceRemoved(1 + rnd.nextInt(2), now) }
                6 -> if (sink.accept) { t("disconnect"); sink.disconnect() }
                // A double tap while the pen touches would change the tool under a stroke (documented in PROTOCOL.md section 4).
                7 -> if (penState != 2 && !cap.penInContact) { t("gestureKey"); cap.onGestureKeyDown(now) }
                in 8..12 -> strayStep()
            }
            if (!sink.accept && rnd.nextInt(10) == 0) {
                t("reconnect")
                sink.reconnect() // a fresh host session, latched, nothing reported
                cap.onSessionReset() // MainActivity does this on every new control connection
            }
            if (wantResume && rnd.nextInt(3) == 0) { t("resume"); cap.resume(); wantResume = false }
        }

        fun advance(ms: Int) {
            var left = ms
            while (left > 0) {
                left--
                now++
                sink.nowMs = now
                if (sink.congestedNow && now >= congestUntil) sink.congestedNow = false
                if (now >= nextTickAt) { cap.tick(nextTickAt); nextTickAt += 25 }
                sink.tickHost()
            }
        }

        fun step() {
            advance(1 + rnd.nextInt(40))
            // Now and then everything holds still (a resting hand, a hovering pen): liveness repeats, the scroll
            // keepalive and the 5 s / 10 s guards all have to work without a single Android event.
            if (rnd.nextInt(60) == 0) {
                advance(
                    when (rnd.nextInt(10)) {
                        in 0..5 -> 200 + rnd.nextInt(700)
                        in 6..8 -> 5_200
                        else -> 10_500
                    },
                )
            }
            if (congest && !sink.congestedNow && rnd.nextInt(20) == 0) {
                sink.congestedNow = true
                congestUntil = now + 25 + rnd.nextInt(175) // shorter than the host's 500 ms watchdog minus the liveness period
            }
            if (rnd.nextInt(5) < 2) penStep() else fingerStep()
            if (chaos) chaosStep()
        }

        /** Host and client model must agree on everything that needs a release. Only meaningful while connected. */
        fun check(label: String) {
            val h = sink.host
            assertTrue("$label: violations ${h.violations}", h.violations.isEmpty())
            if (!sink.accept) return
            assertEquals("$label: pen contact", cap.penInContact, h.penContact)
            assertEquals("$label: pen in range", cap.penInRange, h.penInRange)
            assertEquals("$label: finger pressed", cap.fingerPressed, h.touchDown)
            assertEquals("$label: scroll open", cap.scrollOpen, h.scrollOpen)
            assertEquals("$label: host refused a press the client sent (gate or pointer lock mismatch)", 0, sink.pressesRejected)
            assertEquals("$label: a host watchdog fired (liveness starved)", 0, sink.watchdogFires)
        }

        /** Finish every gesture the way Android would and let the ticks run; no RELEASE_ALL is sent. */
        fun quiesce() {
            if (!sink.accept) { sink.reconnect(); cap.onSessionReset() }
            sink.congestedNow = false
            cap.resume()
            cap.setActive(true, now)
            // In chaos the platform sometimes loses the final releases too; the guards must clear what is left.
            val lose = chaos && rnd.nextInt(3) == 0
            if (!lose) {
                if (penState == 2) pen(PenAction.UP)
                if (penState >= 1) pen(PenAction.HOVER_EXIT)
            } else {
                t("final pen release lost by the platform")
            }
            penState = 0
            val loseAllFingers = chaos && rnd.nextInt(4) == 0 // e.g. both fingers of an open scroll
            for (id in fingers.keys.toList()) {
                val f = fingerFrame(TouchAction.UP, id)
                fingers.remove(id)
                if (loseAllFingers || (chaos && rnd.nextInt(3) == 0)) t("final finger UP $id lost by the platform") else touch(f)
            }
            advance(11_500) // past the 2 s hover guard, the 1 s gate, the 5 s scroll idle end and the 10 s guards
        }
    }

    private fun run(seed: Long, chaos: Boolean, congest: Boolean, steps: Int) {
        val w = World(seed, chaos, congest)
        for (i in 0 until steps) {
            w.step()
            try {
                w.check("seed=$seed chaos=$chaos congest=$congest step=$i")
            } catch (e: AssertionError) {
                throw AssertionError(
                    e.message + "\nEVENTS:\n" + w.trace.takeLast(30).joinToString("\n") +
                        "\nSENT:\n" + w.sink.sent.takeLast(12).joinToString("\n"), e,
                )
            }
        }
        w.quiesce()
        val h = w.sink.host
        assertTrue("seed=$seed: host still holds input: pen=${h.penInRange} contact=${h.penContact} touch=${h.touchDown} scroll=${h.scrollOpen}", !h.hasHeld)
        assertTrue("seed=$seed: violations ${h.violations}", h.violations.isEmpty())
        assertEquals("seed=$seed: refused presses", 0, w.sink.pressesRejected)
    }

    @Test fun wellFormedAndroidEventsNeverLeaveTheHostHoldingAnything() {
        for (seed in 1L..1500L) run(seed, chaos = false, congest = false, steps = 500)
    }

    @Test fun wellFormedEventsUnderBriefBackpressureNeverLeaveTheHostHoldingAnything() {
        for (seed in 5000L..6500L) run(seed, chaos = false, congest = true, steps = 500)
    }

    @Test fun lifecycleLossesConnectionDropsAndMalformedEventsNeverLeaveTheHostHoldingAnything() {
        for (seed in 1000L..3500L) run(seed, chaos = true, congest = false, steps = 500)
    }

    @Test fun chaosUnderBriefBackpressureNeverLeavesTheHostHoldingAnything() {
        for (seed in 9000L..10500L) run(seed, chaos = true, congest = true, steps = 500)
    }
}
