package dev.matebridge.client.video

import android.graphics.ImageFormat
import android.hardware.HardwareBuffer
import android.media.Image
import android.media.ImageReader
import android.os.Handler
import android.os.HandlerThread
import android.view.Surface
import dev.matebridge.client.protocol.KeyframeRequest
import dev.matebridge.client.protocol.StreamConfig
import dev.matebridge.client.protocol.VideoFrame
import dev.matebridge.client.session.MbLog

/**
 * The packed full colour video path (decision 0034, `chroma_layout = 1`): two decoders (the main one is the existing
 * [VideoRenderer], pointed at the main ImageReader; the auxiliary one is [AuxDecoder]), the [PackedPresenter] GL thread
 * that merges and shows them in the SurfaceView, and the auxiliary stream's bounded queue. UI thread: [start], [stop];
 * any thread: [onAuxFrame], [takeAuxRetry], [statsFields].
 *
 * The direct path (`chroma_layout = 0`) never creates this class.
 */
class FullChromaPipeline(
    private val renderer: VideoRenderer,
    /** `KEYFRAME_REQUEST(reason, view = 1)`; any thread. */
    private val sendAuxKeyframeRequest: (reason: Int) -> Unit,
    /** The presenter failed to start or kept failing (any thread): the owner falls back to the direct path. */
    private val onFailed: (String) -> Unit,
    private val extraLeadNs: Long = DEFAULT_EXTRA_LEAD_NS,
) {
    companion object {
        /** GL pass (~3 ms, T-256) plus the ImageReader hop, added to the dispatch lead of the main stream's slot logic. */
        const val DEFAULT_EXTRA_LEAD_NS = 4_000_000L

        /** ImageReader depth: a few images in flight, being drawn, and waiting to be closed (T-254 used 6). */
        const val MAX_IMAGES = 6

        /** True when the packed path can run for [c] at all (size layout, library loaded). */
        fun supports(c: StreamConfig): Boolean =
            FullChromaNative.available && c.isPacked444 && c.codec == StreamConfig.CODEC_HEVC && Avc444v2.isValid(c.widthPx, c.heightPx)
    }

    private fun log(level: Char, ev: String, fields: String) = when (level) {
        'E' -> MbLog.e(ev, fields, "render")
        'W' -> MbLog.w(ev, fields, "render")
        else -> MbLog.i(ev, fields, "render")
    }

    private var presenter: PackedPresenter? = null
    private var auxDecoder: AuxDecoder? = null
    private var auxQueue: AuxFrameQueue? = null
    private var mainReader: ImageReader? = null
    private var auxReader: ImageReader? = null
    private var mainThread: HandlerThread? = null
    private var auxThread: HandlerThread? = null
    @Volatile private var failedReported = false

    /** True between a successful [start] and [stop]. */
    @Volatile var active = false
        private set

    @Volatile private var auxUnmatched = 0L
    @Volatile private var imageErrors = 0L

    /**
     * Builds the pipeline for [config] on [surface] (the SurfaceView's) and points the main renderer at the main
     * ImageReader. False when it cannot be built (the caller then uses the direct path): nothing is left running.
     */
    fun start(surface: Surface, config: StreamConfig): Boolean {
        if (active) stop()
        if (!supports(config)) {
            log('W', "full_chroma_unsupported", "layout=${config.chromaLayout} size=${config.widthPx}x${config.heightPx}")
            return false
        }
        if (!PackedPresenter.awaitPrevious(1_000)) {
            // The old GL thread is stuck inside a native call: a new presenter would replace its context. Direct path.
            log('E', "full_chroma_gl_busy", "reason=previous_presenter_alive")
            return false
        }
        failedReported = false
        auxUnmatched = 0
        imageErrors = 0
        try {
            val w = config.widthPx
            val h = config.heightPx
            val usage = HardwareBuffer.USAGE_GPU_SAMPLED_IMAGE
            val mt = HandlerThread("mb-img-main").also { it.start() }
            val at = HandlerThread("mb-img-aux").also { it.start() }
            mainThread = mt
            auxThread = at
            val main = ImageReader.newInstance(w, h, ImageFormat.PRIVATE, MAX_IMAGES, usage)
            val aux = ImageReader.newInstance(w, h, ImageFormat.PRIVATE, MAX_IMAGES, usage)
            mainReader = main
            auxReader = aux

            val pres = PackedPresenter(
                surface, w, h, YuvConversion.of(config.matrix, config.fullRange == 1), this::log,
                onShown = { pts, ns -> renderer.reportPackedShown(pts, ns) },
                onFailed = { why -> reportFailure(why) },
            )
            presenter = pres

            val queue = AuxFrameQueue(FrameQueue.depthForFps(config.fps))
            auxQueue = queue
            val dec = AuxDecoder(
                config, aux.surface, queue, sendAuxKeyframeRequest,
                onGaveUp = { why ->
                    log('E', "aux_give_up", "reason=${why.take(40)}")
                    reportFailure("aux_give_up") // main-only from here on: the owner drops to chroma = 1 for the process
                },
            )
            auxDecoder = dec

            main.setOnImageAvailableListener({ r -> drain(r) { img -> pres.offerMain(img, img.timestamp / 1000) } }, Handler(mt.looper))
            aux.setOnImageAvailableListener({ r ->
                drain(r) { img ->
                    val cap = dec.captureOf(img.timestamp / 1000)
                    if (cap == null) { auxUnmatched++; runCatching { img.close() } } else pres.offerAux(img, cap)
                }
            }, Handler(at.looper))

            renderer.packed = object : PackedOutput {
                override fun onRelease(pts: Long, captureUs: Long?, renderNs: Long) =
                    pres.expect(pts, captureUs ?: Long.MIN_VALUE, renderNs)
                override val extraLeadNs: Long get() = this@FullChromaPipeline.extraLeadNs
            }
            pres.start()
            dec.start()
            active = true
            renderer.attachSurface(main.surface)
            log('I', "full_chroma_start", "size=${w}x$h fps=${config.fps} extra_lead_us=${extraLeadNs / 1000} aux_depth=${queue.depth}")
            return true
        } catch (e: Throwable) {
            log('E', "full_chroma_start_failed", "err=${e.javaClass.simpleName}")
            teardown()
            return false
        }
    }

    /**
     * Stops everything, main decoder first (no release may follow the presenter), then the auxiliary decoder, the GL
     * thread (the EGL surface is gone afterwards) and the readers. UI thread; bounded waits.
     */
    fun stop() {
        if (!active && presenter == null) return
        renderer.detachSurface()
        teardown()
    }

    private fun teardown() {
        active = false
        renderer.packed = null
        // No image may reach the presenter or the pending queue once they are going away.
        runCatching { mainReader?.setOnImageAvailableListener(null, null) }
        runCatching { auxReader?.setOnImageAvailableListener(null, null) }
        auxDecoder?.stop()
        presenter?.shutdown()
        runCatching { mainReader?.close() }
        runCatching { auxReader?.close() }
        mainThread?.quitSafely()
        auxThread?.quitSafely()
        presenter = null; auxDecoder = null; auxQueue = null; mainReader = null; auxReader = null
        mainThread = null; auxThread = null
    }

    /** A VIDEO_FRAME of the auxiliary view. Any thread; dropped while the pipeline is not running. */
    fun onAuxFrame(frame: VideoFrame) {
        if (!active) return
        auxDecoder?.onFrame(frame)
    }

    /** Periodic keyframe retry of the auxiliary stream while its gate is closed (through its own request limit). */
    fun takeAuxRetry(): Boolean = active && auxDecoder?.gaveUp != true && auxQueue?.takeRetry() == true

    /**
     * `chroma_layout=1 aux_paired_pct= aux_late= gl_ms_p50= gl_ms_p95= ...` for one log window ([StatsFormat.fullChromaFields]),
     * counters reset with [reset].
     */
    fun statsFields(reset: Boolean = true): String {
        val snap = presenter?.snapshot(reset)
        val q = auxQueue?.counters(reset)
        val dec = auxDecoder
        return FullChromaStatsFormat.fields(
            1, snap, q?.dropped ?: 0, q?.kfRequests ?: 0, dec?.restarts ?: 0, dec?.gaveUp == true, auxUnmatched, imageErrors,
        )
    }

    private fun reportFailure(why: String) {
        if (failedReported) return
        failedReported = true
        log('E', "full_chroma_failed", "reason=${why.take(60)}")
        onFailed(why)
    }

    /** Takes every image the reader has (a burst), handing each to [sink]; a full reader is counted, never fatal. */
    private inline fun drain(r: ImageReader, sink: (Image) -> Unit) {
        while (true) {
            val img = try { r.acquireNextImage() } catch (e: IllegalStateException) { imageErrors++; null } ?: return
            sink(img)
        }
    }
}

/** `render ev=stats` fields of the full colour path (docs/LOGGING.md). Pure Kotlin. */
object FullChromaStatsFormat {
    private fun f1(v: Double?) = if (v == null) "-" else String.format(java.util.Locale.ROOT, "%.1f", v)
    private fun f2(v: Double?) = if (v == null) "-" else String.format(java.util.Locale.ROOT, "%.2f", v)

    /**
     * `chroma_layout=<0|1> aux_paired_pct=<%.1f|-> aux_late=<n|-> gl_ms_p50=<%.2f|-> gl_ms_p95=<%.2f|->`, and with layout 1
     * also `gl_drawn= gl_displaced= gl_errors= gl_outstanding_max= aux_drop= aux_kf_req= aux_restarts= aux_dead= aux_unmatched=
     * img_errors=`. Layout 0 (the direct path) carries only the first group, all `-`.
     */
    fun fields(
        layout: Int, s: PackedPresenter.Snapshot?, auxDropped: Long = 0, auxKfRequests: Long = 0, auxRestarts: Long = 0,
        auxDead: Boolean = false, auxUnmatched: Long = 0, imageErrors: Long = 0,
    ): String {
        val head = "chroma_layout=$layout aux_paired_pct=${f1(s?.pairedPct)} aux_late=${s?.mainOnly?.toString() ?: "-"} " +
            "gl_ms_p50=${f2(s?.glMsP50)} gl_ms_p95=${f2(s?.glMsP95)}"
        if (layout != 1) return head
        return head + " gl_drawn=${s?.drawn ?: 0} gl_displaced=${s?.displaced ?: 0} gl_errors=${s?.drawErrors ?: 0} " +
            "gl_outstanding_max=${s?.outstandingMax ?: 0} aux_drop=$auxDropped aux_kf_req=$auxKfRequests " +
            "aux_restarts=$auxRestarts aux_dead=${if (auxDead) 1 else 0} aux_unmatched=$auxUnmatched img_errors=$imageErrors"
    }
}
