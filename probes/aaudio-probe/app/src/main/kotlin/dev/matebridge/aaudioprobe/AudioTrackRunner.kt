package dev.matebridge.aaudioprobe

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioTimestamp
import android.media.AudioTrack

/**
 * Case (c): AudioTrack configured like the product's AudioPlayout.buildTrack (USAGE_MEDIA, CONTENT_TYPE_MOVIE,
 * 48 kHz s16 stereo, PERFORMANCE_MODE_LOW_LATENCY, MODE_STREAM, 2 bursts to start, +1 burst per underrun).
 */
class AudioTrackRunner(private val ctx: Context) {

    fun run(case: String, durationMs: Int, amplitude: Float, stopRequested: () -> Boolean): ProbeResult {
        val am = ctx.getSystemService(AudioManager::class.java)
        val native = am?.getProperty(AudioManager.PROPERTY_OUTPUT_FRAMES_PER_BUFFER)?.toIntOrNull() ?: 0
        val burst = if (native in MIN_BURST..MAX_BURST) native else DEFAULT_BURST

        val attrs = AudioAttributes.Builder()
            .setUsage(AudioAttributes.USAGE_MEDIA)
            .setContentType(AudioAttributes.CONTENT_TYPE_MOVIE)
            .build()
        val fmt = AudioFormat.Builder()
            .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
            .setSampleRate(RATE)
            .setChannelMask(AudioFormat.CHANNEL_OUT_STEREO)
            .build()
        val minBytes = AudioTrack.getMinBufferSize(RATE, AudioFormat.CHANNEL_OUT_STEREO, AudioFormat.ENCODING_PCM_16BIT)
        val track = try {
            AudioTrack.Builder()
                .setAudioAttributes(attrs)
                .setAudioFormat(fmt)
                .setBufferSizeInBytes(maxOf(minBytes, burst * MAX_BURSTS * BYTES_PER_FRAME))
                .setTransferMode(AudioTrack.MODE_STREAM)
                .setPerformanceMode(AudioTrack.PERFORMANCE_MODE_LOW_LATENCY)
                .build()
        } catch (e: RuntimeException) {
            return failed(case, burst, "${e.javaClass.simpleName}", "open")
        }

        val samples = ArrayList<Sample>(4096)
        var written = 0L
        var startNs = 0L
        var tsFail = 0L
        val bufDefault: Int
        val bufStart: Int
        try {
            if (track.state != AudioTrack.STATE_INITIALIZED) return failed(case, burst, "not_initialized", "open")
            bufDefault = track.bufferSizeInFrames
            val got = track.setBufferSizeInFrames(START_BURSTS * burst)
            bufStart = if (got > 0) got else track.bufferSizeInFrames
            var bufFrames = bufStart

            val tone = ToneGen(RATE, amplitude)
            val buf = ShortArray(burst * CHANNELS)
            tone.fill(buf, burst, CHANNELS)
            written += track.write(buf, 0, buf.size, AudioTrack.WRITE_NON_BLOCKING).coerceAtLeast(0) / CHANNELS

            track.play()
            startNs = System.nanoTime()
            val endNs = startNs + durationMs * 1_000_000L
            val ts = AudioTimestamp()
            var lastUnderruns = 0
            while (!stopRequested() && System.nanoTime() < endNs) {
                tone.fill(buf, burst, CHANNELS)
                val w = track.write(buf, 0, buf.size, AudioTrack.WRITE_BLOCKING)
                if (w < 0) return failed(case, burst, "write_$w", "write")
                written += w / CHANNELS

                val u = track.underrunCount
                if (u > lastUnderruns) {
                    lastUnderruns = u
                    if (bufFrames + burst <= track.bufferCapacityInFrames) {
                        val r = track.setBufferSizeInFrames(bufFrames + burst)
                        if (r > 0) bufFrames = r
                    }
                }

                if (track.getTimestamp(ts)) {
                    if (samples.size < MAX_SAMPLES) samples.add(Sample(written, ts.framePosition, ts.nanoTime, System.nanoTime()))
                } else {
                    tsFail++
                }
            }

            return ProbeResult(
                case = case,
                api = "audiotrack",
                reqSharing = "n/a",
                sharing = "n/a",
                perf = perfName(track.performanceMode),
                mmap = null,
                burst = burst,
                capacity = track.bufferCapacityInFrames,
                bufDefault = bufDefault,
                bufStart = bufStart,
                bufFinal = track.bufferSizeInFrames,
                rate = track.sampleRate,
                channels = track.channelCount,
                format = "i16",
                xruns = track.underrunCount,
                framesWritten = written,
                tsFail = tsFail,
                error = "0",
                stage = "none",
                startNs = startNs,
                samples = samples,
            )
        } finally {
            try { track.stop() } catch (_: IllegalStateException) {}
            track.release()
        }
    }

    private fun failed(case: String, burst: Int, err: String, stage: String) = ProbeResult(
        case = case, api = "audiotrack", reqSharing = "n/a", sharing = "n/a", perf = "-", mmap = null,
        burst = burst, capacity = 0, bufDefault = 0, bufStart = 0, bufFinal = 0, rate = RATE, channels = CHANNELS,
        format = "i16", xruns = 0, framesWritten = 0, tsFail = 0, error = err, stage = stage, startNs = 0,
        samples = emptyList(),
    )

    private fun perfName(m: Int) = when (m) {
        AudioTrack.PERFORMANCE_MODE_NONE -> "none"
        AudioTrack.PERFORMANCE_MODE_LOW_LATENCY -> "low_latency"
        AudioTrack.PERFORMANCE_MODE_POWER_SAVING -> "power_saving"
        else -> "unknown_$m"
    }

    companion object {
        // Mirrors client-android AudioPlayout constants.
        const val RATE = 48_000
        const val CHANNELS = 2
        const val BYTES_PER_FRAME = 4
        const val DEFAULT_BURST = 240
        const val MIN_BURST = 16
        const val MAX_BURST = 4800
        const val START_BURSTS = 2
        const val MAX_BURSTS = 6
        const val MAX_SAMPLES = 16384
    }
}
