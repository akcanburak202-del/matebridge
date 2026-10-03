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
        val d = File(storage, folder)
        return try {
            if (java.nio.file.Files.isSymbolicLink(d.toPath())) return null
            if (!d.exists() && !d.mkdir() && !d.isDirectory) return null
            if (!d.isDirectory || java.nio.file.Files.isSymbolicLink(d.toPath())) return null
            // The canonical form must be exactly storage/<folder>: nothing (a link, a mount trick) leads elsewhere.
            if (d.canonicalFile != File(storage.canonicalFile, folder)) return null
            d
        } catch (e: IOException) {
            null
        } catch (e: SecurityException) {
            null
        } catch (e: java.nio.file.InvalidPathException) {
            null
        }
    }

    companion object {
        /** Status line when [directory] gave null: the server stays off (never the whole storage). */
        fun missingFolderText(root: FilesRoot): String =
            "Durum: \"${root.folder ?: root.label}\" klasörü açılamadı; paylaşım kapalı"
    }
}
