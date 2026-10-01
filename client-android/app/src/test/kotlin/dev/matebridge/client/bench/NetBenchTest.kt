package dev.matebridge.client.bench

import dev.matebridge.client.session.Endpoint
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.InputStream
import java.net.ServerSocket
import java.net.Socket
import java.util.Collections
import java.util.concurrent.atomic.AtomicLong
import kotlin.concurrent.thread

class NetBenchTest {
    private fun parse(vararg extras: Pair<String, Any>): NetBenchConfig.Parsed? {
        val m = extras.toMap()
        return NetBenchConfig.parse({ m[it] as? String }, { it in m }, { (m[it] as? Int) ?: 0 })
    }

    private fun ok(vararg extras: Pair<String, Any>) = (parse(*extras) as NetBenchConfig.Parsed.Ok).config

    @Test fun absentExtraMeansNoBench() {
        assertNull(parse())
        assertNull(parse("net_bench_s" to 5))
    }

    @Test fun defaults() {
        val c = ok("net_bench" to "192.168.1.20:5201")
        assertEquals(Endpoint("192.168.1.20", 5201), c.endpoint)
        assertEquals(8, c.seconds)
        assertEquals(listOf(BenchDir.DOWN), c.dirs)
        assertEquals(1, c.streams)
        assertNull(c.rcvbufKb)
        assertEquals("host=192.168.1.20 port=5201 dir=down secs=8 streams=1 rcvbuf_kb=-", c.logFields())
    }

    @Test fun malformedEndpointIsInvalid() {
        assertEquals(NetBenchConfig.Parsed.Invalid, parse("net_bench" to "nohost"))
        assertEquals(NetBenchConfig.Parsed.Invalid, parse("net_bench" to "1.2.3.4:0"))
        assertEquals(NetBenchConfig.Parsed.Invalid, parse("net_bench" to ""))
    }

    @Test fun directions() {
        assertEquals(listOf(BenchDir.UP), ok("net_bench" to "h:1", "net_bench_dir" to "up").dirs)
        assertEquals(listOf(BenchDir.DOWN, BenchDir.UP), ok("net_bench" to "h:1", "net_bench_dir" to "BOTH").dirs)
        assertEquals("both", ok("net_bench" to "h:1", "net_bench_dir" to "both").dirLabel)
        assertEquals(listOf(BenchDir.DOWN), ok("net_bench" to "h:1", "net_bench_dir" to "sideways").dirs)
    }

    @Test fun clamping() {
        assertEquals(1, ok("net_bench" to "h:1", "net_bench_s" to 0).seconds)
        assertEquals(600, ok("net_bench" to "h:1", "net_bench_s" to 99999).seconds)
        assertEquals(4, ok("net_bench" to "h:1", "net_bench_streams" to 9).streams)
        assertEquals(1, ok("net_bench" to "h:1", "net_bench_streams" to -2).streams)
        assertEquals(3, ok("net_bench" to "h:1", "net_bench_streams" to 3).streams)
    }

    @Test fun rcvbufOnlyWhenPositive() {
        assertEquals(512, ok("net_bench" to "h:1", "net_bench_rcvbuf_kb" to 512).rcvbufKb)
        assertNull(ok("net_bench" to "h:1", "net_bench_rcvbuf_kb" to 0).rcvbufKb)
        assertNull(ok("net_bench" to "h:1", "net_bench_rcvbuf_kb" to -1).rcvbufKb)
    }

    @Test fun mbpsMath() {
        assertEquals(8.0, Throughput.mbps(1_000_000, 1_000_000_000), 1e-9) // 1 MB in 1 s = 8 Mbps
        assertEquals(100.0, Throughput.mbps(6_250_000, 500_000_000), 1e-9)
        assertEquals(0.0, Throughput.mbps(123, 0), 0.0)
        assertEquals("27.3", Throughput.fmt(27.25001))
    }

    @Test fun statsAverageIsTotalOverTime() {
        val s = ThroughputStats()
        assertEquals("mbps_avg=- mbps_min=- mbps_max=- bytes=0 ticks=0", s.doneFields())
        assertEquals(80.0, s.add(10_000_000, 1_000_000_000), 1e-9)
        assertEquals(16.0, s.add(1_000_000, 500_000_000), 1e-9)
        assertEquals(16.0, s.min, 1e-9)
        assertEquals(80.0, s.max, 1e-9)
        assertEquals(11_000_000 * 8_000.0 / 1_500_000_000, s.avg, 1e-9) // not the mean of the two rates
        assertEquals("mbps_avg=58.7 mbps_min=16.0 mbps_max=80.0 bytes=11000000 ticks=2", s.doneFields())
    }

    private fun readHeader(inp: InputStream): String {
        val sb = StringBuilder()
        while (true) {
            val b = inp.read()
            if (b < 0 || b == '\n'.code) return sb.toString()
            sb.append(b.toChar())
        }
    }

    @Test fun loopbackBothDirectionsTwoStreams() {
        val server = ServerSocket(0)
        val headers = Collections.synchronizedList(mutableListOf<String>())
        val received = AtomicLong()
        val acceptor = thread(isDaemon = true) {
            repeat(4) {
                val c: Socket = try { server.accept() } catch (_: Exception) { return@thread }
                thread(isDaemon = true) {
                    try {
                        val inp = c.getInputStream()
                        val h = readHeader(inp)
                        headers += h
                        if ("dir=down" in h) {
                            val buf = ByteArray(64 * 1024)
                            while (true) c.getOutputStream().write(buf)
                        } else {
                            val buf = ByteArray(64 * 1024)
                            while (true) { val n = inp.read(buf); if (n < 0) break; received.addAndGet(n.toLong()) }
                        }
                    } catch (_: Exception) {
                    } finally { c.close() }
                }
            }
        }
        val logs = Collections.synchronizedList(mutableListOf<String>())
        val cfg = NetBenchConfig(Endpoint("127.0.0.1", server.localPort), seconds = 1, dirs = listOf(BenchDir.DOWN, BenchDir.UP), streams = 2)
        val r = NetBenchRunner(cfg, log = { _, ev, f -> logs += "$ev $f" }, tickMs = 100, durationMs = 400)
        assertTrue(r.run())
        server.close()
        acceptor.join(1000)

        assertEquals(
            setOf("netbench dir=down stream=0 secs=1", "netbench dir=down stream=1 secs=1",
                "netbench dir=up stream=0 secs=1", "netbench dir=up stream=1 secs=1"),
            headers.toSet(),
        )
        val down = r.results.getValue(BenchDir.DOWN)
        val up = r.results.getValue(BenchDir.UP)
        assertTrue(down.totalBytes > 0)
        assertTrue(up.totalBytes > 0)
        assertTrue(down.ticks in 3..5)
        assertTrue(logs.count { it.startsWith("tick dir=down") } == down.ticks)
        assertTrue(logs.any { it.startsWith("done dir=up streams=2") && "mbps_avg=" in it })
        assertTrue(logs.any { it.startsWith("connected dir=up stream=1") })
    }

    @Test fun connectFailureReportsError() {
        val port = ServerSocket(0).use { it.localPort } // closed again: nothing listens there
        val logs = mutableListOf<String>()
        val r = NetBenchRunner(
            NetBenchConfig(Endpoint("127.0.0.1", port)),
            log = { _, ev, f -> logs += "$ev $f" }, tickMs = 100, durationMs = 200,
        )
        assertFalse(r.run())
        assertTrue(logs.any { it.startsWith("error stage=connect") })
        assertTrue(r.results.isEmpty())
    }
}
