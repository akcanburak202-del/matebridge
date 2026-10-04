package dev.matebridge.client.video

import dev.matebridge.client.protocol.StreamConfig
import java.util.Locale

/**
 * T-231 (decision 0026 class, `--ez dev true` gate): developer overrides of the decoder's `KEY_COLOR_RANGE`,
 * `KEY_COLOR_STANDARD` and `KEY_COLOR_TRANSFER` for the lifted-black-level A/B on the tablet (T-230).
 *
 * Each key is [Choice.AUTO] (today's [ColorMapping] of STREAM_CONFIG), a fixed value, or [Choice.UNSET] (the key is not
 * put at all, so the decoder takes the bitstream VUI). [AUTO] is the app default: it puts exactly today's keys and
 * values. The values are the platform `ColorUtils` codes MediaFormat passes through; literals so this stays JVM-testable.
 */
data class ColorOverrides(
    val range: Choice = Choice.AUTO,
    val standard: Choice = Choice.AUTO,
    val transfer: Choice = Choice.AUTO,
) {
    /** One knob value: [id] is the launch-extra value; [value] the key's value for a fixed choice. */
    data class Choice(val id: String, val value: Int?) {
        override fun toString() = id

        companion object {
            val AUTO = Choice("auto", null)
            val UNSET = Choice("unset", null)
            fun fixed(id: String, value: Int) = Choice(id, value)
        }
    }

    /** `KEY_COLOR_STANDARD` to put, null = leave unset. */
    fun standard(config: StreamConfig): Int? = resolve(standard) { ColorMapping.standard(config.matrix) }

    /** `KEY_COLOR_TRANSFER` to put, null = leave unset. */
    fun transfer(config: StreamConfig): Int? = resolve(transfer) { ColorMapping.transfer(config.transfer) }

    /** `KEY_COLOR_RANGE` to put, null = leave unset. */
    fun range(config: StreamConfig): Int? = resolve(range) { ColorMapping.range(config.fullRange) }

    private inline fun resolve(c: Choice, auto: () -> Int?): Int? = when (c) {
        Choice.AUTO -> auto()
        Choice.UNSET -> null
        else -> c.value
    }

    companion object {
        /** The app default: today's mapping for all three keys. */
        val AUTO = ColorOverrides()

        /** `ColorUtils::kColorRange*` (= `MediaFormat.COLOR_RANGE_*`). */
        val RANGE_CHOICES: List<Choice> = listOf(
            Choice.AUTO,
            Choice.fixed("full", ColorMapping.RANGE_FULL),
            Choice.fixed("limited", ColorMapping.RANGE_LIMITED),
            Choice.UNSET,
        )

        /** `MediaFormat.COLOR_STANDARD_BT709` / `COLOR_STANDARD_BT601_NTSC` (the code [ColorMapping] uses for 601). */
        val STANDARD_CHOICES: List<Choice> = listOf(
            Choice.AUTO,
            Choice.fixed("bt709", ColorMapping.STANDARD_BT709),
            Choice.fixed("bt601", ColorMapping.STANDARD_BT601_NTSC),
            Choice.UNSET,
        )

        /**
         * `srgb` = 2 is `ColorUtils::kColorTransferSRGB`: not a public `MediaFormat.COLOR_TRANSFER_*` constant, but
         * passed through to the codec's ColorAspects (`T:2(SRGB)` in the ACodec log). `sdr_video` = `COLOR_TRANSFER_SDR_VIDEO`.
         */
        val TRANSFER_CHOICES: List<Choice> = listOf(
            Choice.AUTO,
            Choice.fixed("srgb", TRANSFER_SRGB),
            Choice.fixed("sdr_video", ColorMapping.TRANSFER_SDR_VIDEO),
            Choice.UNSET,
        )

        const val TRANSFER_SRGB = 2

        /** The only values that may be logged for each knob (`DevKnobs.Spec.ids`). */
        val RANGE_IDS: Set<String> = RANGE_CHOICES.map { it.id }.toSet()
        val STANDARD_IDS: Set<String> = STANDARD_CHOICES.map { it.id }.toSet()
        val TRANSFER_IDS: Set<String> = TRANSFER_CHOICES.map { it.id }.toSet()

        /** Raw extras (null = absent); an absent or unknown value is `auto`. */
        fun parse(range: String?, standard: String?, transfer: String?): ColorOverrides = ColorOverrides(
            range = pick(RANGE_CHOICES, range),
            standard = pick(STANDARD_CHOICES, standard),
            transfer = pick(TRANSFER_CHOICES, transfer),
        )

        private fun pick(choices: List<Choice>, raw: String?): Choice {
            val v = raw?.trim()?.lowercase(Locale.ROOT)
            return choices.firstOrNull { it.id == v } ?: Choice.AUTO
        }
    }
}

/**
 * T-231: the `ev=decoder_output_format` fields: the colour keys of the decoder's output format after
 * `INFO_OUTPUT_FORMAT_CHANGED`, its `hdr-static-info` (hex, when present), and the colour keys given to configure.
 * Numbers and hex only.
 */
object OutputFormatReport {
    const val KEY_RANGE = "color-range"
    const val KEY_STANDARD = "color-standard"
    const val KEY_TRANSFER = "color-transfer"
    /** `MediaFormat.KEY_HDR_STATIC_INFO`. */
    const val KEY_HDR_STATIC_INFO = "hdr-static-info"
    /** Longest `hdr-static-info` logged; the CTA-861.3 Type 1 blob is 25 bytes. Longer ones add `+<n>` (bytes left out). */
    const val MAX_HDR_BYTES = 64

    /**
     * `range=<v>|unset standard=… transfer=… hdr_static_info=<hex>|unset|? req_range=<v>|unset req_standard=…
     * req_transfer=…`. [requested]: the integer keys given to configure (null = unknown, all `unset`).
     */
    fun fields(out: DecoderCodec.FormatView, requested: Map<String, Int>?): String {
        fun key(k: String): String = try {
            if (out.containsKey(k)) out.getInteger(k).toString() else "unset"
        } catch (e: Exception) { "?" }
        fun req(k: String): String = requested?.get(k)?.toString() ?: "unset"
        return "range=${key(KEY_RANGE)} standard=${key(KEY_STANDARD)} transfer=${key(KEY_TRANSFER)} " +
            "hdr_static_info=${hdr(out)} " +
            "req_range=${req(KEY_RANGE)} req_standard=${req(KEY_STANDARD)} req_transfer=${req(KEY_TRANSFER)}"
    }

    private fun hdr(out: DecoderCodec.FormatView): String {
        val buf = try {
            if (!out.containsKey(KEY_HDR_STATIC_INFO)) return "unset"
            out.getByteBuffer(KEY_HDR_STATIC_INFO) ?: return "?"
        } catch (e: Exception) { return "?" }
        val b = buf.duplicate() // never move the format's own buffer
        val n = b.remaining()
        if (n == 0) return "empty"
        val sb = StringBuilder()
        for (i in 0 until minOf(n, MAX_HDR_BYTES)) sb.append(String.format(Locale.ROOT, "%02x", b.get().toInt() and 0xff))
        if (n > MAX_HDR_BYTES) sb.append("+").append(n - MAX_HDR_BYTES)
        return sb.toString()
    }
}

/**
 * T-231: one `ev=decoder_output_format` line per output-format change of a codec: a change that reports the same fields
 * as the previous line is not repeated, and at most [MAX_LINES] lines per codec. One instance per codec, output thread.
 */
class OutputFormatLogGate {
    private var last: String? = null
    private var lines = 0

    /** True when [fields] should be logged now (and records it). */
    fun take(fields: String): Boolean {
        if (fields == last || lines >= MAX_LINES) return false
        last = fields
        lines++
        return true
    }

    companion object {
        const val MAX_LINES = 16
    }
}
