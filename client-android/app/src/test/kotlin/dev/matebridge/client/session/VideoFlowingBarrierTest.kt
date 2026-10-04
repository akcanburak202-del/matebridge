package dev.matebridge.client.session

import dev.matebridge.client.protocol.StreamConfig
import dev.matebridge.client.protocol.VideoHello
import dev.matebridge.client.session.SessionMachine.Action
import dev.matebridge.client.video.HealthEvent
import dev.matebridge.client.video.VideoHealth
import java.util.Collections
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * T-218 review P2: the "first frame of a video connection" notification ([deliverVideoFrame] → `onVideoFlowing`) is
 * serialized with the connection's retirement by the T-160 delivery barrier, and the UI drops a stale one by video
 * generation. A replaced reader can therefore never restart the current decoder or postpone its recovery.
 */
class VideoFlowingBarrierTest {
    private val gate = VideoDeliveryGate()
    private val videoEp = Endpoint("10.0.0.5", 7421)
    private val cfg = StreamConfig(1, StreamConfig.CODEC_HEVC, 2800, 1840, 1400, 920, 60, 20000, 1, 1, 1, 1)

    /** What the UI thread receives, in posting order (`runOnUiThread` from the reader and the engine). */
    private val ui = Collections.synchronizedList(ArrayList<String>())

    private fun open(gen: Int) {
        gate.onAction(Action.CloseVideo)
        gate.onAction(Action.OpenVideo(gen, videoEp, VideoHello(0, 1, 77)))
    }

    private fun awaitBlocked(t: Thread): Boolean {
        val deadline = System.nanoTime() + 5_000_000_000L
        while (System.nanoTime() < deadline) {
            when (t.state) {
                Thread.State.BLOCKED, Thread.State.WAITING, Thread.State.TIMED_WAITING -> return true
                Thread.State.TERMINATED -> return false
                else -> Thread.sleep(1)
            }
        }
        return false
    }

    @Test fun aHeldReadersFirstFrameNoticeIsOutBeforeItsReplacementAndIsDroppedAsStale() {
        gate.onAction(Action.ApplyConfig(cfg))
        gate.install(cfg)
        open(5)
        // Reader of connection 5: its first frame is inside the delivery and held there.
        val inDelivery = CountDownLatch(1)
        val release = CountDownLatch(1)
        val reader = Thread {
            deliverVideoFrame(gate, 5, 1, first = true, frame = { inDelivery.countDown(); release.await() }) {
                ui += "flowing 5"
            }
        }
        reader.start()
        assertTrue(inDelivery.await(5, TimeUnit.SECONDS))
        // Engine: connection 5 is replaced by 7 (abort + CloseVideo/OpenVideo). It waits for the delivery in flight.
        val engine = Thread {
            gate.close(5)
            open(7)
            ui += "lost 7" // connection 7 fails at once: VideoLost(7) is posted after the replacement returned
        }
        engine.start()
        try {
            assertTrue("the replacement returned while the old reader was delivering", awaitBlocked(engine))
            assertFalse("lost 7" in ui)
        } finally {
            release.countDown()
        }
        reader.join(5_000)
        engine.join(5_000)
        assertEquals("the old reader's notice can only come before its replacement", listOf("flowing 5", "lost 7"), ui.toList())
        // After the replacement nothing of connection 5 is delivered or announced any more.
        var announced = false
        assertFalse(deliverVideoFrame(gate, 5, 1, first = true, frame = {}) { announced = true })
        assertFalse(announced)

        // The UI consumes them in order; a notice that is consumed late anyway is not newer than the lost connection.
        var now = 0L
        val health = VideoHealth({ now })
        health.onEvent(HealthEvent.Generation(1)); health.onEvent(HealthEvent.Running(1)); health.onEvent(HealthEvent.FirstOutput(1))
        health.videoLost(7)
        assertNull("stale: connection 5 was replaced before 7 was lost", health.videoFlowing(5))
        assertNull("the lost connection itself is not fresh video", health.videoFlowing(7))
        assertEquals(VideoHealth.State.FAULT, health.state)
        now += 1000
        assertEquals("the ladder is not postponed by the stale notice", VideoHealth.Action.RESTART_CODEC, health.tick(null))
        health.onEvent(HealthEvent.Generation(2)); health.onEvent(HealthEvent.Running(2))
        assertNull("STARTING after the ladder's restart: it is fed already", health.videoFlowing(9))
        health.videoLost(9)
        assertEquals(VideoHealth.Action.RESTART_CODEC, health.videoFlowing(11)) // a newer connection resumes
    }

    @Test fun onlyTheFirstDeliveredFrameAnnounces() {
        gate.onAction(Action.ApplyConfig(cfg))
        gate.install(cfg)
        open(3)
        var n = 0
        assertTrue(deliverVideoFrame(gate, 3, 1, first = true, frame = {}) { n++ })
        assertTrue(deliverVideoFrame(gate, 3, 1, first = false, frame = {}) { n++ })
        assertEquals(1, n)
        // A frame the gate refuses (not the open connection) announces nothing.
        assertFalse(deliverVideoFrame(gate, 2, 1, first = true, frame = {}) { n++ })
        assertEquals(1, n)
    }
}
