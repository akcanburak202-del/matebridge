package dev.matebridge.client.video

import dev.matebridge.client.protocol.Bytes
import dev.matebridge.client.protocol.KeyframeRequest
import dev.matebridge.client.protocol.VideoFrame
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** T-339 (decision 0038 section 7): the STARTUP repeat while waiting for a keyframe doubles up to 4 s and starts over. */
class KeyframeRetryBackoffTest {
    private val ms = 1_000_000L
    private var now = 1_000 * ms
    private var seq = 0L
    private val q = FrameQueue(VideoStats(), FrameQueue.depthForFps(60)) { now }.ownedByTest()
    private val requests = ArrayList<Pair<Int, FrameQueue.Source>>()

    init {
        q.onRequest = { r, s -> requests += r to s }
    }

    private fun key(): Int? = q.offer(VideoFrame(seq, seq * 1000, VideoFrame.KEYFRAME, 0, 1, 1, Bytes(byteArrayOf(1)))).also { seq++ }

    /** Polls every 100 ms for [totalMs] and returns the times (ms since the start request) at which a repeat went out. */
    private fun repeatsOver(totalMs: Int): List<Int> {
        val out = ArrayList<Int>()
        var t = 0
        while (t < totalMs) {
            now += 100 * ms
            t += 100
            if (q.takeRetry()) out += t
        }
        return out
    }

    @Test fun pureSequenceIs500_1000_2000_4000_4000() {
        val b = KeyframeRetryBackoff()
        assertEquals(listOf(500L, 1000L, 2000L, 4000L, 4000L, 4000L), List(6) { b.onRepeat() })
        b.reset()
        assertEquals(500L, b.delayMs)
        b.restore(100_000)
        assertEquals(4000L, b.delayMs)
        b.restore(1)
        assertEquals(500L, b.delayMs)
    }

    @Test fun startupRepeatsBackOffAndANewKeyframeStartsOver() {
        assertEquals(KeyframeRequest.STARTUP, q.reset()) // the first request at t = 0
        // gaps between requests: 500, 1000, 2000, 4000, 4000
        assertEquals(listOf(500, 1500, 3500, 7500, 11500), repeatsOver(12_000))
        assertTrue(requests.drop(1).all { it.second == FrameQueue.Source.RETRY })
        // the keyframe arrives: the gate opens, no repeats
        key()
        assertFalse(q.isWaitingKeyframe())
        assertEquals(emptyList<Int>(), repeatsOver(5_000))
        // a new wait (restart) begins at 500 ms again
        assertEquals(KeyframeRequest.STARTUP, q.reset())
        assertEquals(listOf(500, 1500, 3500), repeatsOver(4_000))
    }

    @Test fun aFramesDroppedRequestStartsTheBackoffOver() {
        q.reset()
        assertEquals(listOf(500, 1500), repeatsOver(2_000))
        key()
        // overflow: FRAMES_DROPPED request; the repeat then waits 500 ms (hold-off) and only then doubles
        repeat(q.maxPending + 1) { q.offer(VideoFrame(seq, seq * 1000, 0, 0, 1, 1, Bytes(byteArrayOf(1)))); seq++ }
        assertTrue(q.isWaitingKeyframe())
        assertEquals(listOf(500, 1500), repeatsOver(2_000))
    }
}
