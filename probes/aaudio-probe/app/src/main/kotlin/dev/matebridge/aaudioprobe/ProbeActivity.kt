package dev.matebridge.aaudioprobe

import android.app.Activity
import android.graphics.Typeface
import android.os.Bundle
import android.os.Process
import android.os.SystemClock
import android.util.Log
import android.view.WindowManager
import android.widget.Button
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView

/**
 * T-099: runs (a) AAudio LOW_LATENCY+EXCLUSIVE, (b) AAudio LOW_LATENCY+SHARED, (c) AudioTrack (product settings),
 * ~5 s each, and reports output latency. Runs automatically on first resume; "Run again" repeats.
 * onPause stops and closes everything, so no audio plays in the background.
 */
class ProbeActivity : Activity() {

    private lateinit var status: TextView
    private lateinit var table: TextView
    private var worker: Thread? = null
    @Volatile private var stopRequested = false
    private var autoRunPending = true

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        status = TextView(this).apply { textSize = 18f }
        table = TextView(this).apply {
            typeface = Typeface.MONOSPACE
            textSize = 14f
            setHorizontallyScrolling(true)
        }
        val again = Button(this).apply {
            text = "Run again"
            setOnClickListener { start() }
        }
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(32, 32, 32, 32)
            addView(again)
            addView(status)
            addView(table)
        }
        setContentView(ScrollView(this).apply { addView(root) })
        status.text = "idle"
    }

    override fun onResume() {
        super.onResume()
        if (autoRunPending) start()
    }

    override fun onPause() {
        stop()
        super.onPause()
    }

    private fun start() {
        if (worker?.isAlive == true) return
        stopRequested = false
        NativeProbe.resetStop()
        table.text = ResultFormat.TABLE_HEADER
        worker = Thread({ runAll() }, "aaprobe").also { it.start() }
    }

    private fun stop() {
        stopRequested = true
        NativeProbe.requestStop()
        // A blocking write returns within its 1 s timeout; give it a little more.
        worker?.join(JOIN_MS)
        worker = null
    }

    private fun runAll() {
        Process.setThreadPriority(Process.THREAD_PRIORITY_URGENT_AUDIO)
        val results = ArrayList<Pair<ProbeResult, LatencyStats?>>()
        log('I', "run_start", "duration_ms=$CASE_MS gap_ms=$GAP_MS warmup_ms=${ProbeResult.WARMUP_NS / 1_000_000} amplitude=${ToneGen.AMPLITUDE_M40_DBFS}")
        val cases = listOf<Pair<String, () -> ProbeResult>>(
            "a_excl" to { NativeResult.parse("a_excl", NativeProbe.runAaudio(NativeResult.SHARING_EXCLUSIVE, CASE_MS, ToneGen.AMPLITUDE_M40_DBFS)) },
            "b_shared" to { NativeResult.parse("b_shared", NativeProbe.runAaudio(NativeResult.SHARING_SHARED, CASE_MS, ToneGen.AMPLITUDE_M40_DBFS)) },
            "c_track" to { AudioTrackRunner(applicationContext).run("c_track", CASE_MS, ToneGen.AMPLITUDE_M40_DBFS) { stopRequested } },
        )
        for ((i, c) in cases.withIndex()) {
            if (i > 0 && !pause(GAP_MS)) break
            if (stopRequested) break
            val (name, runCase) = c
            ui("running $name (${i + 1}/${cases.size})")
            log('I', "case_start", "case=$name")
            val r = try {
                runCase()
            } catch (e: RuntimeException) {
                log('E', "case_failed", "case=$name err=${e.javaClass.simpleName}")
                continue
            }
            val s = r.stats()
            results.add(r to s)
            log(if (r.error == "0") 'I' else 'W', "result", ResultFormat.resultFields(r, s))
            val row = ResultFormat.tableRow(r, s)
            runOnUiThread { table.append("\n" + row) }
        }
        if (stopRequested) {
            log('W', "run_aborted", "done_cases=${results.size}")
            ui("aborted (paused) after ${results.size} case(s); tap Run again")
        } else {
            log('I', "summary", ResultFormat.summaryFields(results))
            runOnUiThread { autoRunPending = false }
            ui("done")
        }
    }

    /** Sleeps up to [ms]; returns false if a stop was requested meanwhile. */
    private fun pause(ms: Long): Boolean {
        val end = SystemClock.elapsedRealtime() + ms
        while (SystemClock.elapsedRealtime() < end) {
            if (stopRequested) return false
            Thread.sleep(20)
        }
        return !stopRequested
    }

    private fun ui(text: String) = runOnUiThread { status.text = text }

    private fun log(level: Char, ev: String, fields: String) {
        val line = ResultFormat.line(SystemClock.elapsedRealtime(), level, ev, fields)
        when (level) {
            'E' -> Log.e(TAG, line)
            'W' -> Log.w(TAG, line)
            else -> Log.i(TAG, line)
        }
    }

    companion object {
        const val TAG = "MB/aaprobe"
        const val CASE_MS = 5_000
        const val GAP_MS = 1_000L
        const val JOIN_MS = 1_500L
    }
}
