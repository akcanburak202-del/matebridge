package dev.matebridge.client.stream

import dev.matebridge.client.protocol.Coords
import kotlin.math.min

/**
 * The single place that maps view pixels to normalized video-surface coordinates
 * (PROTOCOL.md section 1). The video is fitted (aspect preserved) and centered in a view of
 * [viewW]x[viewH] placed at ([originX], [originY]); the letterbox bands are excluded and points
 * outside clamp to the edge. [left]/[top] are in the same coordinate space as the origin.
 */
class VideoViewport(
    val viewW: Int, val viewH: Int, videoW: Int, videoH: Int,
    originX: Float = 0f, originY: Float = 0f,
) {
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
            left = originX + (viewW - width) / 2f
            top = originY + (viewH - height) / 2f
        }
    }

    val isEmpty get() = width <= 0f || height <= 0f

    fun normX(px: Float): Int = Coords.normalize(px, left, width)
    fun normY(py: Float): Int = Coords.normalize(py, top, height)

    companion object {
        /** Viewport for a laid-out video view of exactly this rectangle (no letterbox inside it). */
        fun ofRect(left: Int, top: Int, width: Int, height: Int) =
            VideoViewport(width, height, width, height, left.toFloat(), top.toFloat())
    }
}
