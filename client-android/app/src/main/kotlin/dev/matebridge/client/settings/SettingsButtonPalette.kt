package dev.matebridge.client.settings

/**
 * Explicit button colors for both settings panels (T-107). Nothing is left to the system theme: on HarmonyOS the
 * default Material button background is light, which made white labels unreadable. Colors are ARGB ints so this stays
 * plain JVM-testable Kotlin.
 */
object SettingsButtonPalette {
    const val NORMAL: Int = 0xFF3A3A42.toInt()
    const val NORMAL_PRESSED: Int = 0xFF5A5A66.toInt()
    const val SELECTED: Int = 0xFF2E7DFF.toInt()
    const val SELECTED_PRESSED: Int = 0xFF1F5FCC.toInt()
    const val TEXT: Int = 0xFFFFFFFF.toInt()

    /** Background for a button in the given state. Pressed always differs from its resting color. */
    fun colorFor(selected: Boolean, pressed: Boolean): Int = when {
        selected && pressed -> SELECTED_PRESSED
        selected -> SELECTED
        pressed -> NORMAL_PRESSED
        else -> NORMAL
    }

    /**
     * (selected, pressed) pairs in StateListDrawable match order: the first matching entry wins, so the most specific
     * states come first and the (false, false) default comes last.
     */
    val stateOrder: List<Pair<Boolean, Boolean>> = listOf(
        true to true,
        false to true,
        true to false,
        false to false,
    )
}
