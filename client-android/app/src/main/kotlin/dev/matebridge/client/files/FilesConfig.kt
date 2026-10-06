package dev.matebridge.client.files

import java.io.File
import java.io.IOException

/**
 * Tunables of the tablet-files WebDAV server (decision 0015, T-135), in one place so the device test can adjust them.
 * The rate cap protects the video stream: file transfers share the USB/adb line with ~7.5 MB/s of video.
 */
data class FilesConfig(
    /** Total transfer rate (request + response bodies of all connections), bytes per second. */
    val rateBytesPerSec: Long = RATE_BYTES_PER_SEC,
    /** Token bucket depth: how much may go out at once after an idle moment. */
    val burstBytes: Long = BURST_BYTES,
    /**
     * Concurrent connections (soft limit). At the limit a truly idle keep-alive connection is closed for a new one;
     * when none is, the new one is taken as overflow, up to [overflowConnections] more (T-139).
     */
    val maxConnections: Int = MAX_CONNECTIONS,
    /** Copy buffer per connection (bounded memory: maxConnections x this). */
    val bufferBytes: Int = BUFFER_BYTES,
    /** An idle keep-alive connection is closed after this long without a request. */
    val idleTimeoutMs: Int = IDLE_TIMEOUT_MS,
    /** A request that stalls mid-transfer is dropped after this long without a byte. */
    val readTimeoutMs: Int = READ_TIMEOUT_MS,
    /** Preferred port on 127.0.0.1; when it is taken the system picks one. */
    val preferredPort: Int = PREFERRED_PORT,
    /**
     * A keep-alive connection may be evicted only after waiting this long for its next request (and only after it
     * completed one, with no unread byte), so fresh connections never evict each other (T-138 livelock).
     */
    val evictIdleMs: Int = EVICT_IDLE_MS,
    /** Connections taken beyond [maxConnections] when nothing is idle; the hard limit is the sum. */
    val overflowConnections: Int = OVERFLOW_CONNECTIONS,
    /** At the hard limit a new connection waits at most this long, then gets `503` + `Retry-After` and is closed. */
    val admitWaitMs: Int = ADMIT_WAIT_MS,
    /** A response write that makes no progress for this long closes the connection (rate-cap waits do not count). */
    val writeTimeoutMs: Int = WRITE_TIMEOUT_MS,
    /**
     * T-190 (decision 0028): PUT, DELETE, MKCOL, MOVE, COPY, LOCK and UNLOCK answer 403, and OPTIONS advertises DAV
     * class 1 only, so macOS mounts the volume read-only.
     */
    val readOnly: Boolean = false,
    /**
     * T-266 (decision 0035): the small-request lane. The first [smallThresholdBytes] bytes of every request and every
     * response (heads, PROPFIND, small GET/PUT) are paid from a separate bucket of this rate and depth
     * [smallBurstBytes], so they never queue behind a big transfer's debt. 0 = no lane (USB: today's behaviour).
     * The ceiling of the whole server is then [rateBytesPerSec] + this rate.
     */
    val smallRateBytesPerSec: Long = 0,
    val smallBurstBytes: Long = SMALL_BURST_BYTES,
    val smallThresholdBytes: Long = SMALL_THRESHOLD_BYTES,
) {
    companion object {
        const val RATE_BYTES_PER_SEC = 20L * 1000 * 1000
        const val BURST_BYTES = 256L * 1024
        const val MAX_CONNECTIONS = 8
        const val BUFFER_BYTES = 64 * 1024
        const val IDLE_TIMEOUT_MS = 30_000
        const val READ_TIMEOUT_MS = 30_000
        const val PREFERRED_PORT = 47010
        const val EVICT_IDLE_MS = 1_000
        const val OVERFLOW_CONNECTIONS = 4
        const val ADMIT_WAIT_MS = 2_000
        const val WRITE_TIMEOUT_MS = 30_000

        /** Wi-Fi profile (T-266, research 2026-10-05-wifi-files.md section 2): smaller bursts and copy buffer. */
        const val WIFI_BURST_BYTES = 64L * 1024
        const val WIFI_BUFFER_BYTES = 16 * 1024
        const val WIFI_SMALL_RATE_BYTES_PER_SEC = 256_000L
        const val SMALL_BURST_BYTES = 32L * 1024
        const val SMALL_THRESHOLD_BYTES = 32L * 1024

        /**
         * The Wi-Fi profile (decision 0035): total rate [capBytesPerSec] (see [filesCapBytesPerSec]; changeable while
         * running through [DavServer.setRate]), 64 KiB bursts, 16 KiB buffers, the small-request lane on. Connection
         * limits (8 + 4) and the rest are the USB values. The USB profile is the plain constructor defaults.
         */
        fun wifi(capBytesPerSec: Long, readOnly: Boolean = false) = FilesConfig(
            rateBytesPerSec = capBytesPerSec,
            burstBytes = WIFI_BURST_BYTES,
            bufferBytes = WIFI_BUFFER_BYTES,
            readOnly = readOnly,
            smallRateBytesPerSec = WIFI_SMALL_RATE_BYTES_PER_SEC,
        )

        /** HTTP auth user name (PROTOCOL.md 0x09); the password is the per-start token. */
        const val USER = "matebridge"
        const val REALM = "MateBridge"

        /** Request head (request line + headers) limit. */
        const val MAX_HEAD_BYTES = 32 * 1024

        /** Largest XML request body we read (PROPFIND / LOCK); bigger ones are refused. */
        const val MAX_XML_BODY_BYTES = 64 * 1024
    }
}

/**
 * Which part of the shared storage the file server serves (T-190, decision 0028). [folder] is a directory directly under
 * the shared storage; null serves the whole storage ("Tüm depolama", the explicit wide choice).
 */
enum class FilesRoot(val id: String, val label: String, val folder: String?) {
    MATEBRIDGE("matebridge", "MateBridge", "MateBridge"),
    DOWNLOAD("download", "Download", "Download"),
    ALL("all", "Tüm depolama", null),
    ;

    companion object {
        /** Decision 0028: a separate MateBridge folder, created when missing. */
        val DEFAULT = MATEBRIDGE

        /** Unknown or missing ids get [DEFAULT], the narrow choice, never the whole storage. */
        fun parse(id: String?): FilesRoot = entries.firstOrNull { it.id == id } ?: DEFAULT
    }
}

/** The scope one server start uses (T-190): the root choice and the read-only switch. Pure Kotlin. */
data class FilesScope(val root: FilesRoot, val readOnly: Boolean) {
    /** Log fields: the class only, never a path or a name (AGENTS.md privacy). */
    fun logFields(): String = "root=${root.id} ro=${if (readOnly) 1 else 0}"

    /**
     * The directory to serve under [storage] (the shared storage root). [FilesRoot.ALL] is [storage] itself. Any other
     * choice is `storage/<folder>`, created when missing; null when it is not a real directory directly under [storage]
     * afterwards (a file, a symbolic link, a failed mkdir, an I/O error). Never falls back to [storage].
     */
    fun directory(storage: File): File? {
        val folder = root.folder ?: return storage
        return safeSubdirectory(storage, listOf(folder))
    }

    companion object {
        /** Status line when [directory] gave null: the server stays off (never the whole storage). */
        fun missingFolderText(root: FilesRoot): String =
            "Durum: \"${root.folder ?: root.label}\" klasörü açılamadı; paylaşım kapalı"
    }
}

/**
 * The directory [segments] below [storage], one level at a time: each must be a real directory (created when missing),
 * not a symbolic link, and its canonical path must be exactly the parent's canonical path + the name (nothing, no link
 * or mount trick, leads elsewhere). Null otherwise (a file, a link, a failed mkdir, an I/O error); the caller never
 * falls back to a parent or the storage.
 */
fun safeSubdirectory(storage: File, segments: List<String>): File? {
    try {
        // Anchored to the storage's canonical path taken once (Codex T-266): an ancestor replaced by a link between two
        // levels cannot move the expected path along with it.
        val base = storage.canonicalFile
        var cur = storage
        var expected = base
        for (seg in segments) {
            val d = File(cur, seg)
            expected = File(expected, seg)
            if (java.nio.file.Files.isSymbolicLink(d.toPath())) return null
            if (!d.exists() && !d.mkdir() && !d.isDirectory) return null
            if (!d.isDirectory || java.nio.file.Files.isSymbolicLink(d.toPath())) return null
            if (d.canonicalFile != expected) return null
            cur = d
        }
        // Every level once more, after the last one was accepted: no ancestor became a link meanwhile.
        var check = cur
        for (i in segments.indices) {
            if (java.nio.file.Files.isSymbolicLink(check.toPath())) return null
            check = check.parentFile ?: return null
        }
        return if (cur.canonicalFile != expected) null else cur
    } catch (e: IOException) {
        return null
    } catch (e: SecurityException) {
        return null
    } catch (e: java.nio.file.InvalidPathException) {
        return null
    }
}

/**
 * The Wi-Fi file root (decision 0035 addendum, T-266): `storage/MateBridge/Wi-Fi/` and nothing else. Both levels are
 * created when missing; a file, a link or a failure gives null and the server stays off: never the parent
 * `MateBridge`, never the storage. The USB choice ([FilesRoot]) is separate and unchanged; the user's
 * `MateBridge/` stays visible over USB, over Wi-Fi only this sub-folder is.
 */
object WifiFilesRoot {
    val SEGMENTS = listOf("MateBridge", "Wi-Fi")

    /** Log fields: the class only, never a path. */
    const val LOG_FIELDS = "root=wifi"

    fun directory(storage: File): File? = safeSubdirectory(storage, SEGMENTS)
}

/**
 * The share of the Wi-Fi link the file server may use (decision 0035, research section 2): the whole stream stays
 * around 48 Mbps (about three quarters of the 66 Mbps that froze on the device), the rest in MB/s (10^6 bytes):
 * clamp((48 - video_Mbps) / 8, 0.5, 3.0). 30 Mbps gives 2.25 MB/s, 15 gives 3, 60 gives 0.5. An unknown video rate
 * (0 or less) gets [UNKNOWN_VIDEO_BYTES_PER_SEC], not the lowest.
 */
fun filesCapBytesPerSec(videoKbps: Int): Long {
    if (videoKbps <= 0) return UNKNOWN_VIDEO_BYTES_PER_SEC
    val mbps = videoKbps / 1000.0
    return (((48.0 - mbps) / 8.0).coerceIn(0.5, 3.0) * 1_000_000).toLong()
}

const val UNKNOWN_VIDEO_BYTES_PER_SEC = 2_000_000L
