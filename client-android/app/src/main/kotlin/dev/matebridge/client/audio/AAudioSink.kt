package dev.matebridge.client.audio

/**
 * AAudio output (decision 0012) through [AAudioNative]. The stream is opened, started, written, timestamped and
 * closed by the writer thread only, so the native side needs no locks. [write] blocks inside AAudio at most
 * [WRITE_TIMEOUT_NS] (normally one burst); a write that times out means the device stopped consuming ("stall") and
 * the stream is rebuilt. [interrupt] does nothing: the writer sees its stop flag within one burst, and no AAudio call
 * is ever made concurrently with a write.
 */
class AAudioSink private constructor(
    private val handle: Long,
    info: IntArray,
    maxBursts: Int,
) : AudioSink {
    override val api = "aaudio"
    private val sharing = info[AAudioNative.I_SHARING]
    override val exclusive = sharing == AAudioNative.SHARING_EXCLUSIVE
    override val mmap = info[AAudioNative.I_MMAP]
    override val burst = info[AAudioNative.I_BURST]
    private val capacity = info[AAudioNative.I_CAPACITY]
    private val maxBufFrames = minOf(capacity, maxBursts * burst)
    override var bufFrames = info[AAudioNative.I_BUF]
        private set
    override val preFrames = info[AAudioNative.I_PRE].toLong()
    override val perfName = when (info[AAudioNative.I_PERF]) {
        AAudioNative.PERF_LOW_LATENCY -> "low_latency"
        AAudioNative.PERF_LOW_LATENCY - 1 -> "power_saving"
        else -> "none"
    }
    override var deadReason = ""
        private set
    override var lastError = 0
        private set
    private var closed = false

    override fun logFields(): String =
        "api=$api sharing=${if (exclusive) "exclusive" else "shared"} mmap=$mmap burst=$burst buf=$bufFrames " +
            "capacity=$capacity perf_mode=$perfName"

    override fun write(pcm: ShortArray, frames: Int): Int {
        val r = AAudioNative.write(handle, pcm, frames, WRITE_TIMEOUT_NS)
        if (r == frames) return r
        if (r >= 0) {
            lastError = AAudioNative.ERROR_TIMEOUT
            deadReason = "stall"
            return AudioSink.WRITE_DEAD
        }
        lastError = r
        if (r == AAudioNative.ERROR_DISCONNECTED) {
            deadReason = "disconnected"
            return AudioSink.WRITE_DEAD
        }
        return AudioSink.WRITE_FAILED
    }

    override fun timestamp(out: LongArray): Boolean = AAudioNative.timestamp(handle, out) == AAudioNative.OK

    override fun xruns(): Int = AAudioNative.xruns(handle).coerceAtLeast(0)

    override fun grow(): Boolean {
        if (bufFrames + burst > maxBufFrames) return false
        val r = AAudioNative.setBufferSize(handle, bufFrames + burst)
        if (r > 0) bufFrames = r
        return r > 0
    }

    override fun interrupt() = Unit

    override fun close() {
        if (closed) return
        closed = true
        AAudioNative.close(handle)
    }

    companion object {
        const val WRITE_TIMEOUT_NS = 200_000_000L

        /** Opens and starts a LOW_LATENCY stream with [sharing] (AAudioNative.SHARING_*); throws [SinkOpenException]. */
        fun open(sharing: Int, startBursts: Int, maxBursts: Int): AAudioSink {
            if (!AAudioNative.available) throw SinkOpenException("err=no_library")
            val info = IntArray(AAudioNative.I_COUNT)
            val h = AAudioNative.open(sharing, startBursts, info)
            if (h == 0L) {
                throw SinkOpenException(
                    "stage=${info[AAudioNative.I_STAGE]} err=${AAudioNative.errorText(info[AAudioNative.I_ERROR])} " +
                        "rate=${info[AAudioNative.I_RATE]} ch=${info[AAudioNative.I_CHANNELS]} format=${info[AAudioNative.I_FORMAT]}",
                )
            }
            val r = AAudioNative.start(h)
            if (r != AAudioNative.OK) {
                AAudioNative.close(h)
                throw SinkOpenException("stage=start err=${AAudioNative.errorText(r)}")
            }
            return AAudioSink(h, info, maxBursts)
        }
    }
}
