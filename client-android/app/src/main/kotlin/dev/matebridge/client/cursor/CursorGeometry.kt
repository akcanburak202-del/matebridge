package dev.matebridge.client.cursor

import dev.matebridge.client.stream.VideoViewport

/**
 * Where a cursor image lands on the tablet (decision 0036, PROTOCOL.md 0x0C/0x0D). All values are in the overlay's
 * coordinate space, the same one [VideoViewport] uses (the overlay fills the window).
 */
object CursorGeometry {
    /** A float rectangle: [left], [top], [width], [height]. */
    class Box(val left: Float, val top: Float, val width: Float, val height: Float) {
        val right get() = left + width
        val bottom get() = top + height
    }

    /** Pixels per Mac point: the video surface width over `STREAM_CONFIG.width_pt`; 0 while either is unknown. */
    fun pixelsPerPoint(viewport: VideoViewport, streamWidthPt: Int): Float =
        if (viewport.isEmpty || streamWidthPt <= 0) 0f else viewport.width / streamWidthPt

    /** Hotspot position in the overlay for normalized [x] (0 = left edge of the picture, 65535 = right edge). */
    fun hotspotX(viewport: VideoViewport, x: Int): Float = viewport.left + x.coerceIn(0, 65535) / 65535f * viewport.width

    /** Hotspot position in the overlay for normalized [y] (0 = top edge of the picture, 65535 = bottom edge). */
    fun hotspotY(viewport: VideoViewport, y: Int): Float = viewport.top + y.coerceIn(0, 65535) / 65535f * viewport.height

    /**
     * Rectangle of a shape of [widthPt16] x [heightPt16] (1/16 pt) with hotspot ([hotXPt16], [hotYPt16]) whose hotspot is at
     * normalized ([x], [y]); null when the viewport, the stream width or the shape size is unknown or empty.
     */
    fun place(
        viewport: VideoViewport, streamWidthPt: Int, x: Int, y: Int,
        widthPt16: Int, heightPt16: Int, hotXPt16: Int, hotYPt16: Int,
    ): Box? {
        val scale = pixelsPerPoint(viewport, streamWidthPt)
        if (scale <= 0f || widthPt16 <= 0 || heightPt16 <= 0) return null
        val k = scale / 16f
        return Box(
            hotspotX(viewport, x) - hotXPt16 * k,
            hotspotY(viewport, y) - hotYPt16 * k,
            widthPt16 * k,
            heightPt16 * k,
        )
    }

    /** Integer dirty rectangle (left, top, right, bottom) covering [a] and [b] (either may be null), grown by [pad] pixels. */
    fun dirty(a: Box?, b: Box?, pad: Int = 2): IntArray? {
        if (a == null && b == null) return null
        var l = Float.MAX_VALUE
        var t = Float.MAX_VALUE
        var r = -Float.MAX_VALUE
        var bt = -Float.MAX_VALUE
        for (box in listOf(a, b)) {
            if (box == null) continue
            l = minOf(l, box.left)
            t = minOf(t, box.top)
            r = maxOf(r, box.right)
            bt = maxOf(bt, box.bottom)
        }
        return intArrayOf(
            Math.floor(l.toDouble()).toInt() - pad, Math.floor(t.toDouble()).toInt() - pad,
            Math.ceil(r.toDouble()).toInt() + pad, Math.ceil(bt.toDouble()).toInt() + pad,
        )
    }
}

/**
 * The built-in arrow (decision 0036: drawn for an unknown shape id or format, or while nothing was ever decoded).
 * Polygon points in Mac points from the hotspot (the tip); 12 x 19 pt, white fill, black outline, like the system arrow.
 */
object BuiltinArrow {
    const val WIDTH_PT16 = 12 * 16
    const val HEIGHT_PT16 = 19 * 16
    const val HOT_X_PT16 = 0
    const val HOT_Y_PT16 = 0

    /** x0, y0, x1, y1, ... in points. */
    val POINTS = floatArrayOf(0f, 0f, 0f, 16f, 3.6f, 12.6f, 6.4f, 19f, 8.6f, 18f, 5.9f, 11.7f, 10.6f, 11.7f)
}
