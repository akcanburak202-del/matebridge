package dev.matebridge.client.stream

import kotlin.math.abs

/** One entry of Display.getSupportedModes(), reduced to what the choice needs. */
data class DisplayModeInfo(val id: Int, val width: Int, val height: Int, val refreshHz: Float)

/** Picks the display mode to request while streaming. Pure Kotlin. */
object DisplayModePicker {
    /**
     * Among modes with the same resolution as [current], the one whose refresh rate is closest to
     * [targetHz] (ties: the higher rate). Returns null when [targetHz] <= 0 (do not touch the mode) or no
     * mode has the current resolution.
     */
    fun pick(modes: List<DisplayModeInfo>, current: DisplayModeInfo, targetHz: Float): DisplayModeInfo? {
        if (targetHz <= 0f) return null
        val sameSize = modes.filter { it.width == current.width && it.height == current.height }
        return sameSize.minWithOrNull(
            compareBy<DisplayModeInfo> { abs(it.refreshHz - targetHz) }.thenByDescending { it.refreshHz },
        )
    }
}
