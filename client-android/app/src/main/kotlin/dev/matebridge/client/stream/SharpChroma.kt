package dev.matebridge.client.stream

import dev.matebridge.client.protocol.StreamConfig
import dev.matebridge.client.session.KeyValueStore

/**
 * "Keskin renk kenarları" (decision 0033, T-241): stored on/off, default off, in every mode. Its own key in the shared
 * preferences store (like `IdleTimeoutStore`, T-234), so "Varsayılanlara dön" resets it through [reset].
 */
class SharpChromaStore(private val store: KeyValueStore) {
    /** Only a stored "1" enables. */
    fun get(): Boolean = store.getString(KEY) == "1"

    fun set(on: Boolean) = store.putString(KEY, if (on) "1" else "0")

    /** T-191 "Varsayılanlara dön": back to off. Returns true when a value was stored (counted in `ev=settings_reset keys=`). */
    fun reset(): Boolean {
        if (store.getString(KEY) == null) return false
        store.remove(KEY)
        return true
    }

    companion object {
        const val KEY = "sharp_chroma"
    }
}

/**
 * Decision 0033: what the panel shows and what STREAM_PREFS `chroma` carries. The row is shown in every mode; while the
 * running stream is HDR10 ([StreamConfig.isHdr10], `transfer = 16`) the host ignores the field, so the row is grey and
 * marked. The applied value is not reported by the host (PROTOCOL.md 0x05), so `ev=profile chroma=` is the request.
 * Pure Kotlin.
 */
object SharpChromaPolicy {
    const val TITLE = "Keskin renk kenarları"
    const val HDR_MARK = " (HDR açıkken etkisiz)"
    const val OPTION_OFF = "off"
    const val OPTION_ON = "on"

    /** PROTOCOL.md 0x05 `chroma`: 0 normal 4:2:0, 1 sharp colour edges. */
    const val CHROMA_NORMAL = 0
    const val CHROMA_SHARP = 1

    /** STREAM_PREFS `chroma` for the stored setting [on] (every mode; the host ignores it under HDR10). */
    fun chroma(on: Boolean): Int = if (on) CHROMA_SHARP else CHROMA_NORMAL

    /** Grey (and taps ignored) while HDR10 is applied: the setting has no effect then. */
    fun rowEnabled(config: StreamConfig?): Boolean = config?.isHdr10 != true

    /** The row's title mark: " (HDR açıkken etkisiz)" while HDR10 is applied. */
    fun marker(config: StreamConfig?): String = if (rowEnabled(config)) "" else HDR_MARK

    fun selected(on: Boolean): String = if (on) OPTION_ON else OPTION_OFF

    /** The `ev=profile` field, `chroma=0|1` (the requested value). */
    fun profileField(on: Boolean): String = "chroma=${chroma(on)}"
}
