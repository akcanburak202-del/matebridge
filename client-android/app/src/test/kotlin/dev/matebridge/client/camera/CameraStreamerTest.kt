package dev.matebridge.client.camera

import dev.matebridge.client.protocol.Bytes
import dev.matebridge.client.protocol.CamFrame
import dev.matebridge.client.protocol.CamHello
import dev.matebridge.client.protocol.CamHelloAck
import dev.matebridge.client.protocol.CamKeyframeRequest
import dev.matebridge.client.protocol.Codec
import dev.matebridge.client.protocol.Limits
import dev.matebridge.client.protocol.Message
import dev.matebridge.client.protocol.MsgType
import dev.matebridge.client.protocol.Ping
import dev.matebridge.client.security.PlainFrames
import dev.matebridge.client.security.RecordDecoder
import dev.matebridge.client.security.RecordOpener
import dev.matebridge.client.security.RecordSealer
import dev.matebridge.client.security.SessionSecrets
import java.io.IOException
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class CameraStreamerTest {
    private val secrets = SessionSecrets(ByteArray(32) { (it * 3).toByte() }, pairing = false, hostId = ByteArray(16))
    private val toClose = CopyOnWriteArrayList<AutoCloseable>()

    @After fun tearDown() {
        toClose.forEach { try { it.close() } catch (_: Exception) {} }
    }

    private val config = byteArrayOf(0, 0, 0, 1, 0x67, 0x64, 0, 0x28)
    private fun nal(tag: Int, size: Int = 16) = ByteArray(size) { if (it < 4) (if (it == 3) 1 else 0).toByte() else tag.toByte() }

    /** The camera side, faked: records the calls; emits the config on start and a keyframe when asked for one. */
    private class FakePipeline : CameraPipeline {
        @Volatile var sink: CameraPipeline.Sink? = null
        val keyRequests = AtomicInteger()
        val stops = AtomicInteger()
        val starts = AtomicInteger()
        var facings = CopyOnWriteArrayList<CameraFacing>()
        @Volatile var keyOnRequest = true
        lateinit var config: ByteArray
        private var ts = 1_000L

        override fun start(facing: CameraFacing, width: Int, height: Int, fps: Int, bitrateKbps: Int, sink: CameraPipeline.Sink) {
            starts.incrementAndGet()
            this.sink = sink
            sink.onConfig(config, ts)
        }

        override fun switchFacing(facing: CameraFacing) { facings += facing; sink?.onConfig(config, ts++) }
        override fun requestKeyframe() {
            keyRequests.incrementAndGet()
            if (keyOnRequest) sink?.onFrame(ByteArray(32) { 5 }, ts++, true)
        }

        override fun stop() { stops.incrementAndGet() }
        fun delta(tag: Int = 9) = sink?.onFrame(ByteArray(24) { tag.toByte() }, ts++, false)
    }

    /** The Mac side, faked: one TCP listener that does the camera connection protocol with real keys. */
    private inner class FakeHost(
        val answer: Int = CamHelloAck.OK,
        val closeAfterHello: Boolean = false,
    ) {
        val server = ServerSocket(0, 50, InetAddress.getByName("127.0.0.1")).also { toClose += it }
        val accepts = AtomicInteger()
        val hellos = CopyOnWriteArrayList<CamHello>()
        val messages = CopyOnWriteArrayList<Message>()
        @Volatile var sealer: RecordSealer? = null
        @Volatile var out: java.io.OutputStream? = null
        @Volatile var eof = CountDownLatch(1)
        val port get() = server.localPort

        init {
            Thread({
                try {
                    while (true) serve(server.accept().also { toClose += it })
                } catch (_: IOException) {
                }
            }, "fake-cam-host").also { it.isDaemon = true; it.start() }
        }

        private fun serve(s: Socket) {
            accepts.incrementAndGet()
            Thread({
                try {
                    val input = s.getInputStream()
                    val frame = PlainFrames.read(input)
                    val hello = Codec.decodePayload(frame.type, frame.payload) as CamHello
                    hellos += hello
                    if (closeAfterHello) { s.close(); return@Thread }
                    val hostNonce = ByteArray(16) { (0xA0 + it).toByte() }
                    val o = s.getOutputStream()
                    o.write(Codec.encode(CamHelloAck(answer, Bytes(if (answer == CamHelloAck.OK) hostNonce else ByteArray(16)))))
                    o.flush()
                    if (answer != CamHelloAck.OK) { s.close(); return@Thread }
                    val keys = secrets.cameraKeys(hello.clientCamNonce.value, hostNonce)
                    sealer = RecordSealer(keys.h2c)
                    out = o
                    val dec = RecordDecoder(Limits.VIDEO_MAX_PAYLOAD, RecordOpener(keys.c2h))
                    val buf = ByteArray(8192)
                    while (true) {
                        val n = input.read(buf)
                        if (n < 0) break
                        dec.feed(buf, 0, n)
                        while (true) messages += dec.next() ?: break
                    }
                } catch (_: Exception) {
                } finally {
                    eof.countDown()
                }
            }, "fake-cam-conn").also { it.isDaemon = true; it.start() }
        }

        fun sendKeyframeRequest(reason: Int) {
            val o = out!!
            o.write(sealer!!.seal(MsgType.CAM_KEYFRAME_REQUEST, Codec.encodePayload(CamKeyframeRequest(reason))))
            o.flush()
        }

        fun frames() = messages.filterIsInstance<CamFrame>()
    }

    private fun waitFor(what: String, timeoutMs: Long = 5_000, cond: () -> Boolean) {
        val until = System.nanoTime() + timeoutMs * 1_000_000
        while (!cond()) {
            if (System.nanoTime() > until) throw AssertionError("timeout waiting for $what")
            Thread.sleep(5)
        }
    }

    private fun streamer(
        pipeline: FakePipeline, host: FakeHost, gaveUp: AtomicInteger = AtomicInteger(),
        retryDelayMs: Long = 20, ackTimeoutMs: Int = 2_000,
    ): CameraStreamer {
        pipeline.config = config
        val plan = CameraPlan(7, host.port, 1920, 1080, 30, 6000)
        val ctx = CameraSessionCtx(1, "127.0.0.1", 0xA1B2C3D4L, secrets)
        return CameraStreamer(
            plan, ctx, CameraFacing.FRONT, pipeline, { _, _ -> gaveUp.incrementAndGet() },
            retryDelayMs = retryDelayMs, statsIntervalMs = 60_000, ackTimeoutMs = ackTimeoutMs,
        ).also { toClose += AutoCloseable { it.close("test") } }
    }

    @Test fun handshakeThenProofThenConfigThenKeyframeThenFramesInOrder() {
        val host = FakeHost()
        val pipe = FakePipeline()
        val s = streamer(pipe, host).start()
        waitFor("config and keyframe") { host.frames().size >= 2 }
        // CAM_HELLO: protocol 1, the session id and cam_id of the START, a fresh 16-byte nonce
        val hello = host.hellos.single()
        assertEquals(Limits.PROTOCOL_VERSION, hello.protocolVersion)
        assertEquals(0xA1B2C3D4L, hello.sessionId)
        assertEquals(7, hello.camId)
        assertEquals(16, hello.clientCamNonce.size)
        // the first sealed record is the PING proof, then CODEC_CONFIG (seq 0), then the keyframe (seq 1)
        assertTrue(host.messages[0] is Ping)
        assertEquals(0L, (host.messages[0] as Ping).seq)
        val f = host.frames()
        assertTrue(f[0].codecConfig)
        assertEquals(0L, f[0].frameSeq)
        assertArrayEquals(config, f[0].data.value)
        assertTrue(f[1].keyframe)
        assertFalse(f[1].codecConfig)
        assertEquals(1L, f[1].frameSeq)
        pipe.delta(); pipe.delta()
        waitFor("two deltas") { host.frames().size >= 4 }
        val g = host.frames()
        assertEquals(listOf(0L, 1L, 2L, 3L), g.take(4).map { it.frameSeq })
        assertEquals(0, g[2].flags)
        assertEquals(1, host.accepts.get())
        s.close("test")
    }

    @Test fun thePipelineIsAskedForAKeyframeWhenTheLinkComesUp() {
        val host = FakeHost()
        val pipe = FakePipeline()
        streamer(pipe, host).start()
        waitFor("link up") { host.frames().size >= 2 }
        assertTrue(pipe.keyRequests.get() >= 2)
    }

    @Test fun aHostKeyframeRequestAsksTheEncoderAndTheNextKeyframeCarriesTheConfig() {
        val host = FakeHost()
        val pipe = FakePipeline()
        streamer(pipe, host).start()
        waitFor("first frames") { host.frames().size >= 2 }
        val before = pipe.keyRequests.get()
        val framesBefore = host.frames().size
        host.sendKeyframeRequest(CamKeyframeRequest.DECODE_ERROR)
        waitFor("request reached the encoder") { pipe.keyRequests.get() > before }
        waitFor("config and keyframe again") { host.frames().size >= framesBefore + 2 }
        val again = host.frames().drop(framesBefore).take(2)
        assertTrue(again[0].codecConfig)
        assertArrayEquals(config, again[0].data.value)
        assertTrue(again[1].keyframe)
    }

    @Test fun deltasBehindARequestedKeyframeAreNotSentUntilTheKeyframeArrives() {
        val host = FakeHost()
        val pipe = FakePipeline()
        pipe.keyOnRequest = false // the encoder answers the request late: we feed it by hand
        streamer(pipe, host).start()
        waitFor("link up") { pipe.keyRequests.get() >= 2 } // 1: the first config, 2: the link came up (queue active)
        pipe.delta() // no keyframe yet: dropped, never sent
        Thread.sleep(100)
        assertTrue(host.frames().isEmpty())
        pipe.sink!!.onFrame(ByteArray(32) { 5 }, 77, true)
        waitFor("config + keyframe") { host.frames().size >= 2 }
        assertTrue(host.frames()[0].codecConfig)
        assertTrue(host.frames()[1].keyframe)
    }

    @Test fun aBrokenConnectionIsRedialledWithTheSameCamIdAtMostThreeTimesThenTheCameraIsClosed() {
        val host = FakeHost(closeAfterHello = true)
        val pipe = FakePipeline()
        val gaveUp = AtomicInteger()
        streamer(pipe, host, gaveUp).start()
        waitFor("given up") { gaveUp.get() == 1 }
        assertEquals(4, host.accepts.get()) // the first dial and three retries
        assertTrue(host.hellos.all { it.camId == 7 })
        assertEquals(1, pipe.stops.get()) // camera, encoder and GL are released
        assertEquals(1, gaveUp.get())
    }

    @Test fun aRejectionIsTerminalAndNotRetried() {
        val host = FakeHost(answer = CamHelloAck.REJECTED)
        val pipe = FakePipeline()
        val gaveUp = AtomicInteger()
        streamer(pipe, host, gaveUp).start()
        waitFor("given up") { gaveUp.get() == 1 }
        Thread.sleep(100)
        assertEquals(1, host.accepts.get())
        assertEquals(1, pipe.stops.get())
    }

    @Test fun anAckThatNeverComesEndsTheAttempt() {
        // a listener that accepts and says nothing
        val silent = ServerSocket(0, 50, InetAddress.getByName("127.0.0.1")).also { toClose += it }
        Thread({ try { while (true) silent.accept().also { toClose += it } } catch (_: IOException) {} }).also { it.isDaemon = true; it.start() }
        val pipe = FakePipeline()
        pipe.config = config
        val gaveUp = AtomicInteger()
        val s = CameraStreamer(
            CameraPlan(1, silent.localPort, 1280, 720, 30, 3000), CameraSessionCtx(1, "127.0.0.1", 1, secrets), CameraFacing.FRONT, pipe,
            { _, _ -> gaveUp.incrementAndGet() }, retryDelayMs = 10, maxRetries = 1, statsIntervalMs = 60_000, ackTimeoutMs = 100,
        ).also { toClose += AutoCloseable { it.close("test") } }
        s.start()
        waitFor("given up after two timed-out attempts") { gaveUp.get() == 1 }
    }

    @Test fun closeReleasesEverythingAndEndsTheConnection() {
        val host = FakeHost()
        val pipe = FakePipeline()
        val s = streamer(pipe, host).start()
        waitFor("frames") { host.frames().size >= 2 }
        s.close("stop")
        assertTrue(host.eof.await(3, TimeUnit.SECONDS)) // the Mac sees the socket go
        assertEquals(1, pipe.stops.get())
        s.close("again") // idempotent
        assertEquals(1, pipe.stops.get())
        waitFor("threads gone") { cameraThreads().isEmpty() }
    }

    @Test fun switchingTheFacingKeepsTheConnectionAndSendsANewConfigAndKeyframe() {
        val host = FakeHost()
        val pipe = FakePipeline()
        val s = streamer(pipe, host).start()
        waitFor("frames") { host.frames().size >= 2 }
        val n = host.frames().size
        s.switchFacing(CameraFacing.BACK)
        assertEquals(listOf(CameraFacing.BACK), pipe.facings.toList())
        waitFor("config + keyframe again") { host.frames().size >= n + 2 }
        assertEquals(1, host.accepts.get()) // the same connection
        val again = host.frames().drop(n).take(2)
        assertTrue(again[0].codecConfig)
        assertTrue(again[1].keyframe)
    }

    @Test fun aPipelineFailureGivesUpAndReleases() {
        val host = FakeHost()
        val pipe = FakePipeline()
        val gaveUp = AtomicInteger()
        streamer(pipe, host, gaveUp).start()
        waitFor("frames") { host.frames().size >= 2 }
        pipe.sink!!.onError("camera_disconnected")
        waitFor("given up") { gaveUp.get() == 1 }
        assertEquals(1, pipe.stops.get())
    }

    @Test fun noCameraThreadsExistWithoutAStream() {
        // zero cost: constructing nothing starts nothing (the controller never creates a streamer without a START)
        waitFor("threads of earlier tests gone") { cameraThreads().isEmpty() }
        val c = CameraController({ _, _, _, _ -> error("no stream expected") }, { true })
        c.setWish(CameraWish(CameraMode.AUTO, CameraFacing.BACK))
        c.setForeground(false)
        c.setForeground(true)
        c.onSessionEnd()
        assertTrue(cameraThreads().isEmpty())
    }

    private fun cameraThreads() = Thread.getAllStackTraces().keys.filter { it.isAlive && it.name.startsWith("mb-cam") }
}
