package dev.matebridge.client.stream

import dev.matebridge.client.protocol.StreamConfig
import dev.matebridge.client.protocol.StreamPrefs

/**
 * Decision 0032: whether this tablet can show an HDR10 stream. Both must hold: the display reports HDR10
 * (`Display.HdrCapabilities` type [HDR_TYPE_HDR10]) and the HEVC decoder the renderer gets (`createDecoderByType`, the
 * first HEVC decoder of the codec list) advertises [HEVC_PROFILE_MAIN10_HDR10]. Computed once at start (`ev=hdr_caps`).
 * Platform constants are inlined so this stays JVM-testable.
 */
data class HdrCapability(val displayHdr10: Boolean, val decoderMain10Hdr10: Boolean) {
    val supported: Boolean get() = displayHdr10 && decoderMain10Hdr10

    /** `ev=hdr_caps` fields. */
    fun logFields(): String = "display_hdr10=${b(displayHdr10)} decoder_main10hdr10=${b(decoderMain10Hdr10)}"

    /** One entry of the platform codec list, reduced to what the check needs. */
    data class CodecEntry(val isEncoder: Boolean, val types: List<String>, val hevcProfiles: IntArray?) {
        override fun equals(other: Any?) = other is CodecEntry && isEncoder == other.isEncoder && types == other.types &&
            (hevcProfiles?.contentEquals(other.hevcProfiles) ?: (other.hevcProfiles == null))
        override fun hashCode() = 31 * (31 * isEncoder.hashCode() + types.hashCode()) + (hevcProfiles?.contentHashCode() ?: 0)
    }

    companion object {
        val NONE = HdrCapability(displayHdr10 = false, decoderMain10Hdr10 = false)

        /** `Display.HdrCapabilities.HDR_TYPE_HDR10`. */
        const val HDR_TYPE_HDR10 = 2

        /** `MediaCodecInfo.CodecProfileLevel.HEVCProfileMain10HDR10`. */
        const val HEVC_PROFILE_MAIN10_HDR10 = 0x1000

        const val MIME_HEVC = "video/hevc"

        /** The display part: [types] from `getSupportedHdrTypes()` (null = no capabilities object). */
        fun displayHdr10(types: IntArray?): Boolean = types?.contains(HDR_TYPE_HDR10) == true

        /**
         * The decoder part: the first HEVC decoder in [codecs] (codec list order, which `createDecoderByType` follows)
         * lists [HEVC_PROFILE_MAIN10_HDR10]. No HEVC decoder, or profiles unknown: false.
         */
        fun decoderMain10Hdr10(codecs: List<CodecEntry>): Boolean {
            val first = codecs.firstOrNull { !it.isEncoder && it.types.any { t -> t.equals(MIME_HEVC, ignoreCase = true) } }
            return first?.hevcProfiles?.contains(HEVC_PROFILE_MAIN10_HDR10) == true
        }

        private fun b(v: Boolean) = if (v) 1 else 0
    }
}

/**
 * Decision 0032: what the client asks for and what the panel shows. HDR10 is requested only in Günlük or Oyun, with
 * that mode's own "HDR" setting on (T-280: one per mode), on a capable tablet; Çizim and anything else asks for SDR (the
 * group is then not written, PROTOCOL.md 0x05).
 * The applied dynamic range is read only from STREAM_CONFIG ([StreamConfig.isHdr10]). Pure Kotlin.
 */
object HdrPolicy {
    const val TITLE = "HDR"
    const val UNAVAILABLE_MARK = " (Bu cihazda yok)"
    const val OPTION_OFF = "off"
    const val OPTION_ON = "on"

    /** STREAM_PREFS `dynamic_range` for [mode] with [mode]'s own stored setting [userOn] (Çizim is always SDR). */
    fun dynamicRange(cap: HdrCapability, mode: StreamMode, userOn: Boolean): Int =
        if (cap.supported && !mode.isDrawing && userOn) StreamPrefs.DYNAMIC_RANGE_HDR10 else StreamPrefs.DYNAMIC_RANGE_SDR

    /** The "HDR" row is shown in Günlük and Oyun, hidden only in Çizim (stays SDR, decision 0032 update, T-280). */
    fun rowHidden(mode: StreamMode): Boolean = mode.isDrawing

    /** Without the capability the row is grey and does nothing. */
    fun rowEnabled(cap: HdrCapability): Boolean = cap.supported

    /** The row's title mark: " (Bu cihazda yok)" without the capability. */
    fun marker(cap: HdrCapability): String = if (cap.supported) "" else UNAVAILABLE_MARK

    /** The selected option id; without the capability always "off" (nothing will be requested). */
    fun selected(cap: HdrCapability, userOn: Boolean): String = if (cap.supported && userOn) OPTION_ON else OPTION_OFF

    /** In-stream "Uygulanan: HDR10 / SDR" (the bit rate's "Uygulanan" pattern); "—" without a config. */
    fun appliedLabel(config: StreamConfig?): String =
        "Uygulanan: " + when {
            config == null -> "—"
            config.isHdr10 -> "HDR10"
            else -> "SDR"
        }

    /** `ev=hdr_request` fields. */
    fun requestFields(dynamicRange: Int, mode: StreamMode, userOn: Boolean, cap: HdrCapability): String =
        "dynamic_range=$dynamicRange mode=${mode.id} setting=${if (userOn) "on" else "off"} capable=${if (cap.supported) 1 else 0}"
}

/**
 * One `ev=hdr_request` line whenever the requested dynamic range changes (and once for the first request), not one per
 * STREAM_PREFS. Main thread only.
 */
class HdrRequestLog {
    private var last: Int? = null

    /** True when [dynamicRange] differs from the last logged one (and records it). */
    fun take(dynamicRange: Int): Boolean {
        if (last == dynamicRange) return false
        last = dynamicRange
        return true
    }
}
