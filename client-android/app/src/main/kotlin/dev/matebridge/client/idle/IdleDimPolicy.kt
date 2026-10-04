package dev.matebridge.client.idle

/** What the policy changes on the window (MainActivity: `screenBrightness` and `FLAG_KEEP_SCREEN_ON`). Main thread. */
interface IdleWindow {
    /** Dim (a very low window brightness) or back to the system brightness. Never touches the system setting. */
    fun setDimmed(dimmed: Boolean)

    /** Hold or drop `FLAG_KEEP_SCREEN_ON`; dropped, the tablet's own screen timeout turns the screen off. */
    fun setKeepScreenOn(on: Boolean)
}

enum class IdleStage { ACTIVE, DIM, OFF }

/** Where a local input came from; only the wake log uses it. */
enum class IdleSource(val id: String) {
    TOUCH("touch"), PEN("pen"), KEY("key"), PAD("pad"), MOUSE("mouse"), GESTURE("gesture"), UI("ui"),
}

/**
 * Idle dim and screen-off (decision 0031, T-234). Pure Kotlin, UI thread only, JVM-tested.
 *
 * Stages: [IdleStage.ACTIVE] → after [IdleTimeout] without local input [IdleStage.DIM] (window brightness down, the
 * session goes on) → [OFF_AFTER_MS] later [IdleStage.OFF] (`FLAG_KEEP_SCREEN_ON` dropped; the tablet's screen timeout
 * takes over, then onStop releases everything as before). The counter does not run while anything is held (a finger on
 * the glass, the pen touching, a key or button down), with the setting "Kapalı", or in game mode.
 *
 * The first input while dimmed only wakes ([admit]): its whole motion is swallowed, so it never reaches the Mac. Rules,
 * per channel (one touchscreen, one pen, one key, ...):
 *  1. a channel being swallowed stays swallowed until it disengages (all fingers up, pen lifted, key up); an engaged but
 *     unpressed channel (a hovering pen, also across the HOVER_EXIT Android sends right before the tip touches) ends
 *     after [LINGER_MS] without an event on it (the pen left range);
 *  2. a release, or anything on a channel whose press already went to the Mac, always passes: a release that belongs to a
 *     press the Mac got is never swallowed (input state never stuck);
 *  3. a new motion is swallowed when it woke the window, or when it is a touchscreen motion while the pen is being
 *     swallowed ([IdleChannel.shadows]: the finger gate cannot see a swallowed pen, so a palm put down meanwhile would
 *     click). Other channels are independent: a palm that woke the window does not keep the pen's strokes from drawing;
 *  4. everything else passes.
 */
class IdleDimPolicy(
    private val window: IdleWindow,
    nowMs: Long,
    timeout: IdleTimeout = IdleTimeout.DEFAULT,
    /** One `MB/input ev=idle` line's fields (no coordinates, no key data). */
    private val log: (String) -> Unit = {},
) {
    var stage = IdleStage.ACTIVE
        private set
    var timeout = timeout
        private set
    var gameMode = false
        private set

    private var lastActivityMs = nowMs
    private var dimAtMs = nowMs

    /** Channels with a press that went to the Mac (it may hold it). */
    private val sent = HashSet<Long>()

    /** Channels being swallowed: whether the channel is pressed right now (a hovering pen is engaged, not pressed). */
    private class Swallow(var pressed: Boolean, var lastMs: Long)

    private val swallowing = HashMap<Long, Swallow>()

    // The wake line is written once the waking motion is over, with what it swallowed.
    private var wakeOpen = false
    private var wakeReason = ""
    private var wakeAtMs = 0L
    private var swallowed = 0

    /** The counter runs: a timeout is set and the mode is not game. */
    val enabled get() = !gameMode && timeout.ms != null

    /** Something local is held (sent to the Mac or swallowed): the counter stands still. */
    val held get() = sent.isNotEmpty() || swallowing.values.any { it.pressed }

    val swallowingAny get() = swallowing.isNotEmpty()

    /** Every input tick (~25 ms). */
    fun tick(nowMs: Long) {
        expireLingering(nowMs)
        val limit = timeout.ms
        if (gameMode || limit == null) return
        if (held) {
            lastActivityMs = nowMs
            return
        }
        when (stage) {
            IdleStage.ACTIVE -> if (nowMs - lastActivityMs >= limit) dim(nowMs)
            IdleStage.DIM -> if (nowMs - dimAtMs >= OFF_AFTER_MS) off()
            IdleStage.OFF -> Unit
        }
    }

    /**
     * A local event that does not go through [admit] (connect panel, settings panel, system keys) or that [admit] already
     * saw: activity, and a wake without swallowing anything. Returns true when it woke the window.
     */
    fun onInput(source: IdleSource, nowMs: Long): Boolean {
        val woke = activity(source, nowMs)
        closeWakeIfDone(nowMs)
        return woke
    }

    /**
     * One event on its way to the Mac. [channel] identifies the held thing ([IdleChannel]); [engaged] is whether the
     * channel is still in its motion after this event (fingers down, pen touching or in hover range, key down), [pressed]
     * whether it holds something (hover is not a press); [release] marks a release event (UP, CANCEL, hover exit, key up,
     * button up). [fresh] marks the start of a new motion with nothing else down on the channel (the first finger, a key
     * DOWN that is not a repeat): a swallow left over from a release that never arrived ends there instead of eating it.
     * Returns false when the event must be swallowed.
     */
    fun admit(
        channel: Long, source: IdleSource, engaged: Boolean, pressed: Boolean, release: Boolean, nowMs: Long, fresh: Boolean = false,
    ): Boolean {
        expireLingering(nowMs)
        if (fresh) swallowing.remove(channel)
        val woke = activity(source, nowMs)
        val pass = decide(channel, engaged, pressed, release, woke, nowMs)
        if (!pass) swallowed++
        closeWakeIfDone(nowMs)
        return pass
    }

    private fun decide(channel: Long, engaged: Boolean, pressed: Boolean, release: Boolean, woke: Boolean, nowMs: Long): Boolean {
        val sw = swallowing[channel]
        if (sw != null) {
            if (engaged) { sw.pressed = pressed; sw.lastMs = nowMs } else swallowing.remove(channel)
            return false
        }
        if (release || channel in sent) {
            if (pressed) sent += channel else sent -= channel
            return true
        }
        if (woke || shadowed(channel)) {
            if (engaged) swallowing[channel] = Swallow(pressed, nowMs)
            return false
        }
        if (pressed) sent += channel
        return true
    }

    /**
     * The input model was forgotten (RELEASE_ALL, a new session, a refused send): the host holds nothing of ours and the
     * trackers ignore the late releases, so the gate forgets too. The stage is not changed.
     */
    fun forgetGestures() {
        sent.clear()
        swallowing.clear()
        closeWakeIfDone(lastActivityMs)
    }

    /** "Boşta karart" changed: the counter starts again; a dimmed window comes back. */
    fun setTimeout(t: IdleTimeout, nowMs: Long) {
        timeout = t
        lastActivityMs = nowMs
        logConfig("setting")
        if (stage != IdleStage.ACTIVE) wakeNow("setting", nowMs)
    }

    /** Game mode on or off: no stages in game mode; the counter starts again either way. */
    fun setGameMode(on: Boolean, nowMs: Long) {
        if (on == gameMode) return
        gameMode = on
        lastActivityMs = nowMs
        logConfig("game")
        if (on && stage != IdleStage.ACTIVE) wakeNow("game", nowMs)
    }

    /** The activity is visible again (onStart): full brightness, the flag held, the counter from now, no gesture state. */
    fun restart(nowMs: Long) {
        sent.clear()
        swallowing.clear()
        lastActivityMs = nowMs
        val was = stage
        stage = IdleStage.ACTIVE
        window.setDimmed(false)
        window.setKeepScreenOn(true)
        if (was != IdleStage.ACTIVE) beginWake("start", nowMs)
        closeWakeIfDone(nowMs)
    }

    private fun shadowed(channel: Long): Boolean {
        if (swallowing.isEmpty()) return false
        val kind = IdleChannel.kindOf(channel)
        return swallowing.keys.any { IdleChannel.shadows(IdleChannel.kindOf(it), kind) }
    }

    /** Engaged-but-unpressed swallows (hover) end once their channel has been silent for [LINGER_MS]. */
    private fun expireLingering(nowMs: Long) {
        if (swallowing.isEmpty()) return
        if (swallowing.values.removeAll { !it.pressed && nowMs - it.lastMs >= LINGER_MS }) closeWakeIfDone(nowMs)
    }

    private fun activity(source: IdleSource, nowMs: Long): Boolean {
        lastActivityMs = nowMs
        if (stage == IdleStage.ACTIVE) return false
        restore()
        beginWake(source.id, nowMs)
        return true
    }

    private fun wakeNow(reason: String, nowMs: Long) {
        restore()
        beginWake(reason, nowMs)
        closeWakeIfDone(nowMs)
    }

    private fun restore() {
        stage = IdleStage.ACTIVE
        window.setDimmed(false)
        window.setKeepScreenOn(true)
    }

    private fun beginWake(reason: String, nowMs: Long) {
        wakeOpen = true
        wakeReason = reason
        wakeAtMs = nowMs
        swallowed = 0
    }

    private fun closeWakeIfDone(nowMs: Long) {
        if (!wakeOpen || swallowing.isNotEmpty()) return
        wakeOpen = false
        log("stage=wake reason=$wakeReason swallowed=$swallowed held_ms=${nowMs - wakeAtMs}")
    }

    private fun dim(nowMs: Long) {
        if (wakeOpen) closeWakeForced(nowMs)
        stage = IdleStage.DIM
        dimAtMs = nowMs
        window.setDimmed(true)
        log("stage=dim reason=timeout idle_ms=${nowMs - lastActivityMs}")
    }

    /** A swallow left open (a hovering pen that never moved again) does not keep the previous wake line back forever. */
    private fun closeWakeForced(nowMs: Long) {
        wakeOpen = false
        log("stage=wake reason=$wakeReason swallowed=$swallowed held_ms=${nowMs - wakeAtMs}")
    }

    private fun off() {
        stage = IdleStage.OFF
        window.setKeepScreenOn(false)
        log("stage=off reason=timeout")
    }

    private fun logConfig(reason: String) =
        log("stage=config reason=$reason timeout_min=${timeout.minutes ?: "off"} game=${if (gameMode) 1 else 0}")

    companion object {
        /** Decision 0031: one more minute without input after dimming, then the flag goes. */
        const val OFF_AFTER_MS = 60_000L

        /** A swallowed hovering pen silent this long has left range (HOVER_EXIT to the tip's DOWN is a few ms). */
        const val LINGER_MS = 1_000L
    }
}

/** Channel ids for [IdleDimPolicy.admit]: a kind plus the device and, for keys, the key identity. */
object IdleChannel {
    const val TOUCH = 1
    const val PEN = 2
    const val PAD = 3
    const val MOUSE = 4
    const val KEY = 5
    const val GESTURE = 6

    fun of(kind: Int, deviceId: Int, code: Int = 0): Long =
        (kind.toLong() shl 56) or ((deviceId.toLong() and 0xFFFF_FFFFL) shl 24) or (code.toLong() and 0xFF_FFFFL)

    fun kindOf(channel: Long): Int = (channel ushr 56).toInt()

    /**
     * A new motion of [newKind] is swallowed while a channel of [swallowedKind] is: only touchscreen fingers under a
     * swallowed pen (the tracker's palm gate needs the pen in range, and it never saw the swallowed pen).
     */
    fun shadows(swallowedKind: Int, newKind: Int) = swallowedKind == PEN && newKind == TOUCH
}
