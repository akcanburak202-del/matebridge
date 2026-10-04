package dev.matebridge.client.video

import java.util.Locale

/**
 * MediaFormat.KEY_OPERATING_RATE policy (T-052): the stream fps ([resolve]). Since T-222 the app default is [MAX]
 * (see [DecoderLatencyKnobs.STANDARD]); the stream fps stays as `--es dec_oprate fps` and as the fallback format.
 */
object OperatingRate {
    /** The value to set, or null to leave the key unset (unknown stream fps). */
    fun resolve(streamFps: Int): Int? = if (streamFps > 0) streamFps else null

    /**
     * T-217 `dec_oprate=max`, the default since T-222: what Moonlight sets for its allowlist (`Short.MAX_VALUE`).
     * On the HiSilicon HEVC decoder it removes the low-clock decode latency at 60 fps (NOTES.md 2026-10-04).
     */
    const val MAX = Short.MAX_VALUE.toInt()
}

/**
 * T-217 (decision 0026): decoder latency keys for the HiSilicon decoder (docs/research/2026-10-04-smoothness.md §1,
 * §4). T-222 adopted `oprate=max` from T-217's device A/B: the app default is [STANDARD] (`off`, `max`). `dec_lowlat`
 * stays off by default (`vdec-lowlatency` is rejected; `hisi` adds ~0.2 ms).
 *
 * [DEFAULT] is the pre-T-217 format (`off`, `fps`): no extra keys, stream-fps operating rate. `VideoRenderer` uses it
 * as the one-shot fallback when a tuning (including [STANDARD]) fails configure/start; [isDefault] means "nothing to
 * fall back from". The name predates T-222.
 *
 * Keys follow Moonlight's `MediaCodecHelper` HiSilicon path. Literal names on purpose (no Android classes here):
 * [LOW_LATENCY] equals `MediaFormat.KEY_LOW_LATENCY`, set here even when the codec does not advertise the feature.
 */
data class DecoderLatencyKnobs(val lowLat: LowLat = LowLat.OFF, val opRate: OpRate = OpRate.MAX) {
    /** `--es dec_lowlat <id>`. */
    enum class LowLat(val id: String) { OFF("off"), HISI("hisi"), VDEC("vdec"), ALL("all") }

    /** `--es dec_oprate <id>`. */
    enum class OpRate(val id: String) { FPS("fps"), MAX("max") }

    /** True for the fallback format itself ([DEFAULT]): a configure failure is not retried. */
    val isDefault: Boolean get() = this == DEFAULT

    /** The operating rate to set (null: leave unset), like [OperatingRate.resolve] for [OpRate.FPS]. */
    fun operatingRate(streamFps: Int): Int? = when (opRate) {
        OpRate.FPS -> OperatingRate.resolve(streamFps)
        OpRate.MAX -> OperatingRate.MAX
    }

    /** The keys added after the default format, in this order. */
    val extraKeys: List<Pair<String, Int>>
        get() {
            val hisi = listOf(HISI_REQ to 1, HISI_RDY to -1)
            val vdec = listOf(VDEC_LOWLATENCY to 1, LOW_LATENCY to 1)
            return when (lowLat) {
                LowLat.OFF -> emptyList()
                LowLat.HISI -> hisi
                LowLat.VDEC -> vdec
                LowLat.ALL -> hisi + vdec
            }
        }

    /**
     * Names of the keys this tuning changes against the fallback [DEFAULT] (`dec_lowlat_rejected keys=`): the extra keys, then
     * [OPERATING_RATE] when the rate differs. Key names only.
     */
    fun changedKeys(): List<String> =
        extraKeys.map { it.first } + if (opRate != OpRate.FPS) listOf(OPERATING_RATE) else emptyList()

    companion object {
        /** T-222: the app default (`dec_lowlat=off`, `dec_oprate=max`). */
        val STANDARD = DecoderLatencyKnobs()

        /** The pre-T-217 format and `VideoRenderer`'s fallback (`off`, `fps`); `--es dec_oprate fps` selects it. */
        val DEFAULT = DecoderLatencyKnobs(LowLat.OFF, OpRate.FPS)

        const val HISI_REQ = "vendor.hisi-ext-low-latency-video-dec.video-scene-for-low-latency-req"
        const val HISI_RDY = "vendor.hisi-ext-low-latency-video-dec.video-scene-for-low-latency-rdy"
        const val VDEC_LOWLATENCY = "vdec-lowlatency"
        /** `MediaFormat.KEY_LOW_LATENCY`. */
        const val LOW_LATENCY = "low-latency"
        /** `MediaFormat.KEY_OPERATING_RATE`. */
        const val OPERATING_RATE = "operating-rate"

        val LOW_LAT_IDS: Set<String> = LowLat.values().map { it.id }.toSet()
        val OP_RATE_IDS: Set<String> = OpRate.values().map { it.id }.toSet()

        /** Raw extras (null = absent); an absent or unknown value gives the [STANDARD] value (`off`, `max`). */
        fun parse(lowLat: String?, opRate: String?): DecoderLatencyKnobs {
            fun norm(v: String?) = v?.trim()?.lowercase(Locale.ROOT)
            return DecoderLatencyKnobs(
                lowLat = LowLat.values().firstOrNull { it.id == norm(lowLat) } ?: STANDARD.lowLat,
                opRate = OpRate.values().firstOrNull { it.id == norm(opRate) } ?: STANDARD.opRate,
            )
        }
    }
}
