package dev.matebridge.client.stream

import java.lang.reflect.Modifier
import java.util.Locale

/**
 * T-243 experiment (`--es hz_pin off|lp|all`, behind `--ez dev true`): extra platform hints that try to keep the panel at
 * 60 Hz in Oyun 60 although touch raises it to 120 Hz (NOTES 2026-10-05). `off` (default) = today's calls only.
 */
enum class HzPinVariant(val id: String) {
    OFF("off"),

    /** Window hints: `LayoutParams.preferredRefreshRate` and `preferredMin/MaxDisplayRefreshRate` (API 34, reflection). */
    LP("lp"),

    /** [LP] plus Huawei extension discovery and re-issuing `Surface.setFrameRate` on every rate change and touch start. */
    ALL("all");

    companion object {
        val IDS: Set<String> = entries.map { it.id }.toSet()

        /** Absent or unknown = [OFF]. */
        fun parse(raw: String?): HzPinVariant {
            val v = raw?.trim()?.lowercase(Locale.ROOT) ?: return OFF
            return entries.firstOrNull { it.id == v } ?: OFF
        }
    }
}

/** One hint of the experiment; [id] is its log name in `ev=hz_pin applied=`. */
enum class HzPinHint(val id: String) {
    /** `WindowManager.LayoutParams.preferredRefreshRate = 60f`, set together with `preferredDisplayModeId`. */
    LP_RATE("lp_rate"),

    /** `preferredMinDisplayRefreshRate` / `preferredMaxDisplayRefreshRate = 60f` (API 34 fields, by reflection). */
    LP_MINMAX("lp_minmax"),

    /** Read-only discovery of vendor (Huawei) refresh fields on `LayoutParams`; nothing is written. */
    HW_LP("hw_lp"),

    /** Re-issue `Surface.setFrameRate` on every `display_rate` change and every touch start (ACTION_DOWN). */
    REAPPLY("reapply"),
}

/** Outcome of one hint; [id] is its log name. */
enum class HzPinResult(val id: String) { OK("ok"), MISSING("missing"), ERROR("error") }

object HzPin {
    /** The rate the experiment pins to (Oyun 60). */
    const val PIN_HZ = 60

    /** The stream fps the experiment applies to. */
    const val PIN_FPS = 60

    const val FIELD_PREFERRED_REFRESH_RATE = "preferredRefreshRate"
    const val FIELD_MIN_RATE = "preferredMinDisplayRefreshRate"
    const val FIELD_MAX_RATE = "preferredMaxDisplayRefreshRate"

    /** Huawei's `LayoutParams` extension class (EMUI/HarmonyOS); only its presence is checked. */
    const val HW_LAYOUT_PARAMS_EX = "com.huawei.android.view.LayoutParamsEx"

    /** AOSP fields that match [VENDOR_FIELD] but are not vendor extensions. */
    private val AOSP_FIELDS = setOf(FIELD_PREFERRED_REFRESH_RATE, FIELD_MIN_RATE, FIELD_MAX_RATE, "preferredDisplayModeId")
    private val VENDOR_FIELD = Regex("(?i).*(refresh|framerate|fps|hz).*")

    /**
     * The hints to apply: only in Oyun at [PIN_FPS]. [HzPinVariant.OFF], other modes or another fps give an empty list,
     * which means exactly today's platform calls.
     */
    fun plan(variant: HzPinVariant, isGame: Boolean, streamFps: Int): List<HzPinHint> {
        if (!isGame || streamFps != PIN_FPS) return emptyList()
        return when (variant) {
            HzPinVariant.OFF -> emptyList()
            HzPinVariant.LP -> listOf(HzPinHint.LP_RATE, HzPinHint.LP_MINMAX)
            HzPinVariant.ALL -> listOf(HzPinHint.LP_RATE, HzPinHint.LP_MINMAX, HzPinHint.HW_LP, HzPinHint.REAPPLY)
        }
    }

    /** Writes the public float field [name] of [target] by reflection; a missing field is [HzPinResult.MISSING]. */
    fun setFloatField(target: Any, name: String, value: Float): HzPinResult {
        val f = try {
            target.javaClass.getField(name)
        } catch (_: NoSuchFieldException) {
            return HzPinResult.MISSING
        } catch (_: SecurityException) {
            return HzPinResult.ERROR
        }
        if (f.type != java.lang.Float.TYPE || Modifier.isStatic(f.modifiers) || Modifier.isFinal(f.modifiers)) return HzPinResult.ERROR
        return try {
            f.setFloat(target, value)
            HzPinResult.OK
        } catch (_: Exception) {
            HzPinResult.ERROR
        }
    }

    /** Both min and max: [HzPinResult.OK] only if both were written, else the worse result. */
    fun setMinMax(target: Any, value: Float): HzPinResult {
        val a = setFloatField(target, FIELD_MIN_RATE, value)
        val b = setFloatField(target, FIELD_MAX_RATE, value)
        return worse(a, b)
    }

    fun worse(a: HzPinResult, b: HzPinResult): HzPinResult = if (a.ordinal >= b.ordinal) a else b

    /**
     * Read-only discovery: public instance fields of [cls] whose name looks like a refresh setting and is not one of the
     * AOSP fields, sorted. Names only (class metadata, never user data).
     */
    fun vendorFields(cls: Class<*>): List<String> = try {
        cls.fields.filter { !Modifier.isStatic(it.modifiers) && VENDOR_FIELD.matches(it.name) && it.name !in AOSP_FIELDS }
            .map { it.name }.distinct().sorted()
    } catch (_: SecurityException) {
        emptyList()
    }

    /** [HzPinHint.HW_LP] result: OK when a vendor field or the Huawei extension class exists, else MISSING. */
    fun vendorResult(fields: List<String>, hwClassPresent: Boolean): HzPinResult =
        if (fields.isNotEmpty() || hwClassPresent) HzPinResult.OK else HzPinResult.MISSING

    /** Whether [plan] asks for `Surface.setFrameRate` to be re-issued on rate changes and touch starts. */
    fun reapplies(plan: List<HzPinHint>): Boolean = HzPinHint.REAPPLY in plan

    /** `variant=<id> state=on|off applied=<hint>:<result>,…|-` for `MB/render ev=hz_pin`. */
    fun logFields(variant: HzPinVariant, on: Boolean, results: List<Pair<HzPinHint, HzPinResult>>): String =
        "variant=${variant.id} state=${if (on) "on" else "off"} applied=" +
            results.joinToString(",") { "${it.first.id}:${it.second.id}" }.ifEmpty { "-" }

    /** Sanitised field names for the `hw_fields=` part: identifier characters only, else dropped. */
    fun fieldList(names: List<String>): String =
        names.filter { FIELD_NAME.matches(it) }.joinToString(",").ifEmpty { "-" }

    private val FIELD_NAME = Regex("[A-Za-z_][A-Za-z0-9_]{0,63}")
}

/**
 * T-243: panel rate switches for `MB/render ev=stats hz_switches=`. Fed the debounced `display_rate` reports; a report
 * that differs from the previous one is a switch. [take] returns the count since the last take and resets it; the last
 * rate is kept across windows. [restart] forgets the last rate (a new vsync run: its first report is not a switch).
 */
class HzSwitchCounter {
    private var last = 0
    private var count = 0

    fun observe(hz: Int) {
        if (hz <= 0) return
        if (last != 0 && hz != last) count++
        last = hz
    }

    fun take(): Int = count.also { count = 0 }

    fun restart() { last = 0 }
}
