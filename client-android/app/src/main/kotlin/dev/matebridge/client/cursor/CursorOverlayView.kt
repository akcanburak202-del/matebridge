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
import dev.matebridge.client.protocol.Message
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
 * one guarded vsync task ([RedrawGate]), and [onDraw] paints the newest state, never every arrived one. The cost of a draw and the
 * age of a state at its first draw feed [CursorStats].
 *
 * The overlay fills the window (like the pen overlay), so [VideoViewport] coordinates are its own. [ageUs] returns the
 * time from the host's sample to now in microseconds (the PING/PONG clock offset applies), or null when it is not known yet.
 */
class CursorOverlayView(
    context: Context,
    private val nowMs: () -> Long = SystemClock::elapsedRealtime,
    private val ageUs: (hostTimeUs: Long) -> Long? = { null },
    /** T-278: host time -> client monotonic microseconds (the clock offset), null while unknown. */
    hostToClientUs: (hostTimeUs: Long) -> Long? = { null },
    /** T-278: one-way delay estimate in microseconds (best RTT / 2), null while unknown. */
    oneWayUs: () -> Long? = { null },
    /** T-278: false (`--ez cursor_predict false`) draws the host's position as in v1. */
    predict: Boolean = true,
) : View(context) {
    /** Decoding runs here: one thread, a short queue; a full queue makes that shape an arrow (never blocks the reader). */
    private val decoder = ThreadPoolExecutor(
        1, 1, 30, TimeUnit.SECONDS, ArrayBlockingQueue(DECODE_QUEUE),
        { r -> Thread(r, "mb-cursor-decode").also { it.isDaemon = true } },
        { _, _ -> throw RejectedExecutionException("cursor decode queue full") },
    ).also { it.allowCoreThreadTimeOut(true) }

    val stats = CursorStats()
    private val redraw = RedrawGate()
    val predictor = CursorPredictor(hostToClientUs, oneWayUs, stats).also { it.setAllowed(predict) }
    val link = CursorLink(
        CursorShapes<Bitmap>(
            executor = decoder,
            decode = { bytes -> decodePng(bytes) },
            onReady = { requestRedraw(null, full = true) }, // a shape that arrived after its state: redraw (rare)
        ),
        stats, nowMs, predictor,
    ) { frame -> onFrameFromReader(frame) }

    /** The position the redraw task chose for this frame; [onDraw] paints exactly it (its dirty area was computed from it). */
    private class Frozen(val frame: CursorFrame, val x: Int, val y: Int, val animating: Boolean, val atUs: Long)

    private var frozen: Frozen? = null
    private val predicted = CursorPredictor.Result()

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
    fun setGeometry(vp: VideoViewport, streamWidthPt: Int, streamHeightPt: Int = 0) {
        viewport = vp
        this.streamWidthPt = streamWidthPt
        // The picture's own aspect gives the height when the stream config did not (never expected).
        val h = if (streamHeightPt > 0) streamHeightPt
        else if (!vp.isEmpty && streamWidthPt > 0) (streamWidthPt * vp.height / vp.width).toInt() else 0
        predictor.setStream(streamWidthPt, h)
        frozen = null
        lastBox = null
        requestRedraw(null, full = true)
    }

    /** Hides the cursor and forgets what was drawn (session end, the layer turned off). UI thread. */
    fun clear() {
        link.slot.clear()
        frozen = null
        stickyShape = null
        lastDrawnSeq = -1L
        val old = lastBox
        lastBox = null
        invalidateBox(old, null)
    }

    /** Reader thread (or the engine thread on a reset): a newer state is held, or the layer was cleared (null). */
    private fun onFrameFromReader(frame: CursorFrame?) {
        val old = lastBox
        invalidateBox(old, if (frame != null && frame.visible) boxOf(frame, frame.x, frame.y) else null)
        if (frame == null) lastBox = null // nothing will be drawn: the next state is not compared with a stale box
    }

    private fun invalidateBox(a: CursorGeometry.Box?, b: CursorGeometry.Box?) {
        requestRedrawAlways(CursorGeometry.dirty(a, b))
    }

    /**
     * At most one redraw is ever pending ([RedrawGate]): states that arrive while the UI thread is busy only widen the dirty
     * rectangle, and the single task invalidates once. Any thread.
     */
    private fun requestRedraw(rect: IntArray?, full: Boolean) {
        if (redraw.request(rect, full)) postOnAnimation(redrawTask)
    }

    /**
     * A new accepted state (or a clear) always gets a frame, even when there is no rectangle to invalidate: a state that
     * hides a cursor which was never drawn has no old box, but a draw prepared for the previous state may be pending and
     * must see the newest state (T-278 review).
     */
    private fun requestRedrawAlways(rect: IntArray?) {
        if (rect != null) requestRedraw(rect, full = false)
        else if (redraw.requestRecompute()) postOnAnimation(redrawTask)
    }

    /**
     * T-278, UI thread: the app just sent [msg] to the host. When it moves the cursor, the predicted position changes now, so
     * a redraw is asked for; the task works out where (at vsync, just before the draw).
     */
    fun onInputSent(msg: Message, gen: Int) {
        if (predictor.onSent(msg, System.nanoTime() / 1000, gen) && redraw.requestRecompute()) postOnAnimation(redrawTask)
    }

    /**
     * Runs at the start of a frame (animation callback), before the draw of that frame. With a prediction the position is
     * fixed here: the dirty area is the old box united with the new one, and [onDraw] paints the same position, so what is
     * cleared and what is drawn always agree (a hardware canvas repaints only the invalidated area).
     */
    @Suppress("DEPRECATION") // the rectangle is a hint only on API 21+; the single invalidate is what matters
    private val redrawTask = Runnable {
        val d = redraw.take() ?: return@Runnable
        var rect: IntArray? = if (d.full || !d.hasRect) null else intArrayOf(d.left, d.top, d.right, d.bottom)
        frozen = null
        val frame = link.slot.latest()
        if (frame != null && frame.visible && !viewport.isEmpty && streamWidthPt > 0 && predictor.active) {
            val nowUs = System.nanoTime() / 1000
            if (predictor.advance(frame.seq, nowUs, predicted)) {
                frozen = Frozen(frame, predicted.xNorm, predicted.yNorm, predicted.animating, nowUs)
                rect = unite(rect, CursorGeometry.dirty(lastBox, boxOf(frame, predicted.xNorm, predicted.yNorm)))
            } else {
                // No prediction (suspended by pen or touch, hidden): the host's own position; what was predicted is erased.
                rect = unite(rect, CursorGeometry.dirty(lastBox, boxOf(frame, frame.x, frame.y)))
            }
        }
        if (d.full) invalidate() else if (rect != null) invalidate(rect[0], rect[1], rect[2], rect[3])
    }

    private fun unite(a: IntArray?, b: IntArray?): IntArray? = when {
        a == null -> b
        b == null -> a
        else -> intArrayOf(minOf(a[0], b[0]), minOf(a[1], b[1]), maxOf(a[2], b[2]), maxOf(a[3], b[3]))
    }

    /** The rectangle [frame]'s shape would be drawn in at normalized ([x], [y]), from the entry the cache holds (or the arrow). */
    private fun boxOf(frame: CursorFrame, x: Int, y: Int): CursorGeometry.Box? {
        val e = link.shapes.lookup(frame.shapeId)
        val vp = viewport
        val pt = streamWidthPt
        return if (e != null && e.status != ShapeStatus.FALLBACK) {
            CursorGeometry.place(vp, pt, x, y, e.widthPt16, e.heightPt16, e.hotXPt16, e.hotYPt16)
        } else {
            CursorGeometry.place(
                vp, pt, x, y,
                BuiltinArrow.WIDTH_PT16, BuiltinArrow.HEIGHT_PT16, BuiltinArrow.HOT_X_PT16, BuiltinArrow.HOT_Y_PT16,
            )
        }
    }

    override fun onDraw(canvas: Canvas) {
        val t0 = System.nanoTime()
        // The task's frozen position of this frame when there is one (fresh and the layer still predicts), else the newest state.
        val fz = frozen
        frozen = null
        val latest = link.slot.latest()
        // Only for the state that is still the newest (a hide, a new state or a session reset since then discards it).
        val useFrozen = fz != null && predictor.active && FrozenFrame.usable(fz.frame, latest, t0 / 1000 - fz.atUs, FROZEN_MAX_US)
        val frame = if (useFrozen) fz!!.frame else latest
        var posX = if (useFrozen) fz!!.x else frame?.x ?: 0
        var posY = if (useFrozen) fz!!.y else frame?.y ?: 0
        var animating = useFrozen && fz!!.animating
        if (!useFrozen && frame != null && frame.visible && predictor.active && streamWidthPt > 0 &&
            predictor.advance(frame.seq, t0 / 1000, predicted)
        ) { // a draw the task did not prepare (the system asked): still never show the stale host position of a moving cursor
            posX = predicted.xNorm
            posY = predicted.yNorm
            animating = predicted.animating
        }
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
            box = CursorGeometry.place(vp, pt, posX, posY, shape.widthPt16, shape.heightPt16, shape.hotXPt16, shape.hotYPt16)
            if (box != null) {
                dst.set(box.left, box.top, box.right, box.bottom)
                canvas.drawBitmap(shape.bitmap!!, null, dst, bitmapPaint)
            }
        } else if (entry != null && entry.status == ShapeStatus.PENDING) {
            box = null // nothing to show yet and nothing shown before: the next frame draws it
        } else {
            box = drawArrow(canvas, vp, pt, posX, posY)
        }
        lastBox = box
        if (box != null && frame.seq != lastDrawnSeq) {
            lastDrawnSeq = frame.seq
            ageUs(frame.hostTimeUs)?.let { stats.onAge(it) }
        }
        stats.onDraw((System.nanoTime() - t0) / 1000)
        // Still easing a correction or waiting for the host to confirm sent input: the next frame moves it again.
        if (animating && redraw.requestRecompute()) postOnAnimation(redrawTask)
    }

    private fun drawArrow(canvas: Canvas, vp: VideoViewport, pt: Int, x: Int, y: Int): CursorGeometry.Box? {
        val box = CursorGeometry.place(
            vp, pt, x, y,
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

        /** A position fixed by the redraw task is used by the draw of the same frame only (a few ms later); older is dropped. */
        const val FROZEN_MAX_US = 50_000L

        fun decodePng(bytes: ByteArray): Bitmap? {
            val o = BitmapFactory.Options().apply {
                inPreferredConfig = Bitmap.Config.ARGB_8888
                inScaled = false
            }
            return BitmapFactory.decodeByteArray(bytes, 0, bytes.size, o)
        }
    }
}
