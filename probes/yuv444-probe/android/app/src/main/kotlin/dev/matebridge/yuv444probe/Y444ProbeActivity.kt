package dev.matebridge.yuv444probe

import android.app.Activity
import android.graphics.Color
import android.os.Build
import android.os.Bundle
import android.util.Log
import android.view.Surface
import android.view.SurfaceHolder
import android.view.SurfaceView
import android.view.View
import android.view.WindowManager
import android.widget.FrameLayout
import android.widget.ScrollView
import android.widget.TextView
import java.io.File

/**
 * T-254: tablet half of the 4:4:4-in-4:2:0 packing gates (docs/research/2026-10-05-yuv444-packing.md, section 7).
 * Starts on launch and runs the tests named by `--es test` (see [Args]); everything stops in onPause. Results are
 * `Y444PROBE` lines in logcat and `files/y444-results.txt`.
 */
class Y444ProbeActivity : Activity(), Host, SurfaceHolder.Callback {
    private lateinit var status: TextView
    private var surfaceView: SurfaceView? = null
    private val lines = ArrayList<String>()
    @Volatile private var running = false
    private var runner: Thread? = null
    private var resultsFile: File? = null

    private val surfaceLock = Object()
    private var surface: Surface? = null
    private var surfaceW = 0
    private var surfaceH = 0

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        val args = readArgs()
        val root = FrameLayout(this).apply { setBackgroundColor(Color.BLACK) }
        if (args.needsSurface) {
            val sv = SurfaceView(this)
            sv.holder.addCallback(this)
            surfaceView = sv
            root.addView(sv, FrameLayout.LayoutParams(-1, -1))
        }
        status = TextView(this).apply {
            setTextColor(Color.WHITE)
            setBackgroundColor(if (args.needsSurface) 0x99000000.toInt() else Color.BLACK)
            textSize = 12f
            setPadding(24, 24, 24, 24)
        }
        // An overlay changes how the video layer is composed; keep it off while measuring presentation.
        val overlay = ScrollView(this).apply {
            addView(status)
            visibility = if (args.needsSurface && !args.ui) View.GONE else View.VISIBLE
        }
        root.addView(overlay, FrameLayout.LayoutParams(-1, -1))
        setContentView(root)
        val dir = getExternalFilesDir(null)
        if (dir == null) {
            log("Y444PROBE info no external files dir")
            return
        }
        resultsFile = File(dir, "y444-results.txt").also { it.writeText("") }
        running = true
        runner = Thread({
            ProbeRunner(applicationContext, dir, args, this, ::log) { running }.runAll()
        }, "y444-runner").also { it.start() }
    }

    override fun onPause() {
        super.onPause()
        running = false
        runner?.join(8_000)
        runner = null
    }

    private fun readArgs(): Args {
        val m = HashMap<String, String>()
        intent.extras?.keySet()?.forEach { k -> intent.getStringExtra(k)?.let { m[k] = it } }
        return Args(m)
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

    // ---- Host ----

    override fun surfaceFor(w: Int, h: Int): Surface? {
        val sv = surfaceView ?: return null
        synchronized(surfaceLock) {
            if (surface?.isValid == true && surfaceW == w && surfaceH == h) return surface
        }
        runOnUiThread { sv.holder.setFixedSize(w, h) }
        val end = System.nanoTime() + 5_000_000_000L
        synchronized(surfaceLock) {
            while (!(surface?.isValid == true && surfaceW == w && surfaceH == h)) {
                val left = (end - System.nanoTime()) / 1_000_000
                if (left <= 0 || !running) return null
                surfaceLock.wait(left)
            }
            return surface
        }
    }

    override fun requestPanel(hz: Int): String {
        val sv = surfaceView
        @Suppress("DEPRECATION")
        val display = windowManager.defaultDisplay ?: return "no_display"
        val modes = display.supportedModes
        val cur = display.mode
        val best = modes.filter { it.physicalWidth == cur.physicalWidth && it.physicalHeight == cur.physicalHeight }
            .minByOrNull { Math.abs(it.refreshRate - hz) }
        runOnUiThread {
            best?.let {
                val lp = window.attributes
                lp.preferredDisplayModeId = it.modeId
                window.attributes = lp
            }
            if (sv != null && Build.VERSION.SDK_INT >= 30 && sv.holder.surface.isValid) {
                sv.holder.surface.setFrameRate(hz.toFloat(), Surface.FRAME_RATE_COMPATIBILITY_FIXED_SOURCE)
            }
        }
        val list = modes.joinToString(";") { "${it.modeId}:${it.physicalWidth}x${it.physicalHeight}@${it.refreshRate}" }
        return "mode=${best?.modeId}@${best?.refreshRate} modes=[$list]".replace(' ', '_')
    }

    @Suppress("DEPRECATION")
    override fun refreshRate(): Float = windowManager.defaultDisplay?.refreshRate ?: -1f

    override fun setStatus(text: String) {
        runOnUiThread { status.text = text }
    }

    // ---- SurfaceHolder.Callback ----

    override fun surfaceCreated(holder: SurfaceHolder) {
        synchronized(surfaceLock) {
            surface = holder.surface
            surfaceLock.notifyAll()
        }
    }

    override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) {
        synchronized(surfaceLock) {
            surface = holder.surface
            surfaceW = width
            surfaceH = height
            surfaceLock.notifyAll()
        }
    }

    override fun surfaceDestroyed(holder: SurfaceHolder) {
        synchronized(surfaceLock) {
            surface = null
            surfaceW = 0
            surfaceH = 0
            surfaceLock.notifyAll()
        }
    }

    companion object {
        const val TAG = "Y444PROBE"
    }
}
