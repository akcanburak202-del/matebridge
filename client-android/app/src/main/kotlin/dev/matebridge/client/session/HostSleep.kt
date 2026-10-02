package dev.matebridge.client.session

/**
 * T-133: the Mac said BYE(HOST_SLEEP) (PROTOCOL.md 0x04). Every packet that reaches a sleeping Mac (PING, reconnect,
 * Bonjour resolve, a USB probe through `adb reverse`, a magic packet) dark-wakes it, so while [asleep] nothing automatic
 * runs: no reconnect, no discovery, no AUTO USB attempt, no automatic wake. A user action ("Bağlan", "Mac'i uyandır") or
 * the app coming back to the foreground clears it and the normal flow (T-129 wake included) starts again.
 * Pure; main thread only.
 */
class HostSleepGate {
    var asleep = false
        private set

    /** A session state; returns true exactly when it puts the gate to sleep (Failed(HOST_SLEEP) while awake). */
    fun onUi(state: SessionUi): Boolean {
        if (asleep || !isHostSleep(state)) return false
        asleep = true
        return true
    }

    /** Leaves the sleep state (foreground, "Bağlan", "Mac'i uyandır"). Returns whether it was asleep. */
    fun clear(): Boolean {
        val was = asleep
        asleep = false
        return was
    }

    /** Automatic reconnects, discovery, AUTO USB attempts and automatic wake are allowed. */
    val allowsAuto: Boolean get() = !asleep

    companion object {
        /** `ev=host_sleep_clear reason=…` values. */
        const val REASON_FOREGROUND = "foreground"
        const val REASON_CONNECT = "connect"
        const val REASON_WAKE = "wake"

        fun isHostSleep(state: SessionUi): Boolean = state is SessionUi.Failed && state.cause == SessionUi.Cause.HOST_SLEEP
    }
}

/**
 * T-133: on USB there is no Bonjour discovery, so the host's TXT `wol` (T-129) would never be learned. Once per activity
 * start, after a session is up on USB, a short discovery runs for the TXT only (it never connects anywhere); its result
 * is logged as `ev=wol_refresh result=…`. Pure and clock-injected; main thread only.
 */
class WolRefresh(private val durationMs: Long = DURATION_MS) {
    enum class Result(val logName: String) { STORED("stored"), NONE("none"), NO_WIFI("no_wifi"), CANCELLED("cancelled") }

    sealed interface Step {
        data object None : Step
        /** Start the TXT-only discovery now. */
        data object Start : Step
        /** Done (the discovery, if any, stops); log [result]. */
        data class Finish(val result: Result) : Step
    }

    var running = false
        private set
    private var done = false
    private var deadlineMs = 0L

    /** A new activity start: one more refresh is allowed. A running one is not affected (cancel it first). */
    fun reset() {
        if (!running) done = false
    }

    /**
     * The session state changed. [connectedOnUsb]: an accepted session on the USB endpoint. [wifiUp] is asked only when a
     * refresh is due: without Wi-Fi it finishes at once as [Result.NO_WIFI] (no retry until the next [reset]).
     */
    fun onSession(connectedOnUsb: Boolean, nowMs: Long, wifiUp: () -> Boolean): Step {
        if (done || running || !connectedOnUsb) return Step.None
        done = true
        if (!wifiUp()) return Step.Finish(Result.NO_WIFI)
        running = true
        deadlineMs = nowMs + durationMs
        return Step.Start
    }

    /** A resolved service's TXT `wol` while running: a usable value ends the refresh as [Result.STORED]. */
    fun onTxt(wol: String?): Step {
        if (!running || WolTxt.parse(wol).isEmpty()) return Step.None
        return finish(Result.STORED)
    }

    fun tick(nowMs: Long): Step = if (running && nowMs >= deadlineMs) finish(Result.NONE) else Step.None

    /** Background or host sleep: a running refresh stops ([Result.CANCELLED]); it counts as done for this start. */
    fun cancel(): Step = if (running) finish(Result.CANCELLED) else Step.None

    private fun finish(r: Result): Step {
        running = false
        return Step.Finish(r)
    }

    companion object {
        const val DURATION_MS = 10_000L
    }
}
