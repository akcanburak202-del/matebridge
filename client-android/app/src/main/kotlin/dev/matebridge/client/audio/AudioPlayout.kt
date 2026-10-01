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
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/**
 * Mac audio on the tablet (decision 0011): AudioTrack in low-latency mode fed by one writer thread per host stream.
 *
 *  - Connection generations ([beginSession]/[endSession], see [AudioStreamGate]): only the current control
 *    connection's messages are taken, so a stale reader can neither start an orphan track after teardown nor replace
 *    the new connection's stream.
 *  - The control reader thread only fills the stream's [AudioJitterBuffer] ([onAudio]); it never blocks on audio.
 *  - The writer thread (THREAD_PRIORITY_URGENT_AUDIO) renders one burst per WRITE_BLOCKING call through
 *    [PlayoutCore], so it runs at the device's audio clock. A new stream's writer waits for the previous writer's
 *    cleanup before it opens its track.
 *  - Stopping pauses and flushes the track from the stopping thread, which interrupts a blocked write; the writer
 *    then releases the track (exactly once).
 *  - The track is rebuilt on ERROR_DEAD_OBJECT and when the output device changes (at most 5 times per 10 s).
 *  - ACTION_AUDIO_BECOMING_NOISY mutes the stream and calls [onNoisy] (the UI turns audio off, so the host stops and
 *    the Mac's own output returns). No audio focus is requested, so the tablet's own media keeps playing.
 *
 * Every failure is logged and contained here: audio never takes the session down. Audio content is never logged.
 * [hostMinusClientUs] is the ClockSync offset (null while unknown).
 */
class AudioPlayout(
    context: Context,
    private val hostMinusClientUs: () -> Long?,
    private val onNoisy: () -> Unit = {},
) {
    private val appContext = context.applicationContext
    private val mainHandler = Handler(Looper.getMainLooper())
    private val gate = AudioStreamGate()
    private val lock = Any()
    @Volatile private var stream: Stream? = null
    private var shut = false
    @Volatile private var errorLogged = false
    private val video = VideoLatencyFilter()

    private val burst: Int
    private val nativeRate: Int

    private val noisyReceiver = object : BroadcastReceiver() {
        override fun onReceive(c: Context?, i: Intent?) {
            if (i?.action != AudioManager.ACTION_AUDIO_BECOMING_NOISY) return
            val s = stream ?: return
            s.core.muted = true
            MbLog.i("audio_noisy", "stream_id=${s.id} muted=1", COMPONENT)
            onNoisy()
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

    /** A new control connection [gen] is being opened (engine thread): only its audio is taken from now on. */
    fun beginSession(gen: Int): Unit = synchronized(lock) {
        if (shut) return
        stopStream("new_connection")
        gate.arm(gen)
    }

    /** The connection ended or the app went to the background (any thread, non-blocking): stop, take nothing more. */
    fun endSession(reason: String): Unit = synchronized(lock) {
        gate.disarm()
        stopStream(reason)
    }

    /** Video capture-to-display estimate (AvSync.videoLatencyUs), once per second from the UI; null = no video. */
    fun onVideoLatency(us: Long?) = video.add(us)

    /** AUDIO_CONFIG / AUDIO_FRAME from the reader thread of control connection [gen]. Never throws. */
    fun onAudio(msg: Message, gen: Int) {
        try {
            when (msg) {
                is AudioConfig -> onConfig(msg, gen)
                is AudioFrame -> onFrame(msg, gen)
                else -> Unit
            }
        } catch (e: RuntimeException) {
            if (!errorLogged) {
                errorLogged = true
                MbLog.e("audio_error", "where=receive err=${e.javaClass.simpleName}", COMPONENT)
            }
        }
    }

    private fun onConfig(c: AudioConfig, gen: Int): Unit = synchronized(lock) {
        if (shut) return
        if (!gate.armed || gen != gate.armedGen) {
            MbLog.i("audio_config_stale", "stream_id=${c.streamId} state=${c.state} gen=$gen", COMPONENT)
            return
        }
        MbLog.i(
            "audio_config",
            "stream_id=${c.streamId} state=${c.state} format=${c.format} rate=${c.sampleRate} ch=${c.channels} fpp=${c.framesPerPacket}",
            COMPONENT,
        )
        when (val a = gate.onConfig(c, gen)) {
            is AudioStreamGate.Action.Start -> {
                val prev = stream
                prev?.stop("restart")
                stream = Stream(a.streamId, prev).also { it.start() }
            }
            AudioStreamGate.Action.Stop -> stopStream("stopped")
            AudioStreamGate.Action.Unsupported -> {
                stopStream("unsupported")
                MbLog.w("audio_unsupported", "stream_id=${c.streamId} format=${c.format} rate=${c.sampleRate} ch=${c.channels}", COMPONENT)
            }
            AudioStreamGate.Action.None -> Unit
        }
    }

    /** Caller holds [lock]. */
    private fun stopStream(reason: String) {
        stream?.stop(reason)
        stream = null
    }

    private fun onFrame(f: AudioFrame, gen: Int) {
        val s = stream ?: return
        if (!gate.accepts(f, gen) || f.streamId != s.id) { s.rejected++; return }
        s.core.buffer.write(f.sampleIndex, f.captureTimeUs, f.data.value, f.frameCount)
    }

    /** Terminal (onDestroy). */
    fun shutdown() {
        synchronized(lock) { shut = true }
        endSession("shutdown")
        if (receiverRegistered) {
            receiverRegistered = false
            try { appContext.unregisterReceiver(noisyReceiver) } catch (_: RuntimeException) {}
        }
    }

    /**
     * One AudioTrack. [interrupt] (any thread) and [close] (the writer) share a lock, so a stop can never touch a
     * released track, and the release happens exactly once.
     */
    private class Track(val track: AudioTrack, val usage: Int, var bufFrames: Int, val preFrames: Long) {
        @Volatile var deviceId: Int? = null
        var routing: AudioRouting.OnRoutingChangedListener? = null
        private val lock = Any()
        private var closed = false

        val perfName: String get() = when (track.performanceMode) {
            AudioTrack.PERFORMANCE_MODE_LOW_LATENCY -> "low_latency"
            AudioTrack.PERFORMANCE_MODE_POWER_SAVING -> "power_saving"
            else -> "none"
        }

        /** Unblocks a WRITE_BLOCKING write in progress (it returns a short count) and drops the queued audio. */
        fun interrupt(): Unit = synchronized(lock) {
            if (closed) return
            try { track.pause() } catch (_: RuntimeException) {}
            try { track.flush() } catch (_: RuntimeException) {}
        }

        fun close(): Unit = synchronized(lock) {
            if (closed) return
            closed = true
            routing?.let { try { track.removeOnRoutingChangedListener(it) } catch (_: RuntimeException) {} }
            try { track.pause() } catch (_: RuntimeException) {}
            try { track.flush() } catch (_: RuntimeException) {}
            track.release()
        }
    }

    private inner class Stream(val id: Int, private var previous: Stream?) {
        val core = PlayoutCore()
        @Volatile var rejected = 0L
        @Volatile private var running = true
        @Volatile private var rebuildReason: String? = null
        /** The track the writer is using, published for [stop]. */
        @Volatile private var current: Track? = null
        private val rebuildTimes = ArrayDeque<Long>()
        val finished = CountDownLatch(1)

        fun start() {
            MbLog.i("audio_start", "stream_id=$id", COMPONENT)
            Thread({ run() }, "mb-audio-$id").also { it.isDaemon = true; it.start() }
        }

        /** Any thread, non-blocking. */
        fun stop(reason: String) {
            if (!running) return
            running = false
            MbLog.i("audio_stop", "stream_id=$id reason=$reason", COMPONENT)
            current?.interrupt()
        }

        private fun run() {
            try {
                try { Process.setThreadPriority(Process.THREAD_PRIORITY_URGENT_AUDIO) } catch (_: RuntimeException) {}
                // Serialize with the previous stream: its track is released before this one is created.
                previous?.let { p ->
                    if (!p.finished.await(PREVIOUS_JOIN_MS, TimeUnit.MILLISECONDS)) {
                        MbLog.w("audio_previous_slow", "stream_id=$id previous=${p.id}", COMPONENT)
                    }
                }
                previous = null
                if (!running) return
                val t = openTrack("start") ?: return
                publish(t)
                loop(t)
            } catch (e: RuntimeException) {
                MbLog.e("audio_error", "where=writer stream_id=$id err=${e.javaClass.simpleName}", COMPONENT)
            } catch (_: InterruptedException) {
                // not interrupted by us; just end
            } finally {
                try { current?.close() } catch (_: RuntimeException) {}
                current = null
                core.buffer.reset()
                running = false
                finished.countDown()
            }
        }

        /** Publishes [t] for [stop]; a stop that raced the publish is honoured at once. */
        private fun publish(t: Track?) {
            current = t
            if (!running) t?.interrupt()
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
            val t: Track
            try {
                val got = at.setBufferSizeInFrames(START_BURSTS * burst)
                // One burst of silence before play() (review L5): the mixer's first pull does not count an underrun.
                val pre = at.write(ShortArray(burst * 2), 0, burst * 2, AudioTrack.WRITE_NON_BLOCKING).coerceAtLeast(0) / 2
                t = Track(at, usage, if (got > 0) got else at.bufferSizeInFrames, pre.toLong())
            } catch (e: RuntimeException) {
                at.release()
                throw e
            }
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
                t.close()
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

        /** Hold for the A/V target while priming (PlayoutCore.primingHoldUs), from the timestamp of frame [written]. */
        private fun primingHold(tsValid: Boolean, written: Long, tsFramePos: Long, tsNano: Long): Long {
            val v = video.value() ?: return 0
            val off = hostMinusClientUs() ?: return 0
            val cap = core.buffer.readHeadCaptureUs() ?: return 0
            if (!tsValid) return if (written < RATE * 3L / 10) 1 else 0 // the track's first timestamp is on its way
            val la = AvSync.audioLatencyUs(AvSync.presentTimeUs(written, tsFramePos, tsNano, RATE), cap, off)
            return v + DriftController.AV_TARGET_US - la
        }

        private fun loop(first: Track) {
            var t = first
            val out = ShortArray(burst * 2)
            val ts = AudioTimestamp()
            var tsValid = false
            var tsFramePos = 0L
            var tsNano = 0L
            var written = t.preFrames
            var nextTsAt = 0L
            var nextLogAt = written + RATE
            var underrunBase: Int? = null // review L5: the first second's track underruns are not acted upon
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
                    publish(null)
                    t = openTrack(why) ?: return
                    publish(t)
                    written = t.preFrames; nextTsAt = 0; nextLogAt = written + RATE; tsValid = false; underrunBase = null
                }
                val priming = core.state == PlayoutCore.State.PRIMING
                // Timestamps: every burst while priming (A/V hold), every ~250 ms otherwise (A/V sample).
                if (priming || written >= nextTsAt) {
                    if (t.track.getTimestamp(ts)) { tsValid = true; tsFramePos = ts.framePosition; tsNano = ts.nanoTime }
                }
                if (priming) {
                    core.primingHoldUs = primingHold(tsValid, written, tsFramePos, tsNano)
                } else if (written >= nextTsAt) {
                    // When will frame `written` be heard, and when was the frame at the read head captured?
                    nextTsAt = written + TS_INTERVAL_FRAMES
                    val off = hostMinusClientUs()
                    val cap = core.buffer.readHeadCaptureUs()
                    if (tsValid && off != null && cap != null && core.state == PlayoutCore.State.PLAYING) {
                        val la = AvSync.audioLatencyUs(AvSync.presentTimeUs(written, tsFramePos, tsNano, RATE), cap, off)
                        audioSum += la; audioN++
                        video.value()?.let { avSum += la - it; avN++ }
                    }
                }
                core.render(out, burst)
                val w = t.track.write(out, 0, out.size, AudioTrack.WRITE_BLOCKING)
                if (w == AudioTrack.ERROR_DEAD_OBJECT) { rebuildReason = "dead_object"; continue }
                if (w < 0) {
                    if (running) MbLog.e("audio_write_failed", "stream_id=$id code=$w", COMPONENT)
                    return
                }
                written += w / 2
                if (written >= nextLogAt) {
                    nextLogAt += RATE
                    val tu = t.track.underrunCount
                    val base = underrunBase
                    if (base != null && tu > base && t.bufFrames < MAX_BURSTS * burst) {
                        val r = t.track.setBufferSizeInFrames(t.bufFrames + burst)
                        if (r > 0) t.bufFrames = r
                        MbLog.i("audio_buffer_grow", "stream_id=$id buf_frames=${t.bufFrames} track_underruns=$tu", COMPONENT)
                    }
                    underrunBase = tu
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
                    "target_ms=${d.targetFrames / MS} safety_ms=${d.safetyFrames / MS} ratio_ppm=${d.ratioPpm.toLong()} " +
                    "underruns=${d.underruns} track_underruns=$trackUnderruns " +
                    "drops=${buf.dropEvents} drop_ms=${buf.dropFrames / MS} gaps=${buf.gapEvents} gap_ms=${buf.gapFrames / MS} late_frames=${buf.lateFrames} " +
                    "resyncs=${d.resyncs} rebuffers=${d.rebuffers} rejected=$rejected muted=${b(core.muted)} " +
                    "av_offset_ms=${avMs ?: "-"} audio_ms=${audioMs ?: "-"} video_ms=${video.value()?.let { it / 1000 } ?: "-"}",
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
        const val PREVIOUS_JOIN_MS = 500L

        fun b(v: Boolean) = if (v) 1 else 0
    }
}
