package dev.matebridge.client.session

import dev.matebridge.client.protocol.Bye
import dev.matebridge.client.protocol.Codec
import dev.matebridge.client.protocol.FrameDecoder
import dev.matebridge.client.protocol.Hello
import dev.matebridge.client.protocol.HelloAck
import dev.matebridge.client.protocol.Message
import dev.matebridge.client.protocol.Pong
import dev.matebridge.client.protocol.ProtocolException
import dev.matebridge.client.protocol.StreamConfig
import dev.matebridge.client.protocol.VideoFrame
import dev.matebridge.client.protocol.VideoHello
import java.io.IOException
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

    /** A PONG arrived (engine thread). Times are microseconds; [nowUs] is the client monotonic clock (`nanoTime/1000`). */
    fun onPong(echoTimeUs: Long, responderTimeUs: Long, nowUs: Long) {}
}

/**
 * Owns the sockets and threads around [SessionMachine]. No socket I/O runs on the caller's thread:
 *  - one engine thread runs the machine (events from a bounded queue plus a 100 ms tick),
 *  - per connection a reader thread; the control connection also has one writer thread fed by a
 *    bounded single-FIFO [SendQueue] (PROTOCOL.md sections 5 and 7).
 * [start]/[stop] and [trySend] may be called from any thread.
 */
class SessionController(hello: Hello, private val listener: SessionListener) {
    private val machine = SessionMachine(hello)

    /** Messages from control reader threads; bounded, and only those threads ever block on it. */
    private val events = LinkedBlockingQueue<SessionMachine.Event>(EVENT_QUEUE_CAP)

    /** Commands and close notifications: single-slot mailboxes, non-blocking and O(1) memory, drained by the engine. */
    private val intent = Latest<SessionMachine.Event>() // Start/Stop: the latest desired state wins
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
    @Volatile private var stopAfterDrain = false

    /** Non-blocking. Ignored after [shutdown]. */
    fun start(endpoint: Endpoint) {
        if (terminated.get()) return
        ensureEngine()
        intent.post(SessionMachine.Event.Start(endpoint))
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

    private fun ensureEngine() {
        if (!running.compareAndSet(false, true)) return
        engine = Thread({ engineLoop() }, "mb-session").also { it.isDaemon = true; it.start() }
    }

    private fun nowUs() = System.nanoTime() / 1000

    private fun engineLoop() {
        var lastTickNs = System.nanoTime()
        try {
            while (true) {
                var e: SessionMachine.Event? = intent.take() ?: controlClosed.take() ?: videoClosed.take()
                if (e == null) {
                    if (stopAfterDrain) break
                    val waitMs = TICK_MS - (System.nanoTime() - lastTickNs) / 1_000_000
                    e = events.poll(maxOf(waitMs, 0), TimeUnit.MILLISECONDS)
                }
                if (e != null) dispatch(e)
                // A busy queue must not starve ticks (PONG timeout, retries, pings).
                if (System.nanoTime() - lastTickNs >= TICK_MS * 1_000_000) {
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
        val actions = machine.handle(e, now)
        inputAllowed = machine.inputAllowed
        MbLog.sid = machine.currentSessionId
        for (a in actions) exec(a)
    }

    /** Concise session log (docs/LOGGING.md). Never per frame, never names or message text. */
    private fun logEvent(e: SessionMachine.Event) {
        when (e) {
            is SessionMachine.Event.Start -> MbLog.i("session_start", "host=${e.endpoint.host} port=${e.endpoint.port}")
            SessionMachine.Event.Stop -> MbLog.i("session_stop")
            is SessionMachine.Event.ControlOpened -> MbLog.i("connect_ok")
            is SessionMachine.Event.ControlClosed ->
                if (e.connectFailed) MbLog.w("connect_fail") else MbLog.w("control_closed")
            is SessionMachine.Event.ProtocolError -> MbLog.e("protocol_error")
            is SessionMachine.Event.VideoClosed -> MbLog.w("video_closed", "vgen=${e.gen}")
            is SessionMachine.Event.Received -> when (val m = e.msg) {
                is HelloAck -> MbLog.i("hello_ack", "status=${m.status} video_port=${m.videoPort}")
                is StreamConfig -> MbLog.i(
                    "stream_config",
                    "config_id=${m.configId} codec=${m.codec} size=${m.widthPx}x${m.heightPx} fps=${m.fps}",
                )
                is Bye -> MbLog.i("bye_recv", "reason=${m.reason}")
                else -> Unit
            }
            is SessionMachine.Event.Tick -> Unit
        }
    }

    private fun exec(a: SessionMachine.Action) {
        when (a) {
            is SessionMachine.Action.OpenControl -> {
                MbLog.gen = a.gen
                MbLog.i("connect_start", "host=${a.endpoint.host} port=${a.endpoint.port}")
                control?.abort()
                control = ControlConn(a.gen, a.endpoint).also { it.startThreads() }
            }
            is SessionMachine.Action.Send -> {
                when (val m = a.msg) {
                    is Hello -> MbLog.i("hello_sent", "proto=${m.protocolVersion}")
                    is Bye -> MbLog.i("bye_sent", "reason=${m.reason}")
                    else -> Unit
                }
                control?.link?.send(a.msg) // overflow is reported through the link itself
            }
            is SessionMachine.Action.CloseControl -> {
                control?.let { if (a.graceful) it.closeGracefully() else it.abort() }
                control = null
            }
            is SessionMachine.Action.OpenVideo -> {
                MbLog.i("video_open", "vgen=${a.gen} port=${a.endpoint.port} config_id=${a.hello.configId}")
                video?.abort()
                video = VideoConn(a.gen, a.endpoint, a.hello).also { it.startThread() }
            }
            SessionMachine.Action.CloseVideo -> {
                if (video != null) MbLog.i("video_close")
                video?.abort()
                video = null
            }
            is SessionMachine.Action.ApplyConfig -> listener.onStreamConfig(a.config)
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

    private inner class ControlConn(val gen: Int, private val endpoint: Endpoint) {
        private val socket = Socket()
        private val queue = SendQueue()
        private val closedPosted = AtomicBoolean(false)
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
        }

        private fun notifyClosed(connectFailed: Boolean) {
            if (closedPosted.compareAndSet(false, true)) controlClosed.post(SessionMachine.Event.ControlClosed(gen, connectFailed))
        }

        private fun readerLoop() {
            try {
                socket.connect(InetSocketAddress(endpoint.host, endpoint.port), CONNECT_TIMEOUT_MS)
                socket.tcpNoDelay = true
            } catch (e: IOException) {
                closeQuietly(socket)
                notifyClosed(connectFailed = true)
                return
            }
            Thread({ writerLoop() }, "mb-ctl-write-$gen").also { it.isDaemon = true; it.start() }
            events.put(SessionMachine.Event.ControlOpened(gen))
            val decoder = FrameDecoder.control()
            val buf = ByteArray(FrameDecoder.READ_CHUNK)
            try {
                val input = socket.getInputStream()
                while (true) {
                    val n = input.read(buf)
                    if (n < 0) break
                    decoder.feed(buf, 0, n)
                    while (true) events.put(SessionMachine.Event.Received(gen, decoder.next() ?: break))
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

        private fun writerLoop() {
            try {
                val out = socket.getOutputStream()
                while (true) {
                    val frame = queue.take() ?: break
                    out.write(frame)
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

    private inner class VideoConn(val gen: Int, private val endpoint: Endpoint, private val hello: VideoHello) {
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
            val decoder = FrameDecoder.video()
            val buf = ByteArray(FrameDecoder.READ_CHUNK)
            try {
                socket.connect(InetSocketAddress(endpoint.host, endpoint.port), CONNECT_TIMEOUT_MS)
                socket.tcpNoDelay = true
                socket.getOutputStream().apply { write(Codec.encode(hello)); flush() }
                val input = socket.getInputStream()
                while (true) {
                    val n = input.read(buf)
                    if (n < 0) break
                    decoder.feed(buf, 0, n)
                    while (true) {
                        val msg = decoder.next() ?: break
                        if (msg is VideoFrame) {
                            if (msg.fragmentIndex == 0) videoFrames.incrementAndGet()
                            listener.onVideoFrame(msg)
                        }
                    }
                }
            } catch (e: ProtocolException) {
                // Video protocol errors close only the video connection (PROTOCOL.md section 2).
            } catch (e: IOException) {
                // fall through
            }
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
