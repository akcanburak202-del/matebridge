package dev.matebridge.client.settings

import dev.matebridge.client.BuildInfo
import dev.matebridge.client.audio.AudioOutPref
import dev.matebridge.client.files.FilesRoot
import dev.matebridge.client.protocol.StreamConfig
import dev.matebridge.client.idle.IdleTimeout
import dev.matebridge.client.session.SpeedRange
import dev.matebridge.client.session.TransportMode
import dev.matebridge.client.stream.Bitrate
import dev.matebridge.client.stream.GameModeSettings
import dev.matebridge.client.stream.GameResolution
import dev.matebridge.client.stream.HdrCapability
import dev.matebridge.client.stream.HdrPolicy
import dev.matebridge.client.stream.ColourChoice
import dev.matebridge.client.stream.ColourPolicy
import dev.matebridge.client.stream.StreamMode
import java.util.Locale

/**
 * Everything a settings control reads or changes (T-105). MainActivity implements it once: persistence
 * ([dev.matebridge.client.session.Settings]) and applying a change (session, audio, input, overlay) live there, and both
 * the connect panel and the in-stream side panel are built from [SettingsCatalog] over the same host, so no setting's
 * logic exists twice. Main thread only.
 */
interface SettingsHost {
    // Bağlantı
    val transportMode: TransportMode
    fun selectTransport(m: TransportMode)
    /** "Bağlantıyı kes": BYE, back to the connect panel, no automatic reconnect until the user connects again. */
    fun disconnect()
    /** T-151 "Bu Mac'i unut" (label from `strings.xml`): opens the two-step confirmation; the host does the rest. */
    val forgetHostLabel: String
    fun forgetHost()

    // Görüntü
    val streamMode: StreamMode
    fun selectStreamMode(m: StreamMode)
    /** "Kare hızı" (decision 0030 §2, T-223): the frame rate the current mode runs at (Çizim: always 120). */
    val frameRate: Int
    /** Stores the rate for the current mode (each mode remembers its own) and asks the host; no effect in Çizim. */
    fun selectFrameRate(fps: Int)
    /** "Oyun çözünürlüğü" (decision 0029, T-215): the stored game display size; applies only in the game modes. */
    val gameResolution: GameResolution
    /** Persists the choice; a STREAM_PREFS goes to the host only while a game mode is on. */
    fun selectGameResolution(r: GameResolution)
    /** The user's bit rate choice, one of [Bitrate.OPTIONS_KBPS] (0 = Otomatik). */
    val bitrateKbps: Long
    fun selectBitrate(kbps: Long)
    /** `STREAM_CONFIG.bitrate_kbps` of the running stream, null without one. */
    val appliedBitrateKbps: Long?
    /** Decision 0032 (T-238): this tablet can show HDR10 (display and decoder), computed once at start. */
    val hdrCapability: HdrCapability
    /** The stored "HDR" setting (applies only in Oyun). */
    val hdrEnabled: Boolean
    /** Persists the choice; a STREAM_PREFS goes to the host only when Oyun's request changes. No effect without the capability. */
    fun selectHdr(on: Boolean)
    /** STREAM_CONFIG of the running stream (the applied dynamic range is read from it), null without one. */
    val appliedConfig: StreamConfig?
    /** Decisions 0033/0034 (T-241, T-260): the stored "Renk" choice (every mode, default Normal). */
    val colourChoice: ColourChoice
    /** The full-chroma capability self-test passed: "Tam renk" is usable (else grey "Bu cihazda yok"). */
    val fullChromaCapable: Boolean
    /** The STREAM_PREFS `chroma` asked of the host right now (2 = Tam renk is in effect for the current mode). */
    val colourRequest: Int
    /** Persists the choice and sends a STREAM_PREFS when what is asked of the host changed. */
    fun selectColour(choice: ColourChoice)
    /**
     * The mode whose temporary layer is in effect (Oyun, decision 0014; Çizim, decision 0030; T-109, T-223), null in
     * Günlük: the settings it overrides ([GameModeSettings.overridesOf]) show and change the session layer, not the
     * stored values; the panels mark them.
     */
    val modeLayer: StreamMode?
    /** "Boşta karart" (decision 0031, T-234): stored; the counter does not run in Oyun. */
    val idleTimeout: IdleTimeout
    /** Persists the choice and restarts the idle counter (a dimmed window comes back). */
    fun selectIdleTimeout(t: IdleTimeout)

    // Ses
    /** False with `--ez audio false`: no audio controls at all. */
    val audioAvailable: Boolean
    val audioEnabled: Boolean
    fun setAudioEnabled(on: Boolean)
    /** The output preference in effect (a launch override included). */
    val audioOut: AudioOutPref
    fun setAudioOut(p: AudioOutPref)

    // Girdi
    val touchpadSpeed: Float
    val mouseSpeed: Float
    /** Multiplies one speed by [factor] (the shortcut steps, [SpeedRange]), persists and applies it. */
    fun stepSpeed(mouse: Boolean, factor: Float)
    val fingerTouchDisabled: Boolean
    fun setFingerTouchDisabled(off: Boolean)
    val penTrail: Boolean
    fun setPenTrail(on: Boolean)
    val penDot: Boolean
    fun setPenDot(on: Boolean)

    // Tablet dosyaları (T-135)
    val filesShare: Boolean
    /** Persists the switch; turning it on without "all files access" opens the system permission screen. */
    fun setFilesShare(on: Boolean)
    /** T-190 (decision 0028): the shared folder; a change restarts a running server with the new root. */
    val filesRoot: FilesRoot
    fun selectFilesRoot(r: FilesRoot)
    /** T-190: read-only sharing; a change restarts a running server. */
    val filesReadOnly: Boolean
    fun setFilesReadOnly(on: Boolean)
    /** The status line under the switch. */
    val filesStatus: String

    // Diğer
    val clipboardShare: Boolean
    fun setClipboardShare(on: Boolean)
    val statsOverlay: Boolean
    fun setStatsOverlay(on: Boolean)

    /** T-191 "Varsayılanlara dön": the two-tap arming state, one for both panels. */
    val resetConfirm: TwoTapConfirm
    /** The first tap armed [resetConfirm]; the host refreshes the panels once the window has passed. */
    fun onResetArmed()
    /**
     * The confirmed reset: every user setting back to its default and the learned audio state cleared; pairing, the
     * device id and the learned wake data stay. Applies the defaults to a live session.
     */
    fun resetToDefaults()
}

/**
 * T-191: a two-step confirmation without a dialog (a dialog is not JVM-testable). The first [tap] only arms it; a second
 * tap within [windowMs] confirms and disarms; a tap after the window is a new first tap. [now] is a monotonic clock in
 * milliseconds. Main thread only.
 */
class TwoTapConfirm(private val now: () -> Long, private val windowMs: Long = WINDOW_MS) {
    private var armedAt: Long? = null

    /** True while a tap would confirm. */
    val armed: Boolean get() = armedAt?.let { within(it, now()) } ?: false

    /** True when this tap confirms; false when it (re)armed. */
    fun tap(): Boolean {
        val t = now()
        val a = armedAt
        if (a != null && within(a, t)) {
            armedAt = null
            return true
        }
        armedAt = t
        return false
    }

    fun cancel() { armedAt = null }

    private fun within(armedAtMs: Long, t: Long) = t - armedAtMs in 0 until windowMs

    companion object {
        const val WINDOW_MS = 5_000L
    }
}

/** One control. Labels are read through lambdas so a refresh shows the current values. */
sealed interface SettingItem {
    val key: String

    /** A row of mutually exclusive buttons; [selected] is the id of the chosen [Option]. */
    class Choice(
        override val key: String,
        val title: String,
        val options: List<Option>,
        val selected: () -> String,
        val marker: () -> String = { "" },
        /** T-223: true while the whole row (title and buttons) is not shown, e.g. "Kare hızı" in Çizim. */
        val hidden: () -> Boolean = { false },
        /** T-238: false while the row is shown grey and its buttons do nothing, e.g. "HDR" without the capability. */
        val enabled: () -> Boolean = { true },
        val select: (String) -> Unit,
    ) : SettingItem {
        /** The title with its current mark, e.g. "Bit hızı (oyun modu)". */
        fun titleText() = title + marker()
    }

    /** One button; its label is read through [labelOf] so a refresh can change it (T-242: "Otomatik (60 Mbps)"). */
    class Option(val id: String, private val labelOf: () -> String) {
        constructor(id: String, label: String) : this(id, labelOf = { label })

        /** T-260: false while this button alone is grey and does nothing, e.g. "Tam renk (Bu cihazda yok)". */
        var enabled: () -> Boolean = { true }
            private set

        fun enabledWhen(f: () -> Boolean): Option = apply { enabled = f }

        val label: String get() = labelOf()
    }

    /** One button showing "title: açık/kapalı"; a tap flips it. */
    class Toggle(
        override val key: String,
        val title: String,
        val get: () -> Boolean,
        val set: (Boolean) -> Unit,
        val onText: String = "açık",
        val offText: String = "kapalı",
        val marker: () -> String = { "" },
    ) : SettingItem {
        fun text() = "$title${marker()}: " + if (get()) onText else offText
    }

    /** "title: value" with − and + buttons. */
    class Stepper(
        override val key: String,
        val title: String,
        val value: () -> String,
        val dec: () -> Unit,
        val inc: () -> Unit,
    ) : SettingItem

    class Action(override val key: String, val title: String, val run: () -> Unit) : SettingItem

    /** Read-only text; [hidden] (T-238) while it is not shown. */
    class Info(override val key: String, val hidden: () -> Boolean = { false }, val text: () -> String) : SettingItem
}

class SettingsSection(val title: String, val items: List<SettingItem>)

/** The single description of the settings controls (T-105, decision 0013), shared by both panels. Pure Kotlin. */
object SettingsCatalog {
    private fun colourNote(h: SettingsHost) =
        ColourPolicy.note(h.colourChoice, h.fullChromaCapable, h.colourRequest, h.appliedConfig)

    private fun colourApplied(h: SettingsHost) = ColourPolicy.applied(h.colourRequest, h.appliedConfig)

    const val SHORTCUTS =
        "Kısayollar: Ctrl+Shift+6: ayarlar paneli · Ctrl+Shift+Esc: Android'e dön · Ctrl+Shift+9/0: imleç hızı · " +
            "Ctrl+Shift+8: istatistik · Ctrl+Shift+7: görüntü modu (Günlük/Çizim/Oyun)"

    /** T-215: only Oyun uses it (the other modes run the native 2800×1840 HiDPI display). */
    const val GAME_RESOLUTION_TITLE = "Oyun çözünürlüğü"

    /** T-223: the frame rate of the current mode (decision 0030 §2). */
    const val FRAME_RATE_TITLE = "Kare hızı"

    /**
     * What the "Kare hızı" title shows next to it: the mode whose rate the buttons change (each mode remembers its own).
     * The row is hidden in Çizim ([SettingItem.Choice.hidden]); the fixed-rate text is only a fallback.
     */
    fun frameRateMarker(mode: StreamMode, fps: Int) =
        if (mode.hasFpsSetting) " (${mode.label})" else " (${mode.label}: hep $fps)"

    /** T-234: idle dim then screen-off (decision 0031). */
    const val IDLE_DIM_TITLE = "Boşta karart"

    /** What the "Boşta karart" title shows: in Oyun the row stays visible but the counter does not run. */
    fun idleDimMarker(mode: StreamMode) = if (mode.isGame) " (Oyun modunda kapalı)" else ""

    const val RESET_TITLE = "Varsayılanlara dön"
    const val RESET_IDLE = "Tüm ayarları varsayılana döndürür; Mac eşleşmesi korunur."
    val RESET_ARMED = "Onaylamak için ${TwoTapConfirm.WINDOW_MS / 1000} saniye içinde yeniden dokun."

    /**
     * Sections in order Bağlantı / Görüntü / Ses / Girdi / Tablet dosyaları / Diğer. [inStream] (the side panel) adds what only makes sense
     * while streaming: "Bağlantıyı kes" and the bit rate the host applied. Ses is left out when audio is unavailable.
     */
    fun sections(h: SettingsHost, inStream: Boolean): List<SettingsSection> {
        fun layered(o: GameModeSettings.Override) = { GameModeSettings.marker(h.modeLayer, o) }
        val out = ArrayList<SettingsSection>(5)
        out += SettingsSection(
            "Bağlantı",
            buildList {
                add(
                    SettingItem.Choice(
                        "transport", "Bağlantı",
                        listOf(
                            SettingItem.Option(TransportMode.AUTO.id, "Otomatik"),
                            SettingItem.Option(TransportMode.USB.id, "Yalnız USB"),
                            SettingItem.Option(TransportMode.WIFI.id, "Yalnız Wi-Fi"),
                        ),
                        { h.transportMode.id },
                    ) { id -> TransportMode.parse(id)?.let { h.selectTransport(it) } },
                )
                if (inStream) add(SettingItem.Action("disconnect", "Bağlantıyı kes") { h.disconnect() })
                add(SettingItem.Action("forget_host", h.forgetHostLabel) { h.forgetHost() }) // T-151, both panels
            },
        )
        out += SettingsSection(
            "Görüntü",
            buildList {
                add(
                    SettingItem.Choice(
                        "stream_mode", "Görüntü modu",
                        StreamMode.entries.map { SettingItem.Option(it.id, it.label) },
                        { h.streamMode.id },
                    ) { id -> h.selectStreamMode(StreamMode.parse(id)) },
                )
                add(
                    SettingItem.Choice(
                        "frame_rate", FRAME_RATE_TITLE,
                        StreamMode.FPS_OPTIONS.map { SettingItem.Option(it.toString(), "$it fps") },
                        { h.frameRate.toString() },
                        { frameRateMarker(h.streamMode, h.frameRate) },
                        { !h.streamMode.hasFpsSetting }, // decision 0030 §2: not shown in Çizim (always 120)
                    ) { id -> id.toIntOrNull()?.let { h.selectFrameRate(it) } },
                )
                add(
                    SettingItem.Choice(
                        "game_resolution", GAME_RESOLUTION_TITLE,
                        // T-250: "2800×1840 (deneysel)" at every Oyun frame rate
                        GameResolution.entries.map { r -> SettingItem.Option(r.id) { r.panelLabel } },
                        { h.gameResolution.id },
                    ) { id -> h.selectGameResolution(GameResolution.parse(id)) },
                )
                add(
                    SettingItem.Choice(
                        "bitrate", "Bit hızı",
                        Bitrate.OPTIONS_KBPS.map { kbps ->
                            SettingItem.Option(kbps.toString()) { GameModeSettings.bitrateOptionLabel(h.modeLayer, kbps) }
                        },
                        { h.bitrateKbps.toString() },
                        layered(GameModeSettings.Override.BITRATE),
                    ) { id -> id.toLongOrNull()?.let { h.selectBitrate(Bitrate.sanitize(it)) } },
                )
                if (inStream) add(SettingItem.Info("bitrate_applied") { Bitrate.appliedLabel(h.appliedBitrateKbps) })
                // Decision 0032 (T-238): only in Oyun; grey "(Bu cihazda yok)" without the capability.
                add(
                    SettingItem.Choice(
                        "hdr", HdrPolicy.TITLE,
                        listOf(SettingItem.Option(HdrPolicy.OPTION_OFF, "Kapalı"), SettingItem.Option(HdrPolicy.OPTION_ON, "Açık")),
                        { HdrPolicy.selected(h.hdrCapability, h.hdrEnabled) },
                        { HdrPolicy.marker(h.hdrCapability) },
                        { HdrPolicy.rowHidden(h.streamMode) },
                        { HdrPolicy.rowEnabled(h.hdrCapability) },
                    ) { id -> if (HdrPolicy.rowEnabled(h.hdrCapability)) h.selectHdr(id == HdrPolicy.OPTION_ON) },
                )
                if (inStream) {
                    add(SettingItem.Info("hdr_applied", { HdrPolicy.rowHidden(h.streamMode) }) { HdrPolicy.appliedLabel(h.appliedConfig) })
                }
                // Decisions 0033/0034 (T-241, T-260): every mode; grey "(HDR açıkken etkisiz)" while HDR10 is applied.
                add(
                    SettingItem.Choice(
                        "colour", ColourPolicy.TITLE,
                        ColourChoice.entries.map { c ->
                            SettingItem.Option(c.id) { ColourPolicy.label(c, h.fullChromaCapable) }.enabledWhen { ColourPolicy.optionEnabled(c, h.fullChromaCapable) }
                        },
                        { ColourPolicy.selected(h.colourChoice, h.fullChromaCapable) },
                        { ColourPolicy.marker(h.appliedConfig) },
                        enabled = { ColourPolicy.rowEnabled(h.appliedConfig) },
                    ) { id ->
                        val c = ColourChoice.parse(id)
                        if (c != null && ColourPolicy.rowEnabled(h.appliedConfig) && ColourPolicy.optionEnabled(c, h.fullChromaCapable)) h.selectColour(c)
                    },
                )
                add(
                    SettingItem.Info("colour_note", { colourNote(h).isEmpty() }) { colourNote(h) },
                )
                if (inStream) {
                    add(SettingItem.Info("colour_applied", { colourApplied(h).isEmpty() }) { colourApplied(h) })
                }
                add(
                    SettingItem.Choice(
                        "idle_dim", IDLE_DIM_TITLE,
                        IdleTimeout.entries.map { SettingItem.Option(it.id, it.label) },
                        { h.idleTimeout.id },
                        { idleDimMarker(h.streamMode) },
                    ) { id -> h.selectIdleTimeout(IdleTimeout.parse(id)) },
                )
            },
        )
        if (h.audioAvailable) {
            out += SettingsSection(
                "Ses",
                listOf(
                    SettingItem.Toggle("audio", "Ses", { h.audioEnabled }, { h.setAudioEnabled(it) }),
                    SettingItem.Choice(
                        "audio_out", "Ses çıkışı",
                        listOf(
                            SettingItem.Option(AudioOutPref.AUTO.id, "Düşük gecikme"),
                            SettingItem.Option(AudioOutPref.TRACK.id, "Uyumlu"),
                        ),
                        { if (h.audioOut == AudioOutPref.TRACK) AudioOutPref.TRACK.id else AudioOutPref.AUTO.id },
                        layered(GameModeSettings.Override.AUDIO),
                    ) { id -> h.setAudioOut(if (id == AudioOutPref.TRACK.id) AudioOutPref.TRACK else AudioOutPref.AUTO) },
                ),
            )
        }
        out += SettingsSection(
            "Girdi",
            listOf(
                SettingItem.Stepper(
                    "touchpad_speed", "Touchpad hızı", { speed(h.touchpadSpeed) },
                    { h.stepSpeed(false, SpeedRange.STEP_DOWN) }, { h.stepSpeed(false, SpeedRange.STEP_UP) },
                ),
                SettingItem.Stepper(
                    "mouse_speed", "Fare hızı", { speed(h.mouseSpeed) },
                    { h.stepSpeed(true, SpeedRange.STEP_DOWN) }, { h.stepSpeed(true, SpeedRange.STEP_UP) },
                ),
                SettingItem.Toggle(
                    "finger_off", "Parmak dokunmasını tamamen kapat", { h.fingerTouchDisabled }, { h.setFingerTouchDisabled(it) },
                    onText = "AÇIK", marker = layered(GameModeSettings.Override.FINGER),
                ),
                SettingItem.Toggle(
                    "pen_trail", "Kalem izi", { h.penTrail }, { h.setPenTrail(it) }, marker = layered(GameModeSettings.Override.PEN),
                ),
                SettingItem.Toggle(
                    "pen_dot", "Kalem noktası", { h.penDot }, { h.setPenDot(it) }, marker = layered(GameModeSettings.Override.PEN),
                ),
            ),
        )
        out += SettingsSection(
            "Tablet dosyaları",
            listOf(
                SettingItem.Toggle("files", "Tablet dosyalarını Mac'te göster", { h.filesShare }, { h.setFilesShare(it) }),
                SettingItem.Choice(
                    "files_root", "Paylaşılan klasör",
                    FilesRoot.entries.map { SettingItem.Option(it.id, it.label) },
                    { h.filesRoot.id },
                ) { id -> h.selectFilesRoot(FilesRoot.parse(id)) },
                SettingItem.Toggle("files_ro", "Salt okunur", { h.filesReadOnly }, { h.setFilesReadOnly(it) }),
                SettingItem.Info("files_status") { h.filesStatus },
            ),
        )
        out += SettingsSection(
            "Diğer",
            listOf(
                SettingItem.Toggle("clipboard", "Pano paylaşımı", { h.clipboardShare }, { h.setClipboardShare(it) }),
                SettingItem.Toggle("stats", "İstatistik katmanı", { h.statsOverlay }, { h.setStatsOverlay(it) }),
                // T-191: two taps; the hint under it shows whether the next tap resets.
                SettingItem.Action("reset_defaults", RESET_TITLE) {
                    if (h.resetConfirm.tap()) h.resetToDefaults() else h.onResetArmed()
                },
                SettingItem.Info("reset_hint") { if (h.resetConfirm.armed) RESET_ARMED else RESET_IDLE },
                SettingItem.Info("shortcuts") { SHORTCUTS },
                SettingItem.Info("version") { BuildInfo.current.settingsText() }, // T-146
            ),
        )
        return out
    }

    /** "1,00" (decimal comma, like the shortcut toast). */
    fun speed(v: Float): String = String.format(Locale.forLanguageTag("tr"), "%.2f", v)
}
