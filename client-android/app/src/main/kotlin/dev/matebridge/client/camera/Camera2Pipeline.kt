package dev.matebridge.client.camera

import android.annotation.SuppressLint
import android.content.Context
import android.content.pm.PackageManager
import android.graphics.SurfaceTexture
import android.hardware.camera2.CameraAccessException
import android.hardware.camera2.CameraCaptureSession
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraDevice
import android.hardware.camera2.CameraManager
import android.hardware.camera2.CaptureRequest
import android.hardware.camera2.params.OutputConfiguration
import android.hardware.camera2.params.SessionConfiguration
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.os.Bundle
import android.os.Handler
import android.os.HandlerThread
import android.util.Range
import android.view.Surface
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

/**
 * The real camera path (T-355, decision 0040): Camera2 -> SurfaceTexture -> OpenGL ES ([GlEncoderSurface]: rotation to
 * upright landscape and centre-crop) -> H.264 `MediaCodec` surface input -> [CameraPipeline.Sink]. Nothing exists until
 * [start]; [stop] releases camera, encoder, GL and threads (non-blocking: the teardown runs on the pipeline's own
 * thread, and the next pipeline waits for it, so two runs never fight over the camera).
 *
 * Threads: one `mb-cam` handler thread for every camera, GL and lifecycle call (the EGL context is current there), one
 * `mb-cam-enc` thread draining the encoder. Frame contents are never logged or stored.
 *
 * The front camera is NOT mirrored (PROTOCOL.md 0x0F). The rotation follows the display ([displayDegrees], re-read per
 * frame, so a landscape flip while streaming stays upright).
 */
class Camera2Pipeline(
    private val context: Context,
    /** Rotation of the display from its natural orientation in degrees (`Surface.ROTATION_*`); read on the camera thread. */
    private val displayDegrees: () -> Int,
    private val log: (warn: Boolean, ev: String, fields: String) -> Unit = { _, _, _ -> },
) : CameraPipeline {
    private val stopRequested = AtomicBoolean(false)
    private val started = AtomicBoolean(false)
    private val closedLatch = CountDownLatch(1)
    @Volatile private var handler: Handler? = null
    @Volatile private var codec: MediaCodec? = null
    @Volatile private var sink: CameraPipeline.Sink? = null

    // Camera thread state.
    private var thread: HandlerThread? = null
    private var gl: GlEncoderSurface? = null
    private var st: SurfaceTexture? = null
    private var camSurface: Surface? = null
    private var encSurface: Surface? = null // T-357 r3: the encoder's input surface, owned here, released in teardown
    private var device: CameraDevice? = null
    private var session: CameraCaptureSession? = null
    private var facing = CameraFacing.FRONT
    private var fps = 30
    private var outW = 0
    private var outH = 0
    private var srcW = 0
    private var srcH = 0
    private var sensorOrientation = 0
    private var fpsRange: Range<Int>? = null
    private var afContinuous = false
    private var released = false
    private var reannounce = false
    private var mvpKey = -1L
    private var mvp = FloatArray(16)

    // Encoder thread / shared.
    @Volatile private var drain: Thread? = null
    @Volatile private var lastConfig: ByteArray? = null

    override fun start(facing: CameraFacing, width: Int, height: Int, fps: Int, bitrateKbps: Int, sink: CameraPipeline.Sink) {
        check(started.compareAndSet(false, true)) { "started twice" }
        this.sink = sink
        this.facing = facing
        this.fps = fps.coerceIn(5, 60)
        val ht = HandlerThread("mb-cam").also { it.start() }
        thread = ht
        val h = Handler(ht.looper)
        handler = h
        val prev = synchronized(Companion) { lastClosed.also { lastClosed = closedLatch } }
        h.post { setup(prev, width, height, bitrateKbps) }
    }

    override fun switchFacing(facing: CameraFacing) {
        handler?.post { if (!stopRequested.get() && !released) doSwitch(facing) }
    }

    override fun requestKeyframe() {
        val c = codec ?: return
        try {
            c.setParameters(Bundle().apply { putInt(MediaCodec.PARAMETER_KEY_REQUEST_SYNC_FRAME, 0) })
        } catch (_: RuntimeException) {
            // the codec is being torn down
        }
    }

    override fun stop() {
        if (!stopRequested.compareAndSet(false, true)) return
        val h = handler
        if (h == null) { closedLatch.countDown(); return }
        h.post { teardown() }
    }

    // ---- camera thread ----

    private fun fail(reason: String) {
        log(true, "camera", "state=error reason=$reason")
        sink?.onError(reason)
    }

    private fun setup(prev: CountDownLatch?, reqW: Int, reqH: Int, kbps: Int) {
        try {
            prev?.await(PREVIOUS_CLOSE_WAIT_MS, TimeUnit.MILLISECONDS) // the previous run releases the camera first
            if (stopRequested.get()) return
            val mgr = context.getSystemService(Context.CAMERA_SERVICE) as CameraManager
            val target = resolveTarget(mgr, facing) ?: return fail("no_camera")
            applyCharacteristics(mgr, target.charId, reqW)
            val enc = createEncoder(reqW, reqH, kbps)
            codec = enc.codec
            outW = enc.w
            outH = enc.h
            val encIn = enc.codec.createInputSurface()
            encSurface = encIn
            enc.codec.start()
            val g = GlEncoderSurface(encIn)
            gl = g
            val t = SurfaceTexture(g.texId)
            t.setDefaultBufferSize(srcW, srcH)
            t.setOnFrameAvailableListener({ onFrame() }, handler)
            st = t
            camSurface = Surface(t)
            startDrain(enc.codec)
            log(false, "camera", "state=encoder size=${outW}x$outH src=${srcW}x$srcH fps=$fps facing=${facing.id}")
            openCamera(mgr, target)
        } catch (e: SecurityException) {
            fail("permission")
        } catch (e: CameraAccessException) {
            fail("camera_access")
        } catch (e: RuntimeException) {
            fail("setup_${e.javaClass.simpleName}")
        }
    }

    private class Enc(val codec: MediaCodec, val w: Int, val h: Int)

    private val openGen = OpenGeneration()

    private fun createEncoder(reqW: Int, reqH: Int, kbps: Int): Enc {
        var last: Exception? = null
        for (profile in listOf(MediaCodecInfo.CodecProfileLevel.AVCProfileHigh, MediaCodecInfo.CodecProfileLevel.AVCProfileMain, 0)) {
            val c = MediaCodec.createEncoderByType(MIME)
            try {
                val caps = c.codecInfo.getCapabilitiesForType(MIME)
                val vc = caps.videoCapabilities ?: throw IllegalStateException("no video capabilities")
                val size = CameraMath.pickEncoderSize(reqW, reqH) { w, h -> vc.isSizeSupported(w, h) }
                    ?: throw IllegalStateException("no supported 16:9 size")
                val fmt = MediaFormat.createVideoFormat(MIME, size.first, size.second).apply {
                    setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface)
                    setInteger(MediaFormat.KEY_BIT_RATE, (kbps.toLong() * 1000).coerceAtMost(Int.MAX_VALUE.toLong()).toInt())
                    setInteger(MediaFormat.KEY_FRAME_RATE, fps)
                    setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, I_FRAME_INTERVAL_S)
                    if (caps.encoderCapabilities?.isBitrateModeSupported(MediaCodecInfo.EncoderCapabilities.BITRATE_MODE_CBR) == true) {
                        setInteger(MediaFormat.KEY_BITRATE_MODE, MediaCodecInfo.EncoderCapabilities.BITRATE_MODE_CBR)
                    }
                    setInteger(MediaFormat.KEY_PRIORITY, 0) // real time
                    setInteger(MediaFormat.KEY_LATENCY, 1)
                    setInteger(MediaFormat.KEY_MAX_B_FRAMES, 0)
                    if (profile != 0) setInteger(MediaFormat.KEY_PROFILE, profile)
                }
                c.configure(fmt, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
                return Enc(c, size.first, size.second)
            } catch (e: Exception) {
                last = e
                try { c.release() } catch (_: RuntimeException) {}
            }
        }
        throw IllegalStateException("no H.264 encoder configuration worked", last)
    }

    /**
     * The camera for [f] (T-358). BACK_WIDE that cannot be resolved logs `wide_unavailable` and falls back to BACK here
     * (the setting is not changed); [facing] then says BACK so the rest of the pipeline treats it as the rear camera.
     */
    private fun resolveTarget(mgr: CameraManager, f: CameraFacing): CameraTarget? {
        val t = AndroidCameraTargets.resolve(mgr, f)
        if (t != null || f != CameraFacing.BACK_WIDE) return t
        return fallBackToBack("no_wide_camera")?.let { AndroidCameraTargets.resolve(mgr, CameraFacing.BACK) }
    }

    /** Wide-angle failed (T-358): log it, continue with BACK. Returns BACK, or null when this already is the fallback. */
    private fun fallBackToBack(why: String): CameraFacing? {
        if (facing != CameraFacing.BACK_WIDE) return null
        log(true, "camera", "state=error reason=wide_unavailable detail=$why")
        facing = CameraFacing.BACK
        return CameraFacing.BACK
    }

    /** A camera/session failure: a wide-angle one reopens the plain rear camera, anything else ends the stream. */
    private fun failOrFallback(reason: String) {
        if (fallBackToBack(reason) == null) return fail(reason)
        val h = handler ?: return
        h.post {
            if (stopRequested.get() || released) return@post
            closeCameraOnly()
            try {
                val mgr = context.getSystemService(Context.CAMERA_SERVICE) as CameraManager
                val t = AndroidCameraTargets.resolve(mgr, CameraFacing.BACK) ?: return@post fail("no_camera")
                applyCharacteristics(mgr, t.charId, outW)
                st?.setDefaultBufferSize(srcW, srcH)
                reannounce = true
                openCamera(mgr, t)
            } catch (e: SecurityException) {
                fail("permission")
            } catch (e: RuntimeException) {
                fail("wide_fallback_${e.javaClass.simpleName}")
            } catch (e: CameraAccessException) {
                fail("camera_access")
            }
        }
    }

    /** Source size, sensor orientation, fps range and autofocus support of camera [id]. */
    private fun applyCharacteristics(mgr: CameraManager, id: String, reqW: Int) {
        val ch = mgr.getCameraCharacteristics(id)
        sensorOrientation = ch.get(CameraCharacteristics.SENSOR_ORIENTATION) ?: 0
        val map = ch.get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP) ?: throw IllegalStateException("no stream map")
        val sizes = map.getOutputSizes(SurfaceTexture::class.java)?.map { it.width to it.height } ?: emptyList()
        val src = CameraMath.pickSource(sizes, reqW) ?: throw IllegalStateException("no camera size")
        srcW = src.first
        srcH = src.second
        val ranges = ch.get(CameraCharacteristics.CONTROL_AE_AVAILABLE_TARGET_FPS_RANGES)?.map { it.lower to it.upper } ?: emptyList()
        fpsRange = CameraMath.pickFpsRange(ranges, fps)?.let { Range(it.first, it.second) }
        val modes = ch.get(CameraCharacteristics.CONTROL_AF_AVAILABLE_MODES)
        afContinuous = modes?.contains(CaptureRequest.CONTROL_AF_MODE_CONTINUOUS_VIDEO) == true
        mvpKey = -1
    }

    @SuppressLint("MissingPermission")
    private fun openCamera(mgr: CameraManager, target: CameraTarget) {
        if (context.checkSelfPermission(android.Manifest.permission.CAMERA) != PackageManager.PERMISSION_GRANTED) return fail("permission")
        val gen = openGen.next() // T-357: every open attempt has its own generation
        val id = target.openId
        mgr.openCamera(id, object : CameraDevice.StateCallback() {
            override fun onOpened(d: CameraDevice) {
                if (stopRequested.get() || released || !openGen.isCurrent(gen)) { d.close(); return } // stale: a switch came first
                device = d
                createSession(d, gen, target.physicalId)
            }

            override fun onDisconnected(d: CameraDevice) {
                d.close()
                if (!openGen.isCurrent(gen)) return // a stale attempt says nothing about the current camera
                if (device === d) device = null
                if (!stopRequested.get()) failOrFallback("camera_disconnected")
            }

            override fun onError(d: CameraDevice, error: Int) {
                d.close()
                if (!openGen.isCurrent(gen)) return
                if (device === d) device = null
                if (!stopRequested.get()) failOrFallback("camera_error_$error")
            }
        }, handler)
    }

    private fun createSession(d: CameraDevice, gen: Int, physicalId: String?) {
        val surface = camSurface ?: return
        val h = handler ?: return
        try {
            val cfg = SessionConfiguration(
                SessionConfiguration.SESSION_REGULAR, listOf(OutputConfiguration(surface).also { if (physicalId != null) it.setPhysicalCameraId(physicalId) }), { r -> h.post(r) },
                object : CameraCaptureSession.StateCallback() {
                    override fun onConfigured(s: CameraCaptureSession) {
                        if (stopRequested.get() || released || device !== d) { s.close(); return }
                        session = s
                        try {
                            val req = d.createCaptureRequest(CameraDevice.TEMPLATE_RECORD).apply {
                                addTarget(surface)
                                fpsRange?.let { set(CaptureRequest.CONTROL_AE_TARGET_FPS_RANGE, it) }
                                if (afContinuous) set(CaptureRequest.CONTROL_AF_MODE, CaptureRequest.CONTROL_AF_MODE_CONTINUOUS_VIDEO)
                            }
                            s.setRepeatingRequest(req.build(), null, h)
                        } catch (e: CameraAccessException) {
                            fail("camera_access")
                            return
                        } catch (e: IllegalStateException) {
                            return // closed meanwhile
                        }
                        if (reannounce) { // after a facing switch: the host gets the config again and a keyframe behind it
                            reannounce = false
                            lastConfig?.let { sink?.onConfig(it, System.nanoTime() / 1000) }
                            requestKeyframe()
                        }
                    }

                    override fun onConfigureFailed(s: CameraCaptureSession) {
                        // T-357 r3: a late failure of an old session (after a facing switch) must not kill the new stream
                        if (stopRequested.get() || released || device !== d || !openGen.isCurrent(gen)) { try { s.close() } catch (_: RuntimeException) {}; return }
                        failOrFallback("session")
                    }
                },
            )
            d.createCaptureSession(cfg)
        } catch (e: CameraAccessException) {
            fail("camera_access")
        } catch (e: IllegalStateException) {
            // closed meanwhile
        }
    }

    private fun doSwitch(f: CameraFacing) {
        if (f == facing && device != null) return
        facing = f
        closeCameraOnly()
        try {
            val mgr = context.getSystemService(Context.CAMERA_SERVICE) as CameraManager
            val target = resolveTarget(mgr, f) ?: return fail("no_camera")
            applyCharacteristics(mgr, target.charId, outW)
            st?.setDefaultBufferSize(srcW, srcH)
            reannounce = true
            log(false, "camera", "state=switched facing=${facing.id} open=${target.openId} physical=${target.physicalId ?: "-"} src=${srcW}x$srcH")
            openCamera(mgr, target)
        } catch (e: SecurityException) {
            fail("permission")
        } catch (e: CameraAccessException) {
            fail("camera_access")
        } catch (e: RuntimeException) {
            fail("switch_${e.javaClass.simpleName}")
        }
    }

    private fun closeCameraOnly() {
        openGen.next() // an open still in flight is now stale; its device is closed when it arrives
        try { session?.close() } catch (_: RuntimeException) {}
        session = null
        try { device?.close() } catch (_: RuntimeException) {}
        device = null
    }

    /** One camera frame: copy the SurfaceTexture's image into the encoder surface, rotated upright. */
    private fun onFrame() {
        val t = st ?: return
        val g = gl ?: return
        if (stopRequested.get() || released) return
        try {
            t.updateTexImage()
            // The camera service sets the buffer transform to the sensor orientation, so the SurfaceTexture matrix
            // already turns the image upright for the display's natural orientation (device test 2026-10-18: applying
            // the sensor rotation again gave a 90-degree, squeezed image). Only the display rotation is left.
            val natural = sensorOrientation % 180 == 90
            val nw = if (natural) srcH else srcW
            val nh = if (natural) srcW else srcH
            val rot = CameraMath.naturalToDisplayDegrees(safeDisplayDegrees())
            // The camera service also mirrors the front camera's buffers (selfie preview); un-mirror so the Mac gets the
            // true image and its apps mirror their own preview (PROTOCOL.md 0x0F; device test 2026-10-18).
            val front = facing == CameraFacing.FRONT
            val key = (rot.toLong() shl 40) or (nw.toLong() shl 20) or nh.toLong() or (if (front) 1L shl 60 else 0L)
            if (key != mvpKey) {
                mvpKey = key
                mvp = CameraMath.mvp(nw, nh, rot, outW, outH).also { if (front) CameraMath.flipOutputX(it) }
            }
            g.drawFrame(t, mvp, outW, outH, t.timestamp)
        } catch (e: RuntimeException) {
            if (!stopRequested.get()) fail("gl_${e.javaClass.simpleName}")
        }
    }

    private fun safeDisplayDegrees(): Int = try { displayDegrees() } catch (_: RuntimeException) { 90 }

    private fun teardown() {
        if (released) return
        released = true
        try {
            closeCameraOnly()
            drain?.let { d ->
                d.interrupt()
                try { d.join(DRAIN_JOIN_MS) } catch (_: InterruptedException) {}
            }
            drain = null
            try { st?.setOnFrameAvailableListener(null) } catch (_: RuntimeException) {}
            try { camSurface?.release() } catch (_: RuntimeException) {}
            try { st?.release() } catch (_: RuntimeException) {}
            st = null
            camSurface = null
            try { gl?.release() } catch (_: RuntimeException) {}
            gl = null
            try { encSurface?.release() } catch (_: RuntimeException) {} // after the EGL surface on it is gone
            encSurface = null
            codec?.let { c ->
                try { c.stop() } catch (_: RuntimeException) {}
                try { c.release() } catch (_: RuntimeException) {}
            }
            codec = null
        } finally {
            closedLatch.countDown()
            thread?.quitSafely()
        }
    }

    // ---- encoder thread ----

    private fun startDrain(c: MediaCodec) {
        val t = Thread({ drainLoop(c) }, "mb-cam-enc")
        t.isDaemon = true
        drain = t
        t.start()
    }

    private fun drainLoop(c: MediaCodec) {
        val info = MediaCodec.BufferInfo()
        try {
            while (!stopRequested.get()) {
                val idx = c.dequeueOutputBuffer(info, DEQUEUE_TIMEOUT_US)
                when {
                    idx == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                        val f = c.outputFormat
                        val csd = ArrayList<ByteArray>(2)
                        for (k in listOf("csd-0", "csd-1")) {
                            f.getByteBuffer(k)?.let { bb -> csd += ByteArray(bb.remaining()).also { bb.duplicate().get(it) } }
                        }
                        if (csd.isNotEmpty()) emitConfig(csd.fold(ByteArray(0)) { a, b -> a + b }, System.nanoTime() / 1000)
                    }
                    idx >= 0 -> {
                        try {
                            val buf = c.getOutputBuffer(idx)
                            if (buf != null && info.size > 0) {
                                buf.position(info.offset)
                                buf.limit(info.offset + info.size)
                                val bytes = ByteArray(info.size)
                                buf.get(bytes)
                                if (info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG != 0) {
                                    emitConfig(bytes, info.presentationTimeUs)
                                } else {
                                    sink?.onFrame(bytes, info.presentationTimeUs, info.flags and MediaCodec.BUFFER_FLAG_KEY_FRAME != 0)
                                }
                            }
                        } finally {
                            c.releaseOutputBuffer(idx, false)
                        }
                        if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) break
                    }
                    else -> Unit // INFO_TRY_AGAIN_LATER and the deprecated buffer-changed code
                }
            }
        } catch (e: IllegalStateException) {
            if (!stopRequested.get()) fail("encoder")
        } catch (e: RuntimeException) {
            if (!stopRequested.get()) fail("encoder_${e.javaClass.simpleName}")
        }
    }

    /** A config reaches the sink once (the config buffer and the format's csd carry the same bytes). */
    private fun emitConfig(bytes: ByteArray, tsUs: Long) {
        if (bytes.contentEquals(lastConfig)) return
        lastConfig = bytes
        sink?.onConfig(bytes, tsUs)
    }

    private companion object {
        const val MIME = "video/avc"
        const val I_FRAME_INTERVAL_S = 2
        const val DEQUEUE_TIMEOUT_US = 100_000L
        const val DRAIN_JOIN_MS = 500L
        const val PREVIOUS_CLOSE_WAIT_MS = 2_000L

        /** The previous run's "everything released" latch (guarded by the companion): the next run waits for it. */
        var lastClosed: CountDownLatch? = null
    }
}
