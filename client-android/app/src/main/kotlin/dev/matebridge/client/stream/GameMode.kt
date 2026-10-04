package dev.matebridge.client.stream

import dev.matebridge.client.audio.AudioOutPref
import dev.matebridge.client.protocol.StreamPrefs
import dev.matebridge.client.session.Settings
import dev.matebridge.client.video.VideoRenderer

/**
 * The temporary mode defaults (decision 0014 §3 for Oyun, decision 0030 §1 for Çizim; T-109, T-223): a session layer
 * over the user's stored [Settings] for the bit rate, the audio output, the local pen trail/dot and the finger switch.
 *
 * - Entering Oyun or Çizim builds the layer from that mode's defaults ([defaults]):
 *   Oyun: 60 Mbps if Otomatik, "Düşük gecikme", no pen trail/dot. Çizim: fingers off, 60 Mbps if Otomatik.
 *   Values a mode does not override keep the stored ones.
 * - While a layer is active every read here returns the layer's value and every write changes only the layer;
 *   [Settings] is never written (the layer is rebuilt on each entry, also Oyun to Çizim and back).
 * - Leaving to Günlük drops the layer, so the stored values are in effect again.
 * - Opening the app with the stored mode Oyun or Çizim builds the layer at once (the caller calls [onModeChanged] at start).
 *
 * The game display size ("Oyun çözünürlüğü", decision 0029, T-215) is a persistent setting outside the layer: Oyun asks
 * for it in STREAM_PREFS `display_*`, other modes (and [gameDisplay] false, `--ei game_display 0`) for the native display
 * (0×0, today's bytes). The frame rate is the per-mode stored "Kare hızı" ([Settings.modeFps]), also outside the layer.
 *
 * The caller applies the effective values (STREAM_PREFS, audio, pen overlay, finger switch). Main thread only. Pure Kotlin.
 */
class GameModeSettings(private val settings: Settings, private val gameDisplay: Boolean = true) {
    /** The layered values, either stored or from the layer. */
    data class Values(
        val bitrateKbps: Long,
        val audioOut: AudioOutPref,
        val penTrail: Boolean,
        val penDot: Boolean,
        val fingerOff: Boolean = false,
    )

    enum class Change(val action: String) { ENTER("enter"), EXIT("exit") }

    /** A layer change and the mode whose layer was built ([Change.ENTER]) or dropped ([Change.EXIT]). */
    data class Transition(val change: Change, val mode: StreamMode)

    /** The settings a layer can override (panels mark the layered ones). */
    enum class Override { BITRATE, AUDIO, PEN, FINGER }

    private var layer: Values? = null
    private var layerMode: StreamMode? = null

    /** True while a layer (Oyun or Çizim) is in effect. */
    val active: Boolean get() = layer != null

    /** True while the Oyun layer is in effect (jitter choice, `GameJitter`). */
    val gameActive: Boolean get() = layerMode == StreamMode.GAME

    /** The mode whose layer is in effect, null in Günlük. The panels mark the layered settings with it ([marker]). */
    val modeLayer: StreamMode? get() = layerMode

    /** What the user stored, regardless of the layer. */
    fun saved(): Values =
        Values(settings.bitrateKbps(), settings.audioOut(), settings.penTrail(), settings.penDot(), settings.fingerTouchDisabled())

    /** What applies now: the layer while a mode layer is on, otherwise the stored values. */
    fun effective(): Values = layer ?: saved()

    val bitrateKbps: Long get() = effective().bitrateKbps
    val audioOut: AudioOutPref get() = effective().audioOut
    val penTrail: Boolean get() = effective().penTrail
    val penDot: Boolean get() = effective().penDot
    val fingerOff: Boolean get() = effective().fingerOff

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

    fun setFingerOff(off: Boolean) {
        val l = layer
        if (l != null) layer = l.copy(fingerOff = off) else settings.setFingerTouchDisabled(off)
    }

    /**
     * The display mode is now [mode]. Builds the layer on entering Oyun or Çizim ([Change.ENTER], also when switching
     * from one to the other), drops it on leaving to Günlük ([Change.EXIT]); null when nothing changed.
     */
    fun onModeChanged(mode: StreamMode): Transition? {
        val target = mode.takeIf { it.isGame || it.isDrawing }
        val current = layerMode
        return when {
            target == current -> null
            target != null -> {
                layerMode = target
                layer = defaults(target, saved())
                Transition(Change.ENTER, target)
            }
            else -> {
                layerMode = null
                layer = null
                Transition(Change.EXIT, current!!)
            }
        }
    }

    /** The "Kare hızı" [mode] runs at: its stored choice or default, Çizim always 120. */
    fun fps(mode: StreamMode): Int = settings.modeFps(mode)

    /** The game display [mode] asks for: the stored "Oyun çözünürlüğü" in Oyun, null (native display) otherwise. */
    fun display(mode: StreamMode): GameResolution? = if (mode.isGame && gameDisplay) settings.gameResolution() else null

    /** The one STREAM_PREFS for [mode]: its frame rate and the full scale with the effective bit rate, plus the game display size in Oyun. */
    fun prefs(mode: StreamMode): StreamPrefs {
        val p = mode.toPrefs(fps(mode), bitrateKbps)
        val d = display(mode) ?: return p
        return StreamPrefs(p.fps, p.scalePermille, p.bitrateKbps, d.widthPx, d.heightPx)
    }

    /**
     * Stores [mode]'s "Kare hızı"; returns the complete STREAM_PREFS to send when it is a real change for a mode with the
     * setting (Günlük, Oyun), else null (Çizim, or an invalid value: nothing stored, nothing sent).
     */
    fun selectFrameRate(mode: StreamMode, fps: Int): StreamPrefs? {
        if (!mode.hasFpsSetting || fps !in StreamMode.FPS_OPTIONS) return null
        settings.setModeFps(mode, fps)
        return prefs(mode)
    }

    /**
     * Stores the "Oyun çözünürlüğü" choice; returns the complete STREAM_PREFS to send when it changes what [mode] asks
     * for (Oyun with the game display on), else null (nothing to send; the next Oyun entry uses it).
     */
    fun selectGameResolution(r: GameResolution, mode: StreamMode): StreamPrefs? {
        settings.setGameResolution(r)
        return if (display(mode) != null) prefs(mode) else null
    }

    companion object {
        /** Decision 0014/0030: "yüksek bit hızı" when the stored choice is Otomatik (Oyun and Çizim). */
        const val GAME_BITRATE_KBPS = 60_000L

        /** The settings [mode]'s layer overrides, in log order. */
        fun overridesOf(mode: StreamMode): List<Override> = when (mode) {
            StreamMode.GAME -> listOf(Override.BITRATE, Override.AUDIO, Override.PEN)
            StreamMode.DRAWING -> listOf(Override.BITRATE, Override.FINGER)
            StreamMode.DAILY -> emptyList()
        }

        /** `ev=mode_layer overrides=` value, e.g. `bitrate,audio,pen` (Oyun) or `bitrate,finger` (Çizim). */
        fun overridesText(mode: StreamMode): String = overridesOf(mode).joinToString(",") { it.name.lowercase() }

        /** Panel mark next to a layered setting while [layer]'s mode is on: " (oyun modu)", " (çizim modu)", else "". */
        fun marker(layer: StreamMode?, o: Override): String = when {
            layer == null || o !in overridesOf(layer) -> ""
            layer.isGame -> " (oyun modu)"
            else -> " (çizim modu)"
        }

        /** Mode defaults over the [saved] values: Oyun = 0014 §3, Çizim = 0030 §1 (see the class comment). */
        fun defaults(mode: StreamMode, saved: Values): Values {
            val high = if (saved.bitrateKbps == Bitrate.AUTO_KBPS) GAME_BITRATE_KBPS else saved.bitrateKbps
            return when (mode) {
                StreamMode.GAME -> saved.copy(bitrateKbps = high, audioOut = AudioOutPref.AUTO, penTrail = false, penDot = false)
                StreamMode.DRAWING -> saved.copy(bitrateKbps = high, fingerOff = true)
                StreamMode.DAILY -> saved
            }
        }

        /** `ev=mode_layer` fields, e.g. `mode=game action=enter overrides=bitrate,audio,pen jitter=adaptive ...`. */
        fun logFields(t: Transition, jitter: GameJitter.Choice, effective: Values): String =
            "mode=${t.mode.id} action=${t.change.action} overrides=${overridesText(t.mode)} jitter=${GameJitter.label(jitter.bufferFrames)}" +
                (if (jitter.source != GameJitter.Source.MODE) " jitter_src=${jitter.source.id}" else "") +
                " bitrate_kbps=${effective.bitrateKbps} audio_out=${effective.audioOut.id} finger_off=${if (effective.fingerOff) 1 else 0}"
    }
}

/**
 * The video jitter buffer per display mode (decision 0014 §2, amended 2026-10-04, T-211):
 * [VideoRenderer.BUFFER_ADAPTIVE] in every mode, game modes included (buffer 0 skipped ~10% of vsyncs at 60 fps on
 * the 120 Hz panel). A launch value (`--ez dev true --ei jitter N`) always wins: `0` gives the old game-mode
 * behaviour (each frame to the next vsync) for A/B, `-1` = [VideoRenderer.BUFFER_ADAPTIVE] (T-210).
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
        game -> Choice(VideoRenderer.BUFFER_ADAPTIVE, Source.MODE)
        else -> Choice(launch, Source.MODE)
    }

    /** "adaptive" or the buffer size in frames. */
    fun label(bufferFrames: Int): String = if (bufferFrames == VideoRenderer.BUFFER_ADAPTIVE) "adaptive" else bufferFrames.toString()
}
