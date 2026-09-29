package dev.matebridge.client.stream

import dev.matebridge.client.protocol.Coords
import kotlin.math.min

/**
 * The single place that maps view pixels to normalized video-surface coordinates
 * (PROTOCOL.md section 1). The video is fitted (aspect preserved) and centered in a view of
 * [viewW]x[viewH]; the letterbox bands are excluded and points outside clamp to the edge.
 */
class VideoViewport(val viewW: Int, val viewH: Int, videoW: Int, videoH: Int) {
    val left: Float
    val top: Float
    val width: Float
    val height: Float

    init {
        if (viewW <= 0 || viewH <= 0 || videoW <= 0 || videoH <= 0) {
            left = 0f; top = 0f; width = 0f; height = 0f
        } else {
            val scale = min(viewW.toFloat() / videoW, viewH.toFloat() / videoH)
            width = videoW * scale
            height = videoH * scale
            left = (viewW - width) / 2f
            top = (viewH - height) / 2f
        }
    }

    val isEmpty get() = width <= 0f || height <= 0f

    fun normX(px: Float): Int = Coords.normalize(px, left, width)
    fun normY(py: Float): Int = Coords.normalize(py, top, height)
}
