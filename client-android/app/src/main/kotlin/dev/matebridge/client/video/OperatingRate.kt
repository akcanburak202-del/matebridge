package dev.matebridge.client.video

import java.util.Locale

/**
 * MediaFormat.KEY_OPERATING_RATE policy (T-052): the stream fps. The `--ei oprate` switch is retired (T-183); the
 * HiSilicon decoder does not take the key (NOTES.md), but the default stays until shown to be a no-op.
 */
object OperatingRate {
    /** The value to set, or null to leave the key unset (unknown stream fps). */
    fun resolve(streamFps: Int): Int? = if (streamFps > 0) streamFps else null

    /** T-217 `dec_oprate=max`: what Moonlight sets for its allowlist (`Short.MAX_VALUE`). */
    const val MAX = Short.MAX_VALUE.toInt()
}

/**
 * T-217 (decision 0026: default off, closed by T-217's device result): decoder latency keys for an A/B on the
 * HiSilicon decoder (docs/research/2026-10-04-smoothness.md §1, §4). [DEFAULT] adds nothing and keeps the stream-fps
 * operating rate, so the format is exactly the pre-T-217 one.
 *
 * Keys follow Moonlight's `MediaCodecHelper` HiSilicon path. Literal names on purpose (no Android classes here):
 * [LOW_LATENCY] equals `MediaFormat.KEY_LOW_LATENCY`, set here even when the codec does not advertise the feature.
 */
data class DecoderLatencyKnobs(val lowLat: LowLat = LowLat.OFF, val opRate: OpRate = OpRate.FPS) {
    /** `--es dec_lowlat <id>`. */
    enum class LowLat(val id: String) { OFF("off"), HISI("hisi"), VDEC("vdec"), ALL("all") }

    /** `--es dec_oprate <id>`. */
    enum class OpRate(val id: String) { FPS("fps"), MAX("max") }

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
     * Names of the keys this tuning changes against [DEFAULT] (`dec_lowlat_rejected keys=`): the extra keys, then
     * [OPERATING_RATE] when the rate differs. Key names only.
     */
    fun changedKeys(): List<String> =
        extraKeys.map { it.first } + if (opRate != OpRate.FPS) listOf(OPERATING_RATE) else emptyList()

    companion object {
        val DEFAULT = DecoderLatencyKnobs()

        const val HISI_REQ = "vendor.hisi-ext-low-latency-video-dec.video-scene-for-low-latency-req"
        const val HISI_RDY = "vendor.hisi-ext-low-latency-video-dec.video-scene-for-low-latency-rdy"
        const val VDEC_LOWLATENCY = "vdec-lowlatency"
        /** `MediaFormat.KEY_LOW_LATENCY`. */
        const val LOW_LATENCY = "low-latency"
        /** `MediaFormat.KEY_OPERATING_RATE`. */
        const val OPERATING_RATE = "operating-rate"

        val LOW_LAT_IDS: Set<String> = LowLat.values().map { it.id }.toSet()
        val OP_RATE_IDS: Set<String> = OpRate.values().map { it.id }.toSet()

        /** Raw extras (null = absent); an unknown value keeps the default. */
        fun parse(lowLat: String?, opRate: String?): DecoderLatencyKnobs {
            fun norm(v: String?) = v?.trim()?.lowercase(Locale.ROOT)
            return DecoderLatencyKnobs(
                lowLat = LowLat.values().firstOrNull { it.id == norm(lowLat) } ?: LowLat.OFF,
                opRate = OpRate.values().firstOrNull { it.id == norm(opRate) } ?: OpRate.FPS,
            )
        }
    }
}
