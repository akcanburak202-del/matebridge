package dev.matebridge.client.session

import dev.matebridge.client.protocol.AudioPrefs
import dev.matebridge.client.protocol.Bye
import dev.matebridge.client.protocol.DisplayRate
import dev.matebridge.client.protocol.Hello
import dev.matebridge.client.protocol.HelloAck
import dev.matebridge.client.protocol.Message
import dev.matebridge.client.protocol.Ping
import dev.matebridge.client.protocol.Pong
import dev.matebridge.client.protocol.SettingsOpen
import dev.matebridge.client.protocol.StreamConfig
import dev.matebridge.client.protocol.StreamPrefs
import dev.matebridge.client.stream.StreamMode
import dev.matebridge.client.protocol.VideoHello

/**
 * Client session state machine (PROTOCOL.md sections 3 and 6). Pure Kotlin: it consumes [Event]s with
 * a monotonic timestamp and returns [Action]s; sockets, threads and clocks live in [SessionController].
 * Not thread-safe: drive it from one thread.
 *
 * Connection generations: every OpenControl / OpenVideo action carries a fresh generation number and
 * events from connections that are no longer current are ignored, so a late close of an old video
 * connection (after STREAM_CONFIG changed) cannot disturb the new one.
 *
 * Retry policy: lost/closed connections and BUSY retry automatically with backoff (1 s doubling to 5 s,
 * reset on ACCEPTED; BUSY waits at least 3 s). REJECTED and VERSION_MISMATCH do not retry, because
 * retrying would only re-prompt the Mac user or fail again; the user must press connect.
 *
 * Migration (T-096): [Event.Migrate] moves an accepted session to another endpoint (Wi-Fi -> USB) make-before-break,
 * through the host's same-device takeover (PROTOCOL.md section 3.3). A *candidate* control connection is opened next to
 * the current one and sends its own HELLO. Only when it is ACCEPTED (PAIRED) does it become current: the old video
 * closes, the old control connection is *retired* (no BYE, no more input routed to it, already queued messages still
 * drain), and the proof PING goes out first on the new one. The host releases the old session's input and closes it
 * when that proof arrives, and only then sends the new STREAM_CONFIG; the retired connection is closed on that
 * STREAM_CONFIG (or after [RETIRE_TIMEOUT_US]). A candidate that fails in any way is closed alone: the current session
 * is never touched. Every Migrate yields exactly one [Action.MigrationResult].
 */
class SessionMachine(
    private val hello: Hello,
    initialPrefs: StreamPrefs = StreamMode.DEFAULT.toPrefs(),
    private val pingIntervalUs: Long = PING_INTERVAL_US, // T-089 knob (--ei ping_ms N); the PONG timeout is unchanged
    initialAudio: Boolean? = null, // T-095: AUDIO_PREFS wish; null = this client does not do audio (nothing is sent)
) {
    sealed interface Event {
        data class Start(val endpoint: Endpoint) : Event
        data object Stop : Event
        data class ControlOpened(val gen: Int) : Event
        /** Control connection failed to open, hit EOF/IO error, or its send queue overflowed. */
        data class ControlClosed(val gen: Int, val connectFailed: Boolean = false) : Event
        data class Received(val gen: Int, val msg: Message) : Event
        data class ProtocolError(val gen: Int) : Event
        /** The first HELLO_ACK was encrypted and valid. [code] is the pairing code (PAIRING only); comes before the ack itself. */
        data class Secured(val gen: Int, val code: String?, val rePairing: Boolean) : Event
        /** PAIRED HELLO_ACK but no stored key for this host: re-pairing is required (no retry). */
        data class KeyMissing(val gen: Int) : Event
        /** The new pairing key could not be persisted: pairing must not be reported as successful. */
        data class KeyStoreFailed(val gen: Int) : Event
        /** The user picked a display mode (T-050): remembered for this and later connections, sent now when input is allowed. */
        data class SetPrefs(val prefs: StreamPrefs) : Event
        /** The debounced panel rate (T-059): remembered, sent now when input is allowed and the value changed. */
        data class SetDisplayRate(val hz: Int) : Event
        /** The user's audio setting (T-095): remembered, and sent as AUDIO_PREFS now when input is allowed. */
        data class SetAudio(val enabled: Boolean) : Event
        /** Video connection closed or failed to open. */
        data class VideoClosed(val gen: Int) : Event
        /** Periodic; [videoFrames] is the running count of frames received on video connections. */
        data class Tick(val videoFrames: Long) : Event
        /** T-096: move the accepted session to [endpoint] via takeover (make-before-break); see the class comment. */
        data class Migrate(val endpoint: Endpoint) : Event
    }

    sealed interface Action {
        data class OpenControl(val gen: Int, val endpoint: Endpoint) : Action
        data class Send(val msg: Message) : Action
        /** [graceful]: flush already queued messages (a final BYE) before closing. */
        data class CloseControl(val graceful: Boolean) : Action
        data class OpenVideo(val gen: Int, val endpoint: Endpoint, val hello: VideoHello) : Action
        data object CloseVideo : Action
        /** A new STREAM_CONFIG was accepted; the video connection is (re)opened right after. */
        data class ApplyConfig(val config: StreamConfig) : Action
        data class Ui(val state: SessionUi) : Action
        /** T-096: open a candidate control connection beside the current one (its events carry [gen]). */
        data class OpenCandidate(val gen: Int, val endpoint: Endpoint) : Action
        /** T-096: send on the candidate connection (only its HELLO). */
        data class SendCandidate(val msg: Message) : Action
        /** T-096: abort the candidate connection. */
        data object CloseCandidate : Action
        /**
         * T-096: the current control connection stops being current, without BYE: no input is routed to it any more,
         * messages already queued still drain. The host closes it on our takeover proof; [CloseRetired] is the fallback.
         */
        data object RetireControl : Action
        /** T-096: the candidate (generation [gen], at [endpoint]) becomes the current control connection. */
        data class PromoteCandidate(val gen: Int, val endpoint: Endpoint) : Action
        /** T-096: close the retired connection (graceful: its queue drains first). */
        data object CloseRetired : Action
        /** T-096: outcome of one [Event.Migrate]. */
        data class MigrationResult(val endpoint: Endpoint, val ok: Boolean, val reason: String) : Action
        /** T-105: the host asked for the settings panel (SETTINGS_OPEN on an accepted session); the UI decides. */
        data object OpenSettings : Action
    }

    private enum class Phase { IDLE, CONNECTING, AWAIT_ACK, PENDING, ACCEPTED, STREAMING, WAIT_RETRY, FAILED }

    private var phase = Phase.IDLE
    private var endpoint: Endpoint? = null
    private var genCounter = 0
    private var controlGen = -1
    private var videoGen = -1
    private var videoOpen = false
    private var videoRetryAtUs = 0L

    private var hostName = ""
    private var pairingCode: String? = null
    private var rePairing = false
    private var sessionId = 0L

    /** For log correlation only. */
    val currentSessionId: Long get() = sessionId
    private var videoPort = 0
    private var config: StreamConfig? = null

    private var prefs = initialPrefs
    private var displayHz = 0 // 0 = not measured yet: nothing is sent
    private var audio: Boolean? = initialAudio
    private var pingSeq = 0L
    private var nextPingUs = 0L
    private var lastPongUs = 0L
    private var retryAtUs = 0L
    private var backoffUs = BACKOFF_START_US

    private var frames = 0L
    private var shownFrames = -1L
    private var lastUiUs = 0L

    // T-096 migration: the candidate connection (-1 = none) and the retired one waiting to be closed.
    private var candGen = -1
    private var candEndpoint: Endpoint? = null
    private var candDeadlineUs = 0L
    private var retiredGen = -1
    private var retireDeadlineUs = 0L

    /** True while a migration candidate is open. */
    val migrating: Boolean get() = candGen >= 0

    /** True once ACCEPTED was received on the current control connection: input may be sent. */
    val inputAllowed: Boolean get() = phase == Phase.ACCEPTED || phase == Phase.STREAMING

    fun handle(event: Event, nowUs: Long): List<Action> {
        val out = ArrayList<Action>()
        when (event) {
            is Event.Start -> {
                if (phase != Phase.IDLE) byeAndClose(out)
                endpoint = event.endpoint
                backoffUs = BACKOFF_START_US
                frames = 0
                openControl(out)
            }
            Event.Stop -> {
                if (phase != Phase.IDLE) {
                    byeAndClose(out)
                    phase = Phase.IDLE
                    out += Action.Ui(SessionUi.Idle)
                }
            }
            is Event.Migrate -> onMigrate(event.endpoint, nowUs, out)
            is Event.ControlOpened -> if (isCandidate(event.gen)) {
                out += Action.SendCandidate(hello)
            } else if (event.gen == controlGen && phase == Phase.CONNECTING) {
                phase = Phase.AWAIT_ACK
                lastPongUs = nowUs
                nextPingUs = nowUs + pingIntervalUs
                out += Action.Send(hello)
            }
            is Event.ControlClosed -> if (isCandidate(event.gen)) {
                abortMigration(out, if (event.connectFailed) REASON_CONNECT_FAILED else REASON_CLOSED)
            } else if (event.gen == controlGen) {
                lose(out, nowUs, if (event.connectFailed) SessionUi.Cause.CONNECT_FAILED else SessionUi.Cause.LOST)
            }
            is Event.ProtocolError -> if (isCandidate(event.gen)) {
                abortMigration(out, REASON_PROTOCOL_ERROR)
            } else if (event.gen == controlGen) {
                // No BYE: the channel is not trusted after a failed record (PROTOCOL.md section 9).
                lose(out, nowUs, SessionUi.Cause.PROTOCOL_ERROR)
            }
            is Event.Secured -> if (event.gen == controlGen) {
                pairingCode = event.code
                rePairing = event.rePairing
            }
            is Event.KeyStoreFailed -> if (isCandidate(event.gen)) {
                abortMigration(out, REASON_KEY)
            } else if (event.gen == controlGen) {
                closeAll(out, graceful = false)
                phase = Phase.FAILED
                out += Action.Ui(SessionUi.Failed(SessionUi.Cause.KEY_STORE_FAILED))
            }
            is Event.KeyMissing -> if (isCandidate(event.gen)) {
                abortMigration(out, REASON_KEY)
            } else if (event.gen == controlGen) {
                closeAll(out, graceful = false)
                phase = Phase.FAILED
                out += Action.Ui(SessionUi.Failed(SessionUi.Cause.KEY_MISSING))
            }
            is Event.Received -> if (isCandidate(event.gen)) {
                onCandidateMessage(event.msg, nowUs, out)
            } else if (event.gen == controlGen) {
                onMessage(event.msg, nowUs, out)
            }
            is Event.VideoClosed -> if (event.gen == videoGen) {
                videoOpen = false
                if (phase == Phase.STREAMING) videoRetryAtUs = nowUs + VIDEO_RETRY_US
            }
            is Event.SetPrefs -> {
                if (event.prefs != prefs) {
                    prefs = event.prefs
                    if (inputAllowed) out += Action.Send(prefs)
                }
            }
            is Event.SetDisplayRate -> {
                if (event.hz != displayHz) {
                    displayHz = event.hz
                    if (inputAllowed && displayHz > 0) out += Action.Send(DisplayRate(displayHz))
                }
            }
            is Event.SetAudio -> {
                // Only a client that does audio (non-null) ever sends AUDIO_PREFS. Sent even when unchanged (review L2):
                // the host's state is what matters, and a repeat is harmless.
                if (audio != null) {
                    audio = event.enabled
                    if (inputAllowed) out += Action.Send(AudioPrefs(event.enabled))
                }
            }
            is Event.Tick -> onTick(event.videoFrames, nowUs, out)
        }
        return out
    }

    private fun onMessage(msg: Message, nowUs: Long, out: MutableList<Action>) {
        when (msg) {
            is HelloAck -> onAck(msg, nowUs, out)
            is StreamConfig -> onConfig(msg, out)
            is Ping -> out += Action.Send(Pong(msg.seq, msg.senderTimeUs, nowUs))
            is Pong -> lastPongUs = nowUs
            // PROTOCOL.md 0x08: only an accepted session; whether the stream is visible is the UI's call.
            SettingsOpen -> if (inputAllowed) out += Action.OpenSettings
            is Bye -> {
                if (msg.reason == Bye.REJECTED) {
                    closeAll(out, graceful = false)
                    phase = Phase.FAILED
                    out += Action.Ui(SessionUi.Failed(SessionUi.Cause.REJECTED))
                } else {
                    lose(out, nowUs, SessionUi.Cause.HOST_CLOSED)
                }
            }
            else -> Unit // input/video types are not expected on this connection; ignore
        }
    }

    private fun onAck(ack: HelloAck, nowUs: Long, out: MutableList<Action>) {
        if (phase != Phase.AWAIT_ACK && phase != Phase.PENDING) return
        when (ack.status) {
            HelloAck.ACCEPTED -> {
                lastPongUs = nowUs
                pairingCode = null
                // First authenticated record: the host activates/keeps this connection only after it (PROTOCOL.md section 3).
                out += Action.Send(Ping(pingSeq++, nowUs))
                out += Action.Send(prefs) // T-050: right after the proof PING, never before it
                if (displayHz > 0) out += Action.Send(DisplayRate(displayHz)) // T-059: once, after STREAM_PREFS
                audio?.let { out += Action.Send(AudioPrefs(it)) } // T-095: after the display messages
                nextPingUs = nowUs + pingIntervalUs
                hostName = ack.hostName
                sessionId = ack.sessionId
                videoPort = ack.videoPort
                backoffUs = BACKOFF_START_US
                phase = Phase.ACCEPTED
                out += Action.Ui(SessionUi.Connected(hostName, frames))
                shownFrames = frames
                lastUiUs = nowUs
            }
            HelloAck.PENDING_APPROVAL -> {
                hostName = ack.hostName
                phase = Phase.PENDING
                lastPongUs = nowUs
                out += Action.Ui(SessionUi.AwaitingApproval(hostName, pairingCode, rePairing))
            }
            HelloAck.REJECTED, HelloAck.VERSION_MISMATCH -> {
                closeAll(out, graceful = false)
                phase = Phase.FAILED
                val cause = if (ack.status == HelloAck.REJECTED) SessionUi.Cause.REJECTED else SessionUi.Cause.VERSION_MISMATCH
                out += Action.Ui(SessionUi.Failed(cause))
            }
            HelloAck.BUSY -> {
                backoffUs = maxOf(backoffUs, BUSY_RETRY_US)
                lose(out, nowUs, SessionUi.Cause.BUSY)
            }
        }
    }

    private fun onConfig(cfg: StreamConfig, out: MutableList<Action>) {
        if (phase != Phase.ACCEPTED && phase != Phase.STREAMING) return
        // The host sends STREAM_CONFIG only after it superseded (released and closed) the old session: now ours goes too.
        closeRetired(out)
        if (phase == Phase.STREAMING && config?.configId == cfg.configId) return
        config = cfg
        phase = Phase.STREAMING
        out += Action.ApplyConfig(cfg)
        if (videoOpen || videoGen >= 0) out += Action.CloseVideo
        openVideo(out)
    }

    private fun onTick(videoFrames: Long, nowUs: Long, out: MutableList<Action>) {
        frames = videoFrames
        if (candGen >= 0 && nowUs >= candDeadlineUs) abortMigration(out, REASON_TIMEOUT)
        if (retiredGen >= 0 && nowUs >= retireDeadlineUs) closeRetired(out)
        when (phase) {
            Phase.WAIT_RETRY -> if (nowUs >= retryAtUs) openControl(out)
            Phase.AWAIT_ACK, Phase.PENDING, Phase.ACCEPTED, Phase.STREAMING -> {
                if (nowUs - lastPongUs >= PONG_TIMEOUT_US) {
                    lose(out, nowUs, SessionUi.Cause.LOST)
                    return
                }
                // Nothing but HELLO may go out before the first HELLO_ACK: encryption starts with it (section 9).
                if (phase != Phase.AWAIT_ACK && nowUs >= nextPingUs) {
                    out += Action.Send(Ping(pingSeq++, nowUs))
                    // Fixed rate (T-089): tick jitter does not stretch the interval; after a stall, no burst of pings.
                    nextPingUs += pingIntervalUs
                    if (nextPingUs <= nowUs) nextPingUs = nowUs + pingIntervalUs
                }
                if (phase == Phase.STREAMING) {
                    if (!videoOpen && nowUs >= videoRetryAtUs) openVideo(out)
                    if (frames != shownFrames && nowUs - lastUiUs >= UI_INTERVAL_US) {
                        shownFrames = frames
                        lastUiUs = nowUs
                        out += Action.Ui(SessionUi.Connected(hostName, frames))
                    }
                }
            }
            else -> Unit
        }
    }

    private fun openControl(out: MutableList<Action>) {
        val ep = endpoint ?: return
        controlGen = ++genCounter
        phase = Phase.CONNECTING
        out += Action.OpenControl(controlGen, ep)
        out += Action.Ui(SessionUi.Connecting(ep))
    }

    private fun openVideo(out: MutableList<Action>) {
        val ep = endpoint ?: return
        val cfg = config ?: return
        videoGen = ++genCounter
        videoOpen = true
        out += Action.OpenVideo(
            videoGen,
            Endpoint(ep.host, videoPort),
            VideoHello(hello.protocolVersion, cfg.configId, sessionId),
        )
    }

    /** Closes both connections (BYE already queued by the caller when graceful) and schedules a retry. */
    private fun lose(out: MutableList<Action>, nowUs: Long, cause: SessionUi.Cause, graceful: Boolean = false) {
        closeAll(out, graceful)
        phase = Phase.WAIT_RETRY
        retryAtUs = nowUs + backoffUs
        out += Action.Ui(SessionUi.Disconnected(cause, backoffUs / 1000))
        backoffUs = minOf(backoffUs * 2, BACKOFF_MAX_US)
    }

    private fun byeAndClose(out: MutableList<Action>) {
        // A BYE is an encrypted record, so it only exists once the first HELLO_ACK arrived (section 9).
        val open = phase == Phase.PENDING || phase == Phase.ACCEPTED || phase == Phase.STREAMING
        if (open) out += Action.Send(Bye(Bye.NORMAL))
        closeAll(out, graceful = open)
    }

    private fun closeAll(out: MutableList<Action>, graceful: Boolean) {
        abortMigration(out, REASON_SESSION_CLOSED)
        closeRetired(out)
        if (controlGen >= 0) {
            out += Action.CloseControl(graceful)
        }
        if (videoGen >= 0) out += Action.CloseVideo
        controlGen = -1
        resetSessionFields()
    }

    private fun resetSessionFields() {
        videoGen = -1
        videoOpen = false
        config = null
        sessionId = 0
        videoPort = 0
        pairingCode = null
        rePairing = false
    }

    // ---- T-096 migration ----

    private fun isCandidate(gen: Int) = candGen >= 0 && gen == candGen

    private fun onMigrate(target: Endpoint, nowUs: Long, out: MutableList<Action>) {
        val reason = when {
            candGen >= 0 -> REASON_IN_PROGRESS
            !inputAllowed -> REASON_NOT_CONNECTED
            target == endpoint -> REASON_SAME_ENDPOINT
            else -> null
        }
        if (reason != null) {
            out += Action.MigrationResult(target, false, reason)
            return
        }
        candGen = ++genCounter
        candEndpoint = target
        candDeadlineUs = nowUs + MIGRATE_TIMEOUT_US
        out += Action.OpenCandidate(candGen, target)
    }

    private fun onCandidateMessage(msg: Message, nowUs: Long, out: MutableList<Action>) {
        when {
            msg is HelloAck && msg.status == HelloAck.ACCEPTED -> promote(msg, nowUs, out)
            // PENDING_APPROVAL cannot be a takeover (the host answers BUSY then): never pair through a migration.
            msg is HelloAck -> abortMigration(out, "ack_${msg.status}")
            msg is Bye -> abortMigration(out, REASON_CLOSED)
            else -> Unit // nothing else is expected before ACCEPTED
        }
    }

    /** Closes the candidate (if any) and reports the failed migration; the current session is not touched. */
    private fun abortMigration(out: MutableList<Action>, reason: String) {
        val ep = candEndpoint
        if (candGen < 0 || ep == null) return
        out += Action.CloseCandidate
        out += Action.MigrationResult(ep, false, reason)
        candGen = -1
        candEndpoint = null
    }

    private fun closeRetired(out: MutableList<Action>) {
        if (retiredGen < 0) return
        out += Action.CloseRetired
        retiredGen = -1
    }

    /**
     * The candidate was ACCEPTED: it becomes the session. The old control connection is retired without a BYE (a BYE
     * that reached the host before our proof would end the session the takeover is about to supersede); the host
     * releases its input and closes it on the proof PING sent first below (PROTOCOL.md sections 3.3 and 7).
     */
    private fun promote(ack: HelloAck, nowUs: Long, out: MutableList<Action>) {
        val gen = candGen
        val ep = candEndpoint ?: return
        candGen = -1
        candEndpoint = null
        closeRetired(out) // an earlier migration's leftover, if any
        if (videoGen >= 0) out += Action.CloseVideo // the old session's frames must not reach the new stream's decoder
        if (controlGen >= 0) {
            out += Action.RetireControl
            retiredGen = controlGen
            retireDeadlineUs = nowUs + RETIRE_TIMEOUT_US
        }
        resetSessionFields()
        controlGen = gen
        endpoint = ep
        out += Action.PromoteCandidate(gen, ep)
        phase = Phase.AWAIT_ACK
        onAck(ack, nowUs, out) // proof PING first, then STREAM_PREFS / DISPLAY_RATE / AUDIO_PREFS, Ui(Connected)
        out += Action.MigrationResult(ep, true, REASON_OK)
    }

    companion object {
        const val PING_INTERVAL_US = 500_000L
        const val PONG_TIMEOUT_US = 3_000_000L
        const val BACKOFF_START_US = 1_000_000L
        const val BACKOFF_MAX_US = 5_000_000L
        const val BUSY_RETRY_US = 3_000_000L
        const val VIDEO_RETRY_US = 500_000L
        const val UI_INTERVAL_US = 250_000L
        const val MIGRATE_TIMEOUT_US = 3_000_000L
        const val RETIRE_TIMEOUT_US = 2_000_000L

        // MigrationResult reasons (log values; AutoUsbPolicy maps them to its backoff classes).
        const val REASON_OK = "ok"
        const val REASON_CONNECT_FAILED = "connect_failed"
        const val REASON_CLOSED = "closed"
        const val REASON_PROTOCOL_ERROR = "protocol_error"
        const val REASON_KEY = "key"
        const val REASON_TIMEOUT = "timeout"
        const val REASON_IN_PROGRESS = "in_progress"
        const val REASON_NOT_CONNECTED = "not_connected"
        const val REASON_SAME_ENDPOINT = "same_endpoint"
        const val REASON_SESSION_CLOSED = "session_closed"
    }
}
