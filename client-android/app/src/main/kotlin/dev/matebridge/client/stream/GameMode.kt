package dev.matebridge.client.stream

import dev.matebridge.client.audio.AudioOutPref
import dev.matebridge.client.protocol.StreamPrefs
import dev.matebridge.client.session.Settings
import dev.matebridge.client.video.VideoRenderer

/**
 * Game mode's temporary defaults (decision 0014 §3, T-109): a session layer over the user's stored [Settings] for the
 * bit rate, the audio output and the local pen trail/dot.
 *
 * - Entering a game mode ([StreamMode.isGame]) builds the layer from the game defaults ([defaults]).
 * - While it is active every read here returns the layer's value and every write changes only the layer; [Settings]
 *   is never written.
 * - Leaving the mode drops the layer, so the stored values are in effect again; the next entry starts from the game
 *   defaults again.
 * - Opening the app with the stored mode Game builds the layer at once (the caller calls [onModeChanged] at start).
 *
 * The caller applies the effective values (STREAM_PREFS, audio, pen overlay). Main thread only. Pure Kotlin.
 */
class GameModeSettings(private val settings: Settings) {
    /** The four layered values, either stored or from the layer. */
    data class Values(val bitrateKbps: Long, val audioOut: AudioOutPref, val penTrail: Boolean, val penDot: Boolean)

    enum class Change(val action: String) { ENTER("enter"), EXIT("exit") }

    private var layer: Values? = null

    /** True while the game layer is in effect (the panels mark the layered settings). */
    val active: Boolean get() = layer != null

    /** What the user stored, regardless of the layer. */
    fun saved(): Values = Values(settings.bitrateKbps(), settings.audioOut(), settings.penTrail(), settings.penDot())

    /** What applies now: the layer while game mode is on, otherwise the stored values. */
    fun effective(): Values = layer ?: saved()

    val bitrateKbps: Long get() = effective().bitrateKbps
    val audioOut: AudioOutPref get() = effective().audioOut
    val penTrail: Boolean get() = effective().penTrail
    val penDot: Boolean get() = effective().penDot

    fun setBitrateKbps(kbps: Long) {
        val v = Bitrate.sanitize(kbps)
        val l = layer
        if (l != null) layer = l.copy(bitrateKbps = v) else settings.setBitrateKbps(v)
    }

    fun setAudioOut(p: AudioOutPref) {
        val l = layer
        if (l != null) layer = l.copy(audioOut = p) else settings.setAudioOut(p)
    }

    fun setPenTrail(on: Boolean) {
        val l = layer
        if (l != null) layer = l.copy(penTrail = on) else settings.setPenTrail(on)
    }

    fun setPenDot(on: Boolean) {
        val l = layer
        if (l != null) layer = l.copy(penDot = on) else settings.setPenDot(on)
    }

    /**
     * The display mode is now [mode]. Builds the layer on entering a game mode ([Change.ENTER]), drops it on
     * leaving ([Change.EXIT]); null when nothing changed (game to game, or between two other modes).
     */
    fun onModeChanged(mode: StreamMode): Change? {
        val game = mode.isGame
        return when {
            game && layer == null -> { layer = defaults(saved()); Change.ENTER }
            !game && layer != null -> { layer = null; Change.EXIT }
            else -> null
        }
    }

    /** The one STREAM_PREFS for [mode]: its fps and scale with the effective bit rate. */
    fun prefs(mode: StreamMode): StreamPrefs = mode.toPrefs(bitrateKbps)

    companion object {
        /** Decision 0014: "yüksek bit hızı" when the stored choice is Otomatik. */
        const val GAME_BITRATE_KBPS = 60_000L

        /** Panel mark next to a layered setting while game mode is on. */
        const val MARKER = " (oyun modu)"

        /** The layered settings, in log order. */
        const val OVERRIDES = "bitrate,audio,pen"

        /** Game defaults: 60 Mbps if the stored bit rate is Otomatik (else kept), "Düşük gecikme", no pen trail/dot. */
        fun defaults(saved: Values) = Values(
            bitrateKbps = if (saved.bitrateKbps == Bitrate.AUTO_KBPS) GAME_BITRATE_KBPS else saved.bitrateKbps,
            audioOut = AudioOutPref.AUTO,
            penTrail = false,
            penDot = false,
        )

        /** `ev=game_mode` fields, e.g. `action=enter overrides=bitrate,audio,pen jitter=0`. */
        fun logFields(change: Change, jitter: GameJitter.Choice, effective: Values): String =
            "action=${change.action} overrides=$OVERRIDES jitter=${GameJitter.label(jitter.bufferFrames)}" +
                (if (jitter.source != GameJitter.Source.MODE) " jitter_src=${jitter.source.id}" else "") +
                " bitrate_kbps=${effective.bitrateKbps} audio_out=${effective.audioOut.id}"
    }
}

/**
 * The video jitter buffer per display mode (decision 0014 §2): 0 in game mode (each frame goes to the next vsync, no
 * adaptive playout delay), [VideoRenderer.BUFFER_ADAPTIVE] otherwise. A launch value (`--ei jitter`) always wins,
 * including `-1` = [VideoRenderer.BUFFER_ADAPTIVE] (T-210: the adaptive pacer in game mode, an A/B knob).
 */
object GameJitter {
    enum class Source(val id: String) { MODE("mode"), EXTRA("extra") }

    data class Choice(val bufferFrames: Int, val source: Source)

    /**
     * [launch] is the launch-time buffer ([VideoRenderer.BUFFER_ADAPTIVE] when nothing was given); [fixed] is where a
     * fixed launch value came from (null = none, the mode decides).
     */
    fun choose(launch: Int, fixed: Source?, game: Boolean): Choice = when {
        fixed != null -> Choice(launch, fixed)
        game -> Choice(0, Source.MODE)
        else -> Choice(launch, Source.MODE)
    }

    /** "adaptive" or the buffer size in frames. */
    fun label(bufferFrames: Int): String = if (bufferFrames == VideoRenderer.BUFFER_ADAPTIVE) "adaptive" else bufferFrames.toString()
}
