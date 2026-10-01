package dev.matebridge.client.settings

import dev.matebridge.client.audio.AudioOutPref
import dev.matebridge.client.session.SpeedRange
import dev.matebridge.client.session.TransportMode
import dev.matebridge.client.stream.Bitrate
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

    // Görüntü
    val streamMode: StreamMode
    fun selectStreamMode(m: StreamMode)
    /** The user's bit rate choice, one of [Bitrate.OPTIONS_KBPS] (0 = Otomatik). */
    val bitrateKbps: Long
    fun selectBitrate(kbps: Long)
    /** `STREAM_CONFIG.bitrate_kbps` of the running stream, null without one. */
    val appliedBitrateKbps: Long?

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

    // Diğer
    val clipboardShare: Boolean
    fun setClipboardShare(on: Boolean)
    val statsOverlay: Boolean
    fun setStatsOverlay(on: Boolean)
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
        val select: (String) -> Unit,
    ) : SettingItem

    class Option(val id: String, val label: String)

    /** One button showing "title: açık/kapalı"; a tap flips it. */
    class Toggle(
        override val key: String,
        val title: String,
        val get: () -> Boolean,
        val set: (Boolean) -> Unit,
        val onText: String = "açık",
        val offText: String = "kapalı",
    ) : SettingItem {
        fun text() = "$title: " + if (get()) onText else offText
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

    /** Read-only text. */
    class Info(override val key: String, val text: () -> String) : SettingItem
}

class SettingsSection(val title: String, val items: List<SettingItem>)

/** The single description of the settings controls (T-105, decision 0013), shared by both panels. Pure Kotlin. */
object SettingsCatalog {
    const val SHORTCUTS =
        "Kısayollar: Ctrl+Shift+6: ayarlar paneli · Ctrl+Shift+Esc: Android'e dön · Ctrl+Shift+9/0: imleç hızı · " +
            "Ctrl+Shift+8: istatistik · Ctrl+Shift+7: görüntü modu"

    /**
     * Sections in order Bağlantı / Görüntü / Ses / Girdi / Diğer. [inStream] (the side panel) adds what only makes sense
     * while streaming: "Bağlantıyı kes" and the bit rate the host applied. Ses is left out when audio is unavailable.
     */
    fun sections(h: SettingsHost, inStream: Boolean): List<SettingsSection> {
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
            },
        )
        out += SettingsSection(
            "Görüntü",
            buildList {
                add(
                    SettingItem.Choice(
                        "stream_mode", "Görüntü modu",
                        StreamMode.entries.map { SettingItem.Option(it.id, "${it.label} (${it.fps} fps)") },
                        { h.streamMode.id },
                    ) { id -> h.selectStreamMode(StreamMode.parse(id)) },
                )
                add(
                    SettingItem.Choice(
                        "bitrate", "Bit hızı",
                        Bitrate.OPTIONS_KBPS.map { SettingItem.Option(it.toString(), Bitrate.label(it)) },
                        { h.bitrateKbps.toString() },
                    ) { id -> id.toLongOrNull()?.let { h.selectBitrate(Bitrate.sanitize(it)) } },
                )
                if (inStream) add(SettingItem.Info("bitrate_applied") { Bitrate.appliedLabel(h.appliedBitrateKbps) })
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
                    onText = "AÇIK",
                ),
                SettingItem.Toggle("pen_trail", "Kalem izi", { h.penTrail }, { h.setPenTrail(it) }),
                SettingItem.Toggle("pen_dot", "Kalem noktası", { h.penDot }, { h.setPenDot(it) }),
            ),
        )
        out += SettingsSection(
            "Diğer",
            listOf(
                SettingItem.Toggle("clipboard", "Pano paylaşımı", { h.clipboardShare }, { h.setClipboardShare(it) }),
                SettingItem.Toggle("stats", "İstatistik katmanı", { h.statsOverlay }, { h.setStatsOverlay(it) }),
                SettingItem.Info("shortcuts") { SHORTCUTS },
            ),
        )
        return out
    }

    /** "1,00" (decimal comma, like the shortcut toast). */
    fun speed(v: Float): String = String.format(Locale.forLanguageTag("tr"), "%.2f", v)
}
