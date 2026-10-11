package dev.matebridge.client.session

import dev.matebridge.client.protocol.AudioPrefs
import dev.matebridge.client.protocol.StreamPrefs

/**
 * Decision 0038: the profile of a remote ("Uzaktan bağlan") session, the one the user starts with its own button. Pure
 * values; the session machine sends [streamPrefs] instead of the normal mode's STREAM_PREFS while a profile is set, and
 * the user's normal mode and settings are never touched.
 *
 * [bitrateKbps] is one of [BITRATE_OPTIONS_KBPS]; [audio] is the remote audio wish (default off, [DEFAULT_AUDIO]).
 */
data class RemoteProfile(val bitrateKbps: Long = DEFAULT_BITRATE_KBPS, val audio: Boolean = DEFAULT_AUDIO) {
    /** The complete STREAM_PREFS of a remote session: 15 fps, 1400x920 at 1x, SDR, normal chroma, `link = 1`. */
    fun streamPrefs(): StreamPrefs = StreamPrefs(
        fps = FPS,
        scalePermille = 1000,
        bitrateKbps = sanitizeBitrate(bitrateKbps),
        displayWidthPx = DISPLAY_WIDTH_PX,
        displayHeightPx = DISPLAY_HEIGHT_PX,
        dynamicRange = StreamPrefs.DYNAMIC_RANGE_SDR,
        chroma = StreamPrefs.CHROMA_NORMAL,
        link = StreamPrefs.LINK_REMOTE,
    )

    /**
     * The remote AUDIO_PREFS. PCM for now: AAC arrives with T-341 (HELLO bit14 is not reported yet, so the host would
     * ignore `codec = 1` anyway).
     */
    fun audioPrefs(): AudioPrefs = AudioPrefs(audio, AudioPrefs.CODEC_PCM)

    companion object {
        const val FPS = 15
        const val DISPLAY_WIDTH_PX = 1400
        const val DISPLAY_HEIGHT_PX = 920
        const val DEFAULT_BITRATE_KBPS = 1000L
        val BITRATE_OPTIONS_KBPS = listOf(500L, 1000L, 2000L)
        const val DEFAULT_AUDIO = false

        /** Label shown by the panel instead of the mode row. */
        const val MODE_LABEL = "Uzak (Tasarruf)"

        /** Anything that is not an option gives the default. */
        fun sanitizeBitrate(kbps: Long?): Long = if (kbps != null && kbps in BITRATE_OPTIONS_KBPS) kbps else DEFAULT_BITRATE_KBPS

        /** "0,5 Mbps", "1 Mbps", "2 Mbps". */
        fun bitrateLabel(kbps: Long): String = when (kbps) {
            500L -> "0,5 Mbps"
            else -> "${kbps / 1000} Mbps"
        }
    }
}

/**
 * Decision 0038 section 6: timings of a remote session (the normal ones are 500 ms ping, 3 s PONG timeout, 1 s STATS,
 * 1.5 s cursor timeout).
 */
object RemoteTimings {
    const val PING_FAST_US = 500_000L
    const val PING_IDLE_US = 2_000_000L

    /** After the last input event the fast PING rate lasts this long. */
    const val INPUT_GRACE_US = 2_000_000L
    const val PONG_TIMEOUT_US = 10_000_000L
    const val STATS_INTERVAL_MS = 5_000L
    const val CURSOR_TIMEOUT_MS = 5_000L

    /**
     * PING interval of a remote session. Input held (key, button, pen contact or proximity, open scroll or pinch) or
     * input within [INPUT_GRACE_US]: 500 ms, so the host's 1.5 s release-all rule never fires for a held input; otherwise
     * 2 s (with nothing held, release-all has nothing to release). The first input event brings the fast rate back at once
     * because [pingDue] is evaluated on every tick against the last PING actually sent.
     */
    fun pingIntervalUs(inputActive: Boolean): Long = if (inputActive) PING_FAST_US else PING_IDLE_US

    /** True when a PING is due: [lastPingUs] is the time the previous one went out. */
    fun pingDue(nowUs: Long, lastPingUs: Long, inputActive: Boolean): Boolean =
        nowUs - lastPingUs >= pingIntervalUs(inputActive)

    /** Whether input counts as active at [nowUs]: something is held, or the last input event was less than the grace ago. */
    fun inputActive(held: Boolean, lastInputUs: Long, nowUs: Long): Boolean =
        held || (lastInputUs != 0L && nowUs - lastInputUs < INPUT_GRACE_US)
}

/** Decision 0038 section 5/6: what a remote session shows when the Mac refuses a new pairing. Pure. */
object RemoteUi {
    /**
     * The states a remote session ends in when the host would have to pair (it refuses: REJECTED, or an old host answers
     * PAIRING and the connection was not a user pairing start). The panel then shows "Yeni eşleşme yalnız ev ağında ya da
     * USB ile yapılabilir." and nothing retries.
     */
    fun pairingRefused(state: SessionUi): Boolean = when (state) {
        is SessionUi.Failed -> state.cause == SessionUi.Cause.REJECTED
        is SessionUi.PairingNeedsUser, is SessionUi.StoredTrust, is SessionUi.AwaitingApproval -> true
        else -> false
    }
}
