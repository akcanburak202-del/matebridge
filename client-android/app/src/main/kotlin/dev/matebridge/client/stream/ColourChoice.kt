package dev.matebridge.client.stream

import dev.matebridge.client.protocol.StreamConfig
import dev.matebridge.client.protocol.StreamPrefs
import dev.matebridge.client.session.KeyValueStore

/** The user's "Renk" choice (decision 0034): Normal / Keskin kenarlar / Tam renk. Default [NORMAL]. */
enum class ColourChoice(val id: String) {
    NORMAL("normal"), SHARP("sharp"), FULL("full");

    companion object {
        fun parse(id: String?): ColourChoice? = entries.firstOrNull { it.id == id }
    }
}

/**
 * The stored colour choice: the `colour` key (the panel writes it). The pre-0034 "Keskin renk kenarları" switch
 * (`sharp_chroma` = "1", decision 0033) is migrated by [migrate] (Açık -> [ColourChoice.SHARP]) and, until then, still
 * read by [get]. Pure over [KeyValueStore].
 */
class ColourStore(private val store: KeyValueStore) {
    fun get(): ColourChoice =
        ColourChoice.parse(store.getString(KEY))
            ?: if (store.getString(LEGACY_SHARP_KEY) == "1") ColourChoice.SHARP else ColourChoice.NORMAL

    /** Stores [choice]; the legacy key is dropped so the two can never disagree. */
    fun set(choice: ColourChoice) {
        store.putString(KEY, choice.id)
        store.remove(LEGACY_SHARP_KEY)
    }

    /** One-time move of the 0033 value into `colour`; true when a legacy value was found. A stored `colour` wins. */
    fun migrate(): Boolean {
        val legacy = store.getString(LEGACY_SHARP_KEY) ?: return false
        if (store.getString(KEY) == null && legacy == "1") store.putString(KEY, ColourChoice.SHARP.id)
        store.remove(LEGACY_SHARP_KEY)
        return true
    }

    /** "Varsayılanlara dön": back to Normal. True when something was stored (counted in `ev=settings_reset keys=`). */
    fun reset(): Boolean {
        val had = store.getString(KEY) != null || store.getString(LEGACY_SHARP_KEY) != null
        store.remove(KEY)
        store.remove(LEGACY_SHARP_KEY)
        return had
    }

    companion object {
        const val KEY = "colour"
        const val LEGACY_SHARP_KEY = "sharp_chroma"
    }
}

/**
 * What the "Renk" panel row shows (decision 0034 §2). Pure Kotlin. `request` is the STREAM_PREFS `chroma` the client
 * currently sends ([GameModeSettings.chromaFor]); `2` means the packed path is wanted right now.
 */
object ColourPolicy {
    const val TITLE = "Renk"
    const val HDR_MARK = " (HDR açıkken etkisiz)"
    const val UNAVAILABLE_MARK = " (Bu cihazda yok)"
    const val NOTE_FULL_ONLY_DAILY_60 = "Tam renk yalnız Günlük 60'ta, şimdi: Keskin kenarlar"
    const val APPLIED_FULL = "Uygulanan: Tam renk"
    const val APPLIED_FELL_BACK = "Uygulanan: Normal (Mac yetişemedi)"

    fun label(c: ColourChoice, capable: Boolean): String = when (c) {
        ColourChoice.NORMAL -> "Normal"
        ColourChoice.SHARP -> "Keskin kenarlar"
        ColourChoice.FULL -> "Tam renk" + if (capable) "" else UNAVAILABLE_MARK
    }

    /** Tam renk is grey without the passed capability self-test. */
    fun optionEnabled(c: ColourChoice, capable: Boolean): Boolean = c != ColourChoice.FULL || capable

    /** The highlighted option: a stored Tam renk on a tablet without the capability shows as Keskin kenarlar (what applies). */
    fun selected(stored: ColourChoice, capable: Boolean): String =
        (if (stored == ColourChoice.FULL && !capable) ColourChoice.SHARP else stored).id

    /** Grey (taps ignored) while HDR10 is applied: the host ignores `chroma` then. */
    fun rowEnabled(config: StreamConfig?): Boolean = config?.isHdr10 != true

    fun marker(config: StreamConfig?): String = if (rowEnabled(config)) "" else HDR_MARK

    /** Note under the row: Tam renk is chosen and usable but not requested in this mode/rate; "" otherwise. */
    fun note(stored: ColourChoice, capable: Boolean, request: Int, config: StreamConfig?): String =
        if (stored == ColourChoice.FULL && capable && request != StreamPrefs.CHROMA_FULL && rowEnabled(config)) NOTE_FULL_ONLY_DAILY_60
        else ""

    /** Applied line (only while Tam renk is requested and a stream runs): what STREAM_CONFIG `chroma_layout` says; "" otherwise. */
    fun applied(request: Int, config: StreamConfig?): String = when {
        request != StreamPrefs.CHROMA_FULL || config == null || config.isHdr10 -> ""
        config.isPacked444 -> APPLIED_FULL
        else -> APPLIED_FELL_BACK
    }

    /** The `ev=profile` field: the requested `chroma` value. */
    fun profileField(request: Int): String = "chroma=$request"
}

/**
 * Which STREAM_PREFS `chroma` the client sends (decision 0034, PROTOCOL.md 0x05 "Tam renk"). `2` only when the user chose
 * [ColourChoice.FULL] and every condition of the packed path holds: Günlük, 60 fps, native display (no game display),
 * full scale, SDR, and the capability self-test passed. Otherwise a chosen Tam renk falls back to the sharp value `1`.
 */
object FullChromaPolicy {
    /** The conditions that depend on the mode and the request (not on the choice or the capability). */
    fun eligible(mode: StreamMode, fps: Int, naturalDisplay: Boolean, scalePermille: Int, dynamicRange: Int): Boolean =
        mode == StreamMode.DAILY && fps == 60 && naturalDisplay &&
            scalePermille == StreamMode.SCALE_PERMILLE && dynamicRange == StreamPrefs.DYNAMIC_RANGE_SDR

    fun chromaRequest(
        choice: ColourChoice, mode: StreamMode, fps: Int, naturalDisplay: Boolean, scalePermille: Int, dynamicRange: Int,
        capable: Boolean,
    ): Int = when (choice) {
        ColourChoice.NORMAL -> StreamPrefs.CHROMA_NORMAL
        ColourChoice.SHARP -> StreamPrefs.CHROMA_SHARP
        ColourChoice.FULL ->
            if (capable && eligible(mode, fps, naturalDisplay, scalePermille, dynamicRange)) StreamPrefs.CHROMA_FULL
            else StreamPrefs.CHROMA_SHARP
    }
}
