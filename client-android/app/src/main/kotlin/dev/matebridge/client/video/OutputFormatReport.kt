package dev.matebridge.client.video

import java.util.Locale

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
