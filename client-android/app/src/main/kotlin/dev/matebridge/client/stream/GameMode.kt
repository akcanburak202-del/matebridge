package dev.matebridge.client.stream

import dev.matebridge.client.audio.AudioOutPref
import dev.matebridge.client.input.FingerPolicy
import dev.matebridge.client.protocol.StreamPrefs
import dev.matebridge.client.session.Settings
import dev.matebridge.client.video.VideoRenderer

/**
 * The temporary mode defaults (decision 0014 §3 for Oyun, decision 0030 §1 for Çizim; T-109, T-223): a session layer
 * over the user's stored [Settings] for the bit rate, the audio output, the local pen trail/dot and the finger switch.
 *
 * - Entering Oyun or Çizim builds the layer from that mode's defaults ([defaults]):
 *   Oyun: 60 Mbps if Otomatik, "Düşük gecikme", no pen trail/dot. Çizim: fingers gestures-only (one finger sends
 *   nothing, pinch and two-finger scroll still work; [FingerPolicy.GESTURES_ONLY]), 60 Mbps if Otomatik.
 *   Values a mode does not override ([overridesOf]) keep the stored ones.
 * - The layer keeps the user's bit rate choice ([bitrateKbps], 0 = Otomatik) apart from the value it sends
 *   ([Values.bitrateKbps]): Otomatik inside a layer always means the layer default [GAME_BITRATE_KBPS], whether it was
 *   stored on entry or picked while the layer is on (T-242); the panel keeps "Otomatik" selected.
 * - While a layer is active every read here returns the layer's value. A write changes only the layer for a setting
 *   that layer overrides ([overridesOf]); any other setting is persisted as usual (and the layer's copy follows), so a
 *   change to a non-overridden setting never silently reverts when the mode changes. The layer is rebuilt on each
 *   entry, also Oyun to Çizim and back.
 * - Leaving to Günlük drops the layer, so the stored values are in effect again.
 * - Opening the app with the stored mode Oyun or Çizim builds the layer at once (the caller calls [onModeChanged] at start).
 *
 * The game display size ("Oyun çözünürlüğü", decision 0029, T-215) is a persistent setting outside the layer: Oyun asks
 * for it in STREAM_PREFS `display_*`, other modes (and [gameDisplay] false, `--ei game_display 0`) for the native display
 * (0×0, today's bytes). The frame rate is the per-mode stored "Kare hızı" ([Settings.modeFps]), also outside the layer.
 *
 * HDR (decision 0032, T-238) is a persistent setting outside the layer too: [prefs] asks for HDR10 only in Oyun, with
 * the stored "HDR" on and a capable tablet ([hdr], computed once at start); every other case asks for SDR, so a mode
 * change re-sends the right `dynamic_range` through the same one STREAM_PREFS.
 *
 * "Renk" (decisions 0033/0034, T-241/T-260) is persistent and outside the layer as well ([colourStore]; null = always
 * Keskin kenarlar). [selectColour] stores it and returns the STREAM_PREFS to send.
 *
 * The caller applies the effective values (STREAM_PREFS, audio, pen overlay, finger switch). Main thread only. Pure Kotlin.
 */
class GameModeSettings(
    private val settings: Settings,
    private val gameDisplay: Boolean = true,
    /** Decision 0032: whether this tablet can show HDR10 ([HdrCapability.NONE] = never ask for it). */
    val hdr: HdrCapability = HdrCapability.NONE,
    /** Decision 0034: the stored "Renk" choice; null = always Normal. The 0033 on/off value is migrated at construction. */
    private val colourStore: ColourStore? = null,
    /** Decision 0034: true while the full-chroma capability self-test has passed ([dev.matebridge.client.video.FullChromaCapability]). */
    private val fullChromaAvailable: () -> Boolean = { false },
) {
    init { colourStore?.migrate() } // decision 0034: the 0033 "Keskin renk kenarları" value moves into `colour`

    /** The layered values, either stored or from the layer. */
    data class Values(
        val bitrateKbps: Long,
        val audioOut: AudioOutPref,
        val penTrail: Boolean,
        val penDot: Boolean,
        val fingers: FingerPolicy = FingerPolicy.ALL,
    ) {
        /** Every finger refused (the stored "tamamen kapat" switch, or its layer value). */
        val fingerOff: Boolean get() = fingers == FingerPolicy.OFF
    }

    enum class Change(val action: String) { ENTER("enter"), EXIT("exit") }

    /** A layer change and the mode whose layer was built ([Change.ENTER]) or dropped ([Change.EXIT]). */
    data class Transition(val change: Change, val mode: StreamMode)

    /** The settings a layer can override (panels mark the layered ones). */
    enum class Override { BITRATE, AUDIO, PEN, FINGER }

    private var layer: Values? = null
    private var layerMode: StreamMode? = null

    /** T-242: the bit rate choice while a layer is on (0 = Otomatik); [Values.bitrateKbps] is its resolved value. */
    private var layerBitrateChoice: Long = Bitrate.AUTO_KBPS

    /** True while a layer (Oyun or Çizim) is in effect. */
    val active: Boolean get() = layer != null

    /** True while the Oyun layer is in effect (jitter choice, `GameJitter`). */
    val gameActive: Boolean get() = layerMode == StreamMode.GAME

    /** The mode whose layer is in effect, null in Günlük. The panels mark the layered settings with it ([marker]). */
    val modeLayer: StreamMode? get() = layerMode

    /** What the user stored, regardless of the layer. */
    fun saved(): Values =
        Values(
            settings.bitrateKbps(), settings.audioOut(), settings.penTrail(), settings.penDot(),
            if (settings.fingerTouchDisabled()) FingerPolicy.OFF else FingerPolicy.ALL,
        )

    /** What applies now: the layer while a mode layer is on, otherwise the stored values. */
    fun effective(): Values = layer ?: saved()

    /**
     * The user's bit rate choice, one of [Bitrate.OPTIONS_KBPS] (0 = Otomatik): the panel selection. Inside a layer it
     * is the layer's choice; what STREAM_PREFS sends is [Values.bitrateKbps] of [effective] (Otomatik there = 60 Mbps).
     */
    val bitrateKbps: Long get() = if (layer != null) layerBitrateChoice else settings.bitrateKbps()
    val audioOut: AudioOutPref get() = effective().audioOut
    val penTrail: Boolean get() = effective().penTrail
    val penDot: Boolean get() = effective().penDot
    /** What fingers may do now (Çizim: [FingerPolicy.GESTURES_ONLY] unless the stored switch is fully off). */
    val fingers: FingerPolicy get() = effective().fingers

    /** The switch's own state: every finger refused ([FingerPolicy.OFF]). */
    val fingerOff: Boolean get() = fingers == FingerPolicy.OFF

    /** True while the active layer overrides [o] (a write to it then stays in the layer; otherwise it is persisted). */
    private fun layered(o: Override): Boolean = layerMode?.let { o in overridesOf(it) } == true

    /**
     * The write rule (decision 0014 §3, T-223): a setting the active layer overrides changes only the layer; any other
     * setting is a normal persistent change, and the layer's copy of it follows so [effective] stays consistent.
     */
    private inline fun write(o: Override, persist: () -> Unit, update: (Values) -> Values) {
        val l = layer
        if (l != null && layered(o)) { layer = update(l); return }
        persist()
        if (l != null) layer = update(l)
    }

    fun setBitrateKbps(kbps: Long) {
        val v = Bitrate.sanitize(kbps)
        write(Override.BITRATE, { settings.setBitrateKbps(v) }) { it.copy(bitrateKbps = layerBitrateKbps(v)) }
        if (layer != null) layerBitrateChoice = v
    }

    fun setAudioOut(p: AudioOutPref) = write(Override.AUDIO, { settings.setAudioOut(p) }) { it.copy(audioOut = p) }

    fun setPenTrail(on: Boolean) = write(Override.PEN, { settings.setPenTrail(on) }) { it.copy(penTrail = on) }

    fun setPenDot(on: Boolean) = write(Override.PEN, { settings.setPenDot(on) }) { it.copy(penDot = on) }

    /**
     * The "Parmak dokunmasını tamamen kapat" switch. In Çizim (which overrides the finger policy) it changes only the
     * layer: on = [FingerPolicy.OFF], off = Çizim's [FingerPolicy.GESTURES_ONLY]; elsewhere it is the stored setting.
     */
    fun setFingerOff(off: Boolean) = write(
        Override.FINGER,
        { settings.setFingerTouchDisabled(off) },
    ) { it.copy(fingers = if (off) FingerPolicy.OFF else if (layered(Override.FINGER)) FingerPolicy.GESTURES_ONLY else FingerPolicy.ALL) }

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
                val s = saved()
                layerBitrateChoice = s.bitrateKbps
                layer = defaults(target, s)
                Transition(Change.ENTER, target)
            }
            else -> {
                layerMode = null
                layer = null
                layerBitrateChoice = Bitrate.AUTO_KBPS
                Transition(Change.EXIT, current!!)
            }
        }
    }

    /** The "Kare hızı" [mode] runs at: its stored choice or default, Çizim always 120. */
    fun fps(mode: StreamMode): Int = settings.modeFps(mode)

    /**
     * The game display [mode] asks for: the stored "Oyun çözünürlüğü" in Oyun (the same at every frame rate, T-250),
     * null (native display) otherwise.
     */
    fun display(mode: StreamMode): GameResolution? =
        if (mode.isGame && gameDisplay) settings.gameResolution() else null

    /** The stored "HDR" setting (decision 0032), regardless of mode or capability. */
    val hdrSetting: Boolean get() = settings.hdrGame()

    /** STREAM_PREFS `dynamic_range` for [mode] ([HdrPolicy.dynamicRange]). */
    fun dynamicRange(mode: StreamMode): Int = HdrPolicy.dynamicRange(hdr, mode, settings.hdrGame())

    /**
     * The one STREAM_PREFS for [mode]: its frame rate and the full scale with the effective bit rate, plus the game
     * display size in Oyun and the dynamic range ([dynamicRange]; SDR writes no group).
     */
    fun prefs(mode: StreamMode): StreamPrefs {
        val p = mode.toPrefs(fps(mode), effective().bitrateKbps) // T-242: the resolved rate, not the panel choice
        val d = display(mode)
        return StreamPrefs(p.fps, p.scalePermille, p.bitrateKbps, d?.widthPx ?: 0, d?.heightPx ?: 0, dynamicRange(mode), chromaFor(mode))
    }

    /**
     * Stores the "HDR" choice; returns the complete STREAM_PREFS to send when it changes what [mode] asks for (Oyun on a
     * capable tablet), else null (nothing stored without the capability: the row is grey; elsewhere it applies on the
     * next Oyun entry).
     */
    fun selectHdr(on: Boolean, mode: StreamMode): StreamPrefs? {
        if (!hdr.supported) return null
        val before = dynamicRange(mode)
        settings.setHdrGame(on)
        return if (dynamicRange(mode) != before) prefs(mode) else null
    }

    /** The stored "Renk" choice (decision 0034). */
    fun colourChoice(): ColourChoice = colourStore?.get() ?: ColourStore.DEFAULT

    /** True while the full-chroma capability self-test has passed (the "Tam renk" option is usable). */
    val fullChromaCapable: Boolean get() = fullChromaAvailable()

    /**
     * STREAM_PREFS `chroma` for [mode] ([FullChromaPolicy.chromaRequest]): `2` only for Tam renk in Günlük at 60 fps on the
     * native display, SDR, with the capability passed; a chosen Tam renk otherwise asks for the sharp value `1`.
     */
    fun chromaFor(mode: StreamMode): Int = FullChromaPolicy.chromaRequest(
        colourChoice(), mode, fps(mode), display(mode) == null, StreamMode.SCALE_PERMILLE, dynamicRange(mode),
        fullChromaAvailable(),
    )

    /** "Varsayılanlara dön": back to Keskin kenarlar (the default); true when a value was stored. */
    fun resetColour(): Boolean = colourStore?.reset() == true

    /**
     * Stores the "Renk" choice; returns the complete STREAM_PREFS for [mode] when it changes what is asked of the host
     * (`chroma`), else null (no store, the same value, or a choice that asks for the same `chroma`; the choice is still
     * stored). Tam renk without the capability is refused (nothing stored).
     */
    fun selectColour(choice: ColourChoice, mode: StreamMode): StreamPrefs? {
        val store = colourStore ?: return null
        if (!ColourPolicy.optionEnabled(choice, fullChromaAvailable())) return null
        val before = chromaFor(mode)
        store.set(choice)
        return if (chromaFor(mode) != before) prefs(mode) else null
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
     * for (Oyun with the game display on, and a different effective size), else null (nothing to send; the next Oyun
     * entry uses it).
     */
    fun selectGameResolution(r: GameResolution, mode: StreamMode): StreamPrefs? {
        val before = display(mode)
        settings.setGameResolution(r)
        val after = display(mode)
        return if (after != null && after != before) prefs(mode) else null
    }

    companion object {
        /** Decision 0014/0030: "yüksek bit hızı" when the stored choice is Otomatik (Oyun and Çizim). */
        const val GAME_BITRATE_KBPS = 60_000L

        /** What a layer sends for the bit rate [choice] (T-242): Otomatik = [GAME_BITRATE_KBPS], else the choice. */
        fun layerBitrateKbps(choice: Long): Long = if (choice == Bitrate.AUTO_KBPS) GAME_BITRATE_KBPS else choice

        /**
         * The panel label of the bit rate option [kbps] while [layer]'s mode is on (T-242): Otomatik shows what it means
         * there, "Otomatik (60 Mbps)"; in Günlük (null) and for the fixed rates it is [Bitrate.label].
         */
        fun bitrateOptionLabel(layer: StreamMode?, kbps: Long): String =
            if (kbps == Bitrate.AUTO_KBPS && layer != null && Override.BITRATE in overridesOf(layer)) {
                "${Bitrate.label(kbps)} (${Bitrate.mbps(GAME_BITRATE_KBPS)})"
            } else {
                Bitrate.label(kbps)
            }

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
            val high = layerBitrateKbps(saved.bitrateKbps)
            return when (mode) {
                StreamMode.GAME -> saved.copy(bitrateKbps = high, audioOut = AudioOutPref.AUTO, penTrail = false, penDot = false)
                // A stored "tamamen kapat" stays fully off; otherwise one finger goes silent but pinch/scroll still work.
                StreamMode.DRAWING -> saved.copy(
                    bitrateKbps = high,
                    fingers = if (saved.fingers == FingerPolicy.OFF) FingerPolicy.OFF else FingerPolicy.GESTURES_ONLY,
                )
                StreamMode.DAILY -> saved
            }
        }

        /** `ev=mode_layer` fields, e.g. `mode=game action=enter overrides=bitrate,audio,pen jitter=adaptive ...`. */
        fun logFields(t: Transition, jitter: GameJitter.Choice, effective: Values): String =
            "mode=${t.mode.id} action=${t.change.action} overrides=${overridesText(t.mode)} jitter=${GameJitter.label(jitter.bufferFrames)}" +
                (if (jitter.source != GameJitter.Source.MODE) " jitter_src=${jitter.source.id}" else "") +
                " bitrate_kbps=${effective.bitrateKbps} audio_out=${effective.audioOut.id} fingers=${effective.fingers.id}"
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
