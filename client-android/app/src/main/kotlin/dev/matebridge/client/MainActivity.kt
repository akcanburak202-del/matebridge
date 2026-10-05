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
import dev.matebridge.client.audio.AudioOutPref
import dev.matebridge.client.audio.AudioPlayout
import dev.matebridge.client.audio.AvSync
import dev.matebridge.client.protocol.Capabilities
import dev.matebridge.client.protocol.FilesInfo
import dev.matebridge.client.files.FilesController
import dev.matebridge.client.files.FilesSessionGate
import dev.matebridge.client.files.FilesRoot
import dev.matebridge.client.idle.IdleDimPolicy
import dev.matebridge.client.idle.IdleSource
import dev.matebridge.client.idle.IdleTimeout
import dev.matebridge.client.idle.IdleTimeoutStore
import dev.matebridge.client.idle.IdleWindow
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
import dev.matebridge.client.stream.GameJitter
import dev.matebridge.client.stream.GameModeSettings
import dev.matebridge.client.stream.GameResolution
import dev.matebridge.client.stream.HdrCapability
import dev.matebridge.client.stream.HdrPolicy
import dev.matebridge.client.stream.HdrRequestLog
import dev.matebridge.client.stream.HzPin
import dev.matebridge.client.stream.HzPinHint
import dev.matebridge.client.stream.HzPinResult
import dev.matebridge.client.stream.HzSwitchCounter
import dev.matebridge.client.stream.SharpChromaPolicy
import dev.matebridge.client.stream.SharpChromaStore
import dev.matebridge.client.protocol.StreamPrefs
import dev.matebridge.client.video.IntervalHistogram
import dev.matebridge.client.stream.StatsFormat
import dev.matebridge.client.stream.StatsLogWindow
import dev.matebridge.client.stream.RefreshMismatch
import dev.matebridge.client.stream.StreamMode
import dev.matebridge.client.overlay.PenOverlayView
import dev.matebridge.client.stream.VideoLayout
import dev.matebridge.client.stream.VideoViewport
import dev.matebridge.client.video.VideoRenderer
import dev.matebridge.client.stream.DisplayRateDebouncer
import dev.matebridge.client.video.VsyncClock
import dev.matebridge.client.video.VsyncIdleGate
import dev.matebridge.client.session.ConnectMode
import dev.matebridge.client.session.Endpoint
import dev.matebridge.client.session.EndpointRediscovery
import dev.matebridge.client.session.Transport
import dev.matebridge.client.session.TransportMode
import dev.matebridge.client.session.AutoUsbPolicy
import dev.matebridge.client.session.CableTracker
import dev.matebridge.client.session.ProbeResult
import dev.matebridge.client.session.UsbProbe
import dev.matebridge.client.session.KeyValueStore
import dev.matebridge.client.session.MacDiscovery
import dev.matebridge.client.session.HomeNetwork
import dev.matebridge.client.session.HostSleepGate
import dev.matebridge.client.session.WolRefresh
import dev.matebridge.client.session.WakeConnect
import dev.matebridge.client.session.WakePlanner
import dev.matebridge.client.session.WakeTag
import dev.matebridge.client.session.WolSender
import dev.matebridge.client.session.WolStore
import dev.matebridge.client.clipboard.ClipboardBridge
import dev.matebridge.client.clipboard.ClipboardSync
import dev.matebridge.client.protocol.Clipboard
import dev.matebridge.client.session.SessionController
import dev.matebridge.client.session.SessionListener
import dev.matebridge.client.session.SessionUi
import dev.matebridge.client.session.Settings
import dev.matebridge.client.session.SpeedRange
import dev.matebridge.client.session.truncateUtf8
import dev.matebridge.client.session.TransportSwitch
import dev.matebridge.client.session.ConnectOrigin
import dev.matebridge.client.session.ForgetFlow
import dev.matebridge.client.session.PairPick
import dev.matebridge.client.session.PromptVisibility
import dev.matebridge.client.session.TrustButton
import dev.matebridge.client.session.TrustLine
import dev.matebridge.client.session.TrustText
import dev.matebridge.client.session.TrustUiText
import dev.matebridge.client.session.TrustView
import dev.matebridge.client.settings.SettingsCatalog
import dev.matebridge.client.settings.SettingsHost
import dev.matebridge.client.settings.TwoTapConfirm
import dev.matebridge.client.settings.SettingsPanelState
import dev.matebridge.client.settings.SettingsSidePanel
import dev.matebridge.client.settings.SettingsViews
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

/**
 * Session UI plus full-screen video (T-012 + T-013 + T-015). Session logic lives in
 * dev.matebridge.client.session, decoding in dev.matebridge.client.video; this class wires them to views.
 * While connected and streaming the connection panel is hidden and the SurfaceView (fitted to the
 * stream aspect, so the surface is exactly the video area) fills the screen. While the video is shown, pen and
 * finger events are routed to [InputCapture] (T-024) instead of the views. The settings side panel (T-105) can open over
 * the running video; while it is open no input is routed to the Mac.
 */
class MainActivity : Activity(), SurfaceHolder.Callback {
    private lateinit var status: TextView
    private lateinit var endpointField: EditText
    private lateinit var settings: Settings
    private lateinit var controller: SessionController
    private var streamMode = StreamMode.DEFAULT
    /**
     * T-109 (decision 0014): bit rate, audio output and pen trail/dot are read and changed only through this, so game
     * mode's temporary defaults sit over [settings] without ever being stored.
     */
    private lateinit var gameSettings: GameModeSettings
    /** T-238 (decision 0032): one `ev=hdr_request` line per change of the requested dynamic range. */
    private val hdrRequestLog = HdrRequestLog()
    /** A valid `--es audio_out` launch override is in effect: game mode leaves the audio output alone until the panel changes it. */
    private var audioOutFromExtra = false
    private lateinit var clipboard: ClipboardBridge // T-055
    /** T-135: the tablet-files WebDAV server (decision 0015); runs only while started, switched on and permitted. */
    private lateinit var files: FilesController
    /** T-153: the server also needs a trusted USB session (authenticated STREAM_CONFIG on the current connection). */
    private val filesGate = FilesSessionGate()

    // T-105: settings controls, built once from SettingsCatalog over [settingsHost] into both panels.
    private val settingsPanel = SettingsPanelState { ev, fields -> MbLog.i(ev, fields) }
    private lateinit var sidePanel: SettingsSidePanel
    /** SETTINGS_OPEN from the session thread: coalesced, so a flood of them queues one UI runnable, not one each. */
    private val settingsOpenPost = dev.matebridge.client.settings.CoalescedPost({ ui.post(it) }) {
        openSettingsPanel(SettingsPanelState.Via.HOST)
    }
    private var connectSettings: SettingsViews? = null
    private var sideSettings: SettingsViews? = null
    /** "Bağlantıyı kes" was used: no automatic (re)connect until "Bağlan", a transport choice or the next onStart. */
    private var userDisconnected = false
    /** T-095: `--ez audio false` turns audio off entirely (no AUDIO_PCM capability, no AUDIO_PREFS, no playback). */
    private var audioAllowed = true
    private var audio: AudioPlayout? = null
    private var discovery: MacDiscovery? = null
    // T-129 Wake-on-LAN: stored host addresses, the episode policy and the UDP sender.
    private lateinit var wolStore: WolStore
    private lateinit var wolSender: WolSender
    private lateinit var wakeButton: Button
    private val wolPlanner = WakePlanner()
    /** T-133: BYE(HOST_SLEEP) received; nothing automatic goes to the Mac until a user action or the next onStart. */
    private val hostSleep = HostSleepGate()
    /** T-133: one TXT-only discovery per start while on USB, so `wol` is learned without Wi-Fi discovery. */
    private val wolRefresh = WolRefresh()
    private var wolRefreshDiscovery: MacDiscovery? = null
    /** T-134: direct wake attempts (an ordinary session to the stored host IPv4:port) during a wake episode. */
    private val wakeConnect = WakeConnect()
    /** T-227: restarts discovery when the session's address keeps failing and checks the host at a new address. */
    private val rediscovery = EndpointRediscovery()
    private lateinit var root: FrameLayout
    private lateinit var video: SurfaceView // MediaCodec -> SurfaceView, the only presentation path (T-184)
    private lateinit var panel: View
    private lateinit var penOverlay: PenOverlayView // T-056
    private lateinit var statsView: TextView
    private val ui = Handler(Looper.getMainLooper())
    private val clock = ClockSync()
    private lateinit var capture: InputCapture
    private lateinit var unbufferedPen: UnbufferedPenDispatch
    private val rootLoc = IntArray(2)
    private var inputFaultUntilMs = 0L

    // T-234 (decision 0031): idle dim, then FLAG_KEEP_SCREEN_ON dropped; the first input while dimmed only wakes.
    private lateinit var idleStore: IdleTimeoutStore
    private lateinit var idle: IdleDimPolicy
    private val idleWindow = object : IdleWindow {
        override fun setDimmed(dimmed: Boolean) {
            val lp = window.attributes
            val b = if (dimmed) IDLE_DIM_BRIGHTNESS else WindowManager.LayoutParams.BRIGHTNESS_OVERRIDE_NONE
            if (lp.screenBrightness == b) return
            lp.screenBrightness = b // the window only: the system and auto brightness are never touched
            window.attributes = lp
        }

        override fun setKeepScreenOn(on: Boolean) {
            if (on) window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
            else window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        }
    }

    // Video state. renderer is read from the video reader thread; the rest is main-thread only.
    @Volatile private var renderer: VideoRenderer? = null
    private var paceTrace: dev.matebridge.client.video.PaceTrace? = null // T-069 experiment (--ez pace_trace true), default off
    /** T-159 (decision 0019): input capture is live only while the video is HEALTHY. UI thread only. */
    private val videoHealth = dev.matebridge.client.video.VideoHealth(
        SystemClock::elapsedRealtime,
        log = { level, ev, fields -> if (level == 'W') MbLog.w(ev, fields, "decoder") else MbLog.i(ev, fields, "decoder") },
        onChange = { onVideoHealthChanged() },
    )
    private var videoFaultOverlay: View? = null
    private var videoFaultText: TextView? = null
    /**
     * T-159 debug `--es decoder_fault create|configure|dequeue|silent` (debuggable builds); one per launch.
     * T-185: like every debug-only extra it also needs `--ez dev true` ([devKnobs], parsed in onCreate before first use).
     */
    private val decoderFault: dev.matebridge.client.video.DecoderFault? by lazy {
        val mode = dev.matebridge.client.video.DecoderFault.parseMode(devKnobs.decoderFault)
        if (mode == null || applicationInfo.flags and android.content.pm.ApplicationInfo.FLAG_DEBUGGABLE == 0) null
        else dev.matebridge.client.video.DecoderFault(
            mode,
            (devKnobs.decoderFaultAfterS ?: dev.matebridge.client.video.DecoderFault.DEFAULT_AFTER_S).coerceAtLeast(0),
            dev.matebridge.client.video.MediaCodecDecoder.FACTORY,
        ) { fields -> MbLog.w("decoder_fault", fields, "decoder") }
    }
    private var streamConfig: StreamConfig? = null

    // ---- T-259 (decision 0034): packed full colour (chroma_layout 1) ----
    private lateinit var fullChromaCap: dev.matebridge.client.video.FullChromaCapability
    /** The presenter failed in this process: no `chroma = 2`, no HELLO bit11 until the app restarts (any thread). */
    @Volatile private var fullChromaRuntimeOff = false
    /** The applied STREAM_CONFIG has `chroma_layout = 1` (any thread: keyframe requests carry `view` only then). */
    @Volatile private var packedVideo = false
    private var chromaPipeline: dev.matebridge.client.video.FullChromaPipeline? = null

    /** Capability self-test passed and the packed path has not failed in this process. */
    private fun fullChromaOn(): Boolean = ::fullChromaCap.isInitialized && fullChromaCap.available() && !fullChromaRuntimeOff

    /** `KEYFRAME_REQUEST` of the main stream: `view` is written only while `chroma_layout = 1` (PROTOCOL.md 0x23). */
    private fun mainKeyframeRequest(reason: Int) = KeyframeRequest(
        reason, if (packedVideo) KeyframeRequest.VIEW_MAIN else KeyframeRequest.VIEW_UNSPECIFIED,
    )
    private var surfaceValid = false
    private var statsOn = false
    private var lastStatsMs = 0L
    /** T-141: log window of the video stats lines (10 s; `--ez stats_1s true` = 1 s). The STATS message stays per second. */
    private var statsLog = StatsLogWindow()
    /** Overlay text last set; an unchanged text is not set again (no relayout/redraw once a second while idle). */
    private var lastOverlayText: String? = null

    // T-016/T-052 smoothness knobs. Launch extras: `--ei jitter N` (unset = adaptive pacing on the surface path;
    // 0|1|2 = fixed jitter buffer in content frames, 0 = render at once as in T-015; -1 = adaptive off = 0) and `--ei hz 120` (preferred refresh rate while streaming, 0 = leave alone).
    private var bufferFrames = VideoRenderer.BUFFER_ADAPTIVE
    /** The launch-time buffer (above) and where a fixed one came from; game mode uses 0 unless fixed (T-109). */
    private var launchBufferFrames = VideoRenderer.BUFFER_ADAPTIVE
    private var bufferFixedBy: GameJitter.Source? = null
    private var targetHz = FrameRatePolicy.HZ_FOLLOW_STREAM // T-046: follow the stream fps unless `hz` is given
    private var appliedModeHz = 0
    /** T-243: the `hz_pin` hints currently applied (empty = none; always empty without `--es hz_pin`). */
    private var hzPinApplied: List<HzPinHint> = emptyList()
    /** T-243: `display_rate` switches in the stats log window (`MB/render ev=stats hz_switches=`). */
    private val hzSwitches = HzSwitchCounter()
    private val vsyncGaps = IntervalHistogram()
    private val vsyncGapsLog = IntervalHistogram() // T-141: the log window's vsync gaps (fed per second from vsyncGaps)
    private val refreshMismatch = RefreshMismatch() // T-169: target vs measured refresh, fed per second
    private val vsync = VsyncClock()
    /** T-141: the vsync loop sleeps while no video frame arrives; a frame or pointer input wakes it. */
    private val vsyncIdle = VsyncIdleGate()
    private val vsyncWake = Runnable { wakeVsync() }

    private var choreographerOn = false
    private var modeApplied = false
    private val vsyncCallback = object : Choreographer.FrameCallback {
        override fun doFrame(frameTimeNanos: Long) {
            vsync.onVsync(frameTimeNanos)
            vsyncGaps.mark(frameTimeNanos / 1000)
            if (!choreographerOn) return
            if (vsyncIdle.onVsync(System.nanoTime())) Choreographer.getInstance().postFrameCallback(this) else sleepVsync()
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
    private var benchForwarded = false // T-090: this instance only forwarded to NetBenchActivity
    private var usbStartMs = 0L

    // T-096 connection mode: AUTO (USB when reachable, else Wi-Fi, moving a Wi-Fi session to USB when it appears), or
    // one transport only. `--es transport auto|usb|wifi` overrides the stored setting for this activity instance.
    private var mode = TransportMode.AUTO
    private var modeOverride: TransportMode? = null
    private val cable = CableTracker()
    private val autoPolicy = AutoUsbPolicy()
    private var cableRegistered = false
    private var lastWifiEndpoint: Endpoint? = null // in memory: the USB -> Wi-Fi fallback goes straight back to it
    private var probeExec: java.util.concurrent.ExecutorService? = null
    /** Bumped to invalidate a running USB probe; a bump also closes a probe socket that is connecting (T-133). */
    private val probeGuard = dev.matebridge.client.session.ProbeGuard()
    private var picking = false
    private var transportEpoch = 0 // bumped whenever the transport is re-applied; stale migration results are ignored
    private var migrateEpoch = -1
    private var fallbackPending = false

    /** Control generation the input layer last reset its model for (T-096); input goes only onto that connection. */
    private var inputGen = -1
    private var hostReached = false
    private val usbHintCheck = Runnable { render(lastUi) }

    // T-151 (decision 0018) trust UI: the pick gate, prompt visibility for T-150's timeout, "Bu Mac'i unut".
    private val pairPick = PairPick()
    private val promptVisibility = PromptVisibility()
    private val forgetFlow = ForgetFlow({ controller.forgetCurrentHost() })
    /** "Bu Mac'i unut" succeeded: the idle panel says the Mac must forget this tablet too. Cleared by the next connect. */
    private var forgetNotice = false
    /** "Bu Mac'i unut" did not persist (`Failed(KEY_STORE_FAILED)` after it): say so instead of the pairing text. */
    private var forgetFailed = false
    /** An already idle machine reports a successful forget with no state: decide after [ForgetFlow.SETTLE_MS]. */
    private val forgetSettle = Runnable { forgetFlow.onTick(SystemClock.elapsedRealtime())?.let { onForgetResult(it) } }
    private lateinit var trustRow: LinearLayout
    private lateinit var connectButton: Button
    private var trustButtons: List<TrustButton> = emptyList()
    private var lastUi: SessionUi = SessionUi.Searching

    // T-089 Wi-Fi knobs (launch extras), RTT window for the per-second `ev=net` line, low-latency Wi-Fi lock.
    private var knobs = dev.matebridge.client.session.WifiKnobs()
    private val rttStats = dev.matebridge.client.session.RttStats()
    private var wifiLock: dev.matebridge.client.session.WifiLockHolder? = null

    /** T-185 (decision 0026): launch extras behind the developer gate; parsed once in onCreate, read nowhere else. */
    private var devKnobs = dev.matebridge.client.session.DevKnobs()

    private fun parseDevKnobs() {
        val i = intent
        devKnobs = dev.matebridge.client.session.DevKnobs.parse(
            if (i == null) dev.matebridge.client.session.LaunchExtras.NONE
            else object : dev.matebridge.client.session.LaunchExtras {
                override fun has(key: String) = i.hasExtra(key)
                override fun int(key: String, default: Int) = i.getIntExtra(key, default)
                override fun bool(key: String, default: Boolean) = i.getBooleanExtra(key, default)
                override fun string(key: String): String? = i.getStringExtra(key)
            },
        )
        MbLog.i("dev_knobs", devKnobs.logFields(), "diag") // keys only, never values
    }

    private fun parseWifiKnobs() {
        knobs = devKnobs.wifi
        MbLog.i("wifi_knobs", knobs.logFields())
        if (knobs.wifiLowLatency) {
            val lock = try {
                val wm = applicationContext.getSystemService(Context.WIFI_SERVICE) as android.net.wifi.WifiManager
                wm.createWifiLock(android.net.wifi.WifiManager.WIFI_MODE_FULL_LOW_LATENCY, "MateBridge:low_latency")
                    .also { it.setReferenceCounted(false) }
            } catch (e: RuntimeException) { // includes a null/foreign service (ClassCast / NullPointer)
                MbLog.w("wifi_lock", "held=0 reason=create err=${e.javaClass.simpleName} mode=low_latency")
                return
            }
            wifiLock = dev.matebridge.client.session.WifiLockHolder(
                object : dev.matebridge.client.session.WifiLockHolder.Backend {
                    override fun acquire() = lock.acquire()
                    override fun release() { if (lock.isHeld) lock.release() }
                },
            ) { fields -> MbLog.i("wifi_lock", "$fields mode=low_latency") }
        }
    }

    /** Holds the low-latency Wi-Fi lock only while a Wi-Fi session is connected and the activity is started (T-089). */
    private fun syncWifiLock(reason: String) {
        val h = wifiLock ?: return
        val tr = currentEndpoint?.let { ConnectMode.transportOf(it) } ?: Transport.WIFI // no endpoint: not connected
        h.sync(dev.matebridge.client.session.WifiLockPolicy.shouldHold(knobs.wifiLowLatency, tr, started && !isDestroyed, lastUi), reason)
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // T-146: names the build once per process in every client log (no serial, no device id).
        if (BuildInfo.claimAppStart()) MbLog.i("app_start", BuildInfo.current.logFields(Build.VERSION.SDK_INT, Build.DISPLAY))
        // T-185: debug-only extras count only with `--ez dev true` on the same launch; ignored keys are logged.
        parseDevKnobs()
        // T-090: `--es net_bench HOST:PORT` runs only the raw TCP throughput bench; no session is set up here. The bench
        // lives in the debug source set (T-185), so it is started by class name.
        if (devKnobs.netBench) {
            try {
                startActivity(android.content.Intent().setClassName(packageName, NET_BENCH_ACTIVITY).putExtras(intent))
                benchForwarded = true
                finish()
                return
            } catch (e: android.content.ActivityNotFoundException) {
                MbLog.w("net_bench", "err=not_in_build", "diag") // a build without the debug source set
            }
        }
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        // T-141: `--ez stats_1s true` brings back the per-second video stats log lines (diagnostics).
        statsLog = StatsLogWindow(if (devKnobs.stats1s) StatsLogWindow.FAST_MS else StatsLogWindow.DEFAULT_MS)
        MbLog.i("stats_log", "window_ms=${statsLog.windowMs}", "render")
        bufferFrames = devKnobs.jitter ?: VideoRenderer.BUFFER_ADAPTIVE
        launchBufferFrames = bufferFrames
        bufferFixedBy = if (devKnobs.jitter != null) GameJitter.Source.EXTRA else null
        devKnobs.leadUs?.let { vsync.leadOverrideNs = it * 1000L }
        // T-071: absent = 6 ms default; -1 = the display's reported deadline; N >= 0 = N us.
        devKnobs.deadlineUs?.let { us ->
            vsync.deadlineOverrideNs = if (us >= 0) us * 1000L else VsyncClock.DEADLINE_DISPLAY
        }
        paceTrace = if (devKnobs.paceTrace) dev.matebridge.client.video.PaceTrace() else null
        targetHz = devKnobs.hz ?: FrameRatePolicy.HZ_FOLLOW_STREAM
        parseWifiKnobs()
        audioAllowed = devKnobs.audio
        MbLog.i("audio_knob", "enabled=${if (audioAllowed) 1 else 0}", "audio")
        devKnobs.transport?.let { raw -> // T-096: one launch only, the stored setting is not changed
            modeOverride = TransportMode.parse(raw)
            MbLog.i("transport_knob", "override=${modeOverride?.id ?: "invalid"}")
        }
        // T-096: one probe thread and at most one waiting probe; a newer one replaces a waiting older one (each result is
        // checked against probeGuard anyway, so a dropped probe loses nothing).
        probeExec = java.util.concurrent.ThreadPoolExecutor(
            1, 1, 0L, java.util.concurrent.TimeUnit.MILLISECONDS, java.util.concurrent.ArrayBlockingQueue(1),
            { r -> Thread(r, "mb-usb-probe").also { it.isDaemon = true } },
            java.util.concurrent.ThreadPoolExecutor.DiscardOldestPolicy(),
        )
        setContentView(R.layout.activity_main)
        status = findViewById(R.id.status)
        root = findViewById(R.id.root)
        video = findViewById(R.id.video)
        panel = findViewById(R.id.panel)
        statsView = findViewById(R.id.stats)
        video.holder.addCallback(this)
        video.addOnLayoutChangeListener { _, _, _, _, _, _, _, _, _ -> updateViewport() }
        video.setOnLongClickListener { toggleStats(); true }
        root.addOnLayoutChangeListener { _, _, _, _, _, _, _, _, _ -> layoutVideo() }
        endpointField = findViewById(R.id.endpoint)
        val prefs = getSharedPreferences("matebridge", Context.MODE_PRIVATE)
        val prefsStore = object : KeyValueStore {
            override fun getString(key: String) = prefs.getString(key, null)
            override fun putString(key: String, value: String) { prefs.edit().putString(key, value).apply() }
            override fun remove(key: String) { prefs.edit().remove(key).apply() } // T-191
        }
        settings = Settings(prefsStore)
        fullChromaCap = dev.matebridge.client.video.FullChromaCapability(
            prefsStore, "${BuildInfo.current.sha}@${BuildInfo.current.builtUtc}",
        ) // T-259: the self-test result is per build
        wolStore = WolStore(prefsStore) // T-129
        wolSender = WolSender(this)
        settings.migrateTransportToAutoOnce()?.let { old -> MbLog.i("transport_pref_migrated", "from=${TransportMode.parse(old)?.id ?: "other"} to=auto") } // T-096
        statsOn = settings.statsOverlay()
        applyStatsVisibility()
        settings.lastEndpoint()?.let { endpointField.setText(it.toString()) }
        setupManualEntry()
        connectButton = findViewById(R.id.connect)
        connectButton.setOnClickListener { onConnectClicked() }
        // T-151: the trust buttons sit right under the status text (built here: the layout is outside this task).
        trustRow = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL; visibility = View.GONE }
        findViewById<LinearLayout>(R.id.panel_content).let { it.addView(trustRow, it.indexOfChild(status) + 1) }
        wakeButton = findViewById(R.id.wake)
        wakeButton.setOnClickListener { onWakeClicked() }
        refreshWakeButton()

        val pairKeys = EncryptedPairKeyStore(
            object : dev.matebridge.client.session.AtomicKeyValueStore {
                val secure = getSharedPreferences("matebridge_pairkeys", Context.MODE_PRIVATE)
                override fun getString(key: String) = secure.getString(key, null)
                override fun putString(key: String, value: String) {
                    // A pairing key that did not persist must not count as paired.
                    if (!secure.edit().putString(key, value).commit()) throw java.io.IOException("prefs commit failed")
                }
                override fun keys(): Set<String> = secure.all.keys.toSet()
                override fun commit(changes: Map<String, String?>) {
                    // T-150: one Editor, one commit: a promotion never leaves a half-written trusted/pending pair.
                    val e = secure.edit()
                    for ((k, v) in changes) if (v == null) e.remove(k) else e.putString(k, v)
                    if (!e.commit()) throw java.io.IOException("prefs commit failed")
                }
            },
            AndroidKeystoreWrapper(),
        )
        // T-223 (decision 0030 §5): the five pre-update mode ids become mode + frame rate once, before any read.
        settings.migrateModesOnce()?.let { MbLog.i("modes_migrated", "mode=${it.mode.id} fps=${it.fps}") }
        streamMode = settings.streamMode()
        // T-238 (decision 0032): HDR10 capability once (display + the HEVC decoder the renderer gets).
        val hdrCaps = detectHdrCapability()
        MbLog.i("hdr_caps", hdrCaps.logFields())
        // T-215: `--ei game_display 0` = native display.
        // T-241 (decision 0033): "Keskin renk kenarları" has its own key in the same store.
        gameSettings = GameModeSettings(
            settings, devKnobs.gameDisplay, hdrCaps, SharpChromaStore(prefsStore),
            colourStore = dev.matebridge.client.stream.ColourStore(prefsStore), // T-259: T-260's panel writes it
            fullChromaAvailable = { fullChromaOn() },
        )
        audioOutFromExtra = devKnobs.audioOut?.let { AudioOutPref.parse(it) } != null
        // T-109/T-223: stored mode Oyun or Çizim starts with its defaults (layer built before anything reads them).
        gameSettings.onModeChanged(streamMode)?.let { change ->
            applyJitter()
            MbLog.i("mode_layer", GameModeSettings.logFields(change, currentJitter(), gameSettings.effective()) + " at=start")
        }
        if (audioAllowed) {
            audio = AudioPlayout(this, { clock.offsetUs() }, gameSettings.audioOut, devKnobs.audioOut, devKnobs.audioBufBursts) {
                runOnUiThread { onAudioBecomingNoisy() }
            }
        }
        val quickAck = devKnobs.quickAck
        val stallDiag = devKnobs.stallDiag
        MbLog.i("stall_diag", "enabled=${if (stallDiag) 1 else 0}", "diag") // T-142
        controller = SessionController(buildHello(), pairKeys, object : SessionListener {
            override fun onUi(state: SessionUi) { runOnUiThread { render(state) } }
            override fun onStreamConfig(config: StreamConfig) { runOnUiThread { installConfig(config) } }

            override fun onVideoFrame(frame: VideoFrame) {
                // Decision 0034: the auxiliary view goes to its own decoder; without the packed pipeline it is dropped (an
                // unknown or unexpected `view` is skipped, never a protocol error).
                if (frame.view != VideoFrame.VIEW_MAIN) {
                    if (frame.view == VideoFrame.VIEW_AUX) chromaPipeline?.onAuxFrame(frame)
                    return
                }
                // Never feed the queue while no surface is attached (T-013 handoff).
                val r = renderer ?: return
                if (!r.attached) return
                // T-141: a frame wakes a sleeping vsync loop (one post per sleep; a volatile write otherwise).
                if (vsyncIdle.onActivity(System.nanoTime())) ui.post(vsyncWake)
                r.onFrame(frame)
            }

            // T-218: a known video loss closes input at once (FAULT -> RELEASE_ALL(USER)); the control session goes on.
            // During a migration proof only the overlay waits (a promotion reconfigures at once); input closes all the same.
            override fun onVideoLost(gen: Int, duringMigration: Boolean) {
                runOnUiThread { videoHealth.videoLost(gen, quietOverlay = duringMigration) }
            }

            // T-218: fresh video after a loss: a new decoder generation, input re-opens at its first decoded output.
            // Posted inside the delivery barrier (a non-blocking post); VideoHealth drops a stale `gen`.
            override fun onVideoFlowing(gen: Int) {
                runOnUiThread { videoHealth.videoFlowing(gen)?.let { runVideoRecovery(it) } }
            }

            override fun onSessionStart() {
                clock.reset()
                rttStats.reset()
            }

            override fun onPong(echoTimeUs: Long, responderTimeUs: Long, nowUs: Long) {
                clock.onPong(echoTimeUs, responderTimeUs, nowUs)
                rttStats.add(nowUs - echoTimeUs) // T-089
            }

            override fun onClipboard(msg: Clipboard, gen: Int) { if (::clipboard.isInitialized) clipboard.postRemote(msg, gen) }

            // T-095: audio is armed per control connection; stale readers' messages are dropped by generation.
            override fun onConnectionGen(gen: Int, transport: Transport) {
                audio?.beginSession(gen, transport) // T-123: safety per transport
                // The host holds no input state for a new connection (a takeover released the old one). Model reset and
                // the new send target change together, so nothing from the old model can reach the new connection.
                runOnUiThread {
                    inputGen = gen
                    capture.onSessionReset()
                    // T-096: a migration stays Connected; re-arm the clipboard for the new generation (render() accepts it).
                    if (::clipboard.isInitialized) clipboard.sync.onSessionAccepted(false, System.currentTimeMillis(), gen)
                    if (filesGate.onConnectionGen(gen, transport)) syncFiles() // T-153: a new connection is untrusted
                }
            }

            override fun onMigration(endpoint: Endpoint, ok: Boolean, reason: String) {
                runOnUiThread { onMigrationResult(endpoint, ok, reason) }
            }

            override fun onAudio(msg: Message, gen: Int) { audio?.onAudio(msg, gen) } // control reader thread, never blocks

            override fun onSessionEnd() { audio?.endSession("session_end") }

            override fun onSettingsOpen() { settingsOpenPost.request() } // T-105: at most one queued on the UI thread

            override fun onWakeConnect(wake: WakeTag, ok: Boolean) { runOnUiThread { onWakeConnectResult(wake, ok) } } // T-134
        }, loggedPrefs(gameSettings.prefs(streamMode)), quickAck, knobs,if (audioAllowed) settings.audioEnabled() else null,
            wifiBinder = { s -> wolSender.bindToWifi(s) }, // T-134: direct wake attempts go out on Wi-Fi only
            initialFiles = FilesInfo.OFF, // T-135: FILES_INFO once per session, READY when the server listens
            stallDiag = stallDiag, // T-142
            // T-259 (decision 0034): HELLO bit11 only while the full colour self-test has passed (read per connection)
            helloCapabilities = { if (fullChromaOn()) Capabilities.FULL_CHROMA.toLong() else 0L },
        )
        startFullChromaSelfTest()
        files = FilesController({ controller.setFilesInfo(it) }, { settings.filesScope() }) { ui.post { refreshSettings() } } // T-190: scope
        capture = InputCapture(
            object : InputSink {
                override fun send(msg: Message) = controller.trySendInput(msg, inputGen)
                override fun congested() = controller.isSendCongested()
                override fun closeConnection() = controller.dropConnection(inputGen)
            },
            { viewport },
            onEvent = { ev, fields -> MbLog.i(ev, fields, "input") },
        ) { line -> MbLog.i("stats", line, "input") }
        capture.setFingerPolicy(gameSettings.fingers, SystemClock.uptimeMillis()) // T-223: Çizim layer included
        idleStore = IdleTimeoutStore(prefsStore) // T-234
        idle = IdleDimPolicy(idleWindow, SystemClock.uptimeMillis(), idleStore.get()) { fields -> MbLog.i("idle", fields, "input") }
        idle.setGameMode(streamMode.isGame, SystemClock.uptimeMillis())
        capture.idleGate = idle
        applyPointerSpeeds()
        // T-026: ask the system not to batch pen samples per display frame while input capture is active. The request
        // sits on a LEAF view, `video` (a fixed child of root): a ViewGroup
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
        video.isFocusable = true
        video.isFocusableInTouchMode = true
        video.setOnCapturedPointerListener(capturedPointerListener)
        clipboard = ClipboardBridge(this, ClipboardSync().also { it.enabled = settings.clipboardShare() }, { controller.trySend(it) }, { runOnUiThread(it) })
        // T-056: local pen indicator above the video (below the stats text and the panel), never touchable.
        penOverlay = PenOverlayView(this)
        penOverlay.model.trailEnabled = gameSettings.penTrail
        penOverlay.model.dotEnabled = gameSettings.penDot
        penOverlay.setVideoViewport(viewport)
        root.addView(penOverlay, root.indexOfChild(statsView), FrameLayout.LayoutParams(FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT))
        capture.penInk = penOverlay
        addVideoFaultOverlay() // T-159
        setupSettingsPanels()
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
        if (::sidePanel.isInitialized) closeSettingsPanel(SettingsPanelState.Via.BACKGROUND, resync = false) // T-105; the ticker re-syncs
        super.onPause()
    }

    // ---- input capture (T-024) ----

    /**
     * Input is routed to [capture] only while the video is visible and laid out and the settings side panel is closed
     * (T-105); the connect panel and the side panel keep normal touch and keys.
     */
    private fun syncInputActive(nowMs: Long = SystemClock.uptimeMillis()): Boolean {
        val on = settingsPanel.inputAllowed(started && !isDestroyed && panel.visibility == View.GONE && !viewport.isEmpty &&
            videoHealth.inputAllowed) // T-159: never live on a frozen, black or starting image
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
        val v = video
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

    override fun dispatchTouchEvent(ev: MotionEvent): Boolean {
        noteInputActivity()
        if (ev.actionMasked == MotionEvent.ACTION_DOWN && HzPin.reapplies(hzPinApplied)) setSurfaceFrameRate(true, log = false) // T-243
        try {
            return routeToCapture(ev) || super.dispatchTouchEvent(ev)
        } finally {
            noteIdleInput()
        }
    }

    override fun dispatchGenericMotionEvent(ev: MotionEvent): Boolean {
        noteInputActivity()
        try {
            return routeToCapture(ev) || super.dispatchGenericMotionEvent(ev)
        } finally {
            noteIdleInput()
        }
    }

    /**
     * T-234: every local event counts as activity for the idle counter. Called after routing, so an event the capture's
     * idle gate swallowed has already woken the window there; anything else (panels, system keys) wakes it here.
     */
    private fun noteIdleInput() {
        if (::idle.isInitialized) idle.onInput(IdleSource.UI, SystemClock.uptimeMillis())
    }

    /**
     * T-141: touch, pen and pointer input wake a sleeping vsync loop before the Mac answers with frames, so the panel
     * rate (a touch raises it to 120 Hz) is measured again by then. Nothing about the event itself changes.
     */
    private fun noteInputActivity() {
        if (vsyncIdle.onActivity(System.nanoTime())) wakeVsync()
    }

    override fun dispatchKeyEvent(ev: KeyEvent): Boolean {
        try {
            return routeKeyEvent(ev)
        } finally {
            noteIdleInput() // T-234
        }
    }

    private fun routeKeyEvent(ev: KeyEvent): Boolean {
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
            val frame = KeyFrame(
                deviceId = ev.deviceId, scanCode = ev.scanCode, keyCode = ev.keyCode,
                down = ev.action == KeyEvent.ACTION_DOWN, repeatCount = ev.repeatCount,
                ctrl = ev.metaState and KeyEvent.META_CTRL_ON != 0,
                shift = ev.metaState and KeyEvent.META_SHIFT_ON != 0,
                capsOn = ev.metaState and KeyEvent.META_CAPS_LOCK_ON != 0,
                timeUs = ev.eventTime * 1000,
            )
            // T-105: while the settings panel is open no key reaches the key tracker (nothing goes to the Mac).
            if (settingsPanel.isOpen) {
                when (val r = SettingsPanelState.keyWhileOpen(frame)) {
                    SettingsPanelState.KeyResult.Close -> closeSettingsPanel(
                        if (KeyTracker.localChord(frame) == LocalAction.SETTINGS) SettingsPanelState.Via.SHORTCUT else SettingsPanelState.Via.ESC,
                    )
                    is SettingsPanelState.KeyResult.Local -> runLocalAction(r.action)
                    SettingsPanelState.KeyResult.Consume -> Unit
                    SettingsPanelState.KeyResult.Pass -> return super.dispatchKeyEvent(ev)
                }
                return true
            }
            syncInputActive()
            val d = capture.onKey(frame)
            runLocalAction(d.local)
            if (d.consumed) return true
        }
        return super.dispatchKeyEvent(ev)
    }

    private fun runLocalAction(a: LocalAction) {
        when (a) {
            LocalAction.STATS -> toggleStats()
            LocalAction.SPEED_DOWN -> adjustPointerSpeed(SpeedRange.STEP_DOWN)
            LocalAction.SPEED_UP -> adjustPointerSpeed(SpeedRange.STEP_UP)
            // onPause sends RELEASE_ALL(BACKGROUND) (Ctrl/Shift held on the Mac are released) and capture is dropped.
            LocalAction.BACKGROUND -> moveTaskToBack(true)
            LocalAction.STREAM_MODE -> cycleStreamMode()
            LocalAction.SETTINGS -> toggleSettingsPanel()
            LocalAction.NONE -> {}
        }
    }

    // ---- in-stream settings panel (T-105, decision 0013) ----

    /** The stream is on screen (connect panel gone, a stream configured): the only time the side panel may open. */
    private fun streamVisible() = started && !isDestroyed && panel.visibility == View.GONE && streamConfig != null

    private fun toggleSettingsPanel() {
        if (settingsPanel.isOpen) closeSettingsPanel(SettingsPanelState.Via.SHORTCUT) else openSettingsPanel(SettingsPanelState.Via.SHORTCUT)
    }

    /**
     * Opens the side panel over the video. Input capture is turned off first, so `RELEASE_ALL(USER)` (after the natural
     * releases of anything held) is queued before the panel shows; pointer capture is released so the panel is touchable.
     */
    private fun openSettingsPanel(via: SettingsPanelState.Via) {
        if (!::sidePanel.isInitialized || !settingsPanel.open(via, streamVisible())) return
        try {
            syncInputActive()
        } catch (e: RuntimeException) {
            inputFailed(e, SystemClock.uptimeMillis())
        }
        sideSettings?.refresh()
        sidePanel.show()
    }

    /** Closes the side panel; input capture and pointer capture come back on the next sync (now, unless [resync] is off). */
    private fun closeSettingsPanel(via: SettingsPanelState.Via, resync: Boolean = true) {
        if (!::sidePanel.isInitialized || !settingsPanel.close(via)) return
        sidePanel.hide()
        if (!resync) return
        lastCaptureRequestMs = 0L // request pointer capture again at once, not after the retry interval
        try {
            syncInputActive()
        } catch (e: RuntimeException) {
            inputFailed(e, SystemClock.uptimeMillis())
        }
    }

    /** Both panels show the same values: any change (from either panel, a shortcut or the session) refreshes both. */
    private fun refreshSettings() {
        connectSettings?.refresh()
        sideSettings?.refresh()
    }

    private fun setupSettingsPanels() {
        connectSettings = SettingsViews(this, findViewById(R.id.panel_settings), SettingsCatalog.sections(settingsHost, inStream = false)) { refreshSettings() }
        sidePanel = SettingsSidePanel(this) { via -> closeSettingsPanel(via) }
        sideSettings = SettingsViews(this, sidePanel.content, SettingsCatalog.sections(settingsHost, inStream = true)) { refreshSettings() }
        root.addView(sidePanel.layer, FrameLayout.LayoutParams(FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT))
    }

    @Deprecated("Deprecated in Java")
    @Suppress("DEPRECATION")
    override fun onBackPressed() {
        if (settingsPanel.isOpen) { closeSettingsPanel(SettingsPanelState.Via.BACK); return }
        super.onBackPressed()
    }

    /** The one implementation of every setting (persist + apply), used by both panels (T-105). */
    private val settingsHost = object : SettingsHost {
        override val transportMode get() = mode
        override fun selectTransport(m: TransportMode) = this@MainActivity.selectTransport(m)
        override fun disconnect() = userDisconnect()
        override val forgetHostLabel get() = getString(R.string.forget_host)
        override fun forgetHost() = onForgetHostClicked()

        override val streamMode get() = this@MainActivity.streamMode
        override fun selectStreamMode(m: StreamMode) = setStreamMode(m, toast = false)
        // T-223 (decision 0030 §2): the current mode's own rate; one complete STREAM_PREFS (a 60<->120 change recreates the display once).
        override val frameRate get() = gameSettings.fps(this@MainActivity.streamMode)
        override fun selectFrameRate(fps: Int) {
            gameSettings.selectFrameRate(this@MainActivity.streamMode, fps)?.let { sendStreamPrefs(it) }
        }
        // T-215 (decision 0029): stored; one complete STREAM_PREFS only while Oyun is on.
        override val gameResolution get() = settings.gameResolution()
        override fun selectGameResolution(r: GameResolution) {
            gameSettings.selectGameResolution(r, this@MainActivity.streamMode)?.let { sendStreamPrefs(it) }
        }
        // T-109: bit rate, audio output and pen trail/dot go through gameSettings (stored, or the game layer).
        override val bitrateKbps get() = gameSettings.bitrateKbps
        override fun selectBitrate(kbps: Long) {
            gameSettings.setBitrateKbps(kbps)
            sendStreamPrefs(gameSettings.prefs(this@MainActivity.streamMode))
        }
        override val appliedBitrateKbps get() = streamConfig?.bitrateKbps
        // T-238 (decision 0032): stored; one complete STREAM_PREFS only when Oyun's request changes.
        override val hdrCapability get() = gameSettings.hdr
        override val hdrEnabled get() = gameSettings.hdrSetting
        override fun selectHdr(on: Boolean) {
            gameSettings.selectHdr(on, this@MainActivity.streamMode)?.let { sendStreamPrefs(it) }
        }
        override val appliedConfig get() = streamConfig
        // T-241 (decision 0033): stored; one complete STREAM_PREFS when it changes (every mode).
        override val sharpChroma get() = gameSettings.sharpChroma
        override fun selectSharpChroma(on: Boolean) {
            gameSettings.selectSharpChroma(on, this@MainActivity.streamMode)?.let { sendStreamPrefs(it) }
        }
        override val modeLayer get() = gameSettings.modeLayer
        override val idleTimeout get() = idle.timeout
        override fun selectIdleTimeout(t: IdleTimeout) { // T-234
            idleStore.set(t)
            idle.setTimeout(t, SystemClock.uptimeMillis())
        }

        override val audioAvailable get() = audio != null
        override val audioEnabled get() = settings.audioEnabled()
        // No local stop (review L2): the host answers AUDIO_PREFS(0) with STOPPED, so a quick off-on cannot leave a
        // stream that the tablet dropped but the host still sends.
        override fun setAudioEnabled(on: Boolean) = setAudioSetting(on)
        override val audioOut get() = audio?.outPref ?: gameSettings.audioOut
        // T-101: saves the choice and applies it, which ends a `--es audio_out` launch override (like the display mode).
        // T-109: in game mode only the layer changes.
        override fun setAudioOut(p: AudioOutPref) {
            gameSettings.setAudioOut(p)
            audioOutFromExtra = false
            audio?.setOutPref(p)
        }

        override val touchpadSpeed get() = settings.touchpadSpeed()
        override val mouseSpeed get() = settings.mouseSpeed()
        override fun stepSpeed(mouse: Boolean, factor: Float) {
            settings.adjustSpeed(mouse, factor)
            applyPointerSpeeds()
        }
        override val fingerTouchDisabled get() = capture.fingersDisabled
        override fun setFingerTouchDisabled(off: Boolean) { // decision 0006; T-223: in Çizim only the layer changes
            gameSettings.setFingerOff(off)
            capture.setFingerPolicy(gameSettings.fingers, SystemClock.uptimeMillis())
        }
        override val penTrail get() = penOverlay.model.trailEnabled
        override fun setPenTrail(on: Boolean) { // T-056
            gameSettings.setPenTrail(on)
            applyPenTrail(on)
        }
        override val penDot get() = penOverlay.model.dotEnabled
        override fun setPenDot(on: Boolean) {
            gameSettings.setPenDot(on)
            applyPenDot(on)
        }

        override val filesShare get() = settings.filesShare()
        override fun setFilesShare(on: Boolean) { // T-135
            settings.setFilesShare(on)
            if (on && !files.hasPermission()) files.openPermissionScreen(this@MainActivity) // onStart re-syncs on return
            syncFiles()
        }
        override val filesRoot get() = settings.filesRoot()
        override fun selectFilesRoot(r: FilesRoot) { settings.setFilesRoot(r); files.rescope() } // T-190
        override val filesReadOnly get() = settings.filesReadOnly()
        override fun setFilesReadOnly(on: Boolean) { settings.setFilesReadOnly(on); files.rescope() } // T-190
        override val filesStatus get() = files.statusText

        override val clipboardShare get() = clipboard.sync.enabled
        override fun setClipboardShare(on: Boolean) { // T-055
            clipboard.sync.enabled = on
            settings.setClipboardShare(on)
        }
        override val statsOverlay get() = statsOn
        override fun setStatsOverlay(on: Boolean) { if (on != statsOn) toggleStats() }

        override val resetConfirm = TwoTapConfirm({ SystemClock.elapsedRealtime() }) // T-191
        override fun onResetArmed() {
            ui.removeCallbacks(resetHintExpiry)
            ui.postDelayed(resetHintExpiry, TwoTapConfirm.WINDOW_MS + 50)
        }
        override fun resetToDefaults() = resetSettingsToDefaults()
    }

    /** T-191: the armed hint goes back once the confirmation window has passed. */
    private val resetHintExpiry = Runnable { if (!isDestroyed) refreshSettings() }

    /**
     * T-191 "Varsayılanlara dön" (confirmed): removes every user setting and the learned audio state, then applies the
     * defaults to what runs now, mostly without writing them back. Pairing keys (their own file), the device id, the
     * last endpoint, the T-096 migration flag and the learned wake data are kept. Launch extras stay, except that the
     * transport and audio output follow the panel rule (a panel choice ends their launch override).
     */
    private fun resetSettingsToDefaults() {
        if (isDestroyed) return
        ui.removeCallbacks(resetHintExpiry)
        val audioWas = settings.audioEnabled()
        val scopeWas = settings.filesScope()
        // T-241: "Keskin renk kenarları" lives outside Settings; reset before the STREAM_PREFS below.
        val removed = settings.resetToDefaults() + (if (gameSettings.resetSharpChroma()) 1 else 0)
        audio?.forgetLearned() // takes effect at the next audio stream start
        MbLog.i("settings_reset", "keys=$removed")
        // Display: mode (a game layer is dropped and its values re-applied) and STREAM_PREFS with the default bit rate.
        // A 60<->120 change may recreate the virtual display once (decision 0016).
        streamMode = settings.streamMode()
        gameSettings.onModeChanged(streamMode)?.let { change -> applyGameLayer(change) }
        sendStreamPrefs(gameSettings.prefs(streamMode))
        // T-234: idle dim back to its default (its key lives in IdleTimeoutStore, not Settings).
        idleStore.reset()
        idle.setGameMode(streamMode.isGame, SystemClock.uptimeMillis())
        idle.setTimeout(idleStore.get(), SystemClock.uptimeMillis())
        // Audio: output (ends a launch override, like the panel), and on/off to the host only when it changed.
        audioOutFromExtra = false
        audio?.setOutPref(gameSettings.audioOut)
        if (settings.audioEnabled() != audioWas) controller.setAudioEnabled(settings.audioEnabled())
        // Input and overlays.
        applyPointerSpeeds()
        if (capture.fingerPolicy != gameSettings.fingers) {
            capture.setFingerPolicy(gameSettings.fingers, SystemClock.uptimeMillis())
        }
        applyPenTrail(gameSettings.effective().penTrail)
        applyPenDot(gameSettings.effective().penDot)
        if (::clipboard.isInitialized) clipboard.sync.enabled = settings.clipboardShare()
        statsOn = settings.statsOverlay()
        applyStatsVisibility()
        // Files: off by default (the server stops); a changed folder or read-only flag restarts a running one.
        syncFiles()
        if (settings.filesScope() != scopeWas) files.rescope()
        refreshSettings()
        Toast.makeText(this, RESET_DONE_TEXT, Toast.LENGTH_LONG).show()
        // Transport last: a change to AUTO may reconnect (it goes through the panel's own path and stores "auto").
        if (mode != settings.transportMode()) selectTransport(settings.transportMode())
    }

    /**
     * "Bağlantıyı kes" (T-105): BYE, back to the connect panel, and no automatic reconnect (discovery, USB probe, AUTO
     * ticker) until the user presses "Bağlan" or picks a connection mode.
     */
    private fun userDisconnect() {
        MbLog.i("user_disconnect")
        userDisconnected = true
        closeSettingsPanel(SettingsPanelState.Via.DISCONNECT, resync = false)
        discovery?.stop()
        discovery = null
        rediscovery.reset() // T-227
        ui.removeCallbacks(usbHintCheck)
        probeGuard.bump()
        picking = false
        transportEpoch++
        fallbackPending = false
        currentEndpoint = null
        pairPick.dismiss() // T-151: no pick prompt after the user disconnected (asked endpoints stay asked)
        controller.stop() // sends BYE, closes both connections
        render(SessionUi.Idle)
    }

    private val inputTicker = object : Runnable {
        override fun run() {
            val now = SystemClock.uptimeMillis()
            try {
                syncInputActive(now)
                idle.tick(now) // T-234
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

    /** Persists the audio setting, tells the host (AUDIO_PREFS) and refreshes both settings panels. Main thread. */
    private fun setAudioSetting(on: Boolean) {
        settings.setAudioEnabled(on)
        controller.setAudioEnabled(on)
        refreshSettings()
    }

    /**
     * Headphones went away (review L6): the stream is already muted locally; turning the setting off sends
     * AUDIO_PREFS(0), so the host stops capturing and the Mac's own output returns instead of both sides being silent.
     */
    private fun onAudioBecomingNoisy() {
        if (isDestroyed || !settings.audioEnabled()) return
        setAudioSetting(false)
        Toast.makeText(this, "Kulaklık çıkarıldı: ses Mac'e döndü (Ses ayarından yeniden açabilirsin)", Toast.LENGTH_LONG).show()
    }

    /** Next display mode (Ctrl+Shift+7) with a Toast. */
    private fun cycleStreamMode() = setStreamMode(streamMode.next(), toast = true)

    /**
     * Display mode (T-050): persist, tell the host (STREAM_PREFS, with the bit rate choice), refresh both panels.
     * Entering or leaving Oyun or Çizim (T-109, T-223) first builds or drops the mode layer and applies what changed (audio output,
     * pen trail/dot, finger switch, jitter buffer); fps, scale and bit rate still go in this one STREAM_PREFS.
     */
    private fun setStreamMode(m: StreamMode, toast: Boolean) {
        streamMode = m
        settings.setStreamMode(m)
        idle.setGameMode(m.isGame, SystemClock.uptimeMillis()) // T-234: no idle stages in Oyun
        gameSettings.onModeChanged(m)?.let { change -> applyGameLayer(change) }
        sendStreamPrefs(gameSettings.prefs(m))
        refreshSettings()
        if (toast) Toast.makeText(this, m.toastText(gameSettings.fps(m), gameSettings.display(m)), Toast.LENGTH_SHORT).show()
    }

    /** T-109/T-223: a mode layer was built or dropped; apply the effective values that differ from what runs now. */
    private fun applyGameLayer(change: GameModeSettings.Transition) {
        val e = gameSettings.effective()
        if (!audioOutFromExtra) audio?.setOutPref(e.audioOut) // no-op (no reopen) when unchanged
        applyPenTrail(e.penTrail)
        applyPenDot(e.penDot)
        // Çizim: one-finger touches go silent (palm), pinch and two-finger scroll stay; whatever the new policy forbids
        // (a held one-finger drag) is released on the host right here, never left stuck.
        if (::capture.isInitialized && capture.fingerPolicy != e.fingers) {
            capture.setFingerPolicy(e.fingers, SystemClock.uptimeMillis())
        }
        applyJitter()
        MbLog.i("mode_layer", GameModeSettings.logFields(change, currentJitter(), e))
    }

    private fun applyPenTrail(on: Boolean) {
        if (penOverlay.model.trailEnabled == on) return
        penOverlay.model.trailEnabled = on
        penOverlay.onPenClear()
    }

    private fun applyPenDot(on: Boolean) {
        if (penOverlay.model.dotEnabled == on) return
        penOverlay.model.dotEnabled = on
        penOverlay.postInvalidateOnAnimation()
    }

    /** Jitter buffer for the current mode (decision 0014 §2); a launch value wins. */
    private fun currentJitter() = GameJitter.choose(launchBufferFrames, bufferFixedBy, gameSettings.gameActive)

    /** Applies [currentJitter]; a running renderer takes it on its next frame. */
    private fun applyJitter() {
        bufferFrames = currentJitter().bufferFrames
        renderer?.bufferFrames = bufferFrames
    }

    private fun applyPointerSpeeds() = capture.setPointerSpeeds(settings.touchpadSpeed(), settings.mouseSpeed())

    private fun adjustPointerSpeed(factor: Float) {
        val mouse = capture.lastPointerIsMouse
        val v = settings.adjustSpeed(mouse, factor)
        applyPointerSpeeds()
        refreshSettings()
        Toast.makeText(this, SpeedRange.label(mouse, v), Toast.LENGTH_SHORT).show()
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
        refreshSettings()
    }

    private fun applyStatsVisibility() {
        statsView.visibility = if (statsOn) View.VISIBLE else View.GONE
    }

    // ---- video surface and renderer ----

    override fun surfaceCreated(holder: SurfaceHolder) {
        if (holder !== video.holder) return
        surfaceValid = true
        if (streamConfig != null) {
            setSurfaceFrameRate(true)
            attachVideoOutput(holder.surface)
        }
    }

    override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) {}

    override fun surfaceDestroyed(holder: SurfaceHolder) {
        if (holder !== video.holder) return
        surfaceValid = false
        detachVideoOutput()
    }

    /**
     * Points the video at [surface] for the current [streamConfig]: the packed pipeline for `chroma_layout = 1` (when it can
     * be built), else the direct path (the main stream straight into the SurfaceView, exactly as before decision 0034).
     * UI thread.
     */
    private fun attachVideoOutput(surface: android.view.Surface) {
        val r = renderer ?: return
        val c = streamConfig
        if (c != null && c.isPacked444 && fullChromaOn()) {
            val p = chromaPipeline ?: dev.matebridge.client.video.FullChromaPipeline(
                r,
                sendAuxKeyframeRequest = { reason -> controller.trySend(KeyframeRequest(reason, KeyframeRequest.VIEW_AUX)) },
                onFailed = { why -> runOnUiThread { onFullChromaFailed(why) } },
            ).also { chromaPipeline = it }
            if (p.start(surface, c)) return
            // Start failed synchronously (ImageReader, thread, previous teardown...): the negotiated fallback, not a
            // silent direct attach, so the host stops sending the auxiliary stream too.
            MbLog.w("full_chroma_fallback", "reason=start layout=${c.chromaLayout}", "render")
            onFullChromaFailed("start_failed")
            return
        }
        attachDirect(surface)
    }

    /** Set while the direct decoder could not be attached because a stuck presenter still owns the surface. */
    private var directDeferred = false
    /** `config_id` the deferred direct attach was requested for; a retry only serves that very configuration. */
    private var directDeferredConfigId = -1

    /**
     * The direct path on [surface], but only once no GL thread of the packed path can still be producing into it; else it
     * is deferred (the ticker retries) and an error is logged.
     */
    private fun attachDirect(surface: android.view.Surface) {
        val pipe = chromaPipeline
        if (!dev.matebridge.client.video.PackedPresenter.awaitPrevious(0) || pipe?.busy() == true) {
            if (!directDeferred) MbLog.e("full_chroma_surface_busy", "action=defer", "render")
            directDeferred = true
            directDeferredConfigId = streamConfig?.configId ?: -1
            return
        }
        directDeferred = false
        renderer?.attachSurface(surface)
    }

    /** Releases the video output (the surface is about to go): the packed pipeline when it runs, else the renderer. */
    private fun detachVideoOutput() {
        directDeferred = false // a pending direct attach belongs to the output that is going away
        val p = chromaPipeline
        if (p != null && p.active) p.stop() else renderer?.detachSurface()
    }

    /**
     * The packed path failed in this process (GL init or repeated draw errors): from now on this process asks for the
     * sharp colour value instead (no `chroma = 2`, no bit11) and shows the main view through the direct path. The host
     * follows the new STREAM_PREFS with a `chroma_layout = 0` STREAM_CONFIG; the main stream shown meanwhile is a normal
     * 4:2:0 picture.
     */
    private fun onFullChromaFailed(why: String) {
        if (isDestroyed || fullChromaRuntimeOff) return
        fullChromaRuntimeOff = true
        MbLog.e("full_chroma_disabled", "reason=${why.take(60)} scope=process", "render")
        val surface = if (surfaceValid) video.holder.surface else null
        detachVideoOutput()
        if (surface != null && streamConfig != null) attachDirect(surface)
        sendStreamPrefs(gameSettings.prefs(streamMode))
        refreshSettings()
    }

    /**
     * Once per build: the capability self-test off the UI thread, before any stream decoder exists. A result that arrives
     * later shows on the next connection's HELLO and applies to the running session through a fresh STREAM_PREFS.
     */
    private fun startFullChromaSelfTest() {
        val st = fullChromaCap.status()
        if (!fullChromaCap.needsTest()) {
            MbLog.i("full_chroma_cap", "state=${st.state.name.lowercase()} reason=${st.reason.ifEmpty { "-" }} cached=1", "render")
            return
        }
        Thread({
            val outcome = dev.matebridge.client.video.FullChromaSelfTest.runAndRecord(fullChromaCap) { detail ->
                MbLog.i("full_chroma_selftest_detail", detail.take(300).replace('\n', ' '), "render")
            }
            val result = when (outcome) {
                dev.matebridge.client.video.FullChromaSelfTest.Outcome.Pass -> "pass reason=-"
                is dev.matebridge.client.video.FullChromaSelfTest.Outcome.Fail -> "fail reason=${outcome.reason}"
                is dev.matebridge.client.video.FullChromaSelfTest.Outcome.Inconclusive -> "inconclusive reason=${outcome.reason}"
            }
            MbLog.i("full_chroma_selftest", "result=$result", "render")
            runOnUiThread {
                if (!isDestroyed) {
                    refreshSettings()
                    if (lastUi is SessionUi.Connected) sendStreamPrefs(gameSettings.prefs(streamMode))
                }
            }
        }, "mb-fc-selftest").start()
    }

    /** T-251: the pacer knobs in effect go on the first `render ev=stats` line of each renderer, once. */
    private var pacerKnobsLogged = false

    private fun pacerKnobsField(): String {
        if (pacerKnobsLogged) return ""
        pacerKnobsLogged = true
        return " pacer_knobs=${devKnobs.pacerTuning.logFields()}"
    }

    private fun installConfig(config: StreamConfig) {
        if (!started || isDestroyed) return
        streamConfig = config
        capture.setStreamGeometry(config.widthPt, config.heightPt)
        val r = renderer ?: VideoRenderer(
            config,
            onKeyframeRequest = { reason -> controller.trySend(mainKeyframeRequest(reason)) }, // T-259: `view` only in packed mode
            onGiveUp = { why -> MbLog.e("decoder_give_up", "reason=${why.take(40)}", "decoder") },
            vsync = vsync,
            bufferFrames = bufferFrames,
            codecReportsShown = true, // T-184: the only path; the codec's render callback reports shown times
            codecFactory = decoderFault ?: dev.matebridge.client.video.MediaCodecDecoder.FACTORY, // T-159 debug extra
            onHealthEvent = { e -> runOnUiThread { onVideoHealthEvent(e) } }, // T-159; Generation runs inline
            onConfigInstalled = { c -> controller.videoConfigInstalled(c) }, // T-160: frames of c are delivered from now on
            decoderTuning = devKnobs.decoderLatency, // T-217 dev knob (`dec_lowlat`, `dec_oprate`)
            colorOverrides = devKnobs.colorOverrides, // T-231 dev knob (`color_range`, `color_standard`, `color_transfer`)
        ).also {
            it.pacerTuning = devKnobs.pacerTuning // T-251 dev knobs (`pace_dcap_half`, `pace_feedback`)
            it.catchUp = devKnobs.catchUp // T-252 dev knob (`catch_up`)
            pacerKnobsLogged = false
            it.paceTrace = paceTrace
            it.paceTraceFile = java.io.File(cacheDir, "pace_trace.csv")
            it.stats.latencyOf = { cap, at -> clock.latencySignedUs(cap, at) } // T-168: signed; `at` on SessionController.clockUs()'s clock
            renderer = it
        }
        layoutVideo()
        applyRefreshRate()
        setSurfaceFrameRate(true)
        startVsync()
        flushStatsLog() // T-141: a reconfiguration closes the log window of the previous configuration
        lastStatsMs = SystemClock.elapsedRealtime()
        statsLog.start(lastStatsMs)
        rttStats.reset() // T-089: the first ev=net window holds no approval-wait or reconnect samples
        // T-259: a change into, out of or within the packed layout rebuilds the video output (the decoder target differs).
        packedVideo = config.isPacked444
        if (chromaPipeline?.active == true || (config.isPacked444 && fullChromaOn() && r.attached)) detachVideoOutput()
        r.reconfigure(config) // restarts the codec without blocking when a surface is attached
        if (!r.attached && surfaceValid) attachVideoOutput(video.holder.surface)
        MbLog.i("stream_config_bitrate", "bitrate_kbps=${config.bitrateKbps} wanted_kbps=${gameSettings.bitrateKbps}") // T-105
        logProfile(config)
        if (filesGate.onConfigApplied()) syncFiles() // T-153: the authenticated config makes this session trusted
        refreshSettings() // "Uygulanan: N Mbps", "Uygulanan: HDR10 / SDR" (T-238)
    }

    /** T-238: every STREAM_PREFS goes to the session through here (logs a changed dynamic range first). */
    private fun sendStreamPrefs(prefs: StreamPrefs) {
        controller.setStreamPrefs(loggedPrefs(prefs))
    }

    /** T-238: `ev=hdr_request` when [prefs] asks for a different dynamic range than the last request; returns [prefs]. */
    private fun loggedPrefs(prefs: StreamPrefs): StreamPrefs {
        if (hdrRequestLog.take(prefs.dynamicRange)) {
            MbLog.i("hdr_request", HdrPolicy.requestFields(prefs.dynamicRange, streamMode, gameSettings.hdrSetting, gameSettings.hdr))
        }
        return prefs
    }

    /**
     * T-238 (decision 0032): the display reports HDR10 and the first HEVC decoder of the codec list (the one
     * `createDecoderByType` returns, as the renderer does) advertises Main10HDR10. Any failure counts as "no".
     */
    @Suppress("DEPRECATION")
    private fun detectHdrCapability(): HdrCapability {
        val types = try {
            val d = if (Build.VERSION.SDK_INT >= 30) display else windowManager.defaultDisplay
            d?.hdrCapabilities?.supportedHdrTypes
        } catch (e: Exception) { null }
        val codecs = try {
            android.media.MediaCodecList(android.media.MediaCodecList.REGULAR_CODECS).codecInfos.map { info ->
                val hevc = info.supportedTypes.firstOrNull { it.equals(HdrCapability.MIME_HEVC, ignoreCase = true) }
                val profiles = if (info.isEncoder || hevc == null) null else try {
                    info.getCapabilitiesForType(hevc).profileLevels.map { it.profile }.toIntArray()
                } catch (e: Exception) { null }
                HdrCapability.CodecEntry(info.isEncoder, info.supportedTypes.toList(), profiles)
            }
        } catch (e: Exception) { emptyList() }
        return HdrCapability(HdrCapability.displayHdr10(types), HdrCapability.decoderMain10Hdr10(codecs))
    }

    /** T-185 (decision 0026 §4): one `ev=profile` line per installed config; no address, serial or device id. */
    private fun logProfile(config: StreamConfig) {
        val audioOut = if (audioOutFromExtra) AudioOutPref.parse(devKnobs.audioOut) ?: gameSettings.audioOut else gameSettings.audioOut
        val profile = dev.matebridge.client.session.StreamProfile(
            mode = streamMode.id,
            fps = config.fps,
            widthPx = config.widthPx,
            heightPx = config.heightPx,
            scalePermille = StreamMode.SCALE_PERMILLE,
            bitrateKbps = config.bitrateKbps,
            bitrateSettingKbps = gameSettings.bitrateKbps,
            transport = currentEndpoint?.let { ConnectMode.transportOf(it).logName } ?: "-",
            transportMode = mode.id,
            audioOn = audioAllowed && settings.audioEnabled(),
            audioOut = audioOut.id,
            bufferFrames = bufferFrames,
            displayWidthPx = gameSettings.display(streamMode)?.widthPx ?: 0,
            displayHeightPx = gameSettings.display(streamMode)?.heightPx ?: 0,
            displayApplied = gameSettings.display(streamMode)?.appliedIn(config) ?: false,
            hdr = config.isHdr10, // T-238: applied, from STREAM_CONFIG
        )
        // T-241 (decision 0033): the requested `chroma` (the host does not report the applied one).
        val chroma = SharpChromaPolicy.profileField(gameSettings.sharpChroma)
        MbLog.i("profile", profile.logFields(BuildInfo.current.sha, BuildInfo.current.builtUtc, devKnobs) + " " + chroma)
    }

    /** Stops video (surface released, frames gated). The renderer object is kept and reused. */
    private fun releaseRenderer() {
        detachVideoOutput()
        packedVideo = false
        streamConfig = null
        audio?.onVideoLatency(null) // no video: no A/V target
        flushStatsLog() // T-141: the partial log window of the stream that ends
        statsView.text = ""
        lastOverlayText = null
        releaseRefreshRate()
        setSurfaceFrameRate(false)
        stopVsync()
    }

    /** T-159: renderer lifecycle, UI thread (a Generation arrives inline, before its decoder thread starts). */
    private fun onVideoHealthEvent(e: dev.matebridge.client.video.HealthEvent) {
        if (e is dev.matebridge.client.video.HealthEvent.Generation) decoderFault?.onGeneration(e.gen)
        videoHealth.onEvent(e)
    }

    /** T-159: FAULT stops feeding (no ~2 IDR/s loop); FAULT and STARTING close capture (releases + RELEASE_ALL(USER)). */
    private fun onVideoHealthChanged() {
        if (!videoHealth.feedAllowed) renderer?.stopFeeding()
        syncVideoFaultOverlay()
        if (::capture.isInitialized) syncInputActive()
    }

    private fun runVideoRecovery(action: dev.matebridge.client.video.VideoHealth.Action) {
        when (action) {
            dev.matebridge.client.video.VideoHealth.Action.RESTART_CODEC -> renderer?.restartCodec()
            // The session reconnects; the surface re-attaches on its STREAM_CONFIG (a new generation).
            dev.matebridge.client.video.VideoHealth.Action.RECONNECT -> controller.dropConnection(inputGen)
        }
    }

    /** T-159: "Görüntü durdu" box with "Yeniden dene", centred over the video, below the stats text and the panels. */
    private fun addVideoFaultOverlay() {
        val d = resources.displayMetrics.density
        val title = TextView(this).apply {
            setText(R.string.video_fault_title)
            setTextColor(Color.WHITE)
            textSize = 22f
            setTypeface(typeface, Typeface.BOLD)
            gravity = android.view.Gravity.CENTER
        }
        val text = TextView(this).apply {
            setTextColor(Color.WHITE)
            textSize = 16f
            gravity = android.view.Gravity.CENTER
            maxWidth = (480 * d).toInt()
        }
        val retry = Button(this).apply {
            setText(R.string.video_fault_retry)
            setOnClickListener { videoHealth.retry()?.let { runVideoRecovery(it) } }
        }
        val box = android.widget.LinearLayout(this).apply {
            orientation = android.widget.LinearLayout.VERTICAL
            gravity = android.view.Gravity.CENTER_HORIZONTAL
            setBackgroundColor(Color.argb(0xCC, 0, 0, 0))
            val pad = (24 * d).toInt()
            setPadding(pad, pad, pad, pad)
            visibility = View.GONE
            val gap = android.widget.LinearLayout.LayoutParams(
                android.widget.LinearLayout.LayoutParams.WRAP_CONTENT, android.widget.LinearLayout.LayoutParams.WRAP_CONTENT,
            ).apply { topMargin = (12 * d).toInt() }
            addView(title)
            addView(text, gap)
            addView(retry, android.widget.LinearLayout.LayoutParams(gap))
        }
        root.addView(box, root.indexOfChild(statsView), FrameLayout.LayoutParams(
            FrameLayout.LayoutParams.WRAP_CONTENT, FrameLayout.LayoutParams.WRAP_CONTENT, android.view.Gravity.CENTER,
        ))
        videoFaultOverlay = box
        videoFaultText = text
    }

    /** T-159: the overlay shows while the video is faulted or recovering and the connect panel is hidden. */
    private fun syncVideoFaultOverlay() {
        val o = videoFaultOverlay ?: return
        val show = videoHealth.showOverlay && panel.visibility == View.GONE
        if (show) videoFaultText?.setText(if (videoHealth.manual) R.string.video_fault_manual else R.string.video_fault_recovering)
        val v = if (show) View.VISIBLE else View.GONE
        if (o.visibility != v) o.visibility = v
    }

    /** Vsync tracking runs only while streaming; seeded from the real display rate. */
    private fun startVsync() {
        if (choreographerOn) return
        choreographerOn = true
        vsync.setNominalHz(currentHz())
        applyDisplayTiming(log = true)
        vsyncGaps.breakSequence()
        vsyncGaps.summary(reset = true)
        vsyncIdle.start(System.nanoTime())
        renderer?.firstOutput?.disarm()
        Choreographer.getInstance().postFrameCallback(vsyncCallback)
        (getSystemService(Context.DISPLAY_SERVICE) as DisplayManager).registerDisplayListener(displayListener, ui)
        rateDebouncer = DisplayRateDebouncer()
        hzSwitches.restart()
        ui.removeCallbacks(rateTicker)
        ui.post(rateTicker)
    }

    /** T-059: the measured panel rate (from the vsync period), debounced, goes to the session (host thins frames to it). */
    private var rateDebouncer = DisplayRateDebouncer()
    private val rateTicker = object : Runnable {
        override fun run() {
            if (!choreographerOn) return
            val period = vsync.periodNs
            if (period > 0 && vsyncIdle.rateReady) { // T-141: right after a wake the clock is re-measured first
                val hz = Math.round(1e9 / period).toInt()
                rateDebouncer.observe(hz, SystemClock.elapsedRealtime())?.let {
                    controller.setDisplayRate(it)
                    MbLog.i("display_rate", "hz=$it", "render")
                    hzSwitches.observe(it) // T-243
                    if (HzPin.reapplies(hzPinApplied)) setSurfaceFrameRate(true, log = false) // T-243
                }
            }
            ui.postDelayed(this, RATE_POLL_MS)
        }
    }

    /**
     * T-141, main thread: no frame for [VsyncIdleGate.DEFAULT_IDLE_AFTER_NS]; the vsync callback was not re-registered.
     * The clock forgets its phase but keeps its period (the panel rate stays at its last value and no DISPLAY_RATE goes
     * out); with no phase the pacers present the first frame after the pause at once instead of on a stale grid.
     */
    private fun sleepVsync() {
        renderer?.firstOutput?.arm() // review P2: the first frame after the sleep goes out at once, even if the loop restarts first
        vsync.reset()
        vsyncGaps.breakSequence()
        ui.removeCallbacks(rateTicker)
        rateDebouncer.onPause()
    }

    /** T-141, main thread: a frame or input arrived while the vsync loop slept; restart it and the rate poll. */
    private fun wakeVsync() {
        if (!choreographerOn) return
        val woke = vsyncIdle.wake(System.nanoTime()) ?: return
        Choreographer.getInstance().postFrameCallback(vsyncCallback)
        ui.removeCallbacks(rateTicker)
        ui.post(rateTicker)
        if (woke.idleLogged) MbLog.i("idle", "state=off idle_ms=${woke.sleptNs / 1_000_000}", "render")
    }

    private fun stopVsync() {
        if (!choreographerOn) return
        choreographerOn = false
        vsyncIdle.stop()
        renderer?.firstOutput?.disarm()
        ui.removeCallbacks(vsyncWake)
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
        if (log) {
            MbLog.i(
                "display_timing",
                "app_vsync_offset_ns=$off presentation_deadline_ns=$deadline lead_override_us=${vsync.leadOverrideNs / 1000} effective_deadline_ns=${vsync.grid().deadlineNs} deadline_override=${vsync.deadlineOverrideNs}",
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
        val pin = HzPin.plan(devKnobs.hzPin, streamMode.isGame, streamConfig?.fps ?: 0) // T-243: empty unless `hz_pin`
        if (target <= 0) { clearHzPin(); return }
        if (modeApplied && appliedModeHz == target && pin == hzPinApplied) return
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
        if (pick == null) { clearHzPin(); return }
        modeApplied = true
        appliedModeHz = target
        val was = hzPinApplied
        val results = ArrayList<Pair<HzPinHint, HzPinResult>>()
        window.attributes = window.attributes.also {
            it.preferredDisplayModeId = pick.id
            if (pin.isNotEmpty()) results += applyHzPinHints(it, pin, HzPin.PIN_HZ.toFloat())
            else if (was.isNotEmpty()) applyHzPinHints(it, was, 0f)
        }
        hzPinApplied = pin
        if (pin.isNotEmpty()) MbLog.i("hz_pin", HzPin.logFields(devKnobs.hzPin, true, results) + hzPinVendorFields(pin), "render")
        else if (was.isNotEmpty()) MbLog.i("hz_pin", HzPin.logFields(devKnobs.hzPin, false, emptyList()), "render")
        setSurfaceFrameRate(true) // vsync period follows via DisplayListener once the mode settles
    }

    /**
     * T-243: writes the window hints of [hints] into [lp] ([rate] 0 = clear). [HzPinHint.HW_LP] only looks (nothing is
     * written) and [HzPinHint.REAPPLY] acts on rate changes and touch starts, so both just report here.
     */
    private fun applyHzPinHints(lp: WindowManager.LayoutParams, hints: List<HzPinHint>, rate: Float): List<Pair<HzPinHint, HzPinResult>> =
        hints.map { h ->
            h to when (h) {
                HzPinHint.LP_RATE -> HzPin.setFloatField(lp, HzPin.FIELD_PREFERRED_REFRESH_RATE, rate)
                HzPinHint.LP_MINMAX -> HzPin.setMinMax(lp, rate)
                HzPinHint.HW_LP -> HzPin.vendorResult(HzPin.vendorFields(WindowManager.LayoutParams::class.java), hwLayoutParamsExPresent())
                HzPinHint.REAPPLY -> if (Build.VERSION.SDK_INT >= 30) HzPinResult.OK else HzPinResult.MISSING
            }
        }

    /** T-243: ` hw_fields=<names>|- hw_ex=0|1` when [HzPinHint.HW_LP] is in [pin], else empty. Class metadata only. */
    private fun hzPinVendorFields(pin: List<HzPinHint>): String {
        if (HzPinHint.HW_LP !in pin) return ""
        val names = HzPin.vendorFields(WindowManager.LayoutParams::class.java)
        return " hw_fields=${HzPin.fieldList(names)} hw_ex=${if (hwLayoutParamsExPresent()) 1 else 0}"
    }

    private fun hwLayoutParamsExPresent(): Boolean = try {
        Class.forName(HzPin.HW_LAYOUT_PARAMS_EX, false, classLoader)
        true
    } catch (_: Throwable) {
        false
    }

    /** T-243: removes applied `hz_pin` window hints (no-op without them, so the default path makes no extra call). */
    private fun clearHzPin() {
        val was = hzPinApplied
        if (was.isEmpty()) return
        hzPinApplied = emptyList()
        window.attributes = window.attributes.also { applyHzPinHints(it, was, 0f) }
        MbLog.i("hz_pin", HzPin.logFields(devKnobs.hzPin, false, emptyList()), "render")
    }

    private fun releaseRefreshRate() {
        if (!modeApplied) return
        modeApplied = false
        appliedModeHz = 0
        setSurfaceFrameRate(false)
        val was = hzPinApplied
        hzPinApplied = emptyList()
        window.attributes = window.attributes.also {
            it.preferredDisplayModeId = 0
            if (was.isNotEmpty()) applyHzPinHints(it, was, 0f) // T-243
        }
        if (was.isNotEmpty()) MbLog.i("hz_pin", HzPin.logFields(devKnobs.hzPin, false, emptyList()), "render")
    }

    /** [log] false: T-243 re-issues (every touch start / rate change) do not write `ev=set_frame_rate`. */
    private fun setSurfaceFrameRate(on: Boolean, log: Boolean = true) {
        if (Build.VERSION.SDK_INT < 30 || !surfaceValid) return
        // T-046: always an explicit FIXED_SOURCE request at the stream fps (the `frate` override went with the GL path,
        // T-184). On API 31+ also CHANGE_FRAME_RATE_ALWAYS so a seamless-only panel still switches.
        val rate = FrameRatePolicy.surfaceRate(-1, streamConfig?.fps ?: 0).toFloat()
        val compat = Surface.FRAME_RATE_COMPATIBILITY_FIXED_SOURCE
        if (on && rate <= 0f) return
        try {
            val sf = video.holder.surface
            if (Build.VERSION.SDK_INT >= 31) {
                sf.setFrameRate(if (on) rate else 0f, compat, Surface.CHANGE_FRAME_RATE_ALWAYS)
            } else {
                sf.setFrameRate(if (on) rate else 0f, compat)
            }
            if (on && log) MbLog.i("set_frame_rate", "rate=$rate fixed_source=true strategy_always=${Build.VERSION.SDK_INT >= 31}", "render")
        } catch (e: Exception) {
            MbLog.w("set_frame_rate_failed", "err=${e.javaClass.simpleName}", "render")
        }
    }

    /**
     * Fits the SurfaceView to the stream aspect so the surface equals the video area (letterbox = black bands). Within
     * 2 px of the root it fills the root (T-215: the 1848×1214 game display is not exactly the panel's shape).
     */
    private fun layoutVideo() {
        val size = VideoLayout.surfaceSize(root.width, root.height, streamConfig)
        val w = size?.first ?: FrameLayout.LayoutParams.MATCH_PARENT
        val h = size?.second ?: FrameLayout.LayoutParams.MATCH_PARENT
        val lp = video.layoutParams as FrameLayout.LayoutParams
        if (lp.width != w || lp.height != h) {
            lp.width = w
            lp.height = h
            video.layoutParams = lp
        } else {
            // T-221: unchanged params (e.g. MATCH_PARENT before and after a config) cause no relayout, so the
            // layout listener would not run and the input viewport would stay empty: recompute it here.
            updateViewport()
        }
    }

    /** Input viewport = the video view's laid-out rectangle; empty until a stream config exists. */
    private fun updateViewport() {
        val v = video
        val next = if (streamConfig == null || v.width <= 0 || v.height <= 0) VideoViewport(0, 0, 0, 0)
        else VideoViewport.ofRect(v.left, v.top, v.width, v.height)
        viewport = next
        if (::penOverlay.isInitialized) penOverlay.setVideoViewport(viewport)
        if (::capture.isInitialized) syncInputActive()
    }

    /** Every 500 ms: re-request a keyframe while gated; every 1 s: STATS, overlay and log summary. */
    private val ticker = object : Runnable {
        override fun run() {
            if (choreographerOn && vsyncIdle.idleLogDue(System.nanoTime())) { // T-141: once per sleep of >= 1 s
                MbLog.i("idle", "state=on since_frame_ms=${vsyncIdle.sinceActivityNs(System.nanoTime()) / 1_000_000}", "render")
            }
            chromaPipeline?.reap() // T-259: close the readers of a timed-out teardown once its threads exited
            if (directDeferred) {
                // T-259: retry once the stuck presenter exited, but only for the configuration it was requested for
                val c = streamConfig
                if (c == null || !surfaceValid || c.configId != directDeferredConfigId || lastUi !is SessionUi.Connected) {
                    directDeferred = false
                } else attachDirect(video.holder.surface)
            }
            val r = renderer
            if (r != null && r.attached) {
                // T-121: the retry goes through the queue's request limit (no retry right after another request).
                if (videoHealth.keyframeRetriesAllowed && r.takeKeyframeRetry()) controller.trySend(mainKeyframeRequest(KeyframeRequest.STARTUP))
                // T-259: the auxiliary stream's own retry (its own request limit; never gates video_health)
                if (videoHealth.keyframeRetriesAllowed && chromaPipeline?.takeAuxRetry() == true) {
                    controller.trySend(KeyframeRequest(KeyframeRequest.STARTUP, KeyframeRequest.VIEW_AUX))
                }
                val now = SystemClock.elapsedRealtime()
                if (now - lastStatsMs >= 1000) statsTick(r, now)
            }
            // T-159: no-output / not-running timers, the recovery ladder and the debug fault trigger.
            videoHealth.tick(r?.progress?.snapshot())?.let { runVideoRecovery(it) }
            decoderFault?.onTick(videoHealth) // fires only after N s HEALTHY
            ui.postDelayed(this, KEYFRAME_RETRY_MS)
        }
    }

    private fun statsTick(r: VideoRenderer, now: Long) {
        val interval = now - lastStatsMs
        lastStatsMs = now
        val s = r.stats.snapshot(reset = true) // T-141: the closed second also joins the log window
        r.onSkipWindow(s.skipPct)
        val vg = vsyncGaps.summaryInto(vsyncGapsLog)
        refreshMismatch.update( // T-169: one W line per sustained (> 5 s) target vs measured refresh mismatch
            FrameRatePolicy.modeTargetHz(targetHz, streamConfig?.fps ?: 0), vg.p50Us.takeIf { vg.count > 0 },
            started && lastUi is SessionUi.Connected, now,
        )?.let { MbLog.w("refresh_mismatch", it.fields() + " stream_mode=${streamMode.id}", "render") }
        val lat = s.latencyAvgUs
        controller.trySend(StatsFormat.toMessage(s, interval, lat))
        audio?.onVideoLatency(AvSync.videoLatencyUs(lat, s.paceAddAvgUs, vsync.periodNs / 1000)) // T-095 A/V target (median-filtered)
        if (statsOn) {
            val base = StatsFormat.overlay(s, interval, lat, StatsFormat.pacingLine(currentHz(), r.bufferFrames, s.paceAddAvgUs, s.skipPct, s.decode.p95Us.takeIf { s.decode.count > 0 }, r.paceDUs()), clock.uncertaintyUs()) +
                (if (vg.count > 0) " | vsync " + "%.1f".format(java.util.Locale.ROOT, vg.p50Us / 1000.0) + " ms" else "")
            val tr = currentTransport()
            val text = getString(if (tr == Transport.USB) R.string.transport_usb else R.string.transport_wifi) +
                (if (mode == TransportMode.AUTO) " (otomatik)" else "") + "\n" +
                StreamMode.overlayLine(streamMode, gameSettings.fps(streamMode), streamConfig) + "\n" + base
            if (text != lastOverlayText) { // T-141: an idle overlay does not change; skip the relayout and redraw
                lastOverlayText = text
                statsView.text = text
            }
        }
        if (statsLog.due(now)) {
            writeStatsLog(r, now)
            statsLog.start(now)
        }
        // T-089: RTT of this statistics window (PING -> PONG), with the transport it was measured on.
        MbLog.i(
            "net",
            "transport=${currentTransport().logName} " +
                "${rttStats.snapshot(reset = true).fields()} ping_ms=${knobs.pingMs}",
        )
    }

    /**
     * T-141: a stream boundary (it ends or is reconfigured). The unfinished second is closed into the log window and the
     * window is written up to now (see [writeStatsLog]), so nothing of this stream is left in the reused renderer's
     * counters for the next one. No STATS goes out for that partial second.
     */
    private fun flushStatsLog() {
        val r = renderer ?: return
        val now = SystemClock.elapsedRealtime()
        r.stats.closeWindow()
        vsyncGaps.summaryInto(vsyncGapsLog)
        writeStatsLog(r, now)
        lastStatsMs = now
    }

    /** T-259: the full colour fields of one log window (counters reset); layout 0 = dashes (the direct path). */
    private fun chromaStatsFields(): String {
        val p = chromaPipeline
        return if (p != null && p.active) p.statsFields(reset = true)
        else dev.matebridge.client.video.FullChromaStatsFormat.fields(0, null)
    }

    /**
     * T-141: closes the log window at [endMs] (the end of its last per-second window) and writes `MB/render ev=present`,
     * `MB/decoder ev=stats` and `MB/render ev=stats` for it: same fields as the per-second lines, values over the whole
     * window, `interval_ms` = its length. A window without any video frame writes nothing (idle screen). Always starts
     * the counters afresh, also when no window was open.
     */
    private fun writeStatsLog(r: VideoRenderer, endMs: Long) {
        val interval = statsLog.close(endMs)
        val s = r.stats.logSnapshot(reset = true)
        val vg = vsyncGapsLog.summary(reset = true)
        val queueFields = r.queueStatsFields(reset = true)
        val switches = hzSwitches.take() // T-243: always taken, so a skipped window does not carry over
        val write = interval >= 0 && StatsLogWindow.hasFrames(s)
        r.logPresent(write)
        if (!write) return
        val lat = s.latencyAvgUs
        val fps = s.rendered * 1000.0 / interval.coerceAtLeast(1)
        MbLog.i(
            "stats",
            // T-168: released= counts releaseOutputBuffer calls; shown= is its deprecated alias (one release).
            "interval_ms=$interval recv=${s.received} dec=${s.decoded} released=${s.rendered} shown=${s.rendered} drop=${s.dropped} " +
                "decode_avg_us=${s.decodeTimeAvgUs} bytes=${s.bytesReceived} $queueFields",
            "decoder",
        )
        MbLog.i(
            "stats",
            "fps=${"%.1f".format(java.util.Locale.ROOT, fps)} latency_us=${lat ?: -1} " +
                "clock_offset_us=${clock.offsetUs() ?: 0} rtt_us=${clock.bestRttUs() ?: -1} " +
                // T-169: hz= is the deprecated alias of display_hz= (one release); target_hz= is the requested mode.
                RefreshMismatch.statsFields(
                    FrameRatePolicy.modeTargetHz(targetHz, streamConfig?.fps ?: 0), currentHz(), vsync.periodNs / 1000,
                    vg.p50Us.takeIf { vg.count > 0 }, streamMode.id,
                ) + " " +
                "buffer=${r.bufferFrames} skip_pct=${s.skipPct?.let { "%.1f".format(java.util.Locale.ROOT, it) } ?: "-"} " +
                "cb_skip_pct=${s.cbSkipPct?.let { "%.1f".format(java.util.Locale.ROOT, it) } ?: "-"} " +
                "pace_ms=${s.paceAddAvgUs?.let { "%.2f".format(java.util.Locale.ROOT, it / 1000.0) } ?: "-"} " +
                "vsync_ms=${"%.2f".format(java.util.Locale.ROOT, vsync.periodNs / 1e6)} pace_add_ms=${s.paceAddAvgUs?.let { "%.2f".format(java.util.Locale.ROOT, it / 1000.0) } ?: "-"} " +
                StatsFormat.gapFields("net", s.network) + " " + StatsFormat.gapFields("ready", s.ready) + " " +
                StatsFormat.gapFields("shown", s.shown) + " " + StatsFormat.gapFields("dec", s.decode) +
                " pace_d_us=${r.paceDUs()} " +
                // T-168: latency stages from the capture stamp; latency_us= above is the deprecated alias (clamped mean).
                StatsFormat.latencyStageFields(s, r.codecReportsShown, clock.uncertaintyUs()) +
                " hz_switches=$switches" + // T-243
                " " + chromaStatsFields() + // T-259: chroma_layout, aux_paired_pct, aux_late, gl_ms_p50/p95 (+ packed counters)
                pacerKnobsField(), // T-251: once per renderer
            "render",
        )
    }

    override fun onStart() {
        super.onStart()
        started = true
        dev.matebridge.client.session.MbLog.i("activity_start")
        currentEndpoint = null
        manualMode = false
        userDisconnected = false // T-105: a fresh start connects as usual
        forgetNotice = false
        forgetFailed = false
        if (hostSleep.clear()) MbLog.i("host_sleep_clear", "reason=${HostSleepGate.REASON_FOREGROUND}") // T-133
        wolRefresh.reset() // T-133: one USB `wol` refresh per start
        mode = modeOverride ?: settings.transportMode()
        // T-135: also picks up a permission granted meanwhile. T-153: no session yet (the stop ended it): only the idle status
        files.sync(settings.filesShare(), foreground = true, sessionTrusted = false, transport = null)
        refreshSettings()
        hostReached = false
        hideManualEntry() // T-078: every (re)start begins without an editable field on screen
        render(SessionUi.Searching)
        ui.removeCallbacks(ticker)
        ui.postDelayed(ticker, KEYFRAME_RETRY_MS)
        ui.removeCallbacks(inputTicker)
        ui.post(inputTicker)
        if (::idle.isInitialized) idle.restart(SystemClock.uptimeMillis()) // T-234: back from screen-off at full brightness
        (getSystemService(Context.INPUT_SERVICE) as InputManager).registerInputDeviceListener(inputDeviceListener, ui)
        registerCableReceiver()
        applyTransport()
        ui.removeCallbacks(autoTicker)
        ui.postDelayed(autoTicker, AUTO_TICK_MS)
        refreshWakeButton()
        ui.removeCallbacks(wolTicker)
        ui.post(wolTicker)
    }

    /**
     * USB: connect straight to loopback and skip NSD; Wi-Fi: NSD discovery (auto-connect) as before. AUTO (T-096): a short
     * TCP probe of the USB port decides (USB when open, else Wi-Fi); [autoTicker] keeps watching afterwards.
     */
    private fun applyTransport() {
        discovery?.stop()
        discovery = null
        rediscovery.reset() // T-227
        ui.removeCallbacks(usbHintCheck)
        probeGuard.bump()
        picking = false
        transportEpoch++
        fallbackPending = false
        when (mode) {
            TransportMode.WIFI -> { logPick("wifi", "manual"); startWifi() }
            TransportMode.USB -> { logPick("usb", "manual"); startUsb(hint = true, ConnectOrigin.USB_MODE) }
            TransportMode.AUTO -> probeUsb(initial = true)
        }
    }

    private fun logPick(chosen: String, reason: String) = MbLog.i("transport_pick", "mode=${mode.id} chosen=$chosen reason=$reason")

    /** Wi-Fi: NSD discovery (auto-connect). In AUTO a Wi-Fi endpoint already used in this activity is tried at once too. */
    private fun startWifi() {
        manualMode = false
        discovery?.stop()
        rediscovery.reset() // T-227: a fresh discovery run reports every service anyway
        pairPick.clearSeen() // T-151: the new discovery run reports every service again
        discovery = MacDiscovery(this, onTxt = { host, wol, port -> onHostTxt(host, wol, port) }) { ep -> runOnUiThread { onDiscovered(ep) } }
            .also { it.start() }
        if (mode == TransportMode.AUTO) lastWifiEndpoint?.let { connect(it, ConnectOrigin.SAVED_WIFI) }
    }

    /**
     * USB: loopback (`adb reverse`), no NSD. The "USB link missing" hint is for the manual USB mode only. T-151: an
     * automatic [origin] skips a loopback endpoint that already answered PAIRING; "Bağlan" or "Eşleş" goes there.
     */
    private fun startUsb(hint: Boolean, origin: ConnectOrigin) {
        discovery?.stop()
        discovery = null
        manualMode = true
        usbStartMs = SystemClock.elapsedRealtime()
        hostReached = false
        ui.removeCallbacks(usbHintCheck)
        if (hint) ui.postDelayed(usbHintCheck, ConnectMode.USB_TIMEOUT_MS)
        if (!connect(ConnectMode.usbEndpoint, origin)) {
            currentEndpoint = ConnectMode.usbEndpoint // "Bağlan" reconnects it after a user tap
            hostReached = true // the pick prompt (or "Hazır"), not the USB hint
            render(SessionUi.Idle)
        }
    }

    /**
     * A connection-mode choice from either panel. An accepted session that already fits the choice is kept (T-105:
     * AUTO always fits and its policy moves Wi-Fi to USB later; USB/Wi-Fi only on that transport); otherwise the session
     * stops and the transport is applied again (T-096).
     */
    private fun selectTransport(m: TransportMode) {
        val keep = TransportSwitch.keepsSession(m, lastUi is SessionUi.Connected && currentEndpoint != null, currentEndpoint?.let { ConnectMode.transportOf(it) })
        mode = m
        modeOverride = null // a panel choice ends the launch override
        settings.setTransportMode(m)
        refreshSettings()
        MbLog.i("transport_select", "mode=${m.id} keep=${if (keep) 1 else 0}")
        // A running AUTO migration (Wi-Fi -> USB) may not fit the new choice: drop its candidate. One that is promoted
        // anyway is checked against the mode in onMigrationResult().
        if (TransportSwitch.cancelsMigration(m)) controller.cancelMigration()
        if (keep) {
            probeGuard.bump() // a probe started under the old mode reports into nothing (it would leave `picking` set)
            picking = false
            // That probe or migration reports no result now; do not leave the policy waiting for one (STUCK_MS).
            if (autoPolicy.inFlight) autoPolicy.onTryResult(AutoUsbPolicy.Outcome.NEUTRAL, SystemClock.elapsedRealtime())
            return
        }
        reconnectForMode()
    }

    /** Stops the session and applies the selected transport again (T-096 logic). */
    private fun reconnectForMode() {
        userDisconnected = false
        if (hostSleep.clear()) MbLog.i("host_sleep_clear", "reason=${HostSleepGate.REASON_CONNECT}") // T-133: a mode choice is a user action
        currentEndpoint = null
        controller.stop()
        render(SessionUi.Searching)
        applyTransport()
    }

    /** T-135 / T-153: starts or stops the file server for the setting, [foreground] and the session gate. */
    private fun syncFiles(foreground: Boolean = started) =
        files.sync(settings.filesShare(), foreground, filesGate.trusted, filesGate.transport)

    private fun currentTransport(): Transport = currentEndpoint?.let { ConnectMode.transportOf(it) } ?: Transport.WIFI

    private fun isOnUsb(): Boolean = currentEndpoint?.let { ConnectMode.transportOf(it) == Transport.USB } == true

    // ---- T-096 automatic transport ----

    /**
     * TCP connect to the USB control port, closed at once (no HELLO, nothing sent), off the UI thread, <= 500 ms.
     * [initial]: the AUTO pick at start (USB when open, else Wi-Fi); otherwise a rescan while not connected on Wi-Fi
     * (switches to USB only when open).
     */
    private fun probeUsb(initial: Boolean) {
        val exec = probeExec ?: return
        val gen = probeGuard.bump()
        picking = true
        autoPolicy.onTryStarted(SystemClock.elapsedRealtime())
        try {
            exec.execute {
                // T-133: re-checked right before the connect (a queued probe must not reach a Mac that said HOST_SLEEP);
                // a later bump closes this socket while it connects.
                val s = java.net.Socket()
                if (!probeGuard.attach(gen, s)) {
                    try { s.close() } catch (_: java.io.IOException) {}
                    return@execute // stale: its result would be ignored anyway
                }
                val r = try {
                    UsbProbe.classify {
                        s.use { it.connect(java.net.InetSocketAddress(ConnectMode.USB_HOST, ConnectMode.USB_CONTROL_PORT), UsbProbe.TIMEOUT_MS) }
                    }
                } finally {
                    probeGuard.detach(gen)
                }
                runOnUiThread { onProbeResult(gen, r, initial) }
            }
        } catch (e: java.util.concurrent.RejectedExecutionException) {
            picking = false
            autoPolicy.onTryResult(AutoUsbPolicy.Outcome.SOFT_FAIL, SystemClock.elapsedRealtime())
            if (initial) { logPick("wifi", ProbeResult.ERROR.reason); startWifi() }
        }
    }

    private fun onProbeResult(gen: Int, r: ProbeResult, initial: Boolean) {
        if (!probeGuard.isCurrent(gen) || !started || isDestroyed || mode != TransportMode.AUTO) return
        picking = false
        autoPolicy.onTryResult(AutoUsbPolicy.outcomeOf(r), SystemClock.elapsedRealtime())
        val usbBlocked = pairPick.isAsked(ConnectMode.usbEndpoint) // T-151: it answered PAIRING to an automatic connect
        when {
            r == ProbeResult.OPEN && initial && usbBlocked -> { logPick("wifi", "usb_asked"); startWifi() }
            r == ProbeResult.OPEN && initial -> {
                logPick("usb", r.reason)
                startUsb(hint = false, ConnectOrigin.AUTO_SWITCH)
            }
            initial -> { logPick("wifi", r.reason); startWifi() }
            r == ProbeResult.OPEN && !isOnUsb() -> {
                // The rescan started while not connected; the Wi-Fi session may have got further since. Never tear down
                // an accepted session (migrate it instead) and never interrupt a pairing or a running connect.
                val action = AutoUsbPolicy.onProbeOpen(lastUi, usbBlocked)
                MbLog.i("transport_probe", "result=${r.reason} action=${action.name.lowercase(java.util.Locale.ROOT)}")
                when (action) {
                    AutoUsbPolicy.OpenAction.SWITCH -> {
                        logPick("usb", r.reason + " trigger=rescan")
                        startUsb(hint = false, ConnectOrigin.AUTO_SWITCH)
                    }
                    AutoUsbPolicy.OpenAction.MIGRATE -> startMigration(SystemClock.elapsedRealtime())
                    AutoUsbPolicy.OpenAction.IGNORE -> Unit
                }
            }
            else -> Unit // rescan: stay on Wi-Fi
        }
    }

    /** Moves the accepted session to USB via takeover; the result comes back through [onMigrationResult]. */
    private fun startMigration(nowMs: Long) {
        autoPolicy.onTryStarted(nowMs)
        migrateEpoch = transportEpoch
        controller.migrate(ConnectMode.usbEndpoint) // real handshake: refused locally if no `adb reverse`
    }

    /** Every [AUTO_TICK_MS] while started in AUTO: the policy decides whether to try USB now. */
    private val autoTicker = object : Runnable {
        override fun run() {
            autoStep()
            ui.postDelayed(this, AUTO_TICK_MS)
        }
    }

    private fun autoStep() {
        if (!started || isDestroyed || mode != TransportMode.AUTO || picking || fallbackPending || userDisconnected || hostSleep.asleep) return
        val now = SystemClock.elapsedRealtime()
        when (autoPolicy.next(isOnUsb(), AutoUsbPolicy.stageOf(lastUi), now, pairPick.isAsked(ConnectMode.usbEndpoint))) {
            AutoUsbPolicy.Step.MIGRATE -> startMigration(now)
            AutoUsbPolicy.Step.PROBE -> probeUsb(initial = false)
            AutoUsbPolicy.Step.NONE -> Unit
        }
    }

    private fun onMigrationResult(ep: Endpoint, ok: Boolean, reason: String) {
        autoPolicy.onTryResult(AutoUsbPolicy.outcomeOf(ok, reason), SystemClock.elapsedRealtime())
        if (!ok || !started || isDestroyed) return
        // T-105: the user may have picked a mode this transport does not fit while the candidate was being promoted
        // (the cancel came too late): the session is on the wrong transport, so reconnect under the chosen mode.
        if (TransportSwitch.onMigrated(mode, ConnectMode.transportOf(ep)) == TransportSwitch.MigrationVerdict.REJECT_RECONNECT) {
            MbLog.w("transport_migrate_rejected", "to=${ConnectMode.transportOf(ep).logName} mode=${mode.id}")
            reconnectForMode()
            return
        }
        if (migrateEpoch != transportEpoch) return
        currentEndpoint = ep
        if (ConnectMode.transportOf(ep) == Transport.USB) {
            // Now on USB: no Wi-Fi discovery; a later drop falls back to Wi-Fi from render().
            discovery?.stop()
            discovery = null
            manualMode = true
            hostReached = true
            ui.removeCallbacks(usbHintCheck)
            autoPolicy.onUsbConnected()
        }
        logPick(ConnectMode.transportOf(ep).logName, "migrated")
        syncWifiLock("migrated") // T-089 lock: held on Wi-Fi only
    }

    /**
     * T-207: a proven session showed that the Mac behind these asked endpoints trusts the tablet ([PairPick]). In AUTO,
     * when the USB loopback endpoint is among them, USB is tried again at once (probe or migration, as usual).
     */
    private fun onAskedCleared(cleared: List<Endpoint>) {
        MbLog.i("pair_asked_cleared", TrustUiText.askedClearedFields(cleared))
        if (mode == TransportMode.AUTO && ConnectMode.usbEndpoint in cleared && !isOnUsb()) {
            autoPolicy.onUsbUnblocked(SystemClock.elapsedRealtime())
            ui.post { autoStep() } // posted: render() must not start a migration itself
        }
    }

    /** AUTO on USB and the session dropped: go back to Wi-Fi (last Wi-Fi endpoint at once, plus discovery). */
    private fun fallBackToWifi() {
        fallbackPending = false
        if (!started || isDestroyed || !AutoUsbPolicy.shouldFallBack(mode, isOnUsb(), lastUi)) return // T-151: also a pick prompt
        autoPolicy.onTryResult(AutoUsbPolicy.Outcome.HARD_FAIL, SystemClock.elapsedRealtime()) // back off before USB again
        logPick("wifi", AutoUsbPolicy.fallbackReason(lastUi)) // T-207: usb_asked for a PAIRING answer, else usb_lost
        probeGuard.bump()
        picking = false
        transportEpoch++
        ui.removeCallbacks(usbHintCheck)
        currentEndpoint = null
        // No (eligible) Wi-Fi address yet: stop the USB retries, discovery connects.
        if (lastWifiEndpoint?.let { pairPick.allowsAuto(it) } != true) controller.stop()
        startWifi() // with a known Wi-Fi endpoint, its start replaces the USB session at once
    }

    private val cableReceiver = object : android.content.BroadcastReceiver() {
        override fun onReceive(context: Context, intent: android.content.Intent) { onCableIntent(intent) }
    }

    /** USB_STATE and BATTERY_CHANGED are sticky: registering delivers the current state at once. */
    private fun registerCableReceiver() {
        if (cableRegistered) return
        val f = android.content.IntentFilter().apply {
            addAction(ACTION_USB_STATE)
            addAction(android.content.Intent.ACTION_BATTERY_CHANGED)
        }
        try {
            if (Build.VERSION.SDK_INT >= 33) registerReceiver(cableReceiver, f, Context.RECEIVER_NOT_EXPORTED)
            else registerReceiver(cableReceiver, f)
            cableRegistered = true
        } catch (e: RuntimeException) {
            MbLog.w("usb_cable", "state=unknown src=register_failed err=${e.javaClass.simpleName}")
        }
    }

    private fun unregisterCableReceiver() {
        if (!cableRegistered) return
        cableRegistered = false
        try { unregisterReceiver(cableReceiver) } catch (_: IllegalArgumentException) {}
    }

    private fun onCableIntent(i: android.content.Intent) {
        val (changed, src) = when (i.action) {
            ACTION_USB_STATE -> cable.onUsbState(i.getBooleanExtra("connected", false)) to "usb_state"
            android.content.Intent.ACTION_BATTERY_CHANGED ->
                cable.onBattery(i.getIntExtra(android.os.BatteryManager.EXTRA_PLUGGED, 0)) to "battery"
            else -> false to ""
        }
        if (!changed) return
        MbLog.i("usb_cable", "state=${cable.state.logName} src=$src")
        autoPolicy.onCable(cable.state, SystemClock.elapsedRealtime())
    }

    override fun onStop() {
        started = false
        promptVisibility.onStop()?.let { controller.setConfirmPromptVisible(it) } // T-151: the 2-min timer pauses
        ui.removeCallbacks(forgetSettle)
        forgetFlow.abandon() // T-151: a forget result after this is not reported (the next screen shows the real state)
        unbufferedPen.sync(false) // the ticker is stopped below; do not leave the request behind
        dev.matebridge.client.session.MbLog.i("activity_stop")
        ui.removeCallbacks(ticker)
        ui.removeCallbacks(inputTicker)
        (getSystemService(Context.INPUT_SERVICE) as InputManager).unregisterInputDeviceListener(inputDeviceListener)
        discovery?.stop()
        discovery = null
        rediscovery.reset() // T-227
        ui.removeCallbacks(usbHintCheck)
        ui.removeCallbacks(autoTicker)
        ui.removeCallbacks(wolTicker)
        wolStep() // started is false: a running wake episode stops (nothing is sent in the background)
        wolRefreshStep(wolRefresh.cancel()) // T-133
        unregisterCableReceiver()
        probeGuard.bump() // a probe still running reports into nothing
        picking = false
        fallbackPending = false
        transportEpoch++
        renderer?.flushPaceTrace()
        releaseRenderer() // video stops in the background; a fresh session re-requests a keyframe on return
        audio?.endSession("background") // T-095: silence at once and take no more audio; the BYE stops the host
        syncFiles(foreground = false) // T-135: no session in the background, so no file server
        controller.stop() // sends BYE, closes both connections
        syncWifiLock("background") // started is false: always released here
        super.onStop()
    }

    override fun onDestroy() {
        if (benchForwarded) { super.onDestroy(); return } // T-090: nothing below was initialised
        ui.removeCallbacksAndMessages(null)
        releaseRenderer()
        controller.shutdown()
        if (::files.isInitialized) files.shutdown()
        audio?.shutdown()
        wifiLock?.sync(false, "destroy")
        probeExec?.shutdownNow()
        if (::wolSender.isInitialized) wolSender.shutdown()
        super.onDestroy()
    }

    /**
     * T-227: the app searches the Mac by Wi-Fi discovery right now (not a typed address, not USB, not after "Bağlantıyı
     * kes", not while the Mac said HOST_SLEEP). Only then may discovery be restarted or a candidate be left again.
     */
    private fun rediscoveryEligible(): Boolean =
        started && !isDestroyed && discovery != null && !manualMode && !isOnUsb() && !userDisconnected && !hostSleep.asleep

    /** T-227, from [wolTicker]: restart NSD discovery when the session's address keeps failing (next to its retries). */
    private fun rediscoveryStep() {
        if (!rediscovery.shouldRestart(SystemClock.elapsedRealtime(), rediscoveryEligible())) return
        MbLog.i("endpoint_rediscover", "reason=${rediscovery.restartReason()} failures=${rediscovery.failures} restart=${rediscovery.restarts}")
        // The session already retrying the old address was started without an expectation: arm it, so another Mac
        // answering there is refused before HELLO_ACK too (review 2 #1). Idempotent; the wake path is not gated.
        val expect = rediscovery.expectedHost()
        val ep = currentEndpoint
        if (expect != null && ep != null && wakeConnect.owned != ep) controller.expectHost(ep, expect)
        pairPick.clearSeen() // the new run reports every service again (as in startWifi)
        discovery?.restart()
    }

    /**
     * T-227: a candidate address was settled. Accepted: it is the session's address now ([connect] already made it the
     * remembered Wi-Fi endpoint). Foreign / unreachable: try the next queued discovery result (T-229), else go back to
     * the old address (posted after T-151's pick handling: when that already moved the session elsewhere, it is left
     * alone).
     */
    private fun onRediscoveryVerdict(v: EndpointRediscovery.Verdict) {
        val fields = EndpointRediscovery.resultFields(v) ?: return
        MbLog.i("endpoint_rediscover_result", fields)
        val (old, left) = when (v) {
            is EndpointRediscovery.Verdict.Foreign -> v.old to v.foreign
            is EndpointRediscovery.Verdict.Unreachable -> v.old to v.candidate
            else -> return
        }
        ui.post {
            // Not after a user start (it ended the episode) or once the session moved on.
            if (!(rediscovery.active && rediscoveryEligible() && currentEndpoint == left)) return@post
            val next = rediscovery.nextQueued { pairPick.allowsAuto(it) } // T-229: another Mac found meanwhile
            if (next != null) {
                MbLog.i("endpoint_rediscover_found", "old=${EndpointRediscovery.octet(old)} new=${EndpointRediscovery.octet(next)}")
                connect(next, ConnectOrigin.DISCOVERY)
            } else {
                connect(old, ConnectOrigin.DISCOVERY)
            }
        }
    }

    private fun onDiscovered(ep: Endpoint) {
        if (!started || manualMode || userDisconnected || hostSleep.asleep) return
        // T-227: an address that answered as another host in this rediscovery episode is dropped before anything
        // remembers it (review #3: T-151's pick fallback must not pick it up either).
        // During an episode a new address is tried at once (CONNECT), also while the old one is still connecting.
        val pick = rediscovery.onDiscovered(ep, currentEndpoint, lastUi)
        if (pick == EndpointRediscovery.Pick.SKIP) {
            MbLog.i("endpoint_rediscover_skip", "new=${EndpointRediscovery.octet(ep)}")
            return
        }
        pairPick.onDiscovered(ep) // T-151: remembered, so a pick prompt does not hide it (NSD reports a service once)
        if (pick == EndpointRediscovery.Pick.QUEUED) return // T-229: a candidate is being tried; this one waits its turn
        if (!pairPick.allowsAuto(ep)) { // it answered PAIRING already: only a user start goes there again
            if (pick == EndpointRediscovery.Pick.CONNECT) rediscovery.forgetCandidate(ep)
            return
        }
        // T-134: discovery wins over a direct wake attempt (it replaces it; the start closes it first, one connection).
        // T-151: a pick prompt holds no connection, so another Mac is tried (an impostor must not park the tablet).
        val usual = wakeConnect.onDiscovered(currentEndpoint, lastUi is SessionUi.Disconnected, lastUi is SessionUi.PairingNeedsUser)
        if (pick == EndpointRediscovery.Pick.CONNECT) {
            MbLog.i("endpoint_rediscover_found", "old=${EndpointRediscovery.octet(rediscovery.old)} new=${EndpointRediscovery.octet(ep)}")
        }
        if (usual || pick == EndpointRediscovery.Pick.CONNECT) connect(ep, ConnectOrigin.DISCOVERY)
    }

    private fun onConnectClicked() {
        val typed = endpointField.text.toString()
        val wasAsleep = hostSleep.clear() // T-133: "Bağlan" is a user action; the normal flow (wake included) starts
        if (wasAsleep) MbLog.i("host_sleep_clear", "reason=${HostSleepGate.REASON_CONNECT}")
        // T-134: while the Mac sleeps, "Bağlan" is "Mac'i uyandır" (wake episode + direct connect) unless an address was
        // typed into the open manual field; a hidden field's remembered text does not count.
        val typedNow = typed.isNotBlank() && (!wasAsleep || endpointField.visibility == View.VISIBLE)
        // T-151: "Bağlan" is a user start for the pick gate; only a typed address in the open field may pair at once.
        val origin = ConnectOrigin.forConnectButton(typed, endpointField.visibility == View.VISIBLE, lastUi)
        if (origin.clearsGate) pairPick.onUserStart()
        if ((userDisconnected || wasAsleep) && !typedNow) { // T-105: after "Bağlantıyı kes", connect the chosen mode's usual way
            userDisconnected = false
            hideManualEntry()
            restartUsualWay()
            if (wasAsleep) wolStep(manual = true) // T-134: the same path as "Mac'i uyandır"
            return
        }
        userDisconnected = false
        val ep = if (typed.isBlank()) currentEndpoint else Endpoint.parse(typed)
        if (ep == null && typed.isBlank()) { // T-151: nothing chosen (e.g. after "Yoksay"): search the usual way again
            hideManualEntry()
            restartUsualWay()
            return
        }
        if (ep == null) {
            Toast.makeText(this, R.string.invalid_endpoint, Toast.LENGTH_SHORT).show()
            return
        }
        if (typed.isNotBlank()) {
            manualMode = true
            settings.saveEndpoint(ep)
        }
        hideManualEntry() // T-078: no focused field once the stream may start
        connect(ep, origin)
        if (wasAsleep) wolStep(manual = true) // T-134: a typed address while the Mac sleeps still gets a wake episode
    }

    /**
     * After "Bağlantıyı kes" or "Mac uyku modunda": search/connect the chosen mode's usual way. The old endpoint is
     * forgotten first (T-134): otherwise a discovered Mac was ignored in Wi-Fi mode (NOTES 2026-10-02 ~15:20).
     */
    private fun restartUsualWay() {
        currentEndpoint = null
        render(SessionUi.Searching)
        applyTransport()
    }

    /**
     * Starts a session to [ep]. T-151 (decision 0018): only a [ConnectOrigin.userInitiated] start may pair; an
     * [ConnectOrigin.automatic] one to an endpoint that already answered PAIRING is skipped (returns false).
     */
    private fun connect(ep: Endpoint, origin: ConnectOrigin): Boolean {
        if (origin.automatic && !pairPick.allowsAuto(ep)) {
            MbLog.i("pair_auto_skip", "origin=${origin.logName}")
            return false
        }
        wakeConnect.disown() // T-134: an ordinary session from here, even to the same address
        // T-227: the user's choice ends a rediscovery episode; T-229: another Mac also drops the remembered identity.
        if (!origin.automatic) rediscovery.onUserStart(ep)
        currentEndpoint = ep
        forgetNotice = false
        forgetFailed = false
        transportEpoch++ // a migration started before this new session reports into nothing (onMigrationResult)
        if (ConnectMode.transportOf(ep) == Transport.WIFI) lastWifiEndpoint = ep
        MbLog.i("transport", "transport=${ConnectMode.transportOf(ep).logName} origin=${origin.logName}")
        // T-227: during a rediscovery episode every automatic start (candidate, way back, T-151's pick fallback) may reach
        // only the host of the last authenticated session; the machine refuses any other one before HELLO_ACK.
        val expect = if (origin.automatic) rediscovery.expectedHost() else null
        controller.start(ep, userInitiated = origin.userInitiated, expectHost = expect)
        return true
    }

    private fun render(state: SessionUi) {
        if (::clipboard.isInitialized) {
            val was = clipboard.sync.accepted
            clipboard.sync.onSessionAccepted(state is SessionUi.Connected, System.currentTimeMillis(), MbLog.gen)
            if (!was && clipboard.sync.accepted) clipboard.recheck() // T-063: copied while the session was down
        }
        val filesChanged = filesGate.onUi(state is SessionUi.Connected) // T-153: also while stopped (trust drops)
        if (!started || isDestroyed) {
            syncWifiLock("stopped")
            return
        }
        lastUi = state
        if (filesChanged) syncFiles()
        syncWifiLock(state.javaClass.simpleName.lowercase(java.util.Locale.ROOT))
        if (hostSleep.onUi(state)) enterHostSleep() // T-133
        wolStep() // T-129: reaching the host stops a wake episode at once
        wolRefreshStep(wolRefresh.onSession(state is SessionUi.Connected && isOnUsb(), SystemClock.elapsedRealtime()) {
            wolSender.wifiSubnets().isNotEmpty()
        }) // T-133
        if (TrustUiText.hostReached(state)) hostReached = true // terminal errors and prompts must not be replaced by the USB hint
        promptVisibility.onRender(state, started)?.let { controller.setConfirmPromptVisible(it) } // T-151: T-150's timer
        if (pairPick.onUi(state)) ui.post { tryNextAfterPick() } // T-151: never parked on one answerer's prompt
        onRediscoveryVerdict(rediscovery.onUi(state, currentEndpoint, SystemClock.elapsedRealtime())) // T-227
        pairPick.takeCleared().takeIf { it.isNotEmpty() }?.let { onAskedCleared(it) } // T-207: that Mac now trusts us
        forgetFlow.onUi(state, SystemClock.elapsedRealtime())?.let { onForgetResult(it) } // T-151: the forget's result
        // T-096: AUTO on USB that lost its session falls back to Wi-Fi (posted: render() must not restart the session itself).
        if (state is SessionUi.Connected && isOnUsb()) autoPolicy.onUsbConnected()
        if (!fallbackPending && AutoUsbPolicy.shouldFallBack(mode, isOnUsb(), state)) {
            fallbackPending = true
            ui.post { fallBackToWifi() }
        }
        if (state !is SessionUi.Connected) releaseRenderer()
        val streaming = state is SessionUi.Connected && state.framesReceived > 0 && renderer != null
        if (streaming && panel.visibility != View.GONE) hideManualEntry() // T-078: before the panel goes away
        panel.visibility = if (streaming) View.GONE else View.VISIBLE
        syncVideoFaultOverlay() // T-159: only over the video, never over the connect panel
        if (!streaming) closeSettingsPanel(SettingsPanelState.Via.STREAM_END, resync = false) // T-105; synced below
        applyStatusText(state)
        syncInputActive() // panel visibility decides whether input is captured
    }

    private fun applyStatusText(state: SessionUi) {
        val trust = TrustUiText.screen(state, pairPick.prompt) // T-151
        status.text = when (state) {
            SessionUi.Idle ->
                if (forgetNotice) getString(R.string.forget_done)
                else if (userDisconnected) USER_DISCONNECTED_TEXT else getString(R.string.state_idle)
            SessionUi.Searching -> getString(R.string.state_searching)
            is SessionUi.Connecting -> getString(R.string.state_connecting, state.endpoint.toString())
            is SessionUi.AwaitingApproval -> getString(R.string.state_awaiting_approval, state.hostName) // code: trust view
            is SessionUi.Connected -> getString(R.string.state_connected, state.hostName, state.framesReceived)
            is SessionUi.PairingNeedsUser -> getString(R.string.state_idle) // the pick prompt below while it is pending
            is SessionUi.StoredTrust -> "" // trust view below
            is SessionUi.Disconnected -> getString(
                R.string.state_disconnected, causeText(state.cause), (state.retryInMs + 999) / 1000,
            )
            is SessionUi.Failed ->
                if (state.cause == SessionUi.Cause.HOST_SLEEP) {
                    getString(if (wolStore.hasMacs()) R.string.state_host_sleep else R.string.state_host_sleep_no_wol)
                } else if (state.cause == SessionUi.Cause.KEY_STORE_FAILED && forgetFailed) getString(R.string.forget_failed)
                else if (state.cause == SessionUi.Cause.KEY_MISSING) KEY_MISSING_TEXT
                else if (state.cause == SessionUi.Cause.KEY_STORE_FAILED) KEY_STORE_FAILED_TEXT
                else if (state.cause == SessionUi.Cause.KEY_MISMATCH) getString(R.string.key_mismatch) // T-156
                else getString(R.string.state_failed, causeText(state.cause))
        }
        // T-151: a trust state replaces its usual text; a pending pick prompt is a banner under the state's text.
        if (trust != null) status.text = trustText(trust, if (TrustUiText.view(state) != null) null else status.text)
        renderTrustButtons(trust?.buttons.orEmpty())
        if (ConnectMode.showUsbHint(mode, SystemClock.elapsedRealtime() - usbStartMs, hostReached)) {
            status.text = getString(R.string.usb_missing)
        }
        if (wolPlanner.active && !WakePlanner.reached(state)) status.text = getString(R.string.wol_waking) // T-129
    }

    // ---- T-129 Wake-on-LAN ----

    /** NSD thread: remembers the host's TXT `wol` addresses, its IPv4 and the home Wi-Fi subnet (none of them logged). */
    private fun onHostTxt(host: String, wol: String?, port: Int) {
        val subnet = HomeNetwork.pick(wolSender.wifiSubnets(), host)
        if (!wolStore.onResolved(host, wol, subnet, port)) return // T-134: the control port is stored with the host
        MbLog.i("wol_stored", "macs=${wolStore.macs().size} home=${if (wolStore.subnet() != null) 1 else 0}")
        runOnUiThread { refreshWakeButton() }
    }

    private fun refreshWakeButton() {
        if (!::wakeButton.isInitialized) return
        wakeButton.visibility = if (wolStore.hasMacs()) View.VISIBLE else View.GONE
    }

    /** Every [WOL_TICK_MS] while started: the planner decides whether to start, send or stop. */
    private val wolTicker = object : Runnable {
        override fun run() {
            wolStep()
            wolRefreshStep(wolRefresh.tick(SystemClock.elapsedRealtime())) // T-133
            rediscoveryStep() // T-227
            ui.postDelayed(this, WOL_TICK_MS)
        }
    }

    /** "Mac'i uyandır": after "Bağlantıyı kes" it also connects again the chosen mode's usual way (like "Bağlan"). */
    private fun onWakeClicked() {
        MbLog.i("wol_manual", "active=${if (wolPlanner.active) 1 else 0}")
        val wasAsleep = hostSleep.clear() // T-133: wake + connect the usual way
        if (wasAsleep) MbLog.i("host_sleep_clear", "reason=${HostSleepGate.REASON_WAKE}")
        if (userDisconnected || wasAsleep) {
            userDisconnected = false
            hideManualEntry()
            restartUsualWay()
        }
        wolStep(manual = true)
    }

    private fun wolStep(manual: Boolean = false) {
        if (!::wolStore.isInitialized || !::wolSender.isInitialized) return
        val now = SystemClock.elapsedRealtime()
        val foreground = started && !isDestroyed
        val reached = WakePlanner.reached(lastUi)
        val wasActive = wolPlanner.active
        val steps = if (manual) wolPlanner.manual(now, reached, wolStore.hasMacs())
        else wolPlanner.update(now, foreground, userDisconnected, reached, wolStore.hasMacs(), hostSleep.asleep) {
            HomeNetwork.skipReason(wolStore.subnet(), wolSender.wifiSubnets()) // automatic wake only on the home Wi-Fi
        }
        for (step in steps) when (step) {
            is WakePlanner.Step.Start -> wolSender.start(step.reason, wolStore.macs(), wolStore.host())
            WakePlanner.Step.Send -> wolSender.send()
            is WakePlanner.Step.Stop -> wolSender.stop(step.reason)
            is WakePlanner.Step.Skip -> MbLog.i("wol_skip", "reason=${step.reason}")
        }
        if (wasActive != wolPlanner.active && foreground) applyStatusText(lastUi)
        wakeConnectStep()
    }

    /**
     * T-134: inside a wake episode, direct session attempts to the stored host IPv4:port (they dark-wake the Mac where
     * magic packets do not). Never outside an episode, so never in the background, after "Bağlantıyı kes" or while the
     * Mac said HOST_SLEEP.
     */
    private fun wakeConnectStep() {
        val now = SystemClock.elapsedRealtime()
        val episode = wolPlanner.active && started && !isDestroyed && !userDisconnected && !hostSleep.asleep
        val ui = lastUi
        val idle = ui is SessionUi.Disconnected || ui == SessionUi.Idle || ui == SessionUi.Searching
        val transportOk = WakeConnect.transportAllows(mode, isOnUsb(), picking || fallbackPending) && !manualMode
        val target = wolStore.wakeEndpoint()?.takeIf { pairPick.allowsAuto(it) } // T-151: not to an endpoint that asked to pair
        when (val step = wakeConnect.update(now, episode, target, currentEndpoint, transportOk, idle)) {
            WakeConnect.Step.None -> Unit
            is WakeConnect.Step.Attempt -> {
                currentEndpoint = step.endpoint
                transportEpoch++ // as in connect(): a migration started before this session reports into nothing
                MbLog.i("transport", "transport=${ConnectMode.transportOf(step.endpoint).logName} via=wake")
                controller.start(step.endpoint, step.tag, userInitiated = ConnectOrigin.WAKE.userInitiated)
            }
            WakeConnect.Step.Release -> {
                // The episode ended and our last attempt failed: no endpoint is chosen any more (discovery may connect).
                currentEndpoint = null
                if (started && !isDestroyed && !userDisconnected && !hostSleep.asleep) render(SessionUi.Searching)
            }
        }
    }

    /** T-134: the connect of a direct wake attempt finished (the session machine follows with its own state). */
    private fun onWakeConnectResult(wake: WakeTag, ok: Boolean) {
        val adopted = wakeConnect.onResult(wake, ok, SystemClock.elapsedRealtime())
        if (adopted != null && adopted == currentEndpoint) {
            lastWifiEndpoint = adopted // an ordinary Wi-Fi session from here (AUTO may later move it to USB)
        }
        wolStep()
    }

    // ---- T-133 host sleep ----

    /**
     * BYE(HOST_SLEEP): the session machine already closed both connections without a retry. Stop everything else that
     * could reach the Mac (discovery, a USB probe, the TXT refresh); the wake planner holds via [hostSleep] in [wolStep].
     */
    private fun enterHostSleep() {
        MbLog.i("host_sleep", "transport=${currentTransport().logName}")
        discovery?.stop()
        discovery = null
        ui.removeCallbacks(usbHintCheck)
        probeGuard.bump() // a queued USB probe never connects; one connecting has its socket closed
        picking = false
        fallbackPending = false
        wolRefreshStep(wolRefresh.cancel())
    }

    /** Runs a [WolRefresh] step: the TXT-only discovery never connects (its onFound is ignored). */
    private fun wolRefreshStep(step: WolRefresh.Step) {
        when (step) {
            WolRefresh.Step.None -> Unit
            WolRefresh.Step.Start -> {
                MbLog.i("wol_refresh_start", "duration_ms=${WolRefresh.DURATION_MS}")
                wolRefreshDiscovery?.stop()
                wolRefreshDiscovery = MacDiscovery(
                    this,
                    onTxt = { host, wol, port ->
                        onHostTxt(host, wol, port) // stores it (NSD thread), as Wi-Fi discovery does
                        runOnUiThread { wolRefreshStep(wolRefresh.onTxt(wol)) }
                    },
                ) { _ -> }.also { it.start() }
            }
            is WolRefresh.Step.Finish -> {
                wolRefreshDiscovery?.stop()
                wolRefreshDiscovery = null
                MbLog.i("wol_refresh", "result=${step.result.logName}")
            }
        }
    }

    // ---- T-151 trust UI (decision 0018) ----

    /**
     * The trust text: [TrustUiText] decides what, `strings.xml` says it. [above]: the state's own text when [v] is the
     * pick prompt shown as a banner under it. The pairing code is shown large and never logged.
     */
    private fun trustText(v: TrustView, above: CharSequence?): CharSequence {
        val b = SpannableStringBuilder()
        if (!above.isNullOrEmpty()) b.append(above).append("\n\n")
        v.lines.forEachIndexed { i, line ->
            if (i > 0) b.append(if (line is TrustLine.Code || v.lines[i - 1] is TrustLine.Code) "\n" else "\n\n")
            val start = b.length
            when (line) {
                is TrustLine.Code -> {
                    val code = line.code
                    b.append(if (code.length == 6) code.substring(0, 3) + " " + code.substring(3) else code)
                    b.setSpan(RelativeSizeSpan(3.5f), start, b.length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
                    b.setSpan(StyleSpan(Typeface.BOLD), start, b.length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
                }
                is TrustLine.Text -> {
                    val arg = line.arg
                    b.append(if (arg != null) getString(trustRes(line.id), arg) else getString(trustRes(line.id)))
                    if (line.id == TrustText.KEY_CHANGED) {
                        b.setSpan(ForegroundColorSpan(Color.parseColor("#FFB300")), start, b.length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
                    }
                }
            }
        }
        return b
    }

    private fun trustRes(t: TrustText) = when (t) {
        TrustText.KEY_CHANGED -> R.string.trust_key_changed
        TrustText.COMPARE_CODE -> R.string.trust_compare_code
        TrustText.CONFIRM_HINT -> R.string.trust_confirm_hint
        TrustText.PARSEC_HINT -> R.string.trust_parsec_hint
        TrustText.WAIT_MAC_ALLOW -> R.string.trust_wait_mac_allow
        TrustText.STORED_CODE -> R.string.trust_stored_code
        TrustText.STORED_CONFIRMED -> R.string.trust_stored_confirmed
        TrustText.NEW_HOST_CLAIM -> R.string.trust_new_host_claim
        TrustText.RE_PAIR_CLAIM -> R.string.trust_re_pair_claim
        TrustText.PAIR_CANCELLED -> R.string.trust_pair_cancelled
        TrustText.FORGET_DONE -> R.string.forget_done
        TrustText.FORGET_NONE -> R.string.forget_none
        TrustText.FORGET_FAILED -> R.string.forget_failed
    }

    private fun trustButtonRes(b: TrustButton) = when (b) {
        TrustButton.CONFIRM -> R.string.trust_btn_confirm
        TrustButton.CANCEL -> R.string.trust_btn_cancel
        TrustButton.PAIR -> R.string.trust_btn_pair
        TrustButton.IGNORE -> R.string.trust_btn_ignore
        TrustButton.REPAIR -> R.string.trust_btn_repair
        TrustButton.CONNECT -> R.string.trust_btn_connect
    }

    /** The trust row under the status text; while it has buttons the plain "Bağlan" is hidden (it would not pair). */
    private fun renderTrustButtons(buttons: List<TrustButton>) {
        if (buttons != trustButtons) {
            trustButtons = buttons
            trustRow.removeAllViews()
            val gap = (8 * resources.displayMetrics.density).roundToInt()
            for (b in buttons) {
                val btn = Button(this).apply {
                    text = getString(trustButtonRes(b))
                    setOnClickListener { onTrustButton(b) }
                }
                trustRow.addView(
                    btn,
                    LinearLayout.LayoutParams(LinearLayout.LayoutParams.WRAP_CONTENT, LinearLayout.LayoutParams.WRAP_CONTENT)
                        .apply { setMargins(gap, 2 * gap, gap, 0) },
                )
            }
        }
        trustRow.visibility = if (buttons.isEmpty()) View.GONE else View.VISIBLE
        connectButton.visibility = if (buttons.isEmpty()) View.VISIBLE else View.GONE
    }

    private fun onTrustButton(b: TrustButton) {
        if (!started || isDestroyed) return
        MbLog.i("pair_ui", TrustUiText.pairUiFields(b.logAction)) // the action only: never the code or the Mac name
        when (b) {
            TrustButton.CONFIRM -> trustConfirm()
            TrustButton.CANCEL -> trustCancel()
            TrustButton.PAIR -> onPairClicked()
            TrustButton.IGNORE -> {
                // The prompt goes and the ordinary screen (with "Bağlan") comes back. The prompt held no connection, so
                // its endpoint is dropped here: discovery, wake and AUTO go on to other Macs, and the ignored one stays
                // out of automatic connects until a user start (PairPick).
                pairPick.ignore()
                if (lastUi is SessionUi.PairingNeedsUser) {
                    currentEndpoint = null
                    render(TrustUiText.afterIgnore(discovery != null))
                } else {
                    applyStatusText(lastUi) // a banner under another state: that state stays
                }
            }
            TrustButton.REPAIR -> userStartStored(ConnectOrigin.STORED_REPAIR)
            TrustButton.CONNECT -> userStartStored(ConnectOrigin.STORED_CONNECT)
        }
    }

    /**
     * "Kodlar aynı — Güven" (T-150 `confirmTrust`): on a live prompt it trusts the key; on a stored one it promotes the
     * pending key and the machine connects, user-initiated, to the endpoint of the blocked start. It applies only to the
     * prompt on screen ([lastUi] is what was rendered): its generation goes along, a stale one is ignored.
     */
    private fun trustConfirm(): Boolean = controller.confirmTrust(TrustUiText.promptGen(lastUi))

    /**
     * "İptal" (T-150 `cancelTrust`): BYE + close a live pairing, drop the pending key, terminal PAIR_CANCELLED (latched:
     * no automatic start until a user one), for the prompt on screen only.
     */
    private fun trustCancel(): Boolean = controller.cancelTrust(TrustUiText.promptGen(lastUi))

    /** "Eşleş": a user start (may pair) to the endpoint that answered PAIRING. */
    private fun onPairClicked() {
        val p = pairPick.pair() ?: return
        userDisconnected = false
        if (hostSleep.clear()) MbLog.i("host_sleep_clear", "reason=${HostSleepGate.REASON_CONNECT}")
        hideManualEntry()
        if (ConnectMode.transportOf(p.endpoint) == Transport.USB) {
            startUsb(hint = mode == TransportMode.USB, ConnectOrigin.PAIR) // no Wi-Fi discovery beside a USB pairing
        } else {
            connect(p.endpoint, ConnectOrigin.PAIR)
        }
    }

    /** "Yeniden eşleş" / "Bağlan" on a stored prompt: a user start to the endpoint whose automatic start was blocked. */
    private fun userStartStored(origin: ConnectOrigin) {
        val ep = currentEndpoint
        if (ep == null) {
            // Not expected (the stored prompt comes from a start to an endpoint): a confirmed one still connects.
            if (origin == ConnectOrigin.STORED_CONNECT) trustConfirm()
            return
        }
        userDisconnected = false
        connect(ep, origin)
    }

    /** A pick prompt holds no connection: try another discovered Mac at once (never the one that asked to pair). */
    private fun tryNextAfterPick() {
        if (!started || isDestroyed || manualMode || userDisconnected || hostSleep.asleep || discovery == null) return
        if (lastUi !is SessionUi.PairingNeedsUser) return
        // T-227: never an address that answered as another host in this rediscovery episode (review #3).
        pairPick.nextAuto()?.takeUnless { rediscovery.isSkipped(it) }?.let { connect(it, ConnectOrigin.DISCOVERY) }
    }

    /** "Bu Mac'i unut" from either settings panel: two confirmations, then [SessionController.forgetCurrentHost]. */
    private fun onForgetHostClicked() {
        forgetFlow.open()
        showForgetDialog()
    }

    private fun showForgetDialog() {
        val first = forgetFlow.step == ForgetFlow.Step.ASK_FIRST
        android.app.AlertDialog.Builder(this)
            .setTitle(R.string.forget_host)
            .setMessage(if (first) R.string.forget_ask_first else R.string.forget_ask_second)
            .setPositiveButton(if (first) R.string.forget_yes_first else R.string.forget_yes_second) { _, _ -> onForgetConfirmed() }
            .setNegativeButton(R.string.forget_no) { _, _ -> forgetFlow.cancel() }
            .setOnCancelListener { forgetFlow.cancel() }
            .show()
    }

    private fun onForgetConfirmed() {
        if (isDestroyed) return
        if (forgetFlow.step == ForgetFlow.Step.ASK_SECOND) MbLog.i("pair_ui", TrustUiText.pairUiFields("forget"))
        when (forgetFlow.confirm(SystemClock.elapsedRealtime())) {
            null -> when (forgetFlow.step) {
                ForgetFlow.Step.ASK_SECOND -> showForgetDialog()
                ForgetFlow.Step.WAITING -> { // queued only (T-150): the result comes as a UI state, see onForgetResult
                    ui.removeCallbacks(forgetSettle)
                    ui.postDelayed(forgetSettle, ForgetFlow.SETTLE_MS + 50)
                }
                else -> Unit
            }
            else -> Toast.makeText(this, R.string.forget_none, Toast.LENGTH_LONG).show()
        }
    }

    /** The forget's result: done -> like "Bağlantıyı kes" with the done text; failed -> the failure text (retry). */
    private fun onForgetResult(t: TrustText) {
        ui.removeCallbacks(forgetSettle)
        if (t == TrustText.FORGET_FAILED) {
            forgetNotice = false
            forgetFailed = true
            MbLog.w("pair_ui_forget_failed")
            if (started && !isDestroyed) applyStatusText(lastUi)
            return
        }
        // T-150 already ended a live session (BYE + close) before the records went; now no automatic reconnect (it
        // would only meet the Mac's stale approval) until the user connects again. Posted: render() may be running.
        ui.post {
            if (!started || isDestroyed) return@post
            forgetNotice = true
            userDisconnect()
        }
    }

    private companion object {
        /** T-090 bench, in the debug source set only (T-185): main code may not reference the class. */
        const val NET_BENCH_ACTIVITY = "dev.matebridge.client.bench.NetBenchActivity"
        const val RESET_DONE_TEXT =
            "Ayarlar varsayılana döndü (eşleşme korundu). Öğrenilen ses ayarları bir sonraki ses akışında sıfırlanır."
        const val KEY_STORE_FAILED_TEXT = "Eşleşme anahtarı kaydedilemedi — Mac'te 'Onaylı cihazları unut' deyip yeniden bağlan."
        const val KEY_MISSING_TEXT = "Mac bu tableti tanımıyor. Mac'te 'Onaylı cihazları unut' deyip yeniden bağlan."
        const val USER_DISCONNECTED_TEXT = "Bağlantı kesildi. Yeniden bağlanmak için Bağlan'a dokun."
        const val KEYFRAME_RETRY_MS = 500L
        const val RATE_POLL_MS = 100L
        const val INPUT_TICK_MS = 25L
        /** T-234: window brightness of the idle dim stage (decision 0031: visible but very dark on the OLED). */
        const val IDLE_DIM_BRIGHTNESS = 0.03f
        const val POINTER_CAPTURE_RETRY_MS = 500L
        const val INPUT_FAULT_BACKOFF_MS = 1000L
        const val AUTO_TICK_MS = 500L // T-096; attempts themselves are >= 2 s apart (AutoUsbPolicy)
        const val WOL_TICK_MS = 250L // T-129; sends themselves are WakePlanner.INTERVAL_MS apart
        /** `UsbManager.ACTION_USB_STATE` (hidden constant, sticky system broadcast; extra `connected`). */
        const val ACTION_USB_STATE = "android.hardware.usb.action.USB_STATE"
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
            SessionUi.Cause.WRONG_HOST -> R.string.cause_connect_failed // T-227: brief; the app goes back to the old address
            SessionUi.Cause.KEY_MISSING, SessionUi.Cause.KEY_STORE_FAILED, SessionUi.Cause.PAIR_CANCELLED,
            SessionUi.Cause.KEY_MISMATCH ->
                R.string.cause_protocol_error // own texts in applyStatusText() (PAIR_CANCELLED: the trust view)
            SessionUi.Cause.HOST_SLEEP -> R.string.cause_host_sleep
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
            Capabilities.TOUCHPAD or Capabilities.TOUCH or Capabilities.DECODE_H264 or Capabilities.DECODE_HEVC or
            (if (audioAllowed) Capabilities.AUDIO_PCM else 0) or // T-095
            Capabilities.SETTINGS_PANEL or // T-105: handles SETTINGS_OPEN
            Capabilities.FILES // T-135: sends FILES_INFO (OFF until the user enables the file server)
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
