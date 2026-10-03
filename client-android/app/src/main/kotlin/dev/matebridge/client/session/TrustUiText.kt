package dev.matebridge.client.session

/**
 * T-151 (decision 0018): the pure side of the pairing/trust UI. MainActivity resolves [TrustText] ids from `strings.xml`
 * and only renders the result, so everything that decides what the user sees and which connects may pair is here and
 * JVM-tested. Nothing here logs; [pairUiFields] is the only log text it makes, and it never carries a value (no code,
 * key, token or Mac name).
 */
enum class TrustText {
    /** Amber warning above the code when the tablet already had a key for this host_id. */
    KEY_CHANGED,
    COMPARE_CODE,
    CONFIRM_HINT,
    PARSEC_HINT,
    /** The user confirmed locally; the Mac's "İzin ver" is still missing. */
    WAIT_MAC_ALLOW,
    STORED_CODE,
    STORED_CONFIRMED,
    /** `%1$s` = the name the answerer claims ([TrustUiText.claimName]). */
    NEW_HOST_CLAIM,
    RE_PAIR_CLAIM,
    PAIR_CANCELLED,
    FORGET_DONE,
    FORGET_NONE,
    /** The removal did not persist (`Failed(KEY_STORE_FAILED)` after a forget): the Mac is still trusted; retry. */
    FORGET_FAILED,
}

/** A button of the trust row. [logAction] is the `action=` value of `ev=pair_ui`. */
enum class TrustButton(val logAction: String) {
    CONFIRM("confirm"), CANCEL("cancel"), PAIR("pair"), IGNORE("ignore"), REPAIR("repair"), CONNECT("connect"),
}

sealed interface TrustLine {
    data class Text(val id: TrustText, val arg: String? = null) : TrustLine

    /** The 6-digit pairing code, shown large. Never logged: [toString] hides it. */
    class Code(val code: String) : TrustLine {
        override fun equals(other: Any?) = other is Code && other.code == code
        override fun hashCode() = code.hashCode()
        override fun toString() = "Code(***)"
    }
}

/** What the status area shows for a trust state: lines top to bottom and the buttons under them. */
data class TrustView(val lines: List<TrustLine>, val buttons: List<TrustButton>)

/** A "Yeni Mac bulundu / Mac yeniden eşleşmek istiyor" prompt: [endpoint] answered PAIRING to an automatic connect. */
data class PairPrompt(val endpoint: Endpoint, val hostName: String, val rePair: Boolean)

object TrustUiText {
    /** Longest claimed host name shown (code points); longer ones end in "…". */
    const val CLAIM_MAX = 40

    /** The trust view of [state], or null when the state is not a trust state (its usual text applies). */
    fun view(state: SessionUi): TrustView? = when (state) {
        is SessionUi.AwaitingApproval -> state.code?.let { code ->
            val lines = ArrayList<TrustLine>()
            if (state.rePairing) lines += TrustLine.Text(TrustText.KEY_CHANGED)
            lines += TrustLine.Text(TrustText.COMPARE_CODE)
            lines += TrustLine.Code(code)
            if (state.needsLocalConfirm) {
                lines += TrustLine.Text(TrustText.CONFIRM_HINT)
                lines += TrustLine.Text(TrustText.PARSEC_HINT)
                TrustView(lines, listOf(TrustButton.CONFIRM, TrustButton.CANCEL))
            } else {
                lines += TrustLine.Text(TrustText.WAIT_MAC_ALLOW)
                TrustView(lines, emptyList())
            }
        }
        is SessionUi.PairingNeedsUser -> claimView(state.hostName, state.rePair)
        is SessionUi.StoredTrust -> {
            val code = state.code
            if (!state.confirmed && code != null) {
                TrustView(
                    listOf(TrustLine.Text(TrustText.STORED_CODE), TrustLine.Code(code), TrustLine.Text(TrustText.PARSEC_HINT)),
                    listOf(TrustButton.CONFIRM, TrustButton.CANCEL, TrustButton.REPAIR),
                )
            } else {
                TrustView(listOf(TrustLine.Text(TrustText.STORED_CONFIRMED)), listOf(TrustButton.CONNECT))
            }
        }
        is SessionUi.Failed ->
            if (state.cause == SessionUi.Cause.PAIR_CANCELLED) TrustView(listOf(TrustLine.Text(TrustText.PAIR_CANCELLED)), emptyList())
            else null
        SessionUi.Idle, SessionUi.Searching, is SessionUi.Connecting, is SessionUi.Connected, is SessionUi.Disconnected -> null
    }

    /** The prompt kept as a non-blocking banner under another state's text (another endpoint is being tried). */
    fun pickView(p: PairPrompt): TrustView = claimView(p.hostName, p.rePair)

    /**
     * What the status area shows: the state's own trust view, else the pending pick prompt as a banner (never over a
     * running stream), else nothing (the state's usual text). A pick prompt is shown only while [pending] holds it:
     * "Eşleş" needs its endpoint, so a dismissed or unattributable `PairingNeedsUser` shows no buttons (and the plain
     * "Bağlan" stays).
     */
    fun screen(state: SessionUi, pending: PairPrompt?): TrustView? = when (state) {
        is SessionUi.PairingNeedsUser -> pending?.let { pickView(it) }
        else -> view(state) ?: pending?.takeIf { state !is SessionUi.Connected }?.let { pickView(it) }
    }

    /**
     * The state rendered after "Yoksay" (QA-1 T-151 #1): the ordinary screen with "Bağlan" again ("Mac aranıyor…" while
     * discovery runs, else "Hazır"). The connection-less prompt holds nothing, so the UI forgets its endpoint and
     * automatic connects go on to other Macs; the ignored one stays asked in [PairPick].
     */
    fun afterIgnore(discoveryRunning: Boolean): SessionUi = if (discoveryRunning) SessionUi.Searching else SessionUi.Idle

    private fun claimView(hostName: String, rePair: Boolean) = TrustView(
        listOf(TrustLine.Text(if (rePair) TrustText.RE_PAIR_CLAIM else TrustText.NEW_HOST_CLAIM, claimName(hostName))),
        listOf(TrustButton.PAIR, TrustButton.IGNORE),
    )

    /**
     * The host name is chosen by whoever answered: shown only as a claim, without control or bidi-override characters
     * (they could fake the surrounding text), whitespace collapsed, at most [CLAIM_MAX] code points.
     */
    fun claimName(raw: String): String {
        val sb = StringBuilder()
        var space = false
        var count = 0
        var i = 0
        var cut = false
        while (i < raw.length) {
            val cp = raw.codePointAt(i)
            i += Character.charCount(cp)
            if (Character.isWhitespace(cp) || Character.isSpaceChar(cp)) { // tabs and line breaks too: one space
                space = sb.isNotEmpty()
                continue
            }
            if (Character.isISOControl(cp) || cp in BIDI_CONTROLS || Character.getType(cp) == Character.FORMAT.toInt()) continue
            if (count >= CLAIM_MAX) { cut = true; break }
            if (space) { sb.append(' '); count++; space = false; if (count >= CLAIM_MAX) { cut = true; break } }
            sb.appendCodePoint(cp)
            count++
        }
        if (sb.isEmpty()) return "?"
        if (cut) sb.append('…')
        return sb.toString()
    }

    private val BIDI_CONTROLS = (0x202A..0x202E).toSet() + (0x2066..0x2069).toSet() + setOf(0x200E, 0x200F, 0x061C)

    /**
     * Whether the Mac answered (the manual USB hint must not replace what the user has to act on): every state that
     * needs the user, including the T-150 prompts.
     */
    fun hostReached(state: SessionUi): Boolean = when (state) {
        is SessionUi.AwaitingApproval, is SessionUi.Connected, is SessionUi.Failed,
        is SessionUi.PairingNeedsUser, is SessionUi.StoredTrust -> true
        SessionUi.Idle, SessionUi.Searching, is SessionUi.Connecting, is SessionUi.Disconnected -> false
    }

    /**
     * The prompt generation of the rendered confirmation prompt (`confirmTrust`/`cancelTrust` take it, so a tap applies
     * to exactly the code on screen); -1 when [state] is not one (the controller then does nothing).
     */
    fun promptGen(state: SessionUi): Int = when (state) {
        is SessionUi.AwaitingApproval -> state.promptGen
        is SessionUi.StoredTrust -> state.promptGen
        else -> -1
    }

    /** Fields of `ev=pair_ui`: the action only, never a value. */
    fun pairUiFields(action: String): String = "action=$action"
}

/**
 * Where a connect comes from (decision 0018: every pairing starts with a tap). Only [userInitiated] starts may pair
 * (`SessionController.start(userInitiated)`); the others abort at a PAIRING answer and show the pick prompt.
 * [automatic] starts are skipped for an endpoint already asked ([PairPick]); [clearsGate] taps make every endpoint
 * eligible again ("Bağlan", a typed address).
 */
enum class ConnectOrigin(val logName: String, val userInitiated: Boolean, val automatic: Boolean, val clearsGate: Boolean) {
    /** "Eşleş" on the pick prompt, to the endpoint that answered PAIRING. */
    PAIR("pair", userInitiated = true, automatic = false, clearsGate = false),
    /** "Yeniden eşleş" on a stored prompt. ("Kodlar aynı — Güven" there connects inside the machine, user-initiated.) */
    STORED_REPAIR("stored_repair", userInitiated = true, automatic = false, clearsGate = false),
    /** "Bağlan" on a stored prompt whose code was already confirmed. */
    STORED_CONNECT("stored_connect", userInitiated = true, automatic = false, clearsGate = false),
    /** "Bağlan" with an address typed into the open manual field. */
    TYPED_ADDRESS("typed", userInitiated = true, automatic = false, clearsGate = true),
    /** "Bağlan" without a typed address (the current endpoint, or the mode's usual way). */
    CONNECT_BUTTON("connect_button", userInitiated = false, automatic = false, clearsGate = true),
    /**
     * "Bağlan" on "Eşleşme iptal edildi": T-150's cancel latch holds every automatic start until a user start, so this
     * tap is one (it may pair again; the code still needs the local confirmation).
     */
    CONNECT_AFTER_CANCEL("connect_after_cancel", userInitiated = true, automatic = false, clearsGate = true),
    /**
     * T-156: "Bağlan" on "Bu Mac'in anahtarı uyuşmuyor": the key-mismatch latch holds every automatic start to that
     * endpoint until a user start, so this tap is one (like [CONNECT_AFTER_CANCEL]).
     */
    CONNECT_AFTER_MISMATCH("connect_after_mismatch", userInitiated = true, automatic = false, clearsGate = true),
    DISCOVERY("discovery", userInitiated = false, automatic = true, clearsGate = false),
    /** The Wi-Fi endpoint remembered in this activity (AUTO). */
    SAVED_WIFI("saved_wifi", userInitiated = false, automatic = true, clearsGate = false),
    /** Manual USB mode's loopback connect. */
    USB_MODE("usb_mode", userInitiated = false, automatic = true, clearsGate = false),
    /** AUTO's probe pick or rescan switch to USB. */
    AUTO_SWITCH("auto_switch", userInitiated = false, automatic = true, clearsGate = false),
    /** T-134 direct wake attempt. */
    WAKE("wake", userInitiated = false, automatic = true, clearsGate = false),
    ;

    companion object {
        /**
         * "Bağlan": a typed address counts only while the manual field is open (a hidden field's remembered text is not
         * a fresh choice, as in T-134's wake rule). [shown]: the state on screen; on `Failed(PAIR_CANCELLED)` the tap
         * releases T-150's cancel latch ([CONNECT_AFTER_CANCEL]); on `Failed(KEY_MISMATCH)` T-156's mismatch latch
         * ([CONNECT_AFTER_MISMATCH]).
         */
        fun forConnectButton(typed: String, fieldVisible: Boolean, shown: SessionUi): ConnectOrigin = when {
            typed.isNotBlank() && fieldVisible -> TYPED_ADDRESS
            shown is SessionUi.Failed && shown.cause == SessionUi.Cause.PAIR_CANCELLED -> CONNECT_AFTER_CANCEL
            shown is SessionUi.Failed && shown.cause == SessionUi.Cause.KEY_MISMATCH -> CONNECT_AFTER_MISMATCH
            else -> CONNECT_BUTTON
        }
    }
}

/**
 * The pick gate (QA-1 T-151 #1): one impostor must not park the tablet. Main thread only.
 *
 * The endpoint of the latest `Connecting` is the one a following `PairingNeedsUser` came from (the machine runs one
 * session; its states arrive in order). Showing that prompt counts the endpoint as asked: automatic connects never go
 * back to it on their own (each would raise a new dialog on a real Mac) until a user start ("Eşleş", "Bağlan", a typed
 * address). Other endpoints stay eligible: discovered ones are remembered ([nextAuto]) because NSD reports a service
 * once, so the real Mac found while the impostor was being tried is not lost. The prompt stays as a banner until a
 * session gets further (Connected, a pairing, a stored prompt), "Yoksay" or "Eşleş".
 */
class PairPick(private val maxAsked: Int = MAX_ASKED, private val maxSeen: Int = MAX_SEEN) {
    private val asked = LinkedHashSet<Endpoint>()
    private val seen = LinkedHashSet<Endpoint>()
    private var lastConnecting: Endpoint? = null

    var prompt: PairPrompt? = null
        private set

    /** Every rendered state. Returns true when a new pick prompt was raised. */
    fun onUi(state: SessionUi): Boolean {
        when (state) {
            is SessionUi.Connecting -> lastConnecting = state.endpoint
            is SessionUi.PairingNeedsUser -> {
                val ep = lastConnecting ?: return false
                ask(ep)
                prompt = PairPrompt(ep, state.hostName, state.rePair)
                return true
            }
            is SessionUi.Connected, is SessionUi.AwaitingApproval, is SessionUi.StoredTrust -> prompt = null
            else -> Unit
        }
        return false
    }

    private fun ask(ep: Endpoint) {
        asked.remove(ep)
        asked.add(ep)
        while (asked.size > maxAsked) asked.remove(asked.first())
    }

    /** Whether an automatic connect may go to [ep]. */
    fun allowsAuto(ep: Endpoint): Boolean = ep !in asked

    fun isAsked(ep: Endpoint): Boolean = ep in asked

    /** Discovery resolved [ep] (newest last, bounded). */
    fun onDiscovered(ep: Endpoint) {
        seen.remove(ep)
        seen.add(ep)
        while (seen.size > maxSeen) seen.remove(seen.first())
    }

    /** A new discovery run reports everything again. */
    fun clearSeen() = seen.clear()

    /** The newest discovered endpoint an automatic connect may still try, other than [except]. */
    fun nextAuto(except: Endpoint? = null): Endpoint? = seen.toList().asReversed().firstOrNull { it != except && allowsAuto(it) }

    /** "Yoksay": the prompt goes; its endpoint stays asked. */
    fun ignore(): PairPrompt? = prompt.also { prompt = null }

    /** "Eşleş": the prompt goes and its endpoint is eligible again (the user start goes there). */
    fun pair(): PairPrompt? {
        val p = prompt ?: return null
        prompt = null
        asked.remove(p.endpoint)
        return p
    }

    /** A user start that [ConnectOrigin.clearsGate]: every endpoint is eligible again; a pending prompt stays. */
    fun onUserStart() = asked.clear()

    /** "Bağlantıyı kes" / forget: the prompt goes (asked endpoints stay asked). */
    fun dismiss() {
        prompt = null
    }

    companion object {
        const val MAX_ASKED = 16
        const val MAX_SEEN = 8
    }
}

/**
 * T-150's prompt timer counts only visible time: the UI posts `ConfirmPromptVisible(true)` when a confirmation prompt is
 * rendered while started and `false` when it is replaced or on `onStop`. Returns the value to post, or null (no change).
 */
class PromptVisibility {
    var posted = false
        private set

    fun onRender(state: SessionUi, started: Boolean): Boolean? = change(started && isConfirmPrompt(state))

    fun onStop(): Boolean? = change(false)

    private fun change(v: Boolean): Boolean? {
        if (v == posted) return null
        posted = v
        return v
    }

    companion object {
        fun isConfirmPrompt(state: SessionUi): Boolean =
            (state is SessionUi.AwaitingApproval && state.needsLocalConfirm) || state is SessionUi.StoredTrust
    }
}

/**
 * "Bu Mac'i unut" (T-151): two confirmations before [forget] (`SessionController.forgetCurrentHost()`) runs; cancelling
 * at either step changes nothing. [forget] returning true only means the request was queued (T-150): the result comes as
 * a UI state. `Idle` means done; `Failed(KEY_STORE_FAILED)` means the removal did not persist (the Mac stays trusted and
 * forgettable, the row stays usable). A machine that was already idle shows no state on success, so a request with no
 * failure after [settleMs] counts as done ([onTick]); a failure within [lateMs] after that still turns it into
 * [TrustText.FORGET_FAILED]. Clock-injected; main thread only.
 */
class ForgetFlow(
    private val forget: () -> Boolean,
    private val settleMs: Long = SETTLE_MS,
    private val lateMs: Long = LATE_MS,
) {
    enum class Step { IDLE, ASK_FIRST, ASK_SECOND, WAITING }

    var step = Step.IDLE
        private set
    private var sinceMs = 0L
    private var lateUntilMs = -1L

    /** Opens the first question (not while a request is still waiting for its result). */
    fun open(): Step {
        if (step != Step.WAITING) step = Step.ASK_FIRST
        return step
    }

    /**
     * A "yes". After the first question: null (ask the second). After the second: [forget] runs; nothing known to forget
     * gives [TrustText.FORGET_NONE], a queued request gives null and [step] [Step.WAITING].
     */
    fun confirm(nowMs: Long): TrustText? = when (step) {
        Step.IDLE, Step.WAITING -> null
        Step.ASK_FIRST -> { step = Step.ASK_SECOND; null }
        Step.ASK_SECOND -> {
            if (forget()) {
                step = Step.WAITING
                sinceMs = nowMs
                lateUntilMs = -1
                null
            } else {
                step = Step.IDLE
                TrustText.FORGET_NONE
            }
        }
    }

    fun cancel() {
        if (step != Step.WAITING) step = Step.IDLE
    }

    /** Every rendered state: the request's result, or null. */
    fun onUi(state: SessionUi, nowMs: Long): TrustText? {
        val failed = state is SessionUi.Failed && state.cause == SessionUi.Cause.KEY_STORE_FAILED
        if (step == Step.WAITING) {
            if (failed) return resolve(TrustText.FORGET_FAILED)
            if (state == SessionUi.Idle) return resolve(TrustText.FORGET_DONE)
            return null
        }
        if (failed && lateUntilMs >= 0 && nowMs <= lateUntilMs) {
            lateUntilMs = -1
            return TrustText.FORGET_FAILED
        }
        return null
    }

    /** No state came: an idle machine reports success silently. */
    fun onTick(nowMs: Long): TrustText? {
        if (step != Step.WAITING || nowMs - sinceMs < settleMs) return null
        lateUntilMs = nowMs + lateMs
        return resolve(TrustText.FORGET_DONE)
    }

    /** The activity stopped before a result: nothing is reported (the next screen shows the real state). */
    fun abandon() {
        if (step == Step.WAITING) step = Step.IDLE
        lateUntilMs = -1
    }

    private fun resolve(t: TrustText): TrustText {
        step = Step.IDLE
        return t
    }

    companion object {
        /** The engine takes the request within one tick (<= 100 ms); the store commit is quick. */
        const val SETTLE_MS = 1_500L
        const val LATE_MS = 10_000L
    }
}
