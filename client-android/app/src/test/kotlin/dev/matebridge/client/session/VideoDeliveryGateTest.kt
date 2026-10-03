package dev.matebridge.client.session

import dev.matebridge.client.protocol.Bytes
import dev.matebridge.client.protocol.Hello
import dev.matebridge.client.protocol.HelloAck
import dev.matebridge.client.protocol.KeyframeRequest
import dev.matebridge.client.protocol.StreamConfig
import dev.matebridge.client.protocol.VideoFrame
import dev.matebridge.client.protocol.VideoHello
import dev.matebridge.client.session.SessionMachine.Action
import dev.matebridge.client.session.SessionMachine.Event
import dev.matebridge.client.video.FakeDecoderFactory
import dev.matebridge.client.video.TestDecoderEnv
import dev.matebridge.client.video.VideoRenderer
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.locks.LockSupport
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * T-160: which video connection may deliver frames to the renderer. The gate is driven by the same machine actions
 * [SessionController] executes (directly or through a real [SessionMachine]); "a reader" is a thread calling
 * [VideoDeliveryGate.deliver] like `VideoConn`, and "abort" is [VideoDeliveryGate.close] like `VideoConn.abort()`.
 */
class VideoDeliveryGateTest {
    private val gate = VideoDeliveryGate()
    private val videoEp = Endpoint("10.0.0.5", 7421)

    private fun cfg(id: Int) = StreamConfig(id, StreamConfig.CODEC_HEVC, 2800, 1840, 1400, 920, 60, 20000, 1, 1, 1, 1)
    private fun open(gen: Int, configId: Int) = gate.onAction(Action.OpenVideo(gen, videoEp, VideoHello(0, configId, 77)))

    /** A STREAM_CONFIG as the engine executes it (ApplyConfig → CloseVideo → OpenVideo), optionally installed by the UI. */
    private fun streamConfig(c: StreamConfig, videoGen: Int, install: Boolean = true) {
        gate.onAction(Action.ApplyConfig(c))
        gate.onAction(Action.CloseVideo)
        open(videoGen, c.configId)
        if (install) gate.install(c)
    }

    private fun delivers(gen: Int, configId: Int): Boolean {
        var ran = false
        val result = gate.deliver(gen, configId) { ran = true }
        assertEquals(ran, result)
        return ran
    }

    /** Waits (bounded) until [t] blocks or ends; true when it is blocked, i.e. still waiting. */
    private fun awaitBlocked(t: Thread): Boolean {
        val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(5)
        while (System.nanoTime() < deadline) {
            when (t.state) {
                Thread.State.BLOCKED, Thread.State.WAITING -> return true
                Thread.State.TERMINATED -> return false
                else -> LockSupport.parkNanos(1_000_000)
            }
        }
        return false
    }

    // ---- X4: the abort barrier ----

    @Test fun aReaderReleasedAfterAbortAndAVideoReconnectDeliversNothing() {
        streamConfig(cfg(1), videoGen = 3)
        val atBarrier = CountDownLatch(1)
        val release = CountDownLatch(1)
        val delivered = AtomicInteger()
        val reader = Thread {
            atBarrier.countDown()
            release.await() // a frame decoded, just before delivery
            gate.deliver(3, 1) { delivered.incrementAndGet() }
        }
        reader.start()
        assertTrue(atBarrier.await(5, TimeUnit.SECONDS))
        // Engine: the reader's connection is aborted and a new one of the same config (video-only reconnect) opened.
        gate.close(3)
        gate.onAction(Action.CloseVideo)
        open(4, 1)
        release.countDown()
        reader.join(5_000)
        assertEquals(0, delivered.get())
        assertTrue("the new connection delivers", delivers(4, 1))
    }

    @Test fun aReaderReleasedAfterTheSessionChangedDeliversNothing() {
        streamConfig(cfg(1), videoGen = 3)
        val atBarrier = CountDownLatch(1)
        val release = CountDownLatch(1)
        val delivered = AtomicInteger()
        val reader = Thread {
            atBarrier.countDown()
            release.await()
            gate.deliver(3, 1) { delivered.incrementAndGet() }
        }
        reader.start()
        assertTrue(atBarrier.await(5, TimeUnit.SECONDS))
        gate.close(3) // VideoConn.abort() on the session's close
        gate.onAction(Action.CloseControl(graceful = false))
        streamConfig(cfg(1), videoGen = 6) // the next session's first config is 1 again
        release.countDown()
        reader.join(5_000)
        assertEquals(0, delivered.get())
    }

    @Test fun bufferedRecordsAfterAbortAreNotDelivered() {
        streamConfig(cfg(1), videoGen = 3)
        assertTrue(delivers(3, 1))
        gate.close(3)
        // The reader's inner loop still holds complete records decoded from its last read.
        assertEquals(0, (1..5).count { delivers(3, 1) })
        // and they stay undeliverable after a video-only reconnect with the same config
        gate.onAction(Action.CloseVideo)
        open(4, 1)
        assertEquals(0, (1..5).count { delivers(3, 1) })
    }

    @Test fun abortWaitsForADeliveryInFlight() {
        streamConfig(cfg(1), videoGen = 3)
        val inDelivery = CountDownLatch(1)
        val finish = CountDownLatch(1)
        val reader = Thread { gate.deliver(3, 1) { inDelivery.countDown(); finish.await() } }
        reader.start()
        assertTrue(inDelivery.await(5, TimeUnit.SECONDS))
        val closed = AtomicBoolean(false)
        val engine = Thread { gate.close(3); closed.set(true) }
        engine.start()
        try {
            assertTrue("abort() returned while a delivery was in flight", awaitBlocked(engine))
            assertFalse(closed.get())
        } finally {
            finish.countDown()
        }
        engine.join(5_000)
        reader.join(5_000)
        assertTrue(closed.get())
        assertFalse(delivers(3, 1))
    }

    @Test fun anOlderConnectionsAbortDoesNotCloseTheCurrentOne() {
        streamConfig(cfg(1), videoGen = 3)
        gate.onAction(Action.CloseVideo)
        open(4, 1)
        gate.close(3) // a late abort of the replaced connection
        assertTrue(delivers(4, 1))
    }

    // ---- frames of a config the renderer has not installed ----

    @Test fun framesOfAConfigTheRendererHasNotInstalledAreDropped() {
        streamConfig(cfg(1), videoGen = 3)
        assertTrue(delivers(3, 1))
        streamConfig(cfg(2), videoGen = 4, install = false)
        assertFalse("new-config frame reached the old codec", delivers(4, 2))
        assertFalse(delivers(3, 1))
        gate.install(cfg(1)) // an equal but different object is not the applied config
        assertFalse(delivers(4, 2))
        val c2 = cfg(2)
        streamConfig(c2, videoGen = 5, install = false)
        gate.install(c2)
        assertTrue(delivers(5, 2))
    }

    @Test fun installingAfterDroppedFramesSendsOneStartupAndNoFramesDroppedStorm() {
        val factory = FakeDecoderFactory()
        val env = TestDecoderEnv()
        val kf = CopyOnWriteArrayList<Int>()
        val a = cfg(1)
        val b = cfg(2)
        val r = VideoRenderer(a, onKeyframeRequest = { kf.add(it) }, codecFactory = factory, env = env,
            onConfigInstalled = gate::install)
        fun frame(seq: Long, flags: Int) = VideoFrame(seq, seq * 1000, flags, 0, 1, 4, Bytes(byteArrayOf(0, 0, 0, 1)))
        fun feed(gen: Int, configId: Int, f: VideoFrame) = gate.deliver(gen, configId) { r.onFrame(f) }
        try {
            // Config A: the engine opens its reader, the UI installs A (MainActivity.installConfig order) and attaches.
            streamConfig(a, videoGen = 3, install = false)
            r.reconfigure(a)
            r.attachTarget(Any())
            assertTrue(factory.awaitEvent("start#1"))
            assertTrue(feed(3, 1, frame(1, VideoFrame.CODEC_CONFIG)))
            assertTrue(feed(3, 1, frame(2, VideoFrame.KEYFRAME)))
            assertTrue(factory.await { queuedInputs >= 2 })
            kf.clear()

            // STREAM_CONFIG B: the engine switches readers before the UI thread reconfigures the renderer.
            streamConfig(b, videoGen = 4, install = false)
            var passed = 0
            for (i in 0 until 40) {
                val flags = when (i) { 0 -> VideoFrame.CODEC_CONFIG; 1 -> VideoFrame.KEYFRAME; else -> 0 }
                if (feed(4, 2, frame(100L + i, flags))) passed++
                if (feed(3, 1, frame(200L + i, 0))) passed++ // the old reader's last records
            }
            assertEquals("frames reached the old codec's queue", 0, passed)
            assertEquals(emptyList<Int>(), kf.toList())

            r.reconfigure(b) // the UI's installConfig
            assertEquals(listOf(KeyframeRequest.STARTUP), kf.toList())
            assertTrue(factory.awaitEvent("start#2"))
            // The host answers STARTUP with CODEC_CONFIG + keyframe (T-030); the stream continues.
            assertTrue(feed(4, 2, frame(300, VideoFrame.CODEC_CONFIG)))
            assertTrue(feed(4, 2, frame(301, VideoFrame.KEYFRAME)))
            assertTrue(factory.await { queuedInputs >= 4 })
            assertTrue(feed(4, 2, frame(302, 0)))
            assertTrue(factory.await { queuedInputs >= 5 })
            assertEquals(listOf(KeyframeRequest.STARTUP), kf.toList())
            assertTrue(env.lines("kf_request").none { "reason=${KeyframeRequest.FRAMES_DROPPED}" in it })
        } finally {
            r.detachSurface()
        }
    }

    // ---- driven by a real SessionMachine ----

    private val hello = Hello(0, Bytes(ByteArray(16) { it.toByte() }), 2800, 1840, 360, 144, 0xFF, "MatePad")
    private val m = SessionMachine(hello)
    private var now = 1_000_000L

    /** One machine step; its actions reach the gate as in `SessionController.exec`. */
    private fun step(e: Event, advanceUs: Long = 0): List<Action> {
        now += advanceUs
        return m.handle(e, now).also { it.forEach(gate::onAction) }
    }

    /** The config object of the latest ApplyConfig (what the UI installs). */
    private var lastApplied: StreamConfig? = null

    private fun ack() = HelloAck(0, HelloAck.ACCEPTED, 77, 7421, "Mac mini")

    private fun connectAccepted(): Int {
        val open = step(Event.Start(Endpoint("10.0.0.5", 7420))).filterIsInstance<Action.OpenControl>().single()
        step(Event.ControlOpened(open.gen))
        step(Event.Received(open.gen, ack()))
        return open.gen
    }

    /** A STREAM_CONFIG from the host; the UI installs the applied object. Returns the new reader's generation. */
    private fun receiveConfig(ctlGen: Int, c: StreamConfig, install: Boolean = true): Int {
        val actions = step(Event.Received(ctlGen, c))
        val applied = actions.filterIsInstance<Action.ApplyConfig>().single().config
        lastApplied = applied
        if (install) gate.install(applied)
        return actions.filterIsInstance<Action.OpenVideo>().single().gen
    }

    @Test fun theActionsOfAStreamConfigLeaveTheNewReaderDeliverable() {
        val ctl = connectAccepted()
        val v1 = receiveConfig(ctl, cfg(1))
        assertTrue(delivers(v1, 1))
        val v2 = receiveConfig(ctl, cfg(2))
        assertEquals(2, gate.currentConfigId)
        assertTrue(delivers(v2, 2))
        assertFalse(delivers(v1, 1))
    }

    @Test fun aVideoOnlyReconnectWithTheSameConfigStaysDeliverable() {
        val ctl = connectAccepted()
        val v1 = receiveConfig(ctl, cfg(3))
        assertTrue(delivers(v1, 3))
        step(Event.VideoClosed(v1))
        step(Event.Received(ctl, dev.matebridge.client.protocol.Pong(0, 0, 0)), 450_000)
        val v2 = step(Event.Tick(0), 100_000).filterIsInstance<Action.OpenVideo>().single().gen
        assertNotEquals(v1, v2)
        assertEquals(3, gate.currentConfigId)
        assertTrue("no re-install needed for the same config", delivers(v2, 3))
        assertFalse(delivers(v1, 3))
    }

    @Test fun sameConfigIdOneInConsecutiveSessionsDoesNotLeakFrames() {
        val ctl1 = connectAccepted()
        val v1 = receiveConfig(ctl1, cfg(1))
        assertTrue(delivers(v1, 1))
        // Session N is lost (heartbeat): CloseControl + CloseVideo.
        val lost = step(Event.Tick(0), SessionMachine.PONG_TIMEOUT_US)
        assertTrue(lost.any { it is Action.CloseControl })
        assertEquals(-1, gate.currentConfigId)
        assertFalse(delivers(v1, 1))
        // Session N+1 after the backoff: its first config is 1 again.
        val open = step(Event.Tick(0), SessionMachine.BACKOFF_START_US).filterIsInstance<Action.OpenControl>().single()
        step(Event.ControlOpened(open.gen))
        step(Event.Received(open.gen, ack()))
        val v2 = receiveConfig(open.gen, cfg(1), install = false)
        assertFalse("session N's reader delivered into session N+1", delivers(v1, 1))
        assertFalse("not installed yet: the renderer still holds session N's config", delivers(v2, 1))
        gate.install(lastApplied!!) // the UI's installConfig of session N+1's config
        assertTrue(delivers(v2, 1))
        assertFalse(delivers(v1, 1))
    }

    @Test fun configIdIsResetOnCloseControlAndPromotionButNotOnCloseVideo() {
        gate.onAction(Action.ApplyConfig(cfg(4)))
        gate.onAction(Action.CloseVideo)
        assertEquals(4, gate.currentConfigId)
        gate.onAction(Action.CloseControl(graceful = true))
        assertEquals(-1, gate.currentConfigId)
        gate.onAction(Action.ApplyConfig(cfg(5)))
        gate.onAction(Action.PromoteCandidate(9, Endpoint("10.0.0.6", 7420))) // a migrated session is a new session
        assertEquals(-1, gate.currentConfigId)
    }
}
