package dev.matebridge.yuv444probe

/**
 * Probe arguments (`adb shell am start ... --es key value`). Pure so the defaults and parsing are unit tested.
 *
 * - `test`    comma list of t2, direct, t1, t3, t4 (default [TestKind.DEFAULT]).
 * - `size`    full (2800x1840, default), small (1848x1214) or WxH: picks the clips by size.
 * - `main`    clip spec for the main view (file name, id or id prefix); default: first clip of `size` by name.
 * - `aux`     clip spec for the auxiliary view, `none` for a single stream; default: second clip of `size` by name,
 *             else the main clip again.
 * - `fps`     feed rate (default 60: the 4:4:4 decision is for 60 fps only).
 * - `seconds` run length of t1/t3/direct (default 20; t4 default 300), `warmup` seconds excluded (default 2).
 * - `panel`   60 or 120: asks the window for a display mode of that refresh rate (default 60).
 * - `gl`      oes, main or merge (default merge): the t3 render pass.
 * - `swap`    EGL swap interval (default 1).
 * - `out`     t1 decoder output: image (default) or buffer.
 * - `frames`  t2 frame numbers compared (default 12,24,36).
 * - `ui`      1 = keep the status text over the video in t3/t4/direct (changes layer composition; default off).
 * - `present` GL path presentation (t3/t4): queue (default), depth1 or pts ([PresentMode]); `swap=0` adds swapint0.
 * - `direct_mode` direct path release: immediate (default) or pts ([DirectMode]).
 * - `lead_ms` slot lead of the pts variants (default 6, like the product).
 * - `vsync_off_ms` phase shift of the Choreographer vsync grid (default 0; tuning knob for the pts variants).
 * - `codec`   decoder name override (default: findDecoderForFormat per clip).
 */
class Args(private val map: Map<String, String>) {
    fun str(key: String): String? = map[key]?.trim()?.takeIf { it.isNotEmpty() }
    fun int(key: String, def: Int): Int = str(key)?.toIntOrNull() ?: def
    fun double(key: String, def: Double): Double = str(key)?.toDoubleOrNull() ?: def

    val tests: Pair<List<TestKind>, List<String>> get() = TestKind.parseList(str("test"))
    val size: Pair<Int, Int>? get() = SizeSpec.parse(str("size"))
    val fps: Int get() = int("fps", 60).coerceIn(1, 240)
    fun seconds(kind: TestKind): Double = double("seconds", if (kind == TestKind.T4) 300.0 else 20.0).coerceAtLeast(2.0)
    val warmup: Double get() = double("warmup", 2.0).coerceAtLeast(0.0)
    val panel: Int get() = int("panel", 60)
    val gl: GlMode? get() = GlMode.parse(str("gl"))
    val present: PresentMode? get() = PresentMode.parse(str("present"))
    val directMode: DirectMode? get() = DirectMode.parse(str("direct_mode"))
    val leadNs: Long get() = (double("lead_ms", 6.0).coerceIn(0.0, 30.0) * 1e6).toLong()
    val vsyncOffsetNs: Long get() = (double("vsync_off_ms", 0.0).coerceIn(-30.0, 30.0) * 1e6).toLong()
    val swap: Int get() = int("swap", 1).coerceIn(0, 4)
    val bufferOut: Boolean get() = str("out")?.lowercase() == "buffer"
    val ui: Boolean get() = str("ui") == "1"
    val frames: List<Int>
        get() = (str("frames") ?: "12,24,36").split(',').mapNotNull { it.trim().toIntOrNull() }.filter { it >= 0 }
    val needsSurface: Boolean
        get() = tests.first.any { it == TestKind.T3 || it == TestKind.T4 || it == TestKind.DIRECT }
}

/** Parses the `Y444PROBE t2 raw ...` result line of the native comparison. */
object RawVerdict {
    private val MIS = Regex("""\b(y|cb|cr)_mis=(\d+)/(\d+)""")

    /** True when Y, Cb and Cr all matched bit for bit; null when the line is not a successful comparison. */
    fun exact(line: String): Boolean? {
        if (!line.contains("ok=1")) return null
        val found = MIS.findAll(line).associate { it.groupValues[1] to it.groupValues[2].toLong() }
        if (found.size < 3) return null
        return found.values.all { it == 0L }
    }
}
