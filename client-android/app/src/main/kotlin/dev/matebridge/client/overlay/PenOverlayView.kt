package dev.matebridge.client.overlay

import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.os.SystemClock
import android.view.View
import dev.matebridge.client.input.PenFrame
import dev.matebridge.client.input.PenInkListener
import dev.matebridge.client.stream.VideoViewport

/**
 * Transparent, never-touchable layer above the video surface that shows the pen locally (T-056): a small ring at the
 * pen position and a short, fading trail while drawing. Drawn on the normal hardware-accelerated canvas at vsync; the
 * video surface is not touched. The same root coordinate space as [VideoViewport], the view fills the root.
 */
class PenOverlayView(context: Context) : View(context), PenInkListener {
    val model = PenInkModel()
    private val density = context.resources.displayMetrics.density
    private val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = NEUTRAL // mid grey: visible on light and dark content alike
        strokeCap = Paint.Cap.ROUND
    }
    private var viewport = VideoViewport(0, 0, 0, 0)
    private var drawCanvas: Canvas? = null

    private val segmentDrawer = InkSegmentVisitor { x0, y0, x1, y1, pressure, alpha ->
        paint.style = Paint.Style.STROKE
        paint.strokeWidth = PenInkStyle.widthDp(pressure) * density
        paint.alpha = (alpha * 255f + 0.5f).toInt().coerceIn(0, 255)
        drawCanvas?.drawLine(x0, y0, x1, y1, paint)
    }

    init {
        isClickable = false
        isFocusable = false
        importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_NO
    }

    /** Where the picture is; drawing is clipped to it so nothing shows in the letterbox bands. */
    fun setVideoViewport(vp: VideoViewport) {
        viewport = vp
        postInvalidateOnAnimation()
    }

    override fun onPenFrame(f: PenFrame, eraser: Boolean) {
        model.onPenFrame(f, eraser)
        postInvalidateOnAnimation()
    }

    override fun onPenClear() {
        model.clear()
        postInvalidateOnAnimation()
    }

    override fun onDraw(canvas: Canvas) {
        if (viewport.isEmpty) return
        val now = SystemClock.uptimeMillis()
        canvas.save()
        canvas.clipRect(viewport.left, viewport.top, viewport.left + viewport.width, viewport.top + viewport.height)
        drawCanvas = canvas
        paint.color = NEUTRAL
        model.forEachSegment(now, segmentDrawer)
        drawCanvas = null
        if (model.showDot) {
            paint.color = NEUTRAL
            paint.alpha = 210
            paint.strokeWidth = 1.5f * density
            if (model.eraser) {
                paint.style = Paint.Style.STROKE
                canvas.drawCircle(model.dotX, model.dotY, PenInkStyle.ERASER_RING_RADIUS_DP * density, paint)
            } else {
                paint.style = if (model.inContact) Paint.Style.FILL else Paint.Style.STROKE
                canvas.drawCircle(model.dotX, model.dotY, PenInkStyle.DOT_RADIUS_DP * density, paint)
            }
        }
        canvas.restore()
        if (model.hasLiveTrail(now)) postInvalidateOnAnimation()
    }

    private companion object {
        const val NEUTRAL = 0xFF8C8C8C.toInt()
    }
}
