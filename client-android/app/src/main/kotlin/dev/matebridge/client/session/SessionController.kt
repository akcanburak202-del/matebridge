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
import java.util.concurrent.LinkedBlockingQueue
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
    private val events = LinkedBlockingQueue<SessionMachine.Event>(EVENT_QUEUE_CAP)
    private val videoFrames = AtomicLong()
    private val running = AtomicBoolean(false)
    private var engine: Thread? = null

    @Volatile private var control: ControlConn? = null
    @Volatile private var video: VideoConn? = null
    @Volatile private var inputAllowed = false

    fun start(endpoint: Endpoint) {
        ensureEngine()
        post(SessionMachine.Event.Start(endpoint))
    }

    fun stop() = post(SessionMachine.Event.Stop)

    /** Shuts the engine down after a final stop. Not restartable. */
    fun shutdown() {
        stop()
        running.set(false)
        engine?.interrupt()
    }

    /**
     * Enqueues an input/maintenance message on the single control FIFO. Returns false when the session
     * is not ACCEPTED (input must not be sent before approval) or the queue is full (which triggers a
     * reconnect, PROTOCOL.md section 5).
     */
    fun trySend(msg: Message): Boolean {
        if (!inputAllowed) return false
        val c = control ?: return false
        return c.send(msg)
    }

    private fun post(e: SessionMachine.Event) {
        try {
            events.put(e)
        } catch (ie: InterruptedException) {
            Thread.currentThread().interrupt()
        }
    }

    private fun ensureEngine() {
        if (!running.compareAndSet(false, true)) return
        engine = Thread({ engineLoop() }, "mb-session").also { it.isDaemon = true; it.start() }
    }

    private fun nowUs() = System.nanoTime() / 1000

    private fun engineLoop() {
        try {
            while (running.get()) {
                val e = events.poll(TICK_MS, java.util.concurrent.TimeUnit.MILLISECONDS)
                    ?: SessionMachine.Event.Tick(videoFrames.get())
                dispatch(e)
                // Ticks must keep flowing under a busy queue too (PONG timeout, retries).
                if (e !is SessionMachine.Event.Tick && events.isEmpty()) dispatch(SessionMachine.Event.Tick(videoFrames.get()))
            }
        } catch (ie: InterruptedException) {
            // shutting down
        } finally {
            control?.abort()
            video?.abort()
        }
    }

    private fun dispatch(e: SessionMachine.Event) {
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
                val c = control
                if (c != null && !c.send(a.msg)) post(SessionMachine.Event.ControlClosed(c.gen))
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

        fun startThreads() {
            Thread({ readerLoop() }, "mb-ctl-read-$gen").also { it.isDaemon = true; it.start() }
        }

        fun send(msg: Message): Boolean = queue.offer(Codec.encode(msg), System.nanoTime() / 1_000_000)

        fun closeGracefully() = queue.closeGracefully() // writer closes the socket after draining

        fun abort() {
            queue.abort()
            closeQuietly(socket)
        }

        private fun notifyClosed(connectFailed: Boolean) {
            if (closedPosted.compareAndSet(false, true)) post(SessionMachine.Event.ControlClosed(gen, connectFailed))
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
            post(SessionMachine.Event.ControlOpened(gen))
            val decoder = FrameDecoder.control()
            val buf = ByteArray(FrameDecoder.READ_CHUNK)
            try {
                val input = socket.getInputStream()
                while (true) {
                    val n = input.read(buf)
                    if (n < 0) break
                    decoder.feed(buf, 0, n)
                    while (true) post(SessionMachine.Event.Received(gen, decoder.next() ?: break))
                }
            } catch (e: ProtocolException) {
                closedPosted.set(true) // the machine reacts to ProtocolError instead
                post(SessionMachine.Event.ProtocolError(gen))
                return
            } catch (e: IOException) {
                // fall through
            }
            notifyClosed(connectFailed = false)
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
            if (closedPosted.compareAndSet(false, true)) post(SessionMachine.Event.VideoClosed(gen))
        }
    }

    private fun closeQuietly(s: Socket) {
        try { s.close() } catch (_: IOException) {}
    }

    private companion object {
        const val TICK_MS = 100L
        const val CONNECT_TIMEOUT_MS = 5000
        const val EVENT_QUEUE_CAP = 1024
    }
}
