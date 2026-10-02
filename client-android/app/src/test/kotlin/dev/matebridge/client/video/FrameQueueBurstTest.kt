package dev.matebridge.client.video

import dev.matebridge.client.protocol.Bytes
import dev.matebridge.client.protocol.KeyframeRequest
import dev.matebridge.client.protocol.VideoFrame
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** T-121: the queue absorbs short bunches, overflows only at its bound, and limits keyframe requests. */
class FrameQueueBurstTest {
    private val ms = 1_000_000L
    private val frameNs = 8_333_333L // 120 fps
    private var now = 1_000 * ms
    private var seq = 0L

    private val stats = VideoStats()
    private val q = FrameQueue(stats, FrameQueue.depthForFps(120)) { now }
    private val overflows = ArrayList<FrameQueue.Overflow>()
    private val requests = ArrayList<Pair<Int, FrameQueue.Source>>()

    init {
        q.onOverflow = { overflows += it }
        q.onRequest = { r, s -> requests += r to s }
    }

    private fun p(): Int? = q.offer(VideoFrame(seq, seq * 1000, 0, 0, 1, 3, Bytes(byteArrayOf(1, 2, 3)))).also { seq++ }
    private fun key(): Int? = q.offer(VideoFrame(seq, seq * 1000, VideoFrame.KEYFRAME, 0, 1, 3, Bytes(byteArrayOf(1)))).also { seq++ }

    /** Fills the queue past its bound at the current time; returns the overflow's request. */
    private fun overflowNow(): Int? {
        var r: Int? = null
        repeat(q.maxPending + 1) { r = p() }
        return r
    }

    @Test fun depthIsAboutSixtyFourMillisecondsOfFrames() {
        assertEquals(8, FrameQueue.depthForFps(120))
        assertEquals(8, FrameQueue.depthForFps(144))
        assertEquals(4, FrameQueue.depthForFps(60))
        assertEquals(2, FrameQueue.depthForFps(30))
        assertEquals(FrameQueue.DEFAULT_MAX_PENDING, FrameQueue.depthForFps(0))
    }

    @Test fun fourFrameBunchAt120FpsIsAbsorbed() { // (a)
        assertNull(key()); q.poll(0)
        repeat(20) { assertNull(p()); assertNotNull(q.poll(0)); now += frameNs } // steady
        repeat(4) { assertNull(p()) } // a network bunch: four frames at once, decoder busy
        assertEquals(4, q.pending())
        repeat(4) { assertNotNull(q.poll(0)) } // the decoder catches up
        repeat(5) { now += frameNs; assertNull(p()); assertNotNull(q.poll(0)) }
        assertEquals(0L, stats.snapshot().dropped)
        assertTrue(requests.isEmpty())
        assertTrue(overflows.isEmpty())
        assertEquals(FrameQueue.Counters(0, 0, 0, 4), q.counters())
    }

    @Test fun sustainedSlowDecoderOverflowsAtTheBoundWithOneRequest() { // (b)
        assertNull(key()); q.poll(0)
        var nextPollNs = now
        var first: Long? = null
        val until = now + 1_000 * ms
        while (now < until) {
            val r = p()
            if (r != null) {
                assertEquals(KeyframeRequest.FRAMES_DROPPED, r)
                if (first == null) {
                    first = now
                    assertEquals(0L, stats.snapshot().dropped - (q.maxPending + 1)) // nothing dropped before the bound
                }
            }
            while (nextPollNs <= now) { q.poll(0); nextPollNs += 10 * ms } // decoder: 100 fps < 120 fps
            now += frameNs
            if (first != null && now - first >= 450 * ms) break // inside the hold-off, no keyframe answer
        }
        assertNotNull(first)
        assertEquals(1, overflows.size)
        assertEquals(q.maxPending + 1, overflows[0].pending)
        assertTrue(overflows[0].requested)
        assertEquals(listOf(KeyframeRequest.FRAMES_DROPPED to FrameQueue.Source.OVERFLOW), requests)
        assertTrue(q.isWaitingKeyframe())
        val c = q.counters()
        assertEquals(1L, c.kfRequests); assertEquals(1L, c.overflows); assertEquals(q.maxPending + 1, c.maxPending)
    }

    @Test fun secondOverflowInsideHoldOffSendsNoRequestThenADeferredOne() { // (c)
        assertNull(key()); q.poll(0)
        assertEquals(KeyframeRequest.FRAMES_DROPPED, overflowNow())
        now += 100 * ms
        assertNull(key()) // the answer: gate open, big IDR
        now += 100 * ms
        assertNull(overflowNow()) // chained overflow 200 ms after the request: held
        assertEquals(2, overflows.size)
        assertFalse(overflows[1].requested)
        assertEquals(200L, overflows[1].sinceRequestMs)
        assertTrue(q.isWaitingKeyframe())
        now += 200 * ms
        assertNull(p()) // 400 ms: still held
        now += 100 * ms
        assertEquals(KeyframeRequest.FRAMES_DROPPED, p()) // 500 ms: the held request goes out on the next frame
        now += 10 * ms
        assertNull(p())
        assertEquals(
            listOf(KeyframeRequest.FRAMES_DROPPED to FrameQueue.Source.OVERFLOW, KeyframeRequest.FRAMES_DROPPED to FrameQueue.Source.DEFERRED),
            requests,
        )
        assertEquals(FrameQueue.Counters(2, 1, 2, q.maxPending + 1), q.counters(reset = true))
        assertEquals(FrameQueue.Counters(0, 0, 0, 0), q.counters())
    }

    @Test fun keyframeAfterAHeldOverflowCancelsTheDeferredRequest() {
        assertNull(key()); q.poll(0)
        overflowNow()
        now += 50 * ms; key(); now += 50 * ms
        assertNull(overflowNow()) // held
        now += 100 * ms
        assertNull(key()) // a keyframe came anyway (periodic or the host's answer)
        now += 600 * ms
        assertNull(p()) // gate open, nothing held: no request
        assertEquals(1, requests.size)
    }

    @Test fun keyframeOpensTheGate() { // (d)
        assertNull(key()); q.poll(0)
        overflowNow()
        assertNull(p()); assertNull(q.poll(0)) // gated
        now += 80 * ms
        assertNull(key())
        assertFalse(q.isWaitingKeyframe())
        assertNull(p())
        assertEquals(2, q.pending())
    }

    @Test fun startupAndDecodeErrorAlwaysGoOutAndRestartTheHoldOff() {
        assertNull(key()); q.poll(0)
        assertEquals(KeyframeRequest.FRAMES_DROPPED, overflowNow())
        now += 10 * ms
        assertEquals(KeyframeRequest.STARTUP, q.reset()) // inside the hold-off: still sent
        now += 10 * ms
        assertEquals(KeyframeRequest.DECODE_ERROR, q.onDecoderError())
        now += 20 * ms
        key()
        now += 450 * ms // 470 ms after the error request
        assertNull(overflowNow())
        assertEquals(
            listOf(FrameQueue.Source.OVERFLOW, FrameQueue.Source.RESET, FrameQueue.Source.ERROR),
            requests.map { it.second },
        )
    }

    @Test fun periodicRetryGoesThroughTheHoldOff() {
        assertEquals(KeyframeRequest.STARTUP, q.reset())
        now += 100 * ms
        assertFalse(q.takeRetry()) // right after the startup request
        now += 400 * ms
        assertTrue(q.takeRetry()) // 500 ms, still gated
        now += 100 * ms
        assertFalse(q.takeRetry())
        key()
        now += 1_000 * ms
        assertFalse(q.takeRetry()) // gate open
        // An overflow request is not followed by a retry before the hold-off ends.
        overflowNow()
        now += 200 * ms
        assertFalse(q.takeRetry())
        assertEquals(
            listOf(FrameQueue.Source.RESET, FrameQueue.Source.RETRY, FrameQueue.Source.OVERFLOW),
            requests.map { it.second },
        )
    }

    @Test fun overflowReportsItsPositionAndArrivalGaps() {
        assertNull(key()); q.poll(0)
        repeat(3) { now += frameNs; p(); q.poll(0) }
        now += 40 * ms // a stall, then the bunch
        repeat(q.maxPending + 1) { p(); now += 1 * ms }
        val o = overflows.single()
        assertEquals(3L + q.maxPending + 1, o.sinceKeyframe)
        assertEquals(q.maxPending + 1, o.pending)
        assertEquals(FrameQueue.GAP_HISTORY, o.gapsUs.size)
        assertEquals(-1L, o.sinceRequestMs)
        assertArrayEquals(LongArray(FrameQueue.GAP_HISTORY) { 1_000L }, o.gapsUs) // newest gaps: the bunch
    }

    @Test fun depthChangesWithTheStream() {
        q.maxPending = FrameQueue.depthForFps(60)
        assertNull(key()); q.poll(0)
        repeat(4) { assertNull(p()) }
        assertEquals(KeyframeRequest.FRAMES_DROPPED, p())
    }
}
