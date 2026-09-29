package dev.matebridge.client.debug

import android.app.Activity
import android.graphics.Color
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.view.Gravity
import android.view.SurfaceHolder
import android.view.SurfaceView
import android.view.View
import android.view.WindowManager
import android.widget.FrameLayout
import android.widget.TextView
import dev.matebridge.client.protocol.StreamConfig
import dev.matebridge.client.protocol.VideoFrame
import dev.matebridge.client.video.AnnexBSplitter
import dev.matebridge.client.video.VideoRenderer
import java.io.File

/**
 * Debug-only: plays <external files>/test.h265 (T-011 dump, HEVC Annex-B) in a loop at real speed
 * through the same VideoRenderer the session will use, and shows the counters.
 *
 * adb push test.h265 /sdcard/Android/data/dev.matebridge.client/files/test.h265
 * adb shell am start -n dev.matebridge.client/.debug.VideoTestActivity [--ei fps 60]
 */
class VideoTestActivity : Activity(), SurfaceHolder.Callback {
    private lateinit var overlay: TextView
    private lateinit var renderer: VideoRenderer
    private var frames: List<VideoFrame> = emptyList()
    @Volatile private var keyframeRequests = 0
    @Volatile private var playing = false
    private var player: Thread? = null
    private var fps = 60
    private val ui = Handler(Looper.getMainLooper())
    private var status = ""

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        fps = intent.getIntExtra("fps", 60)
        val config = StreamConfig(1, StreamConfig.CODEC_HEVC, 2800, 1840, 1400, 920, fps, 0, 1, 1, 1, 0)
        renderer = VideoRenderer(config) { keyframeRequests++ }

        val file = File(getExternalFilesDir(null), "test.h265")
        status = if (file.exists()) {
            frames = AnnexBSplitter.split(file.readBytes())
            "test.h265: ${frames.size} units, ${frames.count { it.isKeyframe }} keyframes"
        } else "missing: ${file.absolutePath}"

        val surface = SurfaceView(this)
        surface.holder.addCallback(this)
        overlay = TextView(this).apply {
            setTextColor(Color.GREEN)
            setBackgroundColor(0x88000000.toInt())
            textSize = 16f
            setPadding(16, 8, 16, 8)
        }
        val root = FrameLayout(this)
        root.addView(surface)
        root.addView(overlay, FrameLayout.LayoutParams(-2, -2, Gravity.TOP or Gravity.START))
        setContentView(root)
        @Suppress("DEPRECATION")
        root.systemUiVisibility = (View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY
            or View.SYSTEM_UI_FLAG_FULLSCREEN or View.SYSTEM_UI_FLAG_HIDE_NAVIGATION
            or View.SYSTEM_UI_FLAG_LAYOUT_STABLE)
    }

    override fun surfaceCreated(holder: SurfaceHolder) {
        renderer.attachSurface(holder.surface)
        startPlayer()
        ui.post(refresh)
    }

    override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) {}

    override fun surfaceDestroyed(holder: SurfaceHolder) {
        stopPlayer()
        renderer.detachSurface()
        ui.removeCallbacks(refresh)
    }

    /** Feeds units at real speed; a config unit is sent without consuming a frame interval. */
    private fun startPlayer() {
        if (frames.isEmpty()) return
        playing = true
        player = Thread({
            val intervalNs = 1_000_000_000L / fps
            var seq = 0L
            var next = System.nanoTime()
            while (playing) {
                for (f in frames) {
                    if (!playing) return@Thread
                    // Renumber so the sequence keeps growing across loops.
                    val out = VideoFrame(seq++, f.captureTimeUs, f.flags, 0, 1, f.frameSize, f.data)
                    renderer.onFrame(out)
                    if (f.isCodecConfig) continue
                    next += intervalNs
                    val wait = next - System.nanoTime()
                    if (wait > 0) Thread.sleep(wait / 1_000_000, (wait % 1_000_000).toInt())
                }
            }
        }, "mb-file-player").also { it.start() }
    }

    private fun stopPlayer() {
        playing = false
        player?.join(1000)
        player = null
    }

    private var lastSnapMs = SystemClock.elapsedRealtime()
    private val refresh = object : Runnable {
        override fun run() {
            val now = SystemClock.elapsedRealtime()
            val s = renderer.stats.snapshot(reset = true)
            val secs = (now - lastSnapMs).coerceAtLeast(1) / 1000.0
            lastSnapMs = now
            overlay.text = "$status\n${renderer.codecInfo}\n" +
                "recv ${s.received} dec ${s.decoded} shown ${s.rendered} drop ${s.dropped} " +
                "(${"%.1f".format(s.rendered / secs)} shown/s)\n" +
                "decode avg ${s.decodeTimeAvgUs} us  kf requests $keyframeRequests"
            ui.postDelayed(this, 1000)
        }
    }

    override fun onStop() {
        super.onStop()
        stopPlayer()
        renderer.detachSurface() // surfaceDestroyed also fires; both are idempotent
    }
}
