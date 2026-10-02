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
 * Threads: one accept thread plus one per connection, at most [FilesConfig.maxConnections]. At the limit an idle
 * keep-alive connection is closed for the new one; when all are busy the accept thread waits. Idle threads block in
 * `accept()`/`read()` (no timers, no polling). [Hooks.threadStarted] runs first on every thread (Android lowers the
 * priority there). All transfer bytes go through one [TokenBucket].
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
    private val stats = FilesStats()
    private val lock = Object()
    private val conns = HashSet<Conn>()
    private var activeRequests = 0
    @Volatile private var stopped = false
    @Volatile private var listener: ServerSocket? = null
    private var acceptThread: Thread? = null

    /** The bound port, 0 until listening. */
    @Volatile var port = 0
        private set

    fun start() {
        synchronized(lock) {
            check(acceptThread == null) { "started twice" }
            acceptThread = Thread({ acceptLoop() }, "mb-files-accept").also { it.isDaemon = true; it.start() }
        }
    }

    /** Non-blocking, idempotent, any thread. */
    fun stop() {
        stopped = true
        closeQuietly(listener)
        synchronized(lock) {
            for (c in conns) closeQuietly(c.socket)
            lock.notifyAll()
        }
    }

    private fun acceptLoop() {
        hooks.threadStarted()
        var failed = false
        try {
            val canonicalRoot = root.canonicalFile
            val handler = DavHandler(canonicalRoot, auth, config, { ev, f -> hooks.log(ev, f) }, nowMs)
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
                if (!admit(c)) { closeQuietly(s); break }
                Thread(c, "mb-files-conn").also { it.isDaemon = true; it.start() }
            }
        } catch (e: IOException) {
            hooks.log("server_error", "kind=${e.javaClass.simpleName}")
            failed = true
        } finally {
            closeQuietly(listener)
            stats.poll(nowMs(), force = true)?.let { hooks.log("stats", it) }
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

    /** Takes [c] into the connection set: frees an idle slot or waits for one. False when the server stopped. */
    private fun admit(c: Conn): Boolean = synchronized(lock) {
        while (!stopped && conns.size >= config.maxConnections) {
            val idle = conns.filter { it.idle }.minByOrNull { it.idleSinceMs }
            if (idle != null) {
                conns.remove(idle)
                closeQuietly(idle.socket) // its thread ends on the closed socket
                break
            }
            lock.wait(WAIT_MS)
        }
        if (stopped) return false
        conns += c
        true
    }

    private fun released(c: Conn) = synchronized(lock) {
        conns.remove(c)
        lock.notifyAll()
    }

    private fun requestStarted() = synchronized(lock) { activeRequests++ }

    /** Returns true when no request is running any more. */
    private fun requestEnded(): Boolean = synchronized(lock) { --activeRequests == 0 }

    private fun pollStats(force: Boolean = false) {
        stats.poll(nowMs(), force)?.let { hooks.log("stats", it) }
    }

    private inner class Conn(val socket: Socket, private val handler: DavHandler) : Runnable {
        @Volatile var idle = true
        @Volatile var idleSinceMs = nowMs()

        override fun run() {
            hooks.threadStarted()
            try {
                socket.tcpNoDelay = true
                val input = BufferedInputStream(
                    ThrottledInputStream(socket.getInputStream(), bucket, stats) { pollStats() },
                    config.bufferBytes,
                )
                val output = BufferedOutputStream(
                    ThrottledOutputStream(socket.getOutputStream(), bucket, stats, config.bufferBytes) { pollStats() },
                    config.bufferBytes,
                )
                while (!stopped) {
                    idleSinceMs = nowMs()
                    idle = true
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
                    requestStarted()
                    val keep = try {
                        handler.handle(req, input, output).also { output.flush() }
                    } finally {
                        if (requestEnded()) pollStats(force = true) else pollStats()
                    }
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
        const val WAIT_MS = 500L

        fun closeQuietly(c: java.io.Closeable?) {
            try {
                c?.close()
            } catch (e: IOException) {
            }
        }
    }
}
