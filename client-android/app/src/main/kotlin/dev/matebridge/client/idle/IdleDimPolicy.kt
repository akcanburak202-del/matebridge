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
 *     unpressed channel (a hovering pen, still or moving) ends only when it leaves: an observed exit (HOVER_EXIT) with no
 *     further event within [EXIT_WINDOW_MS] (Android sends HOVER_EXIT right before the tip's DOWN), or, as a last resort,
 *     [STALE_MS] without any event on it. A pressed one silent for [STALE_MS] goes stale: it
 *     no longer counts as held for the counter, but its continuation is still swallowed until its real release or a fresh
 *     press on the channel, so a tracker never sees the middle of the waking motion as a new gesture;
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
    private class Swallow(var pressed: Boolean, var lastMs: Long) {
        /** Pressed but silent for [STALE_MS]: not held for the counter any more, still swallowed. */
        var stale = false

        /** When the channel reported leaving (pen HOVER_EXIT) with nothing after it yet, or [NO_EXIT]. */
        var exitAtMs = NO_EXIT
    }

    private val swallowing = HashMap<Long, Swallow>()

    // The wake line is written once the waking motion is over, with what it swallowed.
    private var wakeOpen = false
    private var wakeReason = ""
    private var wakeAtMs = 0L
    private var swallowed = 0

    /** The counter runs: a timeout is set and the mode is not game. */
    val enabled get() = !gameMode && timeout.ms != null

    /** Something local is held (sent to the Mac or swallowed): the counter stands still. */
    val held get() = sent.isNotEmpty() || swallowing.values.any { it.pressed && !it.stale }

    val swallowingAny get() = swallowing.isNotEmpty()

    fun isSwallowing(channel: Long) = channel in swallowing

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
     * DOWN that is not a repeat; only events that cannot belong to a press already under way): a swallow left over from a
     * release that never arrived ends there instead of eating it. [leaving] marks an exit that may or may not be followed
     * by more of the motion (pen HOVER_EXIT): a swallowed channel ends [EXIT_WINDOW_MS] later unless another event comes.
     * Returns false when the event must be swallowed.
     */
    fun admit(
        channel: Long, source: IdleSource, engaged: Boolean, pressed: Boolean, release: Boolean, nowMs: Long,
        fresh: Boolean = false, leaving: Boolean = false,
    ): Boolean {
        expireLingering(nowMs)
        if (fresh) swallowing.remove(channel)
        val woke = activity(source, nowMs)
        val pass = decide(channel, engaged, pressed, release, woke, nowMs, leaving)
        if (!pass) swallowed++
        closeWakeIfDone(nowMs)
        return pass
    }

    private fun decide(
        channel: Long, engaged: Boolean, pressed: Boolean, release: Boolean, woke: Boolean, nowMs: Long, leaving: Boolean,
    ): Boolean {
        val sw = swallowing[channel]
        if (sw != null) {
            if (engaged) {
                sw.pressed = pressed; sw.lastMs = nowMs; sw.stale = false
                sw.exitAtMs = if (leaving) nowMs else NO_EXIT
            } else {
                swallowing.remove(channel)
            }
            return false
        }
        if (release || channel in sent) {
            if (pressed) sent += channel else sent -= channel
            return true
        }
        if (woke || shadowed(channel)) {
            if (engaged) swallowing[channel] = Swallow(pressed, nowMs).also { if (leaving) it.exitAtMs = nowMs }
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

    /**
     * An input device went away (T-234 review): its releases were sent (or nothing was, for a swallowed motion), so every
     * channel of that device is forgotten; other devices keep theirs.
     */
    fun forgetDevice(deviceId: Int) {
        sent.removeAll { IdleChannel.deviceOf(it) == deviceId }
        if (swallowing.keys.removeAll { IdleChannel.deviceOf(it) == deviceId }) closeWakeIfDone(lastActivityMs)
    }

    /** A per-source release (pointer capture lost: touchpad and mouse buttons go to 0) forgets every channel of [kinds]. */
    fun forgetKinds(vararg kinds: Int) {
        sent.removeAll { IdleChannel.kindOf(it) in kinds }
        if (swallowing.keys.removeAll { IdleChannel.kindOf(it) in kinds }) closeWakeIfDone(lastActivityMs)
    }

    /**
     * T-234 review: keeps a sent channel only while [holds] says its tracker still holds the press. A tracker's own
     * release (the 10 s stale guards of the pen and touch trackers) thus ends the channel's hold on the counter. The caller
     * leaves channels without such guards (keys, touchpad, mouse) to their own releases.
     */
    fun retainSent(holds: (Long) -> Boolean) {
        sent.retainAll(holds)
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

    /**
     * A hover swallow ends [EXIT_WINDOW_MS] after an exit with nothing after it, or after [STALE_MS] without any event; a
     * pressed one goes stale after [STALE_MS] (see the class doc).
     */
    private fun expireLingering(nowMs: Long) {
        if (swallowing.isEmpty()) return
        var changed = swallowing.values.removeAll {
            !it.pressed && ((it.exitAtMs != NO_EXIT && nowMs - it.exitAtMs >= EXIT_WINDOW_MS) || nowMs - it.lastMs >= STALE_MS)
        }
        for (sw in swallowing.values) {
            if (sw.pressed && !sw.stale && nowMs - sw.lastMs >= STALE_MS) { sw.stale = true; changed = true }
        }
        if (changed) closeWakeIfDone(nowMs)
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
        if (!wakeOpen || swallowing.values.any { !it.stale }) return
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

        /** A swallowed pen that sent HOVER_EXIT and nothing for this long has left range (exit to the tip's DOWN: a few ms). */
        const val EXIT_WINDOW_MS = 300L

        private const val NO_EXIT = Long.MIN_VALUE

        /**
         * A swallowed press with no event for this long stops holding the counter (the trackers' own last-resort guards use
         * the same 10 s: PenTracker.CONTACT_STALE_MS, TouchTracker.PRESS_STALE_MS; a held key autorepeats). A swallowed
         * hover with no event at all for this long ends (last resort, so a lost HOVER_EXIT cannot keep fingers swallowed).
         */
        const val STALE_MS = 10_000L
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

    fun deviceOf(channel: Long): Int = ((channel ushr 24) and 0xFFFF_FFFFL).toInt()

    /**
     * A new motion of [newKind] is swallowed while a channel of [swallowedKind] is: only touchscreen fingers under a
     * swallowed pen (the tracker's palm gate needs the pen in range, and it never saw the swallowed pen).
     */
    fun shadows(swallowedKind: Int, newKind: Int) = swallowedKind == PEN && newKind == TOUCH
}
