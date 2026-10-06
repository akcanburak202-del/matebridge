package dev.matebridge.client.audio

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
import dev.matebridge.client.session.Transport
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.locks.LockSupport

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
 *  - Jitter-buffer safety (T-108, [SafetyMemory]): each output API starts at max(its default, the value remembered
 *    from earlier sessions, at most 30 ms since T-118); AAudio's default is 20 ms. A rebuild on the same API keeps the
 *    learned value. Each API's start is logged once (`safety_start stored= used=`).
 *    T-123: remembered per transport too ([beginSession] carries it; Wi-Fi starts at 40 ms). A stream opened on another
 *    transport than the previous one logs `safety_transport live=0`; [setTransport] under a playing stream switches its
 *    safety without reopening the output (`live=1`: a rise at once, a fall through the normal decay).
 *  - AAudio output buffer (T-110, T-114): starts at 4 bursts (20 ms). The headroom (frames written minus the device's
 *    read position, estimated from the output's timestamp, else its read counter: [HeadroomEstimator]) is sampled
 *    before every write ([HeadroomMeter]);
 *    a window with headroom below one burst, an estimated underflow or (where reported) an xrun grows the buffer by one
 *    burst ([OutBufGrowth]). A grown size is remembered per AAudio path ([OutBufMemory]) and the next output starts
 *    there; `--ei audio_buf_bursts` overrides the start.
 *  - Idle pause (T-287, [IdlePause]): an AAudio output that has had no packet for 60 s (the host sends nothing while the
 *    Mac is silent, T-279) is paused, and the writer parks until a packet arrives, a stop or a rebuild; then the
 *    output is started again and [PlayoutCore] plays the new sound after its usual quick restart (the long gap is
 *    classified idle by its capture-time jump). Logs: `idle_pause`, `resume` (`start_ms` = until the stream reports STARTED), `first_sound` (first packet
 *    to the first write that succeeded once playback started, also logged without pausing). A pause or resume that
 *    fails turns pausing off for the stream (a failed resume rebuilds the output). AudioTrack is never paused.
 *    `--es audio_idle_pause off|pause|stop` ([launchIdlePauseRaw], developer gate) picks no pausing, requestPause (the default) or
 *    requestStop.
 *  - ACTION_AUDIO_BECOMING_NOISY mutes the stream and calls [onNoisy] (the UI turns audio off, so the host stops and
 *    the Mac's own output returns). No audio focus is requested, so the tablet's own media keeps playing.
 *
 * Every failure is logged and contained here: audio never takes the session down. Audio content is never logged.
 * [hostMinusClientUs] is the ClockSync offset (null while unknown).
 *
 * [launchOutRaw] (`--es audio_out aaudio|track`) and [launchBufBursts] (`--ei audio_buf_bursts N`, [AudioBufferConfig])
 * are the launch experiment switches. The caller passes them only behind the developer gate (T-185, decision 0026);
 * null = not given. [launchIdlePauseRaw] is the same kind of switch for the idle pause ([IdlePause.resolve]).
 */
class AudioPlayout(
    context: Context,
    private val hostMinusClientUs: () -> Long?,
    storedOutPref: AudioOutPref = AudioOutPref.AUTO,
    launchOutRaw: String? = null,
    launchBufBursts: Int? = null,
    launchIdlePauseRaw: String? = null,
    private val onNoisy: () -> Unit = {},
) {
    private val appContext = context.applicationContext
    private val mainHandler = Handler(Looper.getMainLooper())
    private val gate = AudioStreamGate()
    private val lock = Any()
    @Volatile private var stream: Stream? = null
    private var shut = false
    @Volatile private var errorLogged = false
    /** T-123: transport of the armed connection ([beginSession], [setTransport]); new streams take it. */
    @Volatile private var transport = Transport.USB
    /** T-123: transport the last stream's safety ran on (writer threads; for `safety_transport live=0`). */
    @Volatile private var lastSafetyTransport: Transport? = null
    private val video = VideoLatencyFilter()
    /** T-108: learned jitter-buffer safety per output API, kept across sessions. */
    private val safety = SafetyMemory(SharedPrefsSafetyStore(appContext))
    /** T-110: learned AAudio output buffer size per path, kept across sessions. */
    private val outBuf = OutBufMemory(SharedPrefsOutBufStore(appContext))
    /**
     * T-191: a [forgetLearned] the next stream must apply again before its first output opens: a writer that was live
     * at the reset may store a learned value afterwards (each stats second, on growth, at its final flush).
     */
    private val forgetPending = java.util.concurrent.atomic.AtomicBoolean(false)

    /** AudioTrack burst (the mixer's period). AAudio streams report their own. */
    private val trackBurst: Int
    private val nativeRate: Int
    private val bufBurstsRaw: Int? = launchBufBursts
    private val idlePauseMode: IdlePause.Mode
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

        val resolved = AudioOutPref.resolve(launchOutRaw, storedOutPref)
        if (resolved.unknownExtra) {
            MbLog.w("audio_out_pref_unknown", "using=${resolved.pref.id}", COMPONENT) // the raw value is not logged
        }
        val pref = resolved.pref
        val idleResolved = IdlePause.resolve(launchIdlePauseRaw)
        idlePauseMode = idleResolved.mode
        if (idleResolved.unknown) MbLog.w("audio_idle_pause_unknown", "using=${idlePauseMode.id}", COMPONENT) // raw value not logged
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
                "audio_out=${pref.name.lowercase()} aaudio_lib=${b(lib)} idle_pause=${idlePauseMode.id}",
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

    /**
     * A new control connection [gen] over [transport] is being opened (engine thread): only its audio is taken from now
     * on. The old stream is stopped before the transport changes, so it never switches its safety.
     */
    fun beginSession(gen: Int, transport: Transport): Unit = synchronized(lock) {
        if (shut) return
        stopStream("new_connection")
        this.transport = transport
        gate.arm(gen)
    }

    /**
     * T-123: the current connection now runs over [t] while its stream keeps playing (any thread). The stream's
     * writer switches its safety to [t]'s remembered value within a second, without reopening the output. Today a
     * migration re-arms audio through [beginSession] instead (new stream), so this is the in-stream path only.
     */
    fun setTransport(t: Transport): Unit = synchronized(lock) {
        if (shut) return
        transport = t
        stream?.transport = t
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

    /**
     * T-191 "Varsayılanlara dön" (main thread, non-blocking): forgets the learned safety and output buffer sizes now, and
     * once more when the next stream starts (after the previous writer has finished), so a live stream cannot carry
     * its learned values into the next session. A playing stream keeps its current values until it ends.
     */
    fun forgetLearned() {
        forgetPending.set(true)
        clearLearned("reset")
    }

    private fun clearLearned(at: String) {
        val safetyOk = safety.clear()
        val bufOk = outBuf.clear()
        MbLog.i("audio_learned_clear", "at=$at safety=${b(safetyOk)} buf=${b(bufOk)}", COMPONENT)
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
                stream = Stream(a.streamId, prev, transport).also { it.start() }
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
        s.onPacket()
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

    private inner class Stream(val id: Int, private var previous: Stream?, initialTransport: Transport) {
        val core = PlayoutCore()
        /** T-123: the connection's transport; the writer follows a change ([setTransport]). */
        @Volatile var transport: Transport = initialTransport
        /** T-117: the control reader's arrival figures, taken once per stats line (writer thread only). */
        private val arrivalWin = AudioArrivalMeter.Window()
        @Volatile var rejected = 0L
        @Volatile private var running = true
        @Volatile private var rebuildReason: String? = null
        /** The output the writer is using, published for [stop]. */
        @Volatile private var current: AudioSink? = null
        /** Latency probation of a shared AAudio output (writer thread only). */
        private var probe: SharedLatencyProbe? = null
        private val rebuildTimes = ArrayDeque<Long>()
        /** T-110: headroom and write timing of the current output (writer thread only). */
        private val meter = HeadroomMeter()
        /** [OutBufMemory] path of the current output; null for AudioTrack (not remembered). Writer thread only. */
        private var outBufPath: String? = null
        val finished = CountDownLatch(1)
        /** T-287: pausing rules and state of this stream (writer thread only). */
        private val idlePause = IdlePause(idlePauseMode)
        private val firstSound = FirstSoundTimer()
        /** The writer is parked with its output paused; the reader wakes it on a packet. */
        @Volatile private var parked = false
        @Volatile private var writer: Thread? = null

        fun start() {
            MbLog.i("audio_start", "stream_id=$id", COMPONENT)
            Thread({ run() }, "mb-audio-$id").also { writer = it; it.isDaemon = true; it.start() }
        }

        /** Any thread: the writer reopens its output before its next burst (T-101 output preference). */
        fun requestRebuild(reason: String) {
            if (running) {
                rebuildReason = reason
                wakeWriter()
            }
        }

        /** Control reader thread: a packet was added to the jitter buffer (T-287). No allocation, no blocking. */
        fun onPacket() {
            firstSound.onPacket(System.nanoTime())
            if (parked) wakeWriter()
        }

        private fun wakeWriter() {
            writer?.let { LockSupport.unpark(it) }
        }

        /** Any thread, non-blocking. */
        fun stop(reason: String) {
            if (!running) return
            running = false
            MbLog.i("audio_stop", "stream_id=$id reason=$reason", COMPONENT)
            current?.interrupt()
            wakeWriter()
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
                if (forgetPending.getAndSet(false)) clearLearned("stream_start") // T-191, before the first initial()
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
                safetyApi?.let { safety.flush(it, safetyTransport, core.drift.safetyFrames / MS) }
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
            outBufPath = null
            while (true) {
                if (!running) return null
                val choice = policy.next()
                val path = when (choice) {
                    OutChoice.AAUDIO_EXCLUSIVE -> OutBufMemory.PATH_EXCLUSIVE
                    OutChoice.AAUDIO_SHARED -> OutBufMemory.PATH_SHARED
                    OutChoice.TRACK -> null
                }
                val bufInit = path?.let {
                    outBuf.initial(it, bufBurstsRaw?.let { r -> AudioBufferConfig.startBursts(r) }, AudioBufferConfig.AAUDIO_DEFAULT_BURSTS)
                }
                val sink = try {
                    when (choice) {
                        OutChoice.AAUDIO_EXCLUSIVE, OutChoice.AAUDIO_SHARED -> AAudioSink.open(
                            if (choice == OutChoice.AAUDIO_EXCLUSIVE) AAudioNative.SHARING_EXCLUSIVE else AAudioNative.SHARING_SHARED,
                            bufInit?.bursts ?: AudioBufferConfig.AAUDIO_DEFAULT_BURSTS,
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
                outBufPath = if (sink is AAudioSink) path else null
                val init = applySafety(sink.api)
                MbLog.i(
                    "audio_out",
                    "${sink.logFields()} stream_id=$id reason=$reason requested=${choice.logName} " +
                        "probation=${b(verdict == SinkPolicy.Verdict.PROBATION)} pref=${policy.pref.name.lowercase()} " +
                        "native_rate=$nativeRate rate=$RATE " +
                        "safety_init_ms=${init?.ms ?: (core.drift.safetyFrames / MS)} source=${init?.source ?: "kept"} " +
                        "stored_ms=${init?.storedMs ?: "-"} buf_bursts_init=${bufInit?.bursts ?: "-"} " +
                        "buf_source=${bufInit?.source ?: "-"} buf_stored=${bufInit?.storedBursts ?: "-"}",
                    COMPONENT,
                )
                return sink
            }
        }

        /** Output API and transport whose safety [core] runs with (writer thread only). */
        private var safetyApi: String? = null
        private var safetyTransport: Transport = initialTransport

        /**
         * T-108: an output of [api] was opened. A different API (or the first output) saves the previous API's value and
         * starts from [SafetyMemory.initial] for the stream's transport; the same API keeps the learned value (returns
         * null).
         */
        private fun applySafety(api: String): SafetyMemory.Init? {
            if (api == safetyApi) return null
            safetyApi?.let { safety.flush(it, safetyTransport, core.drift.safetyFrames / MS) }
            val tr = transport
            val init = safety.initial(api, tr)
            core.drift.resetSafety(init.ms, init.profile.defaultMs, init.profile.sessionMaxMs)
            safetyApi = api
            safetyTransport = tr
            // T-118: once per output API taken into use: what was stored and what the controller now runs with.
            MbLog.i(
                "safety_start",
                "stream_id=$id api=$api transport=${tr.logName} stored=${init.storedMs ?: "-"} " +
                    "used=${core.drift.safetyFrames / MS} source=${init.source} remember_max=${init.profile.rememberMaxMs}",
                COMPONENT,
            )
            // T-123: a new stream on another transport than the last one (a migration or reconnect re-arms audio).
            val last = lastSafetyTransport
            if (last != null && last != tr) logTransport(api, last, tr, init, live = false)
            lastSafetyTransport = tr
            return init
        }

        /**
         * T-123: the stream's transport changed under a playing output ([setTransport]): save the old transport's value
         * and move to the new one's rules without reopening (rise at once, fall by decay). Writer thread only.
         */
        private fun followTransport() {
            val api = safetyApi ?: return
            val tr = transport
            if (tr == safetyTransport) return
            val from = safetyTransport
            safety.flush(api, from, core.drift.safetyFrames / MS)
            val init = safety.initial(api, tr)
            core.drift.retarget(init.ms, init.profile.defaultMs, init.profile.sessionMaxMs)
            safetyTransport = tr
            lastSafetyTransport = tr
            logTransport(api, from, tr, init, live = true)
        }

        private fun logTransport(api: String, from: Transport, to: Transport, init: SafetyMemory.Init, live: Boolean) {
            MbLog.i(
                "safety_transport",
                "stream_id=$id api=$api from=${from.logName} to=${to.logName} used=${core.drift.safetyFrames / MS} " +
                    "stored=${init.storedMs ?: "-"} live=${b(live)}",
                COMPONENT,
            )
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
            var avSkipSeen = core.skipTrims // T-125
            var wasPlaying = false
            var packetsAtRender = core.buffer.packets // T-287: packets the last render could have seen
            val firstSoundWait = FirstSoundWait() // T-287: playback started; logged after the first successful write on a started output
            rawLogged = 0
            meter.reset()
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
                    meter.reset()
                    idlePause.onNewOutput()
                    resumeWatch = 0 // a resume being watched on the replaced output is not reported
                }
                // T-287: a long silence suspends the output; the writer parks here until a packet, a stop or a rebuild.
                val packetsNow = core.buffer.packets
                if (idlePause.shouldPause(
                        core.state == PlayoutCore.State.PRIMING, core.framesSinceLastPacket, t.canPause,
                        newPackets = packetsNow != packetsAtRender,
                    )
                ) {
                    when (parkIdle(t, packetsNow)) {
                        Park.STOPPED -> return
                        Park.REBUILD -> continue
                        Park.RESUMED -> {
                            // The device's counters and timestamps stood still: re-read them before the next write, and
                            // do not act on the first second's output underruns (the start may count one).
                            nextTsAt = 0
                            meter.reset()
                            xrunBase = null
                        }
                        Park.NOT_PAUSED -> Unit
                    }
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
                packetsAtRender = core.buffer.packets // before the render, which looks at the packets itself
                core.render(out, t.burst)
                idlePause.onRendered()
                val playing = core.state == PlayoutCore.State.PLAYING
                if (playing && !wasPlaying) firstSoundWait.onPlaybackStart()
                wasPlaying = playing
                val headroom = t.headroom()
                meter.onWriteStart(headroom, System.nanoTime(), t.headroomCounter, t.headroomFromTs)
                val w = t.write(out, t.burst)
                meter.onWriteEnd(System.nanoTime())
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
                if (firstSoundWait.pending && firstSoundWait.onWrite(t.started())) logFirstSound()
                if (resumeWatch != 0L) watchResume(t)
                if (clock.written >= nextLogAt) {
                    nextLogAt += RATE
                    val xr = t.xruns()
                    val base = xrunBase
                    val win = meter.window()
                    // AAudio: the limit is checked here (testable); AudioTrack: its own grow() keeps the old limit.
                    val maxFrames = (t as? AAudioSink)?.maxFrames ?: Int.MAX_VALUE
                    val grow = OutBufGrowth.decide(win, if (base != null) xr - base else 0, t.burst, t.bufFrames, maxFrames, base != null)
                    if (grow != null && t.grow()) {
                        val bursts = (t.bufFrames + t.burst / 2) / t.burst
                        val saved = outBufPath?.let { outBuf.onGrown(it, bursts) } ?: false
                        MbLog.i(
                            "audio_buffer_grow",
                            "stream_id=$id api=${t.api} buf_frames=${t.bufFrames} bursts=$bursts reason=${grow.logName} " +
                                "xruns=$xr out_headroom_min_frames=${win.headroomMinFrames ?: "-"} underflow_est=${win.underflowEst} " +
                                "headroom_source=${win.source} out_headroom_counter_min_frames=${win.counterMinFrames ?: "-"} " +
                                "saved=${b(saved)}",
                            COMPONENT,
                        )
                        nextTsAt = clock.written // re-read the play position now (audio_ms includes the larger buffer)
                    }
                    xrunBase = xr
                    if (audioN > 0) lastAudioMs = audioSum / audioN / 1000
                    if (avN > 0) {
                        val av = avSum / avN
                        lastAvMs = av / 1000
                        // T-125: a skip this second mixes the levels before and after it; the next sample is clean.
                        if (core.skipTrims == avSkipSeen) core.drift.onAvOffset(av)
                    }
                    avSkipSeen = core.skipTrims
                    audioSum = 0; audioN = 0; avSum = 0; avN = 0
                    logStats(t, xr, win, lastAudioMs, lastAvMs)
                    if (running) followTransport()
                    safety.onSafety(t.api, safetyTransport, core.drift.safetyFrames / MS, SystemClock.elapsedRealtime())
                }
            }
        }

        /**
         * T-287: pauses [t], parks until a packet arrives (or a stop or rebuild is requested) and starts it again.
         * NOT_PAUSED: the pause failed (pausing is then off for this stream) and [t] still runs. REBUILD: a rebuild
         * request (or a failed resume) is pending; [t] may be paused and is closed by the rebuild. STOPPED: [stop].
         */
        private fun parkIdle(t: AudioSink, packets: Long): Park {
            val idleS = core.framesSinceLastPacket / RATE
            val stop = idlePause.mode == IdlePause.Mode.STOP
            val t0 = System.nanoTime()
            val ok = t.pause(stop)
            val pauseMs = (System.nanoTime() - t0) / 1_000_000
            if (!ok) {
                idlePause.disable("pause_failed")
                MbLog.w(
                    "idle_pause_failed",
                    "stream_id=$id api=${t.api} mode=${idlePause.mode.id} code=${t.lastError} state=${t.pauseState} pause_ms=$pauseMs",
                    COMPONENT,
                )
                return Park.NOT_PAUSED
            }
            idlePause.onPaused()
            MbLog.i(
                "idle_pause",
                "stream_id=$id api=${t.api} mode=${idlePause.mode.id} idle_s=$idleS state=${t.pauseState} pause_ms=$pauseMs " +
                    "count=${idlePause.pauses}",
                COMPONENT,
            )
            val pausedAtNs = System.nanoTime()
            parked = true
            while (running && rebuildReason == null && core.buffer.packets == packets) {
                LockSupport.parkNanos(this, PARK_CHECK_NS) // unpark() on a packet, stop or rebuild; the timeout is a safety net
            }
            parked = false
            val wokeNs = System.nanoTime()
            if (!running) return Park.STOPPED
            if (rebuildReason != null) {
                MbLog.i("resume_skipped", "stream_id=$id reason=rebuild paused_ms=${(wokeNs - pausedAtNs) / 1_000_000}", COMPONENT)
                return Park.REBUILD
            }
            val arrivedNs = firstSound.peek()
            val s0 = System.nanoTime()
            val resumed = t.resume()
            val requestMs = (System.nanoTime() - s0) / 1_000_000
            resumeFields = "stream_id=$id api=${t.api} mode=${idlePause.mode.id} paused_ms=${(wokeNs - pausedAtNs) / 1_000_000} " +
                "wake_ms=${if (arrivedNs != 0L) ms1(wokeNs - arrivedNs) else "-"} request_ms=$requestMs"
            if (!resumed) {
                MbLog.w("resume", "$resumeFields ok=0", COMPONENT)
                idlePause.disable("resume_failed")
                rebuildReason = "resume_failed"
                return Park.REBUILD
            }
            resumeWatch = s0
            idlePause.onResumed()
            return Park.RESUMED
        }

        /** T-287: fields of the `resume` line, and when the resume was requested (0 = none being watched). */
        private var resumeFields = ""
        private var resumeWatch = 0L

        /**
         * T-287: after a resume, `requestStart` is asynchronous, so its own duration says little: `start_ms` is the time
         * from before the request until the stream reports STARTED (polled after each write; `started=0` if it did not
         * within [RESUME_WATCH_MAX_NS]). `request_ms` is the call itself.
         */
        private fun watchResume(t: AudioSink) {
            val started = t.started()
            val ns = System.nanoTime() - resumeWatch
            if (!started && ns < RESUME_WATCH_MAX_NS) return
            resumeWatch = 0
            MbLog.i("resume", "$resumeFields ok=1 started=${b(started)} start_ms=${ms1(ns)}", COMPONENT)
        }

        /**
         * T-287: playback started: how long after the first packet of a gap, up to the return of the first write that
         * succeeded after playback started (logged with or without pausing).
         */
        private fun logFirstSound() {
            val arrivedNs = firstSound.take()
            if (arrivedNs == 0L) return
            val ns = System.nanoTime() - arrivedNs
            if (ns !in 0..FIRST_SOUND_MAX_NS) return // a gap that never became a restart
            MbLog.i(
                "first_sound",
                "stream_id=$id api=${current?.api ?: "-"} ms=${ms1(ns)} idle_pause=${idlePause.mode.id} pauses=${idlePause.pauses}",
                COMPONENT,
            )
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

        private fun logStats(t: AudioSink, xruns: Int, win: HeadroomMeter.Window, audioMs: Long?, avMs: Long?) {
            val d = core.drift
            val buf = core.buffer
            AudioArrivalMeter.shared.takeWindow(arrivalWin)
            MbLog.i(
                "stats",
                "stream_id=$id state=${if (core.idle) "idle" else core.state.name.lowercase()} api=${t.api} perf_mode=${t.perfName} " +
                    "burst=${t.burst} buf_frames=${t.bufFrames} " +
                    "level_ms_floor=${if (d.lastFloorFrames >= 0) d.lastFloorFrames / MS else -1} level_ms=${core.lastRemainingFrames / MS} " +
                    "target_ms=${d.targetFrames / MS} safety_ms=${d.safetyFrames / MS} ratio_ppm=${d.ratioPpm.toLong()} " +
                    "underruns=${d.underruns} xruns=$xruns " +
                    "out_headroom_min_frames=${win.headroomMinFrames ?: "-"} out_headroom_p5_frames=${win.headroomP5Frames ?: "-"} " +
                    "underflow_est=${if (win.headroomMinFrames != null) win.underflowEst else "-"} " +
                    "headroom_source=${win.source} out_headroom_counter_min_frames=${win.counterMinFrames ?: "-"} " +
                    "write_gap_ms_max=${ms1(win.gapMaxNs)} write_busy_ms_max=${ms1(win.busyMaxNs)} " +
                    "drops=${buf.dropEvents} drop_ms=${buf.dropFrames / MS} gaps=${buf.gapEvents} gap_ms=${buf.gapFrames / MS} jumps=${buf.jumpEvents} idle_gaps=${core.idleGaps} idle_pauses=${idlePause.pauses} late_frames=${buf.lateFrames} " +
                    "resyncs=${d.resyncs} rebuffers=${d.rebuffers} rejected=$rejected muted=${b(core.muted)} " +
                    "refill_trims=${core.refillTrims} refill_trim_ms=${core.refillTrimFrames / MS} " +
                    "skip_trims=${core.skipTrims} skip_trim_ms=${core.skipTrimFrames / MS} " +
                    "av_offset_ms=${avMs ?: "-"} audio_ms=${audioMs ?: "-"} video_ms=${video.value()?.let { it / 1000 } ?: "-"} " +
                    arrivalWin.logFields(),
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
        /** T-287: a parked writer re-checks its wake conditions at least this often (normally it is unparked). */
        const val PARK_CHECK_NS = 1_000_000_000L
        /** T-287: a first-sound stamp older than this belongs to a gap that never ended in a restart. */
        const val FIRST_SOUND_MAX_NS = 5_000_000_000L
        /** T-287: how long a resumed stream is polled for STARTED. */
        const val RESUME_WATCH_MAX_NS = 2_000_000_000L

        fun b(v: Boolean) = if (v) 1 else 0

        /** [ns] as milliseconds with one decimal (logs). */
        fun ms1(ns: Long): String {
            val tenths = ns.coerceAtLeast(0) / 100_000
            return "${tenths / 10}.${tenths % 10}"
        }
    }
}

/** T-287: how [AudioPlayout]'s writer left its idle park. */
private enum class Park { NOT_PAUSED, RESUMED, REBUILD, STOPPED }
