package dev.matebridge.client.video

import java.nio.ByteBuffer

/**
 * T-159 debug fault injection (`--es decoder_fault create|configure|dequeue|silent`, `--ei decoder_fault_after_s N`,
 * default 10): a [DecoderCodec.Factory] decorator around the production factory. Armed at launch; it fires once, after
 * the stream has been HEALTHY for [afterS] seconds ([onHealthy]), so input is live when the fault hits (T-164 tests a
 * fault with Shift held and the pen down):
 * - `dequeue` / `silent`: every codec of the current generation (the running one and its `decode_error` restarts):
 *   `dequeueOutputBuffer` throws, or the codec is drained without rendering (input accepted, no output: T-028).
 * - `create` / `configure`: every codec of the next generation (e.g. a mode change or a surface re-attach) fails there.
 * The generation after the faulted one runs clean, so the video-health recovery can be timed. One fault per launch.
 *
 * [onHealthy] and [onGeneration] run on the UI thread; the codec calls on the decoder threads.
 */
class DecoderFault(
    val mode: Mode,
    val afterS: Int,
    private val inner: DecoderCodec.Factory,
    /** The `ev=decoder_fault` fields, logged once when the fault fires. */
    private val log: (String) -> Unit,
) : DecoderCodec.Factory {
    enum class Mode(val logName: String) { CREATE("create"), CONFIGURE("configure"), DEQUEUE("dequeue"), SILENT("silent") }

    private enum class Phase { ARMED, PENDING, ACTIVE, DONE }

    companion object {
        const val EXTRA_MODE = "decoder_fault"
        const val EXTRA_AFTER_S = "decoder_fault_after_s"
        const val DEFAULT_AFTER_S = 10

        fun parseMode(raw: String?): Mode? = Mode.values().firstOrNull { it.logName == raw }
    }

    @Volatile private var phase = Phase.ARMED
    private var faultGen = -1 // UI thread only

    /** The fault is hitting codecs now. */
    val active: Boolean get() = phase == Phase.ACTIVE
    /** It has fired (it never fires again). */
    val fired: Boolean get() = phase != Phase.ARMED

    /** UI thread, each ticker run: the current generation [gen] has been HEALTHY for [healthyMs]. */
    fun onHealthy(healthyMs: Long, gen: Int) {
        if (phase != Phase.ARMED || healthyMs < afterS * 1000L) return
        log("mode=${mode.logName} armed_s=$afterS")
        faultGen = gen
        phase = if (mode == Mode.DEQUEUE || mode == Mode.SILENT) Phase.ACTIVE else Phase.PENDING
    }

    /** UI thread: generation [gen] began (before its decoder thread starts). */
    fun onGeneration(gen: Int) {
        when (phase) {
            Phase.PENDING -> if (gen > faultGen) { faultGen = gen; phase = Phase.ACTIVE }
            Phase.ACTIVE -> if (gen > faultGen) phase = Phase.DONE
            else -> {}
        }
    }

    override fun create(mime: String): DecoderCodec {
        if (active && mode == Mode.CREATE) throw java.io.IOException("injected create failure")
        return Codec(inner.create(mime))
    }

    private inner class Codec(private val c: DecoderCodec) : DecoderCodec {
        override val name: String get() = c.name
        override fun lowLatencySupport(mime: String) = c.lowLatencySupport(mime)

        override fun configure(format: DecoderFormat, surface: Any) {
            if (active && mode == Mode.CONFIGURE) throw IllegalStateException("injected configure failure")
            c.configure(format, surface)
        }

        override fun start() = c.start()
        override fun dequeueInputBuffer(timeoutUs: Long) = c.dequeueInputBuffer(timeoutUs)
        override fun getInputBuffer(index: Int): ByteBuffer? = c.getInputBuffer(index)
        override fun queueInputBuffer(index: Int, offset: Int, size: Int, presentationTimeUs: Long, flags: Int) =
            c.queueInputBuffer(index, offset, size, presentationTimeUs, flags)

        override fun dequeueOutputBuffer(info: DecoderCodec.OutputInfo, timeoutUs: Long): Int {
            if (active && mode == Mode.DEQUEUE) throw IllegalStateException("injected dequeue failure")
            val idx = c.dequeueOutputBuffer(info, timeoutUs)
            if (idx >= 0 && active && mode == Mode.SILENT) {
                c.releaseOutputBuffer(idx, false) // decoded but never shown: the renderer sees no output
                return DecoderCodec.INFO_TRY_AGAIN_LATER
            }
            return idx
        }

        override fun releaseOutputBuffer(index: Int, renderTimestampNs: Long) = c.releaseOutputBuffer(index, renderTimestampNs)
        override fun releaseOutputBuffer(index: Int, render: Boolean) = c.releaseOutputBuffer(index, render)
        override fun setOnFrameRenderedListener(listener: (presentationTimeUs: Long, nanoTime: Long) -> Unit) =
            c.setOnFrameRenderedListener(listener)
        override val inputFormat: DecoderCodec.FormatView get() = c.inputFormat
        override val outputFormat: DecoderCodec.FormatView get() = c.outputFormat
        override fun stop() = c.stop()
        override fun release() = c.release()
    }
}
