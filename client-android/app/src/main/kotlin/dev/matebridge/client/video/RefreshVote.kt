package dev.matebridge.client.video

import android.animation.ValueAnimator
import android.content.Context
import android.graphics.Color
import android.os.Handler
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.view.ViewGroup
import android.widget.FrameLayout
import dev.matebridge.client.session.MbLog

/** Why the vote changed (T-140). */
enum class VoteReason(val logName: String) { FPS("fps"), SESSION("session"), BACKGROUND("background") }

/** A state change of [RefreshVote]; [on] is the new state. */
data class VoteChange(val on: Boolean, val reason: VoteReason)

/**
 * T-140 experiment gate: the "animation vote" is held only while a session streams and the video frame rate is at
 * least [minFps] (0 = always while streaming). Falling below the threshold turns it off only after [holdMs]
 * (hysteresis); a session end or background turns it off at once. Pure logic, the clock is injected.
 */
class RefreshVote(
    private val minFps: Int,
    private val clock: () -> Long,
    private val holdMs: Long = HOLD_MS,
) {
    var on = false
        private set
    private var belowSince = NONE

    /** One observation (about once a second): [streaming] and the recent video [fps]. Returns the change, if any. */
    fun update(streaming: Boolean, fps: Double): VoteChange? {
        if (!streaming) return stop(VoteReason.SESSION)
        if (minFps <= 0 || fps >= minFps) {
            belowSince = NONE
            return if (on) null else turn(true, VoteReason.FPS)
        }
        if (!on) return null
        val now = clock()
        if (belowSince == NONE) belowSince = now
        return if (now - belowSince >= holdMs) turn(false, VoteReason.FPS) else null
    }

    /** Immediate off (session end, background, disconnect). */
    fun stop(reason: VoteReason): VoteChange? {
        belowSince = NONE
        return if (on) turn(false, reason) else null
    }

    private fun turn(value: Boolean, reason: VoteReason): VoteChange {
        on = value
        belowSince = NONE
        return VoteChange(value, reason)
    }

    companion object {
        const val HOLD_MS = 1000L
        const val DEFAULT_MIN_FPS = 70
        private const val NONE = Long.MIN_VALUE
    }
}

/**
 * Applies the vote on the device. [mode] bit 1 = animation path (near-transparent 1x1 view + endless ValueAnimator
 * that invalidates it every frame), bit 2 = reflection path (`DynamicRefreshRateHelper.setRefreshRate`, repeated
 * every 400 ms). Mode 0 is never constructed. Main thread only.
 */
class RefreshVoteDriver(
    private val context: Context,
    private val root: ViewGroup,
    private val handler: Handler,
    private val mode: Int,
    private val priority: Int,
) {
    private var view: View? = null
    private var animator: ValueAnimator? = null
    private var reflect: Reflect? = null
    private var reflectDead = false
    private var active = false

    private val repeat = object : Runnable {
        override fun run() {
            if (!active) return
            if (!callReflect(on = true)) return
            handler.postDelayed(this, REPEAT_MS)
        }
    }

    fun apply(on: Boolean) {
        active = on
        if (mode and MODE_ANIM != 0) if (on) startAnim() else stopAnim()
        if (mode and MODE_REFLECT != 0) {
            handler.removeCallbacks(repeat)
            if (on) repeat.run() else callReflect(on = false)
        }
    }

    /** Stops everything without logging (activity teardown). */
    fun release() {
        apply(false)
    }

    private fun startAnim() {
        val v = view ?: object : View(context) {
            // Never takes touch, pen or hover input: not clickable/focusable, and these return false.
            override fun onTouchEvent(event: MotionEvent?) = false
            override fun onGenericMotionEvent(event: MotionEvent?) = false
            override fun onHoverEvent(event: MotionEvent?) = false
        }.also {
            it.setBackgroundColor(NEAR_TRANSPARENT)
            it.isClickable = false
            it.isFocusable = false
            it.importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO
            root.addView(it, FrameLayout.LayoutParams(1, 1, Gravity.TOP or Gravity.END))
            view = it
        }
        v.visibility = View.VISIBLE
        if (animator != null) return
        animator = ValueAnimator.ofFloat(0f, 1f).apply {
            duration = 1000
            repeatCount = ValueAnimator.INFINITE
            addUpdateListener { v.invalidate() }
            start()
        }
    }

    private fun stopAnim() {
        animator?.cancel()
        animator = null
        view?.visibility = View.INVISIBLE // stays in the tree, not drawn
    }

    /** Returns false when the path is dead (it stops itself after one log line). */
    private fun callReflect(on: Boolean): Boolean {
        if (reflectDead) return false
        val r = reflect ?: resolve() ?: return false
        return try {
            r.set.invoke(r.helper, KEY_ID, r.range(if (on) VOTE_FPS else 0, priority)) // (0,0,0) is the "stop" range
            true
        } catch (e: Throwable) {
            fail(e)
        }
    }

    private fun resolve(): Reflect? = try {
        val helperCls = Class.forName("android.view.DynamicRefreshRateHelper")
        val rangeCls = Class.forName("android.view.DynamicRefreshRateHelper\$FrameRange")
        val helper = helperCls.getMethod("getInstance").invoke(null)!!
        val set = helperCls.getMethod("setRefreshRate", String::class.java, rangeCls)
        val i = Int::class.javaPrimitiveType!!
        val ctor4 = runCatching { rangeCls.getConstructor(i, i, i, i) }.getOrNull()
        val ctor = ctor4 ?: rangeCls.getConstructor(i, i, i, i, Boolean::class.javaPrimitiveType)
        val n = if (ctor4 != null) 4 else 5
        Reflect(helper, set) { fps, prio ->
            if (n == 4) ctor.newInstance(fps, fps, fps, prio) else ctor.newInstance(fps, fps, fps, prio, false)
        }.also {
            reflect = it
            MbLog.i("rvote_reflect", "ok=1 ctor=$n", "render")
        }
    } catch (e: Throwable) {
        fail(e)
        null
    }

    private fun fail(e: Throwable): Boolean {
        val cause = e.cause ?: e
        MbLog.w("rvote_reflect_failed", "err=${cause.javaClass.simpleName}", "render")
        reflectDead = true
        handler.removeCallbacks(repeat)
        return false
    }

    private class Reflect(val helper: Any, val set: java.lang.reflect.Method, val range: (Int, Int) -> Any)

    companion object {
        const val MODE_ANIM = 1
        const val MODE_REFLECT = 2
        private const val VOTE_FPS = 120
        private const val REPEAT_MS = 400L
        private const val KEY_ID = "matebridge_rvote"
        private val NEAR_TRANSPARENT = Color.argb(1, 0, 0, 0) // 0x01000000
    }
}
