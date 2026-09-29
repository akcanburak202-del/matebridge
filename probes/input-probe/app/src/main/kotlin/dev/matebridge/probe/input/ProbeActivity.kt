package dev.matebridge.probe.input

import android.app.Activity
import android.graphics.Color
import android.graphics.Typeface
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.view.Gravity
import android.view.KeyEvent
import android.view.MotionEvent
import android.view.View
import android.view.WindowManager
import android.widget.Button
import android.widget.LinearLayout
import android.widget.TextView

/** Single-screen input probe: left = pen drawing area, right = live event list. Local logging only. */
class ProbeActivity : Activity() {
    private lateinit var sink: JsonlSink
    private lateinit var draw: DrawView
    private lateinit var summary: TextView
    private lateinit var list: TextView
    private lateinit var captureBtn: Button
    private lateinit var fileLabel: TextView

    private val handler = Handler(Looper.getMainLooper())
    private val penRate = RateMeter(500)
    private val recent = ArrayDeque<String>()
    private var lastPressure = 0f
    private var lastTilt = 0f
    private var lastOrientation = 0f
    private var lastScan = -1
    private var captured = false

    private val ticker = object : Runnable {
        override fun run() {
            refreshUi()
            sink.flush()
            handler.postDelayed(this, 100)
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        sink = JsonlSink(getExternalFilesDir(null)!!)

        summary = TextView(this).apply {
            typeface = Typeface.MONOSPACE; textSize = 16f; setTextColor(Color.WHITE)
            setBackgroundColor(Color.rgb(40, 40, 60)); setPadding(16, 8, 16, 8)
        }
        draw = DrawView(this)
        draw.setOnCapturedPointerListener { _, e ->
            record(e, "captured", true)
            true
        }
        list = TextView(this).apply {
            typeface = Typeface.MONOSPACE; textSize = 11f; setTextColor(Color.LTGRAY)
            setPadding(8, 4, 8, 4)
        }
        captureBtn = Button(this).apply {
            setOnClickListener { setCapture(!captured) }
        }
        fileLabel = TextView(this).apply { textSize = 10f; setTextColor(Color.GRAY) }
        val newSession = Button(this).apply {
            text = "Dışa aktar / yeni oturum"
            setOnClickListener { startSession() }
        }
        val clear = Button(this).apply { text = "Çizimi sil"; setOnClickListener { draw.clear() } }

        val buttons = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            addView(captureBtn); addView(newSession); addView(clear)
        }
        val right = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundColor(Color.BLACK)
            addView(buttons)
            addView(fileLabel)
            addView(list, LinearLayout.LayoutParams(-1, 0, 1f))
        }
        val body = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            addView(draw, LinearLayout.LayoutParams(0, -1, 1f))
            addView(right, LinearLayout.LayoutParams(0, -1, 1f))
        }
        setContentView(LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            addView(summary, LinearLayout.LayoutParams(-1, -2))
            addView(body, LinearLayout.LayoutParams(-1, 0, 1f))
        })
        hideSystemUi()
        startSession()
    }

    private fun hideSystemUi() {
        @Suppress("DEPRECATION")
        window.decorView.systemUiVisibility = View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY or
            View.SYSTEM_UI_FLAG_FULLSCREEN or View.SYSTEM_UI_FLAG_HIDE_NAVIGATION or
            View.SYSTEM_UI_FLAG_LAYOUT_STABLE or View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN or
            View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION
    }

    private fun startSession() {
        val f = sink.startSession()
        recent.clear()
        penRate.clear()
        val dm = resources.displayMetrics
        sink.write(
            EventJson.meta(
                SystemClock.elapsedRealtime(), "session_start",
                mapOf(
                    "model" to Build.MODEL, "sdk" to Build.VERSION.SDK_INT,
                    "widthPx" to dm.widthPixels, "heightPx" to dm.heightPixels,
                    "density" to dm.density,
                ),
            ),
        )
        for (d in EventMapper.deviceList()) sink.write(EventJson.meta(SystemClock.elapsedRealtime(), "input_device", d))
        fileLabel.text = f.absolutePath
        updateCaptureButton()
    }

    private fun setCapture(on: Boolean) {
        if (on) {
            draw.requestFocus()
            draw.requestPointerCapture()
        } else {
            draw.releasePointerCapture()
        }
    }

    private fun updateCaptureButton() {
        captureBtn.text = if (captured) "Pointer capture: AÇIK (kapat)" else "Pointer capture: KAPALI (aç)"
    }

    override fun onPointerCaptureChanged(hasCapture: Boolean) {
        super.onPointerCaptureChanged(hasCapture)
        captured = hasCapture
        sink.write(EventJson.meta(SystemClock.elapsedRealtime(), "pointer_capture", mapOf("on" to hasCapture)))
        updateCaptureButton()
    }

    // ---- recording: everything passes through the activity dispatchers, then continues normally ----

    override fun dispatchTouchEvent(ev: MotionEvent): Boolean {
        record(ev, "touch", false)
        return super.dispatchTouchEvent(ev)
    }

    override fun dispatchGenericMotionEvent(ev: MotionEvent): Boolean {
        record(ev, "generic", false)
        return super.dispatchGenericMotionEvent(ev)
    }

    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        val r = EventMapper.key(event)
        sink.write(EventJson.key(r))
        lastScan = r.scanCode
        push("KEY ${r.action} ${r.keyName} code=${r.keyCode} scan=${r.scanCode} meta=${r.metaState} rep=${r.repeatCount} dev=${r.deviceName}")
        return super.dispatchKeyEvent(event)
    }

    private fun record(e: MotionEvent, callback: String, isCaptured: Boolean) {
        val r = EventMapper.motion(e, callback, isCaptured)
        sink.write(EventJson.motion(r))
        val p = r.pointers.firstOrNull()
        if (p != null && (p.toolType == "STYLUS" || p.toolType == "ERASER")) {
            for (h in r.history) penRate.add(h.eventTime)
            penRate.add(r.eventTime)
            lastPressure = p.pressure
            lastTilt = p.tilt
            lastOrientation = p.orientation
        }
        val short = r.action.removePrefix("ACTION_")
        push(
            "${callback.take(1).uppercase()} $short ${p?.toolType ?: "-"} " +
                "x=${"%.0f".format(p?.x ?: 0f)} y=${"%.0f".format(p?.y ?: 0f)} " +
                "p=${"%.2f".format(p?.pressure ?: 0f)} tilt=${"%.2f".format(p?.tilt ?: 0f)} " +
                "rel=${"%.1f".format(p?.relX ?: 0f)},${"%.1f".format(p?.relY ?: 0f)} " +
                "vs=${"%.1f".format(p?.vScroll ?: 0f)} btn=${r.buttonState} n=${r.pointerCount} h=${r.historySize}",
        )
    }

    private fun push(line: String) {
        recent.addLast(line)
        while (recent.size > 45) recent.removeFirst()
    }

    private fun refreshUi() {
        val hz = penRate.hzAt(SystemClock.uptimeMillis())
        summary.text = "pen %.0f Hz | pressure %.3f | tilt %.2f rad | orient %.2f | last scan %s | lines %d | capture %s".format(
            hz, lastPressure, lastTilt, lastOrientation, if (lastScan < 0) "-" else lastScan.toString(),
            sink.lines, if (captured) "ON" else "off",
        )
        list.text = recent.joinToString("\n")
    }

    // ---- lifecycle: release capture, flush file ----

    override fun onResume() {
        super.onResume()
        handler.post(ticker)
    }

    override fun onPause() {
        handler.removeCallbacks(ticker)
        if (captured) draw.releasePointerCapture()
        sink.flush()
        super.onPause()
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus) hideSystemUi() else if (captured) draw.releasePointerCapture()
    }

    override fun onDestroy() {
        sink.close()
        super.onDestroy()
    }
}
