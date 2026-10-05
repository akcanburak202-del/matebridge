package dev.matebridge.client.stream

import dev.matebridge.client.protocol.StreamPrefs
import dev.matebridge.client.session.KeyValueStore

/**
 * The user's "Renk" choice (decision 0034): Normal / Keskin kenarlar / Tam renk. This card (T-259) only READS it; the
 * panel row and the migration of the old on/off value are T-260.
 */
enum class ColourChoice(val id: String) {
    NORMAL("normal"), SHARP("sharp"), FULL("full");

    companion object {
        fun parse(id: String?): ColourChoice? = entries.firstOrNull { it.id == id }
    }
}

/**
 * Reads the stored colour choice: the `colour` key (T-260 writes it), else the pre-0034 "Keskin renk kenarları" switch
 * (`sharp_chroma` = "1" -> [ColourChoice.SHARP]), else [ColourChoice.NORMAL]. Pure over [KeyValueStore].
 */
class ColourStore(private val store: KeyValueStore) {
    fun get(): ColourChoice =
        ColourChoice.parse(store.getString(KEY))
            ?: if (store.getString(SharpChromaStore.KEY) == "1") ColourChoice.SHARP else ColourChoice.NORMAL

    fun set(choice: ColourChoice) = store.putString(KEY, choice.id)

    companion object {
        const val KEY = "colour"
    }
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
