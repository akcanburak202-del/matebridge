package dev.matebridge.client.session

import dev.matebridge.client.protocol.Bye
import dev.matebridge.client.protocol.Clipboard
import dev.matebridge.client.protocol.Codec
import dev.matebridge.client.protocol.FrameDecoder
import dev.matebridge.client.protocol.Hello
import dev.matebridge.client.protocol.HelloAck
import dev.matebridge.client.protocol.Message
import dev.matebridge.client.protocol.Pong
import dev.matebridge.client.protocol.ProtocolException
import dev.matebridge.client.protocol.StreamConfig
import dev.matebridge.client.protocol.DisplayRate
import dev.matebridge.client.protocol.StreamPrefs
import dev.matebridge.client.stream.StreamMode
import dev.matebridge.client.protocol.VideoFrame
import dev.matebridge.client.video.PaceTrace
import dev.matebridge.client.video.PerfHint
import dev.matebridge.client.protocol.VideoHello
import dev.matebridge.client.protocol.Bytes
import dev.matebridge.client.protocol.Limits
import dev.matebridge.client.protocol.MsgType
import dev.matebridge.client.security.ClientHandshake
import dev.matebridge.client.security.HandshakeOutcome
import dev.matebridge.client.security.PairKeyStore
import dev.matebridge.client.security.PlainFrames
import dev.matebridge.client.security.RecordDecoder
import dev.matebridge.client.security.RecordOpener
import dev.matebridge.client.security.RecordSealer
import dev.matebridge.client.security.SecureSession
import dev.matebridge.client.security.VideoChannel
import dev.matebridge.client.security.SessionSecrets
import java.security.SecureRandom
import java.util.concurrent.CountDownLatch
import java.io.IOException
import java.io.InputStream
import java.net.InetSocketAddress
import java.net.Socket
import java.util.concurrent.Executors
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong

/** Callbacks arrive on background threads; the UI layer must hop to the main thread. */
interface SessionListener {
    fun onUi(state: SessionUi)

    /** A new stream configuration was accepted (before the video connection is (re)opened). */
    fun onStreamConfig(config: StreamConfig) {}

    /** One VIDEO_FRAME wire fragment, from the video reader thread. Frames are only counted in T-012. */
    fun onVideoFrame(frame: VideoFrame) {}

    /** A new control connection is being opened (first start and every automatic reconnect); reset per-session state. */
    fun onSessionStart() {}

    /** A PONG arrived (engine thread). Times are microseconds; [nowUs] is the client monotonic clock (`nanoTime/1000`). */
    fun onPong(echoTimeUs: Long, responderTimeUs: Long, nowUs: Long) {}

    /** A CLIPBOARD message arrived on an accepted session (engine thread). Its data is private: never log it. */
    fun onClipboard(msg: Clipboard, gen: Int) {}
}

/**
 * Owns the sockets and threads around [SessionMachine]. No socket I/O runs on the caller's thread:
 *  - one engine thread runs the machine (events from a bounded queue plus a 100 ms tick),
 *  - per connection a reader thread; the control connection also has one writer thread fed by a
 *    bounded single-FIFO [SendQueue] (PROTOCOL.md sections 5 and 7).
 * [start]/[stop] and [trySend] may be called from any thread.
 */
class SessionController(
    private val hello: Hello,
    private val pairKeys: PairKeyStore,
    private val listener: SessionListener,
    initialMode: StreamMode = StreamMode.DEFAULT,
    private val quickAck: Boolean = true, // T-074 experiment switch (--ez quickack false)
    private val perfHint: PerfHint? = null, // T-079 experiment (--ez perf_hint true): video reader joins the hint session
    private val knobs: WifiKnobs = WifiKnobs(), // T-089 experiment knobs (ping interval, socket traffic class)
) {
    private val machine = SessionMachine(hello, initialMode.toPrefs(), knobs.pingIntervalUs)

    /** Engine tick; at most the ping interval so a short `ping_ms` is honoured (default: 100 ms as before). */
    private val tickMs = minOf(TICK_MS, knobs.pingMs.toLong())
    private val random = SecureRandom()

    /** Messages from control reader threads; bounded, and only those threads ever block on it. */
    private val events = LinkedBlockingQueue<SessionMachine.Event>(EVENT_QUEUE_CAP)

    /** Commands and close notifications: single-slot mailboxes, non-blocking and O(1) memory, drained by the engine. */
    private val intent = Latest<SessionMachine.Event>() // Start/Stop: the latest desired state wins
    private val prefsMailbox = Latest<SessionMachine.Event>() // the newest display-mode request wins
    private val rateMailbox = Latest<SessionMachine.Event>() // the newest panel rate wins
    private val controlClosed = LatestGen<SessionMachine.Event.ControlClosed> { it.gen }
    private val videoClosed = LatestGen<SessionMachine.Event.VideoClosed> { it.gen }

    private val videoFrames = AtomicLong()
    private val running = AtomicBoolean(false)
    private val terminated = AtomicBoolean(false)
    private val timer = Executors.newSingleThreadScheduledExecutor { r -> Thread(r, "mb-timer").also { it.isDaemon = true } }
    private var engine: Thread? = null

    @Volatile private var control: ControlConn? = null
    @Volatile private var video: VideoConn? = null
    @Volatile private var inputAllowed = false

    /** config_id of the latest applied STREAM_CONFIG; frames from a video connection of another config are dropped. */
    @Volatile private var currentConfigId = -1
    @Volatile private var stopAfterDrain = false

    /** Non-blocking. Ignored after [shutdown]. */
    fun start(endpoint: Endpoint) {
        if (terminated.get()) return
        ensureEngine()
        intent.post(SessionMachine.Event.Start(endpoint))
    }

    /** Non-blocking. Remembers the display mode and sends STREAM_PREFS now when the session is accepted (T-050). */
    fun setStreamMode(mode: StreamMode) {
        if (terminated.get()) return
        ensureEngine()
        prefsMailbox.post(SessionMachine.Event.SetPrefs(mode.toPrefs()))
    }

    /** Non-blocking. The (already debounced) panel rate in Hz; sent when accepted and on change (T-059). */
    fun setDisplayRate(hz: Int) {
        if (terminated.get()) return
        ensureEngine()
        rateMailbox.post(SessionMachine.Event.SetDisplayRate(hz))
    }

    /** Non-blocking. */
    fun stop() {
        intent.post(SessionMachine.Event.Stop)
    }

    /** Terminal: stops the session (BYE goes out gracefully) and the engine; later [start] calls are ignored. */
    fun shutdown() {
        if (!terminated.compareAndSet(false, true)) return
        intent.post(SessionMachine.Event.Stop)
        stopAfterDrain = true
    }

    /**
     * Enqueues an input/maintenance message on the single control FIFO. Returns false when the session
     * is not ACCEPTED (input must not be sent before approval) or the queue overflowed; an overflow
     * aborts the connection so the session reconnects (PROTOCOL.md section 5).
     */
    fun trySend(msg: Message): Boolean {
        if (!inputAllowed) return false
        val c = control ?: return false
        return c.link.send(msg)
    }

    /**
     * Drops the accepted control connection like a send-queue overflow does: the session reports it closed and
     * reconnects, and the host releases all input on the disconnect (PROTOCOL.md section 7). Used when a RELEASE_ALL
     * could not be queued. No-op without an accepted session (the host holds nothing then). Any thread.
     */
    fun dropConnection() {
        if (!inputAllowed) return
        control?.dropForOverflow()
    }

    /** True while the control send queue is backed up (input layer holds mergeable hover/scroll samples then). Any thread. */
    fun isSendCongested(): Boolean = control?.link?.congested() ?: false

    private fun ensureEngine() {
        if (!running.compareAndSet(false, true)) return
        engine = Thread({ engineLoop() }, "mb-session").also { it.isDaemon = true; it.start() }
    }

    private fun nowUs() = System.nanoTime() / 1000

    private fun engineLoop() {
        var lastTickNs = System.nanoTime()
        try {
            while (true) {
                var e: SessionMachine.Event? = intent.take() ?: prefsMailbox.take() ?: rateMailbox.take() ?: controlClosed.take() ?: videoClosed.take()
                if (e == null) {
                    if (stopAfterDrain) break
                    val waitMs = tickMs - (System.nanoTime() - lastTickNs) / 1_000_000
                    e = events.poll(maxOf(waitMs, 0), TimeUnit.MILLISECONDS)
                }
                if (e != null) dispatch(e)
                // A busy queue must not starve ticks (PONG timeout, retries, pings).
                if (System.nanoTime() - lastTickNs >= tickMs * 1_000_000) {
                    lastTickNs = System.nanoTime()
                    dispatch(SessionMachine.Event.Tick(videoFrames.get()))
                }
            }
        } catch (ie: InterruptedException) {
            // shutting down
        } finally {
            control?.closeGracefully()
            video?.abort()
            timer.schedule({ timer.shutdown() }, GRACEFUL_CLOSE_MS + 200, TimeUnit.MILLISECONDS)
        }
    }

    private fun dispatch(e: SessionMachine.Event) {
        if (e is SessionMachine.Event.Start) videoFrames.set(0)
        logEvent(e)
        val now = nowUs()
        if (e is SessionMachine.Event.Received && e.msg is Pong) listener.onPong(e.msg.echoTimeUs, e.msg.responderTimeUs, now)
        if (e is SessionMachine.Event.Received && e.msg is Clipboard && inputAllowed && e.gen == MbLog.gen) listener.onClipboard(e.msg, e.gen)
        val actions = machine.handle(e, now)
        inputAllowed = machine.inputAllowed
        MbLog.sid = machine.currentSessionId
        for (a in actions) exec(a)
    }

    /** Concise session log (docs/LOGGING.md). Never per frame, never names or message text. */
    private fun logEvent(e: SessionMachine.Event) {
        when (e) {
            is SessionMachine.Event.Start -> MbLog.i(
                "session_start",
                "host=${e.endpoint.host} port=${e.endpoint.port} transport=${ConnectMode.transportOf(e.endpoint).logName} " +
                    "quickack=${if (quickAck) 1 else 0} ${knobs.logFields()}",
            )
            SessionMachine.Event.Stop -> MbLog.i("session_stop")
            is SessionMachine.Event.ControlOpened -> MbLog.i("connect_ok")
            is SessionMachine.Event.ControlClosed ->
                if (e.connectFailed) MbLog.w("connect_fail") else MbLog.w("control_closed")
            is SessionMachine.Event.ProtocolError -> MbLog.e("protocol_error")
            is SessionMachine.Event.Secured -> MbLog.i("secured", "pairing=${e.code != null} re_pairing=${e.rePairing}") // never the code
            is SessionMachine.Event.KeyMissing -> MbLog.w("pair_key_missing")
            is SessionMachine.Event.KeyStoreFailed -> MbLog.w("pair_key_store_failed")
            is SessionMachine.Event.VideoClosed -> MbLog.w("video_closed", "vgen=${e.gen}")
            is SessionMachine.Event.Received -> when (val m = e.msg) {
                is HelloAck -> MbLog.i("hello_ack", "status=${m.status} key_mode=${m.keyMode} video_port=${m.videoPort}")
                is StreamConfig -> MbLog.i(
                    "stream_config",
                    "config_id=${m.configId} codec=${m.codec} size=${m.widthPx}x${m.heightPx} fps=${m.fps}",
                )
                is Bye -> MbLog.i("bye_recv", "reason=${m.reason}")
                else -> Unit
            }
            is SessionMachine.Event.SetPrefs -> MbLog.i("stream_prefs_set", "fps=${e.prefs.fps} scale=${e.prefs.scalePermille}")
            is SessionMachine.Event.SetDisplayRate -> MbLog.i("display_rate_set", "hz=${e.hz}")
            is SessionMachine.Event.Tick -> Unit
        }
    }

    private fun exec(a: SessionMachine.Action) {
        when (a) {
            is SessionMachine.Action.OpenControl -> {
                MbLog.gen = a.gen
                MbLog.i("connect_start", "host=${a.endpoint.host} port=${a.endpoint.port}")
                listener.onSessionStart()
                control?.abort()
                control = ControlConn(a.gen, a.endpoint, hello).also { it.startThreads() }
            }
            is SessionMachine.Action.Send -> {
                when (val m = a.msg) {
                    is Hello -> MbLog.i("hello_sent", "proto=${m.protocolVersion}")
                    is Bye -> MbLog.i("bye_sent", "reason=${m.reason}")
                    is DisplayRate -> MbLog.i("display_rate_sent", "hz=${m.hz}")
                    is StreamPrefs -> MbLog.i("stream_prefs_sent", "fps=${m.fps} scale=${m.scalePermille}")
                    else -> Unit
                }
                val c = control
                // The machine's HELLO is a template: this connection's nonce and ephemeral key go in here.
                c?.link?.send(if (a.msg is Hello) c.helloMsg else a.msg) // overflow is reported through the link itself
            }
            is SessionMachine.Action.CloseControl -> {
                control?.let { if (a.graceful) it.closeGracefully() else it.abort() }
                control = null
            }
            is SessionMachine.Action.OpenVideo -> {
                MbLog.i("video_open", "vgen=${a.gen} port=${a.endpoint.port} config_id=${a.hello.configId}")
                video?.abort()
                val secrets = control?.secrets
                if (secrets == null) {
                    MbLog.w("video_no_keys")
                    videoClosed.post(SessionMachine.Event.VideoClosed(a.gen))
                } else {
                    video = VideoConn(a.gen, a.endpoint, a.hello, secrets).also { it.startThread() }
                }
            }
            SessionMachine.Action.CloseVideo -> {
                if (video != null) MbLog.i("video_close")
                video?.abort()
                video = null
            }
            is SessionMachine.Action.ApplyConfig -> {
                currentConfigId = a.config.configId
                listener.onStreamConfig(a.config)
            }
            is SessionMachine.Action.Ui -> {
                when (val u = a.state) {
                    is SessionUi.Disconnected -> MbLog.i("reconnect", "cause=${u.cause} delay_ms=${u.retryInMs}")
                    is SessionUi.Failed -> MbLog.w("session_failed", "cause=${u.cause}")
                    else -> Unit
                }
                listener.onUi(a.state)
            }
        }
    }

    private inner class ControlConn(val gen: Int, private val endpoint: Endpoint, template: Hello) {
        private val socket = Socket()
        private val queue = SendQueue()
        private val closedPosted = AtomicBoolean(false)
        private val handshake = ClientHandshake(random)

        /** This connection's HELLO (fresh nonce and ephemeral key); its payload bytes feed the transcript hash. */
        val helloMsg: Hello = handshake.hello(template)

        /** Session keys once the first HELLO_ACK was validated; video connections derive their keys from it. */
        @Volatile var secrets: SessionSecrets? = null
            private set

        @Volatile private var sealer: RecordSealer? = null
        private val sealerReady = CountDownLatch(1)

        val link = ControlLink(queue, { System.nanoTime() / 1_000_000 }) {
            // Overflow: a message was lost, so the connection must not live on (PINGs would keep it alive).
            abort()
            notifyClosed(connectFailed = false)
        }

        fun startThreads() {
            Thread({ readerLoop() }, "mb-ctl-read-$gen").also { it.isDaemon = true; it.start() }
        }

        /** Writer closes the socket after draining; a deadline aborts it if the writer is stuck. */
        fun closeGracefully() {
            queue.closeGracefully()
            try {
                timer.schedule({ abort() }, GRACEFUL_CLOSE_MS, TimeUnit.MILLISECONDS)
            } catch (_: RejectedExecutionException) {
                abort()
            }
        }

        fun abort() {
            queue.abort()
            closeQuietly(socket)
            secrets?.wipe()
            sealerReady.countDown() // releases a writer still waiting for keys
        }

        /** Same as the overflow handler in [link]: abort and report the connection closed (once). */
        fun dropForOverflow() {
            abort()
            notifyClosed(connectFailed = false)
        }

        private fun notifyClosed(connectFailed: Boolean) {
            if (closedPosted.compareAndSet(false, true)) controlClosed.post(SessionMachine.Event.ControlClosed(gen, connectFailed))
        }

        private fun readerLoop() {
            try {
                val tosErr = TrafficClass.trySet(knobs.tosCtl) { socket.trafficClass = it } // T-089, before connect
                socket.connect(InetSocketAddress(endpoint.host, endpoint.port), CONNECT_TIMEOUT_MS)
                socket.tcpNoDelay = true
                knobs.tosCtl?.let { MbLog.i("traffic_class", TrafficClass.logFields("control", it, tosErr) { socket.trafficClass }) }
            } catch (e: IOException) {
                closeQuietly(socket)
                notifyClosed(connectFailed = true)
                return
            }
            Thread({ writerLoop() }, "mb-ctl-write-$gen").also { it.isDaemon = true; it.start() }
            events.put(SessionMachine.Event.ControlOpened(gen))
            try {
                val input = socket.getInputStream()
                // The first HELLO_ACK is the only plaintext host message; it is read byte-exactly so the
                // encrypted records that may follow immediately are not consumed (PROTOCOL.md section 9).
                val (ack, ackPayload) = PlainFrames.readHelloAck(input)
                when (val outcome = handshake.complete(ack, ackPayload, pairKeys)) {
                    is HandshakeOutcome.Plain -> events.put(SessionMachine.Event.Received(gen, ack)) // terminal; host closes
                    HandshakeOutcome.KeyMissing -> {
                        closedPosted.set(true)
                        events.put(SessionMachine.Event.KeyMissing(gen))
                        return
                    }
                    is HandshakeOutcome.Secure -> {
                        val sec = outcome.session
                        try {
                            // Stored at the first ack, before the Mac's approval: the connection may drop meanwhile.
                            if (sec.storePairKey(pairKeys)) MbLog.i("pair_key_stored")
                        } catch (e: Exception) {
                            // Not persisted: a later PAIRED handshake would have no key. Fail instead of pretending.
                            closedPosted.set(true)
                            events.put(SessionMachine.Event.KeyStoreFailed(gen)) // the key itself is never logged
                            return
                        }
                        secrets = sec.secrets
                        sealer = sec.sealer
                        sealerReady.countDown()
                        if (sec.sas != null) events.put(SessionMachine.Event.Secured(gen, sec.sas, sec.rePairing))
                        events.put(SessionMachine.Event.Received(gen, ack))
                        readRecords(input, sec)
                    }
                }
            } catch (e: ProtocolException) {
                closedPosted.set(true) // the machine reacts to ProtocolError instead
                events.put(SessionMachine.Event.ProtocolError(gen)) // ordered after already received messages
                return
            } catch (e: IOException) {
                // fall through
            }
            // EOF/IO error: ordered after already received messages (e.g. a final BYE), so use the bounded queue.
            if (closedPosted.compareAndSet(false, true)) events.put(SessionMachine.Event.ControlClosed(gen))
        }

        private fun readRecords(input: InputStream, sec: SecureSession) {
            val decoder = RecordDecoder(Limits.CONTROL_MAX_PAYLOAD, sec.opener)
            val buf = ByteArray(RecordDecoder.READ_CHUNK)
            QuickAck.forSocket(socket, quickAck, "control").use { qa ->
                while (true) {
                    val n = input.read(buf)
                    if (n < 0) break
                    qa.ack.afterRead()
                    decoder.feed(buf, 0, n)
                    while (true) {
                        val msg = decoder.next() ?: break
                        events.put(SessionMachine.Event.Received(gen, msg))
                    }
                }
            }
        }

        private fun writerLoop() {
            try {
                val out = socket.getOutputStream()
                var first = true
                while (true) {
                    val frame = queue.take() ?: break
                    val wire = if (first) {
                        // Only HELLO goes out in plaintext, and only first; everything else is sealed in FIFO order.
                        first = false
                        if ((frame[0].toInt() and 0xFF) != MsgType.HELLO) throw IOException("first message must be HELLO")
                        frame
                    } else {
                        sealerReady.await()
                        val s = sealer ?: throw IOException("no keys")
                        s.sealFrame(frame)
                    }
                    out.write(wire)
                    out.flush()
                }
                // Graceful close after a drained queue: half-close so the peer sees BYE then EOF.
                if (!socket.isClosed) closeQuietly(socket)
            } catch (e: IOException) {
                closeQuietly(socket)
                notifyClosed(connectFailed = false)
            }
        }
    }

    private inner class VideoConn(
        val gen: Int,
        private val endpoint: Endpoint,
        private val hello: VideoHello,
        private val secrets: SessionSecrets,
    ) {
        private val socket = Socket()
        private val closedPosted = AtomicBoolean(false)

        fun startThread() {
            Thread({ loop() }, "mb-video-$gen").also { it.isDaemon = true; it.start() }
        }

        fun abort() {
            closedPosted.set(true)
            closeQuietly(socket)
        }

        private fun loop() {
            val buf = ByteArray(RecordDecoder.READ_CHUNK)
            var qa: QuickAck.Handle = QuickAck.Handle(QuickAck(false, {}), null)
            val hint = perfHint
            val tid = if (hint != null) android.os.Process.myTid() else 0
            hint?.register(PerfHint.ROLE_NET, tid)
            try {
                // Fresh nonce per video connection; both directions' keys come from it (section 9).
                val nonce = ByteArray(Limits.NONCE_BYTES).also { random.nextBytes(it) }
                val channel = VideoChannel(secrets.videoKeys(nonce))
                val decoder = channel.decoder
                val tosErr = TrafficClass.trySet(knobs.tosVideo) { socket.trafficClass = it } // T-089, before connect
                socket.connect(InetSocketAddress(endpoint.host, endpoint.port), CONNECT_TIMEOUT_MS)
                socket.tcpNoDelay = true
                knobs.tosVideo?.let { MbLog.i("traffic_class", TrafficClass.logFields("video", it, tosErr) { socket.trafficClass }) }
                // VIDEO_HELLO in plaintext, then one sealed PING as proof of the key (the host sends no frames before it).
                socket.getOutputStream().apply { write(channel.opening(hello, nonce, nowUs())); flush() }
                val input = socket.getInputStream()
                qa = QuickAck.forSocket(socket, quickAck, "video")
                while (true) {
                    val n = input.read(buf)
                    if (n > 0) qa.ack.afterRead()
                    val trace = PaceTrace.active // T-073: receive-path timestamps (null = off)
                    val recvNs = if (trace != null || hint != null) System.nanoTime() else 0L
                    if (n < 0) break
                    decoder.feed(buf, 0, n)
                    while (true) {
                        val msg = decoder.next() ?: break
                        if (msg is VideoFrame) {
                            trace?.onRecv(msg.frameSeq, msg.captureTimeUs, msg.data.size, recvNs, System.nanoTime())
                            hint?.onRecv(msg.frameSeq, recvNs) // T-079: start of the frame's reported work
                            if (msg.fragmentIndex == 0) videoFrames.incrementAndGet()
                            if (hello.configId == currentConfigId) listener.onVideoFrame(msg)
                        }
                    }
                }
            } catch (e: ProtocolException) {
                // Video protocol/authentication errors close only the video connection (PROTOCOL.md sections 2, 9).
            } catch (e: IOException) {
                // fall through
            } catch (e: IllegalStateException) {
                // session secrets wiped: the control connection is gone
            } finally {
                hint?.unregister(PerfHint.ROLE_NET, tid)
            }
            qa.close()
            closeQuietly(socket)
            if (closedPosted.compareAndSet(false, true)) videoClosed.post(SessionMachine.Event.VideoClosed(gen))
        }
    }

    private fun closeQuietly(s: Socket) {
        try { s.close() } catch (_: IOException) {}
    }

    companion object {
        /** The clock all session/latency times use. */
        fun clockUs() = System.nanoTime() / 1000

        private const val TICK_MS = 100L
        private const val GRACEFUL_CLOSE_MS = 1000L
        private const val CONNECT_TIMEOUT_MS = 5000
        private const val EVENT_QUEUE_CAP = 1024
    }
}
