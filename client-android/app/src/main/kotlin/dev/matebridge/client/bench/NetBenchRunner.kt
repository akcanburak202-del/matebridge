package dev.matebridge.client.bench

import java.io.IOException
import java.net.InetSocketAddress
import java.net.Socket
import java.util.concurrent.atomic.AtomicLong

/**
 * Raw TCP throughput bench (T-090), plain java.net so it runs in JVM tests. [run] blocks; call it off the UI thread.
 *
 * Each connection first writes one ASCII line `netbench dir=down|up stream=<i> secs=<S>\n` so the Mac-side script
 * can tell connections apart; afterwards `down` connections only read (and discard) and `up` connections only write.
 * Rates are application-level: `up` counts bytes accepted by the socket (up to one send buffer ahead of the wire).
 */
class NetBenchRunner(
    private val config: NetBenchConfig,
    /** (level 'I'/'W', ev, fields) -> logcat `MB/netbench`. */
    private val log: (Char, String, String) -> Unit,
    /** Human-readable screen text, called from the bench thread. */
    private val onUpdate: (String) -> Unit = {},
    private val tickMs: Long = 1000,
    private val durationMs: Long = config.seconds * 1000L,
    private val connectTimeoutMs: Int = 3000,
) {
    private class Lane(val dir: BenchDir) {
        val counter = AtomicLong()
        val stats = ThroughputStats()
        var last = 0L
        var lastMbps = 0.0
    }

    @Volatile private var cancelled = false
    private val sockets = mutableListOf<Socket>()
    private val workers = mutableListOf<Thread>()
    private val live = AtomicLong()

    /** Per-direction summaries after [run]; empty if it failed to connect. */
    val results = LinkedHashMap<BenchDir, ThroughputStats>()

    fun cancel() {
        cancelled = true
        closeAll()
    }

    /** Returns true when the measurement ran (even if cut short); false on a connect failure. */
    fun run(): Boolean {
        log('I', "start", config.logFields())
        onUpdate("Ağ ölçümü… bağlanıyor ${config.endpoint}")
        val lanes = config.dirs.map { Lane(it) }
        try {
            for (lane in lanes) for (i in 0 until config.streams) {
                if (cancelled) return false
                startStream(lane, i, connect(lane.dir, i))
            }
        } catch (e: IOException) {
            log('W', "error", "stage=connect err=${e.javaClass.simpleName}")
            onUpdate("Ağ ölçümü: bağlantı hatası ${config.endpoint} (${e.javaClass.simpleName})")
            closeAll()
            return false
        }

        val start = System.nanoTime()
        var lastT = start
        var k = 1L
        while (!cancelled) {
            val due = start + k * tickMs * 1_000_000L
            val sleepMs = (due - System.nanoTime()) / 1_000_000L
            if (sleepMs > 0) try { Thread.sleep(sleepMs) } catch (_: InterruptedException) { break }
            val now = System.nanoTime()
            tick(lanes, now - lastT, now - start)
            lastT = now
            k++
            if (now - start >= durationMs * 1_000_000L - tickMs * 500_000L) break // within half a tick of the end
            if (live.get() == 0L) { log('W', "early_end", "reason=all_streams_closed"); break }
        }
        val tail = System.nanoTime() - lastT
        if (tail > tickMs * 100_000L) tick(lanes, tail, System.nanoTime() - start) // >= 10% of a tick left over

        closeAll()
        workers.forEach { it.join(1000) }
        val secs = Throughput.fmt((System.nanoTime() - start) / 1e9)
        val summary = StringBuilder("Ağ ölçümü bitti (${secs} s, ${config.streams} bağlantı/yön)")
        for (lane in lanes) {
            results[lane.dir] = lane.stats
            log('I', "done", "dir=${lane.dir.wire} streams=${config.streams} secs=$secs ${lane.stats.doneFields()}")
            val s = lane.stats
            summary.append("\n${lane.dir.wire}: ort ${Throughput.fmt(s.avg)} Mbps")
            if (s.ticks > 0) summary.append(" (min ${Throughput.fmt(s.min)}, maks ${Throughput.fmt(s.max)})")
        }
        if (cancelled) summary.append("\n(iptal edildi)")
        onUpdate(summary.toString())
        return true
    }

    private fun tick(lanes: List<Lane>, nanos: Long, elapsedNanos: Long) {
        for (lane in lanes) {
            val now = lane.counter.get()
            val delta = now - lane.last
            lane.last = now
            lane.lastMbps = lane.stats.add(delta, nanos)
            log('I', "tick", "dir=${lane.dir.wire} mbps=${Throughput.fmt(lane.lastMbps)} bytes=$delta ms=${nanos / 1_000_000}")
        }
        val rates = lanes.joinToString("  ·  ") { "${it.dir.wire} ${Throughput.fmt(it.lastMbps)} Mbps" }
        onUpdate("Ağ ölçümü… $rates\n(${elapsedNanos / 1_000_000_000}/${durationMs / 1000} s)")
    }

    private fun connect(dir: BenchDir, index: Int): Socket {
        val s = Socket()
        synchronized(sockets) { sockets += s }
        config.rcvbufKb?.let { s.receiveBufferSize = it * 1024 } // before connect so window scaling sees it
        s.connect(InetSocketAddress(config.endpoint.host, config.endpoint.port), connectTimeoutMs)
        s.getOutputStream().apply {
            write("netbench dir=${dir.wire} stream=$index secs=${config.seconds}\n".toByteArray(Charsets.US_ASCII))
            flush()
        }
        log('I', "connected", "dir=${dir.wire} stream=$index rcvbuf=${s.receiveBufferSize} sndbuf=${s.sendBufferSize}")
        return s
    }

    private fun startStream(lane: Lane, index: Int, s: Socket) {
        live.incrementAndGet()
        val t = Thread({
            try {
                if (lane.dir == BenchDir.DOWN) {
                    val buf = ByteArray(READ_BUF)
                    val input = s.getInputStream()
                    while (!cancelled) {
                        val n = input.read(buf)
                        if (n < 0) { if (!stopping) log('W', "stream_end", "dir=down stream=$index reason=eof"); break }
                        lane.counter.addAndGet(n.toLong())
                    }
                } else {
                    val buf = ByteArray(WRITE_BUF)
                    val out = s.getOutputStream()
                    while (!cancelled) {
                        out.write(buf)
                        lane.counter.addAndGet(buf.size.toLong())
                    }
                }
            } catch (e: IOException) {
                if (!stopping && !cancelled) log('W', "stream_end", "dir=${lane.dir.wire} stream=$index err=${e.javaClass.simpleName}")
            } finally {
                live.decrementAndGet()
            }
        }, "netbench-${lane.dir.wire}-$index")
        t.isDaemon = true
        workers += t
        t.start()
    }

    @Volatile private var stopping = false

    private fun closeAll() {
        stopping = true
        val all = synchronized(sockets) { sockets.toList() }
        for (s in all) try { s.close() } catch (_: IOException) {}
    }

    companion object {
        const val READ_BUF = 256 * 1024
        const val WRITE_BUF = 64 * 1024
    }
}
