package dev.matebridge.decprobe

import android.app.Activity
import android.graphics.Color
import android.media.MediaCodecInfo
import android.media.MediaCodecList
import android.media.MediaFormat
import android.os.Build
import android.os.Bundle
import android.os.PowerManager
import android.util.Log
import android.view.WindowManager
import android.widget.ScrollView
import android.widget.TextView
import java.io.File

/**
 * T-248: does the tablet's HEVC decoder scale with concurrent sessions? Runs each scenario (N decoders started
 * together, each looping a clip made by `decprobe-clips`) for each output mode and logs one `DECPROBE` line per run
 * (also appended to `files/decprobe-results.txt`). Starts on launch; everything stops in onPause.
 *
 * Extras (all optional): scenarios (default [Scenario.DEFAULT]), outputs (`image,buffer`), seconds (8), warmup (1),
 * pace (0 = flood; e.g. 120 = one frame per 1/120 s), prio (`0`, `1` or `none`), oprate (`max`, a number or `none`),
 * codec (decoder name; default findDecoderForFormat per clip, asking for Main10 / Main10HDR10 for 10-bit clips),
 * imgfmt (ImageReader format of the `image` output: `private` default, `p010`, `rgba1010102`, `rgba8888`; an
 * unsupported one shows up as ERR(configure:...), never as a silent fallback), colorkeys (`none` = do not pass profile
 * and colour keys for 10-bit clips). T-249 adds 10-bit / high-bitrate clips (`full_10pq_100m` ...), p99/max latency
 * and the latency of IDR frames.
 */
class DecProbeActivity : Activity() {

    private lateinit var status: TextView
    private val lines = ArrayList<String>()
    @Volatile private var running = false
    private var runner: Thread? = null
    private var resultsFile: File? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        status = TextView(this).apply {
            setTextColor(Color.WHITE)
            setBackgroundColor(Color.BLACK)
            textSize = 13f
            setPadding(24, 24, 24, 24)
        }
        setContentView(ScrollView(this).apply { addView(status) })
        running = true
        runner = Thread({ runAll() }, "decprobe-runner").also { it.start() }
    }

    override fun onPause() {
        super.onPause()
        running = false
        runner?.join(4_000)
        runner = null
    }

    private fun log(s: String) {
        Log.i(TAG, s)
        resultsFile?.let { f -> runCatching { f.appendText(s + "\n") } }
        runOnUiThread {
            lines.add(s)
            while (lines.size > 40) lines.removeAt(0)
            status.text = lines.joinToString("\n")
        }
    }

    private fun intExtra(name: String, def: Int): Int = intent.getStringExtra(name)?.toIntOrNull() ?: def
    private fun doubleExtra(name: String, def: Double): Double = intent.getStringExtra(name)?.toDoubleOrNull() ?: def

    private fun runAll() {
        val dir = getExternalFilesDir(null) ?: run { log("DECPROBE info no external files dir"); return }
        resultsFile = File(dir, "decprobe-results.txt").also { it.writeText("") }
        val (scenarios, bad) = Scenario.parseList(intent.getStringExtra("scenarios") ?: Scenario.DEFAULT)
        val outputs = (intent.getStringExtra("outputs") ?: "image,buffer").split(',').map { it.trim() }
            .filter { it == "image" || it == "buffer" }
        val seconds = doubleExtra("seconds", 8.0)
        val warmup = doubleExtra("warmup", 1.0).coerceIn(0.0, seconds / 2)
        val pace = intExtra("pace", 0)
        val prio = when (val p = intent.getStringExtra("prio") ?: "0") { "none" -> null; else -> p.toIntOrNull() ?: 0 }
        val opRate = when (val o = intent.getStringExtra("oprate") ?: "max") {
            "none" -> null
            "max" -> Short.MAX_VALUE.toInt()
            else -> o.toIntOrNull()
        }
        if (bad.isNotEmpty()) log("DECPROBE info ignored scenarios: $bad")

        val names = dir.list()?.toList() ?: emptyList()
        val clips = HashMap<String, LoadedClip>()
        for (id in scenarios.flatMap { it.clips }.toSet()) {
            val cf = ClipFile.find(names, id)
            if (cf == null) { log("DECPROBE info missing clip '$id' in ${dir.path} (adb push it first)"); continue }
            val lc = LoadedClip(cf, File(dir, cf.fileName).readBytes())
            clips[id] = lc
            log("DECPROBE info clip $id ${cf.width}x${cf.height} units=${lc.units.size} bytes=${lc.data.size} " +
                "csd=${lc.csd?.size ?: 0} max_unit=${lc.maxUnit}")
        }
        val (imgFmtName, imgFmt) = ImgFormat.parse(intent.getStringExtra("imgfmt")) ?: run {
            log("DECPROBE info bad imgfmt '${intent.getStringExtra("imgfmt")}' (private, p010, rgba1010102, rgba8888)")
            return
        }
        val colorKeys = intent.getStringExtra("colorkeys") != "none"
        // One decoder per clip format (a 10-bit clip may be served by another decoder than an 8-bit one).
        val override = intent.getStringExtra("codec")
        val codecNames = HashMap<String, String>()
        for ((id, lc) in clips) {
            val name = override ?: findCodec(lc.file)
            if (name == null) { log("DECPROBE info no HEVC decoder for clip $id (${lc.file.profileName})"); continue }
            codecNames[id] = name
        }
        for (name in codecNames.values.toSet()) {
            logCodecInfo(name, clips.filter { codecNames[it.key] == name }.values.map { it.file })
        }
        log("DECPROBE info device=${Build.MODEL} sdk=${Build.VERSION.SDK_INT} seconds=$seconds warmup=$warmup " +
            "pace=$pace prio=${prio ?: "none"} oprate=${opRate ?: "none"} outputs=$outputs imgfmt=$imgFmtName " +
            "colorkeys=$colorKeys scenarios=${scenarios.joinToString(",") { it.name }}")

        outer@ for (out in outputs) {
            for (sc in scenarios) {
                if (!running) break@outer
                runScenario(sc, out, clips, codecNames, seconds, warmup, pace, imgFmt, colorKeys, prio, opRate)
                pauseMs(1500)
            }
        }
        log(if (running) "DECPROBE done" else "DECPROBE aborted (paused)")
    }

    private fun runScenario(
        sc: Scenario, out: String, clips: Map<String, LoadedClip>, codecNames: Map<String, String>,
        seconds: Double, warmup: Double, pace: Int, imgFmt: Int, colorKeys: Boolean, prio: Int?, opRate: Int?,
    ) {
        val missing = sc.clips.filter { it !in clips || it !in codecNames }
        if (missing.isNotEmpty()) { log("DECPROBE scen=${sc.name} out=$out skipped: missing $missing"); return }
        val codecName = sc.clips.map { codecNames.getValue(it) }.distinct().joinToString("+")
        val sessions = sc.clips.mapIndexed { i, id ->
            DecoderSession(i, clips.getValue(id), codecNames.getValue(id), out, pace, imgFmt, colorKeys, prio, opRate, ::log)
        }
        val configured = sessions.map { it.configure() }
        configured.forEachIndexed { i, e -> if (e != null) log("DECPROBE info scen=${sc.name} s$i $e") }
        val t0 = System.nanoTime() + 50_000_000L
        val winStart = t0 + (warmup * 1e9).toLong()
        val end = t0 + (seconds * 1e9).toLong()
        sessions.forEachIndexed { i, s -> if (configured[i] == null) s.start(t0, winStart, end, end) }
        while (running && System.nanoTime() < end) pauseMs(100)
        val results = sessions.map { it.stop() }
        val window = if (running) seconds - warmup else 0.0
        log(Summary.line(sc.name, out, pace, window, codecName, results) + " thermal=${thermal()}")
    }

    private fun pauseMs(ms: Long) {
        try { Thread.sleep(ms) } catch (_: InterruptedException) {}
    }

    private fun thermal(): Int =
        runCatching { (getSystemService(POWER_SERVICE) as PowerManager).currentThermalStatus }.getOrDefault(-1)

    /** The decoder the platform picks for this clip's size and profile (10-bit clips ask for Main10 / Main10HDR10). */
    private fun findCodec(f: ClipFile): String? {
        val list = MediaCodecList(MediaCodecList.REGULAR_CODECS)
        val fmt = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_HEVC, f.width, f.height)
        if (f.bitDepth == 10) fmt.setInteger(MediaFormat.KEY_PROFILE, HevcProfiles.forClip(f))
        return list.findDecoderForFormat(fmt)
    }

    private fun logCodecInfo(name: String, files: Collection<ClipFile>) {
        val info: MediaCodecInfo = MediaCodecList(MediaCodecList.REGULAR_CODECS).codecInfos
            .firstOrNull { it.name == name } ?: run { log("DECPROBE info codec $name not listed"); return }
        val caps = runCatching { info.getCapabilitiesForType(MediaFormat.MIMETYPE_VIDEO_HEVC) }.getOrNull()
            ?: run { log("DECPROBE info codec $name has no HEVC caps"); return }
        val vc = caps.videoCapabilities ?: run { log("DECPROBE info codec $name has no video caps"); return }
        val pps = vc.supportedPerformancePoints?.joinToString(";")
        val profiles = HevcProfiles.names(caps.profileLevels.map { it.profile })
        log("DECPROBE info codec=$name hw=${info.isHardwareAccelerated} max_instances=${caps.maxSupportedInstances} " +
            "profiles=$profiles perf_points=${pps ?: "-"}")
        for (f in files.map { it.profileName }.toSet()) {
            if (f !in profiles) log("DECPROBE info codec=$name does not advertise profile $f (clips may still decode)")
        }
        for (f in files) {
            val rates = runCatching { vc.getAchievableFrameRatesFor(f.width, f.height) }.getOrNull()
            log("DECPROBE info codec=$name ${f.width}x${f.height} achievable=${rates ?: "-"} " +
                "supported=${vc.isSizeSupported(f.width, f.height)}")
        }
    }

    companion object {
        const val TAG = "DECPROBE"
    }
}
