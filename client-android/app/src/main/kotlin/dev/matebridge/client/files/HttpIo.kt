package dev.matebridge.client.files

import java.io.FilterInputStream
import java.io.FilterOutputStream
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream

/** A request the server answers with [status] and then closes the connection (malformed head, oversize, ...). */
class HttpError(val status: Int) : IOException("http $status")

/** Parsed request line and headers. Header names are lowercased; repeated headers are joined with ", ". */
class HttpRequest(val method: String, val target: String, val version: String, val headers: Map<String, String>) {
    fun header(name: String): String? = headers[name.lowercase()]

    val http11: Boolean get() = version == "HTTP/1.1"

    /** HTTP/1.1 keeps the connection unless `Connection: close`; HTTP/1.0 closes unless `Connection: keep-alive`. */
    val keepAlive: Boolean
        get() {
            val c = header("connection")?.lowercase() ?: ""
            return if (http11) !c.contains("close") else c.contains("keep-alive")
        }

    val chunked: Boolean get() = header("transfer-encoding")?.lowercase()?.contains("chunked") == true

    /** Declared body length: -1 for chunked, 0 when there is no body. Throws [HttpError] 400 on a bad value. */
    fun bodyLength(): Long {
        if (chunked) return -1
        val cl = header("content-length") ?: return 0
        return cl.trim().toLongOrNull()?.takeIf { it >= 0 } ?: throw HttpError(400)
    }
}

object HttpIo {
    /**
     * Reads one request head (request line + headers up to the empty line) of at most [maxBytes]. Returns null on a
     * clean end of stream before the first byte (the client closed a keep-alive connection). The head is decoded as
     * ISO-8859-1 so raw UTF-8 bytes in a target survive for [DavPath.decodeSegment].
     */
    fun readHead(input: InputStream, maxBytes: Int = FilesConfig.MAX_HEAD_BYTES): HttpRequest? {
        val lines = ArrayList<String>()
        val line = StringBuilder()
        var total = 0
        var first = true
        while (true) {
            val b = input.read()
            if (b < 0) {
                if (first && total == 0) return null
                throw IOException("eof in request head")
            }
            first = false
            if (++total > maxBytes) throw HttpError(431)
            if (b == '\n'.code) {
                if (line.isNotEmpty() && line[line.length - 1] == '\r') line.setLength(line.length - 1)
                if (line.isEmpty()) {
                    if (lines.isEmpty()) continue // tolerate blank lines before a request (RFC 9112 section 2.2)
                    break
                }
                lines += line.toString()
                line.setLength(0)
            } else {
                line.append(b.toChar())
            }
        }
        val parts = lines[0].split(' ')
        if (parts.size != 3 || parts[0].isEmpty() || parts[1].isEmpty()) throw HttpError(400)
        if (parts[2] != "HTTP/1.1" && parts[2] != "HTTP/1.0") throw HttpError(505)
        val headers = LinkedHashMap<String, String>()
        for (h in lines.subList(1, lines.size)) {
            val colon = h.indexOf(':')
            if (colon <= 0 || h[0] == ' ' || h[0] == '\t') throw HttpError(400) // no obsolete line folding
            val name = h.substring(0, colon).trim().lowercase()
            val value = h.substring(colon + 1).trim()
            headers[name] = headers[name]?.let { "$it, $value" } ?: value
        }
        return HttpRequest(parts[0], parts[1], parts[2], headers)
    }
}

/**
 * A request body: [length] bytes, or chunked when [length] is -1. [complete] tells whether the whole body was read, so
 * the connection can be reused. Closing does not close the socket stream. [beforeFirstRead] runs once (sends
 * `100 Continue`).
 */
class BodyInputStream(
    private val src: InputStream,
    private val length: Long,
    private val beforeFirstRead: () -> Unit = {},
) : InputStream() {
    private var remaining = if (length >= 0) length else 0L
    private var chunkLeft = 0L
    private var done = length == 0L
    private var started = false

    /** True when the body has been read to its end. */
    val complete: Boolean get() = done

    /** True once a read was attempted (the `100 Continue`, if any, went out). */
    val touched: Boolean get() = started

    override fun read(): Int {
        val one = ByteArray(1)
        val n = read(one, 0, 1)
        return if (n < 0) -1 else one[0].toInt() and 0xFF
    }

    override fun read(b: ByteArray, off: Int, len: Int): Int {
        if (len == 0) return 0
        if (!started) {
            started = true
            if (!done) beforeFirstRead()
        }
        if (done) return -1
        if (length >= 0) {
            val n = src.read(b, off, minOf(len.toLong(), remaining).toInt())
            if (n < 0) throw IOException("eof in body")
            remaining -= n
            if (remaining == 0L) done = true
            return n
        }
        if (chunkLeft == 0L) {
            chunkLeft = readChunkSize()
            if (chunkLeft == 0L) {
                skipTrailers()
                done = true
                return -1
            }
        }
        val n = src.read(b, off, minOf(len.toLong(), chunkLeft).toInt())
        if (n < 0) throw IOException("eof in chunk")
        chunkLeft -= n
        if (chunkLeft == 0L) expectCrlf()
        return n
    }

    private fun readLine(): String {
        val sb = StringBuilder()
        while (true) {
            val c = src.read()
            if (c < 0) throw IOException("eof in chunk header")
            if (c == '\n'.code) break
            if (sb.length > 1024) throw HttpError(400)
            sb.append(c.toChar())
        }
        return sb.toString().trimEnd('\r')
    }

    private fun readChunkSize(): Long {
        val hex = readLine().substringBefore(';').trim()
        if (hex.isEmpty() || hex.length > 15) throw HttpError(400)
        return hex.toLongOrNull(16)?.takeIf { it >= 0 } ?: throw HttpError(400)
    }

    private fun expectCrlf() {
        if (readLine().isNotEmpty()) throw HttpError(400)
    }

    private fun skipTrailers() {
        while (readLine().isNotEmpty()) Unit
    }

    /** Reads and discards up to [max] remaining bytes; true when the body is then complete. */
    fun drain(max: Long): Boolean {
        val buf = ByteArray(8192)
        var left = max
        while (!done && left > 0) {
            val n = read(buf, 0, minOf(buf.size.toLong(), left).toInt())
            if (n < 0) break
            left -= n
        }
        return done
    }

    override fun close() = Unit
}

/** Chunked response body; [finish] writes the last chunk. Never closes the underlying stream. */
class ChunkedOutputStream(out: OutputStream) : FilterOutputStream(out) {
    override fun write(b: Int) = write(byteArrayOf(b.toByte()), 0, 1)

    override fun write(b: ByteArray, off: Int, len: Int) {
        if (len == 0) return
        out.write("${Integer.toHexString(len)}\r\n".toByteArray(Charsets.US_ASCII))
        out.write(b, off, len)
        out.write(CRLF)
    }

    fun finish() {
        out.write("0\r\n\r\n".toByteArray(Charsets.US_ASCII))
        out.flush()
    }

    override fun close() = flush()

    private companion object {
        val CRLF = "\r\n".toByteArray(Charsets.US_ASCII)
    }
}

/**
 * Socket input under the shared rate cap: bytes are booked after they arrive (TCP flow control holds the sender).
 * [arrived] runs as soon as a read returned bytes, before any rate-cap wait (the connection is busy from then on);
 * [tick] runs after each read (the per-second stats line).
 */
class ThrottledInputStream(
    src: InputStream,
    private val bucket: ByteBudget,
    private val stats: FilesStats,
    private val arrived: () -> Unit = {},
    private val tick: () -> Unit = {},
) : FilterInputStream(src) {
    override fun read(): Int {
        val v = `in`.read()
        if (v >= 0) account(1)
        return v
    }

    override fun read(b: ByteArray, off: Int, len: Int): Int {
        val n = `in`.read(b, off, len)
        if (n > 0) account(n)
        return n
    }

    private fun account(n: Int) {
        arrived()
        stats.bytesIn(n.toLong())
        val slept = bucket.acquire(n.toLong())
        if (slept > 0) stats.throttled(slept)
        tick()
    }
}

/**
 * Socket output under the shared rate cap: each piece of at most [maxPiece] bytes waits for its budget first. The
 * socket write itself (not the budget wait) is bracketed by [watch], the write-stall timeout (T-139).
 */
class ThrottledOutputStream(
    dst: OutputStream,
    private val bucket: ByteBudget,
    private val stats: FilesStats,
    private val maxPiece: Int,
    private val watch: WriteWatchdog.Watch? = null,
    private val tick: () -> Unit = {},
) : FilterOutputStream(dst) {
    override fun write(b: Int) = write(byteArrayOf(b.toByte()), 0, 1)

    override fun write(b: ByteArray, off: Int, len: Int) {
        var o = off
        var left = len
        while (left > 0) {
            val n = minOf(left, maxPiece)
            val slept = bucket.acquire(n.toLong())
            if (slept > 0) stats.throttled(slept)
            watch?.begin()
            try {
                out.write(b, o, n)
            } finally {
                watch?.end()
            }
            stats.bytesOut(n.toLong())
            o += n
            left -= n
        }
        tick()
    }
}
