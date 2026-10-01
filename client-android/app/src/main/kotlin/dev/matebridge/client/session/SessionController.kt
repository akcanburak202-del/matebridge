package dev.matebridge.client.session

import dev.matebridge.client.protocol.AudioConfig
import dev.matebridge.client.protocol.AudioFrame
import dev.matebridge.client.protocol.AudioPrefs
import dev.matebridge.client.protocol.Bye
import dev.matebridge.client.protocol.Clipboard
import dev.matebridge.client.protocol.Codec
import dev.matebridge.client.protocol.FrameDecoder
import dev.matebridge.client.protocol.Hello
import dev.matebridge.client.protocol.HelloAck
import dev.matebridge.client.protocol.Message
import dev.matebridge.client.protocol.Pong
import dev.matebridge.client.protocol.ProtocolException
import dev.matebridge.client.protocol.StreamConfig
import dev.matebridge.client.protocol.DisplayRate
import dev.matebridge.client.protocol.StreamPrefs
import dev.matebridge.client.stream.StreamMode
import dev.matebridge.client.protocol.VideoFrame
import dev.matebridge.client.video.PaceTrace
import dev.matebridge.client.video.PerfHint
import dev.matebridge.client.protocol.VideoHello
import dev.matebridge.client.protocol.Bytes
import dev.matebridge.client.protocol.Limits
import dev.matebridge.client.protocol.MsgType
import dev.matebridge.client.security.ClientHandshake
import dev.matebridge.client.security.HandshakeOutcome
import dev.matebridge.client.security.PairKeyStore
import dev.matebridge.client.security.PlainFrames
import dev.matebridge.client.security.RecordDecoder
import dev.matebridge.client.security.RecordOpener
import dev.matebridge.client.security.RecordSealer
import dev.matebridge.client.security.SecureSession
import dev.matebridge.client.security.VideoChannel
import dev.matebridge.client.security.SessionSecrets
import java.security.SecureRandom
import java.util.concurrent.CountDownLatch
import java.io.IOException
import java.io.InputStream
import java.net.InetSocketAddress
import java.net.Socket
import java.util.concurrent.Executors
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong

/** Callbacks arrive on background threads; the UI layer must hop to the main thread. */
interface SessionListener {
    fun onUi(state: SessionUi)

    /** A new stream configuration was accepted (before the video connection is (re)opened). */
    fun onStreamConfig(config: StreamConfig) {}

    /** One VIDEO_FRAME wire fragment, from the video reader thread. Frames are only counted in T-012. */
    fun onVideoFrame(frame: VideoFrame) {}

    /** A new control connection is being opened (first start and every automatic reconnect); reset per-session state. */
    fun onSessionStart() {}

    /**
     * Right after [onSessionStart], with the new control connection's generation (engine thread). T-095: audio is
     * armed for exactly this generation; [onAudio] carries the generation of the reader that delivered it.
     */
    fun onConnectionGen(gen: Int) {}

    /** The control connection was closed (engine thread; before any later [onSessionStart]). T-095: audio stops here. */
    fun onSessionEnd() {}

    /** A PONG arrived (engine thread). Times are microseconds; [nowUs] is the client monotonic clock (`nanoTime/1000`). */
    fun onPong(echoTimeUs: Long, responderTimeUs: Long, nowUs: Long) {}

    /** A CLIPBOARD message arrived on an accepted session (engine thread). Its data is private: never log it. */
    fun onClipboard(msg: Clipboard, gen: Int) {}

    /**
     * AUDIO_CONFIG or AUDIO_FRAME from the reader thread of control connection [gen] (it bypasses the engine queue so
     * audio never waits behind a tick). A reader can outlive its connection: the receiver must drop messages whose
     * [gen] is not the one it was armed with ([onConnectionGen]). Must not block. Never log the PCM data.
     */
    fun onAudio(msg: Message, gen: Int) {}

    /**
     * T-096: outcome of [SessionController.migrate] (engine thread), once per request the engine took (a request
     * replaced in the mailbox by a newer one, or made after shutdown, gets none). On success the session now runs over
     * [endpoint]; [onSessionEnd], [onSessionStart] and [onConnectionGen] were called for the switch before it.
     */
    fun onMigration(endpoint: Endpoint, ok: Boolean, reason: String) {}
}

/**
 * Owns the sockets and threads around [SessionMachine]. No socket I/O runs on the caller's thread:
 *  - one engine thread runs the machine (events from a bounded queue plus a 100 ms tick),
 *  - per connection a reader thread; the control connection also has one writer thread fed by a
 *    bounded single-FIFO [SendQueue] (PROTOCOL.md sections 5 and 7).
 * [start]/[stop] and [trySend] may be called from any thread.
 */
class SessionController(
    private val hello: Hello,
    private val pairKeys: PairKeyStore,
    private val listener: SessionListener,
    initialMode: StreamMode = StreamMode.DEFAULT,
    private val quickAck: Boolean = true, // T-074 experiment switch (--ez quickack false)
    private val perfHint: PerfHint? = null, // T-079 experiment (--ez perf_hint true): video reader joins the hint session
    private val knobs: WifiKnobs = WifiKnobs(), // T-089 experiment knobs (ping interval, socket traffic class)
    initialAudio: Boolean? = null, // T-095: AUDIO_PREFS wish; null = audio not supported, AUDIO_PREFS never sent
) {
    private val machine = SessionMachine(hello, initialMode.toPrefs(), knobs.pingIntervalUs, initialAudio)

    /** Engine tick; at most half the ping interval (>= 10 ms) so a short `ping_ms` is honoured (default: 100 ms as before). */
    private val tickMs = engineTickMs(knobs.pingMs)
    private val random = SecureRandom()

    /** Messages from control reader threads; bounded, and only those threads ever block on it. */
    private val events = LinkedBlockingQueue<SessionMachine.Event>(EVENT_QUEUE_CAP)

    /** Commands and close notifications: single-slot mailboxes, non-blocking and O(1) memory, drained by the engine. */
    private val intent = Latest<SessionMachine.Event>() // Start/Stop: the latest desired state wins
    private val prefsMailbox = Latest<SessionMachine.Event>() // the newest display-mode request wins
    private val rateMailbox = Latest<SessionMachine.Event>() // the newest panel rate wins
    private val audioMailbox = Latest<SessionMachine.Event>() // the newest audio setting wins
    private val migrateMailbox = Latest<SessionMachine.Event>() // T-096: the newest migration request wins
    /** T-096: a migration candidate's close has its own slot, so it cannot hide the (lower-gen) current one's close. */
    private val controlClosed = ControlCloseSlots()

    /**
     * T-096: a candidate reads the stored pair key (PAIRED takeover) but never stores one: a migration must not pair.
     * A PAIRING answer therefore fails the candidate (KeyStoreFailed -> migration aborted) instead of replacing the key.
     */
    private val candidateKeys = object : PairKeyStore {
        override fun get(hostId: ByteArray): ByteArray? = pairKeys.get(hostId)
        override fun put(hostId: ByteArray, key: ByteArray) = throw IOException("a migration candidate never stores a pair key")
    }
    private val videoClosed = LatestGen<SessionMachine.Event.VideoClosed> { it.gen }

    private val videoFrames = AtomicLong()
    private val running = AtomicBoolean(false)
    private val terminated = AtomicBoolean(false)
    private val timer = Executors.newSingleThreadScheduledExecutor { r -> Thread(r, "mb-timer").also { it.isDaemon = true } }
    private var engine: Thread? = null

    @Volatile private var control: ControlConn? = null
    /** T-096: migration candidate (handshaking beside [control]) and the retired former control connection. */
    @Volatile private var candidate: ControlConn? = null
    @Volatile private var retired: ControlConn? = null
    @Volatile private var video: VideoConn? = null
    @Volatile private var inputAllowed = false

    /** config_id of the latest applied STREAM_CONFIG; frames from a video connection of another config are dropped. */
    @Volatile private var currentConfigId = -1
    @Volatile private var stopAfterDrain = false

    /** Non-blocking. Ignored after [shutdown]. */
    fun start(endpoint: Endpoint) {
        if (terminated.get()) return
        ensureEngine()
        intent.post(SessionMachine.Event.Start(endpoint))
    }

    /** Non-blocking. Remembers the display mode and sends STREAM_PREFS now when the session is accepted (T-050). */
    fun setStreamMode(mode: StreamMode) {
        if (terminated.get()) return
        ensureEngine()
        prefsMailbox.post(SessionMachine.Event.SetPrefs(mode.toPrefs()))
    }

    /** Non-blocking. The (already debounced) panel rate in Hz; sent when accepted and on change (T-059). */
    fun setDisplayRate(hz: Int) {
        if (terminated.get()) return
        ensureEngine()
        rateMailbox.post(SessionMachine.Event.SetDisplayRate(hz))
    }

    /** Non-blocking. The audio setting (T-095); sent as AUDIO_PREFS when accepted and on change. */
    fun setAudioEnabled(on: Boolean) {
        if (terminated.get()) return
        ensureEngine()
        audioMailbox.post(SessionMachine.Event.SetAudio(on))
    }

    /**
     * Non-blocking. T-096: moves the accepted session to [endpoint] via the host's takeover, make-before-break (see
     * [SessionMachine]). The result arrives as [SessionListener.onMigration].
     */
    fun migrate(endpoint: Endpoint) {
        if (terminated.get()) return
        ensureEngine()
        migrateMailbox.post(SessionMachine.Event.Migrate(endpoint))
    }

    /** Non-blocking. */
    fun stop() {
        intent.post(SessionMachine.Event.Stop)
    }

    /** Terminal: stops the session (BYE goes out gracefully) and the engine; later [start] calls are ignored. */
    fun shutdown() {
        if (!terminated.compareAndSet(false, true)) return
        intent.post(SessionMachine.Event.Stop)
        stopAfterDrain = true
    }

    /**
     * Enqueues an input/maintenance message on the single control FIFO. Returns false when the session
     * is not ACCEPTED (input must not be sent before approval) or the queue overflowed; an overflow
     * aborts the connection so the session reconnects (PROTOCOL.md section 5).
     */
    fun trySend(msg: Message): Boolean {
        if (!inputAllowed) return false
        val c = control ?: return false
        return c.link.send(msg)
    }

    /**
     * T-096: [trySend] for input, only onto control connection [gen] (the one the input layer last reset its model for,
     * see [SessionListener.onConnectionGen]). After a migration switch, input produced from the old connection's model
     * (a mid-stroke contact, a held key) is refused instead of reaching the new session; the refusal makes the input
     * layer forget that model. The old connection's input is released by the host (takeover / disconnect).
     */
    fun trySendInput(msg: Message, gen: Int): Boolean {
        if (!inputAllowed) return false
        val c = control ?: return false
        if (c.gen != gen) return false
        return c.link.send(msg)
    }

    /**
     * Drops the accepted control connection like a send-queue overflow does: the session reports it closed and
     * reconnects, and the host releases all input on the disconnect (PROTOCOL.md section 7). Used when a RELEASE_ALL
     * could not be queued. No-op without an accepted session (the host holds nothing then). Any thread.
     */
    fun dropConnection() {
        if (!inputAllowed) return
        control?.dropForOverflow()
    }

    /**
     * T-096: [dropConnection] only if [gen] is still the current control connection. An older generation's connection
     * is already closed or retired (closing), so the host releases its input anyway; the new session is not dropped.
     */
    fun dropConnection(gen: Int) {
        if (!inputAllowed) return
        val c = control ?: return
        if (c.gen == gen) c.dropForOverflow()
    }

    /** True while the control send queue is backed up (input layer holds mergeable hover/scroll samples then). Any thread. */
    fun isSendCongested(): Boolean = control?.link?.congested() ?: false

    private fun ensureEngine() {
        if (!running.compareAndSet(false, true)) return
        engine = Thread({ engineLoop() }, "mb-session").also { it.isDaemon = true; it.start() }
    }

    private fun nowUs() = System.nanoTime() / 1000

    private fun engineLoop() {
        var lastTickNs = System.nanoTime()
        try {
            while (true) {
                var e: SessionMachine.Event? = intent.take() ?: prefsMailbox.take() ?: rateMailbox.take() ?: audioMailbox.take() ?:
                    migrateMailbox.take() ?: controlClosed.take() ?: videoClosed.take()
                if (e == null) {
                    if (stopAfterDrain) break
                    val waitMs = tickMs - (System.nanoTime() - lastTickNs) / 1_000_000
                    e = events.poll(maxOf(waitMs, 0), TimeUnit.MILLISECONDS)
                }
                if (e != null) dispatch(e)
                // A busy queue must not starve ticks (PONG timeout, retries, pings).
                if (System.nanoTime() - lastTickNs >= tickMs * 1_000_000) {
                    lastTickNs = System.nanoTime()
                    dispatch(SessionMachine.Event.Tick(videoFrames.get()))
                }
            }
        } catch (ie: InterruptedException) {
            // shutting down
        } finally {
            control?.closeGracefully()
            candidate?.abort()
            retired?.abort()
            video?.abort()
            timer.schedule({ timer.shutdown() }, GRACEFUL_CLOSE_MS + 200, TimeUnit.MILLISECONDS)
        }
    }

    private fun dispatch(e: SessionMachine.Event) {
        if (e is SessionMachine.Event.Start) videoFrames.set(0)
        logEvent(e)
        val now = nowUs()
        // Only the current connection's PONGs feed the clock (T-096: a retired one may still answer for a moment).
        if (e is SessionMachine.Event.Received && e.msg is Pong && e.gen == MbLog.gen) listener.onPong(e.msg.echoTimeUs, e.msg.responderTimeUs, now)
        if (e is SessionMachine.Event.Received && e.msg is Clipboard && inputAllowed && e.gen == MbLog.gen) listener.onClipboard(e.msg, e.gen)
        val actions = machine.handle(e, now)
        val allowed = machine.inputAllowed
        // Input stops before the actions run (as before), but starts only after them: the proof PING and STREAM_PREFS
        // are queued first (PROTOCOL.md section 3). A migration switch closes the gate while the connections swap.
        if (!allowed || actions.any { it is SessionMachine.Action.PromoteCandidate }) inputAllowed = false
        MbLog.sid = machine.currentSessionId
        for (a in actions) exec(a)
        inputAllowed = allowed
    }

    /** Concise session log (docs/LOGGING.md). Never per frame, never names or message text. */
    private fun logEvent(e: SessionMachine.Event) {
        when (e) {
            is SessionMachine.Event.Start -> MbLog.i(
                "session_start",
                "host=${e.endpoint.host} port=${e.endpoint.port} transport=${ConnectMode.transportOf(e.endpoint).logName} " +
                    "quickack=${if (quickAck) 1 else 0} ${knobs.logFields()}",
            )
            SessionMachine.Event.Stop -> MbLog.i("session_stop")
            is SessionMachine.Event.ControlOpened -> MbLog.i("connect_ok")
            is SessionMachine.Event.ControlClosed ->
                if (e.connectFailed) MbLog.w("connect_fail") else MbLog.w("control_closed")
            is SessionMachine.Event.ProtocolError -> MbLog.e("protocol_error")
            is SessionMachine.Event.Secured -> MbLog.i("secured", "pairing=${e.code != null} re_pairing=${e.rePairing}") // never the code
            is SessionMachine.Event.KeyMissing -> MbLog.w("pair_key_missing")
            is SessionMachine.Event.KeyStoreFailed -> MbLog.w("pair_key_store_failed")
            is SessionMachine.Event.VideoClosed -> MbLog.w("video_closed", "vgen=${e.gen}")
            is SessionMachine.Event.Received -> when (val m = e.msg) {
                is HelloAck -> MbLog.i("hello_ack", "status=${m.status} key_mode=${m.keyMode} video_port=${m.videoPort}")
                is StreamConfig -> MbLog.i(
                    "stream_config",
                    "config_id=${m.configId} codec=${m.codec} size=${m.widthPx}x${m.heightPx} fps=${m.fps}",
                )
                is Bye -> MbLog.i("bye_recv", "reason=${m.reason}")
                else -> Unit
            }
            is SessionMachine.Event.SetPrefs -> MbLog.i("stream_prefs_set", "fps=${e.prefs.fps} scale=${e.prefs.scalePermille}")
            is SessionMachine.Event.SetDisplayRate -> MbLog.i("display_rate_set", "hz=${e.hz}")
            is SessionMachine.Event.SetAudio -> MbLog.i("audio_prefs_set", "enabled=${if (e.enabled) 1 else 0}")
            is SessionMachine.Event.Tick -> Unit
            is SessionMachine.Event.Migrate -> MbLog.i(
                "migrate_request",
                "host=${e.endpoint.host} port=${e.endpoint.port} transport=${ConnectMode.transportOf(e.endpoint).logName}",
            )
        }
    }

    private fun exec(a: SessionMachine.Action) {
        when (a) {
            is SessionMachine.Action.OpenControl -> {
                MbLog.gen = a.gen
                MbLog.i("connect_start", "host=${a.endpoint.host} port=${a.endpoint.port}")
                listener.onSessionStart()
                listener.onConnectionGen(a.gen)
                control?.abort()
                control = ControlConn(a.gen, a.endpoint, hello).also { it.startThreads() }
            }
            is SessionMachine.Action.Send -> {
                when (val m = a.msg) {
                    is Hello -> MbLog.i("hello_sent", "proto=${m.protocolVersion}")
                    is Bye -> MbLog.i("bye_sent", "reason=${m.reason}")
                    is DisplayRate -> MbLog.i("display_rate_sent", "hz=${m.hz}")
                    is StreamPrefs -> MbLog.i("stream_prefs_sent", "fps=${m.fps} scale=${m.scalePermille}")
                    is AudioPrefs -> MbLog.i("audio_prefs_sent", "enabled=${if (m.enabled) 1 else 0}")
                    else -> Unit
                }
                val c = control
                // The machine's HELLO is a template: this connection's nonce and ephemeral key go in here.
                c?.link?.send(if (a.msg is Hello) c.helloMsg else a.msg) // overflow is reported through the link itself
            }
            is SessionMachine.Action.CloseControl -> {
                control?.let { if (a.graceful) it.closeGracefully() else it.abort() }
                control = null
                listener.onSessionEnd()
            }
            is SessionMachine.Action.OpenVideo -> {
                MbLog.i("video_open", "vgen=${a.gen} port=${a.endpoint.port} config_id=${a.hello.configId}")
                video?.abort()
                val secrets = control?.secrets
                if (secrets == null) {
                    MbLog.w("video_no_keys")
                    videoClosed.post(SessionMachine.Event.VideoClosed(a.gen))
                } else {
                    video = VideoConn(a.gen, a.endpoint, a.hello, secrets).also { it.startThread() }
                }
            }
            SessionMachine.Action.CloseVideo -> {
                if (video != null) MbLog.i("video_close")
                video?.abort()
                video = null
            }
            is SessionMachine.Action.ApplyConfig -> {
                currentConfigId = a.config.configId
                listener.onStreamConfig(a.config)
            }
            is SessionMachine.Action.Ui -> {
                when (val u = a.state) {
                    is SessionUi.Disconnected -> MbLog.i("reconnect", "cause=${u.cause} delay_ms=${u.retryInMs}")
                    is SessionUi.Failed -> MbLog.w("session_failed", "cause=${u.cause}")
                    else -> Unit
                }
                listener.onUi(a.state)
            }
            is SessionMachine.Action.OpenCandidate -> {
                MbLog.i("migrate_start", "cand_gen=${a.gen} host=${a.endpoint.host} port=${a.endpoint.port}")
                candidate?.cancel()
                val c = ControlConn(a.gen, a.endpoint, hello, ControlCloseSlots.Owner.CANDIDATE, candidateKeys)
                candidate = c
                c.startThreads()
            }
            is SessionMachine.Action.SendCandidate -> {
                val c = candidate
                if (a.msg is Hello) MbLog.i("hello_sent", "proto=${a.msg.protocolVersion} cand_gen=${c?.gen ?: -1}")
                c?.link?.send(if (a.msg is Hello) c.helloMsg else a.msg)
            }
            SessionMachine.Action.CloseCandidate -> {
                candidate?.cancel()
                candidate = null
            }
            SessionMachine.Action.RetireControl -> {
                // No BYE and no more input; queued messages still drain. The host closes it on our takeover proof.
                retired?.closeGracefully()
                retired = control
                control = null
                listener.onSessionEnd()
            }
            is SessionMachine.Action.PromoteCandidate -> {
                val c = candidate
                candidate = null
                if (c == null || c.gen != a.gen) {
                    // Cannot happen (the machine promotes only its live candidate); fail safe: the session reconnects.
                    MbLog.e("migrate_no_candidate", "cand_gen=${a.gen}")
                    c?.cancel()
                    controlClosed.post(SessionMachine.Event.ControlClosed(a.gen), ControlCloseSlots.Owner.CURRENT)
                    return
                }
                c.owner = ControlCloseSlots.Owner.CURRENT // from now on its close is the session's close
                MbLog.gen = a.gen
                MbLog.i("migrate_switch", "host=${a.endpoint.host} port=${a.endpoint.port} transport=${ConnectMode.transportOf(a.endpoint).logName}")
                listener.onSessionStart()
                listener.onConnectionGen(a.gen)
                control = c
            }
            SessionMachine.Action.CloseRetired -> {
                retired?.let { MbLog.i("retired_close", "old_gen=${it.gen}") ; it.closeGracefully() }
                retired = null
            }
            is SessionMachine.Action.MigrationResult -> {
                val f = "ok=${if (a.ok) 1 else 0} to=${ConnectMode.transportOf(a.endpoint).logName} reason=${a.reason}"
                if (a.ok) MbLog.i("transport_migrate", f) else MbLog.w("transport_migrate", f)
                listener.onMigration(a.endpoint, a.ok, a.reason)
            }
        }
    }

    private inner class ControlConn(
        val gen: Int,
        private val endpoint: Endpoint,
        template: Hello,
        /** T-096: which close slot this connection posts to; changed only by the engine (promotion, cancel). */
        @Volatile var owner: ControlCloseSlots.Owner = ControlCloseSlots.Owner.CURRENT,
        private val keys: PairKeyStore = pairKeys,
    ) {
        private val socket = Socket()
        private val queue = SendQueue()
        private val closedPosted = AtomicBoolean(false)
        private val handshake = ClientHandshake(random)

        /** This connection's HELLO (fresh nonce and ephemeral key); its payload bytes feed the transcript hash. */
        val helloMsg: Hello = handshake.hello(template)

        /** Session keys once the first HELLO_ACK was validated; video connections derive their keys from it. */
        @Volatile var secrets: SessionSecrets? = null
            private set

        @Volatile private var sealer: RecordSealer? = null
        private val sealerReady = CountDownLatch(1)

        val link = ControlLink(queue, { System.nanoTime() / 1_000_000 }) {
            // Overflow: a message was lost, so the connection must not live on (PINGs would keep it alive).
            abort()
            notifyClosed(connectFailed = false)
        }

        fun startThreads() {
            Thread({ readerLoop() }, "mb-ctl-read-$gen").also { it.isDaemon = true; it.start() }
        }

        /** Writer closes the socket after draining; a deadline aborts it if the writer is stuck. */
        fun closeGracefully() {
            queue.closeGracefully()
            try {
                timer.schedule({ abort() }, GRACEFUL_CLOSE_MS, TimeUnit.MILLISECONDS)
            } catch (_: RejectedExecutionException) {
                abort()
            }
        }

        fun abort() {
            queue.abort()
            closeQuietly(socket)
            secrets?.wipe()
            sealerReady.countDown() // releases a writer still waiting for keys
        }

        /** T-096: abort a candidate the machine gave up on; its close notification is dropped (owner set first). */
        fun cancel() {
            owner = ControlCloseSlots.Owner.CANCELLED
            abort()
        }

        /** Same as the overflow handler in [link]: abort and report the connection closed (once). */
        fun dropForOverflow() {
            abort()
            notifyClosed(connectFailed = false)
        }

        private fun notifyClosed(connectFailed: Boolean) {
            if (!closedPosted.compareAndSet(false, true)) return
            controlClosed.post(SessionMachine.Event.ControlClosed(gen, connectFailed), owner)
        }

        private fun readerLoop() {
            try {
                val tosErr = TrafficClass.trySet(knobs.tosCtl) { socket.trafficClass = it } // T-089, before connect
                socket.connect(InetSocketAddress(endpoint.host, endpoint.port), CONNECT_TIMEOUT_MS)
                socket.tcpNoDelay = true
                knobs.tosCtl?.let { MbLog.i("traffic_class", TrafficClass.logFields("control", it, tosErr) { socket.trafficClass }) }
            } catch (e: IOException) {
                closeQuietly(socket)
                notifyClosed(connectFailed = true)
                return
            }
            Thread({ writerLoop() }, "mb-ctl-write-$gen").also { it.isDaemon = true; it.start() }
            events.put(SessionMachine.Event.ControlOpened(gen))
            try {
                val input = socket.getInputStream()
                // The first HELLO_ACK is the only plaintext host message; it is read byte-exactly so the
                // encrypted records that may follow immediately are not consumed (PROTOCOL.md section 9).
                val (ack, ackPayload) = PlainFrames.readHelloAck(input)
                when (val outcome = handshake.complete(ack, ackPayload, keys)) {
                    is HandshakeOutcome.Plain -> events.put(SessionMachine.Event.Received(gen, ack)) // terminal; host closes
                    HandshakeOutcome.KeyMissing -> {
                        closedPosted.set(true)
                        events.put(SessionMachine.Event.KeyMissing(gen))
                        return
                    }
                    is HandshakeOutcome.Secure -> {
                        val sec = outcome.session
                        try {
                            // Stored at the first ack, before the Mac's approval: the connection may drop meanwhile.
                            if (sec.storePairKey(keys)) MbLog.i("pair_key_stored")
                        } catch (e: Exception) {
                            // Not persisted: a later PAIRED handshake would have no key. Fail instead of pretending.
                            closedPosted.set(true)
                            events.put(SessionMachine.Event.KeyStoreFailed(gen)) // the key itself is never logged
                            return
                        }
                        secrets = sec.secrets
                        sealer = sec.sealer
                        sealerReady.countDown()
                        if (sec.sas != null) events.put(SessionMachine.Event.Secured(gen, sec.sas, sec.rePairing))
                        events.put(SessionMachine.Event.Received(gen, ack))
                        readRecords(input, sec)
                    }
                }
            } catch (e: ProtocolException) {
                closedPosted.set(true) // the machine reacts to ProtocolError instead
                events.put(SessionMachine.Event.ProtocolError(gen)) // ordered after already received messages
                return
            } catch (e: IOException) {
                // fall through
            }
            // EOF/IO error: ordered after already received messages (e.g. a final BYE), so use the bounded queue.
            if (closedPosted.compareAndSet(false, true)) events.put(SessionMachine.Event.ControlClosed(gen))
        }

        private fun readRecords(input: InputStream, sec: SecureSession) {
            val decoder = RecordDecoder(Limits.CONTROL_MAX_PAYLOAD, sec.opener)
            val buf = ByteArray(RecordDecoder.READ_CHUNK)
            QuickAck.forSocket(socket, quickAck, "control").use { qa ->
                while (true) {
                    val n = input.read(buf)
                    if (n < 0) break
                    qa.ack.afterRead()
                    decoder.feed(buf, 0, n)
                    while (true) {
                        val msg = decoder.next() ?: break
                        if (msg is AudioFrame || msg is AudioConfig) deliverAudio(msg) else events.put(SessionMachine.Event.Received(gen, msg))
                    }
                }
            }
        }

        /** T-095: audio goes from this reader straight to the listener, only while this is the current connection. */
        private fun deliverAudio(msg: Message) {
            if (control !== this) return // cheap pre-filter; the receiver re-checks [gen] under its own lock
            try {
                listener.onAudio(msg, gen)
            } catch (e: RuntimeException) {
                if (!audioErrorLogged) {
                    audioErrorLogged = true
                    MbLog.e("audio_deliver_failed", "err=${e.javaClass.simpleName}") // audio never takes the session down
                }
            }
        }

        private var audioErrorLogged = false

        private fun writerLoop() {
            try {
                val out = socket.getOutputStream()
                var first = true
                while (true) {
                    val frame = queue.take() ?: break
                    val wire = if (first) {
                        // Only HELLO goes out in plaintext, and only first; everything else is sealed in FIFO order.
                        first = false
                        if ((frame[0].toInt() and 0xFF) != MsgType.HELLO) throw IOException("first message must be HELLO")
                        frame
                    } else {
                        sealerReady.await()
                        val s = sealer ?: throw IOException("no keys")
                        s.sealFrame(frame)
                    }
                    out.write(wire)
                    out.flush()
                }
                // Graceful close after a drained queue: half-close so the peer sees BYE then EOF.
                if (!socket.isClosed) closeQuietly(socket)
            } catch (e: IOException) {
                closeQuietly(socket)
                notifyClosed(connectFailed = false)
            }
        }
    }

    private inner class VideoConn(
        val gen: Int,
        private val endpoint: Endpoint,
        private val hello: VideoHello,
        private val secrets: SessionSecrets,
    ) {
        private val socket = Socket()
        private val closedPosted = AtomicBoolean(false)

        fun startThread() {
            Thread({ loop() }, "mb-video-$gen").also { it.isDaemon = true; it.start() }
        }

        fun abort() {
            closedPosted.set(true)
            closeQuietly(socket)
        }

        private fun loop() {
            val buf = ByteArray(RecordDecoder.READ_CHUNK)
            var qa: QuickAck.Handle = QuickAck.Handle(QuickAck(false, {}), null)
            val hint = perfHint
            val tid = if (hint != null) android.os.Process.myTid() else 0
            hint?.register(PerfHint.ROLE_NET, tid)
            try {
                // Fresh nonce per video connection; both directions' keys come from it (section 9).
                val nonce = ByteArray(Limits.NONCE_BYTES).also { random.nextBytes(it) }
                val channel = VideoChannel(secrets.videoKeys(nonce))
                val decoder = channel.decoder
                val tosErr = TrafficClass.trySet(knobs.tosVideo) { socket.trafficClass = it } // T-089, before connect
                socket.connect(InetSocketAddress(endpoint.host, endpoint.port), CONNECT_TIMEOUT_MS)
                socket.tcpNoDelay = true
                knobs.tosVideo?.let { MbLog.i("traffic_class", TrafficClass.logFields("video", it, tosErr) { socket.trafficClass }) }
                // VIDEO_HELLO in plaintext, then one sealed PING as proof of the key (the host sends no frames before it).
                socket.getOutputStream().apply { write(channel.opening(hello, nonce, nowUs())); flush() }
                val input = socket.getInputStream()
                qa = QuickAck.forSocket(socket, quickAck, "video")
                while (true) {
                    val n = input.read(buf)
                    if (n > 0) qa.ack.afterRead()
                    val trace = PaceTrace.active // T-073: receive-path timestamps (null = off)
                    val recvNs = if (trace != null || hint != null) System.nanoTime() else 0L
                    if (n < 0) break
                    decoder.feed(buf, 0, n)
                    while (true) {
                        val msg = decoder.next() ?: break
                        if (msg is VideoFrame) {
                            trace?.onRecv(msg.frameSeq, msg.captureTimeUs, msg.data.size, recvNs, System.nanoTime())
                            hint?.onRecv(msg.frameSeq, recvNs) // T-079: start of the frame's reported work
                            if (msg.fragmentIndex == 0) videoFrames.incrementAndGet()
                            if (hello.configId == currentConfigId) listener.onVideoFrame(msg)
                        }
                    }
                }
            } catch (e: ProtocolException) {
                // Video protocol/authentication errors close only the video connection (PROTOCOL.md sections 2, 9).
            } catch (e: IOException) {
                // fall through
            } catch (e: IllegalStateException) {
                // session secrets wiped: the control connection is gone
            } finally {
                hint?.unregister(PerfHint.ROLE_NET, tid)
            }
            qa.close()
            closeQuietly(socket)
            if (closedPosted.compareAndSet(false, true)) videoClosed.post(SessionMachine.Event.VideoClosed(gen))
        }
    }

    private fun closeQuietly(s: Socket) {
        try { s.close() } catch (_: IOException) {}
    }

    companion object {
        /** The clock all session/latency times use. */
        fun clockUs() = System.nanoTime() / 1000

        /** T-089: the engine tick for a ping interval: [TICK_MS] unless half the interval is shorter, never below 10 ms. */
        fun engineTickMs(pingMs: Int): Long = minOf(TICK_MS, maxOf(10L, pingMs / 2L))

        private const val TICK_MS = 100L
        private const val GRACEFUL_CLOSE_MS = 1000L
        private const val CONNECT_TIMEOUT_MS = 5000
        private const val EVENT_QUEUE_CAP = 1024
    }
}
