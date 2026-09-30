package dev.matebridge.client.session

import dev.matebridge.client.protocol.Bye
import dev.matebridge.client.protocol.Hello
import dev.matebridge.client.protocol.HelloAck
import dev.matebridge.client.protocol.Message
import dev.matebridge.client.protocol.Ping
import dev.matebridge.client.protocol.Pong
import dev.matebridge.client.protocol.StreamConfig
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
 */
class SessionMachine(private val hello: Hello) {
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
        /** Video connection closed or failed to open. */
        data class VideoClosed(val gen: Int) : Event
        /** Periodic; [videoFrames] is the running count of frames received on video connections. */
        data class Tick(val videoFrames: Long) : Event
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

    private var pingSeq = 0L
    private var nextPingUs = 0L
    private var lastPongUs = 0L
    private var retryAtUs = 0L
    private var backoffUs = BACKOFF_START_US

    private var frames = 0L
    private var shownFrames = -1L
    private var lastUiUs = 0L

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
            is Event.ControlOpened -> if (event.gen == controlGen && phase == Phase.CONNECTING) {
                phase = Phase.AWAIT_ACK
                lastPongUs = nowUs
                nextPingUs = nowUs + PING_INTERVAL_US
                out += Action.Send(hello)
            }
            is Event.ControlClosed -> if (event.gen == controlGen) {
                lose(out, nowUs, if (event.connectFailed) SessionUi.Cause.CONNECT_FAILED else SessionUi.Cause.LOST)
            }
            is Event.ProtocolError -> if (event.gen == controlGen) {
                // No BYE: the channel is not trusted after a failed record (PROTOCOL.md section 9).
                lose(out, nowUs, SessionUi.Cause.PROTOCOL_ERROR)
            }
            is Event.Secured -> if (event.gen == controlGen) {
                pairingCode = event.code
                rePairing = event.rePairing
            }
            is Event.KeyStoreFailed -> if (event.gen == controlGen) {
                closeAll(out, graceful = false)
                phase = Phase.FAILED
                out += Action.Ui(SessionUi.Failed(SessionUi.Cause.KEY_STORE_FAILED))
            }
            is Event.KeyMissing -> if (event.gen == controlGen) {
                closeAll(out, graceful = false)
                phase = Phase.FAILED
                out += Action.Ui(SessionUi.Failed(SessionUi.Cause.KEY_MISSING))
            }
            is Event.Received -> if (event.gen == controlGen) onMessage(event.msg, nowUs, out)
            is Event.VideoClosed -> if (event.gen == videoGen) {
                videoOpen = false
                if (phase == Phase.STREAMING) videoRetryAtUs = nowUs + VIDEO_RETRY_US
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
                nextPingUs = nowUs + PING_INTERVAL_US
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
        if (phase == Phase.STREAMING && config?.configId == cfg.configId) return
        config = cfg
        phase = Phase.STREAMING
        out += Action.ApplyConfig(cfg)
        if (videoOpen || videoGen >= 0) out += Action.CloseVideo
        openVideo(out)
    }

    private fun onTick(videoFrames: Long, nowUs: Long, out: MutableList<Action>) {
        frames = videoFrames
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
                    nextPingUs = nowUs + PING_INTERVAL_US
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
        if (controlGen >= 0) {
            out += Action.CloseControl(graceful)
        }
        if (videoGen >= 0) out += Action.CloseVideo
        controlGen = -1
        videoGen = -1
        videoOpen = false
        config = null
        sessionId = 0
        videoPort = 0
        pairingCode = null
        rePairing = false
    }

    companion object {
        const val PING_INTERVAL_US = 500_000L
        const val PONG_TIMEOUT_US = 3_000_000L
        const val BACKOFF_START_US = 1_000_000L
        const val BACKOFF_MAX_US = 5_000_000L
        const val BUSY_RETRY_US = 3_000_000L
        const val VIDEO_RETRY_US = 500_000L
        const val UI_INTERVAL_US = 250_000L
    }
}
