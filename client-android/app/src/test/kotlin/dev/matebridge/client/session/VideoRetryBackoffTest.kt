package dev.matebridge.client.session

import dev.matebridge.client.protocol.Bytes
import dev.matebridge.client.protocol.Hello
import dev.matebridge.client.protocol.HelloAck
import dev.matebridge.client.protocol.Pong
import dev.matebridge.client.protocol.StreamConfig
import dev.matebridge.client.session.SessionMachine.Action
import dev.matebridge.client.session.SessionMachine.Event
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** T-294: the video reopen wait backs off while video connections close without a frame. */
class VideoRetryBackoffTest {
    private val hello = Hello(0, Bytes(ByteArray(16) { it.toByte() }), 2800, 1840, 360, 144, 0xFF, "MatePad")
    private val ep = Endpoint("10.0.0.5", 7420)
    private val logs = ArrayList<String>()
    private val m = SessionMachine(hello, log = { l, ev, f -> logs += "$l $ev $f" })
    private var nowUs = 1_000_000_000L
    private var ctl = -1
    private var video = -1
    private var frames = 0L

    private fun step(e: Event, advanceUs: Long = 0): List<Action> {
        nowUs += advanceUs
        val a = m.handle(e, nowUs)
        for (x in a) when (x) {
            is Action.OpenControl -> ctl = x.gen
            is Action.OpenVideo -> video = x.gen
            else -> Unit
        }
        return a
    }

    private fun streaming() {
        step(Event.Start(ep))
        step(Event.ControlOpened(ctl))
        step(Event.Received(ctl, HelloAck(0, HelloAck.ACCEPTED, 77, 7421, "Mac mini")))
        step(Event.Received(ctl, StreamConfig(1, 1, 2800, 1840, 1400, 920, 60, 20000, 1, 1, 1, 1)))
        assertTrue(video >= 0)
    }

    /** Closes the current video connection and returns the microseconds until it reopens (ticks every 100 ms, pongs on). */
    private fun closeAndWaitReopen(): Long {
        val before = video
        step(Event.VideoClosed(video))
        var t = 0L
        while (video == before) {
            step(Event.Tick(frames), 100_000)
            step(Event.Received(ctl, Pong(0, 0, 0)))
            t += 100_000
            assertTrue("reopen within 5 s", t <= 5_000_000)
        }
        return t
    }

    @Test fun delayFunctionStepsAndCaps() {
        val d = (0..9).map { SessionMachine.videoRetryDelayUs(it) / 1000 }
        assertEquals(listOf(500L, 500, 500, 500, 1000, 2000, 4000, 4000, 4000, 4000), d)
    }

    @Test fun firstThreeRetriesAreFiveHundredMsThenBackoffToFourSeconds() {
        streaming()
        val waits = (1..8).map { closeAndWaitReopen() / 1000 }
        assertEquals(listOf(500L, 500, 500, 1000, 2000, 4000, 4000, 4000), waits)
        // Logged only when the step changes.
        val lines = logs.filter { it.contains("video_retry") }
        assertEquals(
            listOf(
                "I video_retry backoff_ms=1000 empty=4",
                "I video_retry backoff_ms=2000 empty=5",
                "I video_retry backoff_ms=4000 empty=6",
            ),
            lines,
        )
    }

    @Test fun aFrameResetsTheBackoff() {
        streaming()
        repeat(6) { closeAndWaitReopen() }
        // The open connection delivers a frame, then closes.
        step(Event.VideoFirstFrame(video))
        assertEquals("I video_retry backoff_ms=500 empty=0", logs.last())
        assertEquals(500L, closeAndWaitReopen() / 1000)
        // A streak starts anew: three empty closes stay at 500 ms, the fourth backs off.
        assertEquals(listOf(500L, 500, 500), (1..3).map { closeAndWaitReopen() / 1000 })
        assertEquals(1000L, closeAndWaitReopen() / 1000)
    }

    /** T-294 review P2: frame, then close before any tick or first-frame event is handled: not empty. */
    @Test fun aFrameThenACloseBeforeTheFirstFrameEventDoesNotBackOff() {
        streaming()
        repeat(6) { closeAndWaitReopen() } // 4 s backoff reached
        val before = video
        step(Event.VideoClosed(video, gotFrame = true))
        var t = 0L
        while (video == before) {
            step(Event.Tick(frames), 100_000)
            step(Event.Received(ctl, Pong(0, 0, 0)))
            t += 100_000
            assertTrue("reopen within 5 s", t <= 5_000_000)
        }
        assertEquals(500_000L, t)
        assertEquals("I video_retry backoff_ms=500 empty=0", logs.last())
    }

    /** A first-frame event of an older connection does not mark the current one. */
    /** T-294 review round 2: "Yeniden dene" clears the streak and pulls a pending retry forward to 500 ms. */
    @Test fun retryTapResetsTheStreakAndPullsThePendingRetryForward() {
        streaming()
        repeat(6) { closeAndWaitReopen() }
        // Close again: the next reopen is 4 s away. 1 s later the user taps.
        val before = video
        step(Event.VideoClosed(video))
        repeat(10) { step(Event.Tick(frames), 100_000); step(Event.Received(ctl, Pong(0, 0, 0))) }
        assertEquals(before, video)
        step(Event.ResetVideoBackoff)
        assertEquals("I video_retry backoff_ms=500 empty=0", logs.last())
        var t = 0L
        while (video == before) {
            step(Event.Tick(frames), 100_000)
            step(Event.Received(ctl, Pong(0, 0, 0)))
            t += 100_000
            assertTrue("reopen within 1 s", t <= 1_000_000)
        }
        assertTrue("at most 500 ms after the tap (+ one tick): $t", t <= 600_000)
        // The streak starts anew.
        assertEquals(listOf(500L, 500, 500), (1..3).map { closeAndWaitReopen() / 1000 })
        assertEquals(1000L, closeAndWaitReopen() / 1000)
    }

    @Test fun aRetryTapDoesNotDelayAnEarlierRetry() {
        streaming()
        val before = video
        step(Event.VideoClosed(video)) // 500 ms wait
        step(Event.Tick(frames), 100_000)
        step(Event.ResetVideoBackoff)
        var t = 100_000L
        while (video == before) {
            step(Event.Tick(frames), 100_000)
            step(Event.Received(ctl, Pong(0, 0, 0)))
            t += 100_000
            assertTrue(t <= 1_000_000)
        }
        assertTrue("not later than the original 500 ms: $t", t <= 600_000)
    }

    @Test fun aStaleFirstFrameEventIsIgnored() {
        streaming()
        val old = video
        closeAndWaitReopen()
        step(Event.VideoFirstFrame(old))
        repeat(2) { closeAndWaitReopen() } // empty = 3 so far
        assertEquals(1000L, closeAndWaitReopen() / 1000) // the 4th empty close backs off
    }

    @Test fun aStaleCloseOfAnOlderConnectionDoesNotCount() {
        streaming()
        val old = video
        closeAndWaitReopen()
        repeat(5) { step(Event.VideoClosed(old)) }
        assertEquals(500L, closeAndWaitReopen() / 1000) // empty = 2 only
    }
}
