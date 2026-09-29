package dev.matebridge.client

import android.app.Activity
import android.content.Context
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.hardware.display.DisplayManager
import android.view.Choreographer
import android.view.KeyEvent
import android.view.Surface
import android.view.SurfaceHolder
import android.view.SurfaceView
import android.view.View
import android.view.WindowManager
import android.widget.FrameLayout
import android.widget.Button
import android.widget.EditText
import android.widget.TextView
import android.widget.Toast
import dev.matebridge.client.protocol.Capabilities
import dev.matebridge.client.protocol.Bytes
import dev.matebridge.client.protocol.Hello
import dev.matebridge.client.protocol.KeyframeRequest
import dev.matebridge.client.protocol.StreamConfig
import dev.matebridge.client.protocol.VideoFrame
import dev.matebridge.client.session.MbLog
import dev.matebridge.client.stream.ClockSync
import dev.matebridge.client.stream.DisplayModeInfo
import dev.matebridge.client.stream.DisplayModePicker
import dev.matebridge.client.stream.StatsFormat
import dev.matebridge.client.stream.VideoViewport
import dev.matebridge.client.video.VideoRenderer
import dev.matebridge.client.video.VsyncClock
import dev.matebridge.client.session.Endpoint
import dev.matebridge.client.session.KeyValueStore
import dev.matebridge.client.session.MacDiscovery
import dev.matebridge.client.session.SessionController
import dev.matebridge.client.session.SessionListener
import dev.matebridge.client.session.SessionUi
import dev.matebridge.client.session.Settings
import dev.matebridge.client.session.truncateUtf8
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

/**
 * Session UI plus full-screen video (T-012 + T-013 + T-015). Session logic lives in
 * dev.matebridge.client.session, decoding in dev.matebridge.client.video; this class wires them to views.
 * While connected and streaming the connection panel is hidden and the SurfaceView (fitted to the
 * stream aspect, so the surface is exactly the video area) fills the screen. Input capture comes later.
 */
class MainActivity : Activity(), SurfaceHolder.Callback {
    private lateinit var status: TextView
    private lateinit var endpointField: EditText
    private lateinit var settings: Settings
    private lateinit var controller: SessionController
    private var discovery: MacDiscovery? = null
    private lateinit var root: FrameLayout
    private lateinit var video: SurfaceView
    private lateinit var panel: View
    private lateinit var statsView: TextView
    private val ui = Handler(Looper.getMainLooper())
    private val clock = ClockSync()

    // Video state. renderer is read from the video reader thread; the rest is main-thread only.
    @Volatile private var renderer: VideoRenderer? = null
    private var streamConfig: StreamConfig? = null
    private var surfaceValid = false
    private var statsOn = false
    private var lastStatsMs = 0L

    // T-016 smoothness knobs. Launch extras: `--ei jitter 0|1|2` (jitter buffer in content frames,
    // 0 = render at once as in T-015) and `--ei hz 120` (preferred refresh rate while streaming, 0 = leave alone).
    private var bufferFrames = 1
    private var targetHz = 120
    private val vsync = VsyncClock()
    private var choreographerOn = false
    private var modeApplied = false
    private val vsyncCallback = object : Choreographer.FrameCallback {
        override fun doFrame(frameTimeNanos: Long) {
            vsync.onVsync(frameTimeNanos)
            if (choreographerOn) Choreographer.getInstance().postFrameCallback(this)
        }
    }
    private val displayListener = object : DisplayManager.DisplayListener {
        override fun onDisplayAdded(displayId: Int) {}
        override fun onDisplayRemoved(displayId: Int) {}
        override fun onDisplayChanged(displayId: Int) { vsync.setNominalHz(currentHz()) }
    }

    /**
     * The one place view pixels map to normalized video coordinates (input capture will use it).
     * Built from the actual laid-out SurfaceView (integer size, `video.left/top`), so it is in
     * ROOT (SurfaceView parent, = window content) coordinates: use it with MotionEvents delivered to
     * `root`/the window (or convert view-local events by adding `video.left/top`). Empty until laid out.
     */
    var viewport: VideoViewport = VideoViewport(0, 0, 0, 0)
        private set

    // Main-thread state
    private var currentEndpoint: Endpoint? = null
    private var manualMode = false
    private var started = false
    private var lastUi: SessionUi = SessionUi.Searching

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        bufferFrames = intent?.getIntExtra("jitter", 1)?.coerceIn(0, 2) ?: 1
        targetHz = intent?.getIntExtra("hz", 120) ?: 120
        setContentView(R.layout.activity_main)
        status = findViewById(R.id.status)
        root = findViewById(R.id.root)
        video = findViewById(R.id.video)
        panel = findViewById(R.id.panel)
        statsView = findViewById(R.id.stats)
        video.holder.addCallback(this)
        root.addOnLayoutChangeListener { _, _, _, _, _, _, _, _, _ -> layoutVideo() }
        video.addOnLayoutChangeListener { v, _, _, _, _, _, _, _, _ ->
            viewport = if (streamConfig == null || v.width <= 0 || v.height <= 0) VideoViewport(0, 0, 0, 0)
            else VideoViewport.ofRect(v.left, v.top, v.width, v.height)
        }
        video.setOnLongClickListener { toggleStats(); true }
        findViewById<Button>(R.id.toggle_stats).setOnClickListener { toggleStats() }
        endpointField = findViewById(R.id.endpoint)
        val prefs = getSharedPreferences("matebridge", Context.MODE_PRIVATE)
        settings = Settings(object : KeyValueStore {
            override fun getString(key: String) = prefs.getString(key, null)
            override fun putString(key: String, value: String) { prefs.edit().putString(key, value).apply() }
        })
        statsOn = settings.statsOverlay()
        applyStatsVisibility()
        settings.lastEndpoint()?.let { endpointField.setText(it.toString()) }
        findViewById<Button>(R.id.connect).setOnClickListener { onConnectClicked() }

        controller = SessionController(buildHello(), object : SessionListener {
            override fun onUi(state: SessionUi) { runOnUiThread { render(state) } }
            override fun onStreamConfig(config: StreamConfig) { runOnUiThread { installConfig(config) } }

            override fun onVideoFrame(frame: VideoFrame) {
                // Never feed the queue while no surface is attached (T-013 handoff).
                renderer?.let { if (it.attached) it.onFrame(frame) }
            }

            override fun onSessionStart() { clock.reset() }

            override fun onPong(echoTimeUs: Long, responderTimeUs: Long, nowUs: Long) {
                clock.onPong(echoTimeUs, responderTimeUs, nowUs)
            }
        })
        applyImmersive()
        render(SessionUi.Searching)
    }

    @Suppress("DEPRECATION")
    private fun applyImmersive() {
        window.decorView.systemUiVisibility = (View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY
            or View.SYSTEM_UI_FLAG_FULLSCREEN
            or View.SYSTEM_UI_FLAG_HIDE_NAVIGATION
            or View.SYSTEM_UI_FLAG_LAYOUT_STABLE
            or View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN
            or View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION)
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus) applyImmersive()
    }

    override fun onKeyDown(keyCode: Int, event: KeyEvent): Boolean {
        if (keyCode == KeyEvent.KEYCODE_F3 && event.repeatCount == 0) { toggleStats(); return true }
        return super.onKeyDown(keyCode, event)
    }

    private fun toggleStats() {
        statsOn = !statsOn
        settings.setStatsOverlay(statsOn)
        applyStatsVisibility()
    }

    private fun applyStatsVisibility() {
        statsView.visibility = if (statsOn) View.VISIBLE else View.GONE
    }

    // ---- video surface and renderer ----

    override fun surfaceCreated(holder: SurfaceHolder) {
        surfaceValid = true
        if (streamConfig != null) renderer?.attachSurface(holder.surface)
        if (modeApplied) setSurfaceFrameRate(true)
    }

    override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) {}

    override fun surfaceDestroyed(holder: SurfaceHolder) {
        surfaceValid = false
        renderer?.detachSurface()
    }

    private fun installConfig(config: StreamConfig) {
        if (!started || isDestroyed) return
        streamConfig = config
        val r = renderer ?: VideoRenderer(
            config,
            onKeyframeRequest = { reason -> controller.trySend(KeyframeRequest(reason)) },
            onGiveUp = { why -> MbLog.e("decoder_give_up", "reason=${why.take(40)}", "decoder") },
            vsync = vsync,
            bufferFrames = bufferFrames,
        ).also {
            it.stats.latencyOf = { cap -> clock.latencyUs(cap, SessionController.clockUs()) }
            renderer = it
        }
        layoutVideo()
        applyRefreshRate()
        lastStatsMs = SystemClock.elapsedRealtime()
        r.reconfigure(config) // restarts the codec without blocking when a surface is attached
        if (!r.attached && surfaceValid) r.attachSurface(video.holder.surface)
    }

    /** Stops video (surface released, frames gated). The renderer object is kept and reused. */
    private fun releaseRenderer() {
        renderer?.detachSurface()
        streamConfig = null
        statsView.text = ""
        releaseRefreshRate()
    }

    @Suppress("DEPRECATION")
    private fun currentHz(): Float = windowManager.defaultDisplay.refreshRate

    /** While streaming, prefer the supported mode closest to [targetHz] at the current resolution. */
    @Suppress("DEPRECATION")
    private fun applyRefreshRate() {
        if (modeApplied || targetHz <= 0) return
        val d = windowManager.defaultDisplay
        val cur = d.mode
        val all = d.supportedModes.map { DisplayModeInfo(it.modeId, it.physicalWidth, it.physicalHeight, it.refreshRate) }
        val pick = DisplayModePicker.pick(
            all, DisplayModeInfo(cur.modeId, cur.physicalWidth, cur.physicalHeight, cur.refreshRate), targetHz.toFloat(),
        )
        MbLog.i(
            "display_mode",
            "requested_hz=$targetHz current_id=${cur.modeId} current_hz=${cur.refreshRate} " +
                "picked_id=${pick?.id ?: -1} picked_hz=${pick?.refreshHz ?: -1f} modes=" +
                all.joinToString(",") { "${it.id}:${it.refreshHz.roundToInt()}" },
            "render",
        )
        if (pick == null) return
        modeApplied = true
        window.attributes = window.attributes.also { it.preferredDisplayModeId = pick.id }
        vsync.setNominalHz(pick.refreshHz)
        setSurfaceFrameRate(true)
    }

    private fun releaseRefreshRate() {
        if (!modeApplied) return
        modeApplied = false
        setSurfaceFrameRate(false)
        window.attributes = window.attributes.also { it.preferredDisplayModeId = 0 }
    }

    private fun setSurfaceFrameRate(on: Boolean) {
        if (Build.VERSION.SDK_INT < 30 || !surfaceValid) return
        try {
            video.holder.surface.setFrameRate(if (on) targetHz.toFloat() else 0f, Surface.FRAME_RATE_COMPATIBILITY_DEFAULT)
        } catch (e: Exception) {
            MbLog.w("set_frame_rate_failed", "err=${e.javaClass.simpleName}", "render")
        }
    }

    /** Fits the SurfaceView to the stream aspect so the surface equals the video area (letterbox = black bands). */
    private fun layoutVideo() {
        val c = streamConfig
        val vp = if (c == null) VideoViewport(0, 0, 0, 0) else VideoViewport(root.width, root.height, c.widthPx, c.heightPx)
        val w = if (vp.isEmpty) FrameLayout.LayoutParams.MATCH_PARENT else Math.round(vp.width)
        val h = if (vp.isEmpty) FrameLayout.LayoutParams.MATCH_PARENT else Math.round(vp.height)
        val lp = video.layoutParams as FrameLayout.LayoutParams
        if (lp.width != w || lp.height != h) {
            lp.width = w
            lp.height = h
            video.layoutParams = lp
        }
    }

    /** Every 500 ms: re-request a keyframe while gated; every 1 s: STATS, overlay and log summary. */
    private val ticker = object : Runnable {
        override fun run() {
            val r = renderer
            if (r != null && r.attached) {
                if (r.isWaitingKeyframe()) controller.trySend(KeyframeRequest(KeyframeRequest.STARTUP))
                val now = SystemClock.elapsedRealtime()
                if (now - lastStatsMs >= 1000) statsTick(r, now)
            }
            ui.postDelayed(this, KEYFRAME_RETRY_MS)
        }
    }

    private fun statsTick(r: VideoRenderer, now: Long) {
        val interval = now - lastStatsMs
        lastStatsMs = now
        val s = r.stats.snapshot(reset = true)
        val lat = s.latencyAvgUs
        controller.trySend(StatsFormat.toMessage(s, interval, lat))
        if (statsOn) {
            statsView.text = StatsFormat.overlay(s, interval, lat, StatsFormat.pacingLine(currentHz(), r.bufferFrames))
        }
        val fps = s.rendered * 1000.0 / interval.coerceAtLeast(1)
        MbLog.i(
            "stats",
            "interval_ms=$interval recv=${s.received} dec=${s.decoded} shown=${s.rendered} drop=${s.dropped} " +
                "decode_avg_us=${s.decodeTimeAvgUs} bytes=${s.bytesReceived}",
            "decoder",
        )
        MbLog.i(
            "stats",
            "fps=${"%.1f".format(java.util.Locale.ROOT, fps)} latency_us=${lat ?: -1} " +
                "clock_offset_us=${clock.offsetUs() ?: 0} rtt_us=${clock.bestRttUs() ?: -1} " +
                "hz=${"%.0f".format(java.util.Locale.ROOT, currentHz())} buffer=${r.bufferFrames} " +
                StatsFormat.gapFields("net", s.network) + " " + StatsFormat.gapFields("ready", s.ready) + " " +
                StatsFormat.gapFields("shown", s.shown),
            "render",
        )
    }

    override fun onStart() {
        super.onStart()
        started = true
        dev.matebridge.client.session.MbLog.i("activity_start")
        currentEndpoint = null
        manualMode = false
        render(SessionUi.Searching)
        ui.removeCallbacks(ticker)
        ui.postDelayed(ticker, KEYFRAME_RETRY_MS)
        if (!choreographerOn) {
            choreographerOn = true
            Choreographer.getInstance().postFrameCallback(vsyncCallback)
            (getSystemService(Context.DISPLAY_SERVICE) as DisplayManager).registerDisplayListener(displayListener, ui)
        }
        discovery = MacDiscovery(this) { ep -> runOnUiThread { onDiscovered(ep) } }.also { it.start() }
    }

    override fun onStop() {
        started = false
        dev.matebridge.client.session.MbLog.i("activity_stop")
        ui.removeCallbacks(ticker)
        choreographerOn = false
        Choreographer.getInstance().removeFrameCallback(vsyncCallback)
        (getSystemService(Context.DISPLAY_SERVICE) as DisplayManager).unregisterDisplayListener(displayListener)
        discovery?.stop()
        discovery = null
        releaseRenderer() // video stops in the background; a fresh session re-requests a keyframe on return
        controller.stop() // sends BYE, closes both connections
        super.onStop()
    }

    override fun onDestroy() {
        ui.removeCallbacksAndMessages(null)
        releaseRenderer()
        controller.shutdown()
        super.onDestroy()
    }

    private fun onDiscovered(ep: Endpoint) {
        if (!started || manualMode) return
        if (currentEndpoint == null || lastUi is SessionUi.Disconnected) {
            connect(ep)
        }
    }

    private fun onConnectClicked() {
        val typed = endpointField.text.toString()
        val ep = if (typed.isBlank()) currentEndpoint else Endpoint.parse(typed)
        if (ep == null) {
            Toast.makeText(this, R.string.invalid_endpoint, Toast.LENGTH_SHORT).show()
            return
        }
        if (typed.isNotBlank()) {
            manualMode = true
            settings.saveEndpoint(ep)
        }
        connect(ep)
    }

    private fun connect(ep: Endpoint) {
        currentEndpoint = ep
        controller.start(ep)
    }

    private fun render(state: SessionUi) {
        if (!started || isDestroyed) return
        lastUi = state
        if (state !is SessionUi.Connected) releaseRenderer()
        val streaming = state is SessionUi.Connected && state.framesReceived > 0 && renderer != null
        panel.visibility = if (streaming) View.GONE else View.VISIBLE
        status.text = when (state) {
            SessionUi.Idle -> getString(R.string.state_idle)
            SessionUi.Searching -> getString(R.string.state_searching)
            is SessionUi.Connecting -> getString(R.string.state_connecting, state.endpoint.toString())
            is SessionUi.AwaitingApproval -> getString(R.string.state_awaiting_approval, state.hostName)
            is SessionUi.Connected -> getString(R.string.state_connected, state.hostName, state.framesReceived)
            is SessionUi.Disconnected -> getString(
                R.string.state_disconnected, causeText(state.cause), (state.retryInMs + 999) / 1000,
            )
            is SessionUi.Failed -> getString(R.string.state_failed, causeText(state.cause))
        }
    }

    private companion object {
        const val KEYFRAME_RETRY_MS = 500L
    }

    private fun causeText(c: SessionUi.Cause) = getString(
        when (c) {
            SessionUi.Cause.LOST -> R.string.cause_lost
            SessionUi.Cause.HOST_CLOSED -> R.string.cause_host_closed
            SessionUi.Cause.BUSY -> R.string.cause_busy
            SessionUi.Cause.REJECTED -> R.string.cause_rejected
            SessionUi.Cause.VERSION_MISMATCH -> R.string.cause_version_mismatch
            SessionUi.Cause.PROTOCOL_ERROR -> R.string.cause_protocol_error
            SessionUi.Cause.CONNECT_FAILED -> R.string.cause_connect_failed
        },
    )

    @Suppress("DEPRECATION")
    private fun buildHello(): Hello {
        val dm = android.util.DisplayMetrics()
        windowManager.defaultDisplay.getRealMetrics(dm)
        val w = max(dm.widthPixels, dm.heightPixels) // landscape-locked: report native landscape size
        val h = min(dm.widthPixels, dm.heightPixels)
        val hz = windowManager.defaultDisplay.refreshRate.roundToInt()
        val caps = Capabilities.PEN or Capabilities.PEN_HOVER or Capabilities.PEN_TILT or Capabilities.KEYBOARD or
            Capabilities.TOUCHPAD or Capabilities.TOUCH or Capabilities.DECODE_H264 or Capabilities.DECODE_HEVC
        return Hello(
            protocolVersion = 0,
            deviceId = Bytes(settings.deviceId()),
            screenWidthPx = w,
            screenHeightPx = h,
            densityDpi = dm.densityDpi,
            maxRefreshHz = hz,
            capabilities = caps.toLong(),
            deviceName = truncateUtf8(Build.MODEL ?: "Android"),
        )
    }
}
