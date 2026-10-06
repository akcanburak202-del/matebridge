package dev.matebridge.client.files

import java.io.BufferedInputStream
import java.io.BufferedOutputStream
import java.io.File
import java.io.IOException
import java.net.BindException
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.net.SocketTimeoutException

/**
 * The tablet-files WebDAV server (decision 0015, T-135): listens on 127.0.0.1 only (the Mac reaches it through
 * `adb forward`), preferred port [FilesConfig.preferredPort], else one the system picks.
 *
 * Threads: one accept thread, one per connection and one write watchdog. Connections (T-139): at
 * [FilesConfig.maxConnections] a truly idle keep-alive connection is closed for the new one (it completed a request,
 * has waited [FilesConfig.evictIdleMs] for the next one and has no unread byte; a fresh connection is never evicted, so
 * new connections cannot evict each other). When none is idle the new connection is taken anyway, up to
 * [FilesConfig.overflowConnections] more: webdavfs holds one connection per open file for a whole-file download, and
 * a request that waits behind them makes Finder fail (T-138). At that hard limit the accept thread waits at most
 * [FilesConfig.admitWaitMs] for a slot, then answers `503` + `Retry-After` and closes (a last resort: webdavfs does not
 * retry a 503, it turns it into an error). A response write without progress for [FilesConfig.writeTimeoutMs] closes
 * its connection ([WriteWatchdog]). Idle threads block in `accept()`/`read()`/`wait()` (no polling).
 * [Hooks.threadStarted] runs first on every thread (Android lowers the priority there). All transfer bytes go through
 * one [TokenBucket].
 *
 * [stop] closes the listener and every connection: a running upload is aborted and its temporary file deleted, a
 * download ends short. Pure JVM code.
 */
class DavServer(
    private val root: File,
    token: String,
    secret: ByteArray,
    private val config: FilesConfig = FilesConfig(),
    private val hooks: Hooks = object : Hooks {},
    private val nowMs: () -> Long = System::currentTimeMillis,
    /**
     * A stopped predecessor: this server listens only after its threads ended (bounded by [PREDECESSOR_WAIT_MS]), so
     * an old COPY/DELETE worker never overlaps with the new server.
     */
    private val after: DavServer? = null,
) {
    interface Hooks {
        /** First thing on every server thread. */
        fun threadStarted() {}
        /** `ev` + key=value fields; never paths, names, the token or header values. */
        fun log(ev: String, fields: String) {}
        /** Listening on [port] (accept thread). */
        fun onListening(port: Int) {}
        /** The server ended: [failed] when it could not listen (accept thread). Called once, also after [stop]. */
        fun onStopped(failed: Boolean) {}
    }

    private val auth = DigestAuth(token, secret, nowMs)
    private val bucket = TokenBucket(config.rateBytesPerSec, config.burstBytes)
    /** T-266: the small-request lane (null on USB); each connection takes two lanes of it, one per direction. */
    private val smallBucket = if (config.smallRateBytesPerSec > 0) TokenBucket(config.smallRateBytesPerSec, config.smallBurstBytes) else null
    private val lanes = LaneBudget(bucket, smallBucket, config.smallThresholdBytes)
    private val stats = FilesStats()
    private val lock = Object()
    private val conns = HashSet<Conn>()
    private val rejecting = HashSet<Socket>() // guarded by [lock]
    private var lastOverflowLogNs = 0L // guarded by [lock]
    private val watchdog = WriteWatchdog(config.writeTimeoutMs.toLong())
    private var acceptRunning = false // guarded by [lock]
    @Volatile private var stopped = false
    @Volatile private var listener: ServerSocket? = null
    private var acceptThread: Thread? = null

    /** The bound port, 0 until listening. */
    @Volatile var port = 0
        private set

    /**
     * Changes the main rate cap while running (T-266; the Wi-Fi cap follows the video bit rate, see
     * [filesCapBytesPerSec]). The small-request lane keeps its own rate. Any thread.
     */
    fun setRate(bytesPerSec: Long) = bucket.setRate(bytesPerSec)

    fun start() {
        synchronized(lock) {
            check(acceptThread == null) { "started twice" }
            acceptRunning = true
            acceptThread = Thread({ acceptLoop() }, "mb-files-accept").also { it.isDaemon = true; it.start() }
            Thread({ hooks.threadStarted(); watchdog.runLoop() }, "mb-files-watchdog").also { it.isDaemon = true; it.start() }
        }
    }

    /** Non-blocking, idempotent, any thread. */
    fun stop() {
        stopped = true
        closeQuietly(listener)
        watchdog.stop()
        synchronized(lock) {
            for (c in conns) closeQuietly(c.socket)
            for (s in rejecting) closeQuietly(s)
            lock.notifyAll()
        }
    }

    private fun acceptLoop() {
        hooks.threadStarted()
        var failed = false
        try {
            if (after != null && !after.awaitTermination(PREDECESSOR_WAIT_MS)) hooks.log("predecessor_busy", "wait_ms=$PREDECESSOR_WAIT_MS")
            val canonicalRoot = root.canonicalFile
            val handler = DavHandler(
                canonicalRoot, auth, config, { ev, f -> hooks.log(ev, f) }, nowMs,
                bucket = bucket, stats = stats, cancelled = { stopped },
            )
            if (stopped) return
            val ss = bind() ?: run { failed = true; return }
            listener = ss
            if (stopped) { closeQuietly(ss); return }
            port = ss.localPort
            hooks.onListening(port)
            while (!stopped) {
                val s = try {
                    ss.accept()
                } catch (e: IOException) {
                    if (stopped) break
                    hooks.log("accept_error", "kind=${e.javaClass.simpleName}")
                    failed = true
                    break
                }
                val c = Conn(s, handler)
                when (admit(c)) {
                    Admission.TAKEN -> Thread(c, "mb-files-conn").also { it.isDaemon = true; it.start() }
                    Admission.FULL -> reject(s)
                    Admission.STOPPED -> { closeQuietly(s); break }
                }
            }
        } catch (e: IOException) {
            hooks.log("server_error", "kind=${e.javaClass.simpleName}")
            failed = true
        } finally {
            closeQuietly(listener)
            val last = synchronized(lock) {
                acceptRunning = false
                lock.notifyAll()
                conns.isEmpty()
            }
            if (last) {
                watchdog.stop()
                pollStats(force = true) // else the last connection thread writes the final summary
            }
            hooks.onStopped(failed)
        }
    }

    private fun bind(): ServerSocket? {
        val loopback = InetAddress.getByAddress(byteArrayOf(127, 0, 0, 1))
        for (p in listOf(config.preferredPort, 0)) {
            val ss = ServerSocket()
            try {
                ss.reuseAddress = true
                ss.bind(InetSocketAddress(loopback, p), BACKLOG)
                return ss
            } catch (e: BindException) {
                closeQuietly(ss)
                if (p == 0) hooks.log("bind_failed", "port=$p")
            } catch (e: IOException) {
                closeQuietly(ss)
                hooks.log("bind_failed", "port=$p kind=${e.javaClass.simpleName}")
                if (p == 0) return null
            }
        }
        return null
    }

    private enum class Admission { TAKEN, FULL, STOPPED }

    /**
     * Takes [c] into the connection set (see the class comment): below the limit at once; at the limit by evicting the
     * longest truly idle connection, else as overflow up to the hard limit; at the hard limit it waits at most
     * [FilesConfig.admitWaitMs] for a slot or an idle connection, then gives up ([Admission.FULL]).
     */
    private fun admit(c: Conn): Admission = synchronized(lock) {
        val hard = config.maxConnections + config.overflowConnections.coerceAtLeast(0)
        val deadline = System.nanoTime() + config.admitWaitMs * 1_000_000L
        while (!stopped && conns.size >= config.maxConnections) {
            val now = System.nanoTime()
            val idle = conns.filter { it.evictable(now) }.minByOrNull { it.idleSinceNs }
            if (idle != null) {
                conns.remove(idle)
                closeQuietly(idle.socket) // its thread ends on the closed socket
                break
            }
            if (conns.size < hard) {
                if (now - lastOverflowLogNs > OVERFLOW_LOG_INTERVAL_NS) {
                    lastOverflowLogNs = now
                    hooks.log("conn_overflow", "conns=${conns.size + 1} limit=${config.maxConnections} hard=$hard")
                }
                break
            }
            val left = (deadline - now) / 1_000_000
            if (left <= 0) return Admission.FULL
            lock.wait(minOf(left, ADMIT_POLL_MS))
        }
        if (stopped) return Admission.STOPPED
        conns += c
        Admission.TAKEN
    }

    /**
     * Answers [s] `503 Service Unavailable` + `Retry-After: 1` on a short-lived thread (reads the request head first and
     * drains a little of a body, so closing does not reset the answer away), then closes it. At most
     * [MAX_REJECTING] at a time; beyond that the connection is just closed.
     */
    private fun reject(s: Socket) {
        val count = synchronized(lock) {
            if (rejecting.size >= MAX_REJECTING || stopped) null else { rejecting += s; conns.size }
        }
        if (count == null) { closeQuietly(s); return }
        hooks.log("conn_rejected", "conns=$count wait_ms=${config.admitWaitMs}")
        Thread({
            hooks.threadStarted()
            try {
                s.soTimeout = REJECT_IO_MS
                val input = BufferedInputStream(s.getInputStream())
                val req = try { HttpIo.readHead(input) } catch (e: IOException) { null }
                s.getOutputStream().apply { write(REJECT_RESPONSE); flush() }
                s.shutdownOutput()
                val body = req?.let { try { BodyInputStream(input, it.bodyLength()) } catch (e: IOException) { null } }
                body?.drain(REJECT_DRAIN_BYTES)
                if (body == null || body.complete) while (input.read() >= 0) Unit // until the client closes
            } catch (e: IOException) {
                // timeout or the client went away: just close
            } finally {
                closeQuietly(s)
                synchronized(lock) { rejecting -= s }
            }
        }, "mb-files-reject").also { it.isDaemon = true; it.start() }
    }

    private fun released(c: Conn) {
        var ended = false
        val last = synchronized(lock) {
            conns.remove(c)
            lock.notifyAll()
            ended = !acceptRunning && conns.isEmpty()
            stopped && ended
        }
        if (ended) watchdog.stop() // the server is over (stopped or failed): no write left to watch
        if (last) pollStats(force = true) // the final summary, once every worker has ended
    }

    /**
     * Waits up to [timeoutMs] until the accept thread and every connection thread (running COPY/DELETE workers
     * included) have ended. True when they have. Any thread.
     */
    fun awaitTermination(timeoutMs: Long): Boolean = synchronized(lock) {
        val deadline = System.nanoTime() + timeoutMs * 1_000_000
        while (acceptRunning || conns.isNotEmpty()) {
            val left = (deadline - System.nanoTime()) / 1_000_000
            if (left <= 0) return false
            lock.wait(left)
        }
        true
    }

    private fun pollStats(force: Boolean = false) {
        stats.poll(nowMs(), force)?.let { hooks.log("stats", it) }
    }

    private inner class Conn(val socket: Socket, private val handler: DavHandler) : Runnable {
        /** Waiting for a request head with nothing read of it yet. */
        @Volatile var idle = false
        @Volatile var idleSinceNs = System.nanoTime()
        /** At least one request completed: before that the connection is never evicted. */
        @Volatile var served = false
        private val watch = watchdog.Watch {
            hooks.log("write_stalled", "timeout_ms=${config.writeTimeoutMs}")
            closeQuietly(socket) // unblocks the write; the thread then ends
        }

        /** Truly idle (see the class comment) at [now]; called under the server lock. */
        fun evictable(now: Long): Boolean =
            served && idle && now - idleSinceNs >= config.evictIdleMs * 1_000_000L && unread() == 0

        private fun unread(): Int = try {
            socket.getInputStream().available()
        } catch (e: IOException) {
            0 // closed: nothing to lose
        }

        override fun run() {
            hooks.threadStarted()
            try {
                socket.tcpNoDelay = true
                val inLane = lanes.newLane()
                val outLane = lanes.newLane()
                val input = BufferedInputStream(
                    ThrottledInputStream(socket.getInputStream(), inLane, stats, arrived = { idle = false }) { pollStats() },
                    config.bufferBytes,
                )
                val output = BufferedOutputStream(
                    ThrottledOutputStream(socket.getOutputStream(), outLane, stats, config.bufferBytes, watch) { pollStats() },
                    config.bufferBytes,
                )
                while (!stopped) {
                    idleSinceNs = System.nanoTime()
                    idle = input.available() == 0 // a pipelined request already buffered is not idle
                    socket.soTimeout = config.idleTimeoutMs
                    val req = try {
                        HttpIo.readHead(input)
                    } catch (e: HttpError) {
                        idle = false
                        output.write("HTTP/1.1 ${e.status} ${DavHandler.reason(e.status)}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".toByteArray(Charsets.US_ASCII))
                        output.flush()
                        break
                    } ?: break
                    idle = false
                    socket.soTimeout = config.readTimeoutMs
                    stats.request()
                    val keep = try {
                        handler.handle(req, input, output).also { output.flush() }
                    } finally {
                        pollStats() // at most one line per second; only the stop forces a final one
                    }
                    served = true
                    inLane.reset()
                    outLane.reset()
                    if (!keep) break
                }
            } catch (e: SocketTimeoutException) {
                // idle keep-alive connection or stalled transfer: just close
            } catch (e: IOException) {
                // client went away, connection evicted, or server stopped
            } catch (e: RuntimeException) {
                hooks.log("conn_error", "kind=${e.javaClass.simpleName}")
            } finally {
                closeQuietly(socket)
                released(this)
            }
        }
    }

    private companion object {
        const val BACKLOG = 8
        const val ADMIT_POLL_MS = 100L
        const val OVERFLOW_LOG_INTERVAL_NS = 1_000_000_000L
        const val MAX_REJECTING = 2
        const val REJECT_IO_MS = 1_000
        const val REJECT_DRAIN_BYTES = 64L * 1024
        val REJECT_RESPONSE =
            "HTTP/1.1 503 Service Unavailable\r\nRetry-After: 1\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                .toByteArray(Charsets.US_ASCII)
        const val PREDECESSOR_WAIT_MS = 5_000L

        fun closeQuietly(c: java.io.Closeable?) {
            try {
                c?.close()
            } catch (e: IOException) {
            }
        }
    }
}
