package dev.matebridge.client.video

import dev.matebridge.client.protocol.Bytes
import dev.matebridge.client.protocol.StreamConfig
import dev.matebridge.client.protocol.VideoFrame
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * T-219 (astra P1 #2): a retired generation's input loop must not consume the next generation's frames. The barrier
 * holds generation 1's input thread after its `att.active` check while a reconfigure retires it, starts generation 2
 * and the host's answer (new CODEC_CONFIG + keyframe) arrives. Every gate is opened in `finally` and in [tearDown].
 * Two barriers: before the queue wait (fake `dequeueInputBuffer` in `prefetch`) and inside it (right before the park).
 */
class DecoderQueueOwnershipTest {
    private val config = StreamConfig(1, StreamConfig.CODEC_HEVC, 2800, 1840, 1400, 920, 60, 50000, 1, 13, 1, 1)
    private val newConfig = config.copy(configId = 2, fps = 120)
    private val factory = FakeDecoderFactory()
    private val env = TestDecoderEnv()
    private val health = DecoderTeardownTest.HealthEvents()
    private val renderers = CopyOnWriteArrayList<VideoRenderer>()
    private val renderer = make()

    private fun make() = VideoRenderer(
        config,
        onKeyframeRequest = {},
        codecFactory = factory,
        env = env,
        onHealthEvent = health::add,
    ).also { renderers.add(it) }

    private val parkRelease = CountDownLatch(1)

    @After fun tearDown() {
        factory.dequeueInputGate?.countDown()
        parkRelease.countDown()
        for (r in renderers) r.detachSurface()
    }

    @Test fun aRetiredInputLoopPastItsActiveCheckNeverTakesTheNextGenerationsStartupFrames() {
        val gate = CountDownLatch(1)
        factory.dequeueInputGate = gate // generation 1's first prefetch blocks: it already passed `att.active`
        renderer.attachTarget(Any())
        try {
            assertTrue("generation 1 never reached its input wait", factory.awaitEvent("dequeueInput#1>"))
            renderer.reconfigure(newConfig) // generation 2 waits in the hand-off until generation 1 has exited
            renderer.onFrame(frame(10, VideoFrame.CODEC_CONFIG))
            renderer.onFrame(frame(11, VideoFrame.KEYFRAME))
        } finally {
            gate.countDown() // generation 1 resumes, retired, with generation 2's frames in the queue
        }
        assertTrue("generation 2 never started a codec", factory.awaitEvent("start#2"))
        factory.await(2_000) { codecs.size >= 2 && codecs[1].inputPts.size >= 2 }
        assertEquals("the retired generation submitted the next generation's frames",
            emptyList<Long>(), factory.codecs[0].inputPts.toList())
        assertEquals("generation 2's startup frames", listOf(10L, 11L), factory.codecs[1].inputPts.toList())
    }

    @Test fun aRetiredInputLoopParkedInTheQueueWaitWakesWithNothingAndTheNextGenerationGetsItsFrames() {
        renderer.attachTarget(Any())
        assertTrue(env.awaitLines("codec_start"))
        renderer.onFrame(frame(0, VideoFrame.CODEC_CONFIG))
        renderer.onFrame(frame(1, VideoFrame.KEYFRAME))
        assertTrue("generation 1 never decoded its own frames",
            factory.await { codecs.isNotEmpty() && codecs[0].inputPts.size >= 2 })

        val parked = CountDownLatch(1)
        renderer.inputParkHook = { // generation 1's input thread, inside awaitNext, about to park
            if (parkRelease.count > 0) { parked.countDown(); parkRelease.await(10, TimeUnit.SECONDS) }
        }
        try {
            assertTrue("generation 1 never parked in the queue wait", parked.await(5, TimeUnit.SECONDS))
            renderer.reconfigure(newConfig)
            renderer.onFrame(frame(10, VideoFrame.CODEC_CONFIG)) // unparks the waiter (generation 1)
            renderer.onFrame(frame(11, VideoFrame.KEYFRAME))
        } finally {
            parkRelease.countDown() // the park returns at once (permit); generation 1 looks at the queue again
        }
        assertTrue("generation 2 never started a codec", factory.awaitEvent("start#2"))
        factory.await(2_000) { codecs.size >= 2 && codecs[1].inputPts.size >= 2 }
        assertEquals("generation 1 got only its own frames", listOf(0L, 1L), factory.codecs[0].inputPts.toList())
        assertEquals("generation 2's startup frames", listOf(10L, 11L), factory.codecs[1].inputPts.toList())
        assertNotNull(health.await { it == HealthEvent.Running(2) })
    }

    private fun frame(seq: Long, flags: Int) = VideoFrame(seq, seq * 1000, flags, 0, 1, 3, Bytes(byteArrayOf(0, 0, 1)))
}
