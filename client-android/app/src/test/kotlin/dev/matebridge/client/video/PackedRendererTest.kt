package dev.matebridge.client.video

import dev.matebridge.client.protocol.Bytes
import dev.matebridge.client.protocol.StreamConfig
import dev.matebridge.client.protocol.VideoFrame
import java.util.concurrent.CopyOnWriteArrayList
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * T-259 (decision 0034): the main stream's hook into the real [VideoRenderer] threads. With a [PackedOutput] set a decoded
 * frame is released to the (ImageReader) surface at once and the presenter is told its target first; with none, the
 * renderer is the direct path (the other renderer tests cover it byte for byte).
 */
class PackedRendererTest {
    private val config = StreamConfig(1, StreamConfig.CODEC_HEVC, 2800, 1840, 1400, 920, 60, 30000, 1, 13, 1, 1, 1)
    private val factory = FakeDecoderFactory().also { it.produceOutput = true }
    private val env = TestDecoderEnv()
    private var renderer: VideoRenderer? = null

    private class Hook : PackedOutput {
        val calls = CopyOnWriteArrayList<Triple<Long, Long?, Long>>()
        override fun onRelease(pts: Long, captureUs: Long?, renderNs: Long) { calls.add(Triple(pts, captureUs, renderNs)) }
        override val extraLeadNs: Long = 4_000_000L
    }

    @After fun tearDown() { renderer?.detachSurface() }

    private fun frame(seq: Long, flags: Int = 0) = VideoFrame(seq, 5_000 + seq * 1000, flags, 0, 1, 3, Bytes(byteArrayOf(0, 0, 1)))

    private fun make(hook: PackedOutput?, buffer: Int = 0): VideoRenderer =
        VideoRenderer(config, onKeyframeRequest = {}, bufferFrames = buffer, codecFactory = factory, env = env,
            restartDelaysMs = longArrayOf(60_000, 60_000, 60_000)).also { it.packed = hook; renderer = it }

    @Test fun packedReleasesToTheReaderAtOnceAndAnnouncesTheTarget() {
        val hook = Hook()
        val r = make(hook)
        r.attachTarget(Any())
        r.onFrame(frame(0, VideoFrame.CODEC_CONFIG))
        r.onFrame(frame(7, VideoFrame.KEYFRAME))
        assertTrue(factory.await { outputsDequeued >= 1 })
        assertTrue(factory.await { codecs.single().renderedPts.isNotEmpty() })
        assertEquals(listOf(7L), factory.codecs.single().renderedPts.toList())
        // the presenter hears about frame_seq 7 and its capture time before/with the release
        assertTrue(hook.calls.isNotEmpty())
        val (pts, capture, renderNs) = hook.calls.first()
        assertEquals(7L, pts)
        assertEquals(5_000L + 7_000L, capture)
        assertEquals(0L, renderNs) // buffer 0: rendered at once
    }

    @Test fun packedFormatCarriesNoColourKeys() {
        val r = make(Hook())
        r.attachTarget(Any())
        assertTrue(env.awaitLines("codec_start"))
        val keys = factory.codecs.single().format!!.integers.keys
        assertFalse(keys.any { it.startsWith("color-") })
        assertTrue(keys.contains("priority"))
    }

    @Test fun directPathStillTagsTheDecoder() {
        val r = make(null)
        r.attachTarget(Any())
        assertTrue(env.awaitLines("codec_start"))
        val keys = factory.codecs.single().format!!.integers.keys
        assertTrue(keys.containsAll(listOf("color-standard", "color-transfer", "color-range")))
    }

    @Test fun directPathNeverCallsAHook() {
        val hook = Hook()
        val r = make(null)
        r.attachTarget(Any())
        r.onFrame(frame(0, VideoFrame.CODEC_CONFIG))
        r.onFrame(frame(1, VideoFrame.KEYFRAME))
        assertTrue(factory.await { codecs.single().renderedPts.isNotEmpty() })
        assertTrue(hook.calls.isEmpty())
    }

    @Test fun packedShownTimesFeedTheScreenLatencyStats() {
        val r = make(Hook())
        r.stats.latencyOf = { cap, at -> at - cap }
        r.attachTarget(Any())
        r.onFrame(frame(0, VideoFrame.CODEC_CONFIG))
        r.onFrame(frame(3, VideoFrame.KEYFRAME))
        assertTrue(factory.await { codecs.single().renderedPts.isNotEmpty() })
        assertEquals(0, r.stats.snapshot(reset = false).capCb.count)
        r.reportPackedShown(3L, System.nanoTime())
        val cb = r.stats.snapshot(reset = false).capCb
        assertEquals(1, cb.count)
    }

    @Test fun reportingForAStoppedRendererIsHarmless() {
        val r = make(Hook())
        r.reportPackedShown(1L, System.nanoTime()) // no codec yet: nothing to feed
        assertEquals(0, r.stats.snapshot(reset = false).capCb.count)
    }
}
