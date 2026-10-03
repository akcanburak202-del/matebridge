package dev.matebridge.client.session

import java.net.ConnectException
import java.net.SocketTimeoutException

/** The user's connection choice (T-096): automatic (USB when available, else Wi-Fi), or one transport only. */
enum class TransportMode(val id: String) {
    AUTO("auto"), USB("usb"), WIFI("wifi");

    companion object {
        /** Exact ids only; anything else (null, typo) is null. */
        fun parse(s: String?): TransportMode? = entries.firstOrNull { it.id == s }

        /** Stored setting: a saved `usb`/`wifi` was picked by hand and is kept; nothing stored (or unknown) is AUTO. */
        fun fromSetting(s: String?): TransportMode = parse(s) ?: AUTO
    }
}

/**
 * T-105: a connection-mode choice made while a session is accepted (the in-stream settings panel) keeps the session when
 * it already fits the new choice: AUTO always fits (its own policy moves Wi-Fi to USB, T-096), USB/Wi-Fi only on that
 * transport. Without an accepted session the transport is always re-applied (the connect panel's behaviour).
 */
object TransportSwitch {
    fun keepsSession(choice: TransportMode, accepted: Boolean, current: Transport?): Boolean = accepted && fits(choice, current)

    /** Whether a session on [transport] fits the mode: AUTO takes either, USB/Wi-Fi only their own. */
    fun fits(choice: TransportMode, transport: Transport?): Boolean = when (choice) {
        TransportMode.AUTO -> true
        TransportMode.USB -> transport == Transport.USB
        TransportMode.WIFI -> transport == Transport.WIFI
    }

    /**
     * A transport choice that a running AUTO migration (Wi-Fi -> USB) may no longer fit cancels it; AUTO itself keeps it.
     */
    fun cancelsMigration(choice: TransportMode): Boolean = choice != TransportMode.AUTO

    /** What to do with a migration that succeeded onto [to] while the selected mode is [choice]. */
    enum class MigrationVerdict { ACCEPT, REJECT_RECONNECT }

    /**
     * A successful migration that no longer fits the selected mode (the user picked "Yalnız Wi-Fi" while the candidate
     * was being promoted) is rejected: the session is on the wrong transport and must reconnect under the chosen mode.
     */
    fun onMigrated(choice: TransportMode, to: Transport): MigrationVerdict =
        if (fits(choice, to)) MigrationVerdict.ACCEPT else MigrationVerdict.REJECT_RECONNECT
}

/** Result of the short TCP reachability probe of the USB control port (`adb reverse`, PROTOCOL.md section 3.1). */
enum class ProbeResult(val reason: String) {
    OPEN("usb_open"), REFUSED("usb_refused"), TIMEOUT("usb_timeout"), ERROR("usb_error");
}

object UsbProbe {
    /** At most this long for the initial auto pick (T-096: <= 500 ms). */
    const val TIMEOUT_MS = 500

    /**
     * Runs [connect] (a TCP connect that is closed again at once, never a session: no HELLO, nothing sent) and
     * classifies the outcome. A refused connect means nothing listens on the loopback port, i.e. no `adb reverse`.
     */
    fun classify(connect: () -> Unit): ProbeResult = try {
        connect()
        ProbeResult.OPEN
    } catch (e: SocketTimeoutException) {
        ProbeResult.TIMEOUT
    } catch (e: ConnectException) {
        ProbeResult.REFUSED
    } catch (e: Exception) {
        ProbeResult.ERROR
    }
}

/**
 * Probe generations across threads (T-133). The main thread [bump]s to invalidate every earlier probe (a new pick,
 * a transport change, background, BYE(HOST_SLEEP)); the probe thread [attach]es its socket right before connecting and
 * must not connect when that fails, so a queued or delayed probe never reaches the Mac (`adb reverse` connects dark-wake
 * a sleeping Mac). A bump also closes the socket of a probe already connecting, which then fails at once.
 */
class ProbeGuard {
    private var gen = 0
    private var inFlight: java.io.Closeable? = null
    private var inFlightGen = -1

    /** Invalidates every earlier probe (closing one that is connecting) and returns the new current generation. */
    fun bump(): Int {
        val (newGen, toClose) = synchronized(this) {
            gen++
            val c = inFlight
            inFlight = null
            inFlightGen = -1
            gen to c
        }
        try { toClose?.close() } catch (_: java.io.IOException) {}
        return newGen
    }

    @Synchronized fun isCurrent(g: Int): Boolean = g == gen

    /** Probe thread, right before connecting: false (do not connect) when [g] is no longer current. */
    @Synchronized
    fun attach(g: Int, socket: java.io.Closeable): Boolean {
        if (g != gen) return false
        inFlight = socket
        inFlightGen = g
        return true
    }

    /** Probe thread, after the connect returned or failed. */
    @Synchronized
    fun detach(g: Int) {
        if (inFlightGen == g) {
            inFlight = null
            inFlightGen = -1
        }
    }
}

/** Whether a USB cable is plugged in, as far as the system tells us. */
enum class CableState(val logName: String) { CONNECTED("connected"), DISCONNECTED("disconnected"), UNKNOWN("unknown") }

/**
 * Cable state from the sticky broadcasts: `android.hardware.usb.action.USB_STATE` (`connected`) is authoritative once
 * seen; until then the battery's `EXTRA_PLUGGED` (any power source counts) stands in; with neither it is UNKNOWN.
 * Main thread only.
 */
class CableTracker {
    var state = CableState.UNKNOWN
        private set
    private var usbStateSeen = false

    /** Returns true when the state changed. */
    fun onUsbState(connected: Boolean): Boolean {
        usbStateSeen = true
        return set(if (connected) CableState.CONNECTED else CableState.DISCONNECTED)
    }

    /** [plugged] is `BatteryManager.EXTRA_PLUGGED` (0 = on battery). Ignored once USB_STATE was seen. */
    fun onBattery(plugged: Int): Boolean {
        if (usbStateSeen) return false
        return set(if (plugged != 0) CableState.CONNECTED else CableState.DISCONNECTED)
    }

    private fun set(s: CableState): Boolean {
        if (s == state) return false
        state = s
        return true
    }
}

/**
 * When to try USB in AUTO mode (T-096). Pure and clock-injected; main thread only.
 *
 * Attempts are at least [MIN_INTERVAL_MS] apart and one at a time. A refused/cheap attempt (nothing listens on the
 * loopback port: the host never sees it) keeps the 2 s cadence for [FAST_SOFT_TRIES] tries (the host needs a moment to
 * set up `adb reverse` after a plug), then slows to [SLOW_INTERVAL_MS] (e.g. on a wall charger). An attempt that reached
 * the port but gave no session (closed, BUSY, timeout, a USB session that dropped) backs off exponentially up to
 * [MAX_BACKOFF_MS], so the host is not hammered with handshakes. A working USB session or a cable change resets the
 * counters. No attempts while the cable is known to be unplugged.
 */
class AutoUsbPolicy {
    enum class Outcome { OK, SOFT_FAIL, HARD_FAIL, NEUTRAL }

    /** What the session is doing, as far as the auto decision is concerned. */
    enum class Stage { NOT_CONNECTED, ACCEPTED, WAITING_USER, FAILED }

    enum class Step { NONE, MIGRATE, PROBE }

    /** What to do with an OPEN rescan probe, decided on the session state when the result is consumed. */
    enum class OpenAction { SWITCH, MIGRATE, IGNORE }

    var cable = CableState.UNKNOWN
        private set
    var failures = 0
        private set
    var softFailures = 0
        private set
    private var nextTryAtMs = 0L
    private var inFlightSinceMs = -1L

    val inFlight: Boolean get() = inFlightSinceMs >= 0

    fun onCable(state: CableState, nowMs: Long) {
        if (state == cable) return
        cable = state
        failures = 0
        softFailures = 0
        if (state == CableState.CONNECTED) nextTryAtMs = minOf(nextTryAtMs, nowMs) // a fresh plug: try at once
    }

    /** The next AUTO step; [onUsb]: the current endpoint is the USB loopback one. */
    fun next(onUsb: Boolean, stage: Stage, nowMs: Long): Step {
        if (onUsb || cable == CableState.DISCONNECTED) return Step.NONE
        if (inFlight && nowMs - inFlightSinceMs < STUCK_MS) return Step.NONE
        if (nowMs < nextTryAtMs) return Step.NONE
        return when (stage) {
            Stage.ACCEPTED -> Step.MIGRATE
            Stage.NOT_CONNECTED -> Step.PROBE
            Stage.WAITING_USER, Stage.FAILED -> Step.NONE
        }
    }

    fun onTryStarted(nowMs: Long) {
        inFlightSinceMs = nowMs
        nextTryAtMs = nowMs + MIN_INTERVAL_MS
    }

    fun onTryResult(outcome: Outcome, nowMs: Long) {
        inFlightSinceMs = -1
        // Never earlier than already planned: a late or duplicate result cannot cut a backoff short.
        val wait = when (outcome) {
            Outcome.OK -> { failures = 0; softFailures = 0; MIN_INTERVAL_MS }
            Outcome.NEUTRAL -> MIN_INTERVAL_MS
            Outcome.SOFT_FAIL -> {
                softFailures = minOf(softFailures + 1, 1000)
                if (softFailures <= FAST_SOFT_TRIES) MIN_INTERVAL_MS else SLOW_INTERVAL_MS
            }
            Outcome.HARD_FAIL -> {
                failures = minOf(failures + 1, 30)
                backoffMs(failures)
            }
        }
        nextTryAtMs = maxOf(nextTryAtMs, nowMs + wait)
    }

    /** A USB session is up: earlier failures no longer count. */
    fun onUsbConnected() {
        failures = 0
        softFailures = 0
    }

    companion object {
        const val MIN_INTERVAL_MS = 2_000L
        const val SLOW_INTERVAL_MS = 10_000L
        const val FAST_SOFT_TRIES = 15
        const val MAX_BACKOFF_MS = 60_000L
        const val STUCK_MS = 10_000L

        fun backoffMs(failures: Int): Long =
            if (failures <= 0) MIN_INTERVAL_MS else minOf(MIN_INTERVAL_MS shl minOf(failures, 10), MAX_BACKOFF_MS)

        fun stageOf(ui: SessionUi): Stage = when (ui) {
            is SessionUi.Connected -> Stage.ACCEPTED
            is SessionUi.AwaitingApproval, is SessionUi.PairingNeedsUser, is SessionUi.StoredTrust -> Stage.WAITING_USER
            is SessionUi.Failed -> Stage.FAILED
            SessionUi.Idle, SessionUi.Searching, is SessionUi.Connecting, is SessionUi.Disconnected -> Stage.NOT_CONNECTED
        }

        /** Migration outcome reasons (SessionMachine) mapped to the backoff class. */
        fun outcomeOf(ok: Boolean, reason: String): Outcome = when {
            ok -> Outcome.OK
            reason in SOFT_REASONS -> Outcome.SOFT_FAIL
            else -> Outcome.HARD_FAIL
        }

        /** Probe outcome: OPEN is NEUTRAL (the session that follows decides), anything else is a cheap local failure. */
        fun outcomeOf(probe: ProbeResult): Outcome = if (probe == ProbeResult.OPEN) Outcome.NEUTRAL else Outcome.SOFT_FAIL

        /**
         * The probe ran off the UI thread; the Wi-Fi session may have moved on meanwhile. Accepted: move it with a
         * takeover (never tear it down). Pairing in progress, a connect attempt underway, or a terminal failure: leave
         * it alone (the next step decides again). Nothing connected: switch to USB.
         */
        fun onProbeOpen(ui: SessionUi): OpenAction = when (ui) {
            is SessionUi.Connected -> OpenAction.MIGRATE
            SessionUi.Idle, SessionUi.Searching, is SessionUi.Disconnected -> OpenAction.SWITCH
            is SessionUi.Connecting, is SessionUi.AwaitingApproval, is SessionUi.Failed,
            is SessionUi.PairingNeedsUser, is SessionUi.StoredTrust -> OpenAction.IGNORE
        }

        /** AUTO on USB and the session dropped (cable pulled, host gone, never reached): fall back to Wi-Fi. */
        fun shouldFallBack(mode: TransportMode, onUsb: Boolean, ui: SessionUi): Boolean =
            mode == TransportMode.AUTO && onUsb && ui is SessionUi.Disconnected

        private val SOFT_REASONS = setOf(
            SessionMachine.REASON_CONNECT_FAILED, SessionMachine.REASON_NOT_CONNECTED,
            SessionMachine.REASON_IN_PROGRESS, SessionMachine.REASON_SAME_ENDPOINT, SessionMachine.REASON_SESSION_CLOSED,
        )
    }
}
