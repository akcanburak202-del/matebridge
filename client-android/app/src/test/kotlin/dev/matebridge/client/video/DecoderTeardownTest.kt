package dev.matebridge.client.video

import dev.matebridge.client.protocol.Bytes
import dev.matebridge.client.protocol.StreamConfig
import dev.matebridge.client.protocol.VideoFrame
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.locks.Condition
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * T-161: bounded decoder hand-off and per-generation state, on the real [VideoRenderer] threads with the T-158 fake.
 * Every gate is opened in `finally` and in [tearDown], so a failing assertion never leaves a thread blocked. Waits are
 * monitor/latch waits with a timeout; nothing sleeps.
 */
class DecoderTeardownTest {
    private val config = StreamConfig(1, StreamConfig.CODEC_HEVC, 2800, 1840, 1400, 920, 60, 50000, 1, 13, 1, 1)
    private val factory = FakeDecoderFactory()
    private val env = TestDecoderEnv()
    private val health = HealthEvents()
    private val renderers = CopyOnWriteArrayList<VideoRenderer>()
    private val renderer = make()

    private fun make(
        timer: HandoffTimer = HandoffTimer.SYSTEM,
        delaysMs: LongArray = RestartPolicy.DELAYS_MS,
    ) = VideoRenderer(
        config,
        onKeyframeRequest = {},
        codecFactory = factory,
        env = env,
        onHealthEvent = health::add,
        handoffTimer = timer,
        restartDelaysMs = delaysMs,
    ).also { renderers.add(it) }

    @After fun tearDown() {
        factory.stopGate?.countDown(); factory.releaseGate?.countDown(); factory.dequeueOutputGate?.countDown()
        for (r in renderers) r.detachSurface()
    }

    /** M03 (a): an old generation that never leaves `stop()` must not park the next one without bound. */
    @Test fun aHungPreviousGenerationIsReportedStuckWithinTwoSecondsAndNoCodecIsOpened() {
        val stopGate = CountDownLatch(1)
        factory.stopGate = stopGate
        renderer.attachTarget(Any())
        assertTrue(env.awaitLines("codec_start"))
        try {
            renderer.reconfigure(config) // generation 2; generation 1 hangs in stop() for good
            assertTrue("first codec never stopped", factory.awaitEvent("stop#1>"))
            val startNs = System.nanoTime()
            val fault = health.await(3_000) { it is HealthEvent.Fault && it.gen == 2 }
            val waitedMs = TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - startNs)
            assertTrue("no stuck fault within 3 s (waited ${waitedMs} ms): ${health.all}", fault != null)
            assertEquals(FaultCause.STUCK, (fault as HealthEvent.Fault).cause)
            assertTrue("waited $waitedMs ms", waitedMs <= VideoRenderer.PREVIOUS_WAIT_MS + 1_000)
            val line = env.lines("decoder_previous_stuck").single()
            assertTrue(line, line.contains(" W decoder ev=decoder_previous_stuck vgen=2 prev_vgen=1 waited_ms="))
            assertTrue(line, line.endsWith(" out_straggler=0"))
            val waitedField = line.substringAfter("waited_ms=").substringBefore(' ').toLong()
            assertTrue(line, waitedField in VideoRenderer.PREVIOUS_WAIT_MS..VideoRenderer.PREVIOUS_WAIT_MS + 1_000)
            assertEquals("no codec while the previous one is stuck", 1, factory.createCalls)
            assertNotNull(health.await { it == HealthEvent.Exited(2) })
            assertTrue("a stuck generation never runs", HealthEvent.Running(2) !in health.all)
            assertFalse("a stuck generation is not fed", renderer.feeding)
        } finally {
            stopGate.countDown()
        }
    }

    /** M03 (b): an output thread that outlives its 500 ms join must not touch the next generation. */
    @Test fun aStragglerOutputThreadIsWaitedForAndCannotTakeTheNextGenerationsFirstOutputBypass() {
        factory.produceOutput = true
        renderer.attachTarget(Any())
        assertTrue(env.awaitLines("codec_start"))
        val gate = CountDownLatch(1)
        factory.dequeueOutputGate = gate
        try {
            assertTrue("output thread not parked", factory.awaitEvent("dequeueOutput#1>"))
            renderer.onFrame(frame(0, VideoFrame.CODEC_CONFIG))
            renderer.onFrame(frame(1, VideoFrame.KEYFRAME)) // waits as a ready output behind the gate
            assertTrue(factory.await { queuedInputs >= 2 })

            renderer.reconfigure(config) // generation 2
            // Generation 1's decoder thread gives up on its output thread after 500 ms and stops the codec.
            assertTrue("codec 1 never stopped", env.awaitLines("codec_stop"))
            // Its output thread is still inside dequeueOutputBuffer: generation 1 is not finished.
            assertFalse("codec 2 created while generation 1's output thread was alive",
                factory.awaitEvent("create#2", timeoutMs = 500))
            renderer.firstOutput.arm() // the vsync loop fell asleep: generation 2's first output must go out at once
        } finally {
            gate.countDown() // the straggler returns with generation 1's output
        }
        assertTrue("straggler never released its output", factory.awaitEvent("releaseOutput#1"))
        assertTrue("generation 2 never started a codec", factory.awaitEvent("start#2"))

        val ev = factory.events
        assertTrue("codec 2 created before the straggler left: $ev",
            ev.indexOf("dequeueOutput#1<") in 0 until ev.indexOf("create#2"))
        assertTrue("the straggler consumed generation 2's first-output bypass", renderer.firstOutput.isArmed)
        assertTrue(env.lines("output_straggler").single().contains(" W decoder ev=output_straggler vgen=1 join_ms=500"))
        // The straggler's frame counted nowhere: no output of generation 1 reached the shared stats or the health.
        assertEquals(0L, renderer.stats.snapshot().decoded)
        assertTrue(health.all.none { it is HealthEvent.FirstOutput })

        // Generation 2 runs normally with its own state: its first output takes the bypass.
        renderer.onFrame(frame(2, VideoFrame.CODEC_CONFIG))
        renderer.onFrame(frame(3, VideoFrame.KEYFRAME))
        assertNotNull(health.await { it == HealthEvent.FirstOutput(2) })
        assertTrue(factory.awaitEvent("releaseOutput#2"))
        assertFalse(renderer.firstOutput.isArmed)
    }

    @Test fun repeatedAttachesWhileStuckKeepOneWaitingThreadAndOpenNoCodec() {
        val timer = SignalTimer()
        val r = make(timer = timer)
        val stopGate = CountDownLatch(1)
        factory.stopGate = stopGate
        r.attachTarget(Any())
        assertTrue(env.awaitLines("codec_start"))
        try {
            r.reconfigure(config) // generation 2 waits for the hung generation 1
            assertTrue(factory.awaitEvent("stop#1>"))
            for (i in 3..6) r.reconfigure(config) // each retires the waiting generation before it
            for (g in 2..5) assertNotNull("generation $g kept waiting", health.await { it == HealthEvent.Exited(g) })
            assertTrue("generation 6 never waited", timer.awaitInside(1))
            assertEquals("waiting decoder threads", 1, r.handoffWaitingThreads)
            assertEquals(1, factory.createCalls)
            assertTrue(health.all.none { it is HealthEvent.Running && it.gen > 1 })

            // Only the last one times out; the retired ones never report a fault.
            assertNotNull(health.await { it == HealthEvent.Fault(6, FaultCause.STUCK) })
            assertNotNull(health.await { it == HealthEvent.Exited(6) })
            assertEquals(1, env.lines("decoder_previous_stuck").size)
            assertEquals(0, r.handoffWaitingThreads)
            assertEquals(listOf(HealthEvent.Fault(6, FaultCause.STUCK)), health.all.filterIsInstance<HealthEvent.Fault>())
        } finally {
            stopGate.countDown()
        }
        // Once the hung generation finally finishes, the recovery step (decision 0019 ladder) opens a codec again.
        assertTrue(factory.awaitEvent("release#1<"))
        r.restartCodec()
        assertTrue("no codec after the stuck generation finished", factory.awaitEvent("start#2"))
        assertNotNull(health.await { it == HealthEvent.Running(7) })
    }

    @Test fun restartsBackOff100Then500Then1000MsAndTheThreePerTenSecondsRuleStillGivesUp() {
        val timer = FakeClockTimer(env)
        val r = make(timer = timer)
        factory.failCreates = 4
        r.attachTarget(Any())
        assertNotNull(health.await { it == HealthEvent.Fault(1, FaultCause.GIVE_UP) })
        assertEquals(listOf(100L, 500L, 1_000L), timer.waits)
        assertEquals(4, factory.createCalls)
        assertEquals(4, env.lines("decode_error").size)
        assertEquals(1, env.lines("give_up").size)
        // The decode_error lines are stamped by the fake clock: each restart came after its backoff.
        val stamps = env.lines("decode_error").map { it.substringAfter("MB/decoder ").substringBefore(' ').toLong() }
        assertEquals(listOf(1_000L, 1_100L, 1_600L, 2_600L), stamps)
    }

    @Test fun aDetachDuringABackoffWaitWakesItAndStaysWithinJoinMs() {
        val inPause = CountDownLatch(1)
        val timer = object : HandoffTimer {
            override fun nowMs() = HandoffTimer.SYSTEM.nowMs()
            override fun await(condition: Condition, ms: Long) {
                if (ms > 5_000) inPause.countDown() // the restart backoff below, not a hand-off wait
                HandoffTimer.SYSTEM.await(condition, ms)
            }
        }
        val r = make(timer = timer, delaysMs = longArrayOf(60_000))
        factory.failCreates = 1
        r.attachTarget(Any())
        assertTrue("decoder thread never backed off", inPause.await(5, TimeUnit.SECONDS))

        val startNs = System.nanoTime()
        r.detachSurface()
        val tookMs = TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - startNs)

        assertTrue("detach took $tookMs ms", tookMs < VideoRenderer.JOIN_MS)
        assertEquals(0, env.lines("detach_slow").size)
        assertNotNull(health.await(1_000) { it == HealthEvent.Exited(1) })
        assertEquals("no restart after the detach", 1, factory.createCalls)
    }

    private fun frame(seq: Long, flags: Int) = VideoFrame(seq, seq * 1000, flags, 0, 1, 3, Bytes(byteArrayOf(0, 0, 1)))

    /** Health events in arrival order, with a monitor wait (no sleeps). */
    class HealthEvents {
        private val lock = Object()
        private val events = CopyOnWriteArrayList<HealthEvent>()
        val all: List<HealthEvent> get() = events.toList()

        fun add(e: HealthEvent) = synchronized(lock) { events.add(e); lock.notifyAll() }

        fun await(timeoutMs: Long = 5_000, match: (HealthEvent) -> Boolean): HealthEvent? {
            val deadline = System.nanoTime() + TimeUnit.MILLISECONDS.toNanos(timeoutMs)
            synchronized(lock) {
                while (true) {
                    events.firstOrNull(match)?.let { return it }
                    val leftMs = TimeUnit.NANOSECONDS.toMillis(deadline - System.nanoTime())
                    if (leftMs <= 0) return null
                    lock.wait(leftMs)
                }
            }
        }
    }

    /** Fake clock: every wait returns at once and advances the decoder env's clock by its full length. */
    class FakeClockTimer(private val env: TestDecoderEnv) : HandoffTimer {
        val waits = CopyOnWriteArrayList<Long>()
        override fun nowMs() = env.nowMs
        override fun await(condition: Condition, ms: Long) {
            waits.add(ms)
            env.nowMs += ms
        }
    }

    /** Real clock; tracks how many threads are inside [await] right now (monitor-notified). */
    class SignalTimer : HandoffTimer {
        private val lock = Object()
        private var inside = 0

        override fun nowMs() = HandoffTimer.SYSTEM.nowMs()
        override fun await(condition: Condition, ms: Long) {
            synchronized(lock) { inside++; lock.notifyAll() }
            try { HandoffTimer.SYSTEM.await(condition, ms) } finally { synchronized(lock) { inside--; lock.notifyAll() } }
        }

        /** Waits until exactly [n] threads are inside [await]. */
        fun awaitInside(n: Int, timeoutMs: Long = 5_000): Boolean {
            val deadline = System.nanoTime() + TimeUnit.MILLISECONDS.toNanos(timeoutMs)
            synchronized(lock) {
                while (inside != n) {
                    val leftMs = TimeUnit.NANOSECONDS.toMillis(deadline - System.nanoTime())
                    if (leftMs <= 0) return false
                    lock.wait(leftMs)
                }
                return true
            }
        }
    }
}
