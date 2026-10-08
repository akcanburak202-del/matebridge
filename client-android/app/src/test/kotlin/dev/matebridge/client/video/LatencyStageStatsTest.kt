package dev.matebridge.client.video

import dev.matebridge.client.protocol.Bytes
import dev.matebridge.client.protocol.StreamConfig
import dev.matebridge.client.protocol.VideoFrame
import java.util.concurrent.locks.LockSupport
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

/** T-168: signed latency stages from the capture stamp, stale per-frame maps, released vs discarded frames. */
class LatencyStageStatsTest {
    /** Offset 0: the latency is client time minus capture time. */
    private fun stats() = VideoStats().also { it.latencyOf = { cap, at -> at - cap } }

    @Test fun staleHighKeysDoNotStarveANewStreamStartingAtZero() {
        val s = stats()
        // Stream 1: 70 frames handed to the decoder but never output (lost in a codec teardown), high frame_seq.
        for (i in 0L until 70) s.onInput(10_000 + i, 1_000 + i, captureTimeUs = 500 + i)
        // Stream 2 restarts frame_seq at 0; even without a boundary call its first frames are timed.
        for (i in 0L until 5) {
            s.onInput(i, 10_000 + i * 100, captureTimeUs = 20_000 + i * 100)
            s.onOutput(i, 12_000 + i * 100, clientUs = 30_000 + i * 100)
        }
        val snap = s.snapshot()
        assertEquals(5L, snap.decoded)
        assertEquals(5, snap.decode.count)
        assertEquals(2_000L, snap.decodeTimeAvgUs)
        assertEquals(5, snap.capDec.count)
        assertEquals(10_000L, snap.latencyAvgUs)
    }

    @Test fun resetFramesForgetsThePreviousStreamsEntries() {
        val s = stats()
        s.onInput(0, 1_000, captureTimeUs = 100)
        s.resetFrames() // codec start of the next stream
        s.onOutput(0, 2_000, clientUs = 9_000) // the new stream's frame 0 never had its input stamped here
        var snap = s.snapshot()
        assertEquals(1L, snap.decoded)
        assertEquals(0, snap.decode.count)
        assertNull(snap.latencyAvgUs)
        // closeWindow (stream boundary) clears them too.
        s.onInput(1, 1_000, captureTimeUs = 100)
        s.closeWindow()
        s.onOutput(1, 2_000, clientUs = 9_000)
        snap = s.snapshot()
        assertEquals(0, snap.capDec.count)
    }

    @Test fun negativeSamplesAreCountedAndKeptWhileTheStatsMeanStaysClamped() {
        val s = stats()
        s.onInput(1, 0, captureTimeUs = 10_000); s.onOutput(1, 1_000, clientUs = 7_000) // -3 ms
        s.onInput(2, 0, captureTimeUs = 10_000); s.onOutput(2, 1_000, clientUs = 15_000) // +5 ms
        val snap = s.snapshot()
        assertEquals(1L, snap.latNeg)
        assertEquals(2, snap.capDec.count)
        assertEquals(-3_000L, snap.capDec.p50Us)
        assertEquals(5_000L, snap.capDec.maxUs)
        assertEquals("STATS latency_avg_us / A/V input: mean of clamped samples", 2_500L, snap.latencyAvgUs)
    }

    @Test fun onlyReleasedFramesFeedCaptureToRelease() {
        val s = stats()
        s.onReleased(1, 1_000, 21_000)
        s.onDiscarded()
        s.onReleased(2, 2_000, 24_000)
        s.onReleased(null, null, 25_000) // a buffer without a known frame: counted only
        val snap = s.snapshot()
        assertEquals(3L, snap.rendered)
        assertEquals(1L, snap.discarded)
        assertEquals(1L, snap.dropped)
        assertEquals(2, snap.capRel.count)
        assertEquals(20_000L, snap.capRel.p50Us)
        assertEquals(22_000L, snap.capRel.maxUs)
    }

    @Test fun missingRenderCallbacksAreCountedInReleaseOrder() {
        val s = stats()
        for (p in 1L..3) { s.awaitCallback(p); s.onReleased(p, 0, 10_000 + p) }
        s.onRenderCallback(1, 0, 20_000)
        s.onRenderCallback(3, 0, 22_000) // frame 2 was released before 3 but never got its callback
        s.onRenderCallback(2, 0, 23_000) // late and out of order: only a latency sample
        val snap = s.snapshot()
        assertEquals(1L, snap.renderCbMissing)
        assertEquals(3, snap.capCb.count)
        assertEquals(23_000L, snap.capCb.maxUs)
    }

    @Test fun awaitedCallbacksAreBoundedAndOverflowCountsAsMissing() {
        val s = stats()
        for (p in 0L until VideoStats.FRAME_MAP_MAX + 6L) { s.awaitCallback(p); s.onReleased(p, 0, 1_000) }
        assertEquals(6L, s.snapshot().renderCbMissing)
        // Without codec callbacks (GL path) nothing is awaited.
        val g = stats()
        for (p in 0L until 100) g.onReleased(p, 0, 1_000)
        assertEquals(0L, g.snapshot().renderCbMissing)
    }

    /** Review (P2): the main-looper callback may run before `releaseOutputBuffer` returns. */
    @Test fun aCallbackBeforeTheReleaseReturnsIsNotLaterCountedMissing() {
        val s = stats()
        s.awaitCallback(1) // registered before the release call
        s.onRenderCallback(1, 0, 9_000) // the callback overtakes the release's return
        s.onReleased(1, 0, 10_000)
        s.awaitCallback(2); s.onReleased(2, 0, 20_000)
        s.onRenderCallback(2, 0, 21_000)
        for (p in 3L..VideoStats.FRAME_MAP_MAX + 2L) { s.awaitCallback(p); s.onReleased(p, 0, 30_000); s.onRenderCallback(p, 0, 31_000) }
        val snap = s.snapshot()
        assertEquals(0L, snap.renderCbMissing)
        assertEquals(VideoStats.FRAME_MAP_MAX + 2, snap.capCb.count)
    }

    @Test fun aReleaseThatThrowsTakesItsRegistrationBack() {
        val s = stats()
        s.awaitCallback(1)
        s.cancelCallback(1) // releaseOutputBuffer threw: no frame went out
        s.awaitCallback(2); s.onReleased(2, 0, 1_000)
        s.onRenderCallback(2, 0, 2_000)
        val snap = s.snapshot()
        assertEquals(0L, snap.renderCbMissing)
        assertEquals(1L, snap.rendered)
    }

    @Test fun stagesJoinTheLogWindowExactly() {
        val s = stats()
        s.onReadySlot(14_000); s.onDiscarded()
        s.onInput(1, 0, captureTimeUs = 10_000); s.onOutput(1, 1_000, clientUs = 9_000)
        s.snapshot(reset = true)
        s.onReadySlot(16_000); s.onReadySlot(13_000)
        s.snapshot(reset = true)
        val log = s.logSnapshot(reset = true)
        assertEquals(3, log.readySlot.count)
        assertEquals(14_000L, log.readySlot.p50Us)
        assertEquals(16_000L, log.readySlot.maxUs)
        assertEquals(1L, log.discarded)
        assertEquals(1L, log.latNeg)
        assertEquals(-1_000L, log.capDec.maxUs)
        assertEquals(0, s.logSnapshot().readySlot.count)
    }
}

class IntervalHistogramMaxTest {
    @Test fun maxIsExactSignedAndCarriedIntoTheLongerWindow() {
        val h = IntervalHistogram()
        val log = IntervalHistogram()
        h.record(-5); h.record(-2)
        assertEquals(-2L, h.summary().maxUs)
        h.summaryInto(log)
        h.record(7)
        assertEquals(7L, h.summary().maxUs)
        h.summaryInto(log)
        val s = log.summary(reset = true)
        assertEquals(3, s.count)
        assertEquals(7L, s.maxUs)
        assertEquals(-2L, s.p50Us)
        assertEquals(IntervalSummary.EMPTY, log.summary())
        // Past the sample cap the maximum stays exact.
        val big = IntervalHistogram()
        for (i in 0 until IntervalHistogram.MAX_SAMPLES) big.record(1)
        big.record(99)
        assertEquals(99L, big.summary().maxUs)
    }
}

/** T-168 through the real renderer threads ([FakeDecoderFactory]): hardware flags and per-release samples. */
class LatencyStageRendererTest {
    private val config = StreamConfig(1, StreamConfig.CODEC_HEVC, 2800, 1840, 1400, 920, 60, 50000, 1, 13, 1, 1)
    private val factory = FakeDecoderFactory()
    private val env = TestDecoderEnv()
    private val renderer = VideoRenderer(config, onKeyframeRequest = {}, codecFactory = factory, env = env)

    @After fun tearDown() = renderer.detachSurface()

    private fun frame(seq: Long, flags: Int) = VideoFrame(seq, seq * 1000, flags, 0, 1, 3, Bytes(byteArrayOf(0, 0, 1)))

    private fun awaitTrue(what: String, cond: () -> Boolean) {
        val deadline = System.nanoTime() + 5_000_000_000L
        while (!cond()) {
            if (System.nanoTime() > deadline) fail(what)
            LockSupport.parkNanos(1_000_000L)
        }
    }

    @Test fun codecStartLogsAHardwareDecoder() {
        renderer.attachTarget(Any())
        assertTrue(env.awaitLines("codec_start"))
        val line = env.lines("codec_start").single()
        // T-217: `lowlat=` `oprate=` sit between `sw_only=` and `accepted`.
        assertTrue(line, line.contains(" requested_rate=") && line.contains(" is_hw=1 sw_only=0 lowlat=off oprate=max accepted "))
        assertEquals(0, env.lines("codec_software").size)
    }

    @Test fun aSoftwareDecoderWarnsOncePerCodecStart() {
        factory.hardware = false
        factory.softwareOnly = true
        renderer.attachTarget(Any())
        assertTrue(env.awaitLines("codec_start"))
        renderer.restartCodec()
        assertTrue(env.awaitLines("codec_start", count = 2))
        assertTrue(env.awaitLines("codec_software", count = 2))
        val w = env.lines("codec_software")
        assertEquals(2, w.size)
        assertTrue(w[0], w[0].contains(" W decoder ev=codec_software name=fake.decoder mime=video/hevc is_hw=0 sw_only=1"))
        assertTrue(env.lines("codec_start")[0].contains(" is_hw=0 sw_only=1 "))
    }

    @Test fun unknownFlagsAreLoggedAsQuestionMarksWithoutAWarning() {
        factory.hardware = null
        factory.softwareOnly = null
        renderer.attachTarget(Any())
        assertTrue(env.awaitLines("codec_start"))
        assertTrue(env.lines("codec_start").single().contains(" is_hw=? sw_only=? "))
        assertEquals(0, env.lines("codec_software").size)
    }

    @Test fun releasedFramesFeedCaptureToReleaseAndRenderCallbacks() {
        factory.produceOutput = true
        renderer.stats.latencyOf = { _, _ -> 5_000 }
        renderer.attachTarget(Any())
        assertTrue(env.awaitLines("codec_start"))
        renderer.onFrame(frame(0, VideoFrame.CODEC_CONFIG))
        renderer.onFrame(frame(1, VideoFrame.KEYFRAME))
        for (seq in 2L..4) renderer.onFrame(frame(seq, 0))
        awaitTrue("outputs not released") { renderer.stats.snapshot().let { it.rendered + it.discarded == 4L } }

        val snap = renderer.stats.snapshot()
        assertEquals(4L, snap.decoded)
        assertEquals(4, snap.capDec.count)
        assertEquals("every released frame, and only those", snap.rendered, snap.capRel.count.toLong())
        assertEquals(5_000L, snap.capRel.maxUs)

        // The newest frame is always released (unpaced); its callback marks every earlier awaited one as missing.
        factory.codecs.single().renderedListener!!(4, System.nanoTime())
        val after = renderer.stats.snapshot()
        assertEquals(1, after.capCb.count)
        assertEquals(snap.rendered - 1, after.renderCbMissing)
    }

    /**
     * Review (P2): the codec delivers each frame-rendered callback inside `releaseOutputBuffer` (the main looper ran
     * before the release returned). Every rendered frame got its callback, so none may count as missing.
     */
    @Test fun callbacksDeliveredBeforeTheReleaseReturnsAreNotMissing() {
        factory.produceOutput = true
        factory.renderCallbackInRelease = true
        renderer.stats.latencyOf = { _, _ -> 5_000 }
        renderer.attachTarget(Any())
        assertTrue(env.awaitLines("codec_start"))
        renderer.onFrame(frame(0, VideoFrame.CODEC_CONFIG))
        renderer.onFrame(frame(1, VideoFrame.KEYFRAME))
        assertTrue(factory.await { outputsDequeued >= 1 })
        for (seq in 2L..8) { // one at a time: the frame queue is shallow at 60 fps
            renderer.onFrame(frame(seq, 0))
            assertTrue(factory.await { outputsDequeued >= seq.toInt() })
        }
        awaitTrue("outputs not released") { renderer.stats.snapshot().let { it.rendered + it.discarded == 8L } }

        val snap = renderer.stats.snapshot()
        assertTrue(snap.rendered > 0)
        assertEquals(snap.rendered, snap.capCb.count.toLong())
        assertEquals(0L, snap.renderCbMissing)
    }
}
