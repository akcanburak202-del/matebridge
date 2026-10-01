package dev.matebridge.client.audio

import android.app.Activity
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.media.AudioManager
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
 * Mac audio on the tablet (decisions 0011, 0012): one writer thread per host stream feeds an [AudioSink] (AAudio
 * LOW_LATENCY, or AudioTrack in low-latency mode; chosen by [SinkPolicy]).
 *
 *  - Connection generations ([beginSession]/[endSession], see [AudioStreamGate]): only the current control
 *    connection's messages are taken, so a stale reader can neither start an orphan output after teardown nor replace
 *    the new connection's stream.
 *  - The control reader thread only fills the stream's [AudioJitterBuffer] ([onAudio]); it never blocks on audio.
 *  - The writer thread (THREAD_PRIORITY_URGENT_AUDIO) renders one output burst per blocking write through
 *    [PlayoutCore], so it runs at the device's audio clock. Play position and latency come from the output's
 *    timestamp the same way for both outputs ([OutputClock]). A new stream's writer waits for the previous writer's
 *    cleanup before it opens its output.
 *  - Output choice (decision 0012 point 2): AAudio EXCLUSIVE, else AAudio SHARED on probation
 *    ([SharedLatencyProbe]), else AudioTrack. AAudio is used only with MMAP (its write timeout must hold).
 *    The panel's "Ses çıkışı" setting (`storedOutPref`, T-101) picks AUTO or AudioTrack; `--es audio_out
 *    aaudio|track|auto` overrides it for this launch ([AudioOutPref.resolve]). [setOutPref] applies a panel change: at
 *    once if a stream is playing (the output is reopened), otherwise with the next stream.
 *  - AAudio play position (T-101): from AAudio's own counters in AAudio's frame domain ([OutputClock.onDeviceCounters]);
 *    AudioTrack keeps its timestamp. The raw counters are logged twice per AAudio output (`audio_clock_raw`).
 *  - Stopping sets the stream's flag and interrupts the output (AudioTrack: pause+flush unblocks the write; AAudio:
 *    the write returns within one burst); the writer then closes the output (exactly once).
 *  - The output is rebuilt when it dies (AudioTrack ERROR_DEAD_OBJECT, AAudio DISCONNECTED or a stalled write) and
 *    when the output device changes (at most 5 times per 10 s). Repeated AAudio failures switch to AudioTrack.
 *  - ACTION_AUDIO_BECOMING_NOISY mutes the stream and calls [onNoisy] (the UI turns audio off, so the host stops and
 *    the Mac's own output returns). No audio focus is requested, so the tablet's own media keeps playing.
 *
 * Every failure is logged and contained here: audio never takes the session down. Audio content is never logged.
 * [hostMinusClientUs] is the ClockSync offset (null while unknown).
 *
 * When [context] is an Activity its launch intent may set `--es audio_out aaudio|track` and `--ei audio_buf_bursts N`
 * ([AudioBufferConfig]); they are read here so the experiment switches stay in this package.
 */
class AudioPlayout(
    context: Context,
    private val hostMinusClientUs: () -> Long?,
    storedOutPref: AudioOutPref = AudioOutPref.AUTO,
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

    /** AudioTrack burst (the mixer's period). AAudio streams report their own. */
    private val trackBurst: Int
    private val nativeRate: Int
    private val bufBurstsRaw: Int? =
        (context as? Activity)?.intent?.takeIf { it.hasExtra(AudioBufferConfig.EXTRA) }?.getIntExtra(AudioBufferConfig.EXTRA, 0)
    private val policy: SinkPolicy

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
        trackBurst = if (nativeBurst in MIN_BURST..MAX_BURST) nativeBurst else DEFAULT_BURST

        val rawOut = (context as? Activity)?.intent?.getStringExtra(AudioOutPref.EXTRA)
        val resolved = AudioOutPref.resolve(rawOut, storedOutPref)
        if (resolved.unknownExtra) {
            MbLog.w("audio_out_pref_unknown", "using=${resolved.pref.id}", COMPONENT) // the raw value is not logged
        }
        val pref = resolved.pref
        // TRACK does not load the native library (as before); a later switch to AUTO lets AAudioSink.open check it.
        val lib = pref != AudioOutPref.TRACK && AAudioNative.available
        policy = SinkPolicy(pref, pref == AudioOutPref.TRACK || lib)
        MbLog.i("audio_out_pref", "value=${pref.id} source=${resolved.source} stream=0", COMPONENT)

        val pm = appContext.packageManager
        MbLog.i(
            "audio_device",
            "native_rate=$nativeRate native_burst=$nativeBurst burst=$trackBurst " +
                "low_latency_feature=${b(pm.hasSystemFeature(PackageManager.FEATURE_AUDIO_LOW_LATENCY))} " +
                "pro_feature=${b(pm.hasSystemFeature(PackageManager.FEATURE_AUDIO_PRO))} rate=$RATE " +
                "buf_bursts=${bufBurstsRaw?.let { AudioBufferConfig.startBursts(it) } ?: "default"} " +
                "audio_out=${pref.name.lowercase()} aaudio_lib=${b(lib)}",
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

    /** The output preference in effect (the stored setting, a launch override, or the last panel choice). */
    val outPref: AudioOutPref get() = policy.pref

    /**
     * T-101: the panel's "Ses çıkışı" changed to [p] (main thread). The policy takes it at once; a playing stream reopens
     * its output (not counted toward the rebuild limit), otherwise the next stream uses it.
     */
    fun setOutPref(p: AudioOutPref) {
        if (!policy.setPref(p)) return
        val s = synchronized(lock) { stream }
        MbLog.i("audio_out_pref", "value=${p.id} source=panel stream=${b(s != null)}", COMPONENT)
        s?.requestRebuild(REASON_PREF)
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

    private inner class Stream(val id: Int, private var previous: Stream?) {
        val core = PlayoutCore()
        @Volatile var rejected = 0L
        @Volatile private var running = true
        @Volatile private var rebuildReason: String? = null
        /** The output the writer is using, published for [stop]. */
        @Volatile private var current: AudioSink? = null
        /** Latency probation of a shared AAudio output (writer thread only). */
        private var probe: SharedLatencyProbe? = null
        private val rebuildTimes = ArrayDeque<Long>()
        val finished = CountDownLatch(1)

        fun start() {
            MbLog.i("audio_start", "stream_id=$id", COMPONENT)
            Thread({ run() }, "mb-audio-$id").also { it.isDaemon = true; it.start() }
        }

        /** Any thread: the writer reopens its output before its next burst (T-101 output preference). */
        fun requestRebuild(reason: String) {
            if (running) rebuildReason = reason
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
                // Serialize with the previous stream: its output is closed before this one is opened.
                previous?.let { p ->
                    if (!p.finished.await(PREVIOUS_JOIN_MS, TimeUnit.MILLISECONDS)) {
                        MbLog.w("audio_previous_slow", "stream_id=$id previous=${p.id}", COMPONENT)
                    }
                }
                previous = null
                if (!running) return
                policy.reset() // a new stream tries the whole output chain again
                val t = openSink("start") ?: return
                publish(t)
                loop(t)
            } catch (e: RuntimeException) {
                MbLog.e("audio_error", "where=writer stream_id=$id err=${e.javaClass.simpleName}", COMPONENT)
            } catch (e: LinkageError) {
                // The AAudio library failed mid-stream (T-100 review L1): never let it kill the process; AudioTrack from now on.
                policy.disableAaudio()
                MbLog.e("audio_error", "where=writer stream_id=$id err=${e.javaClass.simpleName} aaudio_disabled=1", COMPONENT)
            } catch (_: InterruptedException) {
                // not interrupted by us; just end
            } finally {
                try { current?.close() } catch (_: RuntimeException) {} catch (_: LinkageError) {}
                current = null
                core.buffer.reset()
                running = false
                finished.countDown()
            }
        }

        /** Publishes [t] for [stop]; a stop that raced the publish is honoured at once. */
        private fun publish(t: AudioSink?) {
            current = t
            if (!running) t?.interrupt()
        }

        /** Opens the first output the policy allows, falling down the chain; null if not even AudioTrack opens. */
        private fun openSink(reason: String): AudioSink? {
            probe = null
            while (true) {
                if (!running) return null
                val choice = policy.next()
                val sink = try {
                    when (choice) {
                        OutChoice.AAUDIO_EXCLUSIVE, OutChoice.AAUDIO_SHARED -> AAudioSink.open(
                            if (choice == OutChoice.AAUDIO_EXCLUSIVE) AAudioNative.SHARING_EXCLUSIVE else AAudioNative.SHARING_SHARED,
                            AudioBufferConfig.startBursts(bufBurstsRaw, AudioBufferConfig.AAUDIO_DEFAULT_BURSTS),
                            MAX_BURSTS,
                        )
                        OutChoice.TRACK -> TrackSink.open(
                            trackBurst,
                            AudioBufferConfig.startBursts(bufBurstsRaw),
                            MAX_BURSTS,
                            mainHandler,
                        ) { rebuildReason = "routing" }
                    }
                } catch (e: SinkOpenException) {
                    MbLog.w("audio_out_failed", "stream_id=$id requested=${choice.logName} ${e.message}", COMPONENT)
                    if (choice == OutChoice.TRACK) return null
                    if (e.aaudioUnusable) policy.disableAaudio() else policy.onOpenFailed(choice)
                    continue
                }
                val verdict = policy.onOpened(choice, sink.exclusive, sink.mmap)
                if (verdict == SinkPolicy.Verdict.REJECT) {
                    // Not MMAP (review M1): its write could block without bound. Close it and go down the chain.
                    MbLog.w("audio_out_rejected", "${sink.logFields()} stream_id=$id requested=${choice.logName} reason=not_mmap", COMPONENT)
                    sink.close()
                    continue
                }
                if (verdict == SinkPolicy.Verdict.PROBATION) probe = SharedLatencyProbe(RATE)
                MbLog.i(
                    "audio_out",
                    "${sink.logFields()} stream_id=$id reason=$reason requested=${choice.logName} " +
                        "probation=${b(verdict == SinkPolicy.Verdict.PROBATION)} pref=${policy.pref.name.lowercase()} " +
                        "native_rate=$nativeRate rate=$RATE",
                    COMPONENT,
                )
                return sink
            }
        }

        private fun mayRebuild(): Boolean {
            val now = SystemClock.elapsedRealtime()
            while (rebuildTimes.isNotEmpty() && now - rebuildTimes.first() > REBUILD_WINDOW_MS) rebuildTimes.removeFirst()
            if (rebuildTimes.size >= MAX_REBUILDS) return false
            rebuildTimes.addLast(now)
            return true
        }

        /** An AAudio output failed while running: counts toward switching to AudioTrack. */
        private fun aaudioFailed(t: AudioSink, why: String) {
            if (t !is AAudioSink) return
            if (policy.onAaudioFailure(SystemClock.elapsedRealtime())) {
                MbLog.w("audio_out_fallback", "stream_id=$id to=track reason=$why failures=${SinkPolicy.MAX_FAILURES}", COMPONENT)
            }
        }

        /** Hold for the A/V target while priming (PlayoutCore.primingHoldUs), from the play position of [clock]. */
        private fun primingHold(clock: OutputClock): Long {
            val v = video.value() ?: return 0
            val off = hostMinusClientUs() ?: return 0
            val cap = core.buffer.readHeadCaptureUs() ?: return 0
            val present = clock.presentTimeUs()
                ?: return if (clock.written < RATE * 3L / 10) 1 else 0 // the output's first timestamp is on its way
            val la = AvSync.audioLatencyUs(present, cap, off)
            return v + DriftController.AV_TARGET_US - la
        }

        /** Feeds the shared-output probation; on a verdict logs it, and on a rejection asks for a rebuild. */
        private fun probation(t: AudioSink, clock: OutputClock, tsOk: Boolean) {
            val p = probe ?: return
            val r = p.add(clock.written - t.preFrames, if (tsOk) clock.latencyUs(System.nanoTime()) else null)
            if (r == SharedLatencyProbe.Result.PENDING) return
            probe = null
            MbLog.i(
                "audio_shared_probe",
                "stream_id=$id result=${r.name.lowercase()} latency_ms=${p.medianUs?.let { it / 1000 } ?: "-"} " +
                    "max_ms=${p.maxLatencyMs} samples=${p.samples} ts_fail=${p.failures}",
                COMPONENT,
            )
            if (r == SharedLatencyProbe.Result.REJECT) {
                policy.onProbationFailed()
                rebuildReason = REASON_SHARED_LATENCY
            }
        }

        private fun loop(first: AudioSink) {
            var t = first
            var out = ShortArray(t.burst * 2)
            val clock = OutputClock(RATE).also { it.reset(t.preFrames) }
            val tsBuf = LongArray(AAudioNative.C_COUNT) // also holds the AAudio counters (T-101)
            var nextTsAt = 0L
            var nextLogAt = clock.written + RATE
            var xrunBase: Int? = null // T-095 review L5: the first second's output underruns are not acted upon
            var audioSum = 0L
            var audioN = 0
            var avSum = 0L
            var avN = 0
            var lastAvMs: Long? = null
            var lastAudioMs: Long? = null
            rawLogged = 0
            while (running) {
                val why = rebuildReason
                if (why != null) {
                    rebuildReason = null
                    if (why != REASON_PREF && !mayRebuild()) {
                        MbLog.e("audio_rebuild_limit", "stream_id=$id reason=$why api=${t.api}", COMPONENT)
                        return
                    }
                    t.close()
                    publish(null)
                    // A dead or re-routed output may mean a new device: try the whole chain again.
                    if (why != REASON_SHARED_LATENCY) policy.reset()
                    t = openSink(why) ?: return
                    publish(t)
                    if (out.size != t.burst * 2) out = ShortArray(t.burst * 2)
                    clock.reset(t.preFrames)
                    nextTsAt = 0; nextLogAt = clock.written + RATE; xrunBase = null
                    rawLogged = 0
                }
                val priming = core.state == PlayoutCore.State.PRIMING
                val probing = probe != null
                // Timestamps: every burst while priming (A/V hold) or on probation, every ~250 ms otherwise (A/V sample).
                if (priming || probing || clock.written >= nextTsAt) {
                    val tsOk = readClock(t, clock, tsBuf)
                    if (probing) {
                        probation(t, clock, tsOk)
                        if (rebuildReason != null) continue
                    }
                }
                if (priming) {
                    core.primingHoldUs = primingHold(clock)
                } else if (clock.written >= nextTsAt) {
                    // When will frame `written` be heard, and when was the frame at the read head captured?
                    nextTsAt = clock.written + TS_INTERVAL_FRAMES
                    val off = hostMinusClientUs()
                    val cap = core.buffer.readHeadCaptureUs()
                    val present = clock.presentTimeUs()
                    if (present != null && off != null && cap != null && core.state == PlayoutCore.State.PLAYING) {
                        val la = AvSync.audioLatencyUs(present, cap, off)
                        audioSum += la; audioN++
                        video.value()?.let { avSum += la - it; avN++ }
                    }
                }
                core.render(out, t.burst)
                val w = t.write(out, t.burst)
                if (w == AudioSink.WRITE_DEAD) {
                    if (!running) return
                    aaudioFailed(t, t.deadReason)
                    rebuildReason = t.deadReason
                    continue
                }
                if (w < 0) {
                    if (!running) return
                    MbLog.e("audio_write_failed", "stream_id=$id api=${t.api} code=${t.lastError}", COMPONENT)
                    if (t !is AAudioSink) return
                    aaudioFailed(t, "write_failed")
                    rebuildReason = "write_failed"
                    continue
                }
                clock.onWrite(w)
                if (clock.written >= nextLogAt) {
                    nextLogAt += RATE
                    val xr = t.xruns()
                    val base = xrunBase
                    if (base != null && xr > base && t.grow()) {
                        MbLog.i("audio_buffer_grow", "stream_id=$id api=${t.api} buf_frames=${t.bufFrames} xruns=$xr", COMPONENT)
                    }
                    xrunBase = xr
                    if (audioN > 0) lastAudioMs = audioSum / audioN / 1000
                    if (avN > 0) {
                        val av = avSum / avN
                        lastAvMs = av / 1000
                        core.drift.onAvOffset(av)
                    }
                    audioSum = 0; audioN = 0; avSum = 0; avN = 0
                    logStats(t, xr, lastAudioMs, lastAvMs)
                }
            }
        }

        /** `audio_clock_raw` lines logged for the current output (T-101): the first read and one ~1 s in. */
        private var rawLogged = 0

        /**
         * Reads the output's play position into [clock]; true if it has one now. AAudio: its own counters in its own
         * frame domain (T-101); AudioTrack: its timestamp, as before.
         */
        private fun readClock(t: AudioSink, clock: OutputClock, buf: LongArray): Boolean {
            if (!t.counters(buf)) {
                val ok = t.timestamp(buf)
                if (ok) clock.onTimestamp(buf[0], buf[1])
                return ok
            }
            val written = buf[AAudioNative.C_WRITTEN]
            val read = buf[AAudioNative.C_READ]
            val tsNs = buf[AAudioNative.C_TS_NS]
            val tsPos = buf[AAudioNative.C_TS_POS]
            val now = buf[AAudioNative.C_NOW]
            val hasTs = tsNs != 0L
            val src = clock.onDeviceCounters(written, read, if (hasTs) tsPos else null, tsNs, now)
            if (rawLogged == 0 || (rawLogged == 1 && clock.written - t.preFrames >= RATE)) {
                rawLogged++
                MbLog.i(
                    "audio_clock_raw",
                    "stream_id=$id phase=${if (rawLogged == 1) "first" else "1s"} frames_written=$written frames_read=$read " +
                        "ts_pos=${if (hasTs) tsPos else "-"} ts_ns=${if (hasTs) tsNs else "-"} now_ns=$now " +
                        "ts_lag_us=${if (hasTs) clock.timestampLagUs(read, tsPos, tsNs, now) else "-"} " +
                        "our_written=${clock.written} pre=${t.preFrames} offset=${clock.domainOffset} buf=${t.bufFrames} " +
                        "source=${src.logName} latency_us=${clock.latencyUs(now)}",
                    COMPONENT,
                )
            }
            return true
        }

        private fun logStats(t: AudioSink, xruns: Int, audioMs: Long?, avMs: Long?) {
            val d = core.drift
            val buf = core.buffer
            MbLog.i(
                "stats",
                "stream_id=$id state=${if (core.idle) "idle" else core.state.name.lowercase()} api=${t.api} perf_mode=${t.perfName} " +
                    "burst=${t.burst} buf_frames=${t.bufFrames} " +
                    "level_ms_floor=${if (d.lastFloorFrames >= 0) d.lastFloorFrames / MS else -1} level_ms=${core.lastRemainingFrames / MS} " +
                    "target_ms=${d.targetFrames / MS} safety_ms=${d.safetyFrames / MS} ratio_ppm=${d.ratioPpm.toLong()} " +
                    "underruns=${d.underruns} xruns=$xruns " +
                    "drops=${buf.dropEvents} drop_ms=${buf.dropFrames / MS} gaps=${buf.gapEvents} gap_ms=${buf.gapFrames / MS} jumps=${buf.jumpEvents} idle_gaps=${core.idleGaps} late_frames=${buf.lateFrames} " +
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
        const val DEFAULT_BURST = 240
        const val MIN_BURST = 16
        const val MAX_BURST = 4800
        const val MAX_BURSTS = AudioBufferConfig.MAX_BURSTS
        const val TS_INTERVAL_FRAMES = RATE / 4L
        const val MAX_REBUILDS = 5
        const val REBUILD_WINDOW_MS = 10_000L
        const val PREVIOUS_JOIN_MS = 500L
        const val REASON_SHARED_LATENCY = "shared_latency"
        const val REASON_PREF = "pref"

        fun b(v: Boolean) = if (v) 1 else 0
    }
}
