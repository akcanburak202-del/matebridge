package dev.matebridge.client.video

import dev.matebridge.client.protocol.Bytes
import dev.matebridge.client.protocol.StreamConfig
import dev.matebridge.client.protocol.VideoFrame
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** T-312: output-thread park (CB2), the aux decoder's event waits and the GL thread's wait policy (C10/CB9). */
class OutputParkTest {
    private val ms = 1_000_000L

    // ---- OutputPark (pure) ----

    @Test fun parksOnlyWhenEnabledEmptyAndNothingHeld() {
        val off = OutputPark(enabled = false, fuseNs = 5 * ms)
        assertFalse(off.parkIfEmpty(holding = false))
        off.onQueued()
        assertEquals(0, off.pending) // a disabled park counts nothing

        val p = OutputPark(enabled = true, fuseNs = 5 * ms)
        assertFalse("held buffer", p.parkIfEmpty(holding = true))
        p.onQueued()
        assertFalse("frame in flight keeps the poll", p.parkIfEmpty(holding = false))
        p.onOutput()
        assertTrue("empty", p.parkIfEmpty(holding = false))
    }

    @Test fun anOutputBeyondTheCountNeverMakesItNegative() {
        val p = OutputPark(enabled = true, fuseNs = 5 * ms)
        p.onOutput(); p.onOutput()
        assertEquals(0, p.pending)
        p.onQueued()
        assertEquals(1, p.pending)
        p.onQueueFailed(); p.onQueueFailed()
        assertEquals(0, p.pending)
    }

    @Test fun aLostUnparkIsBoundedByTheFuse() {
        val p = OutputPark(enabled = true, fuseNs = 30 * ms) // never bound to a thread: signal() reaches nobody
        p.signal()
        val t0 = System.nanoTime()
        assertTrue(p.parkIfEmpty(false))
        val tookMs = (System.nanoTime() - t0) / ms
        assertTrue("parked $tookMs ms", tookMs >= 20 && tookMs < 1_000)
    }

    @Test fun signalEndsAParkAtOnceAndAnEarlySignalLeavesAPermit() {
        val p = OutputPark(enabled = true, fuseNs = 10_000 * ms)
        val parked = CountDownLatch(1)
        val returnedMs = java.util.concurrent.atomic.AtomicLong(-1)
        val t = Thread {
            p.bindOutputThread()
            parked.countDown()
            val t0 = System.nanoTime()
            p.parkIfEmpty(false)
            returnedMs.set((System.nanoTime() - t0) / ms)
        }
        t.start()
        assertTrue(parked.await(5, TimeUnit.SECONDS))
        Thread.sleep(50)
        p.signal()
        t.join(5_000)
        assertFalse(t.isAlive)
        assertTrue("returned after ${returnedMs.get()} ms", returnedMs.get() in 0..2_000)

        // The unpark comes BEFORE the park: the permit makes the park return at once (no lost wake-up).
        val ready = CountDownLatch(1)
        val go = AtomicBoolean(false) // spun on: a latch wait would eat the permit
        val tookMs = java.util.concurrent.atomic.AtomicLong(-1)
        val t2 = Thread {
            p.bindOutputThread()
            ready.countDown()
            while (!go.get()) Thread.onSpinWait()
            val t0 = System.nanoTime()
            p.parkIfEmpty(false)
            tookMs.set((System.nanoTime() - t0) / ms)
        }
        t2.start()
        assertTrue(ready.await(5, TimeUnit.SECONDS))
        p.signal()
        go.set(true)
        t2.join(5_000)
        assertFalse(t2.isAlive)
        assertTrue("took ${tookMs.get()} ms", tookMs.get() in 0..2_000)
    }

    @Test fun aWakeAlwaysLeavesOneRealDequeueBeforeTheNextPark() {
        val p = OutputPark(enabled = true, fuseNs = 1 * ms)
        assertTrue(p.parkIfEmpty(false))
        assertFalse("probe after the park", p.parkIfEmpty(false))
        assertTrue("park again only after the probe", p.parkIfEmpty(false))
        assertFalse(p.parkIfEmpty(false))
    }

    @Test fun aFrameTheCodecSwallowedKeepsTodaysPollAndNeverFreezes() {
        val p = OutputPark(enabled = true, fuseNs = 1 * ms)
        p.onQueued() // never comes out
        repeat(100) { assertFalse(p.parkIfEmpty(false)) } // every turn dequeues
        assertEquals(1, p.pending)
    }

    @Test fun anOutputThatArrivesAfterAProbeTimedOutIsDequeuedWithinOneFuse() {
        // Simulated output thread: count 0 -> park, probe (empty), park; the output "appears" meanwhile.
        val p = OutputPark(enabled = true, fuseNs = 5 * ms)
        val available = java.util.concurrent.atomic.AtomicBoolean(false)
        val dequeuedAtMs = java.util.concurrent.atomic.AtomicLong(-1)
        val t0 = System.nanoTime()
        val t = Thread {
            p.bindOutputThread()
            while (dequeuedAtMs.get() < 0) {
                if (p.parkIfEmpty(false)) continue
                if (available.get()) { dequeuedAtMs.set((System.nanoTime() - t0) / ms); p.onOutput() }
            }
        }
        t.start()
        Thread.sleep(50) // the thread has parked and probed empty repeatedly
        p.onQueued() // an input whose output only shows up later, with no unpark (lost / late)
        Thread.sleep(50)
        val appearedMs = (System.nanoTime() - t0) / ms
        available.set(true)
        t.join(5_000)
        assertFalse(t.isAlive)
        assertTrue("seen ${dequeuedAtMs.get() - appearedMs} ms after it appeared", dequeuedAtMs.get() - appearedMs < 100)
    }

    @Test fun anIdleThenOneFrameAndABurstKeepEveryCount() {
        val p = OutputPark(enabled = true, fuseNs = 1 * ms)
        assertTrue(p.parkIfEmpty(false)) // idle
        p.onQueued() // 5 s later: age never matters
        assertFalse(p.parkIfEmpty(false))
        assertFalse(p.parkIfEmpty(false))
        assertEquals(1, p.pending)
        p.onOutput()
        repeat(5) { p.onQueued() }
        assertEquals(5, p.pending)
        repeat(5) { p.onOutput() }
        assertEquals(0, p.pending)
    }

    @Test fun neverTwoSkippedDequeuesInARowAcrossRandomInterleavings() {
        val rnd = java.util.Random(312)
        repeat(200) { round ->
            val p = OutputPark(enabled = true, fuseNs = 10_000L) // 10 us fuse: the park is real but short
            var skipped = 0 // consecutive turns without a real dequeue
            repeat(300) {
                when (rnd.nextInt(6)) {
                    0 -> p.onQueued()
                    1 -> p.onOutput()
                    2 -> p.onQueueFailed()
                    3 -> p.signal()
                    else -> {
                        val holding = rnd.nextInt(4) == 0
                        if (p.parkIfEmpty(holding)) skipped++ else skipped = 0 // false = the caller dequeues
                        assertTrue("round $round: $skipped parks in a row", skipped <= 1)
                    }
                }
            }
        }
    }

    // ---- GL wait policy (pure) ----

    @Test fun glThreadPollsOnlyWhileSomethingIsPending() {
        assertEquals(25L, GlWait.waitMs(true))
        assertEquals(250L, GlWait.waitMs(false))
        assertFalse(GlWait.pending(false, false, false, null))
        assertFalse(GlWait.pending(false, false, false, GlWait.TIMESTAMP_TAIL_NS))
        assertTrue(GlWait.pending(true, false, false, null))
        assertTrue(GlWait.pending(false, true, false, null))
        assertTrue(GlWait.pending(false, false, true, null))
        assertTrue(GlWait.pending(false, false, false, GlWait.TIMESTAMP_TAIL_NS - 1))
    }

    // ---- AuxFrameQueue: long event wait ----

    private fun frame(seq: Long, flags: Int = 0) = VideoFrame(seq, seq * 1000, flags, 0, 1, 3, Bytes(byteArrayOf(0, 0, 1)))

    @Test fun auxAbortAlreadyTrueDoesNotWait() {
        val q = AuxFrameQueue(4)
        val t0 = System.nanoTime()
        assertNull(q.awaitNext(10_000 * ms, abort = { true }))
        assertTrue((System.nanoTime() - t0) / ms < 1_000)
    }

    @Test fun auxWakeAfterAbortConditionEndsALongWaitAtOnce() {
        val q = AuxFrameQueue(4)
        val flag = AtomicBoolean(false)
        val waiting = CountDownLatch(1)
        val tookMs = java.util.concurrent.atomic.AtomicLong(-1)
        val t = Thread {
            waiting.countDown()
            val t0 = System.nanoTime()
            q.awaitNext(10_000 * ms, abort = { flag.get() })
            tookMs.set((System.nanoTime() - t0) / ms)
        }
        t.start()
        assertTrue(waiting.await(5, TimeUnit.SECONDS))
        Thread.sleep(50)
        flag.set(true)
        q.wake()
        t.join(5_000)
        assertFalse(t.isAlive)
        assertTrue("took ${tookMs.get()} ms", tookMs.get() in 0..2_000)
    }

    @Test fun auxFrameEndsALongWaitAtOnce() {
        val q = AuxFrameQueue(4)
        val got = CopyOnWriteArrayList<Long>()
        val t = Thread { q.awaitNext(10_000 * ms)?.let { got.add(it.frameSeq) } }
        t.start()
        Thread.sleep(50)
        q.offer(frame(1, VideoFrame.KEYFRAME))
        t.join(5_000)
        assertFalse(t.isAlive)
        assertEquals(listOf(1L), got.toList())
    }

    // ---- VideoRenderer on the fake codec ----

    private val config = StreamConfig(1, StreamConfig.CODEC_HEVC, 2800, 1840, 1400, 920, 60, 50000, 1, 13, 1, 1)
    private val factory = FakeDecoderFactory().also { it.produceOutput = true }
    private val env = TestDecoderEnv()
    private val renderers = CopyOnWriteArrayList<VideoRenderer>()

    private fun make(park: Boolean) = VideoRenderer(
        config, onKeyframeRequest = {}, codecFactory = factory, env = env,
    ).also { it.outPark = park; renderers.add(it) }

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

    /** Silent polls during 1 s of a 10 fps stream (a frame every 100 ms). */
    private fun pollsAt10Fps(r: VideoRenderer): Int {
        val codec = startStream(r)
        Thread.sleep(100)
        val before = factory.silentOutputPolls
        for (seq in 2L..11L) {
            r.onFrame(frame(seq))
            assertTrue(factory.await { codec.renderedPts.contains(seq) })
            Thread.sleep(100)
        }
        return factory.silentOutputPolls - before
    }

    @Test fun withParkOnTheGapsBetweenFramesAreNotPolledEvery5Ms() {
        val polls = pollsAt10Fps(make(park = true))
        assertTrue("silent polls $polls", polls <= 80) // park 20 ms + probe 5 ms: ~4 per 100 ms gap, not ~20
    }

    @Test fun withParkOffTheGapsKeepBeingPolled() {
        val polls = pollsAt10Fps(make(park = false))
        assertTrue("silent polls $polls", polls >= 120)
    }

    @Test fun withParkOnFramesAfterLongIdlesAreShownAtOnceAndInOrder() {
        val r = make(park = true)
        val codec = startStream(r)
        for (seq in 2L..12L) {
            Thread.sleep(if (seq == 2L) 600 else 60) // a long idle first, then ~10 fps gaps
            val t0 = System.nanoTime()
            r.onFrame(frame(seq))
            assertTrue("frame $seq", factory.await { codec.renderedPts.contains(seq) })
            val shownMs = (System.nanoTime() - t0) / ms
            assertTrue("frame $seq shown after $shownMs ms", shownMs < 200)
        }
        assertEquals((1L..12L).toList(), codec.renderedPts.toList())
        assertEquals(0, env.lines("decode_error").size)
    }

    @Test fun withParkOnADetachWhileParkedStopsAtOnceAndReleasesTheCodec() {
        val r = make(park = true)
        startStream(r)
        Thread.sleep(150)
        val t0 = System.nanoTime()
        r.detachSurface()
        val tookMs = (System.nanoTime() - t0) / ms
        assertTrue("detach took $tookMs ms", tookMs < 300)
        assertTrue(r.decoderThreadsFinished())
        assertEquals(1, env.lines("codec_stop").size)
        assertEquals(0, r.handoffWaitingThreads)
    }

    @Test fun withParkOnAFrameQueuedWhileTheOutputThreadIsInFlightStillComesOut() {
        // Several frames at once: each is counted in flight, the count drains back to empty and the thread parks again.
        val r = make(park = true)
        val codec = startStream(r)
        for (seq in 2L..6L) r.onFrame(frame(seq))
        assertTrue(factory.await { codec.renderedPts.contains(6L) })
        Thread.sleep(100)
        val before = factory.silentOutputPolls
        Thread.sleep(500)
        // idle again: park 20 ms + probe 5 ms, i.e. at most ~20 polls in 500 ms (a 5 ms poll would be 100)
        assertTrue("silent polls ${factory.silentOutputPolls - before}", factory.silentOutputPolls - before <= 40)
    }

    @Test fun withParkOnAFrameAfterTwoSecondsIdleAndThenABurstAllDecode() { // Codex P1
        val r = make(park = true)
        val codec = startStream(r)
        Thread.sleep(2_200)
        r.onFrame(frame(2))
        assertTrue("frame 2 after long idle", factory.await { codec.renderedPts.contains(2L) })
        Thread.sleep(1_200)
        for (seq in 3L..8L) r.onFrame(frame(seq))
        assertTrue("burst", factory.await { codec.renderedPts.contains(8L) })
        // The catch-up may show only some frames of a burst (it decodes all of them); what matters is no freeze after it.
        assertTrue(factory.await { outputsDequeued >= 8 })
        r.onFrame(frame(9))
        assertTrue("frame after the burst", factory.await { codec.renderedPts.contains(9L) })
    }
}
