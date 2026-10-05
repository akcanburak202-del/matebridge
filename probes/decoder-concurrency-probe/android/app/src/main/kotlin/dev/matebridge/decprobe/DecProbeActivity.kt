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
 * codec (decoder name; default findDecoderForFormat for HEVC 2800x1840).
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
        val codecName = intent.getStringExtra("codec") ?: findCodec()
        if (codecName == null) { log("DECPROBE info no HEVC decoder"); return }
        logCodecInfo(codecName, clips.values.map { it.file })
        log("DECPROBE info device=${Build.MODEL} sdk=${Build.VERSION.SDK_INT} seconds=$seconds warmup=$warmup " +
            "pace=$pace prio=${prio ?: "none"} oprate=${opRate ?: "none"} outputs=$outputs " +
            "scenarios=${scenarios.joinToString(",") { it.name }}")

        outer@ for (out in outputs) {
            for (sc in scenarios) {
                if (!running) break@outer
                runScenario(sc, out, clips, codecName, seconds, warmup, pace, prio, opRate)
                pauseMs(1500)
            }
        }
        log(if (running) "DECPROBE done" else "DECPROBE aborted (paused)")
    }

    private fun runScenario(
        sc: Scenario, out: String, clips: Map<String, LoadedClip>, codecName: String,
        seconds: Double, warmup: Double, pace: Int, prio: Int?, opRate: Int?,
    ) {
        val missing = sc.clips.filter { it !in clips }
        if (missing.isNotEmpty()) { log("DECPROBE scen=${sc.name} out=$out skipped: missing $missing"); return }
        val sessions = sc.clips.mapIndexed { i, id ->
            DecoderSession(i, clips.getValue(id), codecName, out, pace, prio, opRate, ::log)
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

    private fun findCodec(): String? {
        val fmt = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_HEVC, 2800, 1840)
        return MediaCodecList(MediaCodecList.REGULAR_CODECS).findDecoderForFormat(fmt)
    }

    private fun logCodecInfo(name: String, files: Collection<ClipFile>) {
        val info: MediaCodecInfo = MediaCodecList(MediaCodecList.REGULAR_CODECS).codecInfos
            .firstOrNull { it.name == name } ?: run { log("DECPROBE info codec $name not listed"); return }
        val caps = runCatching { info.getCapabilitiesForType(MediaFormat.MIMETYPE_VIDEO_HEVC) }.getOrNull()
            ?: run { log("DECPROBE info codec $name has no HEVC caps"); return }
        val vc = caps.videoCapabilities ?: run { log("DECPROBE info codec $name has no video caps"); return }
        val pps = vc.supportedPerformancePoints?.joinToString(";")
        log("DECPROBE info codec=$name hw=${info.isHardwareAccelerated} max_instances=${caps.maxSupportedInstances} " +
            "perf_points=${pps ?: "-"}")
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
