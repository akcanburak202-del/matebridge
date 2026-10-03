package dev.matebridge.client.video

import dev.matebridge.client.protocol.Bytes
import dev.matebridge.client.protocol.KeyframeRequest
import dev.matebridge.client.protocol.StreamConfig
import dev.matebridge.client.protocol.VideoFrame
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * T-158: the decoder lifecycle of the real [VideoRenderer] threads, driven through [FakeDecoderFactory]. These tests
 * document today's behaviour (no fix); T-159 / T-161 are expected to change some of them.
 */
class DecoderLifecycleTest {
    private val config = StreamConfig(1, StreamConfig.CODEC_HEVC, 2800, 1840, 1400, 920, 60, 50000, 1, 13, 1, 1)
    private val factory = FakeDecoderFactory()
    private val env = TestDecoderEnv()
    private val kfRequests = CopyOnWriteArrayList<Int>()
    private val giveUps = CopyOnWriteArrayList<String>()
    private val gaveUp = CountDownLatch(1)
    private val renderer = VideoRenderer(
        config,
        onKeyframeRequest = { kfRequests.add(it) },
        onGiveUp = { giveUps.add(it); gaveUp.countDown() },
        codecFactory = factory,
        env = env,
    )

    @After fun tearDown() {
        // Never leave a decoder thread blocked on a gate, whatever the test did.
        factory.stopGate?.countDown(); factory.releaseGate?.countDown(); factory.dequeueOutputGate?.countDown()
        renderer.detachSurface()
    }

    @Test fun fourFailingCreatesGiveUpAfterThreeRestartsAndStayAttached() {
        factory.failCreates = 4 // the clock stands still: all four failures fall in one 10 s window

        renderer.attachTarget(Any())

        assertTrue("onGiveUp not called", gaveUp.await(5, TimeUnit.SECONDS))
        assertEquals(4, factory.createCalls)
        assertEquals(1, giveUps.size)
        assertTrue(giveUps[0], giveUps[0].startsWith("decoder failed repeatedly: IOException"))
        assertEquals(4, env.lines("decode_error").size)
        assertTrue(env.lines("decode_error").all { "err=IOException" in it })
        assertEquals(1, env.lines("give_up").size)
        assertEquals(4, env.lines("codec_stop").size) // runCodec.finally runs even when create failed
        assertEquals(0, env.lines("codec_start").size)
        // One request when the surface was attached, then one per restart; none for the give-up.
        assertEquals(3, kfRequests.count { it == KeyframeRequest.DECODE_ERROR })
        assertEquals(4, kfRequests.size)
        // As-is (T-159 changes this): the renderer still reports a surface after giving up.
        assertTrue(renderer.attached)
    }

    @Test fun aNewAttachmentStartsNoCodecUntilThePreviousDecoderThreadHasExited() {
        val stopGate = CountDownLatch(1)
        factory.stopGate = stopGate
        renderer.attachTarget(Any())
        assertTrue(env.awaitLines("codec_start"))

        try {
            renderer.reconfigure(config) // retires the first thread without waiting; the new one waits for it
            assertTrue("first codec never stopped", factory.awaitEvent("stop#1>"))
            // previous.join() has no timeout: while the old thread hangs in stop(), longer than both JOIN_MS and the
            // 500 ms output-thread join, the new thread creates nothing.
            assertFalse("second codec created while the first was stopping",
                factory.awaitEvent("create#2", timeoutMs = 700))
        } finally {
            stopGate.countDown()
        }

        assertTrue("second codec never created", factory.awaitEvent("start#2"))
        val ev = factory.events
        assertTrue(ev.toString(), ev.indexOf("release#1<") in 0 until ev.indexOf("create#2"))
        assertEquals(listOf("create#1", "configure#1", "start#1", "stop#1>", "stop#1<", "release#1>", "release#1<",
            "create#2", "configure#2", "start#2"), ev)
        assertEquals(1, env.lines("codec_stop").size)
        assertEquals(0, env.lines("decode_error").size)
    }

    @Test fun aSilentCodecThatAcceptsInputButNeverOutputsRaisesNoDecodeError() {
        renderer.attachTarget(Any())
        assertTrue(env.awaitLines("codec_start"))

        renderer.onFrame(frame(0, VideoFrame.CODEC_CONFIG))
        renderer.onFrame(frame(1, VideoFrame.KEYFRAME))
        assertTrue(factory.await { queuedInputs >= 2 })
        for (seq in 2L..30L) { // one at a time, so the bounded queue never overflows
            renderer.onFrame(frame(seq, 0))
            assertTrue("frame $seq not queued", factory.await { queuedInputs >= seq.toInt() + 1 })
        }
        // Let the output thread poll the silent codec a while longer after the last input.
        val polls = factory.silentOutputPolls
        assertTrue(factory.await { silentOutputPolls >= polls + 20 })

        // As-is (T-028 no-output case): nothing notices; no error, no restart, no give-up.
        assertEquals(0, env.lines("decode_error").size)
        assertEquals(0, env.lines("give_up").size)
        assertEquals(0, giveUps.size)
        assertEquals(1, factory.createCalls)
        assertEquals(0, factory.count("releaseOutput#1"))
        assertTrue(renderer.attached)
    }

    @Test fun codecStartLineKeepsItsFields() {
        renderer.attachTarget(Any())
        assertTrue(env.awaitLines("codec_start"))
        val line = env.lines("codec_start").single()
        assertTrue(line, line.contains(" I decoder ev=codec_start name=fake.decoder mime=video/hevc size=2800x1840 " +
            "low_latency=on requested_rate="))
        assertTrue(line, line.contains(" accepted priority=0 operating_rate="))
        assertTrue(line, line.endsWith(" low_latency_fmt=1"))
        assertEquals("fake.decoder 2800x1840 lowLatency=on", renderer.codecInfo)
    }

    private fun frame(seq: Long, flags: Int) = VideoFrame(seq, seq * 1000, flags, 0, 1, 3, Bytes(byteArrayOf(0, 0, 1)))
}
