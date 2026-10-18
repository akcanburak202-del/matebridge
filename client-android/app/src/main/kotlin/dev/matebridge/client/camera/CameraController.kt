package dev.matebridge.client.camera

import dev.matebridge.client.protocol.CameraControl

/**
 * The tablet camera's state machine (T-355, decision 0040): it joins the Mac's wish (`CAMERA_CONTROL`), the user's wish
 * (mode and facing), the runtime permission, the app being in the foreground and the session being alive, and starts or
 * stops one [CameraRun] accordingly. No threads, no Android types: everything real sits behind [CameraRunFactory].
 *
 * The camera runs only while ALL of these hold: the Mac's last word is START (a `cam_id`), the mode is Otomatik, the
 * permission is granted, the app is in the foreground and the session that START belongs to is alive. When any of them
 * drops, the run is closed at once (camera, encoder, GL, socket, threads). A START that is only held back by the
 * foreground rule reopens the same `cam_id` when the app returns. With no START (or mode Kapalı) nothing exists: the
 * factory is never called.
 *
 * Thread-safe (one lock); [CameraRunFactory.start] must not block (see [CameraPipeline]).
 */
class CameraController(
    private val factory: CameraRunFactory,
    private val permissionGranted: () -> Boolean,
    /** UI state changes (any thread); the settings status line reads it. */
    private val onState: (CameraUiState) -> Unit = {},
    private val log: (warn: Boolean, ev: String, fields: String) -> Unit = { _, _, _ -> },
) {
    private val lock = Any()
    private var wish = CameraWish()
    private var foreground = true
    private var ctx: CameraSessionCtx? = null
    private var desired: CameraPlan? = null
    private var unavailable = false
    private var run: CameraRun? = null
    private var runFacing = CameraFacing.FRONT
    private var published = CameraUiState.IDLE

    /** What the status line shows now. */
    val uiState: CameraUiState get() = synchronized(lock) { stateNow() }

    /** True while a stream (camera, encoder, connection) exists. */
    val running: Boolean get() = synchronized(lock) { run != null }

    /** The Mac's `CAMERA_CONTROL` of the accepted session [session] (engine thread). */
    fun onControl(msg: CameraControl, session: CameraSessionCtx) {
        synchronized(lock) {
            if (ctx != null && ctx!!.gen != session.gen) { // another session's leftovers never survive
                closeRun("session_switch")
                desired = null
            }
            ctx = session
            if (msg.isStart) {
                unavailable = false
                val plan = CameraPlan(msg.camId, msg.port, msg.width, msg.height, msg.fps, msg.bitrateKbps)
                val cur = desired
                if (cur != null && cur.camId == plan.camId) { // same cam_id again: nothing changes (PROTOCOL.md 0x0F)
                    reconcile()
                    return
                }
                closeRun("new_cam_id") // a new cam_id replaces a running one
                desired = plan
            } else {
                // STOP, UNAVAILABLE and unknown states all stop; UNAVAILABLE also says why on the settings panel.
                closeRun(if (msg.isUnavailable) "unavailable" else "stop")
                desired = null
                unavailable = msg.isUnavailable
            }
            reconcile()
        }
    }

    /** The user's mode or facing changed (any thread). OFF closes at once; a facing change on a running stream switches the camera. */
    fun setWish(w: CameraWish) {
        synchronized(lock) {
            val was = wish
            wish = w
            if (w.mode == CameraMode.OFF && was.mode != CameraMode.OFF) {
                closeRun("mode_off")
                desired = null // the Mac stops on our CAMERA_PREFS(OFF); a later START is a new stream
            }
            reconcile()
        }
    }

    /** The runtime permission was granted or taken away (any thread; the host of the controller calls it on changes). */
    fun onPermissionChanged() {
        synchronized(lock) {
            if (!permissionGranted()) closeRun("permission")
            reconcile()
        }
    }

    /** The activity went to the background ([foreground] false: close at once) or came back (reopen a held START). */
    fun setForeground(fg: Boolean) {
        synchronized(lock) {
            if (foreground == fg) return
            foreground = fg
            if (!fg) closeRun("background")
            reconcile()
        }
    }

    /** The session ended (BYE, loss, migration switch, shutdown): nothing of it survives. */
    fun onSessionEnd() {
        synchronized(lock) {
            closeRun("session_end")
            desired = null
            unavailable = false
            ctx = null
            publish()
        }
    }

    private fun wanted(): Boolean =
        desired != null && ctx != null && wish.mode == CameraMode.AUTO && foreground && permissionGranted()

    private fun reconcile() {
        val plan = desired
        val c = ctx
        if (plan != null && c != null && wanted()) {
            val r = run
            if (r == null) {
                runFacing = wish.facing
                run = factory.start(plan, c, wish.facing) { who, reason -> onRunEnded(who, reason) }
            } else if (runFacing != wish.facing) {
                runFacing = wish.facing
                r.switchFacing(wish.facing)
            }
        } else if (run != null) {
            closeRun("not_wanted")
        }
        publish()
    }

    /** The stream ended by itself (retries used up, camera or encoder failure): the Mac's START is spent, wait for a new one. */
    private fun onRunEnded(who: CameraRun, reason: String) {
        synchronized(lock) {
            if (run !== who) return // an old run's late word
            run = null
            desired = null
            log(true, "camera", "state=ended reason=$reason")
            publish()
        }
    }

    private fun closeRun(reason: String) {
        val r = run ?: return
        run = null
        r.close(reason)
    }

    private fun stateNow(): CameraUiState = when {
        run != null -> CameraUiState.ACTIVE
        unavailable -> CameraUiState.UNAVAILABLE
        else -> CameraUiState.IDLE
    }

    private fun publish() {
        val s = stateNow()
        if (s != published) {
            published = s
            onState(s)
        }
    }
}
