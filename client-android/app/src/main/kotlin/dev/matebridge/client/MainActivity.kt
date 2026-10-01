package dev.matebridge.client

import android.app.Activity
import android.content.Context
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.hardware.display.DisplayManager
import android.hardware.input.InputManager
import android.view.Choreographer
import android.view.InputDevice
import android.view.KeyEvent
import android.view.MotionEvent
import android.view.Surface
import android.view.SurfaceHolder
import android.view.SurfaceView
import android.view.View
import android.view.WindowManager
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputMethodManager
import android.graphics.Color
import android.graphics.Typeface
import android.text.SpannableStringBuilder
import android.text.Spanned
import android.text.style.ForegroundColorSpan
import android.text.style.RelativeSizeSpan
import android.text.style.StyleSpan
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.Button
import android.widget.EditText
import android.widget.TextView
import android.widget.Toast
import dev.matebridge.client.input.DoubleTapDetector
import dev.matebridge.client.input.InputCapture
import dev.matebridge.client.input.InputSink
import dev.matebridge.client.input.KeyFrame
import dev.matebridge.client.input.KeyTracker
import dev.matebridge.client.input.LocalAction
import dev.matebridge.client.input.MotionEventAdapter
import dev.matebridge.client.input.UnbufferedPenDispatch
import dev.matebridge.client.protocol.Capabilities
import dev.matebridge.client.protocol.Bytes
import dev.matebridge.client.protocol.Hello
import dev.matebridge.client.protocol.KeyframeRequest
import dev.matebridge.client.protocol.Limits
import dev.matebridge.client.protocol.Message
import dev.matebridge.client.protocol.ReleaseAll
import dev.matebridge.client.protocol.StreamConfig
import dev.matebridge.client.protocol.VideoFrame
import dev.matebridge.client.security.AndroidKeystoreWrapper
import dev.matebridge.client.security.EncryptedPairKeyStore
import dev.matebridge.client.session.MbLog
import dev.matebridge.client.stream.ClockSync
import dev.matebridge.client.stream.DisplayModeInfo
import dev.matebridge.client.stream.DisplayModePicker
import dev.matebridge.client.stream.FrameRatePolicy
import dev.matebridge.client.video.IntervalHistogram
import dev.matebridge.client.stream.StatsFormat
import dev.matebridge.client.stream.StreamMode
import dev.matebridge.client.overlay.PenOverlayView
import dev.matebridge.client.stream.VideoLayout
import dev.matebridge.client.stream.VideoViewport
import dev.matebridge.client.video.GlPresenter
import dev.matebridge.client.video.PresentStats
import dev.matebridge.client.video.VideoRenderer
import dev.matebridge.client.video.OperatingRate
import dev.matebridge.client.stream.DisplayRateDebouncer
import dev.matebridge.client.video.VsyncClock
import dev.matebridge.client.session.ConnectMode
import dev.matebridge.client.session.Endpoint
import dev.matebridge.client.session.Transport
import dev.matebridge.client.session.KeyValueStore
import dev.matebridge.client.session.MacDiscovery
import dev.matebridge.client.clipboard.ClipboardBridge
import dev.matebridge.client.clipboard.ClipboardSync
import dev.matebridge.client.protocol.Clipboard
import dev.matebridge.client.session.SessionController
import dev.matebridge.client.session.SessionListener
import dev.matebridge.client.session.SessionUi
import dev.matebridge.client.session.Settings
import dev.matebridge.client.session.SpeedRange
import dev.matebridge.client.session.truncateUtf8
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

/**
 * Session UI plus full-screen video (T-012 + T-013 + T-015). Session logic lives in
 * dev.matebridge.client.session, decoding in dev.matebridge.client.video; this class wires them to views.
 * While connected and streaming the connection panel is hidden and the SurfaceView (fitted to the
 * stream aspect, so the surface is exactly the video area) fills the screen. While the video is shown, pen and
 * finger events are routed to [InputCapture] (T-024) instead of the views.
 */
class MainActivity : Activity(), SurfaceHolder.Callback {
    private lateinit var status: TextView
    private lateinit var endpointField: EditText
    private lateinit var settings: Settings
    private lateinit var controller: SessionController
    private var streamMode = StreamMode.DEFAULT
    private var modeButton: Button? = null
    private lateinit var clipboard: ClipboardBridge // T-055
    private var discovery: MacDiscovery? = null
    private lateinit var root: FrameLayout
    private lateinit var video: SurfaceView // MediaCodec -> SurfaceView path
    private lateinit var videoGl: SurfaceView // target of the GL presenter (T-018)
    private lateinit var videoView: SurfaceView // whichever of the two is in use
    private lateinit var panel: View
    private lateinit var penOverlay: PenOverlayView // T-056
    private lateinit var statsView: TextView
    private val ui = Handler(Looper.getMainLooper())
    private val clock = ClockSync()
    private lateinit var capture: InputCapture
    private lateinit var unbufferedPen: UnbufferedPenDispatch
    private val rootLoc = IntArray(2)
    private var inputFaultUntilMs = 0L

    // Video state. renderer is read from the video reader thread; the rest is main-thread only.
    @Volatile private var renderer: VideoRenderer? = null
    private var paceTrace: dev.matebridge.client.video.PaceTrace? = null // T-069 experiment (--ez pace_trace true), default off
    /** T-079 experiment (--ez perf_hint true), default off; shared by the video reader and the decoder threads. */
    private var perfHint: dev.matebridge.client.video.PerfHint? = null
    private var streamConfig: StreamConfig? = null
    private var surfaceValid = false
    private var statsOn = false
    private var lastStatsMs = 0L

    // T-016/T-052 smoothness knobs. Launch extras: `--ei jitter N` (unset = adaptive pacing on the surface path;
    // 0|1|2 = fixed jitter buffer in content frames, 0 = render at once as in T-015; -1 = adaptive off = 0) and `--ei hz 120` (preferred refresh rate while streaming, 0 = leave alone).
    private var bufferFrames = VideoRenderer.BUFFER_ADAPTIVE
    private var operatingRate = OperatingRate.STREAM_FPS // `--ei oprate 0|-1|-2|N`, see OperatingRate
    private var targetHz = FrameRatePolicy.HZ_FOLLOW_STREAM // T-046: follow the stream fps unless `hz` is given
    private var appliedModeHz = 0
    private val vsyncGaps = IntervalHistogram()
    private val vsync = VsyncClock()

    // T-018: `--es render surface|gl` picks the presentation path; `--ei frate N` sets Surface.setFrameRate(N,
    // FIXED_SOURCE) on either path (0 = off; unset: GL uses `hz`, the surface path keeps the content-fps hint);
    // `--ez glpts true` adds eglPresentationTimeANDROID (GL only).
    private var glMode = false
    private var frameRateOverride = -1
    private var glPresentationTime = false
    private val presentStats = PresentStats()
    private val glVsync = VsyncClock()
    private var inflightLimit = 0 // T-057: `--ei inflight N` (0 = unlimited)
    private var presenter: GlPresenter? = null
    private var glDecoderSurface: Surface? = null
    private var glGeneration = 0
    private var choreographerOn = false
    private var modeApplied = false
    private val vsyncCallback = object : Choreographer.FrameCallback {
        override fun doFrame(frameTimeNanos: Long) {
            vsync.onVsync(frameTimeNanos)
            vsyncGaps.mark(frameTimeNanos / 1000)
            if (choreographerOn) Choreographer.getInstance().postFrameCallback(this)
        }
    }
    private val displayListener = object : DisplayManager.DisplayListener {
        override fun onDisplayAdded(displayId: Int) {}
        override fun onDisplayRemoved(displayId: Int) {}
        override fun onDisplayChanged(displayId: Int) { vsync.setNominalHz(currentHz()); applyDisplayTiming(log = false) }
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
    private var transport = Transport.WIFI
    private var usbStartMs = 0L
    private var hostReached = false
    private val usbHintCheck = Runnable { render(lastUi) }
    private var lastUi: SessionUi = SessionUi.Searching

    /**
     * T-079: `--ez perf_hint true` puts the video reader and decoder threads in one PerformanceHintManager session
     * (target = panel period, or `--ei perf_hint_target_us N`). Logs `ev=perf_hint enabled=… supported=…` either way.
     */
    private fun setupPerfHint() {
        val on = intent?.getBooleanExtra("perf_hint", false) == true
        val backend = dev.matebridge.client.video.AndroidPerfHint.create(this)
        val hint = dev.matebridge.client.video.PerfHint(backend) { ev, fields -> MbLog.i(ev, fields, "render") }
        val fixedUs = intent?.getIntExtra("perf_hint_target_us", 0) ?: 0
        if (on && fixedUs > 0) hint.setFixedTargetNs(fixedUs * 1000L)
        MbLog.i("perf_hint", "enabled=${if (on) 1 else 0} ${hint.describe()} fixed_target=${if (on && fixedUs > 0) 1 else 0}", "render")
        perfHint = if (on) hint else null
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        glMode = intent?.getStringExtra("render") == "gl"
        frameRateOverride = intent?.getIntExtra("frate", -1) ?: -1
        glPresentationTime = intent?.getBooleanExtra("glpts", false) ?: false
        operatingRate = intent?.getIntExtra("oprate", OperatingRate.STREAM_FPS) ?: OperatingRate.STREAM_FPS
        bufferFrames = when {
            glMode -> 0 // the GL presenter aligns to vsync itself; SurfaceTexture ignores release timestamps
            intent?.hasExtra("jitter") != true -> VideoRenderer.BUFFER_ADAPTIVE
            else -> intent.getIntExtra("jitter", 0).coerceIn(0, 2) // -1 (adaptive off) -> 0
        }
        inflightLimit = intent?.getIntExtra("inflight", 0)?.coerceIn(0, 8) ?: 0
        intent?.getIntExtra("lead_us", -1)?.takeIf { it >= 0 }?.let {
            vsync.leadOverrideNs = it * 1000L
            glVsync.leadOverrideNs = it * 1000L
        }
        // T-071: absent = 6 ms default; -1 = the display's reported deadline; N >= 0 = N us.
        if (intent?.hasExtra("deadline_us") == true) {
            val us = intent.getIntExtra("deadline_us", -1)
            val ns = if (us >= 0) us * 1000L else VsyncClock.DEADLINE_DISPLAY
            vsync.deadlineOverrideNs = ns
            glVsync.deadlineOverrideNs = ns
        }
        vsync.keepJitter = intent?.getBooleanExtra("keep_jitter", false) == true
        vsync.recenter = intent?.getBooleanExtra("recenter", false) == true
        paceTrace = if (intent?.getBooleanExtra("pace_trace", false) == true) dev.matebridge.client.video.PaceTrace() else null
        // T-076: one-shot AES-GCM provider benchmark (adb ... --ez crypto_bench true), off the UI thread.
        if (intent?.getBooleanExtra("crypto_bench", false) == true) {
            Thread({ dev.matebridge.client.security.Records.runBench() }, "crypto-bench").start()
        }
        targetHz = intent?.getIntExtra("hz", FrameRatePolicy.HZ_FOLLOW_STREAM) ?: FrameRatePolicy.HZ_FOLLOW_STREAM
        setupPerfHint()
        setContentView(R.layout.activity_main)
        status = findViewById(R.id.status)
        root = findViewById(R.id.root)
        video = findViewById(R.id.video)
        videoGl = findViewById(R.id.video_gl)
        videoView = if (glMode) videoGl else video
        video.visibility = if (glMode) View.GONE else View.VISIBLE
        videoGl.visibility = if (glMode) View.VISIBLE else View.GONE
        MbLog.i("render_mode", "mode=${if (glMode) "gl" else "surface"} frate=$frameRateOverride glpts=$glPresentationTime", "render")
        panel = findViewById(R.id.panel)
        statsView = findViewById(R.id.stats)
        // Both views are wired: the GL path can fall back to the SurfaceView at runtime.
        for (sv in listOf(video, videoGl)) {
            sv.holder.addCallback(this)
            sv.addOnLayoutChangeListener { v, _, _, _, _, _, _, _, _ ->
                if (v === videoView) {
                    viewport = if (streamConfig == null || v.width <= 0 || v.height <= 0) VideoViewport(0, 0, 0, 0)
                    else VideoViewport.ofRect(v.left, v.top, v.width, v.height)
                    if (v === videoView && ::penOverlay.isInitialized) penOverlay.setVideoViewport(viewport)
                }
            }
            sv.setOnLongClickListener { toggleStats(); true }
        }
        root.addOnLayoutChangeListener { _, _, _, _, _, _, _, _, _ -> layoutVideo() }
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
        setupManualEntry()
        findViewById<Button>(R.id.connect).setOnClickListener { onConnectClicked() }
        findViewById<Button>(R.id.connect_usb).setOnClickListener { selectTransport(Transport.USB) }
        findViewById<Button>(R.id.connect_wifi).setOnClickListener { selectTransport(Transport.WIFI) }

        val pairKeys = EncryptedPairKeyStore(
            object : KeyValueStore {
                val secure = getSharedPreferences("matebridge_pairkeys", Context.MODE_PRIVATE)
                override fun getString(key: String) = secure.getString(key, null)
                override fun putString(key: String, value: String) {
                    // A pairing key that did not persist must not count as paired.
                    if (!secure.edit().putString(key, value).commit()) throw java.io.IOException("prefs commit failed")
                }
            },
            AndroidKeystoreWrapper(),
        )
        streamMode = settings.streamMode()
        val quickAck = dev.matebridge.client.session.QuickAck.parseExtra(
            intent?.hasExtra("quickack") == true, intent?.getBooleanExtra("quickack", true) ?: true,
        )
        controller = SessionController(buildHello(), pairKeys, object : SessionListener {
            override fun onUi(state: SessionUi) { runOnUiThread { render(state) } }
            override fun onStreamConfig(config: StreamConfig) { runOnUiThread { installConfig(config) } }

            override fun onVideoFrame(frame: VideoFrame) {
                // Never feed the queue while no surface is attached (T-013 handoff).
                renderer?.let { if (it.attached) it.onFrame(frame) }
            }

            override fun onSessionStart() {
                clock.reset()
                runOnUiThread { capture.onSessionReset() } // the host holds no input state for a new connection
            }

            override fun onPong(echoTimeUs: Long, responderTimeUs: Long, nowUs: Long) {
                clock.onPong(echoTimeUs, responderTimeUs, nowUs)
            }

            override fun onClipboard(msg: Clipboard, gen: Int) { if (::clipboard.isInitialized) clipboard.postRemote(msg, gen) }
        }, streamMode, quickAck, perfHint)
        capture = InputCapture(
            object : InputSink {
                override fun send(msg: Message) = controller.trySend(msg)
                override fun congested() = controller.isSendCongested()
                override fun closeConnection() = controller.dropConnection()
            },
            { viewport },
            onEvent = { ev, fields -> MbLog.i(ev, fields, "input") },
        ) { line -> MbLog.i("stats", line, "input") }
        capture.setFingersDisabled(settings.fingerTouchDisabled(), SystemClock.uptimeMillis())
        applyPointerSpeeds()
        // T-026: ask the system not to batch pen samples per display frame while input capture is active. The request
        // sits on a LEAF view, `video` (a fixed child of root, also while the GL view is the one in use): a ViewGroup
        // recomputes its own unbuffered source from its children (ViewGroup.onDescendantUnbufferedRequested, e.g. on
        // a focus change), so a request stored on `root` itself would be overwritten, while a leaf's request is
        // re-derived by every ancestor.
        unbufferedPen = UnbufferedPenDispatch(
            Build.VERSION.SDK_INT,
            UnbufferedPenDispatch.Backend { on ->
                if (on && !video.isAttachedToWindow) return@Backend false // no window yet; sync retries
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) { // View.requestUnbufferedDispatch(int) is API 30
                    // View ignores a request equal to its current value; clear first so a set always reaches the window.
                    video.requestUnbufferedDispatch(InputDevice.SOURCE_CLASS_NONE)
                    if (on) video.requestUnbufferedDispatch(InputDevice.SOURCE_STYLUS)
                }
                true
            },
            onEvent = { ev, fields -> MbLog.i(ev, fields, "input") },
        )
        // A new window (ViewRootImpl) starts without the request: request it again.
        video.addOnAttachStateChangeListener(object : View.OnAttachStateChangeListener {
            override fun onViewAttachedToWindow(v: View) { unbufferedPen.reapplyOnNextSync() }
            override fun onViewDetachedFromWindow(v: View) { unbufferedPen.reapplyOnNextSync() }
        })
        for (sv in listOf(video, videoGl)) {
            sv.isFocusable = true
            sv.isFocusableInTouchMode = true
            sv.setOnCapturedPointerListener(capturedPointerListener)
        }
        clipboard = ClipboardBridge(this, ClipboardSync().also { it.enabled = settings.clipboardShare() }, { controller.trySend(it) }, { runOnUiThread(it) })
        // T-056: local pen indicator above the video (below the stats text and the panel), never touchable.
        penOverlay = PenOverlayView(this)
        penOverlay.model.trailEnabled = settings.penTrail()
        penOverlay.model.dotEnabled = settings.penDot()
        penOverlay.setVideoViewport(viewport)
        root.addView(penOverlay, root.indexOfChild(statsView), FrameLayout.LayoutParams(FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT))
        capture.penInk = penOverlay
        addFingerToggle()
        addModeButton()
        addClipboardToggle()
        addPenToggles()
        addShortcutHint()
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
        if (::clipboard.isInitialized) { if (hasFocus) clipboard.start() else clipboard.stop() } // clipboard reads need focus
        if (!::capture.isInitialized) return
        if (hasFocus) unbufferedPen.reapplyOnNextSync() // the request is idempotent; re-assert it when the window is back
        if (hasFocus) capture.resume() else capture.releaseAll(ReleaseAll.FOCUS_LOST, SystemClock.uptimeMillis())
    }

    override fun onPause() {
        // Release before onStop() closes the session, so RELEASE_ALL is queued ahead of BYE (PROTOCOL.md section 7).
        if (::capture.isInitialized) capture.releaseAll(ReleaseAll.BACKGROUND, SystemClock.uptimeMillis())
        super.onPause()
    }

    // ---- input capture (T-024) ----

    /** Input is routed to [capture] only while the video is visible and laid out; the connect panel keeps normal touch. */
    private fun syncInputActive(nowMs: Long = SystemClock.uptimeMillis()): Boolean {
        val on = started && !isDestroyed && panel.visibility == View.GONE && !viewport.isEmpty
        capture.setActive(on, nowMs)
        unbufferedPen.sync(on)
        syncPointerCapture(on, nowMs)
        return on
    }

    private var lastCaptureRequestMs = 0L

    /**
     * Pointer capture (touchpad and mouse, T-034) is wanted while input is accepted, the window has focus and input is not
     * suspended. The system drops it on focus loss, so it is requested again (at most every
     * [POINTER_CAPTURE_RETRY_MS]). The touchscreen and the pen are not captured devices: their events keep coming through
     * dispatchTouchEvent unchanged.
     */
    private fun syncPointerCapture(on: Boolean, nowMs: Long) {
        val want = on && hasWindowFocus() && !capture.isSuspended
        val v = videoView
        if (want) {
            if (!v.hasPointerCapture() && nowMs - lastCaptureRequestMs >= POINTER_CAPTURE_RETRY_MS) {
                lastCaptureRequestMs = nowMs
                v.requestFocus()
                v.requestPointerCapture()
            }
        } else if (v.hasPointerCapture()) {
            v.releasePointerCapture()
        }
    }

    /** Captured pointer events (source TOUCHPAD / MOUSE_RELATIVE) go to the focused view; the activity hook may see them first. */
    private val capturedPointerListener = View.OnCapturedPointerListener { _, ev -> routeToCapture(ev) }

    override fun onPointerCaptureChanged(hasCapture: Boolean) {
        super.onPointerCaptureChanged(hasCapture)
        if (hasCapture || !::capture.isInitialized) return
        // Capture lost (focus, system, our own release): reported buttons go to 0 and an open pad scroll ends.
        try {
            capture.onPointerCaptureLost(SystemClock.uptimeMillis())
        } catch (e: RuntimeException) {
            inputFailed(e, SystemClock.uptimeMillis())
        }
    }

    private fun routeToCapture(ev: MotionEvent): Boolean {
        val now = SystemClock.uptimeMillis()
        return try {
            if (!syncInputActive(now)) return false
            if (now < inputFaultUntilMs) return true // recovering from an input fault: consumed, nothing half-processed
            if (capture.isSuspended && hasWindowFocus()) capture.resume() // safety net for a missed focus callback
            // Old API only: the per-gesture request has to be repeated on every pen DOWN (the source form covers all).
            if (unbufferedPen.wantsPerGestureRequest() && ev.actionMasked == MotionEvent.ACTION_DOWN && isPenTool(ev)) {
                video.requestUnbufferedDispatch(ev)
            }
            // Events arrive in window coordinates; the viewport is in root coordinates.
            root.getLocationInWindow(rootLoc)
            MotionEventAdapter.handle(ev, -rootLoc[0].toFloat(), -rootLoc[1].toFloat(), now, capture)
        } catch (e: RuntimeException) {
            inputFailed(e, now)
            true // consumed: never let a capture bug crash the app or leak the event to the views
        }
    }

    private fun isPenTool(ev: MotionEvent): Boolean {
        val tool = ev.getToolType(ev.actionIndex)
        return tool == MotionEvent.TOOL_TYPE_STYLUS || tool == MotionEvent.TOOL_TYPE_ERASER
    }

    /**
     * A bug in the input path must not kill the app mid-stroke: log it and release everything on the host. A
     * persistent fault would otherwise repeat this (log plus RELEASE_ALL) at event rate, so input is paused for
     * [INPUT_FAULT_BACKOFF_MS] after each fault; the model was forgotten by the release, so resuming is consistent.
     */
    private fun inputFailed(e: RuntimeException, nowMs: Long) {
        if (nowMs < inputFaultUntilMs) return
        inputFaultUntilMs = nowMs + INPUT_FAULT_BACKOFF_MS
        MbLog.e("input_error", "err=${e.javaClass.simpleName}", "input")
        try {
            capture.releaseAll(ReleaseAll.USER, nowMs)
        } catch (_: RuntimeException) {
            controller.dropConnection() // last resort: the host releases on disconnect
        }
    }

    override fun dispatchTouchEvent(ev: MotionEvent): Boolean =
        routeToCapture(ev) || super.dispatchTouchEvent(ev)

    override fun dispatchGenericMotionEvent(ev: MotionEvent): Boolean =
        routeToCapture(ev) || super.dispatchGenericMotionEvent(ev)

    override fun dispatchKeyEvent(ev: KeyEvent): Boolean {
        // The M-Pencil double tap arrives as keyCode 718 / scanCode 190; it becomes PEN_GESTURE and is never sent as KEY.
        if (DoubleTapDetector.isGestureKey(ev.keyCode, ev.scanCode)) {
            if (ev.action == KeyEvent.ACTION_DOWN && ev.repeatCount == 0) {
                syncInputActive()
                capture.onGestureKeyDown(ev.eventTime)
            }
            return true
        }
        val dev = ev.device
        if (dev != null && KeyTracker.isPhysicalKeyboard(dev.isVirtual, ev.source, dev.keyboardType)) {
            syncInputActive()
            val d = capture.onKey(
                KeyFrame(
                    deviceId = ev.deviceId, scanCode = ev.scanCode, keyCode = ev.keyCode,
                    down = ev.action == KeyEvent.ACTION_DOWN, repeatCount = ev.repeatCount,
                    ctrl = ev.metaState and KeyEvent.META_CTRL_ON != 0,
                    shift = ev.metaState and KeyEvent.META_SHIFT_ON != 0,
                    capsOn = ev.metaState and KeyEvent.META_CAPS_LOCK_ON != 0,
                    timeUs = ev.eventTime * 1000,
                ),
            )
            when (d.local) {
                LocalAction.STATS -> toggleStats()
                LocalAction.SPEED_DOWN -> adjustPointerSpeed(SpeedRange.STEP_DOWN)
                LocalAction.SPEED_UP -> adjustPointerSpeed(SpeedRange.STEP_UP)
                // onPause sends RELEASE_ALL(BACKGROUND) (Ctrl/Shift held on the Mac are released) and capture is dropped.
                LocalAction.BACKGROUND -> moveTaskToBack(true)
                LocalAction.STREAM_MODE -> cycleStreamMode()
                LocalAction.NONE -> {}
            }
            if (d.consumed) return true
        }
        return super.dispatchKeyEvent(ev)
    }

    private val inputTicker = object : Runnable {
        override fun run() {
            val now = SystemClock.uptimeMillis()
            try {
                syncInputActive(now)
                if (now >= inputFaultUntilMs) capture.tick(now)
            } catch (e: RuntimeException) {
                inputFailed(e, now)
            }
            ui.postDelayed(this, INPUT_TICK_MS)
        }
    }

    private val inputDeviceListener = object : InputManager.InputDeviceListener {
        override fun onInputDeviceAdded(deviceId: Int) {}
        override fun onInputDeviceChanged(deviceId: Int) {}
        override fun onInputDeviceRemoved(deviceId: Int) { capture.onDeviceRemoved(deviceId, SystemClock.uptimeMillis()) }
    }

    /**
     * "Parmak dokunmasını tamamen kapat" switch (decision 0006), added to the connect panel from code because
     * the layout/strings resources are outside T-024's file list. The setting is persisted in [Settings].
     */
    private fun addFingerToggle() {
        val p = panel as? LinearLayout ?: return
        val b = Button(this)
        fun label() { b.text = "Parmak dokunmasını tamamen kapat: " + if (capture.fingersDisabled) "AÇIK" else "kapalı" }
        b.setOnClickListener {
            val off = !capture.fingersDisabled
            settings.setFingerTouchDisabled(off)
            capture.setFingersDisabled(off, SystemClock.uptimeMillis())
            label()
        }
        label()
        val lp = LinearLayout.LayoutParams(LinearLayout.LayoutParams.WRAP_CONTENT, LinearLayout.LayoutParams.WRAP_CONTENT)
        lp.topMargin = (8 * resources.displayMetrics.density).toInt()
        p.addView(b, lp)
    }

    /** T-055: connect-panel switch for clipboard sharing, persisted in [Settings] (default on). */
    private fun addClipboardToggle() {
        val p = panel as? LinearLayout ?: return
        val b = Button(this)
        fun label() { b.text = "Pano paylaşımı: " + if (clipboard.sync.enabled) "açık" else "kapalı" }
        b.setOnClickListener {
            clipboard.sync.enabled = !clipboard.sync.enabled
            settings.setClipboardShare(clipboard.sync.enabled)
            label()
        }
        label()
        val lp = LinearLayout.LayoutParams(LinearLayout.LayoutParams.WRAP_CONTENT, LinearLayout.LayoutParams.WRAP_CONTENT)
        lp.topMargin = (8 * resources.displayMetrics.density).toInt()
        p.addView(b, lp)
    }

    /** T-056: connect-panel switches for the local pen trail and dot, persisted in [Settings] (default on). */
    private fun addPenToggles() {
        val p = panel as? LinearLayout ?: return
        fun add(title: String, get: () -> Boolean, set: (Boolean) -> Unit) {
            val b = Button(this)
            fun label() { b.text = title + ": " + if (get()) "açık" else "kapalı" }
            b.setOnClickListener { set(!get()); label() }
            label()
            val lp = LinearLayout.LayoutParams(LinearLayout.LayoutParams.WRAP_CONTENT, LinearLayout.LayoutParams.WRAP_CONTENT)
            lp.topMargin = (8 * resources.displayMetrics.density).toInt()
            p.addView(b, lp)
        }
        add("Kalem izi", { penOverlay.model.trailEnabled }) { on ->
            penOverlay.model.trailEnabled = on
            settings.setPenTrail(on)
            penOverlay.onPenClear()
        }
        add("Kalem noktası", { penOverlay.model.dotEnabled }) { on ->
            penOverlay.model.dotEnabled = on
            settings.setPenDot(on)
            penOverlay.postInvalidateOnAnimation()
        }
    }

    /** T-050: connect-panel button that cycles the display mode (click), persisted in [Settings]. */
    private fun addModeButton() {
        val p = panel as? LinearLayout ?: return
        val b = Button(this)
        b.text = streamMode.buttonText()
        b.setOnClickListener { cycleStreamMode(toast = false) }
        modeButton = b
        val lp = LinearLayout.LayoutParams(LinearLayout.LayoutParams.WRAP_CONTENT, LinearLayout.LayoutParams.WRAP_CONTENT)
        lp.topMargin = (8 * resources.displayMetrics.density).toInt()
        p.addView(b, lp)
    }

    /** Next display mode: persist, tell the host (STREAM_PREFS), refresh the button; Toast for the shortcut. */
    private fun cycleStreamMode(toast: Boolean = true) {
        streamMode = streamMode.next()
        settings.setStreamMode(streamMode)
        controller.setStreamMode(streamMode)
        modeButton?.text = streamMode.buttonText()
        if (toast) Toast.makeText(this, streamMode.toastText(), Toast.LENGTH_SHORT).show()
    }

    private fun applyPointerSpeeds() = capture.setPointerSpeeds(settings.touchpadSpeed(), settings.mouseSpeed())

    private fun adjustPointerSpeed(factor: Float) {
        val mouse = capture.lastPointerIsMouse
        val v = settings.adjustSpeed(mouse, factor)
        applyPointerSpeeds()
        Toast.makeText(this, SpeedRange.label(mouse, v), Toast.LENGTH_SHORT).show()
    }

    /** One-line shortcut list in the connect panel (added from code, like the finger switch). */
    private fun addShortcutHint() {
        val p = panel as? LinearLayout ?: return
        val t = TextView(this)
        t.text = "Ctrl+Shift+Esc: Android'e dön · Ctrl+Shift+9/0: imleç hızı · Ctrl+Shift+8: istatistik · Ctrl+Shift+7: görüntü modu"
        val lp = LinearLayout.LayoutParams(LinearLayout.LayoutParams.WRAP_CONTENT, LinearLayout.LayoutParams.WRAP_CONTENT)
        lp.topMargin = (8 * resources.displayMetrics.density).toInt()
        p.addView(t, lp)
    }

    // ---- manual address field (T-078) ----

    /**
     * The manual address field is hidden and disabled unless the user opens it with "Manuel adres". While an editable
     * field is focused or visible, Huawei HiWrite (pen handwriting into text fields) adds a touchable system window over
     * the top centre of the screen that outlives the panel and swallows pen events there once streaming starts.
     */
    private fun setupManualEntry() {
        if (Build.VERSION.SDK_INT >= 33) endpointField.setAutoHandwritingEnabled(false) // no-op below API 33 (tablet: 31)
        endpointField.setOnEditorActionListener { _, actionId, _ ->
            if (actionId == EditorInfo.IME_ACTION_DONE) { onConnectClicked(); true } else false
        }
        findViewById<Button>(R.id.endpoint_toggle).setOnClickListener {
            if (endpointField.visibility == View.VISIBLE) hideManualEntry() else showManualEntry()
        }
        hideManualEntry()
    }

    private fun showManualEntry() {
        endpointField.isEnabled = true
        endpointField.visibility = View.VISIBLE
        endpointField.requestFocus()
        (getSystemService(Context.INPUT_METHOD_SERVICE) as InputMethodManager)
            .showSoftInput(endpointField, InputMethodManager.SHOW_IMPLICIT)
    }

    /** Idempotent: no focus, no IME, gone and disabled (the typed text is kept for "Bağlan"). */
    private fun hideManualEntry() {
        if (endpointField.hasFocus()) endpointField.clearFocus()
        (getSystemService(Context.INPUT_METHOD_SERVICE) as InputMethodManager)
            .hideSoftInputFromWindow(endpointField.windowToken, 0)
        endpointField.visibility = View.GONE
        endpointField.isEnabled = false
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
        if (holder !== videoView.holder) return
        surfaceValid = true
        if (streamConfig != null) setSurfaceFrameRate(true)
        if (glMode) {
            val gen = ++glGeneration
            val p = GlPresenter(
                { us -> renderer?.stats?.onShown(us) }, presentStats, glVsync, glPresentationTime,
                onFailed = { why -> runOnUiThread { if (gen == glGeneration) fallBackToSurface(why) } },
            )
            presenter = p
            p.active = streamConfig != null
            p.start(holder.surface) { s ->
                runOnUiThread {
                    if (gen != glGeneration || !surfaceValid) return@runOnUiThread
                    glDecoderSurface = s
                    if (streamConfig != null) renderer?.attachSurface(s)
                }
            }
        } else if (streamConfig != null) {
            renderer?.attachSurface(holder.surface)
        }
    }

    override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) {}

    /** GL setup or drawing failed: continue on the plain MediaCodec -> SurfaceView path. */
    private fun fallBackToSurface(why: String) {
        if (!glMode || isDestroyed) return
        MbLog.w("gl_fallback", "reason=$why to=surface", "render")
        renderer?.detachSurface()
        glGeneration++
        glDecoderSurface = null
        presenter?.stop()
        presenter = null
        glMode = false
        renderer?.codecReportsShown = true
        surfaceValid = false
        videoGl.visibility = View.GONE
        video.visibility = View.VISIBLE
        videoView = video
        layoutVideo() // the SurfaceView's surfaceCreated then attaches the renderer
    }

    override fun surfaceDestroyed(holder: SurfaceHolder) {
        if (holder !== videoView.holder) return
        surfaceValid = false
        renderer?.detachSurface()
        if (glMode) {
            glGeneration++
            glDecoderSurface = null
            presenter?.stop() // after the decoder released the Surface it renders to
            presenter = null
        }
    }

    private fun installConfig(config: StreamConfig) {
        if (!started || isDestroyed) return
        streamConfig = config
        capture.setStreamGeometry(config.widthPt, config.heightPt)
        val r = renderer ?: VideoRenderer(
            config,
            onKeyframeRequest = { reason -> controller.trySend(KeyframeRequest(reason)) },
            onGiveUp = { why -> MbLog.e("decoder_give_up", "reason=${why.take(40)}", "decoder") },
            vsync = vsync,
            bufferFrames = bufferFrames,
            codecReportsShown = !glMode,
        ).also {
            it.operatingRate = operatingRate
            it.maxInFlight = inflightLimit
            it.paceTrace = paceTrace
            it.paceTraceFile = java.io.File(cacheDir, "pace_trace.csv")
            it.perfHint = perfHint
            it.stats.latencyOf = { cap -> clock.latencyUs(cap, SessionController.clockUs()) }
            renderer = it
        }
        layoutVideo()
        applyRefreshRate()
        setSurfaceFrameRate(true)
        startVsync()
        presenter?.active = true
        lastStatsMs = SystemClock.elapsedRealtime()
        r.reconfigure(config) // restarts the codec without blocking when a surface is attached
        if (!r.attached && surfaceValid) {
            // GL path: the decoder surface exists once the GL thread is ready (attached from its callback).
            val s = if (glMode) glDecoderSurface else video.holder.surface
            if (s != null) r.attachSurface(s)
        }
    }

    /** Stops video (surface released, frames gated). The renderer object is kept and reused. */
    private fun releaseRenderer() {
        renderer?.detachSurface()
        presenter?.active = false
        streamConfig = null
        statsView.text = ""
        releaseRefreshRate()
        setSurfaceFrameRate(false)
        stopVsync()
    }

    /** Vsync tracking runs only while streaming; seeded from the real display rate. */
    private fun startVsync() {
        if (choreographerOn) return
        choreographerOn = true
        vsync.setNominalHz(currentHz())
        applyDisplayTiming(log = true)
        perfHint?.setTargetNs(vsync.periodNs.takeIf { it > 0 } ?: streamConfig?.fps?.takeIf { it > 0 }?.let { 1_000_000_000L / it } ?: 0L)
        vsyncGaps.breakSequence()
        vsyncGaps.summary(reset = true)
        Choreographer.getInstance().postFrameCallback(vsyncCallback)
        (getSystemService(Context.DISPLAY_SERVICE) as DisplayManager).registerDisplayListener(displayListener, ui)
        rateDebouncer = DisplayRateDebouncer()
        ui.removeCallbacks(rateTicker)
        ui.post(rateTicker)
    }

    /** T-059: the measured panel rate (from the vsync period), debounced, goes to the session (host thins frames to it). */
    private var rateDebouncer = DisplayRateDebouncer()
    private val rateTicker = object : Runnable {
        override fun run() {
            if (!choreographerOn) return
            val period = vsync.periodNs
            if (period > 0) {
                val hz = Math.round(1e9 / period).toInt()
                rateDebouncer.observe(hz, SystemClock.elapsedRealtime())?.let {
                    controller.setDisplayRate(it)
                    MbLog.i("display_rate", "hz=$it", "render")
                    if (it > 0) perfHint?.setTargetNs(1_000_000_000L / it) // T-079: target = panel period
                }
            }
            ui.postDelayed(this, RATE_POLL_MS)
        }
    }

    private fun stopVsync() {
        if (!choreographerOn) return
        choreographerOn = false
        ui.removeCallbacks(rateTicker)
        Choreographer.getInstance().removeFrameCallback(vsyncCallback)
        (getSystemService(Context.DISPLAY_SERVICE) as DisplayManager).unregisterDisplayListener(displayListener)
        vsync.reset()
    }

    /** T-057: app vsync offset and presentation deadline of the display feed both grids; logged once per start. */
    @Suppress("DEPRECATION")
    private fun applyDisplayTiming(log: Boolean) {
        val d = windowManager.defaultDisplay
        val off = d.appVsyncOffsetNanos
        val deadline = d.presentationDeadlineNanos
        vsync.setDisplayTiming(off, deadline)
        glVsync.setDisplayTiming(off, deadline)
        if (log) {
            MbLog.i(
                "display_timing",
                "app_vsync_offset_ns=$off presentation_deadline_ns=$deadline lead_override_us=${vsync.leadOverrideNs / 1000} effective_deadline_ns=${vsync.grid().deadlineNs} deadline_override=${vsync.deadlineOverrideNs} keep_jitter=${if (vsync.keepJitter) 1 else 0} recenter=${if (vsync.recenter) 1 else 0} " +
                    "inflight=${renderer?.maxInFlight ?: inflightLimit}",
                "render",
            )
        }
    }

    @Suppress("DEPRECATION")
    private fun currentHz(): Float = windowManager.defaultDisplay.refreshRate

    /** While streaming, prefer the supported mode closest to [targetHz] at the current resolution. */
    @Suppress("DEPRECATION")
    private fun applyRefreshRate() {
        val target = FrameRatePolicy.modeTargetHz(targetHz, streamConfig?.fps ?: 0)
        if (target <= 0 || (modeApplied && appliedModeHz == target)) return
        val d = windowManager.defaultDisplay
        val cur = d.mode
        val all = d.supportedModes.map { DisplayModeInfo(it.modeId, it.physicalWidth, it.physicalHeight, it.refreshRate) }
        val pick = DisplayModePicker.pick(
            all, DisplayModeInfo(cur.modeId, cur.physicalWidth, cur.physicalHeight, cur.refreshRate), target.toFloat(),
        )
        MbLog.i(
            "display_mode",
            "requested_hz=$target current_id=${cur.modeId} current_hz=${cur.refreshRate} " +
                "picked_id=${pick?.id ?: -1} picked_hz=${pick?.refreshHz ?: -1f} modes=" +
                all.joinToString(",") { "${it.id}:${it.refreshHz.roundToInt()}" },
            "render",
        )
        if (pick == null) return
        modeApplied = true
        appliedModeHz = target
        window.attributes = window.attributes.also { it.preferredDisplayModeId = pick.id }
        setSurfaceFrameRate(true) // vsync period follows via DisplayListener once the mode settles
    }

    private fun releaseRefreshRate() {
        if (!modeApplied) return
        modeApplied = false
        appliedModeHz = 0
        setSurfaceFrameRate(false)
        window.attributes = window.attributes.also { it.preferredDisplayModeId = 0 }
    }

    private fun setSurfaceFrameRate(on: Boolean) {
        if (Build.VERSION.SDK_INT < 30 || !surfaceValid) return
        // T-046: always an explicit FIXED_SOURCE request at the stream fps (surface and GL paths alike);
        // `frate` overrides it. On API 31+ also CHANGE_FRAME_RATE_ALWAYS so a seamless-only panel still switches.
        val rate = FrameRatePolicy.surfaceRate(frameRateOverride, streamConfig?.fps ?: 0).toFloat()
        val compat = Surface.FRAME_RATE_COMPATIBILITY_FIXED_SOURCE
        if (on && rate <= 0f) return
        try {
            val sf = videoView.holder.surface
            if (Build.VERSION.SDK_INT >= 31) {
                sf.setFrameRate(if (on) rate else 0f, compat, Surface.CHANGE_FRAME_RATE_ALWAYS)
            } else {
                sf.setFrameRate(if (on) rate else 0f, compat)
            }
            if (on) MbLog.i("set_frame_rate", "rate=$rate fixed_source=true strategy_always=${Build.VERSION.SDK_INT >= 31}", "render")
        } catch (e: Exception) {
            MbLog.w("set_frame_rate_failed", "err=${e.javaClass.simpleName}", "render")
        }
    }

    /** Fits the SurfaceView to the stream aspect so the surface equals the video area (letterbox = black bands). */
    private fun layoutVideo() {
        val c = streamConfig
        val vp = if (c == null) VideoViewport(0, 0, 0, 0) else VideoLayout.aspectSize(c).let { (aw, ah) -> VideoViewport(root.width, root.height, aw, ah) }
        val w = if (vp.isEmpty) FrameLayout.LayoutParams.MATCH_PARENT else Math.round(vp.width)
        val h = if (vp.isEmpty) FrameLayout.LayoutParams.MATCH_PARENT else Math.round(vp.height)
        val lp = videoView.layoutParams as FrameLayout.LayoutParams
        if (lp.width != w || lp.height != h) {
            lp.width = w
            lp.height = h
            videoView.layoutParams = lp
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
        r.onSkipWindow(s.skipPct)
        val vg = vsyncGaps.summary(reset = true)
        val lat = s.latencyAvgUs
        controller.trySend(StatsFormat.toMessage(s, interval, lat))
        val gl = if (glMode) presentStats.snapshot(reset = true) else null
        if (statsOn) {
            val base = StatsFormat.overlay(s, interval, lat, StatsFormat.pacingLine(currentHz(), r.bufferFrames, s.paceAddAvgUs, s.skipPct, s.decode.p95Us.takeIf { s.decode.count > 0 }, r.paceDUs())) +
                (if (vg.count > 0) " | vsync " + "%.1f".format(java.util.Locale.ROOT, vg.p50Us / 1000.0) + " ms" else "")
            val withGl = if (gl == null) base else base + "\n" + gl.fields().replace(" gl_", "\ngl_")
            val ep = currentEndpoint
            val tr = if (ep != null) ConnectMode.transportOf(ep) else transport
            statsView.text = getString(if (tr == Transport.USB) R.string.transport_usb else R.string.transport_wifi) + "\n" +
                StreamMode.overlayLine(streamMode, streamConfig) + "\n" + withGl
        }
        if (gl != null) {
            MbLog.i(
                "gl_stats",
                gl.fields() + " gl_vsync_period_us=${glVsync.periodNs / 1000} hz=${"%.0f".format(java.util.Locale.ROOT, currentHz())}",
                "render",
            )
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
                "hz=${"%.0f".format(java.util.Locale.ROOT, currentHz())} vsync_period_us=${vsync.periodNs / 1000} " +
                "display_hz=${"%.1f".format(java.util.Locale.ROOT, currentHz())} vsync_ms_p50=${if (vg.count > 0) "%.2f".format(java.util.Locale.ROOT, vg.p50Us / 1000.0) else "-"} " +
                "buffer=${r.bufferFrames} skip_pct=${s.skipPct?.let { "%.1f".format(java.util.Locale.ROOT, it) } ?: "-"} " +
                "cb_skip_pct=${s.cbSkipPct?.let { "%.1f".format(java.util.Locale.ROOT, it) } ?: "-"} " +
                "pace_ms=${s.paceAddAvgUs?.let { "%.2f".format(java.util.Locale.ROOT, it / 1000.0) } ?: "-"} " +
                "vsync_ms=${"%.2f".format(java.util.Locale.ROOT, vsync.periodNs / 1e6)} pace_add_ms=${s.paceAddAvgUs?.let { "%.2f".format(java.util.Locale.ROOT, it / 1000.0) } ?: "-"} " +
                StatsFormat.gapFields("net", s.network) + " " + StatsFormat.gapFields("ready", s.ready) + " " +
                StatsFormat.gapFields("shown", s.shown) + " " + StatsFormat.gapFields("dec", s.decode) +
                " pace_d_us=${r.paceDUs()}",
            "render",
        )
    }

    override fun onStart() {
        super.onStart()
        started = true
        dev.matebridge.client.session.MbLog.i("activity_start")
        currentEndpoint = null
        manualMode = false
        transport = settings.transport()
        hostReached = false
        hideManualEntry() // T-078: every (re)start begins without an editable field on screen
        render(SessionUi.Searching)
        ui.removeCallbacks(ticker)
        ui.postDelayed(ticker, KEYFRAME_RETRY_MS)
        ui.removeCallbacks(inputTicker)
        ui.post(inputTicker)
        (getSystemService(Context.INPUT_SERVICE) as InputManager).registerInputDeviceListener(inputDeviceListener, ui)
        applyTransport()
    }

    /** USB: connect straight to loopback and skip NSD; Wi-Fi: NSD discovery (auto-connect) as before. */
    private fun applyTransport() {
        discovery?.stop()
        discovery = null
        ui.removeCallbacks(usbHintCheck)
        if (ConnectMode.autoDiscover(transport)) {
            manualMode = false
            discovery = MacDiscovery(this) { ep -> runOnUiThread { onDiscovered(ep) } }.also { it.start() }
        } else {
            manualMode = true
            usbStartMs = SystemClock.elapsedRealtime()
            hostReached = false
            ui.postDelayed(usbHintCheck, ConnectMode.USB_TIMEOUT_MS)
            connect(ConnectMode.usbEndpoint)
        }
    }

    private fun selectTransport(t: Transport) {
        transport = t
        settings.setTransport(t)
        currentEndpoint = null
        controller.stop()
        render(SessionUi.Searching)
        applyTransport()
    }

    override fun onStop() {
        started = false
        unbufferedPen.sync(false) // the ticker is stopped below; do not leave the request behind
        dev.matebridge.client.session.MbLog.i("activity_stop")
        ui.removeCallbacks(ticker)
        ui.removeCallbacks(inputTicker)
        (getSystemService(Context.INPUT_SERVICE) as InputManager).unregisterInputDeviceListener(inputDeviceListener)
        discovery?.stop()
        discovery = null
        ui.removeCallbacks(usbHintCheck)
        renderer?.flushPaceTrace()
        releaseRenderer() // video stops in the background; a fresh session re-requests a keyframe on return
        controller.stop() // sends BYE, closes both connections
        super.onStop()
    }

    override fun onDestroy() {
        ui.removeCallbacksAndMessages(null)
        releaseRenderer()
        presenter?.stop()
        presenter = null
        controller.shutdown()
        perfHint?.close()
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
        hideManualEntry() // T-078: no focused field once the stream may start
        connect(ep)
    }

    private fun connect(ep: Endpoint) {
        currentEndpoint = ep
        MbLog.i("transport", "transport=${ConnectMode.transportOf(ep).logName}")
        controller.start(ep)
    }

    private fun render(state: SessionUi) {
        if (::clipboard.isInitialized) {
            val was = clipboard.sync.accepted
            clipboard.sync.onSessionAccepted(state is SessionUi.Connected, System.currentTimeMillis(), MbLog.gen)
            if (!was && clipboard.sync.accepted) clipboard.recheck() // T-063: copied while the session was down
        }
        if (!started || isDestroyed) return
        lastUi = state
        if (state is SessionUi.AwaitingApproval || state is SessionUi.Connected || state is SessionUi.Failed) hostReached = true // terminal errors must not be replaced by the USB hint
        if (state !is SessionUi.Connected) releaseRenderer()
        val streaming = state is SessionUi.Connected && state.framesReceived > 0 && renderer != null
        if (streaming && panel.visibility != View.GONE) hideManualEntry() // T-078: before the panel goes away
        panel.visibility = if (streaming) View.GONE else View.VISIBLE
        status.text = when (state) {
            SessionUi.Idle -> getString(R.string.state_idle)
            SessionUi.Searching -> getString(R.string.state_searching)
            is SessionUi.Connecting -> getString(R.string.state_connecting, state.endpoint.toString())
            is SessionUi.AwaitingApproval ->
                if (state.code != null) pairingText(state) else getString(R.string.state_awaiting_approval, state.hostName)
            is SessionUi.Connected -> getString(R.string.state_connected, state.hostName, state.framesReceived)
            is SessionUi.Disconnected -> getString(
                R.string.state_disconnected, causeText(state.cause), (state.retryInMs + 999) / 1000,
            )
            is SessionUi.Failed ->
                if (state.cause == SessionUi.Cause.KEY_MISSING) KEY_MISSING_TEXT
                else if (state.cause == SessionUi.Cause.KEY_STORE_FAILED) KEY_STORE_FAILED_TEXT
                else getString(R.string.state_failed, causeText(state.cause))
        }
        if (ConnectMode.showUsbHint(transport, SystemClock.elapsedRealtime() - usbStartMs, hostReached)) {
            status.text = getString(R.string.usb_missing)
        }
        syncInputActive() // panel visibility decides whether input is captured
    }

    /**
     * Pairing screen (PROTOCOL.md section 9): the 6-digit code large, to compare with the Mac's. The strings are
     * literals because the strings resource is outside this task's file list. The code is never logged.
     */
    private fun pairingText(state: SessionUi.AwaitingApproval): CharSequence {
        val b = SpannableStringBuilder()
        if (state.rePairing) {
            val warn = "Mac bu tableti tanımıyor, yeniden eşleşiliyor\n\n"
            b.append(warn)
            b.setSpan(ForegroundColorSpan(Color.parseColor("#FFB300")), 0, warn.length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
        }
        b.append("Mac'teki kodla aynı mı?\n")
        val code = state.code.orEmpty()
        val shown = if (code.length == 6) code.substring(0, 3) + " " + code.substring(3) else code
        val start = b.length
        b.append(shown)
        b.setSpan(RelativeSizeSpan(3.5f), start, b.length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
        b.setSpan(StyleSpan(Typeface.BOLD), start, b.length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
        b.append("\nMac'te \"İzin ver\" dediğinde bağlanır.")
        b.append("\n\nMac'i göremiyorsan: Parsec'te kodu karşılaştırıp İzin ver de, sonra buraya dön.")
        return b
    }

    private companion object {
        const val KEY_STORE_FAILED_TEXT = "Eşleşme anahtarı kaydedilemedi — Mac'te 'Onaylı cihazları unut' deyip yeniden bağlan."
        const val KEY_MISSING_TEXT = "Mac bu tableti tanımıyor. Mac'te 'Onaylı cihazları unut' deyip yeniden bağlan."
        const val KEYFRAME_RETRY_MS = 500L
        const val RATE_POLL_MS = 100L
        const val INPUT_TICK_MS = 25L
        const val POINTER_CAPTURE_RETRY_MS = 500L
        const val INPUT_FAULT_BACKOFF_MS = 1000L
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
            SessionUi.Cause.KEY_MISSING, SessionUi.Cause.KEY_STORE_FAILED -> R.string.cause_protocol_error // literal texts in render()
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
            protocolVersion = Limits.PROTOCOL_VERSION,
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
