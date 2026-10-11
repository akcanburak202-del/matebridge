package dev.matebridge.client.session

import dev.matebridge.client.protocol.Bye
import dev.matebridge.client.protocol.Bytes
import dev.matebridge.client.protocol.Hello
import dev.matebridge.client.protocol.HelloAck
import dev.matebridge.client.protocol.Ping
import dev.matebridge.client.protocol.Pong
import dev.matebridge.client.protocol.StreamConfig
import dev.matebridge.client.security.TrustFixture
import dev.matebridge.client.session.SessionMachine.Action
import dev.matebridge.client.session.SessionMachine.Event
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * T-156: repeated PAIRED connections that end before any host record authenticated end in terminal
 * `Failed(KEY_MISMATCH)`, per endpoint; everything else keeps today's retry behaviour.
 */
class KeyMismatchTest {
    private val hello = Hello(0, Bytes(ByteArray(16) { it.toByte() }), 2800, 1840, 360, 144, 0xFF, "MatePad")
    private val wifi = Endpoint("10.0.0.5", 47001)
    private val usb = ConnectMode.usbEndpoint
    private val hostId = ByteArray(16) { (0x40 + it).toByte() }
    private val logs = ArrayList<String>()
    /** Generations whose reader authenticated a host record (the controller's `ControlConn.authenticated`). */
    private val authed = HashSet<Int>()
    private var m = SessionMachine(hello, recordAuthenticated = { it in authed }) { level, ev, fields -> logs += "$level $ev $fields" }
    private var now = 1_000_000L
    private val mismatch = SessionUi.Failed(SessionUi.Cause.KEY_MISMATCH)

    private fun step(e: Event, advanceUs: Long = 0): List<Action> {
        now += advanceUs
        return m.handle(e, now)
    }

    private inline fun <reified T : Action> List<Action>.only(): T = filterIsInstance<T>().single()
    private inline fun <reified T : Action> List<Action>.has() = any { it is T }
    private fun List<Action>.ui() = filterIsInstance<Action.Ui>().map { it.state }

    private fun ack(status: Int) = HelloAck(0, status, 77, 7421, "Mac mini")
    private fun cfg() = StreamConfig(1, 1, 2800, 1840, 1400, 920, 60, 20000, 1, 1, 1, 1)

    /** The current control generation, from the last OpenControl in [a]. */
    private fun genOf(a: List<Action>) = a.only<Action.OpenControl>().gen

    /** A connection [gen] that got its PAIRED ack: the proof PING went out, nothing from the host authenticated yet. */
    private fun pairedAck(gen: Int): List<Action> {
        step(Event.ControlOpened(gen))
        step(Event.Secured(gen, null, false, Bytes(hostId.copyOf())))
        val a = step(Event.Received(gen, ack(HelloAck.ACCEPTED)))
        assertTrue("proof PING sent", a.filterIsInstance<Action.Send>().any { it.msg is Ping })
        return a
    }

    /** Waits out the retry backoff; returns the reconnect's generation. */
    private fun retry(): Int = genOf(step(Event.Tick(0), SessionMachine.BACKOFF_MAX_US))

    private fun authFail(gen: Int) = step(Event.ProtocolError(gen, authFailed = true))
    private fun closeNoBye(gen: Int) = step(Event.ControlClosed(gen))

    private fun assertNoReconnect() {
        repeat(5) { assertFalse(step(Event.Tick(0), 10_000_000).has<Action.OpenControl>()) }
    }

    @Test fun threeFirstRecordAuthFailuresEndInKeyMismatch() { // (a): a host without T-152
        var gen = genOf(step(Event.Start(wifi)))
        pairedAck(gen)
        assertEquals(listOf<SessionUi>(SessionUi.Disconnected(SessionUi.Cause.PROTOCOL_ERROR, 1000)), authFail(gen).ui())
        gen = retry()
        pairedAck(gen)
        assertEquals(listOf<SessionUi>(SessionUi.Disconnected(SessionUi.Cause.PROTOCOL_ERROR, 1000)), authFail(gen).ui())
        gen = retry()
        pairedAck(gen)
        val r = authFail(gen)
        assertEquals(listOf<SessionUi>(mismatch), r.ui())
        assertFalse(r.has<Action.Send>()) // no BYE: nothing from the host authenticated
        assertEquals(false, r.only<Action.CloseControl>().graceful)
        assertNoReconnect()
        assertTrue(logs.contains("W paired_auth_fail count=3 how=auth_failed"))
    }

    @Test fun threeClosesAfterTheProofPingEndInKeyMismatch() { // (b): a T-152 host closes without BYE
        var gen = genOf(step(Event.Start(wifi)))
        pairedAck(gen)
        assertEquals(listOf<SessionUi>(SessionUi.Disconnected(SessionUi.Cause.LOST, 1000)), closeNoBye(gen).ui())
        gen = retry()
        pairedAck(gen)
        assertEquals(listOf<SessionUi>(SessionUi.Disconnected(SessionUi.Cause.LOST, 1000)), closeNoBye(gen).ui())
        gen = retry()
        pairedAck(gen)
        assertEquals(listOf<SessionUi>(mismatch), closeNoBye(gen).ui())
        assertNoReconnect()
        assertTrue(logs.contains("W paired_auth_fail count=3 how=closed"))
    }

    @Test fun aMixOfAuthFailuresAndClosesCounts() {
        var gen = genOf(step(Event.Start(wifi)))
        pairedAck(gen)
        closeNoBye(gen)
        gen = retry()
        pairedAck(gen)
        authFail(gen)
        gen = retry()
        pairedAck(gen)
        assertEquals(listOf<SessionUi>(mismatch), closeNoBye(gen).ui())
    }

    @Test fun anAutomaticStartToAMismatchedEndpointOpensNothingUntilAUserStart() {
        reachMismatch(wifi)
        val auto = step(Event.Start(wifi))
        assertFalse(auto.has<Action.OpenControl>())
        assertEquals(listOf<SessionUi>(mismatch), auto.ui())
        assertNoReconnect()
        // a user start clears the count: it connects, and one more failure only retries
        val gen = genOf(step(Event.Start(wifi, userInitiated = true)))
        pairedAck(gen)
        assertEquals(listOf<SessionUi>(SessionUi.Disconnected(SessionUi.Cause.LOST, 1000)), closeNoBye(gen).ui())
    }

    @Test fun connectTapOnTheMismatchTextIsAUserStart() { // review P2-1: through the real UI-origin mapping
        reachMismatch(wifi)
        // before the fix, "Bağlan" with the address field hidden was CONNECT_BUTTON (not user-initiated): refused
        assertFalse(step(Event.Start(wifi, userInitiated = ConnectOrigin.CONNECT_BUTTON.userInitiated)).has<Action.OpenControl>())
        val origin = ConnectOrigin.forConnectButton("", fieldVisible = false, shown = mismatch)
        assertEquals(ConnectOrigin.CONNECT_AFTER_MISMATCH, origin)
        assertTrue(origin.userInitiated)
        assertFalse(origin.automatic)
        assertTrue(origin.clearsGate)
        val gen = genOf(step(Event.Start(wifi, userInitiated = origin.userInitiated)))
        pairedAck(gen)
        assertEquals(listOf<SessionUi>(SessionUi.Disconnected(SessionUi.Cause.LOST, 1000)), closeNoBye(gen).ui()) // count cleared
        // a typed address stays a typed address
        assertEquals(ConnectOrigin.TYPED_ADDRESS, ConnectOrigin.forConnectButton("10.0.0.5:47001", true, mismatch))
    }

    @Test fun aCloseThatOvertakesAnAuthenticatedRecordDoesNotCount() { // review P2-2: writer close on the priority mailbox
        var gen = genOf(step(Event.Start(wifi)))
        repeat(2) {
            pairedAck(gen)
            closeNoBye(gen)
            gen = retry()
        }
        pairedAck(gen)
        authed += gen // the reader authenticated STREAM_CONFIG and enqueued it ...
        val r = closeNoBye(gen) // ... but the writer's I/O error close is handled first
        assertEquals(listOf<SessionUi>(SessionUi.Disconnected(SessionUi.Cause.LOST, 1000)), r.ui())
        assertFalse(step(Event.Received(gen, cfg())).has<Action.ApplyConfig>()) // now stale
        // the authenticated record reset the count: two more failures only retry, the third ends it
        gen = retry()
        pairedAck(gen)
        assertTrue(closeNoBye(gen).ui().single() is SessionUi.Disconnected)
        gen = retry()
        pairedAck(gen)
        assertTrue(authFail(gen).ui().single() is SessionUi.Disconnected)
        gen = retry()
        pairedAck(gen)
        assertEquals(listOf<SessionUi>(mismatch), closeNoBye(gen).ui())
    }

    @Test fun authenticatedAudioOrUnknownRecordsResetTheCount() { // review P2-3: they never reach onMessage
        var gen = genOf(step(Event.Start(wifi)))
        repeat(2) {
            pairedAck(gen)
            authFail(gen)
            gen = retry()
        }
        pairedAck(gen)
        authed += gen // AUDIO_CONFIG / an unknown type authenticated; the machine sees no Received
        step(Event.Tick(0), 100_000) // the reset does not wait for the connection to end
        assertTrue(authFail(gen).ui().single() is SessionUi.Disconnected) // a later bad record is not a key mismatch
        repeat(2) {
            gen = retry()
            pairedAck(gen)
            assertTrue(closeNoBye(gen).ui().single() is SessionUi.Disconnected)
        }
        gen = retry()
        pairedAck(gen)
        assertEquals(listOf<SessionUi>(mismatch), closeNoBye(gen).ui())
    }

    @Test fun aPriorityCloseBeforeTheQueuedAckStillResetsOnAuthentication() { // review 2 P2-2: pre-T-152 host
        var gen = genOf(step(Event.Start(wifi)))
        repeat(2) {
            pairedAck(gen)
            authFail(gen)
            gen = retry()
        }
        step(Event.ControlOpened(gen))
        step(Event.Secured(gen, null, false, Bytes(hostId.copyOf())))
        authed += gen // the reader authenticated a record while its plaintext ack is still queued (machine in AWAIT_ACK)
        assertTrue(closeNoBye(gen).ui().single() is SessionUi.Disconnected) // a writer close overtakes the ack
        assertTrue(step(Event.Received(gen, ack(HelloAck.ACCEPTED))).isEmpty()) // stale now
        // the two old failures are gone: two more only retry, the third ends it
        repeat(2) {
            gen = retry()
            pairedAck(gen)
            assertTrue(closeNoBye(gen).ui().single() is SessionUi.Disconnected)
        }
        gen = retry()
        pairedAck(gen)
        assertEquals(listOf<SessionUi>(mismatch), closeNoBye(gen).ui())
    }

    @Test fun anAuthenticatedRecordOfAnotherGenerationDoesNotReset() {
        var gen = genOf(step(Event.Start(wifi)))
        pairedAck(gen)
        authed += gen + 100 // e.g. a candidate's or an old connection's reader
        closeNoBye(gen)
        repeat(2) {
            gen = retry()
            pairedAck(gen)
            val r = closeNoBye(gen)
            if (it == 1) assertEquals(listOf<SessionUi>(mismatch), r.ui())
        }
    }

    @Test fun stopAndForgetClearTheCount() {
        reachMismatch(wifi)
        step(Event.Stop)
        assertTrue(step(Event.Start(wifi)).has<Action.OpenControl>())
        step(Event.Stop)
        reachMismatch(wifi)
        step(Event.ForgetHost) // no trust store here: the forget fails, but the user acted on the mismatch
        assertTrue(step(Event.Start(wifi)).has<Action.OpenControl>())
    }

    @Test fun oneOrTwoFailuresRetryAndAnAuthenticatedRecordResetsTheCount() {
        var gen = genOf(step(Event.Start(wifi)))
        pairedAck(gen)
        authFail(gen)
        gen = retry()
        pairedAck(gen)
        closeNoBye(gen)
        gen = retry()
        pairedAck(gen)
        step(Event.Received(gen, Pong(0, 0, now))) // the first authenticated host record: the key matches
        // a later drop is an ordinary loss; two more never-authenticated connections still only retry
        assertEquals(listOf<SessionUi>(SessionUi.Disconnected(SessionUi.Cause.LOST, 1000)), closeNoBye(gen).ui())
        gen = retry()
        pairedAck(gen)
        assertEquals(listOf<SessionUi>(SessionUi.Disconnected(SessionUi.Cause.LOST, 1000)), closeNoBye(gen).ui())
        gen = retry()
        pairedAck(gen)
        assertEquals(listOf<SessionUi>(SessionUi.Disconnected(SessionUi.Cause.PROTOCOL_ERROR, 1000)), authFail(gen).ui())
        gen = retry()
        pairedAck(gen)
        assertEquals(listOf<SessionUi>(mismatch), authFail(gen).ui())
    }

    @Test fun aByeIsAnAuthenticatedRecordAndResetsTheCount() {
        var gen = genOf(step(Event.Start(wifi)))
        pairedAck(gen)
        authFail(gen)
        gen = retry()
        pairedAck(gen)
        authFail(gen)
        gen = retry()
        pairedAck(gen)
        assertEquals(listOf<SessionUi>(SessionUi.Disconnected(SessionUi.Cause.HOST_CLOSED, 1000)), step(Event.Received(gen, Bye(Bye.NORMAL))).ui())
        gen = retry()
        pairedAck(gen)
        assertTrue(authFail(gen).ui().single() is SessionUi.Disconnected)
    }

    @Test fun nonAuthErrorsAndClosesBeforeTheProofPingNeverCount() {
        var gen = genOf(step(Event.Start(wifi)))
        repeat(6) {
            when (it % 3) {
                // a decoding error (OVERSIZE, ...) after the PAIRED ack is not a key problem
                0 -> { pairedAck(gen); assertTrue(step(Event.ProtocolError(gen)).ui().single() is SessionUi.Disconnected) }
                // closed during the handshake (before the ack): no proof PING went out
                1 -> { step(Event.ControlOpened(gen)); assertTrue(closeNoBye(gen).ui().single() is SessionUi.Disconnected) }
                // a handshake error (AUTH_FAILED while validating the ack itself) is still before the proof PING
                else -> { step(Event.ControlOpened(gen)); assertTrue(authFail(gen).ui().single() is SessionUi.Disconnected) }
            }
            gen = retry()
        }
        // connect failures and plaintext BUSY never count either
        repeat(4) {
            assertTrue(step(Event.ControlClosed(gen, connectFailed = true)).ui().single() is SessionUi.Disconnected)
            gen = retry()
            step(Event.ControlOpened(gen))
            assertTrue(step(Event.Received(gen, ack(HelloAck.BUSY))).ui().single() is SessionUi.Disconnected)
            gen = retry()
        }
        assertFalse(logs.any { "paired_auth_fail" in it })
    }

    @Test fun failuresAfterARecordAuthenticatedNeverCount() {
        var gen = genOf(step(Event.Start(wifi)))
        repeat(5) {
            pairedAck(gen)
            step(Event.Received(gen, cfg())) // authenticated STREAM_CONFIG
            assertTrue(authFail(gen).ui().single() is SessionUi.Disconnected)
            gen = retry()
        }
        assertFalse(logs.any { "paired_auth_fail" in it })
    }

    @Test fun pairingConnectionsNeverCount() {
        var gen = genOf(step(Event.Start(wifi, userInitiated = true)))
        repeat(5) {
            step(Event.ControlOpened(gen))
            step(Event.Secured(gen, "123456", false, Bytes(hostId.copyOf())))
            step(Event.Received(gen, ack(HelloAck.PENDING_APPROVAL)))
            assertTrue(authFail(gen).ui().single() is SessionUi.Disconnected)
            gen = retry()
        }
        assertFalse(logs.any { "paired_auth_fail" in it })
    }

    @Test fun theT150PendingConfirmPathNeverCounts() {
        // PAIRED answer while the host has an unconfirmed pending key: nothing is derived, the reader closes (FirstAck).
        var gen = genOf(step(Event.Start(wifi)))
        repeat(5) {
            step(Event.ControlOpened(gen))
            // no trust store: the pending record is "gone meanwhile", the session is lost and retries
            assertEquals(
                listOf<SessionUi>(SessionUi.Disconnected(SessionUi.Cause.PROTOCOL_ERROR, minOf(1000L shl it, 5000))),
                step(Event.PairedWithPending(gen, Bytes(hostId.copyOf()))).ui(),
            )
            gen = retry()
        }
        assertFalse(logs.any { "paired_auth_fail" in it })
        // with a fresh pending record it shows the stored code instead, never KEY_MISMATCH
        val f = TrustFixture()
        f.trust.storePending(hostId, ByteArray(32) { 1 }, "123456")
        m = SessionMachine(hello, trust = f.trust, recordAuthenticated = { it in authed }) { level, ev, fields -> logs += "$level $ev $fields" }
        gen = genOf(step(Event.Start(wifi, userInitiated = true)))
        repeat(3) {
            step(Event.ControlOpened(gen))
            val r = step(Event.PairedWithPending(gen, Bytes(hostId.copyOf())))
            assertTrue(r.ui().single() is SessionUi.StoredTrust)
            gen = genOf(step(Event.Start(wifi, userInitiated = true)))
        }
        assertFalse(logs.any { "paired_auth_fail" in it })
    }

    @Test fun theCountIsPerEndpoint() {
        reachMismatch(usb)
        // the Wi-Fi path is not poisoned by the USB squatter: an automatic start there connects and retries normally
        var gen = genOf(step(Event.Start(wifi)))
        pairedAck(gen)
        assertTrue(closeNoBye(gen).ui().single() is SessionUi.Disconnected)
        gen = retry()
        pairedAck(gen)
        assertTrue(closeNoBye(gen).ui().single() is SessionUi.Disconnected)
        // ... while USB stays latched for automatic starts
        val auto = step(Event.Start(usb))
        assertFalse(auto.has<Action.OpenControl>())
        assertEquals(listOf<SessionUi>(mismatch), auto.ui())
        // and the two Wi-Fi failures were kept (no reset by the USB start): a third on Wi-Fi ends there too
        gen = genOf(step(Event.Start(wifi)))
        pairedAck(gen)
        assertEquals(listOf<SessionUi>(mismatch), closeNoBye(gen).ui())
    }

    @Test fun keyMismatchOnUsbFallsBackToWifiInAutoOnly() {
        assertTrue(AutoUsbPolicy.shouldFallBack(TransportMode.AUTO, true, mismatch))
        assertFalse(AutoUsbPolicy.shouldFallBack(TransportMode.AUTO, false, mismatch)) // on Wi-Fi: terminal
        assertFalse(AutoUsbPolicy.shouldFallBack(TransportMode.USB, true, mismatch)) // manual USB: terminal
        assertFalse(AutoUsbPolicy.shouldFallBack(TransportMode.WIFI, false, mismatch))
        assertEquals(AutoUsbPolicy.Stage.FAILED, AutoUsbPolicy.stageOf(mismatch)) // AUTO on Wi-Fi does nothing
        assertEquals(AutoUsbPolicy.OpenAction.IGNORE, AutoUsbPolicy.onProbeOpen(mismatch))
    }

    @Test fun theLogCarriesNoKeyMaterial() {
        reachMismatch(wifi)
        val hex = hostId.joinToString("") { "%02x".format(it) }
        for (l in logs) {
            assertFalse(l, l.contains(hex))
            assertFalse(l, l.contains("Mac mini"))
        }
    }

    /** T-339 (decision 0038): the remote button is a user tap: it clears the mismatch latch, yet never starts a pairing. */
    @Test fun remoteStartClearsTheMismatchLatchWithoutBeingAPairingStart() {
        reachMismatch(wifi)
        assertEquals(listOf<SessionUi>(mismatch), step(Event.Start(wifi)).ui()) // automatic: still latched
        val open = step(Event.Start(wifi, remote = RemoteProfile()))
        assertFalse(open.only<Action.OpenControl>().userInitiated)
    }

    private fun reachMismatch(ep: Endpoint) {
        var gen = genOf(step(Event.Start(ep)))
        repeat(SessionMachine.KEY_MISMATCH_LIMIT) {
            pairedAck(gen)
            val r = closeNoBye(gen)
            if (it < SessionMachine.KEY_MISMATCH_LIMIT - 1) gen = retry() else assertEquals(listOf<SessionUi>(mismatch), r.ui())
        }
    }
}
