package dev.matebridge.client.session

import dev.matebridge.client.session.AutoUsbPolicy.Outcome
import dev.matebridge.client.session.AutoUsbPolicy.Stage
import dev.matebridge.client.session.AutoUsbPolicy.Step
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.IOException
import java.net.ConnectException
import java.net.SocketTimeoutException

class AutoTransportTest {
    @Test fun modeParsing() {
        assertEquals(TransportMode.AUTO, TransportMode.parse("auto"))
        assertEquals(TransportMode.USB, TransportMode.parse("usb"))
        assertEquals(TransportMode.WIFI, TransportMode.parse("wifi"))
        assertNull(TransportMode.parse("USB"))
        assertNull(TransportMode.parse(null))
        assertEquals(TransportMode.AUTO, TransportMode.fromSetting(null))
        assertEquals(TransportMode.AUTO, TransportMode.fromSetting("x"))
        assertEquals(TransportMode.WIFI, TransportMode.fromSetting("wifi"))
    }

    @Test fun probeClassification() {
        assertEquals(ProbeResult.OPEN, UsbProbe.classify {})
        assertEquals(ProbeResult.REFUSED, UsbProbe.classify { throw ConnectException("refused") })
        assertEquals(ProbeResult.TIMEOUT, UsbProbe.classify { throw SocketTimeoutException() })
        assertEquals(ProbeResult.ERROR, UsbProbe.classify { throw IOException("other") })
        assertEquals(ProbeResult.ERROR, UsbProbe.classify { throw SecurityException() })
        assertTrue(UsbProbe.TIMEOUT_MS <= 500)
        assertEquals("usb_refused", ProbeResult.REFUSED.reason)
    }

    @Test fun cableUsbStateWinsOverBattery() {
        val c = CableTracker()
        assertEquals(CableState.UNKNOWN, c.state)
        assertTrue(c.onBattery(2)) // BATTERY_PLUGGED_USB
        assertEquals(CableState.CONNECTED, c.state)
        assertFalse(c.onBattery(2))
        assertTrue(c.onUsbState(false))
        assertEquals(CableState.DISCONNECTED, c.state)
        assertFalse(c.onBattery(1)) // ignored once USB_STATE was seen
        assertEquals(CableState.DISCONNECTED, c.state)
        assertTrue(c.onUsbState(true))
        assertEquals(CableState.CONNECTED, c.state)
    }

    @Test fun stageOfUi() {
        assertEquals(Stage.ACCEPTED, AutoUsbPolicy.stageOf(SessionUi.Connected("m", 0)))
        assertEquals(Stage.WAITING_USER, AutoUsbPolicy.stageOf(SessionUi.AwaitingApproval("m")))
        assertEquals(Stage.FAILED, AutoUsbPolicy.stageOf(SessionUi.Failed(SessionUi.Cause.REJECTED)))
        for (ui in listOf(SessionUi.Idle, SessionUi.Searching, SessionUi.Connecting(Endpoint("a", 1)), SessionUi.Disconnected(SessionUi.Cause.LOST, 1000))) {
            assertEquals(Stage.NOT_CONNECTED, AutoUsbPolicy.stageOf(ui))
        }
    }

    @Test fun decisionTable() {
        val p = AutoUsbPolicy()
        assertEquals(Step.MIGRATE, p.next(onUsb = false, stage = Stage.ACCEPTED, nowMs = 0))
        assertEquals(Step.PROBE, p.next(false, Stage.NOT_CONNECTED, 0))
        assertEquals(Step.NONE, p.next(false, Stage.WAITING_USER, 0)) // never interrupt a pairing
        assertEquals(Step.NONE, p.next(false, Stage.FAILED, 0))
        assertEquals(Step.NONE, p.next(true, Stage.ACCEPTED, 0)) // already on USB
        p.onCable(CableState.DISCONNECTED, 0)
        assertEquals(Step.NONE, p.next(false, Stage.ACCEPTED, 0)) // cable known to be out
        p.onCable(CableState.CONNECTED, 0)
        assertEquals(Step.MIGRATE, p.next(false, Stage.ACCEPTED, 0))
    }

    @Test fun oneAttemptAtATimeAndAtMostEveryTwoSeconds() {
        val p = AutoUsbPolicy()
        p.onTryStarted(0)
        assertTrue(p.inFlight)
        assertEquals(Step.NONE, p.next(false, Stage.ACCEPTED, 5_000)) // still running
        p.onTryResult(Outcome.SOFT_FAIL, 5_000)
        assertEquals(Step.NONE, p.next(false, Stage.ACCEPTED, 6_999))
        assertEquals(Step.MIGRATE, p.next(false, Stage.ACCEPTED, 7_000))
        // a stuck attempt is given up after STUCK_MS
        p.onTryStarted(7_000)
        assertEquals(Step.NONE, p.next(false, Stage.ACCEPTED, 7_000 + AutoUsbPolicy.STUCK_MS - 1))
        assertEquals(Step.MIGRATE, p.next(false, Stage.ACCEPTED, 7_000 + AutoUsbPolicy.STUCK_MS))
    }

    @Test fun cheapFailuresSlowDownAfterAWhile() {
        val p = AutoUsbPolicy()
        var t = 0L
        repeat(AutoUsbPolicy.FAST_SOFT_TRIES) {
            assertEquals(Step.PROBE, p.next(false, Stage.NOT_CONNECTED, t))
            p.onTryStarted(t)
            p.onTryResult(Outcome.SOFT_FAIL, t)
            t += AutoUsbPolicy.MIN_INTERVAL_MS
        }
        assertEquals(Step.PROBE, p.next(false, Stage.NOT_CONNECTED, t))
        p.onTryStarted(t)
        p.onTryResult(Outcome.SOFT_FAIL, t)
        assertEquals(Step.NONE, p.next(false, Stage.NOT_CONNECTED, t + AutoUsbPolicy.MIN_INTERVAL_MS))
        assertEquals(Step.PROBE, p.next(false, Stage.NOT_CONNECTED, t + AutoUsbPolicy.SLOW_INTERVAL_MS))
        // a plug resets to the fast cadence and tries at once
        p.onCable(CableState.CONNECTED, t + 1)
        assertEquals(0, p.softFailures)
        assertEquals(Step.PROBE, p.next(false, Stage.NOT_CONNECTED, t + 1))
    }

    @Test fun hardFailuresBackOffExponentiallyAndResetOnSuccessOrPlug() {
        assertEquals(2_000L, AutoUsbPolicy.backoffMs(0))
        assertEquals(4_000L, AutoUsbPolicy.backoffMs(1))
        assertEquals(8_000L, AutoUsbPolicy.backoffMs(2))
        assertEquals(AutoUsbPolicy.MAX_BACKOFF_MS, AutoUsbPolicy.backoffMs(30))
        val p = AutoUsbPolicy()
        p.onTryStarted(0)
        p.onTryResult(Outcome.HARD_FAIL, 0)
        p.onTryStarted(4_000)
        p.onTryResult(Outcome.HARD_FAIL, 4_000)
        assertEquals(2, p.failures)
        assertEquals(Step.NONE, p.next(false, Stage.ACCEPTED, 4_000 + 7_999))
        assertEquals(Step.MIGRATE, p.next(false, Stage.ACCEPTED, 4_000 + 8_000))
        // a late cheap result cannot cut the backoff short
        p.onTryResult(Outcome.SOFT_FAIL, 4_001)
        assertEquals(Step.NONE, p.next(false, Stage.ACCEPTED, 4_000 + 7_999))
        p.onUsbConnected()
        assertEquals(0, p.failures)
        p.onTryResult(Outcome.HARD_FAIL, 20_000)
        p.onCable(CableState.DISCONNECTED, 20_001)
        assertEquals(0, p.failures)
        p.onCable(CableState.CONNECTED, 20_002)
        assertEquals(Step.MIGRATE, p.next(false, Stage.ACCEPTED, 20_002)) // a fresh plug tries at once
    }

    @Test fun outcomeMapping() {
        assertEquals(Outcome.OK, AutoUsbPolicy.outcomeOf(true, SessionMachine.REASON_OK))
        for (r in listOf(SessionMachine.REASON_CONNECT_FAILED, SessionMachine.REASON_NOT_CONNECTED, SessionMachine.REASON_IN_PROGRESS, SessionMachine.REASON_SAME_ENDPOINT, SessionMachine.REASON_SESSION_CLOSED)) {
            assertEquals(r, Outcome.SOFT_FAIL, AutoUsbPolicy.outcomeOf(false, r))
        }
        for (r in listOf(SessionMachine.REASON_CLOSED, SessionMachine.REASON_TIMEOUT, SessionMachine.REASON_PROTOCOL_ERROR, SessionMachine.REASON_KEY, "ack_3")) {
            assertEquals(r, Outcome.HARD_FAIL, AutoUsbPolicy.outcomeOf(false, r))
        }
        assertEquals(Outcome.NEUTRAL, AutoUsbPolicy.outcomeOf(ProbeResult.OPEN))
        assertEquals(Outcome.SOFT_FAIL, AutoUsbPolicy.outcomeOf(ProbeResult.REFUSED))
        assertEquals(Outcome.SOFT_FAIL, AutoUsbPolicy.outcomeOf(ProbeResult.TIMEOUT))
    }

    @Test fun openRescanProbeIsJudgedOnTheStateWhenConsumed() {
        assertEquals(AutoUsbPolicy.OpenAction.MIGRATE, AutoUsbPolicy.onProbeOpen(SessionUi.Connected("m", 0)))
        assertEquals(AutoUsbPolicy.OpenAction.IGNORE, AutoUsbPolicy.onProbeOpen(SessionUi.AwaitingApproval("m", "123456")))
        assertEquals(AutoUsbPolicy.OpenAction.IGNORE, AutoUsbPolicy.onProbeOpen(SessionUi.Connecting(Endpoint("10.0.0.5", 47001))))
        assertEquals(AutoUsbPolicy.OpenAction.IGNORE, AutoUsbPolicy.onProbeOpen(SessionUi.Failed(SessionUi.Cause.REJECTED)))
        for (ui in listOf(SessionUi.Idle, SessionUi.Searching, SessionUi.Disconnected(SessionUi.Cause.LOST, 1000))) {
            assertEquals(AutoUsbPolicy.OpenAction.SWITCH, AutoUsbPolicy.onProbeOpen(ui))
        }
    }

    @Test fun closeSlotsKeepTheCurrentCloseWhenACandidateCloses() {
        val slots = ControlCloseSlots()
        // the current connection (gen 3) and a higher-gen candidate (gen 4) close at the same time
        slots.post(SessionMachine.Event.ControlClosed(3), ControlCloseSlots.Owner.CURRENT)
        slots.post(SessionMachine.Event.ControlClosed(4, connectFailed = true), ControlCloseSlots.Owner.CANDIDATE)
        assertEquals(3, slots.take()?.gen)
        assertEquals(4, slots.take()?.gen)
        assertNull(slots.take())
        // a cancelled (aborted) candidate's close is dropped entirely and cannot replace the current one's
        slots.post(SessionMachine.Event.ControlClosed(5), ControlCloseSlots.Owner.CURRENT)
        slots.post(SessionMachine.Event.ControlClosed(6), ControlCloseSlots.Owner.CANCELLED)
        assertEquals(5, slots.take()?.gen)
        assertNull(slots.take())
        // a promoted candidate posts as CURRENT; an older (retired) connection's close cannot replace it
        slots.post(SessionMachine.Event.ControlClosed(8), ControlCloseSlots.Owner.CURRENT)
        slots.post(SessionMachine.Event.ControlClosed(7), ControlCloseSlots.Owner.CURRENT)
        assertEquals(8, slots.take()?.gen)
        assertNull(slots.take())
    }

    @Test fun pickPromptStatesWaitForTheUserAndAreIgnoredByAnOpenProbe() { // T-151
        val waiting = listOf(
            SessionUi.AwaitingApproval("m", "123456", needsLocalConfirm = true),
            SessionUi.StoredTrust("123456", confirmed = false),
            SessionUi.StoredTrust(null, confirmed = true),
            SessionUi.PairingNeedsUser("m", rePair = false),
        )
        for (ui in waiting) {
            assertEquals(Stage.WAITING_USER, AutoUsbPolicy.stageOf(ui))
            assertEquals(AutoUsbPolicy.OpenAction.IGNORE, AutoUsbPolicy.onProbeOpen(ui))
            assertEquals(Step.NONE, AutoUsbPolicy().next(false, AutoUsbPolicy.stageOf(ui), 0)) // no probe, no migrate
        }
    }

    @Test fun anAskedUsbEndpointIsNeverProbedSwitchedToOrMigratedTo() { // T-151
        val p = AutoUsbPolicy()
        assertEquals(Step.NONE, p.next(false, Stage.NOT_CONNECTED, 0, usbBlocked = true))
        assertEquals(Step.NONE, p.next(false, Stage.ACCEPTED, 0, usbBlocked = true))
        assertEquals(Step.PROBE, p.next(false, Stage.NOT_CONNECTED, 0, usbBlocked = false))
        for (ui in listOf(SessionUi.Idle, SessionUi.Searching, SessionUi.Disconnected(SessionUi.Cause.LOST, 1000), SessionUi.Connected("m", 0))) {
            assertEquals(AutoUsbPolicy.OpenAction.IGNORE, AutoUsbPolicy.onProbeOpen(ui, usbBlocked = true))
        }
    }

    @Test fun pickPromptOnUsbFallsBackToWifiInAuto() { // T-151: a localhost squatter must not park the tablet
        val pick = SessionUi.PairingNeedsUser("m", rePair = false)
        assertTrue(AutoUsbPolicy.shouldFallBack(TransportMode.AUTO, true, pick))
        assertFalse(AutoUsbPolicy.shouldFallBack(TransportMode.USB, true, pick)) // manual USB: the prompt stays
        assertFalse(AutoUsbPolicy.shouldFallBack(TransportMode.AUTO, false, pick)) // already on Wi-Fi
        assertFalse(AutoUsbPolicy.shouldFallBack(TransportMode.AUTO, true, SessionUi.StoredTrust("123456", false)))
        assertFalse(AutoUsbPolicy.shouldFallBack(TransportMode.AUTO, true, SessionUi.AwaitingApproval("m", "123456", needsLocalConfirm = true)))
    }

    @Test fun fallbackReasonNamesAPairingAnswer() { // T-207: not the misleading usb_lost
        assertEquals("usb_asked", AutoUsbPolicy.fallbackReason(SessionUi.PairingNeedsUser("m", rePair = true)))
        assertEquals("usb_lost", AutoUsbPolicy.fallbackReason(SessionUi.Disconnected(SessionUi.Cause.LOST, 1000)))
        assertEquals("usb_lost", AutoUsbPolicy.fallbackReason(SessionUi.Failed(SessionUi.Cause.KEY_MISMATCH)))
    }

    @Test fun anUnblockedUsbEndpointIsTriedAtOnceDespiteTheFallbackBackoff() { // T-207
        val p = AutoUsbPolicy()
        p.onCable(CableState.CONNECTED, 0)
        p.onTryStarted(0)
        p.onTryResult(Outcome.HARD_FAIL, 0) // fallBackToWifi after the PAIRING answer
        p.onTryResult(Outcome.HARD_FAIL, 0)
        p.onTryResult(Outcome.HARD_FAIL, 0) // a few of them: 16 s backoff
        assertEquals(Step.NONE, p.next(false, Stage.ACCEPTED, 1_000, usbBlocked = false))
        p.onUsbUnblocked(1_000)
        assertEquals(0, p.failures)
        assertEquals(Step.MIGRATE, p.next(false, Stage.ACCEPTED, 1_000))
        assertEquals(Step.PROBE, p.next(false, Stage.NOT_CONNECTED, 1_000))
        // never while one is in flight, nor with the cable known unplugged
        p.onTryStarted(1_000)
        p.onUsbUnblocked(1_500)
        assertEquals(Step.NONE, p.next(false, Stage.ACCEPTED, 1_500))
        p.onCable(CableState.DISCONNECTED, 2_000)
        p.onTryResult(Outcome.NEUTRAL, 2_000)
        p.onUsbUnblocked(5_000)
        assertEquals(Step.NONE, p.next(false, Stage.ACCEPTED, 5_000))
    }

    @Test fun fallBackOnlyInAutoOnUsbWhenDisconnected() {
        val lost = SessionUi.Disconnected(SessionUi.Cause.LOST, 1000)
        assertTrue(AutoUsbPolicy.shouldFallBack(TransportMode.AUTO, true, lost))
        assertTrue(AutoUsbPolicy.shouldFallBack(TransportMode.AUTO, true, SessionUi.Disconnected(SessionUi.Cause.CONNECT_FAILED, 1000)))
        assertFalse(AutoUsbPolicy.shouldFallBack(TransportMode.USB, true, lost)) // manual USB keeps retrying USB
        assertFalse(AutoUsbPolicy.shouldFallBack(TransportMode.AUTO, false, lost))
        assertFalse(AutoUsbPolicy.shouldFallBack(TransportMode.AUTO, true, SessionUi.Connected("m", 1)))
        assertFalse(AutoUsbPolicy.shouldFallBack(TransportMode.AUTO, true, SessionUi.Failed(SessionUi.Cause.REJECTED)))
    }
}
