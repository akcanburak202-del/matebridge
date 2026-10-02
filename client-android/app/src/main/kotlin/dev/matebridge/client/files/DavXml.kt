package dev.matebridge.client.files

import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone

/** One PROPFIND result row (T-135). [href] is already percent-encoded; [name] is the plain display name. */
data class DavEntry(
    val href: String,
    val name: String,
    val collection: Boolean,
    val length: Long,
    val modifiedMs: Long,
)

/** XML bodies and header values of the WebDAV server (RFC 4918). Pure Kotlin. */
object DavXml {
    const val CONTENT_TYPE = "application/xml; charset=\"utf-8\""
    const val MULTISTATUS_OPEN = "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n<D:multistatus xmlns:D=\"DAV:\">\n"
    const val MULTISTATUS_CLOSE = "</D:multistatus>\n"

    private const val SUPPORTED_LOCK =
        "<D:supportedlock><D:lockentry><D:lockscope><D:exclusive/></D:lockscope><D:locktype><D:write/></D:locktype>" +
            "</D:lockentry></D:supportedlock>"

    /**
     * One `<D:response>` with every property Finder reads.
     *
     * Never the RFC 4331 quota properties (`quota-available-bytes` / `quota-used-bytes`), T-137: when the pre-mount
     * PROPFIND reports them, macOS webdavfs keeps `WEBDAV_MOUNT_SUPPORTS_STATFS`, and the kernel's first statfs during
     * `mount(2)` asks webdavfs_agent (`WEBDAV_STATFS`), which does not answer while it is itself inside `mount(2)`: the
     * kernel waits 9 x 10 s and every mount takes 90 s. Without them the volume reports no sizes
     * (`VOL_CAP_FMT_NO_VOLUME_SIZES`, as with Apache mod_dav) and mounts in well under a second.
     */
    fun response(e: DavEntry): String {
        val sb = StringBuilder(640)
        sb.append("<D:response><D:href>").append(escape(e.href)).append("</D:href><D:propstat><D:prop>")
        sb.append("<D:displayname>").append(escape(e.name)).append("</D:displayname>")
        if (e.collection) {
            sb.append("<D:resourcetype><D:collection/></D:resourcetype>")
        } else {
            sb.append("<D:resourcetype/>")
            sb.append("<D:getcontentlength>").append(e.length).append("</D:getcontentlength>")
            sb.append("<D:getcontenttype>").append(escape(contentType(e.name))).append("</D:getcontenttype>")
        }
        sb.append("<D:getlastmodified>").append(httpDate(e.modifiedMs)).append("</D:getlastmodified>")
        sb.append("<D:creationdate>").append(isoDate(e.modifiedMs)).append("</D:creationdate>")
        sb.append("<D:getetag>").append(escape(etag(e.length, e.modifiedMs))).append("</D:getetag>")
        sb.append(SUPPORTED_LOCK).append("<D:lockdiscovery/>")
        sb.append("</D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>\n")
        return sb.toString()
    }

    fun multistatus(entries: List<DavEntry>): String =
        buildString {
            append(MULTISTATUS_OPEN)
            for (e in entries) append(response(e))
            append(MULTISTATUS_CLOSE)
        }

    /** LOCK response body: the granted (fake, in-memory) exclusive write lock. */
    fun lockDiscovery(token: String, href: String, depthInfinity: Boolean, timeoutSec: Long): String =
        "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n<D:prop xmlns:D=\"DAV:\"><D:lockdiscovery><D:activelock>" +
            "<D:locktype><D:write/></D:locktype><D:lockscope><D:exclusive/></D:lockscope>" +
            "<D:depth>${if (depthInfinity) "infinity" else "0"}</D:depth>" +
            "<D:timeout>Second-$timeoutSec</D:timeout>" +
            "<D:locktoken><D:href>${escape(token)}</D:href></D:locktoken>" +
            "<D:lockroot><D:href>${escape(href)}</D:href></D:lockroot>" +
            "</D:activelock></D:lockdiscovery></D:prop>\n"

    /**
     * XML text escaping. Characters XML 1.0 cannot carry at all (most C0 controls, lone surrogates, U+FFFE/U+FFFF; file
     * names may contain them) become U+FFFD, so one odd name cannot break a whole listing.
     */
    fun escape(s: String): String {
        val sb = StringBuilder(s.length + 16)
        var i = 0
        while (i < s.length) {
            val c = s[i]
            when {
                c == '&' -> sb.append("&amp;")
                c == '<' -> sb.append("&lt;")
                c == '>' -> sb.append("&gt;")
                c == '"' -> sb.append("&quot;")
                c == '\'' -> sb.append("&apos;")
                c == '\t' || c == '\n' || c == '\r' -> sb.append(c)
                c < ' ' || c == '￾' || c == '￿' -> sb.append('�')
                Character.isHighSurrogate(c) && i + 1 < s.length && Character.isLowSurrogate(s[i + 1]) -> {
                    sb.append(c).append(s[i + 1])
                    i++
                }
                Character.isSurrogate(c) -> sb.append('�')
                else -> sb.append(c)
            }
            i++
        }
        return sb.toString()
    }

    /** RFC 1123 date, e.g. `Fri, 02 Oct 2026 12:00:00 GMT` (getlastmodified, Last-Modified, Date). */
    fun httpDate(ms: Long): String = HTTP_DATE.get()!!.format(Date(ms))

    /** ISO 8601 UTC, e.g. `2026-10-02T12:00:00Z` (creationdate). */
    fun isoDate(ms: Long): String = ISO_DATE.get()!!.format(Date(ms))

    // SimpleDateFormat is not thread-safe: one per server thread (a large listing formats two dates per entry).
    private val HTTP_DATE = utcFormat("EEE, dd MMM yyyy HH:mm:ss 'GMT'")
    private val ISO_DATE = utcFormat("yyyy-MM-dd'T'HH:mm:ss'Z'")

    private fun utcFormat(pattern: String): ThreadLocal<SimpleDateFormat> = ThreadLocal.withInitial {
        SimpleDateFormat(pattern, Locale.US).apply { timeZone = TimeZone.getTimeZone("UTC") }
    }

    /** Weak validator from size and modification time (quoted, as on the wire). */
    fun etag(length: Long, modifiedMs: Long): String = "\"${java.lang.Long.toHexString(modifiedMs)}-${java.lang.Long.toHexString(length)}\""

    /** Content type from the file extension; unknown ones are `application/octet-stream`. */
    fun contentType(name: String): String {
        val dot = name.lastIndexOf('.')
        if (dot < 0 || dot == name.length - 1) return OCTET
        return TYPES[name.substring(dot + 1).lowercase(Locale.ROOT)] ?: OCTET
    }

    private const val OCTET = "application/octet-stream"

    private val TYPES = mapOf(
        "txt" to "text/plain", "md" to "text/markdown", "csv" to "text/csv", "html" to "text/html", "htm" to "text/html",
        "xml" to "application/xml", "json" to "application/json", "pdf" to "application/pdf",
        "jpg" to "image/jpeg", "jpeg" to "image/jpeg", "png" to "image/png", "gif" to "image/gif", "webp" to "image/webp",
        "heic" to "image/heic", "heif" to "image/heif", "bmp" to "image/bmp", "svg" to "image/svg+xml", "tif" to "image/tiff",
        "tiff" to "image/tiff", "mp4" to "video/mp4", "mov" to "video/quicktime", "mkv" to "video/x-matroska",
        "webm" to "video/webm", "3gp" to "video/3gpp", "mp3" to "audio/mpeg", "m4a" to "audio/mp4", "aac" to "audio/aac",
        "wav" to "audio/wav", "ogg" to "audio/ogg", "flac" to "audio/flac", "zip" to "application/zip",
        "apk" to "application/vnd.android.package-archive", "doc" to "application/msword",
        "docx" to "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
        "xls" to "application/vnd.ms-excel", "xlsx" to "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
        "ppt" to "application/vnd.ms-powerpoint",
        "pptx" to "application/vnd.openxmlformats-officedocument.presentationml.presentation",
    )
}
