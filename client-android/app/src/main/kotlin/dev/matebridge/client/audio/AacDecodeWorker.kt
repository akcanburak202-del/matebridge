package dev.matebridge.client.audio

import android.media.MediaCodec
import android.media.MediaFormat
import android.os.Process
import java.nio.ByteBuffer

/** The AAC decoder as [AacDecodeWorker] uses it (a fake in JVM tests; [MediaCodecAacPort] in production). */
interface AacCodecPort {
    class Output(val pcm: ByteArray, val size: Int, val ptsUs: Long)

    /** Configures and starts the decoder with AudioSpecificConfig [csd0]. Throws on failure. */
    fun start(csd0: ByteArray)

    /** Queues one access unit; false when no input buffer became free within [timeoutUs]. */
    fun queueInput(data: ByteArray, ptsUs: Long, timeoutUs: Long): Boolean

    /** The next decoded PCM (s16le stereo), or null when none within [timeoutUs]. Throws on a decoder error. */
    fun pollOutput(timeoutUs: Long): Output?

    fun release()
}

/**
 * Decodes the AAC access units of one audio stream on its own thread (decision 0038 section 4) and hands the PCM to
 * [sink] with the unit's `sample_index` and `capture_time_us`. `capture_time_us` is the capture time of the first
 * decoded frame of the unit (the host already subtracted the encoder delay); `sample_index` only keeps the jitter
 * buffer's continuity, no time is derived from it. A unit that yields several outputs advances both by the frames
 * already handed on. Audio content is never logged.
 *
 * Failure is contained: the first exception calls [onError] once, releases the decoder and the thread ends (the
 * stream is silent from then on). The decoder is released when the thread ends, whatever the reason.
 */
class AacDecodeWorker(
    private val queue: AacUnitQueue,
    private val portFactory: () -> AacCodecPort,
    private val sink: (sampleIndex: Long, captureUs: Long, pcm: ByteArray, frames: Int) -> Unit,
    private val onError: (String) -> Unit,
    private val name: String = "mb-aac",
) {
    @Volatile private var running = true
    @Volatile private var thread: Thread? = null

    /** Units that produced at least one output. */
    @Volatile var decodedUnits = 0L
        private set
    @Volatile var failed = false
        private set

    /** Units whose decoder input could not be queued in time (dropped). */
    @Volatile var inputDrops = 0L
        private set

    fun start() {
        Thread({ run() }, name).also { thread = it; it.isDaemon = true; it.start() }
    }

    /** Any thread, non-blocking: the thread exits within one poll and releases the decoder. */
    fun stop() {
        running = false
        queue.close()
    }

    fun join(ms: Long) { thread?.join(ms) }

    private class Pending(val seq: Long, val unit: AacUnit)

    private fun run() {
        try { Process.setThreadPriority(Process.THREAD_PRIORITY_AUDIO) } catch (_: RuntimeException) {}
        runLoop()
    }

    /** Separate from [run] so JVM tests (no android.os.Process) can drive it on their own thread. */
    internal fun runLoop() {
        var port: AacCodecPort? = null
        try {
            val csd = AacRules.audioSpecificConfig(AacRules.SAMPLE_RATE, AacRules.CHANNELS) ?: error("asc")
            val p = portFactory()
            port = p
            p.start(csd)
            val pending = ArrayDeque<Pending>()
            var seq = 0L
            var lastPts = -1L
            var emitted = 0
            fun drain(firstTimeoutUs: Long) {
                var t = firstTimeoutUs
                while (true) {
                    val o = p.pollOutput(t) ?: return
                    t = 0
                    if (o.size <= 0) continue
                    while (pending.isNotEmpty() && pending.first().seq < o.ptsUs) pending.removeFirst() // lost unit
                    val head = pending.firstOrNull()
                    if (head == null || head.seq != o.ptsUs) continue
                    if (o.ptsUs != lastPts) { lastPts = o.ptsUs; emitted = 0; decodedUnits++ }
                    val frames = o.size / (AacRules.CHANNELS * 2)
                    sink(
                        head.unit.sampleIndex + emitted,
                        head.unit.captureUs + emitted * 1_000_000L / AacRules.SAMPLE_RATE,
                        o.pcm,
                        frames,
                    )
                    emitted += frames
                }
            }
            while (running) {
                val u = queue.poll(POLL_MS)
                if (u == null) { drain(0); continue }
                val s = ++seq
                pending.addLast(Pending(s, u))
                while (pending.size > MAX_PENDING) pending.removeFirst()
                var queued = p.queueInput(u.data, s, INPUT_TIMEOUT_US)
                if (!queued) { drain(0); queued = p.queueInput(u.data, s, INPUT_TIMEOUT_US) }
                if (!queued) { inputDrops++; pending.removeLast(); continue }
                drain(FIRST_OUTPUT_WAIT_US)
            }
        } catch (e: Exception) {
            failed = true
            onError(e.javaClass.simpleName)
        } finally {
            running = false
            queue.close()
            try { port?.release() } catch (_: RuntimeException) {}
        }
    }

    companion object {
        /** [AacUnitQueue.poll] wakes at once on a unit or a stop; the timeout only bounds idle wakeups. */
        const val POLL_MS = 250L
        const val INPUT_TIMEOUT_US = 5_000L
        const val FIRST_OUTPUT_WAIT_US = 5_000L
        const val MAX_PENDING = 64
    }
}

/** Production [AacCodecPort]: a synchronous-mode `audio/mp4a-latm` decoder, 48 kHz stereo, raw access units. */
class MediaCodecAacPort : AacCodecPort {
    private var codec: MediaCodec? = null
    private val info = MediaCodec.BufferInfo()
    private var out = ByteArray(AacRules.FRAMES_PER_UNIT * AacRules.CHANNELS * 2)

    override fun start(csd0: ByteArray) {
        val fmt = MediaFormat.createAudioFormat(AacRules.MIME, AacRules.SAMPLE_RATE, AacRules.CHANNELS)
        fmt.setInteger(MediaFormat.KEY_AAC_PROFILE, 2) // AACObjectLC
        fmt.setByteBuffer("csd-0", ByteBuffer.wrap(csd0))
        val c = MediaCodec.createDecoderByType(AacRules.MIME)
        codec = c
        c.configure(fmt, null, null, 0)
        c.start()
    }

    override fun queueInput(data: ByteArray, ptsUs: Long, timeoutUs: Long): Boolean {
        val c = codec ?: return false
        val i = c.dequeueInputBuffer(timeoutUs)
        if (i < 0) return false
        val b = c.getInputBuffer(i) ?: return false
        b.clear()
        b.put(data)
        c.queueInputBuffer(i, 0, data.size, ptsUs, 0)
        return true
    }

    override fun pollOutput(timeoutUs: Long): AacCodecPort.Output? {
        val c = codec ?: return null
        var wait = timeoutUs
        while (true) {
            val i = c.dequeueOutputBuffer(info, wait)
            when {
                i == MediaCodec.INFO_TRY_AGAIN_LATER -> return null
                i == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                    val f = c.outputFormat
                    val ch = if (f.containsKey(MediaFormat.KEY_CHANNEL_COUNT)) f.getInteger(MediaFormat.KEY_CHANNEL_COUNT) else AacRules.CHANNELS
                    val sr = if (f.containsKey(MediaFormat.KEY_SAMPLE_RATE)) f.getInteger(MediaFormat.KEY_SAMPLE_RATE) else AacRules.SAMPLE_RATE
                    if (ch != AacRules.CHANNELS || sr != AacRules.SAMPLE_RATE) throw IllegalStateException("format")
                    wait = 0
                }
                i < 0 -> wait = 0
                else -> {
                    try {
                        val size = info.size
                        if (out.size < size) out = ByteArray(size)
                        val b = c.getOutputBuffer(i)
                        if (b == null || size <= 0) return AacCodecPort.Output(out, 0, info.presentationTimeUs)
                        b.position(info.offset)
                        b.get(out, 0, size)
                        return AacCodecPort.Output(out, size, info.presentationTimeUs)
                    } finally {
                        c.releaseOutputBuffer(i, false)
                    }
                }
            }
        }
    }

    override fun release() {
        val c = codec ?: return
        codec = null
        try { c.stop() } catch (_: RuntimeException) {}
        c.release()
    }
}

/** Whether this device has an `audio/mp4a-latm` decoder (HELLO bit14). Android only. */
object AacDecoderProbe {
    val available: Boolean by lazy {
        try {
            android.media.MediaCodecList(android.media.MediaCodecList.REGULAR_CODECS).codecInfos
                .any { !it.isEncoder && it.supportedTypes.any { t -> t.equals(AacRules.MIME, ignoreCase = true) } }
        } catch (_: RuntimeException) {
            false
        }
    }
}
