package dev.matebridge.client.audio

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioRouting
import android.media.AudioTimestamp
import android.media.AudioTrack
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.Process
import android.os.SystemClock
import dev.matebridge.client.protocol.AudioConfig
import dev.matebridge.client.protocol.AudioFrame
import dev.matebridge.client.protocol.Message
import dev.matebridge.client.session.MbLog

/**
 * Mac audio on the tablet (decision 0011): AudioTrack in low-latency mode fed by one writer thread per host stream.
 *
 *  - The control reader thread only fills the stream's [AudioJitterBuffer] ([onAudio]); it never blocks on audio.
 *  - The writer thread (THREAD_PRIORITY_URGENT_AUDIO) renders one burst per WRITE_BLOCKING call through
 *    [PlayoutCore], so it runs at the device's audio clock.
 *  - The track is rebuilt on ERROR_DEAD_OBJECT and when the output device changes (at most 5 times per 10 s).
 *  - ACTION_AUDIO_BECOMING_NOISY mutes the stream until the next one starts. No audio focus is requested, so the
 *    tablet's own media keeps playing.
 *  - [stop] (session end, background, STOPPED, setting off) ends the writer: pause, flush, release; the ring is dropped.
 *
 * Every failure is logged and contained here: audio never takes the session down. Audio content is never logged.
 * [hostMinusClientUs] is the ClockSync offset (null while unknown).
 */
class AudioPlayout(context: Context, private val hostMinusClientUs: () -> Long?) {
    private val appContext = context.applicationContext
    private val mainHandler = Handler(Looper.getMainLooper())
    private val gate = AudioStreamGate()
    private val lock = Any()
    @Volatile private var stream: Stream? = null
    private var shut = false
    private var errorLogged = false

    /** Video capture-to-display estimate (AvSync.videoLatencyUs), set once per second by the UI; null = unknown. */
    @Volatile var videoLatencyUs: Long? = null

    private val burst: Int
    private val nativeRate: Int

    private val noisyReceiver = object : BroadcastReceiver() {
        override fun onReceive(c: Context?, i: Intent?) {
            if (i?.action != AudioManager.ACTION_AUDIO_BECOMING_NOISY) return
            val s = stream ?: return
            s.core.muted = true
            MbLog.i("audio_noisy", "stream_id=${s.id} muted=1", COMPONENT)
        }
    }
    private var receiverRegistered = false

    init {
        val am = appContext.getSystemService(AudioManager::class.java)
        nativeRate = am?.getProperty(AudioManager.PROPERTY_OUTPUT_SAMPLE_RATE)?.toIntOrNull() ?: 0
        val nativeBurst = am?.getProperty(AudioManager.PROPERTY_OUTPUT_FRAMES_PER_BUFFER)?.toIntOrNull() ?: 0
        burst = if (nativeBurst in MIN_BURST..MAX_BURST) nativeBurst else DEFAULT_BURST
        val pm = appContext.packageManager
        MbLog.i(
            "audio_device",
            "native_rate=$nativeRate native_burst=$nativeBurst burst=$burst " +
                "low_latency_feature=${b(pm.hasSystemFeature(PackageManager.FEATURE_AUDIO_LOW_LATENCY))} " +
                "pro_feature=${b(pm.hasSystemFeature(PackageManager.FEATURE_AUDIO_PRO))} rate=$RATE",
            COMPONENT,
        )
        try {
            val filter = IntentFilter(AudioManager.ACTION_AUDIO_BECOMING_NOISY)
            if (Build.VERSION.SDK_INT >= 33) {
                appContext.registerReceiver(noisyReceiver, filter, Context.RECEIVER_NOT_EXPORTED) // system broadcasts still arrive
            } else {
                appContext.registerReceiver(noisyReceiver, filter)
            }
            receiverRegistered = true
        } catch (e: RuntimeException) {
            MbLog.w("audio_noisy_receiver_failed", "err=${e.javaClass.simpleName}", COMPONENT)
        }
    }

    /** AUDIO_CONFIG / AUDIO_FRAME from the control reader thread. Never throws. */
    fun onAudio(msg: Message) {
        try {
            when (msg) {
                is AudioConfig -> onConfig(msg)
                is AudioFrame -> onFrame(msg)
                else -> Unit
            }
        } catch (e: RuntimeException) {
            if (!errorLogged) {
                errorLogged = true
                MbLog.e("audio_error", "where=receive err=${e.javaClass.simpleName}", COMPONENT)
            }
        }
    }

    private fun onConfig(c: AudioConfig): Unit = synchronized(lock) {
        if (shut) return
        MbLog.i(
            "audio_config",
            "stream_id=${c.streamId} state=${c.state} format=${c.format} rate=${c.sampleRate} ch=${c.channels} fpp=${c.framesPerPacket}",
            COMPONENT,
        )
        when (val a = gate.onConfig(c)) {
            is AudioStreamGate.Action.Start -> {
                stream?.stop("restart")
                stream = Stream(a.streamId).also { it.start() }
            }
            AudioStreamGate.Action.Stop -> { stream?.stop("stopped"); stream = null }
            AudioStreamGate.Action.Unsupported -> {
                stream?.stop("unsupported")
                stream = null
                MbLog.w("audio_unsupported", "stream_id=${c.streamId} format=${c.format} rate=${c.sampleRate} ch=${c.channels}", COMPONENT)
            }
            AudioStreamGate.Action.None -> Unit
        }
    }

    private fun onFrame(f: AudioFrame) {
        val s = stream ?: return
        if (!gate.accepts(f) || f.streamId != s.id) { s.rejected++; return }
        s.core.buffer.write(f.sampleIndex, f.captureTimeUs, f.data.value, f.frameCount)
    }

    /** Stops playback now (any thread, non-blocking): the writer pauses, flushes and releases its track. */
    fun stop(reason: String) = synchronized(lock) {
        gate.reset()
        stream?.stop(reason)
        stream = null
    }

    /** Terminal (onDestroy). */
    fun shutdown() {
        synchronized(lock) { shut = true }
        stop("shutdown")
        if (receiverRegistered) {
            receiverRegistered = false
            try { appContext.unregisterReceiver(noisyReceiver) } catch (_: RuntimeException) {}
        }
    }

    private class Track(val track: AudioTrack, val usage: Int, var bufFrames: Int) {
        @Volatile var deviceId: Int? = null
        var routing: AudioRouting.OnRoutingChangedListener? = null

        val perfName: String get() = when (track.performanceMode) {
            AudioTrack.PERFORMANCE_MODE_LOW_LATENCY -> "low_latency"
            AudioTrack.PERFORMANCE_MODE_POWER_SAVING -> "power_saving"
            else -> "none"
        }

        fun close() {
            routing?.let { try { track.removeOnRoutingChangedListener(it) } catch (_: RuntimeException) {} }
            try { track.pause() } catch (_: RuntimeException) {}
            try { track.flush() } catch (_: RuntimeException) {}
            track.release()
        }
    }

    private inner class Stream(val id: Int) {
        val core = PlayoutCore()
        @Volatile var rejected = 0L
        @Volatile private var running = true
        @Volatile private var rebuildReason: String? = null
        private val rebuildTimes = ArrayDeque<Long>()

        fun start() {
            MbLog.i("audio_start", "stream_id=$id", COMPONENT)
            Thread({ run() }, "mb-audio-$id").also { it.isDaemon = true; it.start() }
        }

        fun stop(reason: String) {
            if (!running) return
            running = false
            MbLog.i("audio_stop", "stream_id=$id reason=$reason", COMPONENT)
        }

        private fun run() {
            try { Process.setThreadPriority(Process.THREAD_PRIORITY_URGENT_AUDIO) } catch (_: RuntimeException) {}
            var t: Track? = null
            try {
                t = openTrack("start") ?: return
                loop(t) { t = it }
            } catch (e: RuntimeException) {
                MbLog.e("audio_error", "where=writer stream_id=$id err=${e.javaClass.simpleName}", COMPONENT)
            } finally {
                try { t?.close() } catch (_: RuntimeException) {}
                core.buffer.reset()
                running = false
            }
        }

        private fun buildTrack(usage: Int): AudioTrack {
            val attrs = AudioAttributes.Builder().setUsage(usage).setContentType(AudioAttributes.CONTENT_TYPE_MOVIE).build()
            val fmt = AudioFormat.Builder()
                .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                .setSampleRate(RATE)
                .setChannelMask(AudioFormat.CHANNEL_OUT_STEREO)
                .build()
            val minBytes = AudioTrack.getMinBufferSize(RATE, AudioFormat.CHANNEL_OUT_STEREO, AudioFormat.ENCODING_PCM_16BIT)
            val bytes = maxOf(minBytes, burst * MAX_BURSTS * BYTES_PER_FRAME)
            return AudioTrack.Builder()
                .setAudioAttributes(attrs)
                .setAudioFormat(fmt)
                .setBufferSizeInBytes(bytes)
                .setTransferMode(AudioTrack.MODE_STREAM)
                .setPerformanceMode(AudioTrack.PERFORMANCE_MODE_LOW_LATENCY)
                .build()
        }

        /** USAGE_MEDIA first; USAGE_GAME only if it gets the FAST path and MEDIA did not. */
        private fun openTrack(reason: String): Track? {
            var usage = AudioAttributes.USAGE_MEDIA
            var at = try {
                buildTrack(usage)
            } catch (e: RuntimeException) {
                MbLog.e("audio_track_failed", "stream_id=$id usage=media err=${e.javaClass.simpleName}", COMPONENT)
                return null
            }
            if (at.performanceMode != AudioTrack.PERFORMANCE_MODE_LOW_LATENCY) {
                val game = try { buildTrack(AudioAttributes.USAGE_GAME) } catch (_: RuntimeException) { null }
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
                MbLog.e("audio_track_failed", "stream_id=$id reason=not_initialized", COMPONENT)
                return null
            }
            val got = at.setBufferSizeInFrames(START_BURSTS * burst)
            val t = Track(at, usage, if (got > 0) got else at.bufferSizeInFrames)
            try {
                val l = AudioRouting.OnRoutingChangedListener { router ->
                    val dev = router.routedDevice?.id ?: return@OnRoutingChangedListener
                    val prev = t.deviceId
                    t.deviceId = dev
                    if (prev != null && prev != dev) rebuildReason = "routing"
                }
                t.routing = l
                at.addOnRoutingChangedListener(l, mainHandler)
                at.play()
                if (t.deviceId == null) t.deviceId = at.routedDevice?.id
            } catch (e: RuntimeException) {
                try { t.close() } catch (_: RuntimeException) {}
                throw e
            }
            MbLog.i(
                "audio_track",
                "stream_id=$id reason=$reason perf_mode=${t.perfName} usage=${if (usage == AudioAttributes.USAGE_GAME) "game" else "media"} " +
                    "burst=$burst buf_frames=${t.bufFrames} capacity_frames=${at.bufferCapacityInFrames} native_rate=$nativeRate rate=$RATE",
                COMPONENT,
            )
            return t
        }

        private fun mayRebuild(): Boolean {
            val now = SystemClock.elapsedRealtime()
            while (rebuildTimes.isNotEmpty() && now - rebuildTimes.first() > REBUILD_WINDOW_MS) rebuildTimes.removeFirst()
            if (rebuildTimes.size >= MAX_REBUILDS) return false
            rebuildTimes.addLast(now)
            return true
        }

        private fun loop(first: Track, setCurrent: (Track?) -> Unit) {
            var t = first
            val out = ShortArray(burst * 2)
            val ts = AudioTimestamp()
            var tsValid = false
            var tsFramePos = 0L
            var tsNano = 0L
            var written = 0L
            var nextTsAt = 0L
            var nextLogAt = RATE.toLong()
            var lastTrackUnderruns = t.track.underrunCount
            var audioSum = 0L
            var audioN = 0
            var avSum = 0L
            var avN = 0
            var lastAvMs: Long? = null
            var lastAudioMs: Long? = null
            while (running) {
                val why = rebuildReason
                if (why != null) {
                    rebuildReason = null
                    if (!mayRebuild()) {
                        MbLog.e("audio_rebuild_limit", "stream_id=$id reason=$why", COMPONENT)
                        return
                    }
                    t.close()
                    setCurrent(null) // closed: the finally block must not touch it again
                    t = openTrack(why) ?: return
                    setCurrent(t)
                    written = 0; nextTsAt = 0; nextLogAt = RATE.toLong(); tsValid = false
                    lastTrackUnderruns = t.track.underrunCount
                }
                // A/V sample (every ~250 ms) before rendering: when will frame `written` be heard, and when was the
                // frame at the read head captured?
                if (written >= nextTsAt) {
                    nextTsAt = written + TS_INTERVAL_FRAMES
                    if (t.track.getTimestamp(ts)) { tsValid = true; tsFramePos = ts.framePosition; tsNano = ts.nanoTime }
                    val off = hostMinusClientUs()
                    val cap = core.buffer.readHeadCaptureUs()
                    if (tsValid && off != null && cap != null && core.state == PlayoutCore.State.PLAYING) {
                        val la = AvSync.audioLatencyUs(AvSync.presentTimeUs(written, tsFramePos, tsNano, RATE), cap, off)
                        audioSum += la; audioN++
                        videoLatencyUs?.let { avSum += la - it; avN++ }
                    }
                }
                core.render(out, burst)
                val w = t.track.write(out, 0, out.size, AudioTrack.WRITE_BLOCKING)
                if (w == AudioTrack.ERROR_DEAD_OBJECT) { rebuildReason = "dead_object"; continue }
                if (w < 0) {
                    MbLog.e("audio_write_failed", "stream_id=$id code=$w", COMPONENT)
                    return
                }
                written += w / 2
                if (written >= nextLogAt) {
                    nextLogAt += RATE
                    val tu = t.track.underrunCount
                    if (tu > lastTrackUnderruns && t.bufFrames < MAX_BURSTS * burst) {
                        val r = t.track.setBufferSizeInFrames(t.bufFrames + burst)
                        if (r > 0) t.bufFrames = r
                        MbLog.i("audio_buffer_grow", "stream_id=$id buf_frames=${t.bufFrames} track_underruns=$tu", COMPONENT)
                    }
                    lastTrackUnderruns = tu
                    if (audioN > 0) lastAudioMs = audioSum / audioN / 1000
                    if (avN > 0) {
                        val av = avSum / avN
                        lastAvMs = av / 1000
                        core.drift.onAvOffset(av)
                    }
                    audioSum = 0; audioN = 0; avSum = 0; avN = 0
                    logStats(t, tu, lastAudioMs, lastAvMs)
                }
            }
        }

        private fun logStats(t: Track, trackUnderruns: Int, audioMs: Long?, avMs: Long?) {
            val d = core.drift
            val buf = core.buffer
            MbLog.i(
                "stats",
                "stream_id=$id state=${core.state.name.lowercase()} perf_mode=${t.perfName} burst=$burst buf_frames=${t.bufFrames} " +
                    "level_ms_floor=${if (d.lastFloorFrames >= 0) d.lastFloorFrames / MS else -1} level_ms=${core.lastRemainingFrames / MS} " +
                    "target_ms=${d.targetFrames / MS} ratio_ppm=${d.ratioPpm.toLong()} underruns=${d.underruns} track_underruns=$trackUnderruns " +
                    "drops=${buf.dropEvents} drop_ms=${buf.dropFrames / MS} gaps=${buf.gapEvents} gap_ms=${buf.gapFrames / MS} late_frames=${buf.lateFrames} " +
                    "resyncs=${d.resyncs} rebuffers=${d.rebuffers} rejected=$rejected muted=${b(core.muted)} " +
                    "av_offset_ms=${avMs ?: "-"} audio_ms=${audioMs ?: "-"} video_ms=${videoLatencyUs?.let { it / 1000 } ?: "-"}",
                COMPONENT,
            )
        }
    }

    private companion object {
        const val COMPONENT = "audio"
        const val RATE = AudioStreamGate.SAMPLE_RATE
        const val MS = RATE / 1000
        const val BYTES_PER_FRAME = 4
        const val DEFAULT_BURST = 240
        const val MIN_BURST = 16
        const val MAX_BURST = 4800
        const val START_BURSTS = 2
        const val MAX_BURSTS = 6
        const val TS_INTERVAL_FRAMES = RATE / 4L
        const val MAX_REBUILDS = 5
        const val REBUILD_WINDOW_MS = 10_000L

        fun b(v: Boolean) = if (v) 1 else 0
    }
}
