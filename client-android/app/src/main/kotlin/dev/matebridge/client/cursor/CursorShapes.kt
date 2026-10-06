package dev.matebridge.client.cursor

import dev.matebridge.client.protocol.CursorShape
import java.util.concurrent.Executor
import java.util.concurrent.RejectedExecutionException

/** What a cached shape can be drawn as. */
enum class ShapeStatus {
    /** The PNG is being decoded in the background; the previous shape stays on screen meanwhile. */
    PENDING,

    /** [ShapeEntry.bitmap] is ready. */
    READY,

    /** Unknown format, a PNG that failed the size check or the decoder, or no background capacity: the built-in arrow is drawn. */
    FALLBACK,
}

/** One cached cursor shape (sizes and hotspot in 1/16 Mac points, as on the wire). [B] is the platform bitmap type. */
class ShapeEntry<B : Any>(
    val id: Long,
    val widthPt16: Int,
    val heightPt16: Int,
    val hotXPt16: Int,
    val hotYPt16: Int,
) {
    @Volatile var bitmap: B? = null
        internal set
    @Volatile var status: ShapeStatus = ShapeStatus.PENDING
        internal set
}

/**
 * Shapes of one session (decision 0036, PROTOCOL.md 0x0C): an LRU of at least 64 entries, unknown formats included (they
 * keep their id and draw the built-in arrow). PNGs are decoded on [executor], never on the caller's thread: pass a
 * single-thread executor with a small bounded queue; a rejected task makes the entry [ShapeStatus.FALLBACK] (the cursor
 * is then an arrow, never blocked or missing). [decode] gets bytes whose header passed [PngInfo] (at most
 * [MAX_PIXELS] on each side) and returns null when it cannot decode. [onReady] runs on the decode thread once a pending entry
 * is decided, [ShapeStatus.READY] or [ShapeStatus.FALLBACK] (to redraw). Thread-safe.
 */
class CursorShapes<B : Any>(
    capacity: Int = ShapeCache.DEFAULT_CAPACITY,
    private val executor: Executor,
    private val decode: (ByteArray) -> B?,
    private val onReady: () -> Unit = {},
) {
    private val cache = ShapeCache<ShapeEntry<B>>(capacity)

    /** Registers the shape (a repeated id replaces the older image) and starts decoding a PNG. */
    fun onShape(s: CursorShape) {
        if (s.shapeId == 0L) return // id 0 is not used on the wire
        val entry = ShapeEntry<B>(s.shapeId, s.widthPt16, s.heightPt16, s.hotXPt16, s.hotYPt16)
        cache.put(s.shapeId, entry)
        if (s.format != CursorShape.FORMAT_PNG) {
            entry.status = ShapeStatus.FALLBACK
            return
        }
        val bytes = s.data.value
        val dims = PngInfo.dimensions(bytes)
        if (dims == null || dims.first > MAX_PIXELS || dims.second > MAX_PIXELS) {
            entry.status = ShapeStatus.FALLBACK
            return
        }
        try {
            executor.execute { decodeInto(entry, bytes) }
        } catch (e: RejectedExecutionException) {
            entry.status = ShapeStatus.FALLBACK
        }
    }

    private fun decodeInto(entry: ShapeEntry<B>, bytes: ByteArray) {
        val bmp = try {
            decode(bytes)
        } catch (e: RuntimeException) {
            null
        }
        if (cache.peek(entry.id) !== entry) return // forgotten (cleared, evicted or replaced) while decoding
        if (bmp == null) {
            entry.status = ShapeStatus.FALLBACK
        } else {
            entry.bitmap = bmp
            entry.status = ShapeStatus.READY
        }
        onReady()
    }

    /** The entry for [id] counted as a use (a `CURSOR_STATE` that names it), or null when unknown. */
    fun use(id: Long): ShapeEntry<B>? = cache.touch(id)

    /** The entry for [id] without counting a use (drawing). */
    fun lookup(id: Long): ShapeEntry<B>? = cache.peek(id)

    val size: Int get() = cache.size

    /** Forgets every shape (session end or a new connection: the host's "client has it" set is per session). */
    fun clear() = cache.clear()

    companion object {
        /** The host sends at most 128 x 128 pixels; double that is tolerated, anything larger is refused before decoding. */
        const val MAX_PIXELS = 256
    }
}
