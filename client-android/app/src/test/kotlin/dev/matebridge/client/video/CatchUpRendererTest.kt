package dev.matebridge.client.video

import dev.matebridge.client.protocol.Bytes
import dev.matebridge.client.protocol.KeyframeRequest
import dev.matebridge.client.protocol.StreamConfig
import dev.matebridge.client.protocol.VideoFrame
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.CountDownLatch
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * T-252 end to end on the real [VideoRenderer] threads with the fake codec: the input thread is held while a backlog
 * builds (more than the normal depth), then released. Every frame is decoded in order, only the newest is rendered, the
 * others are released without rendering, and no keyframe request goes out beyond the startup one.
 */
class CatchUpRendererTest {
    private val config = StreamConfig(1, StreamConfig.CODEC_HEVC, 2800, 1840, 1400, 920, 60, 50000, 1, 13, 1, 1)
    private val factory = FakeDecoderFactory().also { it.produceOutput = true }
    private val env = TestDecoderEnv()
    private val requests = CopyOnWriteArrayList<Int>()
    private val renderers = CopyOnWriteArrayList<VideoRenderer>()
    private val gate = CountDownLatch(1)

    private fun make(catchUp: Boolean = true) = VideoRenderer(
        config, onKeyframeRequest = { requests.add(it) }, codecFactory = factory, env = env,
    ).also { it.catchUp = catchUp; renderers.add(it) }

    @After fun tearDown() {
        gate.countDown()
        for (r in renderers) r.detachSurface()
    }

    private fun frame(seq: Long, flags: Int = 0) = VideoFrame(seq, seq * 1000, flags, 0, 1, 3, Bytes(byteArrayOf(0, 0, 1)))

    /** Attaches, holds the input thread, feeds config + keyframe + [p] P frames, releases the thread. */
    private fun backlog(r: VideoRenderer, p: Int): FakeDecoderFactory.Codec {
        factory.dequeueInputGate = gate
        r.attachTarget(Any())
        assertTrue(factory.awaitEvent("dequeueInput#1>"))
        r.onFrame(frame(0, VideoFrame.CODEC_CONFIG))
        r.onFrame(frame(1, VideoFrame.KEYFRAME))
        for (i in 0 until p) r.onFrame(frame(2L + i))
        gate.countDown()
        return factory.codecs[0]
    }

    @Test fun aBacklogIsDecodedInOrderAndOnlyTheNewestFrameIsRendered() {
        val r = make()
        val codec = backlog(r, 14) // 15 non-config frames > normal depth 4 (60 fps), inside the 30-frame backlog bound
        val total = 15
        assertTrue("outputs", factory.await { outputsDequeued >= total })
        assertTrue("all released", factory.await { codec.renderedPts.size + codec.discardedPts.size >= total })
        assertEquals("every frame decoded in order", listOf(0L) + (1L..15L).toList(), codec.inputPts.toList())
        // pending 15..2 are skipped (the 50 ms rule may show some), the newest frame (15) is the TAIL
        assertEquals("the newest frame is rendered last", 15L, codec.renderedPts.toList().last())
        assertEquals("every frame released once", (1L..15L).toList(), (codec.renderedPts + codec.discardedPts).sorted())
        assertEquals("only the startup request", listOf(KeyframeRequest.STARTUP), requests.toList())
        assertFalse(r.isWaitingKeyframe())
        assertTrue(env.awaitLines("catch_up"))
        assertTrue(env.lines("catch_up").single().contains("frames=15"))
        val fields = r.queueStatsFields(reset = false)
        assertTrue(fields, fields.contains("catchups=1 cu_skipped=${codec.discardedPts.size} "))
    }

    @Test fun framesAfterTheCatchUpAreRenderedNormally() {
        val r = make()
        val codec = backlog(r, 14)
        assertTrue(factory.await { codec.renderedPts.size + codec.discardedPts.size >= 15 })
        r.onFrame(frame(100))
        assertTrue("next frame rendered", factory.await { codec.renderedPts.contains(100L) })
        assertEquals(listOf(15L, 100L), codec.renderedPts.toList().takeLast(2))
    }

    @Test fun withCatchUpOffTheBacklogIsFlushedAndAKeyframeIsRequested() {
        val r = make(catchUp = false)
        val codec = backlog(r, 14)
        assertTrue(factory.await { codec.inputPts.isNotEmpty() })
        // the request itself is held by the T-121 hold-off after the startup request; the gate is the proof
        assertTrue(r.isWaitingKeyframe())
        assertTrue(r.queueStatsFields(reset = false).contains("overflows=1"))
        assertTrue(r.queueStatsFields(reset = false).contains("catchups=0"))
    }

    @Test fun aBacklogBeyondTheBoundIsFlushedAsBefore() {
        val r = make()
        backlog(r, 40) // above the 30-frame bound at 60 fps
        assertTrue(r.isWaitingKeyframe())
        assertTrue(r.queueStatsFields(reset = false).contains("overflows=1 "))
    }

    @Test fun delayedOutputsStillPresentAtLeastEvery50msDuringTheCatchUp() {
        factory.outputSpacingMs = 20 // the codec swallows all inputs at once and emits the outputs 20 ms apart
        val r = make()
        val codec = backlog(r, 14)
        assertTrue("all released", factory.await(10_000) { codec.renderedPts.size + codec.discardedPts.size >= 15 })
        val shown = codec.renderedPts.toList()
        assertEquals("the newest frame is shown last", 15L, shown.last())
        assertEquals("shown frames keep their order", shown.sorted(), shown)
        assertTrue("display stood still: only $shown shown over ~300 ms of outputs", shown.size >= 3)
        assertEquals(listOf(KeyframeRequest.STARTUP), requests.toList())
    }
}
