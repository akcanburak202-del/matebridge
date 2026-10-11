package dev.matebridge.client.video

import dev.matebridge.client.protocol.Bytes
import dev.matebridge.client.protocol.KeyframeRequest
import dev.matebridge.client.protocol.VideoFrame
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class AuxQueueAndPairingTest {
    private var now = 0L
    private fun queue(depth: Int = 4) = AuxFrameQueue(depth) { now }

    private fun frame(seq: Long, flags: Int, capture: Long = seq * 1000) =
        VideoFrame(seq, capture, flags, 0, 1, 4, Bytes(ByteArray(4)), VideoFrame.VIEW_AUX)

    private val kf = VideoFrame.KEYFRAME
    private val cfg = VideoFrame.CODEC_CONFIG

    @Test
    fun nonKeyframesAreGatedUntilAKeyframe() {
        val q = queue()
        assertNull(q.offer(frame(1, 0)))
        assertEquals(0, q.pendingFrames())
        assertNull(q.offer(frame(2, kf)))
        assertEquals(1, q.pendingFrames())
        assertNull(q.offer(frame(3, 0)))
        assertEquals(2, q.pendingFrames())
        assertEquals(1, q.counters().dropped)
    }

    @Test
    fun configGoesFirstAndIsKeptAcrossReset() {
        val q = queue()
        q.offer(frame(0, cfg))
        q.offer(frame(1, kf))
        assertTrue(q.awaitNext(0)!!.isCodecConfig)
        assertTrue(q.awaitNext(0)!!.isKeyframe)
        assertEquals(KeyframeRequest.DECODE_ERROR, q.reset(KeyframeRequest.DECODE_ERROR))
        assertTrue(q.isWaitingKeyframe())
        assertTrue(q.awaitNext(0)!!.isCodecConfig) // replayed for the rebuilt decoder
        assertNull(q.awaitNext(0))
    }

    @Test
    fun overflowDropsEverythingAndRequestsAuxKeyframe() {
        val q = queue(depth = 2)
        q.offer(frame(1, kf))
        assertNull(q.offer(frame(2, 0)))
        val req = q.offer(frame(3, 0)) // 3 pending > 2
        assertEquals(KeyframeRequest.FRAMES_DROPPED, req)
        assertEquals(0, q.pendingFrames())
        assertTrue(q.isWaitingKeyframe())
        assertEquals(1, q.counters().overflows)
    }

    @Test
    fun requestsAreRateLimitedAndHeld() {
        val q = queue(depth = 2)
        q.offer(frame(1, kf))
        q.offer(frame(2, 0))
        assertEquals(KeyframeRequest.FRAMES_DROPPED, q.offer(frame(3, 0)))
        now += 100_000_000L
        q.offer(frame(4, kf))
        q.offer(frame(5, 0))
        assertNull(q.offer(frame(6, 0))) // inside the hold-off: held
        assertTrue(q.isWaitingKeyframe())
        now += 500_000_000L
        assertEquals(KeyframeRequest.FRAMES_DROPPED, q.offer(frame(7, 0))) // first frame after the hold-off
        assertNull(q.offer(frame(8, 0))) // not again
    }

    @Test
    fun retryOnlyWhileGatedAndAfterHoldoff() {
        val q = queue()
        assertTrue(q.takeRetry()) // never requested yet, gate closed
        assertTrue(!q.takeRetry())
        now += 600_000_000L
        assertTrue(!q.takeRetry()) // decision 0038: the second repeat waits 1 s
        now += 500_000_000L
        assertTrue(q.takeRetry())
        q.offer(frame(1, kf))
        now += 600_000_000L
        assertTrue(!q.takeRetry()) // gate open
    }

    @Test
    fun keyframeFlushesStaleFramesAndReopensGate() {
        val q = queue()
        q.offer(frame(1, kf))
        q.offer(frame(2, 0))
        q.offer(frame(3, kf))
        assertEquals(1, q.pendingFrames())
        assertEquals(3L, q.awaitNext(0)!!.frameSeq)
    }

    @Test
    fun pairingMatchesByCaptureTime() {
        val evicted = ArrayList<String>()
        val p = AuxPairing<String>(3) { evicted += it }
        p.add(100, "a100")
        p.add(200, "a200")
        assertEquals("a200", p.pair(200))
        assertEquals(listOf("a100"), evicted) // older than a matched frame: can never match again
        assertEquals(1L, p.paired)
    }

    @Test
    fun lateAuxMeansMainOnly() {
        val p = AuxPairing<String>(3) {}
        p.add(100, "a100")
        assertNull(p.pair(200)) // aux of frame 200 not decoded yet
        assertEquals(1L, p.late)
        assertEquals(0.0, p.pairedPct()!!, 1e-9)
        p.resetCounts()
        assertNull(p.pairedPct())
    }

    @Test
    fun ringIsBounded_andClearEvictsAll() {
        val evicted = ArrayList<Int>()
        val p = AuxPairing<Int>(2) { evicted += it }
        for (i in 1..5) p.add(i * 10L, i)
        assertEquals(listOf(1, 2, 3), evicted)
        assertEquals(2, p.size)
        p.clear()
        assertEquals(listOf(1, 2, 3, 4, 5), evicted)
    }

    @Test
    fun pairedPercentCountsBothKinds() {
        val p = AuxPairing<String>(4) {}
        p.add(10, "x")
        p.pair(10)
        p.pair(20)
        p.pair(30)
        p.add(40, "y")
        p.pair(40)
        assertEquals(50.0, p.pairedPct()!!, 1e-9)
    }

    @Test
    fun glTimingsPercentiles() {
        val t = GlTimings()
        assertNull(t.percentiles())
        for (i in 1..100) t.add(i.toDouble())
        val (p50, p95) = t.percentiles()!!
        assertEquals(50.0, p50, 1e-9)
        assertEquals(95.0, p95, 1e-9)
        assertNull(t.percentiles()) // reset
    }

    @Test
    fun auxRetryBacksOffTo4sAndAKeyframeResets() {
        val q = queue()
        q.reset(0) // the start request
        val gaps = ArrayList<Int>()
        var t = 0
        while (gaps.size < 5) {
            now += 100_000_000L; t += 100
            if (q.takeRetry()) { gaps += t; t = 0 }
        }
        assertEquals(listOf(500, 1000, 2000, 4000, 4000), gaps)
    }

    @Test
    fun retryAnswersAHeldOverflowRequestSoNoRedundantFramesDroppedFollows() {
        val q = queue(depth = 2)
        q.reset(KeyframeRequest.STARTUP)
        q.offer(frame(1, kf))
        q.offer(frame(2, 0)); q.offer(frame(3, 0))
        assertNull(q.offer(frame(4, 0))) // overflow inside the hold-off: held
        now += 600_000_000L
        assertTrue(q.takeRetry()) // the retry goes out first
        now += 600_000_000L
        assertNull(q.offer(frame(5, 0))) // no redundant FRAMES_DROPPED, the backoff is not reset
        now += 300_000_000L
        assertTrue(!q.takeRetry()) // 900 ms since the retry: still waiting out its 1 s delay
        now += 200_000_000L
        assertTrue(q.takeRetry())
    }
}
