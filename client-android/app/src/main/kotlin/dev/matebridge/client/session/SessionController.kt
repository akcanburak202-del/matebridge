package dev.matebridge.client.session

import dev.matebridge.client.protocol.Codec
import dev.matebridge.client.protocol.FrameDecoder
import dev.matebridge.client.protocol.Hello
import dev.matebridge.client.protocol.Message
import dev.matebridge.client.protocol.ProtocolException
import dev.matebridge.client.protocol.StreamConfig
import dev.matebridge.client.protocol.VideoFrame
import dev.matebridge.client.protocol.VideoHello
import java.io.IOException
import java.net.InetSocketAddress
import java.net.Socket
import java.util.concurrent.ConcurrentLinkedQueue
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

    /** Commands and close notifications: non-blocking to post from any thread, drained by the engine. */
    private val urgent = ConcurrentLinkedQueue<SessionMachine.Event>()

    /** Engine-thread-only follow-up events (handled inline, never through a blocking queue). */
    private val local = ArrayDeque<SessionMachine.Event>()

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
        urgent.add(SessionMachine.Event.Start(endpoint))
    }

    /** Non-blocking. */
    fun stop() {
        urgent.add(SessionMachine.Event.Stop)
    }

    /** Terminal: stops the session (BYE goes out gracefully) and the engine; later [start] calls are ignored. */
    fun shutdown() {
        if (!terminated.compareAndSet(false, true)) return
        urgent.add(SessionMachine.Event.Stop)
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
                var e = local.removeFirstOrNull() ?: urgent.poll()
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
        val actions = machine.handle(e, nowUs())
        inputAllowed = machine.inputAllowed
        for (a in actions) exec(a)
    }

    private fun exec(a: SessionMachine.Action) {
        when (a) {
            is SessionMachine.Action.OpenControl -> {
                control?.abort()
                control = ControlConn(a.gen, a.endpoint).also { it.startThreads() }
            }
            is SessionMachine.Action.Send -> {
                control?.link?.send(a.msg) // overflow is reported through the link itself
            }
            is SessionMachine.Action.CloseControl -> {
                control?.let { if (a.graceful) it.closeGracefully() else it.abort() }
                control = null
            }
            is SessionMachine.Action.OpenVideo -> {
                video?.abort()
                video = VideoConn(a.gen, a.endpoint, a.hello).also { it.startThread() }
            }
            SessionMachine.Action.CloseVideo -> {
                video?.abort()
                video = null
            }
            is SessionMachine.Action.ApplyConfig -> listener.onStreamConfig(a.config)
            is SessionMachine.Action.Ui -> listener.onUi(a.state)
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
            if (closedPosted.compareAndSet(false, true)) urgent.add(SessionMachine.Event.ControlClosed(gen, connectFailed))
        }

        private fun readerLoop() {
            try {
                socket.connect(InetSocketAddress(endpoint.host, endpoint.port), CONNECT_TIMEOUT_MS)
                socket.tcpNoDelay = true
            } catch (e: IOException) {
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
            if (closedPosted.compareAndSet(false, true)) urgent.add(SessionMachine.Event.VideoClosed(gen))
        }
    }

    private fun closeQuietly(s: Socket) {
        try { s.close() } catch (_: IOException) {}
    }

    private companion object {
        const val TICK_MS = 100L
        const val GRACEFUL_CLOSE_MS = 1000L
        const val CONNECT_TIMEOUT_MS = 5000
        const val EVENT_QUEUE_CAP = 1024
    }
}
