package dev.matebridge.client.files

import java.io.ByteArrayOutputStream
import java.io.File
import java.io.IOException
import java.nio.ByteBuffer
import java.nio.charset.CharacterCodingException
import java.nio.charset.CodingErrorAction
import java.text.Normalizer

/**
 * URL path handling of the WebDAV server (T-135). Pure Kotlin over java.io.File, no Android dependency.
 *
 * Safety rules: the request target is split on `/` *before* percent-decoding, every segment is decoded as strict UTF-8,
 * and a segment that decodes to `.`, `..`, or contains `/` or NUL is refused, so no path can climb out of the root by
 * name. Symbolic links are covered by [resolve]: the canonical form of the result must stay under the canonical root.
 *
 * macOS sends names in NFD (decomposed) form while files on the tablet are usually NFC, so a segment that does not exist
 * as sent is also looked up in the other normalization form; new names are created in NFC.
 */
object DavPath {
    /**
     * Path segments of a request target or a `Destination` header: origin form (`/a/b`), absolute form
     * (`http://localhost:1234/a/b`) or `*`. Query and fragment are dropped. Null when the target is malformed or unsafe.
     */
    fun parseTarget(target: String): List<String>? {
        if (target == "*") return emptyList()
        var path = target
        val scheme = path.indexOf("://")
        if (scheme > 0 && path.substring(0, scheme).all { it.isLetter() }) {
            val slash = path.indexOf('/', scheme + 3)
            path = if (slash < 0) "/" else path.substring(slash)
        }
        path = path.substringBefore('?').substringBefore('#')
        if (!path.startsWith("/")) return null
        val out = ArrayList<String>()
        for (raw in path.split('/')) {
            if (raw.isEmpty()) continue
            val seg = decodeSegment(raw) ?: return null
            if (seg == "." || seg == ".." || seg.contains('/') || seg.contains('\u0000')) return null
            out += seg
        }
        return out
    }

    /**
     * Strict percent-decoding of one segment to UTF-8. Characters above 0x7F are taken as raw bytes (the request head
     * is read as ISO-8859-1, so a client sending raw UTF-8 still decodes correctly). Null on bad escapes or bad UTF-8.
     */
    fun decodeSegment(raw: String): String? {
        val bytes = ByteArrayOutputStream(raw.length)
        var i = 0
        while (i < raw.length) {
            val c = raw[i]
            if (c == '%') {
                if (i + 2 >= raw.length) return null
                val hi = Character.digit(raw[i + 1], 16)
                val lo = Character.digit(raw[i + 2], 16)
                if (hi < 0 || lo < 0) return null
                bytes.write(hi * 16 + lo)
                i += 3
            } else {
                if (c.code > 0xFF) return null
                bytes.write(c.code)
                i++
            }
        }
        return try {
            Charsets.UTF_8.newDecoder()
                .onMalformedInput(CodingErrorAction.REPORT)
                .onUnmappableCharacter(CodingErrorAction.REPORT)
                .decode(ByteBuffer.wrap(bytes.toByteArray())).toString()
        } catch (e: CharacterCodingException) {
            null
        }
    }

    /** Percent-encodes one name for an href: RFC 3986 unreserved characters stay, every other UTF-8 byte is `%XX`. */
    fun encodeSegment(name: String): String {
        val sb = StringBuilder(name.length + 8)
        for (b in name.toByteArray(Charsets.UTF_8)) {
            val v = b.toInt() and 0xFF
            val ch = v.toChar()
            if (ch in 'A'..'Z' || ch in 'a'..'z' || ch in '0'..'9' || ch == '-' || ch == '.' || ch == '_' || ch == '~') {
                sb.append(ch)
            } else {
                sb.append('%').append(HEX[v shr 4]).append(HEX[v and 15])
            }
        }
        return sb.toString()
    }

    /** `/a/b` for a file, `/a/b/` for a collection; the root is `/`. */
    fun href(segments: List<String>, collection: Boolean): String {
        if (segments.isEmpty()) return "/"
        val p = segments.joinToString("/", prefix = "/") { encodeSegment(it) }
        return if (collection) "$p/" else p
    }

    /** A request path mapped onto the disk: [file] and the on-disk names of its [segments] (empty = the root). */
    class Resolved(val file: File, val segments: List<String>) {
        val isRoot: Boolean get() = segments.isEmpty()
        val name: String get() = segments.lastOrNull() ?: ""
    }

    /**
     * Maps [segments] under [root] (which must be canonical). Null when the result would lie outside the root (a
     * symbolic link pointing out of it). The target need not exist; missing names are returned in NFC.
     */
    fun resolve(root: File, segments: List<String>): Resolved? {
        var cur = root
        val names = ArrayList<String>(segments.size)
        var missing = false
        for (seg in segments) {
            val name = if (missing) nfc(seg) else lookup(cur, seg)
            val next = File(cur, name)
            if (!missing && !exists(next)) missing = true
            names += name
            cur = next
        }
        if (!inside(root, canonical(root, names))) return null
        return Resolved(cur, names)
    }

    /** The on-disk name in [dir] for a requested [seg]: as sent, else its NFC/NFD form, else an NFC-equal entry. */
    private fun lookup(dir: File, seg: String): String {
        if (exists(File(dir, seg))) return seg
        val c = nfc(seg)
        if (c != seg && exists(File(dir, c))) return c
        val d = Normalizer.normalize(seg, Normalizer.Form.NFD)
        if (d != seg && exists(File(dir, d))) return d
        if (c != d) { // only names with composable characters can have another stored form
            dir.list()?.firstOrNull { nfc(it) == c }?.let { return it }
        }
        return c
    }

    private fun nfc(s: String) = Normalizer.normalize(s, Normalizer.Form.NFC)

    /** True also for a dangling symbolic link (it occupies the name). */
    private fun exists(f: File): Boolean = f.exists() || isSymlink(f)

    fun isSymlink(f: File): Boolean = try {
        java.nio.file.Files.isSymbolicLink(f.toPath())
    } catch (e: Exception) {
        false
    }

    /**
     * Canonical path of root/names: the deepest existing ancestor is canonicalized (resolving symbolic links) and the
     * remaining, already validated names are appended. A dangling link resolves to its target.
     */
    private fun canonical(root: File, names: List<String>): File {
        var existing = names.size
        while (existing > 0) {
            val f = names.subList(0, existing).fold(root) { d, n -> File(d, n) }
            if (exists(f)) break
            existing--
        }
        val base = names.subList(0, existing).fold(root) { d, n -> File(d, n) }
        var c = try {
            base.canonicalFile
        } catch (e: IOException) {
            return File("/\u0000invalid") // never inside the root
        }
        if (isSymlink(base) && !base.exists()) {
            // Dangling link: canonicalFile may stop at the link itself; follow it one level by hand.
            try {
                val t = java.nio.file.Files.readSymbolicLink(base.toPath()).toFile()
                c = (if (t.isAbsolute) t else File(base.parentFile, t.path)).canonicalFile
            } catch (e: Exception) {
                return File("/\u0000invalid")
            }
        }
        for (n in names.subList(existing, names.size)) c = File(c, n)
        return c
    }

    /** [f] is [root] itself or below it (both canonical). */
    fun inside(root: File, f: File): Boolean {
        val r = root.path.trimEnd('/')
        val p = f.path
        return p == r || p.startsWith("$r/") || (r.isEmpty() && p.startsWith("/"))
    }

    private val HEX = "0123456789ABCDEF".toCharArray()
}
