package dev.matebridge.client.video

import dev.matebridge.client.protocol.Bytes
import dev.matebridge.client.protocol.VideoFrame
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicLong
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** T-077: park/unpark hand-off of [FrameQueue.awaitNext] and the prefetched decoder input buffer. */
class InputHandoffTest {
    private fun frame(seq: Long, flags: Int = 0) =
        VideoFrame(seq, seq * 1000, flags, 0, 1, 1, Bytes(byteArrayOf(1)))

    @Test fun awaitNextReturnsAQueuedFrameAtOnceAndNullOnTimeout() {
        val q = FrameQueue(VideoStats())
        q.offer(frame(1, VideoFrame.KEYFRAME))
        assertEquals(1L, q.awaitNext(0)!!.frameSeq)
        assertNull(q.awaitNext(0))
        val t0 = System.nanoTime()
        assertNull(q.awaitNext(20_000_000L))
        assertTrue(System.nanoTime() - t0 >= 15_000_000L)
    }

    @Test fun offerWakesAParkedConsumerLongBeforeItsTimeout() {
        val q = FrameQueue(VideoStats())
        val parked = CountDownLatch(1)
        val gotAt = AtomicLong(0)
        val consumer = Thread {
            parked.countDown()
            val f = q.awaitNext(5_000_000_000L)
            if (f != null) gotAt.set(System.nanoTime())
        }
        consumer.start()
        parked.await()
        Thread.sleep(50) // let it park
        val sentAt = System.nanoTime()
        q.offer(frame(1, VideoFrame.KEYFRAME))
        consumer.join(2_000)
        assertFalse(consumer.isAlive)
        assertTrue(gotAt.get() > 0)
        assertTrue("woke after ${(gotAt.get() - sentAt) / 1_000_000} ms", gotAt.get() - sentAt < 1_000_000_000L)
    }

    @Test fun noFrameIsLostOrReorderedInAPingPongHandOff() {
        val q = FrameQueue(VideoStats())
        val n = 2000
        val received = ArrayList<Long>(n)
        val ready = java.util.concurrent.Semaphore(0)
        val consumer = Thread {
            while (received.size < n) {
                val f = q.awaitNext(10_000_000_000L) ?: continue
                received += f.frameSeq
                ready.release()
            }
        }
        consumer.start()
        q.offer(frame(0, VideoFrame.KEYFRAME))
        for (s in 1 until n) {
            assertTrue(ready.tryAcquire(5, TimeUnit.SECONDS)) // previous frame consumed: never overflows the bound
            q.offer(frame(s.toLong()))
        }
        consumer.join(10_000)
        assertFalse(consumer.isAlive)
        assertEquals((0 until n).map { it.toLong() }, received)
    }

    @Test fun queueRulesAreUnchangedThroughAwaitNext() {
        val s = VideoStats()
        val q = FrameQueue(s)
        q.offer(frame(0)) // gate closed: dropped
        q.offer(frame(1, VideoFrame.CODEC_CONFIG))
        q.offer(frame(2, VideoFrame.KEYFRAME))
        q.offer(frame(3)) // keyframe + 3: two pending
        assertEquals(dev.matebridge.client.protocol.KeyframeRequest.FRAMES_DROPPED, q.offer(frame(4)))
        assertEquals(1L, q.awaitNext(0)!!.frameSeq) // config survives the overflow
        assertNull(q.awaitNext(0))
        assertTrue(q.isWaitingKeyframe())
    }

    @Test fun prefetchedInputBufferIsUsedFirstWithoutWaiting() {
        val calls = ArrayList<Long>()
        var next = 7
        val slot = InputBufferSlot { t -> calls += t; next++ }
        assertTrue(slot.prefetch())
        assertTrue(slot.prefetch()) // already held: no second dequeue
        assertEquals(listOf(0L), calls)
        assertEquals(7, slot.take(4_000))
        assertTrue(slot.lastPrefetched)
        assertEquals(-1, slot.index)
        assertEquals(listOf(0L), calls) // no dequeue on the frame's path
    }

    @Test fun withoutAFreeBufferTheFrameFallsBackToATimedDequeue() {
        val calls = ArrayList<Long>()
        val answers = ArrayDeque(listOf(-1, 3))
        val slot = InputBufferSlot { t -> calls += t; answers.removeFirst() }
        assertFalse(slot.prefetch())
        assertEquals(3, slot.take(4_000))
        assertFalse(slot.lastPrefetched)
        assertEquals(listOf(0L, 4_000L), calls)
    }

    @Test fun failedTimedDequeueReturnsNegativeAndHoldsNothing() {
        val slot = InputBufferSlot { -1 }
        assertTrue(slot.take(4_000) < 0)
        assertEquals(-1, slot.index)
    }
}
