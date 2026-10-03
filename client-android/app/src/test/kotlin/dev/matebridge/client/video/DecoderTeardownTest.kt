package dev.matebridge.client.video

import dev.matebridge.client.protocol.Bytes
import dev.matebridge.client.protocol.StreamConfig
import dev.matebridge.client.protocol.VideoFrame
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Ignore
import org.junit.Test

/**
 * T-161: bounded decoder hand-off and per-generation state, on the real [VideoRenderer] threads with the T-158 fake.
 * Every gate is opened in `finally` and in [tearDown], so a failing assertion never leaves a thread blocked.
 */
class DecoderTeardownTest {
    private val config = StreamConfig(1, StreamConfig.CODEC_HEVC, 2800, 1840, 1400, 920, 60, 50000, 1, 13, 1, 1)
    private val factory = FakeDecoderFactory()
    private val env = TestDecoderEnv()
    private val health = HealthEvents()
    private val renderer = VideoRenderer(
        config,
        onKeyframeRequest = {},
        codecFactory = factory,
        env = env,
        onHealthEvent = health::add,
    )

    @After fun tearDown() {
        factory.stopGate?.countDown(); factory.releaseGate?.countDown(); factory.dequeueOutputGate?.countDown()
        renderer.detachSurface()
    }

    /** M03 (a): an old generation that never leaves `stop()` must not park the next one without bound. */
    @Ignore("T-161 red: fails at HEAD, fixed in the next commit")
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
            assertTrue("waited $waitedMs ms", waitedMs <= 2_000 + 1_000) // decision 0019: 2 s bound
            assertEquals(1, env.lines("decoder_previous_stuck").size)
            assertEquals("no codec while the previous one is stuck", 1, factory.createCalls)
        } finally {
            stopGate.countDown()
        }
    }

    /** M03 (b): an output thread that outlives its 500 ms join must not touch the next generation. */
    @Ignore("T-161 red: fails at HEAD, fixed in the next commit")
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
}
