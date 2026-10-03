package dev.matebridge.client.files

import java.io.BufferedInputStream
import java.io.File
import java.io.InputStream
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
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

/**
 * T-190 (decision 0028): the server on a chosen folder of the shared storage (`MateBridge/`), end to end over
 * 127.0.0.1. Nothing outside that folder is reachable, and read-only mode refuses every write.
 */
class DavScopeTest {
    @get:Rule val tmp = TemporaryFolder()

    private val token = "0123456789abcdef0123456789abcdef"
    private lateinit var storage: File
    private lateinit var root: File
    private var server: DavServer? = null
    private var stopped = CountDownLatch(1)
    private var port = 0
    private val logs = ArrayList<String>()

    private val cfg = FilesConfig(preferredPort = 0, rateBytesPerSec = 200_000_000, idleTimeoutMs = 5000, readTimeoutMs = 5000)

    /** storage/{top.txt, DCIM/photo.jpg, MateBridge/{a.txt, Notlar/n.txt, kamera -> ../DCIM}}; serves MateBridge/. */
    private fun setUpStorage(readOnly: Boolean) {
        storage = tmp.newFolder("storage").canonicalFile
        File(storage, "top.txt").writeText("top secret")
        File(storage, "DCIM").mkdir()
        File(storage, "DCIM/photo.jpg").writeText("photo")
        root = FilesScope(FilesRoot.MATEBRIDGE, readOnly).directory(storage)!!
        File(root, "a.txt").writeText("hello")
        File(root, "Notlar").mkdir()
        File(root, "Notlar/n.txt").writeText("note")
        // A link inside the root that points to a sibling folder of the root.
        Files.createSymbolicLink(File(root, "kamera").toPath(), File(storage, "DCIM").toPath())
        start(cfg.copy(readOnly = readOnly))
    }

    private fun start(c: FilesConfig) {
        val listening = CountDownLatch(1)
        val st = CountDownLatch(1)
        stopped = st
        // DavServer canonicalizes the root, as in FilesController.
        server = DavServer(root, token, ByteArray(32) { 3 }, c, object : DavServer.Hooks {
            override fun log(ev: String, fields: String) { synchronized(logs) { logs += "ev=$ev $fields" } }
            override fun onListening(port: Int) { this@DavScopeTest.port = port; listening.countDown() }
            override fun onStopped(failed: Boolean) = st.countDown()
        }).also { it.start() }
        assertTrue(listening.await(10, TimeUnit.SECONDS))
    }

    @After fun tearDown() {
        server?.stop()
        if (server != null) assertTrue(stopped.await(5, TimeUnit.SECONDS))
        synchronized(logs) {
            for (l in logs) {
                for (secret in listOf(token, "MateBridge", "a.txt", "DCIM", "photo", "kamera", "Notlar")) {
                    assertFalse("logged: $l", l.contains(secret))
                }
            }
        }
    }

    // ---- a minimal HTTP/1.1 client: one request per connection ----

    private class Response(val status: Int, val headers: Map<String, String>, val body: ByteArray) {
        fun header(n: String) = headers[n.lowercase()]
        val text get() = body.toString(Charsets.UTF_8)
    }

    private fun call(method: String, target: String, headers: List<Pair<String, String>> = emptyList(), body: ByteArray? = null): Response {
        Socket(InetAddress.getByAddress(byteArrayOf(127, 0, 0, 1)), port).use { s ->
            s.soTimeout = 5000
            val auth = "Basic " + Base64.getEncoder().encodeToString("matebridge:$token".toByteArray())
            val sb = StringBuilder("$method $target HTTP/1.1\r\nHost: localhost:$port\r\nAuthorization: $auth\r\nConnection: close\r\n")
            for ((k, v) in headers) sb.append("$k: $v\r\n")
            if (body != null) sb.append("Content-Length: ${body.size}\r\n")
            sb.append("\r\n")
            val out = s.getOutputStream()
            out.write(sb.toString().toByteArray(Charsets.ISO_8859_1))
            if (body != null) out.write(body)
            out.flush()
            return read(BufferedInputStream(s.getInputStream()), method == "HEAD")
        }
    }

    private fun line(input: InputStream): String {
        val sb = StringBuilder()
        while (true) {
            val c = input.read()
            require(c >= 0) { "eof" }
            if (c == '\n'.code) return sb.toString().trimEnd('\r')
            sb.append(c.toChar())
        }
    }

    private fun read(input: InputStream, head: Boolean): Response {
        val status = line(input).split(' ')[1].toInt()
        val headers = HashMap<String, String>()
        while (true) {
            val l = line(input)
            if (l.isEmpty()) break
            headers[l.substringBefore(':').trim().lowercase()] = l.substringAfter(':').trim()
        }
        val body = when {
            head -> ByteArray(0)
            headers["transfer-encoding"]?.contains("chunked") == true -> BodyInputStream(input, -1).readBytes()
            headers["content-length"] != null -> {
                val n = headers["content-length"]!!.toInt()
                ByteArray(n).also { var o = 0; while (o < n) { val r = input.read(it, o, n - o); require(r > 0); o += r } }
            }
            else -> ByteArray(0)
        }
        return Response(status, headers, body)
    }

    /** Every entry under the storage (links not followed) with its bytes; a read-only server must leave it identical. */
    private fun snapshot(): Map<String, String> {
        val out = sortedMapOf<String, String>()
        fun walk(d: File, rel: String) {
            for (c in d.listFiles()!!.sortedBy { it.name }) {
                val r = "$rel/${c.name}"
                when {
                    Files.isSymbolicLink(c.toPath()) -> out[r] = "link"
                    c.isDirectory -> { out[r] = "dir"; walk(c, r) }
                    else -> out[r] = c.readText() + "@" + c.length()
                }
            }
        }
        walk(storage, "")
        return out
    }

    private val lockBody = ("<?xml version=\"1.0\"?><D:lockinfo xmlns:D=\"DAV:\"><D:lockscope><D:exclusive/></D:lockscope>" +
        "<D:locktype><D:write/></D:locktype><D:owner>me</D:owner></D:lockinfo>").toByteArray()

    // ---- chosen root ----

    @Test fun onlyTheChosenFolderIsListedAndServed() {
        setUpStorage(readOnly = false)
        val list = call("PROPFIND", "/MatePad/", listOf("Depth" to "1"))
        assertEquals(207, list.status)
        assertTrue(list.text.contains("<D:href>/MatePad/a.txt</D:href>"))
        assertTrue(list.text.contains("<D:href>/MatePad/Notlar/</D:href>"))
        for (outside in listOf("top.txt", "DCIM", "photo", "kamera", "MateBridge")) assertFalse(outside, list.text.contains(outside))
        val get = call("GET", "/MatePad/a.txt")
        assertEquals(200, get.status)
        assertEquals("hello", get.text)
        assertEquals("note", call("GET", "/MatePad/Notlar/n.txt").text)
        assertEquals(404, call("GET", "/MatePad/top.txt").status) // the storage root's file is not under the chosen folder
        assertEquals(404, call("GET", "/MatePad/DCIM/photo.jpg").status)
    }

    @Test fun escapesOutOfTheChosenFolderAreRefused() {
        setUpStorage(readOnly = false)
        val before = snapshot()
        // By name or encoding: refused while parsing, before any file is touched.
        for (t in listOf(
            "/MatePad/../top.txt", "/MatePad/%2e%2e/top.txt", "/MatePad/%2E%2E/DCIM/photo.jpg", "/MatePad/..%2Ftop.txt",
            "/MatePad/Notlar%2F..%2F..%2Ftop.txt", "/MatePad/a.txt%00", "/MatePad/%00", "/MatePad/%FF%FE", "/MatePad/%C3",
            "/MatePad/%zz",
        )) {
            assertEquals(t, 400, call("GET", t).status)
            assertEquals(t, 400, call("PUT", t, body = "x".toByteArray()).status)
        }
        // A link inside the root that points to a sibling folder.
        assertEquals(403, call("GET", "/MatePad/kamera/photo.jpg").status)
        assertEquals(403, call("PROPFIND", "/MatePad/kamera/", listOf("Depth" to "1")).status)
        assertEquals(403, call("PUT", "/MatePad/kamera/new.jpg", body = "x".toByteArray()).status)
        assertEquals(403, call("DELETE", "/MatePad/kamera/photo.jpg").status)
        assertEquals(403, call("MKCOL", "/MatePad/kamera/yeni").status)
        // A Destination outside the chosen folder: by name, by encoding, through the link, or outside /MatePad/.
        for (dest in listOf(
            "/MatePad/../top2.txt", "/MatePad/%2e%2e/DCIM/a.txt", "http://localhost:$port/MatePad/kamera/a.txt",
            "/MatePad/kamera/a.txt", "/DCIM/a.txt", "/top2.txt", "/MatePad/..%2Fx.txt", "/MatePad/%00",
        )) {
            assertEquals(dest, 403, call("MOVE", "/MatePad/a.txt", listOf("Destination" to dest)).status)
            assertEquals(dest, 403, call("COPY", "/MatePad/a.txt", listOf("Destination" to dest)).status)
        }
        assertEquals(before, snapshot())
        assertEquals("photo", File(storage, "DCIM/photo.jpg").readText())
        assertArrayEquals(arrayOf("photo.jpg"), File(storage, "DCIM").list()!!.sortedArray())
    }

    @Test fun readWriteModeStillWritesInsideTheFolder() {
        setUpStorage(readOnly = false)
        val opt = call("OPTIONS", "/MatePad/")
        assertEquals("1, 2", opt.header("DAV"))
        assertEquals(DavHandler.ALLOW, opt.header("Allow"))
        assertEquals(201, call("PUT", "/MatePad/yeni.txt", body = "y".toByteArray()).status)
        assertEquals("y", File(root, "yeni.txt").readText())
        assertNull(File(storage, "yeni.txt").takeIf { it.exists() })
    }

    // ---- read-only ----

    @Test fun readOnlyRefusesEveryWriteAndChangesNothing() {
        setUpStorage(readOnly = true)
        val before = snapshot()
        val dest = listOf("Destination" to "/MatePad/b.txt")
        for (name in listOf("a.txt", "new.txt", "Notlar/", "._a.txt", ".DS_Store", "Notlar/._n.txt")) {
            val t = "/MatePad/$name"
            assertEquals("PUT $t", 403, call("PUT", t, body = "x".toByteArray()).status)
            assertEquals("DELETE $t", 403, call("DELETE", t).status)
            assertEquals("MKCOL $t", 403, call("MKCOL", t).status)
            assertEquals("MOVE $t", 403, call("MOVE", t, dest).status)
            assertEquals("COPY $t", 403, call("COPY", t, dest).status)
            assertEquals("COPY meta $t", 403, call("COPY", t, listOf("Destination" to "/MatePad/._b.txt")).status)
            assertEquals("LOCK $t", 403, call("LOCK", t, listOf("Timeout" to "Second-600"), lockBody).status)
            assertEquals("LOCK refresh $t", 403, call("LOCK", t, listOf("If" to "(<opaquelocktoken:x>)")).status)
            assertEquals("UNLOCK $t", 403, call("UNLOCK", t, listOf("Lock-Token" to "<opaquelocktoken:x>")).status)
        }
        // The virtual root and the mount root as well.
        for (m in listOf("PUT", "DELETE", "MKCOL", "MOVE", "COPY", "LOCK", "UNLOCK")) {
            assertEquals("$m /", 403, call(m, "/", dest).status)
            assertEquals("$m /MatePad/", 403, call(m, "/MatePad/", dest).status)
        }
        assertEquals(before, snapshot())
        assertEquals(404, call("GET", "/MatePad/._a.txt").status) // no metadata was stored either
        assertEquals(404, call("GET", "/MatePad/.DS_Store").status)
    }

    @Test fun readOnlyStillReadsAndAdvertisesClassOneOnly() {
        setUpStorage(readOnly = true)
        val opt = call("OPTIONS", "/MatePad/")
        assertEquals(200, opt.status)
        assertEquals("1", opt.header("DAV")) // no class 2: macOS webdavfs mounts read-only
        assertEquals("OPTIONS, PROPFIND, GET, HEAD", opt.header("Allow"))
        assertEquals("1", call("OPTIONS", "/").header("DAV"))
        assertEquals(207, call("PROPFIND", "/", listOf("Depth" to "1")).status)
        val list = call("PROPFIND", "/MatePad/", listOf("Depth" to "1"))
        assertEquals(207, list.status)
        assertTrue(list.text.contains("<D:href>/MatePad/a.txt</D:href>"))
        assertEquals("hello", call("GET", "/MatePad/a.txt").text)
        val range = call("GET", "/MatePad/a.txt", listOf("Range" to "bytes=1-2"))
        assertEquals(206, range.status)
        assertEquals("el", range.text)
        val head = call("HEAD", "/MatePad/a.txt")
        assertEquals(200, head.status)
        assertEquals("5", head.header("Content-Length"))
        val dir = call("GET", "/MatePad/Notlar/")
        assertEquals(405, dir.status)
        assertEquals("OPTIONS, PROPFIND, GET, HEAD", dir.header("Allow"))
        // Escapes are still refused in read-only mode.
        assertEquals(403, call("GET", "/MatePad/kamera/photo.jpg").status)
        assertEquals(400, call("GET", "/MatePad/%2e%2e/top.txt").status)
    }
}
