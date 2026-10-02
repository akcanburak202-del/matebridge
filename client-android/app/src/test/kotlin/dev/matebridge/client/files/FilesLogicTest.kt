package dev.matebridge.client.files

import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.util.Base64
import java.util.Random
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** T-135: pure pieces of the WebDAV server. */
class FilesLogicTest {
    // ---- Range ----

    @Test fun rangeForms() {
        assertEquals(ByteRange.Full, ByteRange.parse(null, 100))
        assertEquals(ByteRange.Part(0, 9), ByteRange.parse("bytes=0-9", 100))
        assertEquals(ByteRange.Part(90, 99), ByteRange.parse("bytes=90-", 100))
        assertEquals(ByteRange.Part(90, 99), ByteRange.parse("bytes=-10", 100))
        assertEquals(ByteRange.Part(0, 99), ByteRange.parse("bytes=-1000", 100))
        assertEquals(ByteRange.Part(50, 99), ByteRange.parse("bytes=50-5000", 100))
        assertEquals(ByteRange.Part(50, 99), ByteRange.parse("bytes=50-99999999999999999999999", 100))
        assertEquals(10L, ByteRange.Part(0, 9).length)
        assertEquals("bytes 0-9/100", ByteRange.Part(0, 9).contentRange(100))
    }

    @Test fun rangeUnsatisfiableAndIgnored() {
        assertEquals(ByteRange.Unsatisfiable, ByteRange.parse("bytes=100-", 100))
        assertEquals(ByteRange.Unsatisfiable, ByteRange.parse("bytes=-0", 100))
        assertEquals(ByteRange.Unsatisfiable, ByteRange.parse("bytes=0-", 0))
        // Several ranges, other units and malformed specs are ignored: a full 200.
        for (h in listOf("bytes=0-1,5-6", "items=0-1", "bytes=5-1", "bytes=a-b", "bytes=-", "bytes=", "bytes 0-1")) {
            assertEquals(h, ByteRange.Full, ByteRange.parse(h, 100))
        }
    }

    // ---- XML ----

    @Test fun propfindXmlWithTurkishNames() {
        val xml = DavXml.multistatus(
            listOf(
                DavEntry("/MatePad/", "MatePad", true, 0, 0, Pair(1000L, 24L)),
                DavEntry(
                    "/MatePad/" + DavPath.encodeSegment("Çizim & <ödev>.png"), "Çizim & <ödev>.png", false, 1234,
                    1_790_000_000_000L,
                ),
            ),
        )
        assertTrue(xml.startsWith("<?xml version=\"1.0\" encoding=\"utf-8\"?>\n<D:multistatus xmlns:D=\"DAV:\">"))
        assertTrue(xml.contains("<D:href>/MatePad/%C3%87izim%20%26%20%3C%C3%B6dev%3E.png</D:href>"))
        assertTrue(xml.contains("<D:displayname>Çizim &amp; &lt;ödev&gt;.png</D:displayname>"))
        assertTrue(xml.contains("<D:resourcetype><D:collection/></D:resourcetype>"))
        assertTrue(xml.contains("<D:resourcetype/><D:getcontentlength>1234</D:getcontentlength><D:getcontenttype>image/png</D:getcontenttype>"))
        assertTrue(xml.contains("<D:getlastmodified>Mon, 21 Sep 2026 14:13:20 GMT</D:getlastmodified>"))
        assertTrue(xml.contains("<D:creationdate>2026-09-21T14:13:20Z</D:creationdate>"))
        assertTrue(xml.contains("<D:quota-available-bytes>1000</D:quota-available-bytes><D:quota-used-bytes>24</D:quota-used-bytes>"))
        assertTrue(xml.contains("<D:getetag>&quot;"))
        assertTrue(xml.contains("<D:supportedlock>"))
        assertEquals(2, Regex("<D:status>HTTP/1.1 200 OK</D:status>").findAll(xml).count())
        // Well-formed XML (the JDK parser is namespace aware).
        val f = javax.xml.parsers.DocumentBuilderFactory.newInstance().apply { isNamespaceAware = true }
        val doc = f.newDocumentBuilder().parse(ByteArrayInputStream(xml.toByteArray(Charsets.UTF_8)))
        assertEquals(2, doc.getElementsByTagNameNS("DAV:", "response").length)
        assertEquals("Çizim & <ödev>.png", doc.getElementsByTagNameNS("DAV:", "displayname").item(1).textContent)
    }

    @Test fun xmlEscapeReplacesCharactersXmlCannotCarry() {
        assertEquals("a�b�", DavXml.escape("a\u0001b\uD800"))
        assertEquals("😀 \t", DavXml.escape("😀 \t"))
        assertEquals("&amp;&lt;&gt;&quot;&apos;", DavXml.escape("&<>\"'"))
    }

    @Test fun contentTypes() {
        assertEquals("image/jpeg", DavXml.contentType("IMG_1.JPG"))
        assertEquals("application/pdf", DavXml.contentType("a.b.pdf"))
        assertEquals("application/octet-stream", DavXml.contentType("noext"))
        assertEquals("application/octet-stream", DavXml.contentType("x."))
    }

    @Test fun lockTimeout() {
        assertEquals(600L, DavHandler.parseTimeout("Second-600"))
        assertEquals(3600L, DavHandler.parseTimeout("Infinite, Second-99999"))
        assertEquals(3600L, DavHandler.parseTimeout(null))
        assertEquals(1L, DavHandler.parseTimeout("Second-0"))
    }

    // ---- Auth ----

    private val token = "0123456789abcdef0123456789abcdef"
    private var clock = 1_790_000_000_000L
    private val auth = DigestAuth(token, ByteArray(32) { it.toByte() }) { clock }

    private fun digest(
        nonce: String, uri: String = "/MatePad/", method: String = "PROPFIND", pass: String = token,
        user: String = FilesConfig.USER, realm: String = FilesConfig.REALM, nc: String = "00000001", cnonce: String = "abc",
    ): String {
        val r = DigestAuth.response(user, realm, pass, method, uri, nonce, nc, cnonce, "auth")
        return "Digest username=\"$user\", realm=\"$realm\", nonce=\"$nonce\", uri=\"$uri\", response=\"$r\", " +
            "qop=auth, nc=$nc, cnonce=\"$cnonce\", algorithm=MD5"
    }

    @Test fun digestRfc2617Vector() {
        // RFC 2617 section 3.5.
        assertEquals(
            "6629fae49393a05397450978507c4ef1",
            DigestAuth.response(
                "Mufasa", "testrealm@host.com", "Circle Of Life", "GET", "/dir/index.html",
                "dcd98b7102dd2f0e8b11d0f600bfb0c093", "00000001", "0a4f113b", "auth",
            ),
        )
    }

    @Test fun digestAcceptsOwnNonceAndCorrectPassword() {
        val nonce = auth.mintNonce()
        assertEquals(DigestAuth.Result.OK, auth.check("PROPFIND", "/MatePad/", digest(nonce)))
        // The uri may be spelled differently as long as it names the same path.
        assertEquals(DigestAuth.Result.OK, auth.check("PROPFIND", "/MatePad/%C3%A7", digest(nonce, uri = "/MatePad/%c3%a7")))
    }

    @Test fun digestRejectsWrongPasswordUserMethodUriOrForeignNonce() {
        val nonce = auth.mintNonce()
        assertEquals(DigestAuth.Result.BAD, auth.check("PROPFIND", "/MatePad/", digest(nonce, pass = "ffffffffffffffffffffffffffffffff")))
        assertEquals(DigestAuth.Result.BAD, auth.check("PROPFIND", "/MatePad/", digest(nonce, user = "admin")))
        assertEquals(DigestAuth.Result.BAD, auth.check("DELETE", "/MatePad/", digest(nonce)))
        assertEquals(DigestAuth.Result.BAD, auth.check("PROPFIND", "/MatePad/other", digest(nonce)))
        assertEquals(DigestAuth.Result.BAD, auth.check("PROPFIND", "/MatePad/", digest("dcd98b7102dd2f0e8b11d0f600bfb0c093")))
        val other = DigestAuth(token, ByteArray(32)) { clock }
        assertEquals(DigestAuth.Result.BAD, auth.check("PROPFIND", "/MatePad/", digest(other.mintNonce())))
        assertEquals(DigestAuth.Result.BAD, auth.check("PROPFIND", "/MatePad/", digest(nonce).replace("qop=auth", "qop=auth-int")))
        assertEquals(DigestAuth.Result.BAD, auth.check("PROPFIND", "/MatePad/", "Digest garbage"))
        assertEquals(DigestAuth.Result.MISSING, auth.check("PROPFIND", "/MatePad/", null))
        assertEquals(DigestAuth.Result.BAD, auth.check("PROPFIND", "/MatePad/", "Bearer x"))
    }

    @Test fun oldNonceIsStaleOnlyWithTheRightPassword() {
        val nonce = auth.mintNonce()
        clock += DigestAuth.NONCE_LIFETIME_MS + 1
        assertEquals(DigestAuth.Result.STALE, auth.check("PROPFIND", "/MatePad/", digest(nonce)))
        assertEquals(DigestAuth.Result.BAD, auth.check("PROPFIND", "/MatePad/", digest(nonce, pass = "wrong")))
        assertTrue(auth.challenge(stale = true).endsWith("stale=true"))
    }

    @Test fun basicIsAccepted() {
        fun basic(s: String) = "Basic " + Base64.getEncoder().encodeToString(s.toByteArray())
        assertEquals(DigestAuth.Result.OK, auth.check("GET", "/", basic("matebridge:$token")))
        assertEquals(DigestAuth.Result.BAD, auth.check("GET", "/", basic("matebridge:nope")))
        assertEquals(DigestAuth.Result.BAD, auth.check("GET", "/", basic("other:$token")))
        assertEquals(DigestAuth.Result.BAD, auth.check("GET", "/", "Basic !!!"))
    }

    @Test fun challengeOffersDigestOnly() {
        val c = auth.challenge()
        assertTrue(c.startsWith("Digest realm=\"MateBridge\", qop=\"auth\", algorithm=MD5, nonce=\""))
        assertFalse(c.contains(token))
    }

    @Test fun authParams() {
        val p = DigestAuth.parseParams("a=1, b=\"x, \\\"y\\\"\",c=\"\"")!!
        assertEquals(mapOf("a" to "1", "b" to "x, \"y\"", "c" to ""), p)
        assertNull(DigestAuth.parseParams("a=\"unterminated"))
        assertNull(DigestAuth.parseParams("a=1, a=2"))
    }

    // ---- Rate cap and stats ----

    @Test fun tokenBucketCapsTheRate() {
        var t = 0L
        val b = TokenBucket(1_000_000, 100_000, nanoTime = { t }, sleepNs = { t += it })
        assertEquals(0L, b.reserve(100_000)) // the burst
        assertEquals(64_000_000L, b.reserve(64_000)) // 64 KB at 1 MB/s = 64 ms of debt
        val waited = b.acquire(64_000) // the clock advances by what it sleeps
        assertEquals(128_000_000L, waited) // queued behind the first debt
        // Over a long run the average rate is the cap.
        t = 0
        val c = TokenBucket(20_000_000, 256 * 1024, nanoTime = { t }, sleepNs = { t += it })
        var sent = 0L
        repeat(1000) { c.acquire(65_536); sent += 65_536 }
        val rate = (sent - 256 * 1024) * 1e9 / t
        assertEquals(20_000_000.0, rate, 20_000.0)
    }

    @Test fun tokenBucketRefillsUpToTheBurstOnly() {
        var t = 0L
        val b = TokenBucket(1_000_000, 10_000, nanoTime = { t }, sleepNs = { t += it })
        assertEquals(0L, b.reserve(10_000))
        t += 10_000_000_000 // a long idle time
        assertEquals(0L, b.reserve(10_000))
        assertTrue(b.reserve(1) > 0)
    }

    @Test fun statsLineOnlyAfterActivityAndAtMostOncePerSecond() {
        val s = FilesStats()
        assertNull(s.poll(0))
        s.request(); s.bytesOut(2048); s.bytesIn(10); s.throttled(5_000_000)
        assertEquals("reqs=1 bytes_out=2048 bytes_in=10 bytes_copied=0 throttled_ms=5", s.poll(1000))
        s.bytesOut(1)
        assertNull(s.poll(1500))
        assertEquals("reqs=0 bytes_out=1 bytes_in=0 bytes_copied=0 throttled_ms=0", s.poll(2000))
        assertNull(s.poll(5000))
        s.request(); s.bytesCopied(7)
        assertEquals("reqs=1 bytes_out=0 bytes_in=0 bytes_copied=7 throttled_ms=0", s.poll(5001, force = true))
    }

    // ---- HTTP bodies ----

    @Test fun chunkedBodyDecodes() {
        val wire = "5\r\nhello\r\n8;ext=1\r\n, dünya\r\n0\r\nX-Trailer: 1\r\n\r\nNEXT".toByteArray(Charsets.UTF_8)
        val src = ByteArrayInputStream(wire)
        val body = BodyInputStream(src, -1)
        assertEquals("hello, dünya", body.readBytes().toString(Charsets.UTF_8))
        assertTrue(body.complete)
        assertEquals("NEXT", src.readBytes().toString(Charsets.US_ASCII)) // the next request is untouched
    }

    @Test fun chunkedOutputRoundTrips() {
        val out = ByteArrayOutputStream()
        val c = ChunkedOutputStream(out)
        c.write("abc".toByteArray())
        c.write(ByteArray(0))
        c.write("defgh".toByteArray())
        c.finish()
        val back = BodyInputStream(ByteArrayInputStream(out.toByteArray()), -1).readBytes()
        assertEquals("abcdefgh", String(back))
    }

    @Test fun requestHeadParsing() {
        val head = "PROPFIND /MatePad/%C3%A7 HTTP/1.1\r\nHost: localhost\r\nDepth: 1\r\nX-A: 1\r\nx-a: 2\r\n\r\nBODY"
        val src = ByteArrayInputStream(head.toByteArray(Charsets.ISO_8859_1))
        val r = HttpIo.readHead(src)!!
        assertEquals("PROPFIND", r.method)
        assertEquals("/MatePad/%C3%A7", r.target)
        assertEquals("1", r.header("Depth"))
        assertEquals("1, 2", r.header("x-a"))
        assertTrue(r.keepAlive)
        assertEquals("BODY", src.readBytes().toString(Charsets.US_ASCII))
        assertNull(HttpIo.readHead(ByteArrayInputStream(ByteArray(0))))
        try {
            HttpIo.readHead(ByteArrayInputStream("GET / HTTP/1.1\r\n${"X: y\r\n".repeat(10_000)}\r\n".toByteArray()))
            throw AssertionError("oversize head accepted")
        } catch (e: HttpError) {
            assertEquals(431, e.status)
        }
    }

    // ---- Switch ----

    @Test fun serverRunsOnlyWhenEnabledPermittedAndForeground() {
        assertTrue(FilesSwitch.shouldRun(enabled = true, permission = true, foreground = true))
        assertFalse(FilesSwitch.shouldRun(enabled = false, permission = true, foreground = true))
        assertFalse(FilesSwitch.shouldRun(enabled = true, permission = false, foreground = true))
        assertFalse(FilesSwitch.shouldRun(enabled = true, permission = true, foreground = false))
        assertEquals(FilesStatus.DISABLED, FilesSwitch.idleStatus(enabled = false, permission = false))
        assertEquals(FilesStatus.NO_PERMISSION, FilesSwitch.idleStatus(enabled = true, permission = false))
        assertEquals(FilesStatus.PAUSED, FilesSwitch.idleStatus(enabled = true, permission = true))
    }

    @Test fun tokenIs32LowercaseHexAndFresh() {
        val r = Random(1)
        val a = FilesSwitch.newToken(r)
        assertTrue(a.matches(Regex("[0-9a-f]{32}")))
        assertFalse(a == FilesSwitch.newToken(r))
    }

    // ---- Finder metadata store ----

    @Test fun metaNames() {
        assertTrue(MetaStore.isMetaName("._çizim.png"))
        assertTrue(MetaStore.isMetaName(".DS_Store"))
        assertFalse(MetaStore.isMetaName(".gizli"))
        assertFalse(MetaStore.isMetaName("a._b"))
    }

    @Test fun metaStoreIsBoundedAndLeastRecentlyUsedGoesFirst() {
        val m = MetaStore(maxEntries = 3, maxEntryBytes = 10, maxTotalBytes = 25)
        assertTrue(m.put("a/._1", ByteArray(10), 1))
        assertTrue(m.put("a/._2", ByteArray(10), 2))
        m.get("a/._1") // touch: ._2 is now the oldest
        assertTrue(m.put("a/._3", ByteArray(10), 3)) // 30 bytes > 25: ._2 goes
        assertNull(m.get("a/._2"))
        assertEquals(setOf("._1", "._3"), m.list("a").map { it.first }.toSet())
        assertFalse(m.put("a/._1", ByteArray(11), 4)) // too large: not kept, the old one is gone too
        assertNull(m.get("a/._1"))
        m.put("a/b/._x", ByteArray(1), 5)
        assertEquals(listOf("._3"), m.list("a").map { it.first }) // only direct children
        m.moveUnder("a", "z", copy = false)
        assertEquals(setOf("._3"), m.list("z").map { it.first }.toSet())
        assertEquals(listOf("._x"), m.list("z/b").map { it.first })
        m.removeUnder("z")
        assertEquals(0, m.size())
    }
}
