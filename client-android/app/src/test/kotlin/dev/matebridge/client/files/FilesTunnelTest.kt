package dev.matebridge.client.files

import dev.matebridge.client.protocol.Bytes
import dev.matebridge.client.protocol.Codec
import dev.matebridge.client.protocol.FilesData
import dev.matebridge.client.protocol.FilesHello
import dev.matebridge.client.protocol.FilesHelloAck
import dev.matebridge.client.protocol.Limits
import dev.matebridge.client.protocol.Message
import dev.matebridge.client.protocol.MsgType
import dev.matebridge.client.protocol.Ping
import dev.matebridge.client.protocol.StreamConfig
import dev.matebridge.client.security.FilesChannel
import dev.matebridge.client.security.PlainFrames
import dev.matebridge.client.security.RecordDecoder
import dev.matebridge.client.security.RecordOpener
import dev.matebridge.client.security.RecordSealer
import dev.matebridge.client.security.SessionSecrets
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.security.SecureRandom
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.atomic.AtomicInteger
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * T-269 (decision 0035): the file tunnel against a scripted Mac (a real loopback listener speaking the PROTOCOL.md
 * "Dosya bağlantısı" rules with the real key schedule) and a scripted tablet server (an echo / canned-answer socket).
 */
class FilesTunnelTest {
    private val prk = ByteArray(32) { (it * 7 + 3).toByte() }
    private val secrets = SessionSecrets(prk, pairing = false, hostId = ByteArray(16))
    private val toClose = ArrayList<AutoCloseable>()

    /** What the tablet reports as the running server's scope: a Wi-Fi server of the plan's generation (7) by default. */
    @Volatile private var davScopeNow = FilesServerScope(true, 7)

    @After fun cleanup() {
        for (c in toClose.reversed()) try { c.close() } catch (_: Exception) {}
    }

    // ---- scripted Mac ----

    private enum class Mode { OK, REJECT, SILENT, CLOSE_AT_ONCE }

    /** The Mac's file listener: accepts, answers FILES_HELLO per [mode], proves the tablet's PING, then serves [HostConn]s. */
    private inner class TestHost(val hostPrk: ByteArray = prk) : AutoCloseable {
        val server = ServerSocket(0, 50, InetAddress.getByName("127.0.0.1")).also { toClose += AutoCloseable { it.close() } }
        val port get() = server.localPort
        @Volatile var mode = Mode.OK
        val conns = CopyOnWriteArrayList<HostConn>()
        val accepted = AtomicInteger()
        val rejected = AtomicInteger()
        val hellos = CopyOnWriteArrayList<FilesHello>()

        init {
            Thread({
                try {
                    while (true) {
                        val s = server.accept()
                        accepted.incrementAndGet()
                        Thread { serve(s) }.also { it.isDaemon = true; it.start() }
                    }
                } catch (_: IOException) {}
            }, "test-host-accept").also { it.isDaemon = true; it.start() }
            toClose += this
        }

        private fun serve(s: Socket) {
            try {
                s.tcpNoDelay = true
                val input = s.getInputStream()
                val f = PlainFrames.read(input)
                assertEquals(MsgType.FILES_HELLO, f.type)
                val hello = Codec.decodePayload(f.type, f.payload) as FilesHello
                hellos += hello
                when (mode) {
                    Mode.SILENT -> { Thread.sleep(20_000); return }
                    Mode.CLOSE_AT_ONCE -> { s.close(); return }
                    Mode.REJECT -> {
                        rejected.incrementAndGet()
                        s.getOutputStream().write(Codec.encode(FilesHelloAck(FilesHelloAck.REJECTED, Bytes(ByteArray(16)))))
                        s.close()
                        return
                    }
                    Mode.OK -> Unit
                }
                val hostNonce = ByteArray(16).also { SecureRandom().nextBytes(it) }
                s.getOutputStream().write(Codec.encode(FilesHelloAck(FilesHelloAck.OK, Bytes(hostNonce))))
                s.getOutputStream().flush()
                val keys = SessionSecrets(hostPrk, pairing = false, hostId = ByteArray(16)).filesKeys(hello.clientFilesNonce.value, hostNonce)
                val c = HostConn(s, hello, RecordSealer(keys.h2c), RecordDecoder(Limits.CONTROL_MAX_PAYLOAD, RecordOpener(keys.c2h)))
                conns += c
                c.readLoop()
            } catch (_: Exception) {
                // the test ended or the tablet closed
            }
        }

        override fun close() {
            try { server.close() } catch (_: IOException) {}
            for (c in conns) c.close()
        }

        fun awaitProven(n: Int, timeoutMs: Long = 5_000) =
            eventually(timeoutMs) { conns.count { it.proven } >= n }
    }

    private inner class HostConn(val socket: Socket, val hello: FilesHello, val sealer: RecordSealer, val decoder: RecordDecoder) : AutoCloseable {
        @Volatile var proven = false
        @Volatile var eof = false
        @Volatile var failure: Exception? = null
        val inbox = LinkedBlockingQueue<Message>()
        val pings = AtomicInteger()
        val received = ByteArrayOutputStream()
        @Volatile var paused = false // stop reading: the Mac keeps the TCP connection open but never drains it
        @Volatile var maxRecord = 0
        @Volatile var records = 0

        fun readLoop() {
            val buf = ByteArray(16 * 1024)
            val input = socket.getInputStream()
            try {
                while (true) {
                    while (paused) Thread.sleep(5)
                    val n = input.read(buf)
                    if (n < 0) break
                    decoder.feed(buf, 0, n)
                    while (true) {
                        val m = decoder.next() ?: break
                        if (m is Ping) { pings.incrementAndGet(); proven = true }
                        if (m is FilesData) {
                            synchronized(received) { received.write(m.data.value) }
                            maxRecord = maxOf(maxRecord, m.data.size)
                            records++
                        }
                        inbox.add(m)
                    }
                }
            } catch (e: Exception) {
                failure = e
            }
            eof = true
            close() // the Mac's proxy closes the local connection when the file connection ends
        }

        @Synchronized fun send(m: Message) = sendRaw(sealer.sealFrame(Codec.encode(m)))

        @Synchronized fun sendRaw(b: ByteArray) {
            socket.getOutputStream().write(b)
            socket.getOutputStream().flush()
        }

        fun data(): ByteArray = synchronized(received) { received.toByteArray() }

        override fun close() { try { socket.close() } catch (_: IOException) {} }
    }

    // ---- scripted tablet server ----

    /** What the tablet's own server does with a local connection: echo everything, or answer from [answer] then close. */
    private inner class TestDav(val echo: Boolean = true, val closeAfterEcho: Boolean = false, val answer: ByteArray? = null) : AutoCloseable {
        val server = ServerSocket(0, 50, InetAddress.getByName("127.0.0.1"))
        val port get() = server.localPort
        val accepted = AtomicInteger()
        val socks = CopyOnWriteArrayList<Socket>()
        val got = CopyOnWriteArrayList<ByteArray>()
        @Volatile var eofSeen = 0
        @Volatile var stopReading = false

        init {
            Thread({
                try {
                    while (true) {
                        val s = server.accept()
                        accepted.incrementAndGet()
                        socks += s
                        Thread { handle(s) }.also { it.isDaemon = true; it.start() }
                    }
                } catch (_: IOException) {}
            }, "test-dav-accept").also { it.isDaemon = true; it.start() }
            toClose += this
        }

        private fun handle(s: Socket) {
            try {
                val input = s.getInputStream()
                val out = s.getOutputStream()
                val buf = ByteArray(8192)
                if (stopReading) { Thread.sleep(30_000); return }
                if (answer != null) {
                    // read one chunk of the request, answer, close (a "Connection: close" answer)
                    val n = input.read(buf)
                    if (n > 0) got += buf.copyOf(n)
                    out.write(answer); out.flush()
                    s.close()
                    return
                }
                while (true) {
                    val n = input.read(buf)
                    if (n < 0) { eofSeen++; break }
                    got += buf.copyOf(n)
                    if (echo) { out.write(buf, 0, n); out.flush() }
                    if (closeAfterEcho) { s.close(); return }
                }
            } catch (_: IOException) {
                eofSeen++
            }
        }

        override fun close() {
            try { server.close() } catch (_: IOException) {}
            for (s in socks) try { s.close() } catch (_: IOException) {}
        }
    }

    private fun tunnel(
        host: TestHost, dav: TestDav?, pool: Int = 2, max: Int = 12, secrets: SessionSecrets = this.secrets,
        pingMs: Int = FilesTunnel.PING_INTERVAL_MS, ackMs: Long = FilesTunnel.ACK_TIMEOUT_MS, logs: MutableList<String>? = null,
        writeMs: Long = FilesTunnel.WRITE_TIMEOUT_MS,
    ): FilesTunnel {
        val plan = FilesTunnelPlan(7, "127.0.0.1", host.port, pool, max, dav?.port ?: 1, 2712847316L)
        return FilesTunnel(
            plan, secrets, davScope = { davScopeNow },
            log = { _, ev, f -> logs?.add("$ev $f") },
            pingIntervalMs = pingMs, ackTimeoutMs = ackMs, writeTimeoutMs = writeMs,
        ).also { toClose += AutoCloseable { it.close() }; it.start() }
    }

    private fun eventually(timeoutMs: Long = 5_000, cond: () -> Boolean): Boolean {
        val end = System.nanoTime() + timeoutMs * 1_000_000
        while (System.nanoTime() < end) {
            if (cond()) return true
            Thread.sleep(10)
        }
        return cond()
    }

    private fun http(n: Int) = ByteArray(n) { ('a'.code + it % 26).toByte() }

    // ---- tests ----

    @Test fun poolOpensAndProvesTheIdleConnectionsWithAFreshNoncePerConnection() {
        val host = TestHost(); val dav = TestDav()
        val t = tunnel(host, dav, pool = 2)
        assertTrue(host.awaitProven(2))
        assertEquals(2, host.hellos.size)
        for (h in host.hellos) {
            assertEquals(1, h.protocolVersion)
            assertEquals(2712847316L, h.sessionId)
            assertEquals(16, h.clientFilesNonce.size)
        }
        assertNotEquals(host.hellos[0].clientFilesNonce, host.hellos[1].clientFilesNonce)
        assertTrue(eventually { t.live() == Triple(2, 0, 0) })
        // every idle connection's first record is the proof PING
        assertTrue(host.conns.all { it.pings.get() >= 1 })
        assertEquals(0L, t.counters().paired)
        assertEquals(0, dav.accepted.get()) // the tablet's server is touched only by a paired connection
    }

    @Test fun theTabletNeverSendsDataOnAnIdleConnection() {
        val host = TestHost(); val dav = TestDav()
        tunnel(host, dav, pool = 1)
        assertTrue(host.awaitProven(1))
        Thread.sleep(300)
        assertEquals(0, host.conns.single().records)
        assertEquals(0, dav.accepted.get())
    }

    @Test fun theFirstHostDataPairsAConnectionAndBytesFlowBothWaysAndThePoolIsReplenished() {
        val host = TestHost(); val dav = TestDav()
        val t = tunnel(host, dav, pool = 2)
        assertTrue(host.awaitProven(2))
        val c = host.conns[0]
        c.send(FilesData(Bytes("PROPFIND / HTTP/1.1\r\n\r\n".toByteArray())))
        assertTrue(eventually { String(c.data()) == "PROPFIND / HTTP/1.1\r\n\r\n" }) // echoed through the tablet's server
        assertEquals(1, dav.accepted.get())
        assertTrue(eventually { t.live().second == 1 })
        // the paired connection is replaced: two idle again (three connections at the Mac)
        assertTrue(host.awaitProven(3))
        assertTrue(eventually { t.live().first == 2 })
        assertEquals(1L, t.counters().paired)
        // and the answer path keeps working for more requests on the same connection
        c.send(FilesData(Bytes("second".toByteArray())))
        assertTrue(eventually { String(c.data()).endsWith("second") })
    }

    @Test fun aBigTransferIsChunkedAtMost16KiBPerRecordAndArrivesIntact() {
        val host = TestHost(); val dav = TestDav()
        tunnel(host, dav, pool = 1)
        assertTrue(host.awaitProven(1))
        val c = host.conns[0]
        val payload = http(300_000)
        var pos = 0
        while (pos < payload.size) { // the Mac sends <= 16 KiB records
            val n = minOf(16 * 1024, payload.size - pos)
            c.send(FilesData(Bytes(payload.copyOfRange(pos, pos + n))))
            pos += n
        }
        assertTrue(eventually(10_000) { c.data().size == payload.size })
        assertArrayEquals(payload, c.data())
        assertTrue("record of ${c.maxRecord} bytes", c.maxRecord in 1..16 * 1024)
    }

    @Test fun whenTheTabletsServerClosesTheFileConnectionEndsAfterEveryByte() {
        val answer = http(100_000)
        val host = TestHost(); val dav = TestDav(echo = false, answer = answer)
        val t = tunnel(host, dav, pool = 1)
        assertTrue(host.awaitProven(1))
        val c = host.conns[0]
        c.send(FilesData(Bytes("GET /x HTTP/1.1\r\n\r\n".toByteArray())))
        assertTrue(eventually(10_000) { c.eof })
        assertArrayEquals(answer, c.data()) // all bytes before the EOF
        assertEquals(answer.size.toLong(), t.counters().bytesToHost)
        assertTrue(eventually { t.live().second == 0 })
    }

    @Test fun whenTheMacClosesTheLocalConnectionIsClosedToo() {
        val host = TestHost(); val dav = TestDav()
        val t = tunnel(host, dav, pool = 1)
        assertTrue(host.awaitProven(1))
        val c = host.conns[0]
        c.send(FilesData(Bytes("hello".toByteArray())))
        assertTrue(eventually { dav.accepted.get() == 1 && c.data().size == 5 })
        c.close()
        assertTrue(eventually { dav.eofSeen == 1 })
        assertTrue(eventually { t.live().second == 0 })
    }

    @Test fun totalConnectionsNeverExceedMax() {
        val host = TestHost(); val dav = TestDav()
        val t = tunnel(host, dav, pool = 2, max = 3)
        assertTrue(host.awaitProven(2))
        host.conns[0].send(FilesData(Bytes("a".toByteArray())))
        assertTrue(host.awaitProven(3)) // replaced: 1 paired + 2 idle = 3
        host.conns[1].send(FilesData(Bytes("b".toByteArray())))
        host.conns[2].send(FilesData(Bytes("c".toByteArray())))
        assertTrue(eventually { t.live().second == 3 })
        Thread.sleep(400)
        assertEquals(3, host.accepted.get()) // the cap holds: no fourth connection while three are paired
        assertEquals(3, t.live().first + t.live().second + t.live().third)
    }

    @Test fun aRejectingHostBacksOffAndANewHostAnswerRecoversThePool() {
        val host = TestHost(); host.mode = Mode.REJECT
        val logs = CopyOnWriteArrayList<String>()
        val t = tunnel(host, null, pool = 2, logs = logs)
        Thread.sleep(1_500)
        // 250 ms, 500, 1000 ... between rounds of failures: a handful of attempts, not a flood
        assertTrue("attempts=${host.accepted.get()}", host.accepted.get() in 2..12)
        assertFalse(t.isClosed)
        assertTrue(t.counters().rejected >= 2)
        assertTrue(logs.any { it.startsWith("files_conn_failed") && it.contains("reason=rejected") })
        host.mode = Mode.OK
        assertTrue(host.awaitProven(2, 10_000))
        assertTrue(eventually { t.live().first == 2 })
    }

    @Test fun aHostThatNeverAnswersIsGivenUpOnAtTheDeadline() {
        val host = TestHost(); host.mode = Mode.SILENT
        val logs = CopyOnWriteArrayList<String>()
        tunnel(host, null, pool = 1, ackMs = 200, logs = logs)
        assertTrue(eventually { logs.any { it.contains("reason=ack_timeout") } })
    }

    @Test fun aHostThatClosesAtOnceIsRetriedWithBackoffNotInAHotLoop() {
        val host = TestHost(); host.mode = Mode.CLOSE_AT_ONCE
        val t = tunnel(host, null, pool = 1)
        Thread.sleep(1_200)
        assertTrue("attempts=${host.accepted.get()}", host.accepted.get() in 2..8)
        assertFalse(t.isClosed)
    }

    @Test fun anIdleConnectionSendsKeepalivePingsAndPairedOnesDoNot() {
        val host = TestHost(); val dav = TestDav()
        tunnel(host, dav, pool = 1, pingMs = 100)
        assertTrue(host.awaitProven(1))
        val c = host.conns[0]
        assertTrue(eventually { c.pings.get() >= 4 }) // the proof plus a PING every 100 ms
        c.send(FilesData(Bytes("x".toByteArray())))
        assertTrue(eventually { c.data().size == 1 })
        Thread.sleep(150) // let any in-flight idle ping land
        val before = c.pings.get()
        Thread.sleep(450)
        assertEquals(before, c.pings.get())
    }

    @Test fun theIdleHeartbeatIsADeadlineNotAReadTimeoutSoInboundTrafficCannotPostponeIt() {
        val host = TestHost(); val dav = TestDav()
        tunnel(host, dav, pool = 1, pingMs = 150)
        assertTrue(host.awaitProven(1))
        val c = host.conns[0]
        // the Mac chatters every 20 ms (its own keepalives): a read timeout would never fire
        val chatter = Thread {
            var i = 0L
            try { while (!c.eof) { c.send(Ping(i++, 0)); Thread.sleep(20) } } catch (_: Exception) {}
        }.also { it.isDaemon = true; it.start() }
        assertTrue("pings=${c.pings.get()}", eventually(3_000) { c.pings.get() >= 5 }) // proof + one per ~150 ms of ITS clock
        chatter.interrupt()
    }

    @Test fun aRecordFromTheWrongKeyClosesThatConnectionOnly() {
        val host = TestHost(); val dav = TestDav()
        val t = tunnel(host, dav, pool = 2)
        assertTrue(host.awaitProven(2))
        val bad = host.conns[0]
        // sealed with another connection's key: the tag does not verify
        bad.sendRaw(RecordSealer(ByteArray(32) { 1 }).seal(MsgType.FILES_DATA, byteArrayOf(1, 0, 65)))
        assertTrue(eventually { bad.eof })
        assertEquals(0, dav.accepted.get()) // never reached the tablet's server
        assertTrue(eventually { t.live().first == 2 }) // replaced; the other connection lived on
        assertFalse(t.isClosed)
        assertTrue(host.conns[1].let { !it.eof })
    }

    @Test fun aKnownNonFileMessageIsAProtocolErrorButAnUnknownTypeIsSkipped() {
        val host = TestHost(); val dav = TestDav()
        val t = tunnel(host, dav, pool = 1)
        assertTrue(host.awaitProven(1))
        val c = host.conns[0]
        c.sendRaw(c.sealer.seal(0x7E, byteArrayOf(1, 2, 3))) // unknown type: skipped, the connection stays
        c.send(FilesData(Bytes("ok".toByteArray())))
        assertTrue(eventually { String(c.data()) == "ok" })
        assertFalse(c.eof)
        // a STREAM_CONFIG (known, but not a file connection message) is a protocol error: that connection closes
        c.send(StreamConfig(1, 1, 2800, 1840, 1400, 920, 60, 20000, 1, 1, 1, 1))
        assertTrue(eventually { c.eof })
        assertTrue(eventually { t.counters().proven >= 2 }) // a replacement came up
        assertFalse(t.isClosed)
    }

    @Test fun anEmptyOrOversizeFilesDataFromTheMacIsAProtocolError() {
        val host = TestHost(); val dav = TestDav()
        tunnel(host, dav, pool = 1)
        assertTrue(host.awaitProven(1))
        val c = host.conns[0]
        c.sendRaw(c.sealer.seal(MsgType.FILES_DATA, byteArrayOf(0, 0))) // size 0
        assertTrue(eventually { c.eof })
        assertEquals(0, dav.accepted.get())
    }

    @Test fun ifTheTabletsServerIsGoneThePairedConnectionClosesAndThePoolSurvives() {
        val host = TestHost()
        val dav = TestDav()
        val port = dav.port
        dav.close() // nothing listens on the tablet's server port any more
        val plan = FilesTunnelPlan(7, "127.0.0.1", host.port, 1, 12, port, 5)
        val t = FilesTunnel(plan, secrets, davScope = { davScopeNow }).also { toClose += AutoCloseable { it.close() }; it.start() }
        assertTrue(host.awaitProven(1))
        val c = host.conns[0]
        c.send(FilesData(Bytes("GET / HTTP/1.1\r\n\r\n".toByteArray())))
        assertTrue(eventually { c.eof })
        assertTrue(host.awaitProven(2)) // the pool re-opened
        assertFalse(t.isClosed)
    }

    @Test fun closeEndsEveryFileConnectionAndTheLocalOnesAndIsIdempotent() {
        val host = TestHost(); val dav = TestDav()
        val logs = CopyOnWriteArrayList<String>()
        val t = tunnel(host, dav, pool = 2, logs = logs)
        assertTrue(host.awaitProven(2))
        host.conns[0].send(FilesData(Bytes("hi".toByteArray())))
        assertTrue(eventually { dav.accepted.get() == 1 && host.conns[0].data().size == 2 })
        assertTrue(host.awaitProven(3))
        t.close("test")
        t.close("again")
        assertTrue(t.isClosed)
        assertTrue(eventually { host.conns.all { it.eof } })
        assertTrue(eventually { dav.eofSeen == 1 })
        val accepted = host.accepted.get()
        Thread.sleep(300)
        assertEquals(accepted, host.accepted.get()) // nothing is opened after close
        assertEquals(1, logs.count { it.startsWith("files_tunnel_close") })
    }

    @Test fun wipedSessionSecretsEndTheTunnel() {
        val host = TestHost()
        val own = SessionSecrets(prk.copyOf(), pairing = false, hostId = ByteArray(16))
        val t = tunnel(host, null, pool = 1, secrets = own)
        assertTrue(host.awaitProven(1))
        own.wipe()
        // the next connection that needs keys finds them gone: the whole tunnel closes (the session is over)
        host.conns[0].close()
        assertTrue(eventually { t.isClosed })
    }

    @Test fun logLinesCarryCountersAndNeverPayloadOrAddresses() {
        val host = TestHost(); val dav = TestDav()
        val logs = CopyOnWriteArrayList<String>()
        val t = tunnel(host, dav, pool = 1, logs = logs)
        assertTrue(host.awaitProven(1))
        host.conns[0].send(FilesData(Bytes("Authorization: Digest secret-token-value".toByteArray())))
        assertTrue(eventually { host.conns[0].data().isNotEmpty() })
        host.conns[0].close()
        assertTrue(eventually { logs.any { it.startsWith("files_conn_closed") } })
        t.close()
        for (line in logs) {
            assertFalse(line, line.contains("secret-token-value") || line.contains("Authorization"))
            assertFalse(line, line.contains("127.0.0.1"))
        }
        assertNull(logs.firstOrNull { it.contains("path=") })
    }

    @Test fun theTunnelNeverPairsWithAServerThatIsNotTheWifiServerOfItsGeneration() {
        for (bad in listOf(FilesServerScope(false, 7), FilesServerScope(true, 6), FilesServerScope.NONE)) {
            davScopeNow = bad // a USB-scope server (possibly the whole storage), an earlier session's, or none
            val host = TestHost(); val dav = TestDav()
            val logs = CopyOnWriteArrayList<String>()
            val t = tunnel(host, dav, pool = 1, logs = logs)
            assertTrue(host.awaitProven(1))
            val c = host.conns[0]
            c.send(FilesData(Bytes("GET /secret HTTP/1.1\r\n\r\n".toByteArray())))
            assertTrue("$bad: connection must end", eventually { c.eof })
            assertEquals("$bad: the server is never touched", 0, dav.accepted.get())
            assertEquals(0L, t.counters().paired)
            assertTrue(logs.any { it.contains("reason=scope_mismatch") })
            t.close()
        }
        // the right scope pairs as usual
        davScopeNow = FilesServerScope(true, 7)
        val host = TestHost(); val dav = TestDav()
        tunnel(host, dav, pool = 1)
        assertTrue(host.awaitProven(1))
        host.conns[0].send(FilesData(Bytes("ok".toByteArray())))
        assertTrue(eventually { String(host.conns[0].data()) == "ok" })
    }

    @Test fun aMacThatStopsReadingCannotHoldASlotForEver() {
        // The Mac keeps the TCP connection open but never drains it; the tablet's server has a lot to say. The pump blocks
        // in write(): the write watchdog closes BOTH sockets, the slot frees and the pool replaces the connection.
        val host = TestHost(); val dav = TestDav(echo = false, answer = http(40_000_000))
        val logs = CopyOnWriteArrayList<String>()
        val t = tunnel(host, dav, pool = 1, max = 2, writeMs = 300, logs = logs)
        assertTrue(host.awaitProven(1))
        val c = host.conns[0]
        c.paused = true
        c.send(FilesData(Bytes("GET /big HTTP/1.1\r\n\r\n".toByteArray())))
        assertTrue("write stall never fired", eventually(10_000) { t.writeStalls() >= 1 })
        assertTrue(eventually { t.live().second == 0 })
        assertTrue(eventually { logs.any { it.startsWith("files_conn_closed") && it.contains("reason=write_stall") } })
        assertTrue(host.awaitProven(2)) // the pool opened a replacement
        assertFalse(t.isClosed)
        assertTrue(eventually { dav.eofSeen >= 1 || dav.socks.all { it.isClosed } }) // the local socket was closed too
    }

    @Test fun aLocalServerThatStopsReadingIsDroppedTheSameWay() {
        val host = TestHost(); val dav = TestDav(echo = false, answer = null).also { }
        val t = tunnel(host, dav, pool = 1, writeMs = 300)
        assertTrue(host.awaitProven(1))
        // the "server" never reads: it only accepts. The Mac sends more than the buffers hold.
        dav.stopReading = true
        val c = host.conns[0]
        var sent = 0
        val chunk = Bytes(http(16 * 1024))
        val sender = Thread {
            try { while (sent < 200) { c.send(FilesData(chunk)); sent++ } } catch (_: IOException) {}
        }.also { it.isDaemon = true; it.start() }
        assertTrue(eventually(10_000) { t.writeStalls() >= 1 })
        assertTrue(eventually { t.live().second == 0 })
        sender.interrupt()
    }

    // ---- pure pieces ----

    @Test fun plannerKeepsThePoolFilledWithinMaxAndAtMostTwoHandshakes() {
        val p = PoolPlanner(pool = 2, max = 12)
        assertEquals(2, p.toOpen())
        p.opening = 2
        assertEquals(0, p.toOpen())
        p.opening = 0; p.idle = 2
        assertEquals(0, p.toOpen())
        p.idle = 1; p.paired = 3
        assertEquals(1, p.toOpen())
        p.idle = 0; p.paired = 11
        assertEquals(1, p.toOpen()) // total 11 of 12: one more
        p.paired = 12
        assertEquals(0, p.toOpen()) // at max
        val big = PoolPlanner(pool = 4, max = 16)
        assertEquals(2, big.toOpen()) // never more than two unproven at once
        big.opening = 1
        assertEquals(1, big.toOpen())
    }

    @Test fun backoffDoublesFromQuarterSecondToFiveSeconds() {
        assertEquals(0L, FilesTunnel.backoffMs(0))
        assertEquals(listOf(250L, 500L, 1000L, 2000L, 4000L, 5000L, 5000L), (1..7).map { FilesTunnel.backoffMs(it) })
    }

    @Test fun filesChannelOfTheTabletSealsWhatTheMacOpens() {
        val keys = secrets.filesKeys(ByteArray(16) { 1 }, ByteArray(16) { 2 })
        val hostSide = secrets.filesKeys(ByteArray(16) { 1 }, ByteArray(16) { 2 })
        val tablet = FilesChannel(keys)
        val rec = tablet.sealer.sealFrame(Codec.encode(FilesData(Bytes(byteArrayOf(9, 8, 7)))))
        val dec = RecordDecoder(Limits.CONTROL_MAX_PAYLOAD, RecordOpener(hostSide.c2h))
        dec.feed(rec)
        assertEquals(FilesData(Bytes(byteArrayOf(9, 8, 7))), dec.next())
    }
}
