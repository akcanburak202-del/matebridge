package dev.matebridge.client.audio

import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioRouting
import android.media.AudioTimestamp
import android.media.AudioTrack
import android.os.Handler

/**
 * AudioTrack output (decision 0011, the pre-T-100 path): low-latency mode, WRITE_BLOCKING writes of one burst.
 * [interrupt] (any thread) pauses and flushes, which unblocks a write in progress; it shares a lock with [close], so a
 * stop can never touch a released track, and the release happens exactly once. A change of the routed output device
 * calls `onRouteChange` (main thread), and the writer rebuilds.
 */
class TrackSink private constructor(
    private val track: AudioTrack,
    private val usage: Int,
    override val burst: Int,
    private val maxBursts: Int,
    override var bufFrames: Int,
    override val preFrames: Long,
) : AudioSink {
    override val api = "track"
    override val exclusive = false
    override val mmap = -1
    override var deadReason = ""
        private set
    override var lastError = 0
        private set
    @Volatile private var deviceId: Int? = null
    private var routing: AudioRouting.OnRoutingChangedListener? = null
    private val ts = AudioTimestamp()
    private val lock = Any()
    private var closed = false

    override val perfName: String get() = when (track.performanceMode) {
        AudioTrack.PERFORMANCE_MODE_LOW_LATENCY -> "low_latency"
        AudioTrack.PERFORMANCE_MODE_POWER_SAVING -> "power_saving"
        else -> "none"
    }

    override fun logFields(): String =
        "api=$api sharing=- mmap=- burst=$burst buf=$bufFrames capacity=${track.bufferCapacityInFrames} " +
            "perf_mode=$perfName usage=${if (usage == AudioAttributes.USAGE_GAME) "game" else "media"}"

    override fun write(pcm: ShortArray, frames: Int): Int {
        val w = track.write(pcm, 0, frames * CHANNELS, AudioTrack.WRITE_BLOCKING)
        if (w >= 0) return w / CHANNELS
        lastError = w
        if (w == AudioTrack.ERROR_DEAD_OBJECT) {
            deadReason = "dead_object"
            return AudioSink.WRITE_DEAD
        }
        return AudioSink.WRITE_FAILED
    }

    override fun timestamp(out: LongArray): Boolean {
        if (!track.getTimestamp(ts)) return false
        out[0] = ts.framePosition
        out[1] = ts.nanoTime
        return true
    }

    override fun xruns(): Int = track.underrunCount

    override fun grow(): Boolean {
        if (bufFrames >= maxBursts * burst) return false
        val r = track.setBufferSizeInFrames(bufFrames + burst)
        if (r > 0) bufFrames = r
        return r > 0
    }

    /** Unblocks a WRITE_BLOCKING write in progress (it returns a short count) and drops the queued audio. */
    override fun interrupt(): Unit = synchronized(lock) {
        if (closed) return
        try { track.pause() } catch (_: RuntimeException) {}
        try { track.flush() } catch (_: RuntimeException) {}
    }

    override fun close(): Unit = synchronized(lock) {
        if (closed) return
        closed = true
        routing?.let { try { track.removeOnRoutingChangedListener(it) } catch (_: RuntimeException) {} }
        try { track.pause() } catch (_: RuntimeException) {}
        try { track.flush() } catch (_: RuntimeException) {}
        track.release()
    }

    companion object {
        private const val RATE = AudioStreamGate.SAMPLE_RATE
        private const val CHANNELS = 2
        private const val BYTES_PER_FRAME = 4

        private fun build(usage: Int, burst: Int, maxBursts: Int): AudioTrack {
            val attrs = AudioAttributes.Builder().setUsage(usage).setContentType(AudioAttributes.CONTENT_TYPE_MOVIE).build()
            val fmt = AudioFormat.Builder()
                .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                .setSampleRate(RATE)
                .setChannelMask(AudioFormat.CHANNEL_OUT_STEREO)
                .build()
            val minBytes = AudioTrack.getMinBufferSize(RATE, AudioFormat.CHANNEL_OUT_STEREO, AudioFormat.ENCODING_PCM_16BIT)
            val bytes = maxOf(minBytes, burst * maxBursts * BYTES_PER_FRAME)
            return AudioTrack.Builder()
                .setAudioAttributes(attrs)
                .setAudioFormat(fmt)
                .setBufferSizeInBytes(bytes)
                .setTransferMode(AudioTrack.MODE_STREAM)
                .setPerformanceMode(AudioTrack.PERFORMANCE_MODE_LOW_LATENCY)
                .build()
        }

        /**
         * Opens and starts a track with [burst]-frame writes. USAGE_MEDIA first; USAGE_GAME only if it gets the FAST
         * path and MEDIA did not. Throws [SinkOpenException]; nothing is left open on failure.
         */
        fun open(burst: Int, startBursts: Int, maxBursts: Int, handler: Handler, onRouteChange: () -> Unit): TrackSink {
            var usage = AudioAttributes.USAGE_MEDIA
            var at = try {
                build(usage, burst, maxBursts)
            } catch (e: RuntimeException) {
                throw SinkOpenException("usage=media err=${e.javaClass.simpleName}")
            }
            if (at.performanceMode != AudioTrack.PERFORMANCE_MODE_LOW_LATENCY) {
                val game = try { build(AudioAttributes.USAGE_GAME, burst, maxBursts) } catch (_: RuntimeException) { null }
                if (game != null && game.performanceMode == AudioTrack.PERFORMANCE_MODE_LOW_LATENCY) {
                    at.release()
                    at = game
                    usage = AudioAttributes.USAGE_GAME
                } else {
                    game?.release()
                }
            }
            if (at.state != AudioTrack.STATE_INITIALIZED) {
                at.release()
                throw SinkOpenException("reason=not_initialized")
            }
            val t: TrackSink
            try {
                val got = at.setBufferSizeInFrames(startBursts * burst)
                // One burst of silence before play() (T-095 review L5): the mixer's first pull does not count an underrun.
                val pre = at.write(ShortArray(burst * CHANNELS), 0, burst * CHANNELS, AudioTrack.WRITE_NON_BLOCKING).coerceAtLeast(0) / CHANNELS
                t = TrackSink(at, usage, burst, maxBursts, if (got > 0) got else at.bufferSizeInFrames, pre.toLong())
            } catch (e: RuntimeException) {
                at.release()
                throw SinkOpenException("stage=configure err=${e.javaClass.simpleName}")
            }
            try {
                val l = AudioRouting.OnRoutingChangedListener { router ->
                    val dev = router.routedDevice?.id ?: return@OnRoutingChangedListener
                    val prev = t.deviceId
                    t.deviceId = dev
                    if (prev != null && prev != dev) onRouteChange()
                }
                t.routing = l
                at.addOnRoutingChangedListener(l, handler)
                at.play()
                if (t.deviceId == null) t.deviceId = at.routedDevice?.id
            } catch (e: RuntimeException) {
                t.close()
                throw SinkOpenException("stage=play err=${e.javaClass.simpleName}")
            }
            return t
        }
    }
}
