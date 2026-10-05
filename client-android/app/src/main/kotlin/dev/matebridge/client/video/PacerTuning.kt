package dev.matebridge.client.video

/**
 * T-251: developer knobs of the [AdaptivePacer] (`--ei pace_dcap_half N`, `--ez pace_feedback false`, behind
 * `--ez dev true`). [STANDARD] changes nothing.
 *
 * [dCapHalf]: the cap of D for lockable cadences (n = 1 and n = 2) in half panel periods; null = the built-in caps
 * (n = 1: 2 half periods, n = 2: [AdaptivePacer.MAX_D_HALF_PERIODS]). The latency bounds grow with a raised cap, so a
 * larger D is not immediately folded away by them. [feedback] false pins the skip feedback level at 0.
 */
data class PacerTuning(val dCapHalf: Int? = null, val feedback: Boolean = true) {
    val isStandard: Boolean get() = dCapHalf == null && feedback

    /** D cap in half periods for cadence [n] (1 or 2; other values behave like 2, the unlocked cap). */
    fun capHalfFor(n: Long): Long = dCapHalf?.toLong() ?: builtInCapHalf(n)

    /** Half periods the latency bounds are widened by: only a cap above the built-in one widens them. */
    fun boundExtraHalf(n: Long): Long = (capHalfFor(n) - builtInCapHalf(n)).coerceAtLeast(0)

    /** `-` when standard, else `pace_dcap_half:N;pace_feedback:0` (keys and numbers only). */
    fun logFields(): String {
        val parts = buildList {
            dCapHalf?.let { add("pace_dcap_half:$it") }
            if (!feedback) add("pace_feedback:0")
        }
        return if (parts.isEmpty()) "-" else parts.joinToString(";")
    }

    companion object {
        val STANDARD = PacerTuning()
        const val MAX_CAP_HALF = 8

        private fun builtInCapHalf(n: Long): Long = if (n == 1L) 2L else AdaptivePacer.MAX_D_HALF_PERIODS

        /** [dCapHalf] raw value or null; values below 1 are ignored (standard), above [MAX_CAP_HALF] are clamped. */
        fun parse(dCapHalf: Int?, feedback: Boolean): PacerTuning =
            PacerTuning(dCapHalf?.takeIf { it >= 1 }?.coerceAtMost(MAX_CAP_HALF), feedback)
    }
}

/** T-251: the pacer's D components for `render ev=present` (`fb_level= d_jitter_us= d_extra_us= d_cap_us=`). */
data class PacerDiag(val level: Int, val jitterUs: Long, val extraUs: Long, val capUs: Long) {
    fun logFields() = "fb_level=$level d_jitter_us=$jitterUs d_extra_us=$extraUs d_cap_us=$capUs"

    companion object {
        /** No adaptive pacer running (fixed jitter buffer). */
        const val NONE = "fb_level=- d_jitter_us=- d_extra_us=- d_cap_us=-"
    }
}
