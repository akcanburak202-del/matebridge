package dev.matebridge.client.audio

/**
 * T-110: when to grow the output buffer by one burst (pure). Decided once per stats window.
 *
 *  - `underflow`: a write found the headroom at or below zero ([HeadroomMeter.Window.underflowEst] > 0).
 *  - `headroom`: the headroom fell below one burst (the writer was away from the output for over a burst; the device
 *    plays stale data if it is late once more). Normally the headroom before a write is about the buffer size.
 *    T-114: on AAudio the headroom comes from the output's timestamp where it can ([HeadroomEstimator]); it may then
 *    read high by the device's presentation delay, so this rule errs towards not growing.
 *  - `xrun`: the output reported underruns (the pre-T-110 rule, for devices whose HAL reports them; this MMAP HAL
 *    reports none).
 *
 * At most one burst per window, never above [maxFrames], never shrinks. The first window after an output is opened is
 * ignored ([warm] false): its start is not steady state.
 */
object OutBufGrowth {
    enum class Reason(val logName: String) { UNDERFLOW("underflow"), HEADROOM("headroom"), XRUN("xrun") }

    /** The reason to grow now, or null (no reason, not warm, or already at the limit). */
    fun decide(w: HeadroomMeter.Window, xrunDelta: Int, burst: Int, bufFrames: Int, maxFrames: Int, warm: Boolean): Reason? {
        if (!warm || burst <= 0 || bufFrames + burst > maxFrames) return null
        return when {
            w.underflowEst > 0 -> Reason.UNDERFLOW
            w.headroomMinFrames != null && w.headroomMinFrames < burst -> Reason.HEADROOM
            xrunDelta > 0 -> Reason.XRUN
            else -> null
        }
    }
}
