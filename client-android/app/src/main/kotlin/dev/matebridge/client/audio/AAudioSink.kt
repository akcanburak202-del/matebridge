package dev.matebridge.client.audio

/**
 * AAudio output (decision 0012) through [AAudioNative]. The stream is opened, started, written, timestamped and
 * closed by the writer thread only, so the native side needs no locks. [write] blocks inside AAudio at most
 * [WRITE_TIMEOUT_NS] (normally one burst; [START_WRITE_TIMEOUT_NS] during the first [START_GRACE_NS], while an MMAP
 * stream may still be starting, T-100 review L2); a write that times out means the device stopped consuming ("stall")
 * and the stream is rebuilt. The timeout holds only for MMAP streams, which is why [SinkPolicy] rejects legacy ones.
 * [interrupt] does nothing: the writer sees its stop flag within one burst, and no AAudio call is ever made
 * concurrently with a write. A LinkageError from the native library propagates to the writer, which disables AAudio.
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
    private val openedNs = System.nanoTime()

    override fun logFields(): String =
        "api=$api sharing=${if (exclusive) "exclusive" else "shared"} mmap=$mmap burst=$burst buf=$bufFrames " +
            "capacity=$capacity max_buf=$maxBufFrames perf_mode=$perfName"

    override fun write(pcm: ShortArray, frames: Int): Int {
        val timeout = if (System.nanoTime() - openedNs < START_GRACE_NS) START_WRITE_TIMEOUT_NS else WRITE_TIMEOUT_NS
        val r = AAudioNative.write(handle, pcm, frames, timeout)
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

    /** The native side zeroes the timestamp fields when getTimestamp fails (no timestamp yet: the read counter is used). */
    override fun counters(out: LongArray): Boolean = AAudioNative.counters(handle, out) != AAudioNative.ERROR_NULL

    override fun xruns(): Int = AAudioNative.xruns(handle).coerceAtLeast(0)

    private val headroomBuf = LongArray(AAudioNative.C_COUNT)
    private val estimator = HeadroomEstimator()

    /** T-114: from AAudio's counters and timestamp ([HeadroomEstimator]); no allocation. */
    override fun headroom(): Long {
        if (AAudioNative.counters(handle, headroomBuf) == AAudioNative.ERROR_NULL) return AudioSink.HEADROOM_UNKNOWN
        val b = headroomBuf
        return estimator.estimate(
            b[AAudioNative.C_WRITTEN], b[AAudioNative.C_READ], b[AAudioNative.C_TS_POS], b[AAudioNative.C_TS_NS], b[AAudioNative.C_NOW],
        )
    }

    override val headroomCounter: Long get() = estimator.counterHeadroom

    override val headroomFromTs: Boolean get() = estimator.source == HeadroomEstimator.Source.TIMESTAMP

    /** The largest buffer [grow] may reach: min(capacity, max bursts × burst). */
    val maxFrames: Int get() = maxBufFrames

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
        const val START_WRITE_TIMEOUT_NS = 1_000_000_000L
        const val START_GRACE_NS = 500_000_000L

        /**
         * Opens and starts a LOW_LATENCY stream with [sharing] (AAudioNative.SHARING_*); throws [SinkOpenException]
         * (with `aaudioUnusable` when the native library itself failed).
         */
        fun open(sharing: Int, startBursts: Int, maxBursts: Int): AAudioSink {
            if (!AAudioNative.available) throw SinkOpenException("err=no_library", aaudioUnusable = true)
            return try {
                openNative(sharing, startBursts, maxBursts)
            } catch (e: LinkageError) {
                throw SinkOpenException("err=${e.javaClass.simpleName}", aaudioUnusable = true)
            }
        }

        private fun openNative(sharing: Int, startBursts: Int, maxBursts: Int): AAudioSink {
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
