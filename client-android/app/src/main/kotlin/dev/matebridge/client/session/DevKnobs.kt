package dev.matebridge.client.session

import dev.matebridge.client.video.PacerTuning
import java.util.Locale

/** Read access to launch extras (Android: an `Intent`). Pure, so [DevKnobs] is JVM-testable. */
interface LaunchExtras {
    fun has(key: String): Boolean
    fun int(key: String, default: Int): Int
    fun bool(key: String, default: Boolean): Boolean
    fun string(key: String): String?

    companion object {
        val NONE = object : LaunchExtras {
            override fun has(key: String) = false
            override fun int(key: String, default: Int) = default
            override fun bool(key: String, default: Boolean) = default
            override fun string(key: String): String? = null
        }
    }
}

/**
 * T-185 (decision 0026 §3, `docs/KNOBS.md`): MainActivity's launch extras behind the developer gate.
 *
 * `MainActivity` is the exported launcher and the daily APK is the debug variant, so any app (or a mistyped `am start`)
 * can pass extras. "Debug-only" keys take effect only when the same launch also passes `--ez dev true`; without it they
 * keep their defaults and are listed in [ignored] (keys only, never values). "Keep" keys (diagnostics) apply either way.
 *
 * Every field is the effective value: read through the gated view, so the gate cannot be bypassed by a reader.
 */
data class DevKnobs(
    /** `--ez dev true` was given. */
    val dev: Boolean = false,
    /** Debug-only keys that were present but ignored because [dev] was not set ([SPECS] order). */
    val ignored: List<String> = emptyList(),
    /** Honoured, profile-relevant knobs as `key:value` ([SPECS] order); the `ev=profile` `knobs=` field. */
    val knobs: List<String> = emptyList(),
    /** `--ei hz N`: null = follow the stream. */
    val hz: Int? = null,
    /** `--ei lead_us N` (>= 0); null = default lead. */
    val leadUs: Int? = null,
    /** `--ei deadline_us N`: null = default; -1 = the display's deadline; >= 0 = N us. */
    val deadlineUs: Int? = null,
    /** `ping_ms` (T-089). */
    val wifi: WifiKnobs = WifiKnobs(),
    /** `--ez audio false` turns audio off (T-095). */
    val audio: Boolean = true,
    /** `--es transport auto|usb|wifi` raw value (T-096); null = absent. */
    val transport: String? = null,
    /** `--es audio_out aaudio|track|auto` raw value (T-100/T-101); null = absent. */
    val audioOut: String? = null,
    /** `--ei audio_buf_bursts N` (T-110); null = absent. */
    val audioBufBursts: Int? = null,
    /** `--es audio_idle_pause off|pause|stop` raw value (T-287); null = absent. */
    val audioIdlePause: String? = null,
    /** `--ez quickack false` turns TCP_QUICKACK off (T-074). */
    val quickAck: Boolean = true,
    /** `--es net_bench HOST:PORT`: forward to the debug NetBench screen (T-090). The value is never kept or logged here. */
    val netBench: Boolean = false,
    /** `--es decoder_fault <mode>` raw value (T-159); null = absent. */
    val decoderFault: String? = null,
    /** `--ei decoder_fault_after_s N`; null = absent. */
    val decoderFaultAfterS: Int? = null,
    /**
     * `--ei game_display 0` (T-215, decision 0029): game modes send STREAM_PREFS without the `display_*` group (0×0,
     * the native HiDPI display) for A/B; any other value or absent = the "Oyun çözünürlüğü" setting applies.
     */
    val gameDisplay: Boolean = true,
    /**
     * `--ei pace_dcap_half N`, `--ez pace_feedback false` (T-251): adaptive pacer D cap (half periods) and the skip
     * feedback. Absent = [PacerTuning.STANDARD].
     */
    val pacerTuning: PacerTuning = PacerTuning.STANDARD,
    /** `--ez catch_up false` (T-252): the pre-T-252 queue overflow (flush + keyframe request) for A/B. Default on. */
    val catchUp: Boolean = true,
    /**
     * `--es dec_out_park off|on` (T-312, CB2): the decoder output thread parks while the codec holds nothing instead of
     * polling every 5 ms. A/B knob; default off (off = the pre-T-312 poll). Applies to codecs started afterwards.
     */
    val decOutPark: Boolean = false,
    /** `--ez cursor_predict false` (T-278, decision 0036 v2): the local cursor draws the host's position as in v1. Default on. */
    val cursorPredict: Boolean = true,
    /** Keep: `--ez stats_1s true` (T-141). */
    val stats1s: Boolean = false,
    /** Keep: `--ez pace_trace true` (T-069). */
    val paceTrace: Boolean = false,
    /** Keep: `--ez stall_diag true` (T-142). */
    val stallDiag: Boolean = false,
) {
    /** `dev=0|1 ignored=<key>[,<key>…]|-` for the `diag ev=dev_knobs` line (format kept stable for T-127). */
    fun logFields(): String = "dev=${if (dev) 1 else 0} ignored=${ignored.joinToString(",").ifEmpty { "-" }}"

    enum class Kind { INT, BOOL, STRING }

    /**
     * One launch extra. [ids]: the only string values that may be logged (anything else logs as `other`), so a value
     * such as an address can never reach a log line. [inProfile] false: never listed in `knobs=`.
     */
    class Spec(
        val key: String,
        val kind: Kind,
        val debugOnly: Boolean,
        val ids: Set<String> = emptySet(),
        val inProfile: Boolean = true,
    )

    companion object {
        const val EXTRA_DEV = "dev"

        /** Decision 0026 classes (`docs/KNOBS.md`), in log order. */
        val SPECS: List<Spec> = listOf(
            Spec("hz", Kind.INT, debugOnly = true),
            Spec("lead_us", Kind.INT, debugOnly = true),
            Spec("deadline_us", Kind.INT, debugOnly = true),
            Spec("ping_ms", Kind.INT, debugOnly = true),
            Spec("audio", Kind.BOOL, debugOnly = true),
            Spec("transport", Kind.STRING, debugOnly = true, ids = setOf("auto", "usb", "wifi")),
            Spec("audio_out", Kind.STRING, debugOnly = true, ids = setOf("auto", "aaudio", "track", "audiotrack")),
            Spec("audio_buf_bursts", Kind.INT, debugOnly = true),
            Spec("audio_idle_pause", Kind.STRING, debugOnly = true, ids = setOf("off", "pause", "stop")),
            Spec("quickack", Kind.BOOL, debugOnly = true),
            Spec("net_bench", Kind.STRING, debugOnly = true, inProfile = false),
            Spec("net_bench_s", Kind.INT, debugOnly = true, inProfile = false),
            Spec("net_bench_dir", Kind.STRING, debugOnly = true, inProfile = false),
            Spec("net_bench_streams", Kind.INT, debugOnly = true, inProfile = false),
            Spec("net_bench_rcvbuf_kb", Kind.INT, debugOnly = true, inProfile = false),
            Spec("decoder_fault", Kind.STRING, debugOnly = true, ids = setOf("create", "configure", "dequeue", "silent")),
            Spec("decoder_fault_after_s", Kind.INT, debugOnly = true),
            Spec("game_display", Kind.INT, debugOnly = true),
            Spec("pace_dcap_half", Kind.INT, debugOnly = true),
            Spec("pace_feedback", Kind.BOOL, debugOnly = true),
            Spec("catch_up", Kind.BOOL, debugOnly = true),
            Spec("dec_out_park", Kind.STRING, debugOnly = true, ids = setOf("off", "on")),
            Spec("cursor_predict", Kind.BOOL, debugOnly = true),
            Spec("stats_1s", Kind.BOOL, debugOnly = false),
            Spec("pace_trace", Kind.BOOL, debugOnly = false),
            Spec("stall_diag", Kind.BOOL, debugOnly = false),
        )

        val DEBUG_ONLY_KEYS: Set<String> = SPECS.filter { it.debugOnly }.map { it.key }.toSet()

        fun parse(raw: LaunchExtras): DevKnobs {
            val dev = raw.bool(EXTRA_DEV, false)
            val ignored = if (dev) emptyList() else SPECS.filter { it.debugOnly && raw.has(it.key) }.map { it.key }
            val x = Gated(raw, dev)
            val knobs = SPECS.filter { it.inProfile && x.has(it.key) }.map { "${it.key}:${value(x, it)}" }
            return DevKnobs(
                dev = dev,
                ignored = ignored,
                knobs = knobs,
                hz = if (x.has("hz")) x.int("hz", -1) else null,
                leadUs = if (x.has("lead_us")) x.int("lead_us", -1).takeIf { it >= 0 } else null,
                deadlineUs = if (x.has("deadline_us")) x.int("deadline_us", -1) else null,
                wifi = WifiKnobs.parse({ x.has(it) }, { x.int(it, 0) }),
                audio = x.bool("audio", true),
                transport = x.string("transport"),
                audioOut = x.string("audio_out"),
                audioBufBursts = if (x.has("audio_buf_bursts")) x.int("audio_buf_bursts", 0) else null,
                audioIdlePause = x.string("audio_idle_pause"),
                quickAck = if (x.has("quickack")) x.bool("quickack", true) else true,
                netBench = x.has("net_bench"),
                decoderFault = x.string("decoder_fault"),
                decoderFaultAfterS = if (x.has("decoder_fault_after_s")) x.int("decoder_fault_after_s", 0) else null,
                gameDisplay = !(x.has("game_display") && x.int("game_display", 1) == 0),
                pacerTuning = PacerTuning.parse(
                    if (x.has("pace_dcap_half")) x.int("pace_dcap_half", 0) else null, x.bool("pace_feedback", true),
                ),
                catchUp = x.bool("catch_up", true),
                decOutPark = x.string("dec_out_park")?.trim()?.lowercase(Locale.ROOT) == "on",
                cursorPredict = x.bool("cursor_predict", true),
                stats1s = x.bool("stats_1s", false),
                paceTrace = x.bool("pace_trace", false),
                stallDiag = x.bool("stall_diag", false),
            )
        }

        /** A loggable value: numbers and 0/1 as they are; strings only as a known id, else `other`. */
        private fun value(x: LaunchExtras, s: Spec): String = when (s.kind) {
            Kind.INT -> x.int(s.key, 0).toString()
            Kind.BOOL -> if (x.bool(s.key, false)) "1" else "0"
            Kind.STRING -> x.string(s.key)?.trim()?.lowercase(Locale.ROOT)?.takeIf { it in s.ids } ?: "other"
        }
    }

    /** Debug-only keys are absent unless [dev]; an absent key reads as its default. */
    private class Gated(private val raw: LaunchExtras, private val dev: Boolean) : LaunchExtras {
        override fun has(key: String) = raw.has(key) && (dev || key !in DEBUG_ONLY_KEYS)
        override fun int(key: String, default: Int) = if (has(key)) raw.int(key, default) else default
        override fun bool(key: String, default: Boolean) = if (has(key)) raw.bool(key, default) else default
        override fun string(key: String): String? = if (has(key)) raw.string(key) else null
    }
}

/**
 * T-185 (decision 0026 §4): the client `ev=profile` line, once per installed STREAM_CONFIG, so every measurement names
 * its configuration. Built only from enumerated values and numbers: never an endpoint address, serial number or
 * device id. `is_hw` is not here: the codec for this config starts asynchronously (it is in `ev=codec_start`, T-168).
 */
data class StreamProfile(
    /** [StreamMode.id] chosen on the tablet. */
    val mode: String,
    /** Effective stream fps and encoded size (STREAM_CONFIG). */
    val fps: Int,
    val widthPx: Int,
    val heightPx: Int,
    /** The mode's requested scale (permille of the display). */
    val scalePermille: Int,
    /** STREAM_CONFIG bit rate (applied) and the tablet's setting (0 = auto, decision 0013). */
    val bitrateKbps: Long,
    val bitrateSettingKbps: Long,
    /** Transport of the current connection (`usb`/`wifi`, `-` unknown) and the connection-mode setting in effect. */
    val transport: String,
    val transportMode: String,
    /** Audio playback on, and the output preference in effect ([AudioOutPref.id]). */
    val audioOn: Boolean,
    val audioOut: String,
    /** T-215: the requested game display (STREAM_PREFS `display_*`); 0×0 = native HiDPI display. */
    val displayWidthPx: Int = 0,
    val displayHeightPx: Int = 0,
    /** T-215: the host applied the requested game display (full geometry, `GameResolution.appliedIn`). */
    val displayApplied: Boolean = false,
    /** T-238 (decision 0032): the host applied HDR10 (STREAM_CONFIG transfer 16). */
    val hdr: Boolean = false,
) {
    fun logFields(sha: String, built: String, knobs: DevKnobs): String =
        "mode=${id(mode)} fps=$fps size=${widthPx}x$heightPx scale_permille=$scalePermille ${displayFields()} " +
            "hdr=${if (hdr) 1 else 0} " +
            "bitrate_kbps=$bitrateKbps " +
            "bitrate_setting=${if (bitrateSettingKbps <= 0) "auto" else bitrateSettingKbps.toString()} " +
            "transport=${id(transport)} transport_mode=${id(transportMode)} audio=${if (audioOn) 1 else 0} " +
            "audio_out=${id(audioOut)} pacer=adaptive " + // constant since T-303; tools/measure/mblog.py reads it
            "sha=${token(sha)} built=${token(built)} dev=${if (knobs.dev) 1 else 0} " +
            "knobs=${knobs.knobs.joinToString(";").ifEmpty { "-" }}"

    /** `display=native`, or `display=<w>x<h> display_applied=0|1` when a game display was requested (T-215). */
    private fun displayFields(): String =
        if (displayWidthPx <= 0 && displayHeightPx <= 0) "display=native"
        else "display=${displayWidthPx}x$displayHeightPx display_applied=${if (displayApplied) 1 else 0}"

    private companion object {
        private val ID = Regex("[a-z0-9_]{1,16}")
        private val TOKEN = Regex("[A-Za-z0-9_:-]{1,40}") // short SHA[-dirty], yyyy-MM-ddTHH:mmZ; no dots

        /** An enum id as given; anything else (never expected) logs as `other`. */
        fun id(v: String): String = if (v == "-" || ID.matches(v)) v else "other"

        /** A build identifier (BuildInfo already cleaned it); anything unexpected logs as `unknown`. */
        fun token(v: String): String = if (TOKEN.matches(v)) v else "unknown"
    }
}
