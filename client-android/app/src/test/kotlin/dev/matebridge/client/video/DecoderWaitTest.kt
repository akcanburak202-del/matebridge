package dev.matebridge.client.video

import dev.matebridge.client.protocol.Bytes
import dev.matebridge.client.protocol.StreamConfig
import dev.matebridge.client.protocol.VideoFrame
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * T-286: event-driven input wait of the decoder (`dec_wait event_in`, the default) against the old fixed poll (`poll`,
 * a fallback kept for one cycle). The `event` arm (long output idle wait) is gone; its id parses to the default.
 */
class DecoderWaitTest {
    private val ms = 1_000_000L

    // ---- policy (pure) ----

    @Test fun parseKnownIdsAndFallBackToTheDefault() {
        assertEquals(DecoderWait.EVENT_IN, DecoderWait.DEFAULT)
        assertEquals(DecoderWait.EVENT_IN, DecoderWait.parse("event_in"))
        assertEquals(DecoderWait.EVENT_IN, DecoderWait.parse(" Event_In "))
        assertEquals(DecoderWait.POLL, DecoderWait.parse("poll"))
        assertEquals(DecoderWait.POLL, DecoderWait.parse(" POLL "))
        assertEquals(DecoderWait.EVENT_IN, DecoderWait.parse(null))
        assertEquals(DecoderWait.EVENT_IN, DecoderWait.parse("fast"))
        assertEquals("the removed event arm falls back to the default", DecoderWait.EVENT_IN, DecoderWait.parse("event"))
        assertEquals(setOf("poll", "event_in"), DecoderWait.IDS)
    }

    @Test fun defaultModeParksTheInputThread() {
        for (since in listOf(0L, 100 * ms, 5_000 * ms)) {
            assertEquals(DecoderWaits.EVENT_INPUT_WAIT_NS, DecoderWaits.inputWaitNs(DecoderWait.DEFAULT, since, 4 * ms))
        }
        assertTrue(DecoderWaits.EVENT_INPUT_WAIT_NS >= 100 * ms) // a safety net, not a poll
        assertTrue(DecoderWait.EVENT_IN.parksInput)
        assertFalse(DecoderWait.POLL.parksInput)
    }

    @Test fun pollFallbackKeepsTodaysInputWait() {
        // 4 ms while frames flow, 20 ms (IdleWait) after 300 ms without one.
        assertEquals(4 * ms, DecoderWaits.inputWaitNs(DecoderWait.POLL, 0, 4 * ms))
        assertEquals(4 * ms, DecoderWaits.inputWaitNs(DecoderWait.POLL, 299 * ms, 4 * ms))
        assertEquals(20 * ms, DecoderWaits.inputWaitNs(DecoderWait.POLL, 300 * ms, 4 * ms))
    }

    @Test fun outputWaitIsThePollForEveryModeWithNoLongIdleWait() {
        // 5 ms while outputs flow, 20 ms (IdleWait) after 300 ms without one: never longer.
        assertEquals(5_000L, DecoderWaits.outputWaitUs(10 * ms, 5_000, null))
        assertEquals(5_000L, DecoderWaits.outputWaitUs(299 * ms, 5_000, null))
        assertEquals(20_000L, DecoderWaits.outputWaitUs(400 * ms, 5_000, null))
        assertEquals(20_000L, DecoderWaits.outputWaitUs(60_000 * ms, 5_000, null))
        // the held buffer's deadline shortens it, never lengthens it
        assertEquals(2_000L, DecoderWaits.outputWaitUs(10 * ms, 5_000, 2 * ms))
        assertEquals(5_000L, DecoderWaits.outputWaitUs(10 * ms, 5_000, 80 * ms))
        assertEquals(0L, DecoderWaits.outputWaitUs(10 * ms, 5_000, 0))
        assertEquals(20_000L, DecoderWaits.outputWaitUs(400 * ms, 5_000, 80 * ms))
    }

    // ---- FrameQueue: abort + nudge ----

    private fun frame(seq: Long, flags: Int = 0) = VideoFrame(seq, seq * 1000, flags, 0, 1, 3, Bytes(byteArrayOf(0, 0, 1)))

    @Test fun anAbortConditionAlreadyTrueReturnsAtOnce() {
        val q = FrameQueue(VideoStats())
        val t0 = System.nanoTime()
        assertNull(q.awaitNext(10_000 * ms, abort = { true }))
        assertTrue(System.nanoTime() - t0 < 1_000 * ms)
    }

    @Test fun aFrameStillWinsOverAnAbortCondition() {
        val q = FrameQueue(VideoStats())
        q.offer(frame(1, VideoFrame.KEYFRAME))
        assertEquals(1L, q.awaitNext(10_000 * ms, abort = { true })!!.frameSeq)
    }

    @Test fun nudgeWakesAParkedConsumerWhoseAbortConditionBecameTrue() {
        val q = FrameQueue(VideoStats())
        val flag = AtomicBoolean(false)
        val parked = CountDownLatch(1)
        val leftAt = AtomicLong(0)
        val got = CopyOnWriteArrayList<VideoFrame?>()
        val consumer = Thread {
            q.parkHook = { parked.countDown() }
            got.add(q.awaitNext(30_000 * ms, abort = { flag.get() }))
            leftAt.set(System.nanoTime())
        }
        consumer.start()
        assertTrue(parked.await(5, TimeUnit.SECONDS))
        Thread.sleep(30) // let it actually park
        val t0 = System.nanoTime()
        flag.set(true)
        q.nudge()
        consumer.join(5_000)
        assertFalse(consumer.isAlive)
        assertNull(got.single())
        assertTrue("left after ${(leftAt.get() - t0) / ms} ms", leftAt.get() - t0 < 1_000 * ms)
    }

    /** No lost wake-up whatever the interleaving of "condition true + nudge" with "publish waiter, check, park". */
    @Test fun noWakeUpIsLostBetweenTheConditionAndThePark() {
        repeat(400) { i ->
            val q = FrameQueue(VideoStats())
            val flag = AtomicBoolean(false)
            val start = CountDownLatch(1)
            val done = CountDownLatch(1)
            val consumer = Thread {
                start.await()
                q.awaitNext(30_000 * ms, abort = { flag.get() })
                done.countDown()
            }
            consumer.start()
            start.countDown()
            // Vary the relative timing: nudge before, during and after the consumer reaches its park.
            if (i % 4 == 1) Thread.yield()
            if (i % 4 == 2) Thread.sleep(0, 200_000)
            if (i % 4 == 3) Thread.sleep(1)
            flag.set(true)
            q.nudge()
            assertTrue("consumer stuck in iteration $i", done.await(5, TimeUnit.SECONDS))
            consumer.join()
        }
    }

    @Test fun anOfferStillWakesALongParkAtOnce() {
        val q = FrameQueue(VideoStats())
        val parked = CountDownLatch(1)
        val gotAt = AtomicLong(0)
        val consumer = Thread {
            q.parkHook = { parked.countDown() }
            if (q.awaitNext(30_000 * ms, abort = { false }) != null) gotAt.set(System.nanoTime())
        }
        consumer.start()
        assertTrue(parked.await(5, TimeUnit.SECONDS))
        Thread.sleep(30)
        val t0 = System.nanoTime()
        q.offer(frame(1, VideoFrame.KEYFRAME))
        consumer.join(5_000)
        assertTrue(gotAt.get() > 0)
        assertTrue("woke after ${(gotAt.get() - t0) / ms} ms", gotAt.get() - t0 < 500 * ms)
    }

    @Test fun aRevokedConsumerLeavesALongParkAtOnce() {
        val q = FrameQueue(VideoStats())
        q.assignConsumer(7)
        val parked = CountDownLatch(1)
        val left = CountDownLatch(1)
        val consumer = Thread {
            q.parkHook = { parked.countDown() }
            assertNull(q.awaitNext(30_000 * ms, 7, abort = { false }))
            left.countDown()
        }
        consumer.start()
        assertTrue(parked.await(5, TimeUnit.SECONDS))
        q.revokeConsumer(7)
        assertTrue(left.await(2, TimeUnit.SECONDS))
    }

    // ---- VideoRenderer on the fake codec ----

    private val config = StreamConfig(1, StreamConfig.CODEC_HEVC, 2800, 1840, 1400, 920, 60, 50000, 1, 13, 1, 1)
    private val factory = FakeDecoderFactory().also { it.produceOutput = true }
    private val env = TestDecoderEnv()
    private val renderers = CopyOnWriteArrayList<VideoRenderer>()

    private fun make(mode: DecoderWait) = VideoRenderer(
        config, onKeyframeRequest = {}, codecFactory = factory, env = env,
    ).also { it.decoderWait = mode; renderers.add(it) }

    @After fun tearDown() {
        for (r in renderers) r.detachSurface()
    }

    private fun startStream(r: VideoRenderer): FakeDecoderFactory.Codec {
        r.attachTarget(Any())
        assertTrue(env.awaitLines("codec_start"))
        r.onFrame(frame(0, VideoFrame.CODEC_CONFIG))
        r.onFrame(frame(1, VideoFrame.KEYFRAME))
        val codec = factory.codecs[0]
        assertTrue("first frame rendered", factory.await { codec.renderedPts.contains(1L) })
        return codec
    }

    /** Parks of the input thread (frame waits) during [idleMs] without any frame. */
    private fun idleParks(r: VideoRenderer, idleMs: Long): Int {
        val parks = AtomicInteger()
        r.inputParkHook = { parks.incrementAndGet() }
        Thread.sleep(idleMs)
        return parks.get().also { r.inputParkHook = null }
    }


    // ---- renderer: default (event_in) input park, output keeps polling ----

    @Test fun theDefaultModeIsEventIn() {
        val r = VideoRenderer(config, onKeyframeRequest = {}, codecFactory = factory, env = env)
        renderers.add(r)
        assertEquals(DecoderWait.EVENT_IN, r.decoderWait)
    }

    @Test fun eventInParksInputWithFarFewerWakeUpsThanPollAndTheOutputThreadKeepsPolling() {
        val poll = make(DecoderWait.POLL)
        startStream(poll)
        val pollParks = idleParks(poll, 1_000)
        val pollOut = factory.silentOutputPolls
        poll.detachSurface()

        val r = make(DecoderWait.EVENT_IN)
        val codecsBefore = factory.codecs.size
        r.attachTarget(Any())
        assertTrue(factory.await { codecs.size > codecsBefore })
        r.onFrame(frame(0, VideoFrame.CODEC_CONFIG))
        r.onFrame(frame(1, VideoFrame.KEYFRAME))
        val codec = factory.codecs.last()
        assertTrue(factory.await { codec.renderedPts.contains(1L) })
        val outBefore = factory.silentOutputPolls
        val parks = idleParks(r, 1_000)
        val out = factory.silentOutputPolls - outBefore

        // Absolute bound holds on a loaded machine too (slow threads only wake less often); poll (4 ms, then 20 ms after
        // 300 ms idle) gives ~100 parks on an idle machine, event_in a handful.
        assertTrue("input parks $parks (poll $pollParks)", parks <= 10 && parks < pollParks)
        assertTrue("output polls $out (poll $pollOut)", out >= 15) // poll's 5 ms then 20 ms idle polls, not a handful
    }

    @Test fun aFrameAfterALongIdleIsTakenAtOnceAndOrderIsKept() {
        val r = make(DecoderWait.EVENT_IN)
        val codec = startStream(r)
        Thread.sleep(600)
        val inputsBefore = factory.queuedInputs
        val t0 = System.nanoTime()
        r.onFrame(frame(2))
        assertTrue(factory.await { queuedInputs > inputsBefore })
        val queuedMs = (System.nanoTime() - t0) / ms
        assertTrue("queued after $queuedMs ms", queuedMs < 100)
        assertTrue(factory.await { codec.renderedPts.contains(2L) })
        val shownMs = (System.nanoTime() - t0) / ms
        assertTrue("rendered after $shownMs ms", shownMs < 200)
        for (seq in 3L..20L) { // ~10 fps: gaps long enough for the input thread to go back to its park
            r.onFrame(frame(seq))
            assertTrue("frame $seq", factory.await { codec.renderedPts.contains(seq) })
            Thread.sleep(40)
        }
        assertEquals((1L..20L).toList(), codec.renderedPts.toList())
        assertEquals(0, env.lines("decode_error").size)
    }

    @Test fun theModeCanBeSwitchedWhileRunning() {
        val r = make(DecoderWait.POLL)
        val codec = startStream(r)
        r.decoderWait = DecoderWait.EVENT_IN
        Thread.sleep(100)
        r.onFrame(frame(2))
        assertTrue(factory.await { codec.renderedPts.contains(2L) })
        r.decoderWait = DecoderWait.POLL
        Thread.sleep(100)
        r.onFrame(frame(3))
        assertTrue(factory.await { codec.renderedPts.contains(3L) })
    }

    @Test fun aParkedInputThreadStopsAtOnceOnDetach() {
        val r = make(DecoderWait.EVENT_IN)
        startStream(r)
        Thread.sleep(150)
        val t0 = System.nanoTime()
        r.detachSurface()
        val tookMs = (System.nanoTime() - t0) / ms
        assertTrue("detach took $tookMs ms", tookMs < 200)
        assertTrue(r.decoderThreadsFinished())
        assertEquals(1, env.lines("codec_stop").size)
        assertEquals(0, r.handoffWaitingThreads)
    }

    @Test fun anOutputThreadErrorIsSeenByAParkedInputThreadAtOnce() {
        val r = make(DecoderWait.EVENT_IN)
        startStream(r)
        Thread.sleep(150)
        val t0 = System.nanoTime()
        factory.throwOnDequeueOutput = true
        assertTrue("decode_error", env.awaitLines("decode_error", timeoutMs = 3_000))
        factory.throwOnDequeueOutput = false
        val tookMs = (System.nanoTime() - t0) / ms
        assertTrue("error seen after $tookMs ms", tookMs < 200) // the 250 ms safety net alone would be slower
        assertTrue(env.lines("decode_error").single().contains("err=IllegalStateException"))
        assertTrue("restart", env.awaitLines("codec_start", count = 2, timeoutMs = 3_000))
    }

    @Test fun reconfigureWhileParkedHandsOverToTheNextGeneration() {
        val r = make(DecoderWait.EVENT_IN)
        startStream(r)
        Thread.sleep(150)
        r.reconfigure(config)
        assertTrue("second codec", env.awaitLines("codec_start", count = 2))
        r.onFrame(frame(0, VideoFrame.CODEC_CONFIG))
        r.onFrame(frame(1, VideoFrame.KEYFRAME))
        val second = factory.codecs[1]
        assertTrue(factory.await { second.renderedPts.contains(1L) })
        assertEquals(0, env.lines("decode_error").size)
        assertEquals(1, env.lines("codec_stop").size) // the first codec stopped once
    }
}
