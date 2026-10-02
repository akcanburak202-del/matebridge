package dev.matebridge.client.files

import java.io.BufferedInputStream
import java.io.File
import java.io.InputStream
import java.io.OutputStream
import java.net.InetAddress
import java.net.Socket
import java.nio.file.Files
import java.util.Base64
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

/** T-135: the WebDAV server end to end over a real 127.0.0.1 socket, on a temporary root. */
class DavServerTest {
    @get:Rule val tmp = TemporaryFolder()

    private val token = "0123456789abcdef0123456789abcdef"
    private lateinit var root: File
    private lateinit var server: DavServer
    private val logs = ArrayList<String>()
    private val stopped = CountDownLatch(1)
    private var port = 0

    @Before fun setUp() {
        root = tmp.newFolder("storage").canonicalFile
        val listening = CountDownLatch(1)
        // Port 0: never collide with a real server on the preferred port. A high rate keeps the tests fast.
        val cfg = FilesConfig(preferredPort = 0, rateBytesPerSec = 200_000_000, maxConnections = 2, idleTimeoutMs = 5000, readTimeoutMs = 5000)
        server = DavServer(root, token, ByteArray(32) { 7 }, cfg, object : DavServer.Hooks {
            override fun log(ev: String, fields: String) { synchronized(logs) { logs += "ev=$ev $fields" } }
            override fun onListening(port: Int) { this@DavServerTest.port = port; listening.countDown() }
            override fun onStopped(failed: Boolean) = stopped.countDown()
        })
        server.start()
        assertTrue(listening.await(5, TimeUnit.SECONDS))
    }

    @After fun tearDown() {
        server.stop()
        assertTrue(stopped.await(5, TimeUnit.SECONDS))
        synchronized(logs) {
            for (l in logs) assertFalse("token logged: $l", l.contains(token))
        }
    }

    // ---- a tiny HTTP/1.1 client ----

    private class Response(val status: Int, val headers: Map<String, String>, val body: ByteArray) {
        fun header(n: String) = headers[n.lowercase()]
        val text get() = body.toString(Charsets.UTF_8)
    }

    private fun basic() = "Basic " + Base64.getEncoder().encodeToString("matebridge:$token".toByteArray())

    private fun call(
        method: String, target: String, headers: List<Pair<String, String>> = emptyList(), body: ByteArray? = null,
        auth: Boolean = true, chunked: Boolean = false,
    ): Response = RawClient().use { it.send(method, target, headers, body, auth, chunked) }

    /** Client with a hand-written response parser (status line differs from a request line). */
    private inner class RawClient : AutoCloseable {
        val socket = Socket(InetAddress.getByAddress(byteArrayOf(127, 0, 0, 1)), port).also { it.soTimeout = 5000 }
        val input = BufferedInputStream(socket.getInputStream())
        val output: OutputStream = socket.getOutputStream()

        fun send(
            method: String, target: String, headers: List<Pair<String, String>> = emptyList(), body: ByteArray? = null,
            auth: Boolean = true, chunked: Boolean = false, authHeader: String? = null,
        ): Response {
            val sb = StringBuilder("$method $target HTTP/1.1\r\nHost: localhost:$port\r\n")
            if (authHeader != null) sb.append("Authorization: ").append(authHeader).append("\r\n")
            else if (auth) sb.append("Authorization: ").append(basic()).append("\r\n")
            for ((k, v) in headers) sb.append("$k: $v\r\n")
            if (body != null && !chunked) sb.append("Content-Length: ${body.size}\r\n")
            if (chunked) sb.append("Transfer-Encoding: chunked\r\n")
            sb.append("\r\n")
            output.write(sb.toString().toByteArray(Charsets.ISO_8859_1))
            if (body != null) {
                if (chunked) {
                    var i = 0
                    while (i < body.size) {
                        val n = minOf(1000, body.size - i)
                        output.write("${Integer.toHexString(n)}\r\n".toByteArray())
                        output.write(body, i, n)
                        output.write("\r\n".toByteArray())
                        i += n
                    }
                    output.write("0\r\n\r\n".toByteArray())
                } else {
                    output.write(body)
                }
            }
            output.flush()
            return readResponse(input, method == "HEAD")
        }

        override fun close() = socket.close()
    }

    private fun readLine(input: InputStream): String {
        val sb = StringBuilder()
        while (true) {
            val c = input.read()
            require(c >= 0) { "eof" }
            if (c == '\n'.code) return sb.toString().trimEnd('\r')
            sb.append(c.toChar())
        }
    }

    private fun readResponse(input: InputStream, noBody: Boolean): Response {
        var status: Int
        var headers: MutableMap<String, String>
        while (true) {
            status = readLine(input).split(' ')[1].toInt()
            headers = HashMap()
            while (true) {
                val l = readLine(input)
                if (l.isEmpty()) break
                headers[l.substringBefore(':').trim().lowercase()] = l.substringAfter(':').trim()
            }
            if (status != 100) break
        }
        val body = when {
            noBody -> ByteArray(0)
            headers["transfer-encoding"]?.contains("chunked") == true -> BodyInputStream(input, -1).readBytes()
            headers["content-length"] != null -> {
                val n = headers["content-length"]!!.toInt()
                ByteArray(n).also { var o = 0; while (o < n) { val r = input.read(it, o, n - o); require(r > 0); o += r } }
            }
            else -> ByteArray(0)
        }
        return Response(status, headers, body)
    }

    // ---- tests ----

    @Test fun everyRequestNeedsAuthAndTheChallengeIsDigest() {
        for (m in listOf("OPTIONS", "PROPFIND", "GET", "PUT", "DELETE")) {
            val r = call(m, "/MatePad/", listOf("Depth" to "0"), auth = false)
            assertEquals(m, 401, r.status)
            assertTrue(r.header("WWW-Authenticate")!!.startsWith("Digest realm=\"MateBridge\", qop=\"auth\""))
        }
        val wrong = RawClient().use {
            it.send("PROPFIND", "/MatePad/", listOf("Depth" to "0"), authHeader = "Basic " + Base64.getEncoder().encodeToString("matebridge:x".toByteArray()))
        }
        assertEquals(401, wrong.status)
    }

    @Test fun digestHandshakeLikeFinder() {
        RawClient().use { c ->
            val challenge = c.send("PROPFIND", "/MatePad/", listOf("Depth" to "0"), auth = false)
            assertEquals(401, challenge.status)
            val params = DigestAuth.parseParams(challenge.header("WWW-Authenticate")!!.removePrefix("Digest "))!!
            val nonce = params["nonce"]!!
            val resp = DigestAuth.response(FilesConfig.USER, params["realm"]!!, token, "PROPFIND", "/MatePad/", nonce, "00000001", "c1", "auth")
            val h = "Digest username=\"matebridge\", realm=\"MateBridge\", nonce=\"$nonce\", uri=\"/MatePad/\", " +
                "response=\"$resp\", qop=auth, nc=00000001, cnonce=\"c1\""
            // Same connection: the 401 kept it alive.
            assertEquals(207, c.send("PROPFIND", "/MatePad/", listOf("Depth" to "0"), authHeader = h).status)
        }
    }

    @Test fun optionsAdvertisesDavClass2() {
        val r = call("OPTIONS", "/")
        assertEquals(200, r.status)
        assertEquals("1, 2", r.header("DAV"))
        assertTrue(r.header("Allow")!!.contains("LOCK"))
    }

    @Test fun rootListsOnlyMatePad() {
        File(root, "Download").mkdir()
        val r = call("PROPFIND", "/", listOf("Depth" to "1"))
        assertEquals(207, r.status)
        assertTrue(r.text.contains("<D:href>/</D:href>"))
        assertTrue(r.text.contains("<D:href>/MatePad/</D:href>"))
        assertFalse(r.text.contains("Download"))
        assertEquals(405, call("DELETE", "/").status) // the virtual root is read-only
        assertEquals(404, call("PUT", "/x.txt", body = ByteArray(1)).status) // nothing exists outside /MatePad/
        assertEquals(404, call("GET", "/Download/").status)
        assertEquals(404, call("PROPFIND", "/Other/", listOf("Depth" to "0")).status)
    }

    @Test fun propfindDepth1ListsTurkishNames() {
        File(root, "Çizimler").mkdir()
        File(root, "ödev ğüş.txt").writeText("merhaba")
        File(root, DavHandler.TEMP_PREFIX + "abc" + DavHandler.TEMP_SUFFIX).writeText("half upload")
        val r = call("PROPFIND", "/MatePad/", listOf("Depth" to "1", "Content-Type" to "application/xml"), "<?xml version=\"1.0\"?><propfind xmlns=\"DAV:\"><allprop/></propfind>".toByteArray())
        assertEquals(207, r.status)
        assertEquals("chunked", r.header("Transfer-Encoding"))
        val xml = r.text
        assertTrue(xml.contains("<D:href>/MatePad/</D:href>"))
        assertTrue(xml.contains("<D:href>/MatePad/%C3%87izimler/</D:href>"))
        assertTrue(xml.contains("<D:displayname>ödev ğüş.txt</D:displayname>"))
        assertTrue(xml.contains("<D:getcontentlength>7</D:getcontentlength>"))
        assertFalse(xml.contains(DavHandler.TEMP_PREFIX)) // temporary upload files are hidden
        assertTrue(xml.contains("quota-available-bytes"))
        assertEquals(403, call("PROPFIND", "/MatePad/", listOf("Depth" to "infinity")).status)
        assertEquals(403, call("PROPFIND", "/MatePad/").status) // no Depth means infinity
        assertEquals(404, call("PROPFIND", "/MatePad/nope", listOf("Depth" to "0")).status)
    }

    @Test fun getWithRangeAndHead() {
        val data = ByteArray(300_000) { (it * 31).toByte() }
        File(root, "big.bin").writeBytes(data)
        val full = call("GET", "/MatePad/big.bin")
        assertEquals(200, full.status)
        assertArrayEquals(data, full.body)
        assertEquals("bytes", full.header("Accept-Ranges"))
        val part = call("GET", "/MatePad/big.bin", listOf("Range" to "bytes=1000-1999"))
        assertEquals(206, part.status)
        assertEquals("bytes 1000-1999/300000", part.header("Content-Range"))
        assertArrayEquals(data.copyOfRange(1000, 2000), part.body)
        assertEquals(416, call("GET", "/MatePad/big.bin", listOf("Range" to "bytes=999999-")).status)
        val head = call("HEAD", "/MatePad/big.bin")
        assertEquals(200, head.status)
        assertEquals("300000", head.header("Content-Length"))
        assertEquals(0, head.body.size)
        // If-Range with a stale validator gives the whole file.
        assertEquals(200, call("GET", "/MatePad/big.bin", listOf("Range" to "bytes=0-1", "If-Range" to "\"old\"")).status)
    }

    @Test fun putChunkedThenReadBackAndOverwrite() {
        val data = ByteArray(150_000) { (it % 251).toByte() }
        val name = "/MatePad/" + DavPath.encodeSegment("çizim 1.png")
        val put = call("PUT", name, listOf("Expect" to "100-continue"), data, chunked = true)
        assertEquals(201, put.status)
        assertArrayEquals(data, File(root, "çizim 1.png").readBytes())
        assertEquals(204, call("PUT", name, body = "x".toByteArray()).status)
        assertEquals("x", File(root, "çizim 1.png").readText())
        assertTrue(root.list()!!.none { DavHandler.isTempName(it) })
        assertEquals(409, call("PUT", "/MatePad/missing/dir/a.txt", body = ByteArray(1)).status)
        assertEquals(405, call("PUT", "/MatePad/", body = ByteArray(1)).status)
    }

    @Test fun abortedUploadLeavesNothingBehind() {
        val c = RawClient()
        c.output.write("PUT /MatePad/half.bin HTTP/1.1\r\nHost: x\r\nAuthorization: ${basic()}\r\nContent-Length: 1000000\r\n\r\n".toByteArray())
        c.output.write(ByteArray(10_000))
        c.output.flush()
        Thread.sleep(200)
        c.close()
        val deadline = System.currentTimeMillis() + 5000
        while (System.currentTimeMillis() < deadline && root.list()!!.isNotEmpty()) Thread.sleep(20)
        assertEquals(emptyList<String>(), root.list()!!.toList())
    }

    @Test fun mkcolMoveCopyDelete() {
        assertEquals(201, call("MKCOL", "/MatePad/Yeni%20Klas%C3%B6r").status)
        assertTrue(File(root, "Yeni Klasör").isDirectory)
        assertEquals(405, call("MKCOL", "/MatePad/Yeni%20Klas%C3%B6r").status)
        assertEquals(409, call("MKCOL", "/MatePad/a/b").status)
        File(root, "Yeni Klasör/a.txt").writeText("A")

        val dest = "http://localhost:$port/MatePad/" + DavPath.encodeSegment("Kopya")
        assertEquals(201, call("COPY", "/MatePad/Yeni%20Klas%C3%B6r/", listOf("Destination" to dest)).status)
        assertEquals("A", File(root, "Kopya/a.txt").readText())
        assertEquals(412, call("COPY", "/MatePad/Yeni%20Klas%C3%B6r/", listOf("Destination" to dest, "Overwrite" to "F")).status)
        assertEquals(204, call("COPY", "/MatePad/Yeni%20Klas%C3%B6r/", listOf("Destination" to dest)).status)

        assertEquals(201, call("MOVE", "/MatePad/Kopya/a.txt", listOf("Destination" to "/MatePad/b.txt")).status)
        assertFalse(File(root, "Kopya/a.txt").exists())
        assertEquals("A", File(root, "b.txt").readText())
        // Into itself, onto the storage root, or outside /MatePad/: refused.
        assertEquals(409, call("MOVE", "/MatePad/Kopya/", listOf("Destination" to "/MatePad/Kopya/inner")).status)
        assertEquals(403, call("MOVE", "/MatePad/b.txt", listOf("Destination" to "/MatePad/")).status)
        assertEquals(403, call("MOVE", "/MatePad/b.txt", listOf("Destination" to "/elsewhere/b.txt")).status)
        assertEquals(403, call("MOVE", "/MatePad/b.txt", listOf("Destination" to "/MatePad/../b.txt")).status)

        assertEquals(204, call("DELETE", "/MatePad/Kopya/").status)
        assertFalse(File(root, "Kopya").exists())
        assertEquals(404, call("DELETE", "/MatePad/Kopya/").status)
        assertEquals(403, call("DELETE", "/MatePad/").status)
        assertTrue(root.isDirectory)
    }

    @Test fun lockCreatesAndRefreshesAndUnlock() {
        val lockBody = "<?xml version=\"1.0\"?><D:lockinfo xmlns:D=\"DAV:\"><D:lockscope><D:exclusive/></D:lockscope>" +
            "<D:locktype><D:write/></D:locktype><D:owner>me</D:owner></D:lockinfo>"
        val r = call("LOCK", "/MatePad/new.txt", listOf("Timeout" to "Second-600", "Depth" to "0"), lockBody.toByteArray())
        assertEquals(201, r.status)
        assertTrue(File(root, "new.txt").exists())
        val token = r.header("Lock-Token")!!.removePrefix("<").removeSuffix(">")
        assertTrue(token.startsWith("opaquelocktoken:"))
        assertTrue(r.text.contains("<D:timeout>Second-600</D:timeout>"))
        val refresh = call("LOCK", "/MatePad/new.txt", listOf("If" to "(<$token>)"))
        assertEquals(200, refresh.status)
        assertTrue(refresh.text.contains(token))
        assertEquals(200, call("LOCK", "/MatePad/new.txt", body = lockBody.toByteArray()).status)
        assertEquals(204, call("UNLOCK", "/MatePad/new.txt", listOf("Lock-Token" to "<$token>")).status)
    }

    @Test fun traversalAndSymlinkEscapesAreRefused() {
        val outside = tmp.newFolder("outside")
        File(outside, "secret.txt").writeText("secret")
        Files.createSymbolicLink(File(root, "link").toPath(), outside.toPath())
        assertEquals(400, call("GET", "/MatePad/../outside/secret.txt").status)
        assertEquals(400, call("GET", "/MatePad/%2e%2e/outside/secret.txt").status)
        assertEquals(403, call("GET", "/MatePad/link/secret.txt").status)
        assertEquals(403, call("PUT", "/MatePad/link/new.txt", body = ByteArray(1)).status)
        assertFalse(File(outside, "new.txt").exists())
        val list = call("PROPFIND", "/MatePad/", listOf("Depth" to "1"))
        assertFalse(list.text.contains("/MatePad/link")) // a link leading out is not listed
    }

    @Test fun keepAliveCarriesSeveralRequestsAndIdleConnectionsAreEvicted() {
        File(root, "a.txt").writeText("a")
        val c1 = RawClient()
        assertEquals(200, c1.send("GET", "/MatePad/a.txt").status)
        assertEquals(200, c1.send("GET", "/MatePad/a.txt").status)
        val c2 = RawClient()
        assertEquals(200, c2.send("GET", "/MatePad/a.txt").status)
        // maxConnections = 2: a third client still gets served (an idle connection is closed for it).
        val r = call("GET", "/MatePad/a.txt")
        assertEquals(200, r.status)
        c1.close(); c2.close()
    }

    @Test fun stopClosesEverything() {
        val c = RawClient()
        File(root, "a.txt").writeText("a")
        assertEquals(200, c.send("GET", "/MatePad/a.txt").status)
        server.stop()
        assertTrue(stopped.await(5, TimeUnit.SECONDS))
        assertEquals(-1, c.input.read()) // the open keep-alive connection was closed
        c.close()
        try {
            Socket(InetAddress.getByAddress(byteArrayOf(127, 0, 0, 1)), port).close()
            throw AssertionError("still listening")
        } catch (e: java.net.ConnectException) {
        }
    }

    @Test fun statsAreLoggedWithoutNames() {
        File(root, "gizli-ad.txt").writeText("x".repeat(5000))
        assertEquals(200, call("GET", "/MatePad/gizli-ad.txt").status)
        val deadline = System.currentTimeMillis() + 3000
        while (System.currentTimeMillis() < deadline && synchronized(logs) { logs.none { it.startsWith("ev=stats") } }) Thread.sleep(20)
        val all = synchronized(logs) { logs.toList() }
        val stats = all.first { it.startsWith("ev=stats") }
        assertTrue(stats, stats.matches(Regex("ev=stats reqs=\\d+ bytes_out=\\d+ bytes_in=\\d+ throttled_ms=\\d+")))
        assertTrue(all.none { it.contains("gizli") })
    }
}
