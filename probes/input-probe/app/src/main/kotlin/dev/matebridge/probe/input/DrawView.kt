package dev.matebridge.probe.input

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.view.MotionEvent
import android.view.View

/** Freehand area: line width follows pressure. Uses every batched sample. */
class DrawView(context: Context) : View(context) {
    private var bitmap: Bitmap? = null
    private var bmpCanvas: Canvas? = null
    private val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.WHITE
        strokeCap = Paint.Cap.ROUND
    }
    private var lastX = 0f
    private var lastY = 0f
    private var drawing = false

    init {
        setBackgroundColor(Color.rgb(24, 24, 28))
        isFocusable = true
        isFocusableInTouchMode = true
    }

    override fun onSizeChanged(w: Int, h: Int, ow: Int, oh: Int) {
        if (w <= 0 || h <= 0) return
        bitmap = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
        bmpCanvas = Canvas(bitmap!!)
    }

    fun clear() {
        bitmap?.eraseColor(Color.TRANSPARENT)
        invalidate()
    }

    override fun onDraw(canvas: Canvas) {
        bitmap?.let { canvas.drawBitmap(it, 0f, 0f, null) }
    }

    private fun segment(x: Float, y: Float, pressure: Float) {
        val c = bmpCanvas ?: return
        paint.strokeWidth = 1.5f + pressure * 24f
        if (drawing) c.drawLine(lastX, lastY, x, y, paint) else c.drawPoint(x, y, paint)
        lastX = x
        lastY = y
        drawing = true
    }

    private fun isPen(e: MotionEvent, i: Int): Boolean {
        val t = e.getToolType(i)
        return t == MotionEvent.TOOL_TYPE_STYLUS || t == MotionEvent.TOOL_TYPE_ERASER
    }

    override fun onTouchEvent(e: MotionEvent): Boolean {
        when (e.actionMasked) {
            MotionEvent.ACTION_DOWN -> drawing = false
            MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> { drawing = false; return true }
        }
        // Draw only from the first stylus pointer; ignore finger and palm.
        var i = -1
        for (k in 0 until e.pointerCount) if (isPen(e, k)) { i = k; break }
        if (i < 0) return true
        for (h in 0 until e.historySize) {
            segment(e.getHistoricalX(i, h), e.getHistoricalY(i, h), e.getHistoricalPressure(i, h))
        }
        segment(e.getX(i), e.getY(i), e.getPressure(i))
        invalidate()
        return true
    }
}
