package dev.matebridge.client.input

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.GestureDescription
import android.content.Context
import android.graphics.Color
import android.graphics.Path
import android.graphics.PixelFormat
import android.os.Handler
import android.os.Looper
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.view.WindowManager
import android.view.accessibility.AccessibilityEvent

/**
 * T-360 (decision 0041): holds one motionless fake touch on its own tiny overlay window so the Huawei panel stays at
 * 120 Hz with a gamepad or keyboard. It does nothing by itself: the client calls [HoldTouchActuator]. It listens to no
 * events and reads no window content. The overlay swallows the touch, so it never reaches the video surface or the Mac.
 */
class HoldTouchService : AccessibilityService() {
    override fun onServiceConnected() {
        super.onServiceConnected()
        instance = this
        mainHandler.post { onBoundChanged?.invoke() }
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {}
    override fun onInterrupt() {}

    override fun onUnbind(intent: android.content.Intent?): Boolean {
        release(this)
        return super.onUnbind(intent)
    }

    override fun onDestroy() {
        release(this)
        super.onDestroy()
    }

    private fun release(s: HoldTouchService) {
        if (instance === s) instance = null
        activeActuator?.stop() // never leave a held touch or window behind
        mainHandler.post { onBoundChanged?.invoke() }
    }

    companion object {
        private val mainHandler = Handler(Looper.getMainLooper())

        /** The connected service, or null (permission off, or not bound yet). */
        @Volatile var instance: HoldTouchService? = null
            private set

        val bound: Boolean get() = instance != null

        /** Called on the main thread when [bound] changed. Set by MainActivity; cleared on destroy. */
        @Volatile var onBoundChanged: (() -> Unit)? = null

        @Volatile internal var activeActuator: HoldTouchActuator? = null

        /** On-screen rect (l, t, r, b) of the existing overlay, or null. MainActivity drops real touches that start inside it. */
        @Volatile var overlayRect: IntArray? = null
            internal set
    }
}

/**
 * The real [Hold120Actuator]: adds the overlay, then holds the touch with a chain of `willContinue` strokes and ends it
 * with a short final stroke (the UP). All work is on the main thread.
 */
class HoldTouchActuator(private val service: HoldTouchService) : Hold120Actuator {
    private val handler = Handler(Looper.getMainLooper())
    private var overlay: View? = null
    private var stroke: GestureDescription.StrokeDescription? = null
    private var seg = 0 // index of the chunk last dispatched (HoldPathGeometry)
    private val gate = DrainGate()
    private var ox = 0 // actual on-screen origin minus the intended one
    private var oy = 0
    private var onCancelled: (() -> Unit)? = null
    private var canDispatch: () -> Boolean = { true }
    private var epoch = 0

    override fun start(onCancelled: () -> Unit, canDispatch: () -> Boolean) {
        if (gate.active || gate.draining) return
        gate.onStart()
        this.onCancelled = onCancelled
        this.canDispatch = canDispatch
        HoldTouchService.activeActuator = this
        val e = ++epoch
        val wm = service.getSystemService(Context.WINDOW_SERVICE) as WindowManager
        val size = HoldPathGeometry.OVERLAY_SIZE_PX
        val v = object : View(service) {
            override fun onTouchEvent(event: MotionEvent?): Boolean = true // swallow: never reaches anything below
        }
        v.setBackgroundColor(Color.TRANSPARENT)
        val lp = WindowManager.LayoutParams(
            size, size, WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN or
                WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS,
            PixelFormat.TRANSLUCENT,
        )
        lp.gravity = Gravity.TOP or Gravity.START
        lp.x = HoldPathGeometry.INSET_PX
        lp.y = HoldPathGeometry.INSET_PX
        try {
            wm.addView(v, lp)
            overlay = v
        } catch (_: Throwable) {
            gate.onStop(false)
            HoldTouchService.activeActuator = null
            handler.post { if (e == epoch) onCancelled() }
            return
        }
        HoldTouchService.overlayRect = intArrayOf(
            HoldPathGeometry.INSET_PX, HoldPathGeometry.INSET_PX,
            HoldPathGeometry.INSET_PX + size, HoldPathGeometry.INSET_PX + size,
        )
        awaitReady(e, v, android.os.SystemClock.uptimeMillis(), null)
    }

    /** Polls until the overlay is attached, laid out and settled; only then is the first gesture dispatched (never before). */
    private fun awaitReady(e: Int, v: View, startedAt: Long, readyAt: Long?) {
        if (e != epoch || !gate.active) return
        val now = android.os.SystemClock.uptimeMillis()
        val loc = IntArray(2)
        val laidOut = v.isAttachedToWindow && v.width > 0 && v.height > 0
        if (laidOut) try { v.getLocationOnScreen(loc) } catch (_: Throwable) {}
        val ready = if (laidOut) (readyAt ?: now) else null
        when (OverlayReadiness.decide(laidOut, laidOut, ready?.let { now - it }, now - startedAt)) {
            OverlayReadiness.Verdict.GO -> {
                if (!canDispatch()) { fail(e); return } // a real contact (or its quiet period) began during the settle
                ox = loc[0] - HoldPathGeometry.INSET_PX
                oy = loc[1] - HoldPathGeometry.INSET_PX
                HoldTouchService.overlayRect = intArrayOf(loc[0], loc[1], loc[0] + v.width, loc[1] + v.height)
                seg = 0
                val st = GestureDescription.StrokeDescription(pathOf(HoldPathGeometry.segment(0)), 0, chunkMs(), true)
                stroke = st
                dispatch(st, e)
            }
            OverlayReadiness.Verdict.FAIL -> fail(e) // no dispatch: the DOWN could land on the video surface
            OverlayReadiness.Verdict.WAIT -> handler.postDelayed({ awaitReady(e, v, startedAt, ready) }, OverlayReadiness.POLL_MS)
        }
    }

    private fun chunkMs(): Long = minOf(HoldPathGeometry.CHUNK_MS, GestureDescription.getMaxGestureDuration()).coerceAtLeast(100L)

    private fun dispatch(s: GestureDescription.StrokeDescription, e: Int) {
        val ok = try {
            service.dispatchGesture(
                GestureDescription.Builder().addStroke(s).build(),
                object : android.accessibilityservice.AccessibilityService.GestureResultCallback() {
                    override fun onCompleted(g: GestureDescription?) {
                        if (e != epoch || !gate.active) return
                        val prev = stroke ?: return
                        seg++
                        val next = try { prev.continueStroke(pathOf(HoldPathGeometry.segment(seg)), 0, chunkMs(), true) } catch (_: Throwable) { fail(e); return }
                        stroke = next
                        dispatch(next, e)
                    }

                    override fun onCancelled(g: GestureDescription?) {
                        if (e != epoch || !gate.active) return
                        fail(e)
                    }
                },
                handler,
            )
        } catch (_: Throwable) { false }
        if (!ok) fail(e)
    }

    private fun fail(e: Int) {
        if (e != epoch || !gate.active) return
        val cb = onCancelled
        // The controller calls stop() (which removes the window); it then schedules the retry.
        handler.post { if (e == epoch) cb?.invoke() }
    }

    override fun abortIfPreparing(): Boolean {
        if (!gate.active || gate.draining || stroke != null) return false
        gate.onStop(false)
        epoch++
        onCancelled = null
        if (HoldTouchService.activeActuator === this) HoldTouchService.activeActuator = null
        removeOverlay()
        return true
    }

    override fun stop() {
        val s0 = stroke
        val action = gate.onStop(s0 != null)
        if (action == DrainGate.Action.NOOP) return // already draining: only its end removes the overlay
        epoch++
        if (HoldTouchService.activeActuator === this) HoldTouchService.activeActuator = null
        val s = s0
        stroke = null
        onCancelled = null
        if (action == DrainGate.Action.DRAIN && s != null) {
            // The UP: a short final stroke (it must move, see HoldPathGeometry) with willContinue = false ends the held touch.
            // The overlay stays until it completes or cancels (or a short timeout), so the UP lands on the overlay.
            var done = false
            val finish = Runnable { if (!done) { done = true; handler.removeCallbacksAndMessages(null); gate.onDrained(); removeOverlay() } }
            try {
                val f = HoldPathGeometry.finalSegment(seg)
                val last = s.continueStroke(pathOf(f), 0, HoldPathGeometry.FINAL_MS, false)
                val ok = service.dispatchGesture(
                    GestureDescription.Builder().addStroke(last).build(),
                    object : AccessibilityService.GestureResultCallback() {
                        override fun onCompleted(g: GestureDescription?) = finish.run()
                        override fun onCancelled(g: GestureDescription?) = finish.run()
                    },
                    handler,
                )
                if (ok) { handler.postDelayed(finish, HoldPathGeometry.removalTimeoutMs()); return }
            } catch (_: Throwable) {}
        }
        gate.onDrained()
        removeOverlay()
    }

    private fun pathOf(g: HoldPathGeometry.Seg) = Path().apply { moveTo(g.x0 + ox, g.y0 + oy); lineTo(g.x1 + ox, g.y1 + oy) }

    private fun removeOverlay() {
        val v = overlay ?: return
        overlay = null
        HoldTouchService.overlayRect = null
        try { (service.getSystemService(Context.WINDOW_SERVICE) as WindowManager).removeViewImmediate(v) } catch (_: Throwable) {}
    }

    private companion object {
    }
}
