package dev.matebridge.client

import android.app.Activity
import android.content.Context
import android.os.Build
import android.os.Bundle
import android.view.View
import android.view.WindowManager
import android.widget.Button
import android.widget.EditText
import android.widget.TextView
import android.widget.Toast
import dev.matebridge.client.protocol.Capabilities
import dev.matebridge.client.protocol.Bytes
import dev.matebridge.client.protocol.Hello
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
 * Connection screen for T-012: discovery (or manual IP:port), session state, received-frame counter.
 * Session logic lives in dev.matebridge.client.session; this class only wires it to views.
 * Video rendering (T-013) and input capture come later.
 */
class MainActivity : Activity() {
    private lateinit var status: TextView
    private lateinit var endpointField: EditText
    private lateinit var settings: Settings
    private lateinit var controller: SessionController
    private var discovery: MacDiscovery? = null

    // Main-thread state
    private var currentEndpoint: Endpoint? = null
    private var manualMode = false
    private var started = false
    private var lastUi: SessionUi = SessionUi.Searching

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        setContentView(R.layout.activity_main)
        status = findViewById(R.id.status)
        endpointField = findViewById(R.id.endpoint)
        val prefs = getSharedPreferences("matebridge", Context.MODE_PRIVATE)
        settings = Settings(object : KeyValueStore {
            override fun getString(key: String) = prefs.getString(key, null)
            override fun putString(key: String, value: String) { prefs.edit().putString(key, value).apply() }
        })
        settings.lastEndpoint()?.let { endpointField.setText(it.toString()) }
        findViewById<Button>(R.id.connect).setOnClickListener { onConnectClicked() }

        controller = SessionController(buildHello(), object : SessionListener {
            override fun onUi(state: SessionUi) { runOnUiThread { render(state) } }
        })
        @Suppress("DEPRECATION")
        status.systemUiVisibility = (View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY
            or View.SYSTEM_UI_FLAG_FULLSCREEN
            or View.SYSTEM_UI_FLAG_HIDE_NAVIGATION
            or View.SYSTEM_UI_FLAG_LAYOUT_STABLE)
        render(SessionUi.Searching)
    }

    override fun onStart() {
        super.onStart()
        started = true
        currentEndpoint = null
        manualMode = false
        render(SessionUi.Searching)
        discovery = MacDiscovery(this) { ep -> runOnUiThread { onDiscovered(ep) } }.also { it.start() }
    }

    override fun onStop() {
        started = false
        discovery?.stop()
        discovery = null
        controller.stop() // sends BYE, closes both connections
        super.onStop()
    }

    override fun onDestroy() {
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
        lastUi = state
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
