package dev.matebridge.client.video

import dev.matebridge.client.protocol.Bytes
import dev.matebridge.client.protocol.KeyframeRequest
import dev.matebridge.client.protocol.VideoFrame
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** T-219: consumer-generation ownership of [FrameQueue] (pure). */
class FrameQueueOwnershipTest {
    private val stats = VideoStats()
    private val q = FrameQueue(stats, maxPending = 2)
    private val requests = ArrayList<Int>()

    init { q.onRequest = { reason, _ -> synchronized(requests) { requests.add(reason) } } }

    private fun frame(seq: Long, flags: Int = 0) = VideoFrame(seq, seq * 1000, flags, 0, 1, 3, Bytes(byteArrayOf(1, 2, 3)))

    @Test fun aReplacedConsumerTakesNothingAndTheFramesWaitForTheOwner() {
        q.assignConsumer(1)
        q.offer(frame(0, VideoFrame.CODEC_CONFIG))
        q.offer(frame(1, VideoFrame.KEYFRAME))
        assertEquals(0L, q.awaitNext(0, consumer = 1)!!.frameSeq)

        q.assignConsumer(2)
        assertNull(q.awaitNext(0, consumer = 1))
        val startNs = System.nanoTime()
        assertNull("a non-owner must not park", q.awaitNext(TimeUnit.SECONDS.toNanos(10), consumer = 1))
        assertTrue(TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - startNs) < 1_000)
        assertEquals("the frame stayed for the owner", 1L, q.awaitNext(0, consumer = 2)!!.frameSeq)
        assertNull(q.awaitNext(0, consumer = 2))
    }

    @Test fun withNoOwnerFramesWaitBoundedAndTheNextOwnerGetsTheNewestKeyframe() {
        q.assignConsumer(1)
        q.revokeConsumer(1)
        q.offer(frame(0, VideoFrame.CODEC_CONFIG))
        q.offer(frame(1, VideoFrame.KEYFRAME))
        q.offer(frame(2))
        assertEquals(KeyframeRequest.FRAMES_DROPPED, q.offer(frame(3))) // overflow rule unchanged while unowned
        assertEquals("only the config is left", 1, q.pending())
        assertNull(q.awaitNext(0, consumer = 1))
        q.offer(frame(4, VideoFrame.KEYFRAME))

        q.assignConsumer(2)
        assertEquals(0L, q.awaitNext(0, consumer = 2)!!.frameSeq)
        assertEquals(4L, q.awaitNext(0, consumer = 2)!!.frameSeq)
        assertNull(q.awaitNext(0, consumer = 2))
    }

    @Test fun revokingAnotherGenerationLeavesTheOwnerInPlace() {
        q.assignConsumer(2)
        q.revokeConsumer(1) // a late revoke of an older generation
        q.offer(frame(0, VideoFrame.KEYFRAME))
        assertEquals(0L, q.awaitNext(0, consumer = 2)!!.frameSeq)
    }

    @Test fun aRetiredConsumerCanNeitherResetNorFailTheOwnersQueue() {
        q.assignConsumer(1)
        q.assignConsumer(2)
        q.offer(frame(0, VideoFrame.CODEC_CONFIG))
        q.offer(frame(1, VideoFrame.KEYFRAME))
        val before = q.counters().kfRequests

        assertNull(q.resetIfOwner(1, KeyframeRequest.DECODE_ERROR))
        assertNull(q.onDecoderErrorIfOwner(1))
        assertEquals(before, q.counters().kfRequests)
        assertTrue(synchronized(requests) { requests.isEmpty() })
        assertFalse(q.isWaitingKeyframe())
        assertEquals(0L, q.awaitNext(0, consumer = 2)!!.frameSeq)
        assertEquals(1L, q.awaitNext(0, consumer = 2)!!.frameSeq)

        // The owner itself still can.
        assertEquals(KeyframeRequest.DECODE_ERROR, q.onDecoderErrorIfOwner(2))
        assertTrue(q.isWaitingKeyframe())
        assertEquals(KeyframeRequest.DECODE_ERROR, q.resetIfOwner(2, KeyframeRequest.DECODE_ERROR))
        assertEquals(listOf(KeyframeRequest.DECODE_ERROR, KeyframeRequest.DECODE_ERROR), synchronized(requests) { requests.toList() })
    }

    @Test fun aRevokeWakesAParkedConsumerAtOnceWithNothing() {
        q.assignConsumer(1)
        val parked = CountDownLatch(1)
        q.parkHook = { parked.countDown() }
        val got = AtomicReference<VideoFrame?>(frame(99))
        val t = Thread { got.set(q.awaitNext(TimeUnit.SECONDS.toNanos(30), consumer = 1)) }
        val startNs = System.nanoTime()
        t.start()
        try {
            assertTrue(parked.await(5, TimeUnit.SECONDS))
            q.revokeConsumer(1) // retire: no frame, no owner
            t.join(5_000)
            assertFalse("the revoked consumer kept waiting", t.isAlive)
        } finally {
            q.revokeConsumer(1)
            t.join(5_000)
        }
        assertNull(got.get())
        assertTrue(TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - startNs) < 5_000)
    }

    @Test fun aNewOwnerWakesTheReplacedConsumerAndKeepsTheFrame() {
        q.assignConsumer(1)
        val parked = CountDownLatch(1)
        q.parkHook = { parked.countDown() }
        val got = AtomicReference<VideoFrame?>(frame(99))
        val t = Thread { got.set(q.awaitNext(TimeUnit.SECONDS.toNanos(30), consumer = 1)) }
        val startNs = System.nanoTime()
        t.start()
        try {
            assertTrue(parked.await(5, TimeUnit.SECONDS))
            q.assignConsumer(2) // a new generation takes over
            q.offer(frame(0, VideoFrame.CODEC_CONFIG))
            t.join(5_000)
            assertFalse("the replaced consumer kept waiting", t.isAlive)
        } finally {
            q.revokeConsumer(1)
            t.join(5_000)
        }
        assertNull(got.get())
        assertTrue(TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - startNs) < 5_000)
        assertEquals("the frame went to the new owner", 0L, q.awaitNext(0, consumer = 2)!!.frameSeq)
    }
}
