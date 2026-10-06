package dev.matebridge.client.files

import dev.matebridge.client.protocol.Bytes
import dev.matebridge.client.protocol.Codec
import dev.matebridge.client.protocol.FilesData
import dev.matebridge.client.protocol.FilesHello
import dev.matebridge.client.protocol.FilesHelloAck
import dev.matebridge.client.protocol.Limits
import dev.matebridge.client.protocol.MsgType
import dev.matebridge.client.protocol.Ping
import dev.matebridge.client.protocol.ProtocolException
import dev.matebridge.client.security.FilesChannel
import dev.matebridge.client.security.PlainFrames
import dev.matebridge.client.security.SessionSecrets
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.net.InetSocketAddress
import java.net.Socket
import java.net.SocketTimeoutException
import java.security.SecureRandom
import java.util.concurrent.ScheduledThreadPoolExecutor
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.RejectedExecutionException

/**
 * What the session wants of the file tunnel right now (decision 0035): the machine emits it (null = no tunnel) whenever it
 * changes. [gen] is the control connection it belongs to, [host]/[port] the Mac's file listener (`FILES_NET.port`, same
 * address as the control connection), [pool]/[max] the clamped idle and total limits, [davPort] the tablet's own WebDAV
 * server (`FILES_INFO.port`, 127.0.0.1) and [sessionId] the `HELLO_ACK` session id of the file connections' hello.
 * Nothing in it is secret (the token is not part of it).
 */
data class FilesTunnelPlan(
    val gen: Int,
    val host: String,
    val port: Int,
    val pool: Int,
    val max: Int,
    val davPort: Int,
    val sessionId: Long,
    /** The Mac's open request this tunnel serves (the local server must have been started for the same one). */
    val request: Int = 0,
)

/**
 * Which tablet server a published `FILES_INFO` describes (T-269, round 3). [request] correlates with the Mac's open
 * request (the machine numbers every accepted OPEN): a READY is only for the request it was started for, and an OFF or
 * STANDBY ends only the request it belongs to, so a delayed teardown of an old server never clears a newer OPEN (0 = none).
 * [wifi] = a server started for the Wi-Fi scope
 * (`MateBridge/Wi-Fi/` only), [generation] = the control connection generation it was started for. A READY that is not
 * tagged with the current generation, and a file tunnel whose server is not a Wi-Fi one, are never trusted: a stale or
 * USB-scope server (possibly the whole storage) must not be reachable over Wi-Fi. [NONE]: no server.
 */
data class FilesServerScope(val wifi: Boolean, val generation: Int, val request: Int = 0) {
    companion object {
        val NONE = FilesServerScope(false, -1)
    }
}

/**
 * How many file connections to open next (PROTOCOL.md "Dosya bağlantısı", research section 2): keep [pool] proven idle
 * connections, at most [max] in total, at most [MAX_UNPROVEN] still handshaking at once (the host drops more of them).
 * Pure; the tunnel feeds it the counters under its lock.
 */
internal class PoolPlanner(val pool: Int, val max: Int) {
    var opening = 0 // connected or connecting, not proven yet
    var idle = 0 // proven, no HTTP bytes yet
    var paired = 0 // carrying a local connection

    val total: Int get() = opening + idle + paired

    fun toOpen(): Int = minOf(pool - idle - opening, max - total, MAX_UNPROVEN - opening).coerceAtLeast(0)

    companion object {
        const val MAX_UNPROVEN = 2
    }
}

/**
 * The encrypted file connections of the tablet-files server over Wi-Fi (decision 0035, PROTOCOL.md "Dosya bağlantısı").
 *
 * The tablet opens no LAN port: it dials the Mac's file listener. A pool of idle, key-proven connections is kept ready
 * (`plan.pool`, total `plan.max`); the first `FILES_DATA` from the Mac pairs a connection 1:1 with a new local
 * connection to the tablet's own server on `127.0.0.1:davPort`, and bytes flow both ways until either side closes (then
 * the other closes too, no message). A paired connection is replaced by a new idle one.
 *
 * Per connection: connect (traffic class and keepalive through [tune]) -> plain `FILES_HELLO` -> plain
 * `FILES_HELLO_ACK` within [ACK_TIMEOUT_MS] -> keys from the session's `prk` and the two nonces -> sealed `PING` as proof ->
 * idle (a sealed `PING` every [PING_INTERVAL_MS]) -> first host `FILES_DATA` pairs. The tablet never sends
 * `FILES_DATA` on a connection the host has not sent one on (the pump starts only after pairing). Only `FILES_DATA` and
 * `PING` are accepted from the host; any other known type, a failed tag or a malformed record closes that connection only.
 *
 * Bounded memory: blocking sockets give backpressure (the reader stops reading while the local socket blocks and vice
 * versa); each direction holds at most one [CHUNK_BYTES] chunk plus the record decoder's partial record. Rate: the
 * tablet's server paces the bytes it sends (its bucket follows the stream bit rate), so the tunnel adds no second bucket
 * on that path (a second bucket in series would put small answers behind a big transfer's debt again).
 *
 * Threads (all daemon): one pool thread, one per connection and one pump per paired connection. [close] is idempotent,
 * non-blocking and closes every socket; nothing is logged with a path, a header or a token (counters and states only).
 */
class FilesTunnel(
    private val plan: FilesTunnelPlan,
    private val secrets: SessionSecrets,
    /** A new, unconnected socket for the Mac (the traffic class is set on it before the connect). */
    private val newHostSocket: () -> Socket = { Socket() },
    /** After the connect: keepalive and the like. Must not throw. */
    private val tune: (Socket) -> Unit = {},
    /** First thing on every tunnel thread (lowers the priority on Android). */
    private val threadStarted: () -> Unit = {},
    private val log: (warn: Boolean, ev: String, fields: String) -> Unit = { _, _, _ -> },
    private val random: SecureRandom = SecureRandom(),
    private val nowUs: () -> Long = { System.nanoTime() / 1000 },
    private val nowMs: () -> Long = { System.nanoTime() / 1_000_000 },
    /** Idle keepalive PING interval and the handshake deadline; the PROTOCOL.md values, parameters only for tests. */
    private val pingIntervalMs: Int = PING_INTERVAL_MS,
    private val ackTimeoutMs: Long = ACK_TIMEOUT_MS,
    /**
     * Defence in depth: the scope of the tablet server that is running right now. A connection pairs (connects to the
     * local server) only when it is a Wi-Fi server of the plan's generation; anything else ends the connection
     * (`reason=scope_mismatch`), so a USB-scope or previous-session server is never reached through the tunnel.
     */
    private val davScope: () -> FilesServerScope,
    /** A new unconnected socket for the local connection to the tablet's own server (tests wrap it). */
    private val newDavSocket: () -> Socket = { Socket() },
    /** A socket write (Mac side or tablet-server side) with no progress for this long closes BOTH sockets of its connection. */
    private val writeTimeoutMs: Long = WRITE_TIMEOUT_MS,
) {
    private val planner = PoolPlanner(plan.pool.coerceIn(1, 4), plan.max.coerceIn(plan.pool.coerceIn(1, 4), 16))
    private val lock = Object()
    private val conns = HashSet<Conn>()
    private val closed = AtomicBoolean(false)
    private var started = false
    private var failStreak = 0
    private var nextOpenAtMs = 0L
    private val connSeq = AtomicLong()

    /**
     * Java sockets have no write timeout: a Mac that keeps the TCP connection open but stops reading (or a local server
     * that stops reading) would leave a writer blocked for ever and the slot counted against `max`. Every raw write is
     * bracketed by a [WriteWatchdog] watch; a stalled one closes the whole connection (network and local socket).
     */
    private val watchdog = WriteWatchdog(writeTimeoutMs)
    private val stallTotal = AtomicLong()
    private val timer = ScheduledThreadPoolExecutor(1) { r -> Thread(r, "mb-files-timer").also { it.isDaemon = true } }
        .apply { removeOnCancelPolicy = true }

    // Counters for the summary lines (any thread).
    private val openedTotal = AtomicLong()
    private val provenTotal = AtomicLong()
    private val pairedTotal = AtomicLong()
    private val failedTotal = AtomicLong()
    private val rejectedTotal = AtomicLong()
    private val bytesFromHost = AtomicLong() // Mac -> tablet server
    private val bytesToHost = AtomicLong() // tablet server -> Mac

    /** Counters: opened, proven, paired, failed (connect / handshake / protocol / IO), rejected (host said no). */
    data class Counters(
        val opened: Long, val proven: Long, val paired: Long, val failed: Long, val rejected: Long,
        val bytesFromHost: Long, val bytesToHost: Long,
    )

    fun counters() = Counters(
        openedTotal.get(), provenTotal.get(), pairedTotal.get(), failedTotal.get(), rejectedTotal.get(),
        bytesFromHost.get(), bytesToHost.get(),
    )

    /** Connections closed because a write made no progress for the write timeout. */
    fun writeStalls(): Long = stallTotal.get()

    /** Live connection counts (idle / paired / still handshaking). */
    fun live(): Triple<Int, Int, Int> = synchronized(lock) { Triple(planner.idle, planner.paired, planner.opening) }

    val isClosed: Boolean get() = closed.get()

    fun start() {
        synchronized(lock) {
            check(!started) { "started twice" }
            started = true
        }
        if (closed.get()) return
        log(false, "files_tunnel_open", "pool=${planner.pool} max=${planner.max}")
        startThread("mb-files-watchdog") { watchdog.runLoop() }
        startThread("mb-files-pool") { poolLoop() }
    }

    /** A daemon thread whose body runs after [threadStarted] (a failure of that hook never loses the body). */
    private fun startThread(name: String, body: () -> Unit) {
        Thread({
            try { threadStarted() } catch (_: RuntimeException) {}
            body()
        }, name).also { it.isDaemon = true; it.start() }
    }

    /** Closes every file connection and its local connection. Idempotent, non-blocking, any thread. */
    fun close(reason: String = "close") {
        if (!closed.compareAndSet(false, true)) return
        val all = synchronized(lock) {
            val copy = conns.toList()
            lock.notifyAll()
            copy
        }
        for (c in all) c.closeAll()
        watchdog.stop()
        try { timer.shutdownNow() } catch (_: RuntimeException) {}
        val c = counters()
        log(
            false, "files_tunnel_close",
            "reason=$reason opened=${c.opened} proven=${c.proven} paired=${c.paired} failed=${c.failed} rejected=${c.rejected} " +
                "h2c_bytes=${c.bytesFromHost} c2h_bytes=${c.bytesToHost}",
        )
    }

    // ---- pool ----

    private fun poolLoop() {
        while (!closed.get()) {
            val opened = ArrayList<Conn>()
            synchronized(lock) {
                if (closed.get()) return
                val now = nowMs()
                var n = planner.toOpen()
                if (n > 0 && now < nextOpenAtMs) {
                    lock.wait(maxOf(1L, nextOpenAtMs - now))
                    return@synchronized
                }
                while (n-- > 0) {
                    val c = Conn(connSeq.incrementAndGet())
                    conns += c
                    planner.opening++
                    opened += c
                }
                if (opened.isNotEmpty()) nextOpenAtMs = maxOf(nextOpenAtMs, now + MIN_OPEN_GAP_MS) // no hot loop on a host that closes at once
                if (opened.isEmpty()) lock.wait()
            }
            for (c in opened) {
                openedTotal.incrementAndGet()
                try {
                    startThread("mb-files-conn-${c.id}") { c.run() }
                } catch (e: OutOfMemoryError) {
                    c.closeAll() // cannot start a thread: counts as a failed connection (its run() never ran)
                    c.finished(ConnState.OPENING, "thread")
                }
            }
        }
    }

    private enum class ConnState { OPENING, IDLE, PAIRED, GONE }

    /** One file connection. The host socket is read by [run]'s thread; a paired connection also has a pump thread. */
    private inner class Conn(val id: Long) {
        private val host: Socket = newHostSocket()
        private var dav: Socket? = null
        private val closing = AtomicBoolean(false)

        /** Guarded by [lock]. */
        var state = ConnState.OPENING
        private val startMs = nowMs()
        @Volatile private var h2c = 0L
        @Volatile private var c2h = 0L

        /** The handshake deadline closed the socket / the local side ended first (reasons of the closing log line). */
        @Volatile private var ackTimedOut = false
        @Volatile private var davEnded = false
        @Volatile private var stalled = false
        @Volatile private var davWriteFailed = false

        /** One watch per writing thread (the reader writes to the local server, the pump and the idle PING write to the Mac). */
        private val hostWatch = watchdog.Watch { onStall() }
        private val davWatch = watchdog.Watch { onStall() }

        private fun onStall() {
            stalled = true
            stallTotal.incrementAndGet()
            closeAll() // both sockets: the blocked writer fails, the other direction ends too
        }

        private inline fun <T> watched(w: WriteWatchdog.Watch, write: () -> T): T {
            w.begin()
            try { return write() } finally { w.end() }
        }

        fun run() {
            var reason = "error"
            try {
                reason = session()
            } catch (e: ProtocolException) {
                reason = "protocol"
            } catch (e: ScopeMismatch) {
                reason = "scope_mismatch"
            } catch (e: IOException) {
                reason = when {
                    stalled -> "write_stall"
                    ackTimedOut -> "ack_timeout"
                    closing.get() || closed.get() -> "closed"
                    else -> "io"
                }
            } catch (e: IllegalStateException) {
                reason = "keys_gone" // the session's secrets were wiped: the session is over
                close("keys_gone")
            } catch (e: RuntimeException) {
                reason = "error"
            } finally {
                closeAll()
            }
            finished(state(), reason)
        }

        private fun state(): ConnState = synchronized(lock) { state }

        /** Handshake, proof, idle and pairing. Returns the reason the connection ended normally. */
        private fun session(): String {
            host.connect(InetSocketAddress(plan.host, plan.port), CONNECT_TIMEOUT_MS)
            host.tcpNoDelay = true
            tune(host)
            if (closed.get() || closing.get()) return "closed"
            val out = host.getOutputStream()
            val input = host.getInputStream()
            val clientNonce = ByteArray(Limits.NONCE_BYTES).also { random.nextBytes(it) }
            // The whole handshake must finish within ACK_TIMEOUT_MS (the host drops a connection that lingers).
            val deadline = try {
                timer.schedule({ if (state() == ConnState.OPENING) { ackTimedOut = true; closeAll() } }, ackTimeoutMs, TimeUnit.MILLISECONDS)
            } catch (e: RejectedExecutionException) {
                return "closed"
            }
            val channel: FilesChannel
            try {
                out.write(Codec.encode(FilesHello(Limits.PROTOCOL_VERSION, plan.sessionId, Bytes(clientNonce))))
                out.flush()
                val frame = PlainFrames.read(input)
                if (frame.type != MsgType.FILES_HELLO_ACK) throw ProtocolException(ProtocolException.Kind.INVALID_VALUE, "first host message is not FILES_HELLO_ACK")
                val ack = Codec.decodePayload(frame.type, frame.payload) as FilesHelloAck
                if (!ack.ok) {
                    rejectedTotal.incrementAndGet()
                    return "rejected"
                }
                channel = FilesChannel(secrets.filesKeys(clientNonce, ack.hostFilesNonce.value))
                // The proof: the first sealed record is a PING (the host proves nothing before it; it answers no PING here).
                out.write(channel.sealer.sealFrame(Codec.encode(Ping(0, nowUs()))))
                out.flush()
            } finally {
                deadline.cancel(false)
            }
            markProven()
            return serve(channel, input, out)
        }

        private fun markProven() {
            provenTotal.incrementAndGet()
            synchronized(lock) {
                if (state == ConnState.OPENING) {
                    state = ConnState.IDLE
                    planner.opening--
                    planner.idle++
                    failStreak = 0
                    lock.notifyAll()
                }
            }
        }

        /** Reads sealed records from the Mac: PING (ignored), the first FILES_DATA pairs, then bytes flow. */
        private fun serve(channel: FilesChannel, input: InputStream, out: OutputStream): String {
            val buf = ByteArray(CHUNK_BYTES)
            var pingSeq = 1L
            var davOut: OutputStream? = null
            // The idle heartbeat is a send deadline on the monotonic clock, not a read timeout: the Mac's own records
            // (its PINGs, anything) must never postpone ours (PROTOCOL: a PING every 10 s on every idle connection).
            var nextPingMs = nowMs() + pingIntervalMs
            while (true) {
                if (davOut == null) host.soTimeout = maxOf(1L, nextPingMs - nowMs()).coerceAtMost(Int.MAX_VALUE.toLong()).toInt()
                val n = try {
                    input.read(buf)
                } catch (e: SocketTimeoutException) {
                    0
                }
                if (n < 0) return if (davWriteFailed) "dav_write_failed" else if (davEnded) "dav_eof" else "host_eof"
                if (n > 0) channel.decoder.feed(buf, 0, n)
                while (n > 0) {
                    val msg = channel.decoder.next() ?: break
                    when (msg) {
                        is Ping -> Unit // keepalive of the other side: no PONG on a file connection
                        is FilesData -> {
                            if (davOut == null) davOut = pair(channel, out)
                            val data = msg.data.value
                            if (davWriteFailed) continue // the local server stopped reading: what the Mac still sends is dropped
                            val dout = davOut
                            try {
                                watched(davWatch) { dout.write(data); dout.flush() }
                            } catch (e: IOException) {
                                if (closing.get() || closed.get()) throw e // the stall watchdog or a close: end as before
                                onLocalWriteFailed()
                                continue
                            }
                            h2c += data.size
                            bytesFromHost.addAndGet(data.size.toLong())
                        }
                        else -> throw ProtocolException(ProtocolException.Kind.INVALID_VALUE, "unexpected message type ${msg.type} on a file connection")
                    }
                }
                // paired: no protocol timeout (HTTP and TCP keepalive decide)
                if (davOut == null && nowMs() >= nextPingMs) {
                    val ping = channel.sealer.sealFrame(Codec.encode(Ping(pingSeq++, nowUs())))
                    watched(hostWatch) { out.write(ping); out.flush() }
                    nextPingMs = nowMs() + pingIntervalMs
                }
            }
        }

        /**
         * The local server stopped reading (e.g. an early 401/403 to a big PUT, then it closed its input): it may still be
         * sending its answer. Stop writing to it and drop the rest of what the Mac sends on this connection, but keep the
         * pump running so the Mac gets the answer instead of an EOF or reset; the connection then ends when the server
         * closes (the pump's FIN and drain timer), or after at most [DRAIN_GRACE_MS] from now if it never does.
         */
        private fun onLocalWriteFailed() {
            davWriteFailed = true
            try {
                timer.schedule({ closeAll() }, DRAIN_GRACE_MS, TimeUnit.MILLISECONDS)
            } catch (e: RejectedExecutionException) {
                closeAll()
            }
        }

        /** The first FILES_DATA arrived: connect to the tablet's own server and start the tablet-to-Mac pump. */
        private fun pair(channel: FilesChannel, out: OutputStream): OutputStream {
            val sc = davScope()
            if (!sc.wifi || sc.generation != plan.gen || sc.request != plan.request) throw ScopeMismatch() // never the USB root or an earlier session's server
            val d = newDavSocket()
            dav = d
            if (closing.get() || closed.get()) { closeQuietly(d); throw IOException("closed") }
            d.connect(InetSocketAddress(LOOPBACK, plan.davPort), DAV_CONNECT_TIMEOUT_MS)
            d.tcpNoDelay = true
            host.soTimeout = 0
            synchronized(lock) {
                if (state == ConnState.IDLE) {
                    state = ConnState.PAIRED
                    planner.idle--
                    planner.paired++
                    lock.notifyAll() // the pool replaces this connection
                }
            }
            pairedTotal.incrementAndGet()
            startThread("mb-files-pump-$id") { pump(d, channel, out) }
            return d.getOutputStream()
        }

        /** Tablet server -> Mac: reads of at most [CHUNK_BYTES] become sealed FILES_DATA records (<= 16 KiB). */
        private fun pump(d: Socket, channel: FilesChannel, out: OutputStream) {
            val buf = ByteArray(CHUNK_BYTES)
            val input = d.getInputStream()
            try {
                while (true) {
                    val n = input.read(buf)
                    if (n < 0) break
                    val payload = ByteArray(2 + n)
                    payload[0] = n.toByte()
                    payload[1] = (n ushr 8).toByte()
                    System.arraycopy(buf, 0, payload, 2, n)
                    val record = channel.sealer.seal(MsgType.FILES_DATA, payload)
                    watched(hostWatch) { out.write(record); out.flush() }
                    c2h += n
                    bytesToHost.addAndGet(n.toLong())
                }
            } catch (e: IOException) {
                // the local or the Mac side went away: the connection ends below
            }
            davEnded = true
            // The local side closed (or failed) after its last byte went out: end the file connection with a FIN so the
            // Mac sees every byte before the EOF (a plain close with unread input could reset it); the reader closes
            // everything when the Mac's side ends, and a timer makes sure it does.
            if (closing.get() || closed.get()) return
            try { host.shutdownOutput() } catch (_: IOException) {}
            closeQuietly(d)
            try {
                timer.schedule({ closeAll() }, DRAIN_GRACE_MS, TimeUnit.MILLISECONDS)
            } catch (e: RejectedExecutionException) {
                closeAll()
            }
        }

        /** Closes both sockets (idempotent, any thread); the reader and the pump end by their failed I/O. */
        fun closeAll() {
            closing.set(true)
            closeQuietly(host)
            dav?.let { closeQuietly(it) }
        }

        /** Bookkeeping of the planner and the log once the connection is over. */
        fun finished(was: ConnState, reason: String) {
            var failed = false
            synchronized(lock) {
                when (state) {
                    ConnState.OPENING -> planner.opening--
                    ConnState.IDLE -> planner.idle--
                    ConnState.PAIRED -> planner.paired--
                    ConnState.GONE -> return
                }
                state = ConnState.GONE
                conns -= this
                // Only a connection that never got proven backs the pool off (a replaced idle or paired one does not).
                if (was == ConnState.OPENING && reason != "closed" && reason != "keys_gone") {
                    failStreak++
                    nextOpenAtMs = nowMs() + backoffMs(failStreak)
                    failed = true
                }
                lock.notifyAll()
            }
            if (failed) failedTotal.incrementAndGet()
            if (closed.get() && reason == "closed") return // the tunnel's own summary line covers these
            when {
                was == ConnState.PAIRED ->
                    log(false, "files_conn_closed", "conn=$id reason=$reason h2c_bytes=$h2c c2h_bytes=$c2h ms=${nowMs() - startMs}")
                // repeated failures (a host that keeps saying no) are logged on the first few and then every 12th
                was == ConnState.OPENING -> if (failStreak <= 3 || failStreak % 12 == 0) {
                    log(true, "files_conn_failed", "conn=$id reason=$reason streak=$failStreak")
                }
                // an idle connection ended: the host closed it, an error, or its pool entry was replaced; no payload bytes
                else -> log(false, "files_conn_closed", "conn=$id reason=$reason idle=1")
            }
        }
    }

    private fun closeQuietly(s: Socket) {
        try { s.close() } catch (_: IOException) {}
    }

    /** The tablet server running now is not the Wi-Fi server of this session. */
    private class ScopeMismatch : IOException("server scope")

    companion object {
        const val CONNECT_TIMEOUT_MS = 5_000
        const val ACK_TIMEOUT_MS = 5_000L
        const val DAV_CONNECT_TIMEOUT_MS = 2_000
        const val PING_INTERVAL_MS = 10_000

        /** Same stall limit as the tablet's own server (FilesConfig.WRITE_TIMEOUT_MS). */
        const val WRITE_TIMEOUT_MS = FilesConfig.WRITE_TIMEOUT_MS.toLong()

        /** Least time between two pool openings (a safety against a spin; a handshake takes longer anyway). */
        const val MIN_OPEN_GAP_MS = 20L

        /** Largest chunk per read and per FILES_DATA record on the Wi-Fi path (PROTOCOL.md: <= 16 KiB). */
        const val CHUNK_BYTES = 16 * 1024

        /** After the local side ended, how long the Mac gets to close its end before the connection is closed anyway. */
        const val DRAIN_GRACE_MS = 3_000L

        private const val LOOPBACK = "127.0.0.1"

        /** Retry delay after [streak] consecutive failures: 250 ms doubling to 5 s. */
        fun backoffMs(streak: Int): Long =
            if (streak <= 0) 0 else minOf(5_000L, 250L shl (streak - 1).coerceAtMost(5))
    }
}
