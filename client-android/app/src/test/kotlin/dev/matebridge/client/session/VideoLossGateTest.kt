package dev.matebridge.client.session

import dev.matebridge.client.input.FakeSink
import dev.matebridge.client.input.InputCapture
import dev.matebridge.client.input.KeyFrame
import dev.matebridge.client.input.PenAction
import dev.matebridge.client.input.VP
import dev.matebridge.client.input.downConfirmed
import dev.matebridge.client.input.penFrame
import dev.matebridge.client.input.pt
import dev.matebridge.client.protocol.Bytes
import dev.matebridge.client.protocol.Hello
import dev.matebridge.client.protocol.HelloAck
import dev.matebridge.client.protocol.Key
import dev.matebridge.client.protocol.Pong
import dev.matebridge.client.protocol.ReleaseAll
import dev.matebridge.client.protocol.StreamConfig
import dev.matebridge.client.session.SessionMachine.Action
import dev.matebridge.client.session.SessionMachine.Event
import dev.matebridge.client.video.DecodeProgress
import dev.matebridge.client.video.FaultCause
import dev.matebridge.client.video.HealthEvent
import dev.matebridge.client.video.VideoHealth
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * T-218 (decision 0019): a video-only loss closes input although the control session goes on. Pure mirror of the app:
 * [SessionMachine] actions as `SessionController.exec` routes them, [VideoHealth] and the renderer generations as
 * `MainActivity` drives them, and a real [InputCapture] whose activity follows `syncInputActive` (video health only;
 * the panels are hidden). The [FakeSink] host model shows what the Mac would still hold.
 */
class VideoLossGateTest {
    private val hello = Hello(0, Bytes(ByteArray(16) { it.toByte() }), 2800, 1840, 360, 144, 0xFF, "MatePad")
    private val ep = Endpoint("10.0.0.5", 7420)
    private val m = SessionMachine(hello)
    private var nowUs = 1_000_000_000L
    private val nowMs get() = nowUs / 1000

    private val sink = FakeSink()
    private val cap = InputCapture(sink, { VP })
    private val logs = ArrayList<String>()
    private val health = VideoHealth({ nowMs }, log = { l, ev, f -> logs += "$l $ev $f" }, onChange = { sync() })
    private val progress = DecodeProgress()
    private var rgen = 0
    private var ctl = -1
    private var video = -1
    private val actions = ArrayList<Action>()

    init {
        cap.setStreamGeometry(1400, 920)
    }

    /** `MainActivity.syncInputActive` with the stream visible: only the video health decides. */
    private fun sync() {
        sink.nowMs = nowMs
        cap.setActive(health.inputAllowed, nowMs)
    }

    /** `SessionController.dispatch` + the listener hops (the UI thread runs them in order). */
    private fun step(e: Event, advanceUs: Long = 0): List<Action> {
        nowUs += advanceUs
        sink.nowMs = nowMs
        val a = m.handle(e, nowUs)
        for (x in a) when (x) {
            is Action.OpenControl -> { ctl = x.gen; pendingOpen = true }
            is Action.CloseControl -> health.onEvent(HealthEvent.Detached(rgen)) // panel shown, releaseRenderer()
            is Action.OpenVideo -> video = x.gen
            is Action.ApplyConfig -> newGeneration() // installConfig -> reconfigure / attach
            is Action.VideoLost -> health.videoLost() // listener.onVideoLost
            else -> Unit
        }
        actions += a
        return a
    }

    private var pendingOpen = false

    /** The host accepts a (re)opened control connection (PAIRED) and sends its STREAM_CONFIG. */
    private fun acceptPending() {
        if (!pendingOpen) return
        pendingOpen = false
        step(Event.ControlOpened(ctl))
        step(Event.Received(ctl, HelloAck(0, HelloAck.ACCEPTED, 77, 7421, "Mac mini")))
        step(Event.Received(ctl, cfg(1)))
    }

    /** A renderer generation (attach / reconfigure / restartCodec) whose decoder thread runs. */
    private fun newGeneration() {
        rgen++
        progress.begin(rgen)
        health.onEvent(HealthEvent.Generation(rgen))
        health.onEvent(HealthEvent.Running(rgen))
    }

    /** One frame decoded by the current generation. */
    private fun decodeOne() {
        progress.onInput(rgen, nowMs)
        if (progress.onOutput(rgen)) health.onEvent(HealthEvent.FirstOutput(rgen))
    }

    private fun recover(a: VideoHealth.Action?) {
        when (a) {
            VideoHealth.Action.RESTART_CODEC -> newGeneration()
            VideoHealth.Action.RECONNECT -> step(Event.ControlClosed(ctl)) // dropConnection: the session reconnects
            null -> Unit
        }
    }

    /** The first frame of the current video connection reached the listener (`onVideoFlowing`). */
    private fun videoFlowing() = recover(health.videoFlowing())

    /**
     * The 100 ms engine tick with the host answering pings and accepting reconnects, plus the activity's 500 ms health
     * ticker. [onVideoOpen] runs for every video connection the session opens meanwhile.
     */
    private fun run(us: Long, onVideoOpen: (Int) -> Unit = {}) {
        var t = 0L
        while (t < us) {
            val v = video
            step(Event.Tick(0), 100_000)
            acceptPending()
            if (video != v) onVideoOpen(video)
            step(Event.Received(ctl, Pong(0, 0, 0)))
            t += 100_000
            if (t % 500_000 == 0L) recover(health.tick(progress.snapshot()))
        }
    }

    private fun cfg(id: Int) = StreamConfig(id, 1, 2800, 1840, 1400, 920, 60, 20000, 1, 1, 1, 1)

    private fun streaming() {
        step(Event.Start(ep))
        acceptPending()
        assertTrue(video >= 0)
        decodeOne()
        assertTrue(health.inputAllowed)
    }

    private fun keyDown() = cap.onKey(KeyFrame(7, 30, 29, true, 0, false, false, false, nowUs))

    /** Keys the host holds after replaying KEY and RELEASE_ALL in order. */
    private fun hostKeysHeld(): Set<Int> {
        val held = HashSet<Int>()
        for (msg in sink.sent) when (msg) {
            is Key -> if (msg.action == Key.DOWN) held += msg.scanCode else held -= msg.scanCode
            is ReleaseAll -> held.clear()
            else -> Unit
        }
        return held
    }

    @Test fun aVideoCloseOfAHealthySessionClosesInputAndReleasesEverythingInTheSameStep() {
        streaming()
        keyDown()
        cap.downConfirmed(penFrame(PenAction.DOWN, pt(nowMs)), nowMs)
        assertEquals(setOf(30), hostKeysHeld())
        assertTrue(sink.host.penContact)

        val a = step(Event.VideoClosed(video))
        assertEquals(listOf<Action>(Action.VideoLost(video)), a)
        // Right after this one event: input closed, the Mac holds nothing, RELEASE_ALL(USER) went out on the control link.
        assertFalse(health.inputAllowed)
        assertEquals(FaultCause.VIDEO_LOST, health.cause)
        assertTrue(hostKeysHeld().isEmpty())
        assertFalse(sink.host.penContact)
        assertTrue(sink.host.clear)
        assertEquals(ReleaseAll.USER, sink.sent.filterIsInstance<ReleaseAll>().last().reason)
        // The session itself is untouched, so those releases were not refused.
        assertTrue(m.inputAllowed)
        assertTrue(a.none { it is Action.Ui || it is Action.CloseControl })
    }

    @Test fun inputStaysClosedWithTheOverlayWhileTheVideoCannotReconnectAndPongsContinue() {
        streaming()
        step(Event.VideoClosed(video))
        val sentBefore = sink.sent.size
        var reopens = 0
        // 20 s: every video reconnect fails at once (port blocked), the control link answers every ping. The ladder
        // restarts the decoder twice, then rebuilds the session once (its video fails again), then waits for the user.
        run(20_000_000) { gen ->
            reopens++
            keyDown() // the user keeps typing on the frozen picture
            step(Event.VideoClosed(gen))
            keyDown()
            assertFalse(health.inputAllowed)
            assertTrue(health.showOverlay)
        }
        assertTrue("the video kept retrying ($reopens)", reopens >= 10)
        assertFalse(health.inputAllowed)
        assertTrue(health.showOverlay)
        assertTrue(health.manual)
        assertTrue("no keys reached the Mac", sink.sent.drop(sentBefore).none { it is Key })
        assertTrue(hostKeysHeld().isEmpty())
        assertEquals("one session rebuild (ladder +6 s)", 2, actions.count { it is Action.OpenControl })
        assertTrue("the control session is up", m.inputAllowed)
    }

    @Test fun whenTheVideoReturnsInputReopensOnlyAtTheFirstDecodedOutputAfterTheLoss() {
        streaming()
        val lostGen = rgen
        step(Event.VideoClosed(video))
        var flowed = false
        run(1_000_000) { _ -> videoFlowing(); flowed = true } // reconnect after 500 ms, its first frame arrives
        assertTrue(flowed)
        assertTrue("a new decoder generation", rgen > lostGen)
        assertFalse("STARTING until its first decoded output", health.inputAllowed)
        health.onEvent(HealthEvent.FirstOutput(lostGen)) // the old generation's late output does not count
        assertFalse(health.inputAllowed)
        decodeOne()
        assertTrue(health.inputAllowed)
        keyDown()
        assertEquals(setOf(30), hostKeysHeld())
    }

    @Test fun aStaticDesktopWithAnIntactVideoConnectionNeverClosesInput() {
        streaming()
        // 60 s without a single frame: nothing closes the video socket (keepalive probes are ACKed by the Mac).
        run(60_000_000)
        assertTrue(actions.none { it is Action.VideoLost })
        assertTrue(health.inputAllowed)
        assertFalse(health.showOverlay)
        keyDown()
        assertEquals(setOf(30), hostKeysHeld())
    }

    @Test fun aStaleOrReplacedVideoCloseIsNotALoss() {
        streaming()
        val old = video
        val a = step(Event.Received(ctl, cfg(2))) // reconfigure: CloseVideo + OpenVideo (the controller posts no close)
        assertTrue(a.any { it is Action.OpenVideo })
        decodeOne()
        assertTrue(step(Event.VideoClosed(old)).none { it is Action.VideoLost })
        assertTrue(health.inputAllowed)
    }

    @Test fun aSessionLossIsNotReportedAsAVideoLoss() {
        streaming()
        val v = video
        val lost = step(Event.ControlClosed(ctl))
        assertTrue(lost.any { it is Action.CloseVideo })
        assertTrue(step(Event.VideoClosed(v)).isEmpty()) // videoGen is gone with the session
    }
}
