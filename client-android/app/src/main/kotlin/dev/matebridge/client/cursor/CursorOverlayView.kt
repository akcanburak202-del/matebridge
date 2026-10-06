package dev.matebridge.client.cursor

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.Path
import android.graphics.RectF
import android.os.SystemClock
import android.view.View
import dev.matebridge.client.stream.VideoViewport
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.TimeUnit

/**
 * The local cursor layer (decision 0036, T-276): a transparent, never-touchable View above the video surface that draws
 * the Mac's cursor where the host says it is. The video path and the input path are not touched (a plain, non-clickable
 * View returns false for every touch, so events reach the views below as before). Drawn on the normal hardware-accelerated
 * canvas at vsync: [CursorLink] runs on the reader thread, requests a redraw of just the old and new cursor rectangle with
 * `postInvalidateOnAnimation`, and [onDraw] paints the newest state, never every arrived one. The cost of a draw and the
 * age of a state at its first draw feed [CursorStats].
 *
 * The overlay fills the window (like the pen overlay), so [VideoViewport] coordinates are its own. [ageUs] returns the
 * time from the host's sample to now in microseconds (the PING/PONG clock offset applies), or null when it is not known yet.
 */
class CursorOverlayView(
    context: Context,
    private val nowMs: () -> Long = SystemClock::elapsedRealtime,
    private val ageUs: (hostTimeUs: Long) -> Long? = { null },
) : View(context) {
    /** Decoding runs here: one thread, a short queue; a full queue makes that shape an arrow (never blocks the reader). */
    private val decoder = ThreadPoolExecutor(
        1, 1, 30, TimeUnit.SECONDS, ArrayBlockingQueue(DECODE_QUEUE),
        { r -> Thread(r, "mb-cursor-decode").also { it.isDaemon = true } },
        { _, _ -> throw RejectedExecutionException("cursor decode queue full") },
    ).also { it.allowCoreThreadTimeOut(true) }

    val stats = CursorStats()
    val link = CursorLink(
        CursorShapes<Bitmap>(
            executor = decoder,
            decode = { bytes -> decodePng(bytes) },
            onReady = { postInvalidateOnAnimation() }, // a shape that arrived after its state: redraw (rare)
        ),
        stats, nowMs,
    ) { frame -> onFrameFromReader(frame) }

    @Volatile private var viewport = VideoViewport(0, 0, 0, 0)
    @Volatile private var streamWidthPt = 0

    private val bitmapPaint = Paint(Paint.FILTER_BITMAP_FLAG or Paint.ANTI_ALIAS_FLAG)
    private val fillPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.FILL; color = 0xFFFFFFFF.toInt() }
    private val strokePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE; color = 0xFF000000.toInt(); strokeJoin = Paint.Join.ROUND
    }
    private val dst = RectF()
    private val path = Path()

    /** What the previous [onDraw] painted (read by the reader thread to erase it); a box, or null when nothing was drawn. */
    @Volatile private var lastBox: CursorGeometry.Box? = null
    private var lastDrawnSeq = -1L

    /** The shape drawn last (kept while the next one is still decoding, so the cursor never blinks to an arrow). */
    private var stickyShape: ShapeEntry<Bitmap>? = null

    init {
        isClickable = false
        isFocusable = false
        importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_NO
    }

    /** Where the picture is and how many Mac points wide the stream is; a change repaints everything. */
    fun setGeometry(vp: VideoViewport, streamWidthPt: Int) {
        viewport = vp
        this.streamWidthPt = streamWidthPt
        lastBox = null
        postInvalidateOnAnimation()
    }

    /** Hides the cursor and forgets what was drawn (session end, the layer turned off). UI thread. */
    fun clear() {
        link.slot.clear()
        stickyShape = null
        lastDrawnSeq = -1L
        val old = lastBox
        lastBox = null
        invalidateBox(old, null)
    }

    /** Reader thread (or the engine thread on a reset): a newer state is held, or the layer was cleared (null). */
    private fun onFrameFromReader(frame: CursorFrame?) {
        val old = lastBox
        invalidateBox(old, if (frame != null && frame.visible) boxOf(frame) else null)
        if (frame == null) lastBox = null // nothing will be drawn: the next state is not compared with a stale box
    }

    private fun invalidateBox(a: CursorGeometry.Box?, b: CursorGeometry.Box?) {
        val d = CursorGeometry.dirty(a, b) ?: return
        postInvalidateOnAnimation(d[0], d[1], d[2], d[3])
    }

    /** The rectangle [frame] would be drawn in right now, from the entry the cache holds for its shape (or the arrow). */
    private fun boxOf(frame: CursorFrame): CursorGeometry.Box? {
        val e = link.shapes.lookup(frame.shapeId)
        val vp = viewport
        val pt = streamWidthPt
        return if (e != null && e.status != ShapeStatus.FALLBACK) {
            CursorGeometry.place(vp, pt, frame.x, frame.y, e.widthPt16, e.heightPt16, e.hotXPt16, e.hotYPt16)
        } else {
            CursorGeometry.place(
                vp, pt, frame.x, frame.y,
                BuiltinArrow.WIDTH_PT16, BuiltinArrow.HEIGHT_PT16, BuiltinArrow.HOT_X_PT16, BuiltinArrow.HOT_Y_PT16,
            )
        }
    }

    override fun onDraw(canvas: Canvas) {
        val t0 = System.nanoTime()
        val frame = link.slot.latest()
        val vp = viewport
        if (frame == null) { // nothing held: a session ended or the layer was turned off, so what was remembered goes too
            stickyShape = null
            lastDrawnSeq = -1L
        }
        if (frame == null || !frame.visible || vp.isEmpty || streamWidthPt <= 0) {
            lastBox = null
            return
        }
        val pt = streamWidthPt
        val entry = link.shapes.lookup(frame.shapeId)
        // A pending shape keeps the previous one on screen; a failed, unknown or missing one is the built-in arrow.
        val shape = when {
            entry == null -> null
            entry.status == ShapeStatus.READY -> entry.also { stickyShape = it }
            entry.status == ShapeStatus.PENDING -> stickyShape
            else -> null
        }
        val box: CursorGeometry.Box?
        if (shape != null && shape.bitmap != null) {
            box = CursorGeometry.place(vp, pt, frame.x, frame.y, shape.widthPt16, shape.heightPt16, shape.hotXPt16, shape.hotYPt16)
            if (box != null) {
                dst.set(box.left, box.top, box.right, box.bottom)
                canvas.drawBitmap(shape.bitmap!!, null, dst, bitmapPaint)
            }
        } else if (entry != null && entry.status == ShapeStatus.PENDING) {
            box = null // nothing to show yet and nothing shown before: the next frame draws it
        } else {
            box = drawArrow(canvas, vp, pt, frame)
        }
        lastBox = box
        if (box != null && frame.seq != lastDrawnSeq) {
            lastDrawnSeq = frame.seq
            ageUs(frame.hostTimeUs)?.let { stats.onAge(it) }
        }
        stats.onDraw((System.nanoTime() - t0) / 1000)
    }

    private fun drawArrow(canvas: Canvas, vp: VideoViewport, pt: Int, frame: CursorFrame): CursorGeometry.Box? {
        val box = CursorGeometry.place(
            vp, pt, frame.x, frame.y,
            BuiltinArrow.WIDTH_PT16, BuiltinArrow.HEIGHT_PT16, BuiltinArrow.HOT_X_PT16, BuiltinArrow.HOT_Y_PT16,
        ) ?: return null
        val k = CursorGeometry.pixelsPerPoint(vp, pt)
        val p = BuiltinArrow.POINTS
        path.rewind()
        path.moveTo(box.left + p[0] * k, box.top + p[1] * k)
        var i = 2
        while (i < p.size) {
            path.lineTo(box.left + p[i] * k, box.top + p[i + 1] * k)
            i += 2
        }
        path.close()
        strokePaint.strokeWidth = maxOf(1f, k)
        canvas.drawPath(path, fillPaint)
        canvas.drawPath(path, strokePaint)
        return box
    }

    private companion object {
        const val DECODE_QUEUE = 8

        fun decodePng(bytes: ByteArray): Bitmap? {
            val o = BitmapFactory.Options().apply {
                inPreferredConfig = Bitmap.Config.ARGB_8888
                inScaled = false
            }
            return BitmapFactory.decodeByteArray(bytes, 0, bytes.size, o)
        }
    }
}
