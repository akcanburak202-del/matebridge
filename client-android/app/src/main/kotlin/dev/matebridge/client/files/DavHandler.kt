package dev.matebridge.client.files

import java.io.BufferedOutputStream
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.io.OutputStreamWriter
import java.io.RandomAccessFile
import java.security.SecureRandom
import java.util.UUID

/**
 * One WebDAV request (RFC 4918 subset Finder needs, decision 0015, T-135): OPTIONS, PROPFIND (Depth 0/1), GET/HEAD
 * (single Range), PUT (streamed to a temporary file, then moved), DELETE, MKCOL, MOVE, COPY, LOCK/UNLOCK (fake,
 * in-memory locks: macOS mounts read-only without DAV class 2). Every request must authenticate ([DigestAuth]).
 *
 * Pure JVM code over java.io: the connection's streams come in already rate-limited. Never logs paths, names, the
 * token or header values.
 */
class DavHandler(
    /** Canonical root directory; nothing outside it is ever served or touched. */
    private val root: File,
    private val auth: DigestAuth,
    private val config: FilesConfig,
    private val log: (ev: String, fields: String) -> Unit = { _, _ -> },
    private val nowMs: () -> Long = System::currentTimeMillis,
) {
    private val random = SecureRandom()
    private val locks = object : LinkedHashMap<String, String>(16, 0.75f, false) {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<String, String>?) = size > MAX_LOCKS
    }

    /**
     * Answers one request read from [input] (the connection's input, positioned at the body) onto [out]. Returns true
     * when the connection may carry another request. Socket errors propagate (the caller closes the connection).
     */
    fun handle(req: HttpRequest, input: InputStream, out: OutputStream): Boolean {
        val length = try {
            req.bodyLength()
        } catch (e: HttpError) {
            Exchange(req, BodyInputStream(input, 0), out).also { it.closeAfter = true }.empty(e.status)
            return false
        }
        val expectContinue = req.http11 && req.header("expect")?.trim()?.equals("100-continue", ignoreCase = true) == true
        val body = BodyInputStream(input, length) {
            if (expectContinue) {
                out.write(CONTINUE)
                out.flush()
            }
        }
        val ex = Exchange(req, body, out)
        try {
            dispatch(req, body, ex)
        } catch (e: HttpError) {
            if (ex.started) throw e
            ex.closeAfter = true
            ex.empty(e.status)
        } catch (e: IOException) {
            // A file-system failure before the response started gets a 500; one after it (or a socket error) ends the
            // connection. Only the exception class is logged: messages can contain paths.
            if (ex.started) throw e
            log("request_error", "method=${logMethod(req.method)} kind=${e.javaClass.simpleName}")
            ex.closeAfter = true
            ex.empty(500)
        }
        return !ex.closeAfter
    }

    private fun dispatch(req: HttpRequest, body: BodyInputStream, ex: Exchange) {
        val a = auth.check(req.method, req.target, req.header("authorization"))
        if (a != DigestAuth.Result.OK) {
            ex.empty(401, listOf("WWW-Authenticate" to auth.challenge(stale = a == DigestAuth.Result.STALE)))
            return
        }
        val all = DavPath.parseTarget(req.target) ?: return ex.empty(400)
        if (req.method == "OPTIONS") return ex.empty(200, listOf("DAV" to "1, 2", "MS-Author-Via" to "DAV", "Allow" to ALLOW))
        if (all.isEmpty()) return virtualRoot(req, body, ex)
        // The storage lives under /MatePad/ so Finder names the volume "MatePad" (orchestrator decision); nothing else exists.
        if (all[0] != MOUNT) return ex.empty(404)
        val segs = all.drop(1)
        val res = DavPath.resolve(root, segs) ?: return ex.empty(403)
        when (req.method) {
            "PROPFIND" -> propfind(req, body, ex, segs, res)
            "GET" -> get(req, ex, res, head = false)
            "HEAD" -> get(req, ex, res, head = true)
            "PUT" -> put(req, body, ex, res)
            "DELETE" -> delete(ex, res)
            "MKCOL" -> mkcol(req, ex, res)
            "MOVE" -> moveOrCopy(req, ex, res, move = true)
            "COPY" -> moveOrCopy(req, ex, res, move = false)
            "LOCK" -> lock(req, body, ex, segs, res)
            "UNLOCK" -> {
                req.header("lock-token")?.trim()?.removePrefix("<")?.removeSuffix(">")?.let { synchronized(locks) { locks.remove(it) } }
                ex.empty(204)
            }
            else -> ex.empty(405, listOf("Allow" to ALLOW))
        }
    }

    /** `/MatePad` + the storage path; the storage root is `/MatePad/`. */
    private fun hrefOf(segs: List<String>, collection: Boolean) = "/$MOUNT" + DavPath.href(segs, collection)

    /** Storage segments of a `Destination` header: null unless it lies under `/MatePad/`. */
    private fun storageSegments(dest: String): List<String>? {
        val all = DavPath.parseTarget(dest) ?: return null
        if (all.isEmpty() || all[0] != MOUNT) return null
        return all.drop(1)
    }

    /** `/` itself: a read-only collection whose only member is `MatePad/`. */
    private fun virtualRoot(req: HttpRequest, body: BodyInputStream, ex: Exchange) {
        if (req.method != "PROPFIND") return ex.empty(405, listOf("Allow" to "OPTIONS, PROPFIND"))
        val depth = req.header("depth")?.trim()?.lowercase()
        if (depth != "0" && depth != "1") return ex.empty(403)
        readSmallBody(body) ?: return ex.empty(413)
        val mtime = root.lastModified()
        val entries = ArrayList<DavEntry>(2)
        entries += DavEntry("/", "MateBridge", true, 0, mtime)
        if (depth == "1") entries += DavEntry("/$MOUNT/", MOUNT, true, 0, mtime, quota())
        ex.bytes(207, DavXml.CONTENT_TYPE, DavXml.multistatus(entries).toByteArray(Charsets.UTF_8))
    }

    // ---- PROPFIND ----

    private fun propfind(req: HttpRequest, body: BodyInputStream, ex: Exchange, segs: List<String>, res: DavPath.Resolved) {
        val depth = req.header("depth")?.trim()?.lowercase()
        // Depth infinity (also the default when the header is missing) would walk the whole storage: refused (RFC 4918 9.1).
        if (depth != "0" && depth != "1") return ex.empty(403)
        readSmallBody(body) ?: return ex.empty(413)
        val f = res.file
        if (!f.exists()) return ex.empty(404)
        val collection = f.isDirectory
        val self = DavEntry(
            href = hrefOf(segs, collection),
            name = segs.lastOrNull() ?: MOUNT,
            collection = collection,
            length = if (collection) 0 else f.length(),
            modifiedMs = f.lastModified(),
            quota = if (collection) quota() else null,
        )
        val children = if (collection && depth == "1") (f.listFiles() ?: emptyArray()) else emptyArray()
        ex.start(207, listOf("Content-Type" to DavXml.CONTENT_TYPE), null)
        val sink = ex.bodySink()
        val w = OutputStreamWriter(BufferedOutputStream(sink, 16 * 1024), Charsets.UTF_8)
        w.write(DavXml.MULTISTATUS_OPEN)
        w.write(DavXml.response(self))
        for (c in children) {
            val name = c.name
            if (isTempName(name)) continue
            if (DavPath.isSymlink(c) && !insideCanonical(c)) continue // a link leading out of the root is not shown
            val dir = c.isDirectory
            w.write(
                DavXml.response(
                    DavEntry(hrefOf(res.segments + name, dir), name, dir, if (dir) 0 else c.length(), c.lastModified()),
                ),
            )
        }
        w.write(DavXml.MULTISTATUS_CLOSE)
        w.flush()
        ex.finishBody()
    }

    private fun quota(): Pair<Long, Long> = try {
        val free = root.usableSpace
        Pair(free, (root.totalSpace - root.freeSpace).coerceAtLeast(0))
    } catch (e: SecurityException) {
        Pair(0L, 0L)
    }

    private fun insideCanonical(f: File): Boolean = try {
        DavPath.inside(root, f.canonicalFile)
    } catch (e: IOException) {
        false
    }

    // ---- GET / HEAD ----

    private fun get(req: HttpRequest, ex: Exchange, res: DavPath.Resolved, head: Boolean) {
        val f = res.file
        if (!f.exists()) return ex.empty(404)
        if (f.isDirectory) return ex.empty(405, listOf("Allow" to ALLOW))
        if (!f.canRead()) return ex.empty(403)
        val total = f.length()
        val mtime = f.lastModified()
        val etag = DavXml.etag(total, mtime)
        var range = ByteRange.parse(req.header("range"), total)
        req.header("if-range")?.trim()?.let { v -> if (v != etag && v != DavXml.httpDate(mtime)) range = ByteRange.Full }
        val common = listOf(
            "Content-Type" to DavXml.contentType(res.name),
            "Last-Modified" to DavXml.httpDate(mtime),
            "ETag" to etag,
            "Accept-Ranges" to "bytes",
        )
        val (status, start, count, extra) = when (val r = range) {
            ByteRange.Full -> Quad(200, 0L, total, emptyList())
            is ByteRange.Part -> Quad(206, r.start, r.length, listOf("Content-Range" to r.contentRange(total)))
            ByteRange.Unsatisfiable -> return ex.empty(416, listOf("Content-Range" to "bytes */$total"))
        }
        if (head) {
            ex.start(status, common + extra, count, withBody = false)
            return
        }
        RandomAccessFile(f, "r").use { raf ->
            raf.seek(start)
            ex.start(status, common + extra, count)
            val buf = ByteArray(config.bufferBytes)
            var left = count
            val sink = ex.bodySink()
            while (left > 0) {
                val n = raf.read(buf, 0, minOf(buf.size.toLong(), left).toInt())
                if (n < 0) throw ConnectionAbort() // the file shrank under us: the client sees a short body
                sink.write(buf, 0, n)
                left -= n
            }
            sink.flush()
        }
    }

    private data class Quad(val status: Int, val start: Long, val count: Long, val extra: List<Pair<String, String>>)

    // ---- PUT ----

    private fun put(req: HttpRequest, body: BodyInputStream, ex: Exchange, res: DavPath.Resolved) {
        val target = res.file
        if (res.isRoot || target.isDirectory) return ex.empty(405, listOf("Allow" to ALLOW))
        val parent = target.parentFile
        if (parent == null || !parent.isDirectory) return ex.empty(409)
        val expected = (req.header("x-expected-entity-length") ?: req.header("content-length"))?.trim()?.toLongOrNull()
        if (expected != null && expected > parent.usableSpace) return ex.empty(507)
        val existed = target.exists()
        val tmp = File(parent, TEMP_PREFIX + hex(8) + TEMP_SUFFIX)
        var committed = false
        try {
            FileOutputStream(tmp).use { fos ->
                val buf = ByteArray(config.bufferBytes)
                while (true) {
                    val n = body.read(buf, 0, buf.size)
                    if (n < 0) break
                    fos.write(buf, 0, n)
                }
            }
            if (!tmp.renameTo(target)) {
                // Some file systems refuse to replace on rename: remove the old file, then move.
                if (!(target.delete() && tmp.renameTo(target))) throw IOException("rename failed")
            }
            committed = true
        } finally {
            if (!committed) tmp.delete() // an aborted or failed upload leaves nothing behind
        }
        ex.empty(if (existed) 204 else 201)
    }

    // ---- DELETE / MKCOL ----

    private fun delete(ex: Exchange, res: DavPath.Resolved) {
        val f = res.file
        if (res.isRoot) return ex.empty(403)
        if (!f.exists() && !DavPath.isSymlink(f)) return ex.empty(404)
        ex.empty(if (deleteTree(f)) 204 else 500)
    }

    private fun mkcol(req: HttpRequest, ex: Exchange, res: DavPath.Resolved) {
        if (req.bodyLength() != 0L) return ex.empty(415)
        val f = res.file
        if (res.isRoot || f.exists() || DavPath.isSymlink(f)) return ex.empty(405, listOf("Allow" to ALLOW))
        val parent = f.parentFile
        if (parent == null || !parent.isDirectory) return ex.empty(409)
        ex.empty(if (f.mkdir()) 201 else 500)
    }

    // ---- MOVE / COPY ----

    private fun moveOrCopy(req: HttpRequest, ex: Exchange, res: DavPath.Resolved, move: Boolean) {
        val destHeader = req.header("destination") ?: return ex.empty(400)
        val destSegs = storageSegments(destHeader.trim()) ?: return ex.empty(403) // only within /MatePad/
        val dest = DavPath.resolve(root, destSegs) ?: return ex.empty(403)
        val src = res.file
        if (res.isRoot || dest.isRoot) return ex.empty(403)
        if (!src.exists()) return ex.empty(404)
        val overwrite = req.header("overwrite")?.trim()?.uppercase() != "F"
        val d = dest.file
        val dParent = d.parentFile
        if (dParent == null || !dParent.isDirectory) return ex.empty(409)
        if (d.path == src.path) return ex.empty(403)
        if (d.path.startsWith(src.path + "/")) return ex.empty(409) // into itself
        val destExisted = d.exists() || DavPath.isSymlink(d)
        if (destExisted && sameFile(src, d)) {
            // The same file under another spelling (case-insensitive storage, NFC/NFD): a rename, never "delete dest".
            if (!move) return ex.empty(403)
            return ex.empty(if (src.renameTo(d)) 201 else 500)
        }
        if (destExisted) {
            if (!overwrite) return ex.empty(412)
            if (!deleteTree(d)) return ex.empty(500)
        }
        val ok = if (move) {
            src.renameTo(d) || (copyTree(src, d, recursive = true) && deleteTree(src))
        } else {
            copyTree(src, d, recursive = req.header("depth")?.trim() != "0")
        }
        ex.empty(if (!ok) 500 else if (destExisted) 204 else 201)
    }

    private fun sameFile(a: File, b: File): Boolean = try {
        java.nio.file.Files.isSameFile(a.toPath(), b.toPath())
    } catch (e: Exception) {
        false
    }

    /** Deletes [f] and, for a real directory, everything below it. Symbolic links are removed, never followed. */
    private fun deleteTree(f: File): Boolean {
        if (f.isDirectory && !DavPath.isSymlink(f)) {
            for (c in f.listFiles() ?: emptyArray()) if (!deleteTree(c)) return false
        }
        return f.delete()
    }

    /** Copies [src] to [dst]; symbolic links inside a copied tree are skipped. */
    private fun copyTree(src: File, dst: File, recursive: Boolean): Boolean {
        if (src.isDirectory) {
            if (!dst.mkdir()) return false
            if (recursive) {
                for (c in src.listFiles() ?: emptyArray()) {
                    if (DavPath.isSymlink(c) || isTempName(c.name)) continue
                    if (!copyTree(c, File(dst, c.name), true)) return false
                }
            }
            dst.setLastModified(src.lastModified())
            return true
        }
        FileInputStream(src).use { input ->
            FileOutputStream(dst).use { output ->
                val buf = ByteArray(config.bufferBytes)
                while (true) {
                    val n = input.read(buf)
                    if (n < 0) break
                    output.write(buf, 0, n)
                }
            }
        }
        dst.setLastModified(src.lastModified())
        return true
    }

    // ---- LOCK ----

    private fun lock(req: HttpRequest, body: BodyInputStream, ex: Exchange, segs: List<String>, res: DavPath.Resolved) {
        val xml = readSmallBody(body) ?: return ex.empty(413)
        val timeout = parseTimeout(req.header("timeout"))
        val depthInfinity = req.header("depth")?.trim() != "0"
        val href = hrefOf(segs, res.file.isDirectory)
        if (xml.isBlank()) {
            // Refresh: the token comes in the If header.
            val token = LOCK_TOKEN.find(req.header("if") ?: "")?.groupValues?.get(1) ?: return ex.empty(400)
            return sendLock(ex, 200, token, href, depthInfinity, timeout)
        }
        var status = 200
        val f = res.file
        if (!f.exists()) {
            // RFC 4918 9.10.4: locking an unmapped URL creates an empty resource.
            val parent = f.parentFile
            if (res.isRoot || parent == null || !parent.isDirectory) return ex.empty(409)
            if (!f.createNewFile() && !f.exists()) return ex.empty(500)
            status = 201
        }
        val token = "opaquelocktoken:${UUID.randomUUID()}"
        synchronized(locks) { locks[token] = href }
        sendLock(ex, status, token, href, depthInfinity, timeout)
    }

    private fun sendLock(ex: Exchange, status: Int, token: String, href: String, depthInfinity: Boolean, timeout: Long) {
        val body = DavXml.lockDiscovery(token, href, depthInfinity, timeout).toByteArray(Charsets.UTF_8)
        ex.bytes(status, DavXml.CONTENT_TYPE, body, listOf("Lock-Token" to "<$token>"))
    }

    // ---- helpers ----

    /** Reads a small XML request body; null when it is larger than [FilesConfig.MAX_XML_BODY_BYTES]. */
    private fun readSmallBody(body: BodyInputStream): String? {
        val acc = ByteArrayOutputStream()
        val buf = ByteArray(8192)
        while (true) {
            val n = body.read(buf, 0, buf.size)
            if (n < 0) break
            acc.write(buf, 0, n)
            if (acc.size() > FilesConfig.MAX_XML_BODY_BYTES) return null
        }
        return acc.toString("UTF-8")
    }

    private fun hex(bytes: Int): String {
        val b = ByteArray(bytes).also { random.nextBytes(it) }
        return b.joinToString("") { "%02x".format(it.toInt() and 0xFF) }
    }

    /**
     * The response side of one request. Before the head goes out, a request body that was not read is drained (small)
     * or the connection is marked to close, so the next request never starts in the middle of an old body.
     */
    private inner class Exchange(private val req: HttpRequest, private val body: BodyInputStream, private val out: OutputStream) {
        var closeAfter = !req.keepAlive
        var started = false
            private set
        private var chunked: ChunkedOutputStream? = null

        fun empty(status: Int, headers: List<Pair<String, String>> = emptyList()) = start(status, headers, 0)

        fun bytes(status: Int, type: String, data: ByteArray, headers: List<Pair<String, String>> = emptyList()) {
            start(status, headers + ("Content-Type" to type), data.size.toLong())
            out.write(data)
            out.flush()
        }

        /** Writes the head. [length] null: a body of unknown length (chunked on HTTP/1.1, else ended by closing). */
        fun start(status: Int, headers: List<Pair<String, String>>, length: Long?, withBody: Boolean = true) {
            check(!started)
            settleBody()
            started = true
            val sb = StringBuilder(256)
            sb.append("HTTP/1.1 ").append(status).append(' ').append(reason(status)).append("\r\n")
            sb.append("Date: ").append(DavXml.httpDate(nowMs())).append("\r\n")
            sb.append("Server: MateBridge\r\n")
            for ((k, v) in headers) sb.append(k).append(": ").append(v).append("\r\n")
            when {
                length != null -> sb.append("Content-Length: ").append(length).append("\r\n")
                !withBody -> Unit
                req.http11 -> sb.append("Transfer-Encoding: chunked\r\n")
                else -> closeAfter = true // HTTP/1.0: the body ends when the connection closes
            }
            if (closeAfter) sb.append("Connection: close\r\n")
            sb.append("\r\n")
            out.write(sb.toString().toByteArray(Charsets.ISO_8859_1))
            if (length == null && withBody && req.http11) chunked = ChunkedOutputStream(out)
            if (length != null || !withBody) out.flush()
        }

        /** Where the body of a [start]ed response goes (chunk-encoded when needed). */
        fun bodySink(): OutputStream = chunked ?: object : java.io.FilterOutputStream(out) {
            override fun write(b: ByteArray, off: Int, len: Int) = out.write(b, off, len)
            override fun close() = flush()
        }

        fun finishBody() {
            chunked?.finish() ?: out.flush()
        }

        private fun settleBody() {
            if (body.complete) return
            val expectContinue = req.http11 && req.header("expect")?.trim()?.equals("100-continue", ignoreCase = true) == true
            // With Expect: 100-continue and no read yet, the client holds the body back: reading would deadlock.
            if (expectContinue && !body.touched) { closeAfter = true; return }
            val ok = try {
                body.drain(MAX_DRAIN_BYTES)
            } catch (e: IOException) {
                false
            }
            if (!ok) closeAfter = true
        }
    }

    /** The file changed under a running GET: the connection is dropped (the client sees a short body). */
    private class ConnectionAbort : IOException("short file")

    companion object {
        const val ALLOW = "OPTIONS, PROPFIND, GET, HEAD, PUT, DELETE, MKCOL, MOVE, COPY, LOCK, UNLOCK"
        /** First path segment of the storage (`/MatePad/...`); the host mounts `http://localhost:<port>/MatePad/`. */
        const val MOUNT = "MatePad"
        const val TEMP_PREFIX = ".mbput-"
        const val TEMP_SUFFIX = ".tmp"
        private const val MAX_LOCKS = 256
        private const val MAX_DRAIN_BYTES = 64L * 1024
        private const val MAX_TIMEOUT_SEC = 3600L
        private val CONTINUE = "HTTP/1.1 100 Continue\r\n\r\n".toByteArray(Charsets.US_ASCII)
        private val LOCK_TOKEN = Regex("<(opaquelocktoken:[^>]+)>")

        fun isTempName(name: String) = name.startsWith(TEMP_PREFIX) && name.endsWith(TEMP_SUFFIX)

        /** `Timeout: Second-600, Infinite` -> 600; Infinite or missing -> [MAX_TIMEOUT_SEC]; capped at it. */
        fun parseTimeout(h: String?): Long {
            if (h == null) return MAX_TIMEOUT_SEC
            for (part in h.split(',')) {
                val p = part.trim()
                if (p.startsWith("Second-", ignoreCase = true)) {
                    val v = p.substring(7).toLongOrNull() ?: continue
                    return v.coerceIn(1, MAX_TIMEOUT_SEC)
                }
            }
            return MAX_TIMEOUT_SEC
        }

        /** Method name for logs: known methods only (a request line is client data). */
        fun logMethod(m: String) = if (m in ALLOW.split(", ")) m else "other"

        fun reason(status: Int) = when (status) {
            100 -> "Continue"
            200 -> "OK"
            201 -> "Created"
            204 -> "No Content"
            206 -> "Partial Content"
            207 -> "Multi-Status"
            400 -> "Bad Request"
            401 -> "Unauthorized"
            403 -> "Forbidden"
            404 -> "Not Found"
            405 -> "Method Not Allowed"
            409 -> "Conflict"
            412 -> "Precondition Failed"
            413 -> "Content Too Large"
            415 -> "Unsupported Media Type"
            416 -> "Range Not Satisfiable"
            431 -> "Request Header Fields Too Large"
            500 -> "Internal Server Error"
            503 -> "Service Unavailable"
            505 -> "HTTP Version Not Supported"
            507 -> "Insufficient Storage"
            else -> "Status"
        }
    }
}
