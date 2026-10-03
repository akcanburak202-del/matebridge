package dev.matebridge.client.session

import dev.matebridge.client.protocol.AudioPrefs
import dev.matebridge.client.protocol.Bye
import dev.matebridge.client.protocol.Bytes
import dev.matebridge.client.protocol.Clipboard
import dev.matebridge.client.protocol.DisplayRate
import dev.matebridge.client.protocol.FilesInfo
import dev.matebridge.client.protocol.Hello
import dev.matebridge.client.protocol.HelloAck
import dev.matebridge.client.protocol.Message
import dev.matebridge.client.protocol.Ping
import dev.matebridge.client.protocol.Pong
import dev.matebridge.client.protocol.SettingsOpen
import dev.matebridge.client.protocol.StreamConfig
import dev.matebridge.client.protocol.StreamPrefs
import dev.matebridge.client.security.PairTrust
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
 * Migration (T-096, T-205): [Event.Migrate] moves an accepted session to another endpoint (Wi-Fi -> USB)
 * make-before-break, through the host's same-device takeover (PROTOCOL.md section 3.3). A *candidate* control connection
 * is opened next to the current one and sends its own HELLO. Its plaintext ACCEPTED (PAIRED) ack proves nothing (any app
 * holding the loopback port can send one with the real host_id), so the candidate then sends the proof PING **on itself**
 * and waits (`migration_proof_wait`) while the current session stays current and keeps carrying input. Only the
 * candidate's first host record that decrypts and authenticates (the reader delivers nothing else) promotes it: the old
 * video closes, the old control connection is *retired* (no BYE, no more input routed to it, already queued messages
 * still drain), the remembered settings follow the proof PING on the new one, and that first record (normally the new
 * STREAM_CONFIG) is handled as the new session's. The host supersedes the old session (releases its input, BYE(SUPERSEDED),
 * close) on our proof, so that BYE and close (or the old heartbeat expiring) may come while the proof is pending: they do
 * not end the session, the candidate's outcome decides (if it fails then, the session is lost and reconnects). The retired connection is closed on
 * the new STREAM_CONFIG (or after [RETIRE_TIMEOUT_US]). A candidate that fails in any way is closed alone: the current
 * session is never touched while it lives. Every Migrate yields exactly one [Action.MigrationResult].
 *
 * Local trust (T-150, decision 0018): a session is accepted only when the host accepted it **and** its key is locally
 * trusted. A PAIRED first ack derives with the trusted key, so it is both at once. A PAIRING session keeps its new key
 * pending ([PairTrust]) until the user confirms the code ([Event.TrustConfirmed]); until then only PING goes out, the UI
 * is `AwaitingApproval(needsLocalConfirm = true)`, a STREAM_CONFIG is buffered, and nothing inbound (clipboard, settings,
 * audio through [acceptedGen]) is delivered. A start the user did not make ([Event.Start.userInitiated] false) opens no
 * connection while an unresolved pairing exists: it shows [SessionUi.StoredTrust] instead. The confirmation prompt times
 * out after [CONFIRM_TIMEOUT_US] of *visible* time ([Event.ConfirmPromptVisible]).
 *
 * Key mismatch (T-156): a PAIRED connection that ends after its proof PING and before any host record authenticated
 * (the first record fails AEAD, or a T-152 host closes without BYE) counts against its endpoint. Below
 * [KEY_MISMATCH_LIMIT] it retries as before; at the limit it ends in terminal `Failed(KEY_MISMATCH)`, and an automatic
 * start to that endpoint opens nothing until a user start, a Stop or a forget clears the counts. An authenticated record
 * resets its endpoint's count; so does one the reader authenticated whose event has not arrived ([recordAuthenticated]).
 */
class SessionMachine(
    private val hello: Hello,
    initialPrefs: StreamPrefs = StreamMode.DEFAULT.toPrefs(),
    private val pingIntervalUs: Long = PING_INTERVAL_US, // T-089 knob (--ei ping_ms N); the PONG timeout is unchanged
    initialAudio: Boolean? = null, // T-095: AUDIO_PREFS wish; null = this client does not do audio (nothing is sent)
    initialFiles: FilesInfo? = null, // T-135: file server state; null = this client has no file server (nothing is sent)
    /** T-150: pending/trusted pair keys; null = no store (a pairing can then not be confirmed: KEY_STORE_FAILED). */
    private val trust: PairTrust? = null,
    /**
     * T-156: whether the reader of control connection `gen` has authenticated at least one host record (any type: also
     * audio, which bypasses the machine, and unknown types the decoder skips). Set by the reader *before* it enqueues the
     * record, read at the moment a failure would count, so a close that overtakes the record's event cannot count.
     */
    private val recordAuthenticated: (Int) -> Boolean = { false },
    /** T-150: log sink (level, ev, fields) for the trust lines; never given a code, key, host_id or host name. */
    private val log: (Char, String, String) -> Unit = { _, _, _ -> },
) {
    sealed interface Event {
        /**
         * [wake] non-null (T-134): a direct wake attempt (see [WakeTag]). If its TCP connect fails there is no retry
         * timer (the wake planner paces the attempts): the machine goes idle with `Ui(Disconnected(CONNECT_FAILED, 0))`.
         * Once the connection opens it is an ordinary session (normal retries).
         */
        data class Start(val endpoint: Endpoint, val wake: WakeTag? = null, val userInitiated: Boolean = false) : Event
        data object Stop : Event
        data class ControlOpened(val gen: Int) : Event
        /** Control connection failed to open, hit EOF/IO error, or its send queue overflowed. */
        data class ControlClosed(val gen: Int, val connectFailed: Boolean = false) : Event
        data class Received(val gen: Int, val msg: Message) : Event
        /** [authFailed] (T-156): the reader's error was `ProtocolException.Kind.AUTH_FAILED` (a record did not authenticate). */
        data class ProtocolError(val gen: Int, val authFailed: Boolean = false) : Event
        /**
         * The first HELLO_ACK was encrypted and valid. [code] is the pairing code (PAIRING only); [hostId] the ack's
         * host_id (T-150). [pendingKey] (PAIRING only): the new key, stored pending by the machine only while [gen] is the
         * current connection, so a stale reader never writes (review #2); zeroed after use, never logged. Comes before
         * the ack itself.
         */
        data class Secured(
            val gen: Int,
            val code: String?,
            val rePairing: Boolean,
            val hostId: Bytes? = null,
            val pendingKey: Bytes? = null,
        ) : Event
        /** T-150: PAIRING answer on a connection the user did not start; the reader closed it, nothing was stored. */
        data class PairingNeedsUser(val gen: Int, val hostName: String, val rePair: Boolean) : Event
        /** T-150: PAIRED answer while [hostId] has a fresh unconfirmed pending key; nothing was derived, the reader closed it. */
        data class PairedWithPending(val gen: Int, val hostId: Bytes) : Event
        /** T-150: the user confirmed the code of prompt [gen] ([confirmPromptGen]). */
        data class TrustConfirmed(val gen: Int) : Event
        /** T-150: the user cancelled prompt [gen]. */
        data class TrustCancelled(val gen: Int) : Event
        /** T-150: whether a confirmation prompt is visible in the foreground; only visible time counts toward the timeout. */
        data class ConfirmPromptVisible(val visible: Boolean) : Event
        /** T-150: "Bu Mac'i unut" for [forgettableHost]: a live session ends first (BYE + close), then the records go. */
        data object ForgetHost : Event
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
        /** T-135: the tablet file server's state: remembered, sent as FILES_INFO now when input is allowed and it changed. */
        data class SetFiles(val info: FilesInfo) : Event
        /** Video connection closed or failed to open. */
        data class VideoClosed(val gen: Int) : Event
        /** Periodic; [videoFrames] is the running count of frames received on video connections. */
        data class Tick(val videoFrames: Long) : Event
        /** T-096: move the accepted session to [endpoint] via takeover (make-before-break); see the class comment. */
        data class Migrate(val endpoint: Endpoint) : Event
        /**
         * T-105: the user picked a connection mode the running migration no longer fits: close the candidate (failed
         * [Action.MigrationResult], reason `cancelled`). No-op without a candidate, also after it was promoted.
         */
        data object CancelMigration : Event
    }

    sealed interface Action {
        /** [wake] non-null (T-134): a direct wake attempt (Wi-Fi-bound socket, short connect timeout, logged). */
        data class OpenControl(val gen: Int, val endpoint: Endpoint, val wake: WakeTag? = null, val userInitiated: Boolean = false) : Action
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
        /** T-096: send on the candidate connection (its HELLO, then T-205's proof PING). */
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
        /** T-150: a CLIPBOARD arrived on the accepted (and locally trusted) control connection [gen]. Never log its data. */
        data class DeliverClipboard(val msg: Clipboard, val gen: Int) : Action
    }

    /**
     * HOST_ACCEPTED_UNTRUSTED: the host sent a sealed ACCEPTED for a PAIRING session the user has not confirmed yet.
     * STORED_PROMPT: no connection; an unresolved pairing is shown ([SessionUi.StoredTrust]) and waits for the user.
     */
    private enum class Phase {
        IDLE, CONNECTING, AWAIT_ACK, PENDING, HOST_ACCEPTED_UNTRUSTED, ACCEPTED, STREAMING, WAIT_RETRY, FAILED, STORED_PROMPT,
    }

    private var phase = Phase.IDLE
    private var endpoint: Endpoint? = null
    /** T-134: the wake attempt the current control connection is (null = none); cleared once it opens. */
    private var wakeAttempt: WakeTag? = null
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
    private var files: FilesInfo? = initialFiles
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
    /** T-205: the candidate's plaintext ACCEPTED ack (non-null = its proof PING went out; waiting for its first record). */
    private var candAck: HelloAck? = null
    /** T-205: host_id of the candidate's handshake (from its Secured event); must be the current session's. */
    private var candHostId: ByteArray? = null
    /**
     * T-205: while the proof is pending, the host already superseded (BYE(SUPERSEDED)) or closed the current connection.
     * Nothing is sent or retried on it any more; the candidate's outcome decides (a failure then loses the session).
     */
    private var oldGone = false
    /**
     * T-205 review: while the proof is pending, the current connection's heartbeat expired (provisional: a valid PONG on
     * it clears this). Treated like [oldGone] until then: nothing sent or retried on it, a candidate failure loses.
     */
    private var oldStale = false
    private var retiredGen = -1
    private var retireDeadlineUs = 0L

    /** True while a migration candidate is open. */
    val migrating: Boolean get() = candGen >= 0

    // T-150 local trust of the current start / connection.
    /** The current start (and its automatic retries) was made by the user: a PAIRING answer may be stored pending. */
    private var userInitiated = false
    private var pairingSession = false
    private var locallyTrusted = false
    private var sessionHostId: ByteArray? = null
    private var sealedSeen = false
    private var bufferedConfig: StreamConfig? = null
    /** host_id that "Bu Mac'i unut" may remove: last PAIRED ack, last locally trusted session, or the stored prompt. */
    private var knownHostId: ByteArray? = null

    // T-150 confirmation prompt (live AwaitingApproval(needsLocalConfirm) or StoredTrust); -1 = none.
    private var promptGen = -1
    private var promptHostId: ByteArray? = null
    private var promptCode: String? = null
    /** Fingerprint of the pending record whose code the prompt shows; a confirmation promotes only that record. */
    private var promptFingerprint: ByteArray? = null
    /** Fingerprint of the pending record this connection stored. */
    private var sessionPendingFp: ByteArray? = null
    /**
     * Review #3: set by a cancel/timeout; an automatic start does nothing (`Failed(PAIR_CANCELLED)` again) until a
     * user-initiated start or a forget clears it, so a cancelled key the Mac already approved cannot loop.
     */
    private var cancelLatched = false
    private var promptVisible = false
    private var promptVisibleUs = 0L
    private var promptLastUs = 0L

    /** T-156: consecutive PAIRED connections per endpoint that ended before any host record authenticated. */
    private val authFailures = HashMap<Endpoint, Int>()

    /**
     * True once the current control connection is accepted by the host **and** locally trusted (T-150): input may be
     * sent and inbound clipboard/settings/audio delivered.
     */
    val inputAllowed: Boolean get() = phase == Phase.ACCEPTED || phase == Phase.STREAMING

    /** T-150: the control generation whose inbound audio may be delivered (-1: none). */
    val acceptedGen: Int get() = if (inputAllowed) controlGen else -1

    /** T-150: generation of the confirmation prompt on screen (for [Event.TrustConfirmed]/[Event.TrustCancelled]); -1 = none. */
    val confirmPromptGen: Int get() = promptGen

    /** T-150: whether [Event.ForgetHost] has a host_id to forget (never one taken only from an aborted PAIRING answer). */
    val forgettableHost: Boolean get() = knownHostId != null

    fun handle(event: Event, nowUs: Long): List<Action> {
        val out = ArrayList<Action>()
        when (event) {
            is Event.Start -> {
                if (phase != Phase.IDLE) byeAndClose(out)
                clearPrompt()
                if (event.userInitiated) {
                    cancelLatched = false
                    authFailures.clear() // T-156: the user tries again
                } else if (cancelLatched) {
                    wakeAttempt = null
                    userInitiated = false
                    phase = Phase.FAILED
                    log('I', "pair_cancel_latched", "")
                    out += Action.Ui(SessionUi.Failed(SessionUi.Cause.PAIR_CANCELLED))
                    return out
                } else if ((authFailures[event.endpoint] ?: 0) >= KEY_MISMATCH_LIMIT) {
                    // T-156: no automatic connect to an endpoint whose key did not match; only the user starts it again.
                    wakeAttempt = null
                    userInitiated = false
                    phase = Phase.FAILED
                    log('I', "key_mismatch_latched", "")
                    out += Action.Ui(SessionUi.Failed(SessionUi.Cause.KEY_MISMATCH))
                    return out
                }
                endpoint = event.endpoint
                backoffUs = BACKOFF_START_US
                frames = 0
                wakeAttempt = event.wake
                userInitiated = event.userInitiated
                // T-150: an automatic start never touches an unresolved pairing (it would replace the Mac's pending code).
                val stored = if (event.userInitiated) null else storedPrompt()
                if (stored != null) showStoredPrompt(stored, nowUs, out) else openControl(out)
            }
            Event.Stop -> {
                wakeAttempt = null
                userInitiated = false
                authFailures.clear() // T-156
                clearPrompt()
                if (phase != Phase.IDLE) {
                    byeAndClose(out)
                    phase = Phase.IDLE
                    out += Action.Ui(SessionUi.Idle)
                }
            }
            is Event.Migrate -> onMigrate(event.endpoint, nowUs, out)
            Event.CancelMigration -> failCandidate(out, nowUs, REASON_CANCELLED) // no candidate (none, or promoted): nothing
            is Event.ControlOpened -> if (isCandidate(event.gen)) {
                out += Action.SendCandidate(hello)
            } else if (event.gen == controlGen && phase == Phase.CONNECTING) {
                wakeAttempt = null // the host answered the connect: from here an ordinary session (normal retries)
                phase = Phase.AWAIT_ACK
                lastPongUs = nowUs
                nextPingUs = nowUs + pingIntervalUs
                out += Action.Send(hello)
            }
            is Event.ControlClosed -> if (isCandidate(event.gen)) {
                val reason = when {
                    candAck != null -> REASON_PROOF_CLOSED
                    event.connectFailed -> REASON_CONNECT_FAILED
                    else -> REASON_CLOSED
                }
                failCandidate(out, nowUs, reason)
            } else if (event.gen == controlGen) {
                if (candAck != null) {
                    oldConnectionGone("closed") // T-205: the host's takeover may close it before the candidate's record
                } else if (wakeAttempt != null) {
                    // T-134: a wake attempt that did not connect has no retry timer; the wake planner paces attempts.
                    wakeAttempt = null
                    closeAll(out, graceful = false)
                    phase = Phase.IDLE
                    out += Action.Ui(SessionUi.Disconnected(SessionUi.Cause.CONNECT_FAILED, 0))
                } else if (!event.connectFailed && unauthenticatedPairedEnd()) {
                    pairedAuthFailure(out, nowUs, "closed", SessionUi.Cause.LOST) // T-156 (b): a T-152 host on a wrong key
                } else {
                    lose(out, nowUs, if (event.connectFailed) SessionUi.Cause.CONNECT_FAILED else SessionUi.Cause.LOST)
                }
            }
            is Event.ProtocolError -> if (isCandidate(event.gen)) {
                // T-205: after the proof PING this is the candidate's first record failing to authenticate (a squatter).
                failCandidate(out, nowUs, if (candAck != null) REASON_PROOF_FAILED else REASON_PROTOCOL_ERROR)
            } else if (event.gen == controlGen) {
                // No BYE: the channel is not trusted after a failed record (PROTOCOL.md section 9).
                if (unauthenticatedPairedEnd() && event.authFailed) {
                    pairedAuthFailure(out, nowUs, "auth_failed", SessionUi.Cause.PROTOCOL_ERROR) // T-156 (a)
                } else {
                    lose(out, nowUs, SessionUi.Cause.PROTOCOL_ERROR)
                }
            }
            is Event.Secured -> if (event.gen == controlGen) {
                onSecured(event, out)
            } else {
                event.pendingKey?.value?.fill(0) // a stale reader (stopped or superseded connection) never writes
                if (isCandidate(event.gen)) onCandidateSecured(event, nowUs, out) // T-205: never stores or pends a key
            }
            is Event.PairingNeedsUser -> if (isCandidate(event.gen)) {
                failCandidate(out, nowUs, REASON_KEY) // a migration never pairs
            } else if (event.gen == controlGen) {
                closeAll(out, graceful = false)
                phase = Phase.FAILED // no retry: each one would raise a new approval dialog on the Mac
                log('I', "pairing_needs_user", "re_pair=${flag(event.rePair)}")
                out += Action.Ui(SessionUi.PairingNeedsUser(event.hostName, event.rePair))
            }
            is Event.PairedWithPending -> if (isCandidate(event.gen)) {
                failCandidate(out, nowUs, REASON_KEY)
            } else if (event.gen == controlGen) {
                closeAll(out, graceful = false)
                val pending = try { trust?.freshPending(event.hostId.value) } catch (e: Exception) { null }
                if (pending == null) {
                    lose(out, nowUs, SessionUi.Cause.PROTOCOL_ERROR) // gone meanwhile: the next attempt derives normally
                } else {
                    val fp = pending.fingerprint()
                    pending.key.fill(0)
                    showStoredPrompt(
                        PairTrust.StoredPrompt(event.hostId.value.copyOf(), pending.sas, pending.createdAtWallMs, fp), nowUs, out,
                    )
                }
            }
            is Event.TrustConfirmed -> if (promptGen >= 0 && event.gen == promptGen) {
                onTrustConfirmed(nowUs, out)
            } else {
                log('W', "pair_trust_event_stale", "kind=confirm")
            }
            is Event.TrustCancelled -> if (promptGen >= 0 && event.gen == promptGen) {
                cancelPrompt(REASON_USER, out)
            } else {
                log('W', "pair_trust_event_stale", "kind=cancel")
            }
            is Event.ConfirmPromptVisible -> {
                if (event.visible && !promptVisible) promptLastUs = nowUs
                if (!event.visible && promptVisible && promptGen >= 0) promptVisibleUs += nowUs - promptLastUs
                promptVisible = event.visible
            }
            Event.ForgetHost -> onForget(out)
            is Event.KeyStoreFailed -> if (isCandidate(event.gen)) {
                failCandidate(out, nowUs, REASON_KEY)
            } else if (event.gen == controlGen) {
                closeAll(out, graceful = false)
                phase = Phase.FAILED
                out += Action.Ui(SessionUi.Failed(SessionUi.Cause.KEY_STORE_FAILED))
            }
            is Event.KeyMissing -> if (isCandidate(event.gen)) {
                failCandidate(out, nowUs, REASON_KEY)
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
            is Event.SetFiles -> {
                // Only a client with a file server (non-null) sends FILES_INFO (PROTOCOL.md 0x09): once per session, then on change.
                if (files != null && event.info != files) {
                    files = event.info
                    if (inputAllowed) out += Action.Send(event.info)
                }
            }
            is Event.Tick -> onTick(event.videoFrames, nowUs, out)
        }
        return out
    }

    private fun onMessage(msg: Message, nowUs: Long, out: MutableList<Action>) {
        // Everything but the first (plaintext) HELLO_ACK is a sealed record. In a PAIRED session the first one proves that
        // the host holds our trusted key, i.e. it accepted it: the awaiting-host marker of that host_id is cleared (T-150).
        if (!sealedSeen && !(msg is HelloAck && phase == Phase.AWAIT_ACK)) {
            sealedSeen = true
            if (!pairingSession) sessionHostId?.let { clearMarkerOf(it) }
            endpoint?.let { authFailures.remove(it) } // T-156: the host holds our key on this endpoint
        }
        when (msg) {
            is HelloAck -> onAck(msg, nowUs, out)
            is StreamConfig -> onConfig(msg, out)
            is Ping -> out += Action.Send(Pong(msg.seq, msg.senderTimeUs, nowUs))
            is Pong -> {
                lastPongUs = nowUs
                if (oldStale && !oldGone) {
                    // T-205: the current connection answered again: a later candidate failure keeps it, pings resume.
                    oldStale = false
                    log('I', "migration_old_recovered", "")
                }
            }
            // PROTOCOL.md 0x08: only an accepted session; whether the stream is visible is the UI's call.
            SettingsOpen -> if (inputAllowed) out += Action.OpenSettings
            is Clipboard -> if (inputAllowed) out += Action.DeliverClipboard(msg, controlGen) // T-150: never before local trust
            is Bye -> {
                if (msg.reason == Bye.SUPERSEDED && candAck != null) {
                    oldConnectionGone("bye") // T-205: the host took over for our candidate's proof; it decides now
                    return
                }
                if (msg.reason == Bye.REJECTED) onPairingRejected()
                if (msg.reason == Bye.REJECTED || msg.reason == Bye.HOST_SLEEP) {
                    // HOST_SLEEP (T-133): every packet to a sleeping Mac dark-wakes it, so no retry timer either.
                    closeAll(out, graceful = false)
                    phase = Phase.FAILED
                    val cause = if (msg.reason == Bye.REJECTED) SessionUi.Cause.REJECTED else SessionUi.Cause.HOST_SLEEP
                    out += Action.Ui(SessionUi.Failed(cause))
                } else {
                    lose(out, nowUs, SessionUi.Cause.HOST_CLOSED)
                }
            }
            else -> Unit // input/video types are not expected on this connection; ignore
        }
    }

    private fun onAck(ack: HelloAck, nowUs: Long, out: MutableList<Action>) {
        if (phase != Phase.AWAIT_ACK && phase != Phase.PENDING && phase != Phase.HOST_ACCEPTED_UNTRUSTED) return
        when (ack.status) {
            HelloAck.ACCEPTED -> when (phase) {
                // First ack ACCEPTED = PAIRED: derived with the trusted key, so it is locally trusted too.
                Phase.AWAIT_ACK -> {
                    locallyTrusted = true
                    takeAck(ack)
                    acceptSession(nowUs, out)
                }
                // Sealed ACCEPTED of a PAIRING session: the Mac approved; the tablet user may not have confirmed yet.
                Phase.PENDING -> {
                    takeAck(ack)
                    if (locallyTrusted) {
                        sessionHostId?.let { clearMarkerOf(it) } // confirmed before: the host has now accepted that key
                        acceptSession(nowUs, out)
                    } else {
                        phase = Phase.HOST_ACCEPTED_UNTRUSTED // only PING goes out until the user confirms
                        lastPongUs = nowUs
                        out += Action.Ui(
                            SessionUi.AwaitingApproval(hostName, pairingCode, rePairing, needsLocalConfirm = true, promptGen = promptGen),
                        )
                    }
                }
                else -> Unit // a repeated ACCEPTED changes nothing
            }
            HelloAck.PENDING_APPROVAL -> if (phase == Phase.AWAIT_ACK) {
                hostName = ack.hostName
                phase = Phase.PENDING
                pairingSession = true
                locallyTrusted = false
                lastPongUs = nowUs
                showPrompt(controlGen, sessionHostId, pairingCode, sessionPendingFp, nowUs)
                out += Action.Ui(
                    SessionUi.AwaitingApproval(hostName, pairingCode, rePairing, needsLocalConfirm = true, promptGen = promptGen),
                )
            }
            HelloAck.REJECTED, HelloAck.VERSION_MISMATCH -> {
                if (ack.status == HelloAck.REJECTED) onPairingRejected()
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

    private fun takeAck(ack: HelloAck) {
        hostName = ack.hostName
        sessionId = ack.sessionId
        videoPort = ack.videoPort
    }

    /**
     * Host accepted and locally trusted: the session opens (proof PING first, then the remembered settings). [proofSent]
     * (T-205 promotion): the proof PING already went out on this connection, so the settings follow it directly.
     */
    private fun acceptSession(nowUs: Long, out: MutableList<Action>, proofSent: Boolean = false) {
        lastPongUs = nowUs
        pairingCode = null
        // First authenticated record: the host activates/keeps this connection only after it (PROTOCOL.md section 3).
        if (!proofSent) out += Action.Send(Ping(pingSeq++, nowUs))
        out += Action.Send(prefs) // T-050: right after the proof PING, never before it
        if (displayHz > 0) out += Action.Send(DisplayRate(displayHz)) // T-059: once, after STREAM_PREFS
        audio?.let { out += Action.Send(AudioPrefs(it)) } // T-095: after the display messages
        files?.let { out += Action.Send(it) } // T-135: once per session, after AUDIO_PREFS
        nextPingUs = nowUs + pingIntervalUs
        backoffUs = BACKOFF_START_US
        userInitiated = false
        clearPrompt()
        sessionHostId?.let { knownHostId = it }
        phase = Phase.ACCEPTED
        out += Action.Ui(SessionUi.Connected(hostName, frames))
        shownFrames = frames
        lastUiUs = nowUs
        // T-150: a STREAM_CONFIG that arrived while waiting for the local confirmation opens video now.
        bufferedConfig?.let {
            bufferedConfig = null
            onConfig(it, out)
        }
    }

    // ---- T-150 local trust ----

    private fun flag(b: Boolean) = if (b) 1 else 0

    private fun storedPrompt(): PairTrust.StoredPrompt? = try {
        trust?.storedPrompt()
    } catch (e: Exception) {
        null // an unreadable store blocks nothing; the handshake still decides per host_id
    }

    /** PAIRING Secured on the current connection: store the new key pending (engine thread, gen-checked: review #2). */
    private fun onSecured(event: Event.Secured, out: MutableList<Action>) {
        pairingCode = event.code
        rePairing = event.rePairing
        sessionHostId = event.hostId?.value?.copyOf()
        if (event.code == null) {
            event.pendingKey?.value?.fill(0)
            if (sessionHostId != null) knownHostId = sessionHostId // PAIRED: derived with our trusted key for this host_id
            return
        }
        pairingSession = true
        val key = event.pendingKey?.value ?: return // no key handed over (tests of the UI path only): nothing stored
        val hostId = sessionHostId
        val stored = try {
            // Only a user-initiated start pairs (the handshake already aborts otherwise; this is the second lock).
            if (userInitiated && hostId != null && trust != null) {
                trust.storePending(hostId, key, event.code)
                sessionPendingFp = dev.matebridge.client.security.PendingRecord.fingerprint(key, event.code)
                true
            } else {
                false
            }
        } catch (e: Exception) {
            false
        } finally {
            key.fill(0)
        }
        if (!stored) {
            // Not persisted (or not allowed): fail instead of pretending; the key is never logged.
            log('W', "pair_key_store_failed", "")
            closeAll(out, graceful = false)
            phase = Phase.FAILED
            out += Action.Ui(SessionUi.Failed(SessionUi.Cause.KEY_STORE_FAILED))
            return
        }
        log('I', "pair_pending_stored", "re_pair=${flag(event.rePairing)}")
    }

    private fun showPrompt(gen: Int, hostId: ByteArray?, code: String?, fingerprint: ByteArray?, nowUs: Long) {
        promptGen = gen
        promptHostId = hostId
        promptCode = code
        promptFingerprint = fingerprint
        promptVisibleUs = 0
        promptLastUs = nowUs
    }

    private fun clearPrompt() {
        promptGen = -1
        promptHostId = null
        promptCode = null
        promptFingerprint = null
        promptVisibleUs = 0
    }

    /** No connection: show the unresolved pairing and wait for the user (a confirm then connects, user-initiated). */
    private fun showStoredPrompt(sp: PairTrust.StoredPrompt, nowUs: Long, out: MutableList<Action>) {
        wakeAttempt = null
        phase = Phase.STORED_PROMPT
        knownHostId = sp.hostId
        showPrompt(++genCounter, sp.hostId, sp.code, sp.fingerprint, nowUs)
        log('I', "pair_stored_prompt", "confirmed=${flag(sp.code == null)}")
        out += Action.Ui(SessionUi.StoredTrust(sp.code, confirmed = sp.code == null, promptGen = promptGen))
    }

    private fun onTrustConfirmed(nowUs: Long, out: MutableList<Action>) {
        when (phase) {
            Phase.PENDING -> {
                val h = sessionHostId
                if (!promote(h, awaitHost = true, out)) return
                locallyTrusted = true
                knownHostId = h
                clearPrompt()
                log('I', "pair_trust_confirmed", "where=live host_accepted=0")
                out += Action.Ui(SessionUi.AwaitingApproval(hostName, pairingCode, rePairing, needsLocalConfirm = false))
            }
            Phase.HOST_ACCEPTED_UNTRUSTED -> {
                if (!promote(sessionHostId, awaitHost = false, out)) return
                locallyTrusted = true
                log('I', "pair_trust_confirmed", "where=live host_accepted=1")
                acceptSession(nowUs, out)
            }
            Phase.STORED_PROMPT -> {
                // A pending key is promoted (the Mac's acceptance is unknown: marker); a marker-only prompt just connects.
                if (promptCode != null && !promote(promptHostId, awaitHost = true, out)) return
                log('I', "pair_trust_confirmed", "where=stored")
                clearPrompt()
                userInitiated = true
                openControl(out)
            }
            else -> Unit
        }
    }

    /**
     * Promotes the pending key of [hostId], only if it is still the record whose code the prompt shows (review #2).
     * A commit failure fails the session with KEY_STORE_FAILED (nothing half-written); a different or missing record
     * ends it like a cancel (`reason=stale`): the user never confirmed that key.
     */
    private fun promote(hostId: ByteArray?, awaitHost: Boolean, out: MutableList<Action>): Boolean {
        val fp = promptFingerprint
        val ok = try {
            hostId != null && fp != null && trust != null && trust.promote(hostId, awaitHost, fp)
        } catch (e: Exception) {
            log('W', "pair_trust_confirm_failed", "")
            byeAndClose(out)
            phase = Phase.FAILED
            userInitiated = false
            clearPrompt()
            out += Action.Ui(SessionUi.Failed(SessionUi.Cause.KEY_STORE_FAILED))
            return false
        }
        if (!ok) cancelPrompt(REASON_STALE, out)
        return ok
    }

    /** Cancel or timeout: BYE + close a live connection, drop the pending key (trusted untouched), terminal PAIR_CANCELLED. */
    private fun cancelPrompt(reason: String, out: MutableList<Action>) {
        val live = phase == Phase.PENDING || phase == Phase.HOST_ACCEPTED_UNTRUSTED
        val hostId = if (live) sessionHostId else promptHostId
        val pending = live || promptCode != null
        if (live) byeAndClose(out)
        try {
            if (hostId != null) {
                if (pending) trust?.dropPending(hostId) else trust?.clearMarker(hostId)
            }
        } catch (e: Exception) {
            log('W', "pair_pending_drop_failed", "")
        }
        phase = Phase.FAILED
        userInitiated = false
        cancelLatched = true
        clearPrompt()
        log('I', "pair_trust_cancelled", "reason=$reason")
        out += Action.Ui(SessionUi.Failed(SessionUi.Cause.PAIR_CANCELLED))
    }

    /** REJECTED: before a local confirm the pending key goes; after it the promoted key stays and the marker goes. */
    private fun onPairingRejected() {
        if (!pairingSession) return
        val h = sessionHostId ?: return
        try {
            if (locallyTrusted) trust?.clearMarker(h) else trust?.dropPending(h)
        } catch (e: Exception) {
            log('W', "pair_pending_drop_failed", "")
        }
        log('I', "pair_rejected", "confirmed=${flag(locallyTrusted)}")
    }

    private fun clearMarkerOf(hostId: ByteArray) {
        try {
            trust?.clearMarker(hostId)
        } catch (e: Exception) {
            log('W', "pair_marker_clear_failed", "")
        }
    }

    /** Trust is never revoked on an open connection: a live session ends like Stop (BYE + close) before the records go. */
    private fun onForget(out: MutableList<Action>) {
        authFailures.clear() // T-156: the user acted on the mismatch; automatic connects may run again
        val h = knownHostId
        if (h == null) {
            cancelLatched = false // the user dealt with the Mac: automatic connects may run again
            log('I', "pair_forget_none", "")
            return
        }
        val live = controlGen >= 0
        val wasIdle = phase == Phase.IDLE
        if (!wasIdle) byeAndClose(out) // BYE + close first in every case: the host releases all input
        wakeAttempt = null
        userInitiated = false
        clearPrompt()
        val removed = try {
            trust?.forget(h)
            trust != null
        } catch (e: Exception) {
            false
        }
        if (!removed) {
            // Review: the removal did not persist, so the Mac is still trusted after a restart. Never report success:
            // keep its identity (the user can retry) and the cancel latch, and show KEY_STORE_FAILED.
            phase = Phase.FAILED
            log('W', "pair_forget_failed", "live=${flag(live)}")
            out += Action.Ui(SessionUi.Failed(SessionUi.Cause.KEY_STORE_FAILED))
            return
        }
        phase = Phase.IDLE
        if (!wasIdle) out += Action.Ui(SessionUi.Idle)
        knownHostId = null
        cancelLatched = false
        log('I', "pair_forget", "live=${flag(live)}")
    }

    private fun onConfig(cfg: StreamConfig, out: MutableList<Action>) {
        if (phase == Phase.HOST_ACCEPTED_UNTRUSTED) {
            bufferedConfig = cfg // T-150: latest only; applied after the local confirmation
            return
        }
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
        // T-156: a record authenticated by the reader (e.g. audio only) resets the count even if no event reaches onMessage.
        if (!sealedSeen && controlGen >= 0 && authFailures.isNotEmpty() && recordAuthenticated(controlGen)) {
            endpoint?.let { authFailures.remove(it) }
        }
        // T-150: the confirmation prompt times out after CONFIRM_TIMEOUT_US of visible time (background never counts).
        if (promptGen >= 0 && promptVisible) {
            promptVisibleUs += nowUs - promptLastUs
            promptLastUs = nowUs
            if (promptVisibleUs >= CONFIRM_TIMEOUT_US) {
                cancelPrompt(REASON_TIMEOUT, out)
                return
            }
        }
        if (candGen >= 0 && nowUs >= candDeadlineUs) {
            failCandidate(out, nowUs, if (candAck != null) REASON_PROOF_TIMEOUT else REASON_TIMEOUT)
        }
        if (retiredGen >= 0 && nowUs >= retireDeadlineUs) closeRetired(out)
        // T-205 review: while the proof is pending, the current connection's heartbeat expiring does not lose the session
        // (that would also drop the candidate and its authenticated STREAM_CONFIG; the host may have superseded the old
        // connection and its PONG baseline is older than the proof). It is marked *stale*: provisional, unlike a close or
        // BYE(SUPERSEDED) ([oldGone]); a later valid PONG on it clears the mark ([onMessage]).
        if (candAck != null && !oldGone && !oldStale && nowUs - lastPongUs >= PONG_TIMEOUT_US) {
            oldStale = true
            log('I', "migration_old_stale", "")
        }
        // T-205: the current connection is gone or stale for our pending proof: no PONG timeout, ping or video retry on
        // it; the candidate's first record or its deadline (above) decides (a failure then loses the session).
        if (oldGone || oldStale) return
        when (phase) {
            Phase.WAIT_RETRY -> if (nowUs >= retryAtUs) openControl(out)
            Phase.AWAIT_ACK, Phase.PENDING, Phase.HOST_ACCEPTED_UNTRUSTED, Phase.ACCEPTED, Phase.STREAMING -> {
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
        out += Action.OpenControl(controlGen, ep, wakeAttempt, userInitiated)
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

    /**
     * T-156: the current connection, now ending, is PAIRED, its proof PING went out (the PAIRED ack moved it to ACCEPTED)
     * and no host record has authenticated on it. PAIRING sessions, T-150's pending-confirm path (closed before any ack
     * is handled) and handshake errors (still AWAIT_ACK) never match. A record the reader authenticated but the machine
     * has not seen (still queued behind this event, audio, an unknown type) does not match and resets the count.
     */
    private fun unauthenticatedPairedEnd(): Boolean {
        val ep = endpoint ?: return false
        // Authentication always resets, in any phase (review: the reader may authenticate while the plaintext ack is
        // still queued behind a priority close); only counting needs the phase guard below.
        if (controlGen >= 0 && recordAuthenticated(controlGen)) {
            authFailures.remove(ep)
            return false
        }
        return phase == Phase.ACCEPTED && !pairingSession && !sealedSeen && candGen < 0
    }

    /**
     * T-156: one more PAIRED connection on [endpoint] ended before any authenticated host record ([how]: `auth_failed`
     * or `closed`). Below [KEY_MISMATCH_LIMIT] it is lost as before ([cause], normal backoff); at the limit the session
     * ends in terminal `Failed(KEY_MISMATCH)`: no BYE (nothing from the host authenticated), no retry timer.
     */
    private fun pairedAuthFailure(out: MutableList<Action>, nowUs: Long, how: String, cause: SessionUi.Cause) {
        val ep = endpoint ?: return lose(out, nowUs, cause)
        val n = (authFailures[ep] ?: 0) + 1
        authFailures[ep] = n
        log('W', "paired_auth_fail", "count=$n how=$how")
        if (n < KEY_MISMATCH_LIMIT) {
            lose(out, nowUs, cause)
            return
        }
        closeAll(out, graceful = false)
        phase = Phase.FAILED
        userInitiated = false
        out += Action.Ui(SessionUi.Failed(SessionUi.Cause.KEY_MISMATCH))
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
        val open = phase == Phase.PENDING || phase == Phase.HOST_ACCEPTED_UNTRUSTED || phase == Phase.ACCEPTED ||
            phase == Phase.STREAMING
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
        if (promptGen >= 0 && promptGen == controlGen) clearPrompt() // a live prompt ends with its connection
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
        pairingSession = false
        locallyTrusted = false
        sessionHostId = null
        sessionPendingFp = null
        sealedSeen = false
        bufferedConfig = null
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

    /** T-205: the candidate's handshake (PAIRED, read-only store): its key is never kept; it must be the same Mac. */
    private fun onCandidateSecured(event: Event.Secured, nowUs: Long, out: MutableList<Action>) {
        val id = event.hostId?.value
        val current = sessionHostId
        if (event.code != null || (id != null && current != null && !id.contentEquals(current))) {
            failCandidate(out, nowUs, REASON_KEY)
            return
        }
        candHostId = id?.copyOf()
    }

    private fun onCandidateMessage(msg: Message, nowUs: Long, out: MutableList<Action>) {
        if (candAck != null) {
            // T-205: the reader delivers a record only after it decrypted and authenticated it: the host holds our key.
            if (msg is Bye) failCandidate(out, nowUs, REASON_PROOF_CLOSED) else promote(msg, nowUs, out)
            return
        }
        when {
            msg is HelloAck && msg.status == HelloAck.ACCEPTED -> startProof(msg, nowUs, out)
            // PENDING_APPROVAL cannot be a takeover (the host answers BUSY then): never pair through a migration.
            msg is HelloAck -> failCandidate(out, nowUs, "ack_${msg.status}")
            msg is Bye -> failCandidate(out, nowUs, REASON_CLOSED)
            else -> Unit // nothing else is expected before ACCEPTED
        }
    }

    /**
     * T-205: the candidate's plaintext ACCEPTED proves nothing yet. The proof PING (its first sealed record) goes out on
     * the candidate; the current session stays current, input keeps flowing on it, its video stays open.
     */
    private fun startProof(ack: HelloAck, nowUs: Long, out: MutableList<Action>) {
        candAck = ack
        out += Action.SendCandidate(Ping(pingSeq++, nowUs))
        log('I', "migration_proof_wait", "cand_gen=$candGen")
    }

    /** T-205: BYE(SUPERSEDED) or a close of the current connection while the proof is pending (final, unlike [oldStale]). */
    private fun oldConnectionGone(how: String) {
        if (oldGone) return
        oldGone = true
        oldStale = false
        log('I', "migration_old_gone", "how=$how")
    }

    /**
     * A candidate failure: the candidate is closed and reported ([abortMigration]). If the host already superseded the
     * current connection for its proof ([oldGone]), or its heartbeat expired and never recovered ([oldStale]), the session
     * has no live connection left: it is lost and reconnects. A recovered one (a PONG cleared [oldStale]) is kept.
     */
    private fun failCandidate(out: MutableList<Action>, nowUs: Long, reason: String) {
        val gone = oldGone || oldStale
        abortMigration(out, reason)
        if (gone) lose(out, nowUs, SessionUi.Cause.LOST)
    }

    /** Closes the candidate (if any) and reports the failed migration; the current session is not touched. */
    private fun abortMigration(out: MutableList<Action>, reason: String) {
        val ep = candEndpoint
        if (candGen < 0 || ep == null) return
        out += Action.CloseCandidate
        out += Action.MigrationResult(ep, false, reason)
        clearCandidate()
    }

    private fun clearCandidate() {
        candGen = -1
        candEndpoint = null
        candAck = null
        candHostId = null
        oldGone = false
        oldStale = false
    }

    private fun closeRetired(out: MutableList<Action>) {
        if (retiredGen < 0) return
        out += Action.CloseRetired
        retiredGen = -1
    }

    /**
     * T-205: the candidate's first authenticated host record [first] arrived: it becomes the session. The old control
     * connection is retired without a BYE (a BYE that reached the host before our proof would end the session the
     * takeover supersedes); the host releases its input and closes it on the proof (PROTOCOL.md sections 3.3 and 7).
     * The settings follow the proof PING already queued on the candidate; then [first] is the new session's message.
     */
    private fun promote(first: Message, nowUs: Long, out: MutableList<Action>) {
        val gen = candGen
        val ep = candEndpoint ?: return
        val ack = candAck ?: return
        val hostId = candHostId ?: sessionHostId // same Mac (PAIRED takeover with the same trusted key)
        clearCandidate()
        closeRetired(out) // an earlier migration's leftover, if any
        if (videoGen >= 0) out += Action.CloseVideo // the old session's frames must not reach the new stream's decoder
        if (controlGen >= 0) {
            out += Action.RetireControl
            retiredGen = controlGen
            retireDeadlineUs = nowUs + RETIRE_TIMEOUT_US
        }
        resetSessionFields()
        sessionHostId = hostId
        controlGen = gen
        endpoint = ep
        out += Action.PromoteCandidate(gen, ep)
        log('I', "migration_proved", "cand_gen=$gen")
        locallyTrusted = true // the candidate inherits the replaced session's trust (same host_id, same trusted key)
        takeAck(ack)
        acceptSession(nowUs, out, proofSent = true) // STREAM_PREFS / DISPLAY_RATE / AUDIO_PREFS / FILES_INFO, Ui(Connected)
        out += Action.MigrationResult(ep, true, REASON_OK)
        onMessage(first, nowUs, out) // normally the new STREAM_CONFIG: closes the retired connection, opens video
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
        /** T-150: the local code confirmation is cancelled after this much *visible* prompt time. */
        const val CONFIRM_TIMEOUT_US = 120_000_000L
        /** T-156: consecutive PAIRED connections without an authenticated host record before `Failed(KEY_MISMATCH)`. */
        const val KEY_MISMATCH_LIMIT = 3

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
        const val REASON_CANCELLED = "cancelled"
        /** T-205: after the proof PING, the candidate's first record did not authenticate (a squatter). HARD_FAIL. */
        const val REASON_PROOF_FAILED = "proof_failed"
        /** T-205: after the proof PING, the candidate closed (or said BYE) before an authenticated record. HARD_FAIL. */
        const val REASON_PROOF_CLOSED = "proof_closed"
        /** T-205: after the proof PING, no authenticated record before the candidate deadline. HARD_FAIL. */
        const val REASON_PROOF_TIMEOUT = "proof_timeout"

        /** T-150 `pair_trust_cancelled reason=` (with [REASON_TIMEOUT]). */
        const val REASON_USER = "user"
        /** Review #2: the confirmed prompt's pending record was replaced or is gone; nothing was promoted. */
        const val REASON_STALE = "stale"

        /** T-150: whether audio read on control connection [gen] may be delivered, given the machine's [acceptedGen]. */
        fun deliversAudio(acceptedGen: Int, gen: Int): Boolean = acceptedGen >= 0 && acceptedGen == gen
    }
}
