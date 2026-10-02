package dev.matebridge.client.video

import android.graphics.SurfaceTexture
import android.opengl.EGL14
import android.opengl.EGLConfig
import android.opengl.EGLContext
import android.opengl.EGLDisplay
import android.opengl.EGLExt
import android.opengl.EGLSurface
import android.opengl.GLES11Ext
import android.opengl.GLES20
import android.os.Handler
import android.os.HandlerThread
import android.view.Choreographer
import android.view.Surface
import dev.matebridge.client.session.MbLog
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.FloatBuffer

/**
 * GL presentation path (T-018): MediaCodec renders into a [SurfaceTexture] (OES texture) and this class
 * draws the newest frame onto [target] once per vsync from its own EGL thread. Compared with
 * MediaCodec -> SurfaceView this makes us the producer for the display layer, so it is not labeled as
 * video and we choose when a frame is presented.
 *
 * Everything GL happens on the private "mb-gl" thread, which also runs a Choreographer: at each vsync, if
 * at least one frame arrived since the previous one, the newest is latched ([SurfaceTexture.updateTexImage]
 * skips older queued buffers), drawn 1:1 with NEAREST sampling (the target view is sized to the video, so
 * no scaling or filtering) and swapped. The last frame stays on screen when nothing new arrived.
 *
 * Lifecycle: [start] when the target surface exists, [stop] before/when it is destroyed. [start] returns
 * at once; [onReady] is called on the GL thread with the Surface the decoder must render to, after GL is
 * set up. The decoder must be detached before [stop] (which releases that Surface). [active] gates the
 * vsync loop so nothing runs while not streaming.
 *
 * T-141: while no frame arrives for [VsyncIdleGate.DEFAULT_IDLE_AFTER_NS] the vsync loop sleeps (no callback, the clock
 * forgets its phase). The next frame wakes it and is drawn at once instead of waiting for a vsync callback.
 *
 * @param presentationTime when true, eglPresentationTimeANDROID asks the compositor to show each frame
 *   at the next vsync after the one it was drawn for (experiment; off by default).
 */
class GlPresenter(
    /** Receives the "shown" time (client monotonic microseconds) of each presented frame. */
    private val onShown: (Long) -> Unit,
    private val presentStats: PresentStats,
    private val vsync: VsyncClock,
    private val presentationTime: Boolean = false,
    /**
     * Called from the GL thread when GL setup or drawing failed for good. The decoder Surface has been
     * released by then, so a decoder still rendering to it errors out instead of stalling silently.
     */
    private val onFailed: (String) -> Unit = {},
) {
    private companion object {
        const val TAG = "render"

        /** Thread of the most recently stopped presenter (UI thread only); the next one waits for it. */
        var lingering: Thread? = null

        const val VERTEX = """
            attribute vec4 aPos;
            attribute vec2 aTex;
            uniform mat4 uTexMatrix;
            varying highp vec2 vTex;
            void main() {
                gl_Position = aPos;
                vTex = (uTexMatrix * vec4(aTex, 0.0, 1.0)).xy;
            }
        """
        const val FRAGMENT = """
            #extension GL_OES_EGL_image_external : require
            #ifdef GL_FRAGMENT_PRECISION_HIGH
            precision highp float;
            #define HP highp
            #else
            precision mediump float;
            #define HP mediump
            #endif
            varying HP vec2 vTex;
            uniform samplerExternalOES uTex;
            void main() { gl_FragColor = texture2D(uTex, vTex); }
        """
        // x, y, s, t (triangle strip)
        val QUAD = floatArrayOf(-1f, -1f, 0f, 0f, 1f, -1f, 1f, 0f, -1f, 1f, 0f, 1f, 1f, 1f, 1f, 1f)
    }

    private var thread: HandlerThread? = null
    private var handler: Handler? = null

    /** Vsync loop gate; set from any thread. */
    @Volatile var active = false
        set(v) {
            val was = field
            field = v
            if (v && !was) handler?.post { startLoop() }
        }

    // ---- GL thread state ----
    private var display: EGLDisplay = EGL14.EGL_NO_DISPLAY
    private var context: EGLContext = EGL14.EGL_NO_CONTEXT
    private var eglSurface: EGLSurface = EGL14.EGL_NO_SURFACE
    private var program = 0
    private var texId = 0
    private var uTexMatrix = 0
    private var surfaceTexture: SurfaceTexture? = null
    private var decoderSurface: Surface? = null
    private var vertices: FloatBuffer? = null
    private val texMatrix = FloatArray(16)
    private var width = 0
    private var height = 0
    private var pending = 0
    private var lastAvailNs = 0L
    private var loopRunning = false
    private var failed = false
    private var loggedMatrix = false
    private val idle = VsyncIdleGate()
    /** Review P2: armed when the loop falls asleep; the next frame is drawn on arrival, not on a vsync. GL thread only. */
    private val firstFrame = FirstOutputBypass()

    private val frameCallback = Choreographer.FrameCallback { t -> onVsync(t) }

    fun start(target: Surface, onReady: (Surface) -> Unit) {
        stop()
        val previous = lingering
        val t = HandlerThread("mb-gl").also { it.start() }
        thread = t
        lingering = t
        val h = Handler(t.looper)
        handler = h
        h.post {
            try { previous?.join() } catch (_: InterruptedException) { return@post }
            try {
                setupGl(target)
                onReady(decoderSurface!!)
                if (active) startLoop()
            } catch (e: Exception) {
                MbLog.e("gl_setup_failed", "err=${e.javaClass.simpleName} egl=0x${Integer.toHexString(EGL14.eglGetError())}", TAG)
                fail("setup")
            }
        }
    }

    /**
     * Releases GL and the decoder Surface on the GL thread without blocking the caller; a presenter
     * started afterwards waits for this one to finish. The decoder must already be detached.
     */
    fun stop() {
        val t = thread ?: return
        val h = handler
        thread = null
        handler = null
        h?.post {
            loopRunning = false
            idle.stop()
            Choreographer.getInstance().removeFrameCallback(frameCallback)
            teardownGl()
            t.quitSafely()
        }
    }

    /** GL thread: give up. Releasing the decoder Surface makes a decoder still writing to it fail loudly. */
    private fun fail(why: String) {
        if (failed) return
        failed = true
        teardownGl()
        onFailed(why)
    }

    // ---- GL thread ----

    private fun setupGl(target: Surface) {
        failed = false
        display = EGL14.eglGetDisplay(EGL14.EGL_DEFAULT_DISPLAY)
        check(display != EGL14.EGL_NO_DISPLAY) { "no display" }
        val ver = IntArray(2)
        check(EGL14.eglInitialize(display, ver, 0, ver, 1)) { "eglInitialize" }
        val cfgAttrs = intArrayOf(
            EGL14.EGL_RED_SIZE, 8, EGL14.EGL_GREEN_SIZE, 8, EGL14.EGL_BLUE_SIZE, 8, EGL14.EGL_ALPHA_SIZE, 8,
            EGL14.EGL_RENDERABLE_TYPE, EGL14.EGL_OPENGL_ES2_BIT, EGL14.EGL_NONE,
        )
        val configs = arrayOfNulls<EGLConfig>(1)
        val n = IntArray(1)
        check(EGL14.eglChooseConfig(display, cfgAttrs, 0, configs, 0, 1, n, 0) && n[0] > 0) { "eglChooseConfig" }
        val config = configs[0]!!
        context = EGL14.eglCreateContext(display, config, EGL14.EGL_NO_CONTEXT, intArrayOf(EGL14.EGL_CONTEXT_CLIENT_VERSION, 2, EGL14.EGL_NONE), 0)
        check(context != EGL14.EGL_NO_CONTEXT) { "eglCreateContext" }
        eglSurface = EGL14.eglCreateWindowSurface(display, config, target, intArrayOf(EGL14.EGL_NONE), 0)
        check(eglSurface != EGL14.EGL_NO_SURFACE) { "eglCreateWindowSurface" }
        check(EGL14.eglMakeCurrent(display, eglSurface, eglSurface, context)) { "eglMakeCurrent" }
        EGL14.eglSwapInterval(display, 1)
        querySize()

        program = buildProgram(VERTEX, FRAGMENT)
        uTexMatrix = GLES20.glGetUniformLocation(program, "uTexMatrix")
        val tex = IntArray(1)
        GLES20.glGenTextures(1, tex, 0)
        texId = tex[0]
        GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, texId)
        // 1:1 mapping, so nearest is exact and never blurs; edge clamp keeps the crop transform safe.
        GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_MIN_FILTER, GLES20.GL_NEAREST)
        GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_MAG_FILTER, GLES20.GL_NEAREST)
        GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_WRAP_S, GLES20.GL_CLAMP_TO_EDGE)
        GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_WRAP_T, GLES20.GL_CLAMP_TO_EDGE)
        vertices = ByteBuffer.allocateDirect(QUAD.size * 4).order(ByteOrder.nativeOrder()).asFloatBuffer()
            .also { it.put(QUAD); it.position(0) }

        val st = SurfaceTexture(texId)
        st.setOnFrameAvailableListener({
            pending++
            lastAvailNs = System.nanoTime()
            val wakeAsked = idle.onActivity(lastAvailNs)
            if (firstFrame.take() || wakeAsked) presentNow() // GL thread: the loop thread itself
        }, handler)
        surfaceTexture = st
        decoderSurface = Surface(st)
        MbLog.i(
            "gl_ready",
            "egl=${ver[0]}.${ver[1]} surface=${width}x$height presentation_time=$presentationTime " +
                "renderer=${GLES20.glGetString(GLES20.GL_RENDERER)}",
            TAG,
        )
    }

    private fun teardownGl() {
        try { decoderSurface?.release() } catch (_: Exception) {}
        try { surfaceTexture?.setOnFrameAvailableListener(null) } catch (_: Exception) {}
        try { surfaceTexture?.release() } catch (_: Exception) {}
        decoderSurface = null
        surfaceTexture = null
        if (display != EGL14.EGL_NO_DISPLAY) {
            EGL14.eglMakeCurrent(display, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_CONTEXT)
            if (eglSurface != EGL14.EGL_NO_SURFACE) EGL14.eglDestroySurface(display, eglSurface)
            if (context != EGL14.EGL_NO_CONTEXT) EGL14.eglDestroyContext(display, context)
            // No eglTerminate: the default display is shared with the rest of the process.
            EGL14.eglReleaseThread()
        }
        display = EGL14.EGL_NO_DISPLAY
        context = EGL14.EGL_NO_CONTEXT
        eglSurface = EGL14.EGL_NO_SURFACE
        program = 0
        texId = 0
    }

    private fun startLoop() {
        if (loopRunning || failed || surfaceTexture == null) return
        loopRunning = true
        idle.start(System.nanoTime())
        firstFrame.disarm()
        presentStats.breakSequence()
        Choreographer.getInstance().postFrameCallback(frameCallback)
    }

    /**
     * T-141, GL thread: the first frame after an idle sleep. Draw it now (no vsync wait), then make sure the loop runs.
     * Does not depend on the loop's state: it may already have been restarted ([active] rising) before the frame came.
     */
    private fun presentNow() {
        idle.wake(System.nanoTime())
        if (!active || failed || surfaceTexture == null) return
        if (pending > 0) {
            try { draw(System.nanoTime()) } catch (e: Exception) {
                MbLog.e("gl_draw_failed", "err=${e.javaClass.simpleName} egl=0x${Integer.toHexString(EGL14.eglGetError())}", TAG)
                fail("draw")
                return
            }
        }
        startLoop()
    }

    private fun onVsync(frameTimeNs: Long) {
        vsync.onVsync(frameTimeNs)
        presentStats.onVsync(frameTimeNs, vsync.periodNs)
        if (pending > 0 && !failed) {
            try { draw(frameTimeNs) } catch (e: Exception) {
                MbLog.e("gl_draw_failed", "err=${e.javaClass.simpleName} egl=0x${Integer.toHexString(EGL14.eglGetError())}", TAG)
                fail("draw")
            }
        }
        if (active && !failed && idle.onVsync(System.nanoTime())) {
            Choreographer.getInstance().postFrameCallback(frameCallback)
        } else if (active && !failed) {
            // T-141: idle, the loop sleeps until the next frame (presentNow); the period is kept, the phase forgotten.
            loopRunning = false
            firstFrame.arm()
            presentStats.breakSequence()
            vsync.reset()
        } else {
            loopRunning = false
            presentStats.breakSequence()
            vsync.reset()
        }
    }

    private fun draw(vsyncNs: Long) {
        val st = surfaceTexture ?: return
        val startNs = System.nanoTime()
        val waited = startNs - lastAvailNs
        // updateTexImage latches one queued buffer per call: drain every frame that arrived, keep the
        // last (newest wins). This also frees the decoder's output slots so it cannot stall.
        val n = pending
        pending = 0
        for (i in 0 until n) st.updateTexImage()
        val coalesced = n - 1
        st.getTransformMatrix(texMatrix)
        if (!loggedMatrix) {
            loggedMatrix = true
            MbLog.i("gl_tex_matrix", "m=" + texMatrix.joinToString(",") { "%.4f".format(java.util.Locale.ROOT, it) }, TAG)
        }
        querySize()

        GLES20.glViewport(0, 0, width, height)
        GLES20.glUseProgram(program)
        GLES20.glActiveTexture(GLES20.GL_TEXTURE0)
        GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, texId)
        GLES20.glUniformMatrix4fv(uTexMatrix, 1, false, texMatrix, 0)
        val v = vertices!!
        val aPos = GLES20.glGetAttribLocation(program, "aPos")
        val aTex = GLES20.glGetAttribLocation(program, "aTex")
        v.position(0)
        GLES20.glVertexAttribPointer(aPos, 2, GLES20.GL_FLOAT, false, 16, v)
        GLES20.glEnableVertexAttribArray(aPos)
        v.position(2)
        GLES20.glVertexAttribPointer(aTex, 2, GLES20.GL_FLOAT, false, 16, v)
        GLES20.glEnableVertexAttribArray(aTex)
        GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4)

        if (presentationTime) {
            // Show at the vsync after the one this callback belongs to.
            EGLExt.eglPresentationTimeANDROID(display, eglSurface, vsyncNs + vsync.periodNs)
        }
        val swapStart = System.nanoTime()
        EGL14.eglSwapBuffers(display, eglSurface)
        val end = System.nanoTime()
        presentStats.onDraw(waited, end - swapStart, coalesced)
        // "Shown" proxy: the vsync this frame was queued for. EGL_ANDROID_get_frame_timestamps has no
        // Java binding, so real display times are not available; gaps are multiples of the vsync period.
        onShown(vsyncNs / 1000)
    }

    private fun querySize() {
        val dim = IntArray(1)
        if (EGL14.eglQuerySurface(display, eglSurface, EGL14.EGL_WIDTH, dim, 0)) width = dim[0]
        if (EGL14.eglQuerySurface(display, eglSurface, EGL14.EGL_HEIGHT, dim, 0)) height = dim[0]
    }

    private fun buildProgram(vs: String, fs: String): Int {
        fun compile(type: Int, src: String): Int {
            val s = GLES20.glCreateShader(type)
            GLES20.glShaderSource(s, src)
            GLES20.glCompileShader(s)
            val ok = IntArray(1)
            GLES20.glGetShaderiv(s, GLES20.GL_COMPILE_STATUS, ok, 0)
            check(ok[0] != 0) { "shader: ${GLES20.glGetShaderInfoLog(s)}" }
            return s
        }
        val p = GLES20.glCreateProgram()
        GLES20.glAttachShader(p, compile(GLES20.GL_VERTEX_SHADER, vs))
        GLES20.glAttachShader(p, compile(GLES20.GL_FRAGMENT_SHADER, fs))
        GLES20.glLinkProgram(p)
        val ok = IntArray(1)
        GLES20.glGetProgramiv(p, GLES20.GL_LINK_STATUS, ok, 0)
        check(ok[0] != 0) { "link: ${GLES20.glGetProgramInfoLog(p)}" }
        return p
    }
}
