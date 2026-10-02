package dev.matebridge.client.diag

/** T-142: the stall detector (T-120) is opt-in (`--ez stall_diag true`); without it no detector exists at all. */
object StallDiag {
    fun create(enabled: Boolean, readers: StallDetector.Readers): StallDetector? = if (enabled) StallDetector(readers) else null
}
