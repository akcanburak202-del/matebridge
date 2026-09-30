package dev.matebridge.client.session

import dev.matebridge.client.protocol.Bye
import dev.matebridge.client.protocol.Bytes
import dev.matebridge.client.protocol.Hello
import dev.matebridge.client.protocol.HelloAck
import dev.matebridge.client.protocol.Ping
import dev.matebridge.client.protocol.Pong
import dev.matebridge.client.protocol.StreamConfig
import dev.matebridge.client.protocol.StreamPrefs
import dev.matebridge.client.stream.StreamMode
import dev.matebridge.client.protocol.VideoHello
import dev.matebridge.client.session.SessionMachine.Action
import dev.matebridge.client.session.SessionMachine.Event
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class SessionMachineTest {
    private val hello = Hello(0, Bytes(ByteArray(16) { it.toByte() }), 2800, 1840, 360, 144, 0xFF, "MatePad")
    private val ep = Endpoint("10.0.0.5", 7420)
    private val m = SessionMachine(hello)
    private var now = 1_000_000L // us

    private fun step(e: Event, advanceUs: Long = 0): List<Action> {
        now += advanceUs
        return m.handle(e, now)
    }

    private inline fun <reified T : Action> List<Action>.only(): T = filterIsInstance<T>().single()
    private inline fun <reified T : Action> List<Action>.has() = any { it is T }
    private fun List<Action>.ui() = filterIsInstance<Action.Ui>().map { it.state }

    private fun ack(status: Int, session: Long = 0, port: Int = 0) = HelloAck(0, status, session, port, "Mac mini")
    private fun cfg(id: Int) = StreamConfig(id, 1, 2800, 1840, 1400, 920, 60, 20000, 1, 1, 1, 1)

    /** Drives to the ACCEPTED state, returns the control generation. */
    private fun connectAccepted(): Int {
        val open = step(Event.Start(ep)).only<Action.OpenControl>()
        step(Event.ControlOpened(open.gen))
        step(Event.Received(open.gen, ack(HelloAck.ACCEPTED, 77, 7421)))
        return open.gen
    }

    @Test fun startOpensControlAndSendsHelloOnceOpen() {
        val a = step(Event.Start(ep))
        val open = a.only<Action.OpenControl>()
        assertEquals(ep, open.endpoint)
        assertEquals(listOf<SessionUi>(SessionUi.Connecting(ep)), a.ui())
        val b = step(Event.ControlOpened(open.gen))
        assertEquals(hello, b.only<Action.Send>().msg)
        assertFalse(m.inputAllowed)
    }

    @Test fun pendingThenAccepted() {
        val gen = step(Event.Start(ep)).only<Action.OpenControl>().gen
        step(Event.ControlOpened(gen))
        val p = step(Event.Received(gen, ack(HelloAck.PENDING_APPROVAL)))
        assertEquals(listOf<SessionUi>(SessionUi.AwaitingApproval("Mac mini")), p.ui())
        assertFalse(m.inputAllowed)
        val a = step(Event.Received(gen, ack(HelloAck.ACCEPTED, 5, 7421)))
        assertEquals(listOf<SessionUi>(SessionUi.Connected("Mac mini", 0)), a.ui())
        assertTrue(m.inputAllowed)
    }

    @Test fun pairingCodeAndRePairingReachTheUi() {
        val gen = step(Event.Start(ep)).only<Action.OpenControl>().gen
        step(Event.ControlOpened(gen))
        step(Event.Secured(gen, "044261", rePairing = true))
        val p = step(Event.Received(gen, ack(HelloAck.PENDING_APPROVAL)))
        assertEquals(listOf<SessionUi>(SessionUi.AwaitingApproval("Mac mini", "044261", true)), p.ui())
        step(Event.Received(gen, ack(HelloAck.ACCEPTED, 5, 7421)))
        // a later session starts without the old code
        val gen2 = step(Event.Start(ep)).only<Action.OpenControl>().gen
        step(Event.ControlOpened(gen2))
        val q = step(Event.Received(gen2, ack(HelloAck.PENDING_APPROVAL)))
        assertEquals(listOf<SessionUi>(SessionUi.AwaitingApproval("Mac mini", null, false)), q.ui())
    }

    @Test fun staleSecuredEventIsIgnored() {
        val gen = step(Event.Start(ep)).only<Action.OpenControl>().gen
        step(Event.ControlOpened(gen))
        step(Event.Secured(gen + 50, "111111", false))
        val p = step(Event.Received(gen, ack(HelloAck.PENDING_APPROVAL)))
        assertEquals(listOf<SessionUi>(SessionUi.AwaitingApproval("Mac mini", null, false)), p.ui())
    }

    @Test fun missingPairKeyFailsWithoutRetryOrBye() {
        val gen = step(Event.Start(ep)).only<Action.OpenControl>().gen
        step(Event.ControlOpened(gen))
        val r = step(Event.KeyMissing(gen))
        assertEquals(listOf<SessionUi>(SessionUi.Failed(SessionUi.Cause.KEY_MISSING)), r.ui())
        assertFalse(r.has<Action.Send>())
        assertEquals(false, r.only<Action.CloseControl>().graceful)
        assertFalse(step(Event.Tick(0), 60_000_000).has<Action.OpenControl>())
    }

    @Test fun stopBeforeTheFirstAckSendsNoByeBecauseNothingIsEncryptedYet() {
        val gen = step(Event.Start(ep)).only<Action.OpenControl>().gen
        step(Event.ControlOpened(gen))
        val r = step(Event.Stop)
        assertFalse(r.has<Action.Send>())
    }

    @Test fun acceptedSendsOneImmediatePingFirstAndSecond() {
        val gen = step(Event.Start(ep)).only<Action.OpenControl>().gen
        step(Event.ControlOpened(gen))
        val pend = step(Event.Received(gen, ack(HelloAck.PENDING_APPROVAL)))
        assertFalse(pend.has<Action.Send>())
        val acc = step(Event.Received(gen, ack(HelloAck.ACCEPTED, 5, 7421)))
        assertEquals(listOf(true, false), acc.filterIsInstance<Action.Send>().map { it.msg is Ping })
        // direct ACCEPTED (PAIRED) also proves the key at once
        val gen2 = step(Event.Start(ep)).only<Action.OpenControl>().gen
        step(Event.ControlOpened(gen2))
        val acc2 = step(Event.Received(gen2, ack(HelloAck.ACCEPTED, 6, 7421)))
        assertTrue(acc2.filterIsInstance<Action.Send>().first().msg is Ping)
    }

    private fun sends(a: List<Action>) = a.filterIsInstance<Action.Send>().map { it.msg }

    @Test fun acceptedSendsStreamPrefsRightAfterTheProofPing() {
        val gen = step(Event.Start(ep)).only<Action.OpenControl>().gen
        step(Event.ControlOpened(gen))
        val acc = step(Event.Received(gen, ack(HelloAck.ACCEPTED, 5, 7421)))
        val s = sends(acc)
        assertEquals(2, s.size)
        assertTrue(s[0] is Ping)
        assertEquals(StreamMode.DEFAULT.toPrefs(), s[1])
        assertEquals(StreamPrefs(120, 1000), s[1])
    }

    @Test fun initialModeIsUsedAndResentOnEveryConnection() {
        val mm = SessionMachine(hello, StreamMode.PERFORMANCE_144.toPrefs())
        for (i in 1..2) {
            val gen = mm.handle(Event.Start(ep), now).filterIsInstance<Action.OpenControl>().single().gen
            mm.handle(Event.ControlOpened(gen), now)
            val acc = mm.handle(Event.Received(gen, ack(HelloAck.ACCEPTED, 5, 7421)), now)
            assertEquals(StreamPrefs(144, 750), acc.filterIsInstance<Action.Send>().last().msg)
        }
    }

    @Test fun setPrefsSendsWhenAcceptedAndRemembersOtherwise() {
        // not connected: nothing goes out, the value is remembered for the next ACCEPTED
        assertTrue(step(Event.SetPrefs(StreamMode.PERFORMANCE.toPrefs())).isEmpty())
        val gen = step(Event.Start(ep)).only<Action.OpenControl>().gen
        step(Event.ControlOpened(gen))
        // awaiting approval: still nothing
        assertTrue(step(Event.SetPrefs(StreamMode.CLARITY.toPrefs())).isEmpty())
        val acc = step(Event.Received(gen, ack(HelloAck.ACCEPTED, 5, 7421)))
        assertEquals(StreamPrefs(60, 1000), sends(acc).last())
        // accepted: sent at once; the same value again sends nothing
        assertEquals(listOf<Any>(StreamPrefs(120, 750)), sends(step(Event.SetPrefs(StreamMode.PERFORMANCE.toPrefs()))))
        assertTrue(step(Event.SetPrefs(StreamMode.PERFORMANCE.toPrefs())).isEmpty())
        // streaming state too
        step(Event.Received(gen, cfg(1)))
        assertEquals(listOf<Any>(StreamPrefs(144, 750)), sends(step(Event.SetPrefs(StreamMode.PERFORMANCE_144.toPrefs()))))
    }

    @Test fun smallerStreamConfigIsAppliedLikeAnyOther() {
        val gen = connectAccepted()
        val small = StreamConfig(2, 2, 2100, 1380, 1400, 920, 120, 20000, 1, 1, 1, 1)
        val r = step(Event.Received(gen, small))
        assertEquals(small, r.only<Action.ApplyConfig>().config)
        assertTrue(r.has<Action.OpenVideo>())
    }

    @Test fun keyStoreFailureFailsTheSessionWithoutRetry() {
        val gen = step(Event.Start(ep)).only<Action.OpenControl>().gen
        step(Event.ControlOpened(gen))
        val r = step(Event.KeyStoreFailed(gen))
        assertEquals(listOf<SessionUi>(SessionUi.Failed(SessionUi.Cause.KEY_STORE_FAILED)), r.ui())
        assertFalse(m.inputAllowed)
        assertFalse(step(Event.Tick(0), 60_000_000).has<Action.OpenControl>())
    }

    @Test fun rejectedAndVersionMismatchAreTerminal() {
        for ((status, cause) in listOf(
            HelloAck.REJECTED to SessionUi.Cause.REJECTED,
            HelloAck.VERSION_MISMATCH to SessionUi.Cause.VERSION_MISMATCH,
        )) {
            val gen = step(Event.Start(ep)).only<Action.OpenControl>().gen
            step(Event.ControlOpened(gen))
            val r = step(Event.Received(gen, ack(status)))
            assertEquals(listOf<SessionUi>(SessionUi.Failed(cause)), r.ui())
            assertTrue(r.has<Action.CloseControl>())
            // No automatic retry however long we wait.
            assertFalse(step(Event.Tick(0), 60_000_000).has<Action.OpenControl>())
        }
    }

    @Test fun busyRetriesAfterAtLeastThreeSeconds() {
        val gen = step(Event.Start(ep)).only<Action.OpenControl>().gen
        step(Event.ControlOpened(gen))
        val r = step(Event.Received(gen, ack(HelloAck.BUSY)))
        assertEquals(SessionUi.Disconnected(SessionUi.Cause.BUSY, 3000), r.ui().single())
        assertFalse(step(Event.Tick(0), 2_900_000).has<Action.OpenControl>())
        assertTrue(step(Event.Tick(0), 200_000).has<Action.OpenControl>())
    }

    @Test fun streamConfigOpensVideoWithSessionAndConfigId() {
        val gen = connectAccepted()
        val a = step(Event.Received(gen, cfg(1)))
        assertEquals(cfg(1), a.only<Action.ApplyConfig>().config)
        val v = a.only<Action.OpenVideo>()
        assertEquals(Endpoint("10.0.0.5", 7421), v.endpoint)
        assertEquals(VideoHello(0, 1, 77), v.hello)
    }

    @Test fun configIdChangeReopensVideoAndIgnoresStaleClose() {
        val gen = connectAccepted()
        val v1 = step(Event.Received(gen, cfg(1))).only<Action.OpenVideo>()
        val a = step(Event.Received(gen, cfg(2)))
        assertTrue(a.has<Action.CloseVideo>())
        val v2 = a.only<Action.OpenVideo>()
        assertEquals(2, v2.hello.configId)
        assertNotEquals(v1.gen, v2.gen)
        // Host closes the old video connection after STREAM_CONFIG: must not trigger another reopen.
        step(Event.VideoClosed(v1.gen))
        assertEquals(0, step(Event.Tick(0), 100_000).filterIsInstance<Action.OpenVideo>().size)
        // Same config_id repeated: ignored.
        assertTrue(step(Event.Received(gen, cfg(2))).isEmpty())
    }

    @Test fun unexpectedVideoCloseReopensAfterDelay() {
        val gen = connectAccepted()
        val v = step(Event.Received(gen, cfg(3))).only<Action.OpenVideo>()
        step(Event.VideoClosed(v.gen))
        step(Event.Received(gen, Pong(0, 0, 0)))
        val early = step(Event.Tick(0), 100_000)
        assertFalse(early.has<Action.OpenVideo>())
        step(Event.Received(gen, Pong(1, 0, 0)), 450_000)
        val again = step(Event.Tick(0))
        assertEquals(3, again.only<Action.OpenVideo>().hello.configId)
    }

    @Test fun pingsEvery500ms() {
        val gen = step(Event.Start(ep)).only<Action.OpenControl>().gen
        step(Event.ControlOpened(gen))
        step(Event.Received(gen, ack(HelloAck.PENDING_APPROVAL))) // nothing but HELLO goes out before the first ack
        assertTrue(step(Event.Tick(0), 100_000).filterIsInstance<Action.Send>().isEmpty())
        val p = step(Event.Tick(0), 400_000).only<Action.Send>().msg as Ping
        assertEquals(0L, p.seq)
        val q = step(Event.Tick(0), 500_000)
        assertEquals(1L, (q.only<Action.Send>().msg as Ping).seq)
    }

    @Test fun noPongForThreeSecondsReconnects() {
        val gen = connectAccepted()
        var lost: List<Action> = emptyList()
        var elapsed = 0L
        while (elapsed < 2_900_000) {
            val r = step(Event.Tick(0), 100_000)
            elapsed += 100_000
            assertFalse(r.has<Action.CloseControl>())
        }
        lost = step(Event.Tick(0), 200_000)
        assertTrue(lost.has<Action.CloseControl>())
        assertEquals(SessionUi.Disconnected(SessionUi.Cause.LOST, 1000), lost.ui().single())
        // Reconnect after backoff, with a fresh generation.
        assertFalse(step(Event.Tick(0), 900_000).has<Action.OpenControl>())
        val re = step(Event.Tick(0), 200_000).only<Action.OpenControl>()
        assertNotEquals(gen, re.gen)
    }

    @Test fun pongKeepsSessionAlive() {
        val gen = connectAccepted()
        repeat(60) {
            step(Event.Received(gen, Pong(0, 0, 0)), 100_000)
            assertFalse(step(Event.Tick(0)).has<Action.CloseControl>())
        }
    }

    @Test fun hostPingIsAnswered() {
        val gen = connectAccepted()
        val r = step(Event.Received(gen, Ping(9, 1234)), 10)
        assertEquals(Pong(9, 1234, now), r.only<Action.Send>().msg)
    }

    @Test fun pingAndPongAreAnsweredWhilePending() {
        val gen = step(Event.Start(ep)).only<Action.OpenControl>().gen
        step(Event.ControlOpened(gen))
        step(Event.Received(gen, ack(HelloAck.PENDING_APPROVAL)))
        assertTrue(step(Event.Received(gen, Ping(1, 2))).only<Action.Send>().msg is Pong)
    }

    @Test fun hostByeReconnectsButRejectedByeDoesNot() {
        val gen = connectAccepted()
        val r = step(Event.Received(gen, Bye(Bye.SHUTTING_DOWN)))
        assertTrue(r.has<Action.CloseControl>())
        assertEquals(SessionUi.Cause.HOST_CLOSED, (r.ui().single() as SessionUi.Disconnected).cause)
        assertTrue(step(Event.Tick(0), 1_100_000).has<Action.OpenControl>())

        val gen2 = connectAccepted()
        val r2 = step(Event.Received(gen2, Bye(Bye.REJECTED)))
        assertEquals(listOf<SessionUi>(SessionUi.Failed(SessionUi.Cause.REJECTED)), r2.ui())
    }

    @Test fun stopSendsByeGracefullyAndClosesVideo() {
        val gen = connectAccepted()
        step(Event.Received(gen, cfg(1)))
        val r = step(Event.Stop)
        assertEquals(Bye(Bye.NORMAL), r.only<Action.Send>().msg)
        assertEquals(true, r.only<Action.CloseControl>().graceful)
        assertTrue(r.has<Action.CloseVideo>())
        assertEquals(listOf<SessionUi>(SessionUi.Idle), r.ui())
        assertFalse(m.inputAllowed)
        // Late events from the closed connection are ignored.
        assertTrue(step(Event.ControlClosed(gen)).isEmpty())
    }

    @Test fun protocolErrorClosesWithoutByeAndReconnects() {
        val gen = connectAccepted()
        val r = step(Event.ProtocolError(gen))
        assertFalse(r.has<Action.Send>()) // section 9: no BYE over a channel that failed authentication
        assertEquals(false, r.only<Action.CloseControl>().graceful)
        assertEquals(SessionUi.Cause.PROTOCOL_ERROR, (r.ui().single() as SessionUi.Disconnected).cause)
    }

    @Test fun connectFailureBacksOffExponentiallyUpToFiveSeconds() {
        var gen = step(Event.Start(ep)).only<Action.OpenControl>().gen
        val delays = ArrayList<Long>()
        repeat(5) {
            val r = step(Event.ControlClosed(gen, connectFailed = true))
            val d = r.ui().single() as SessionUi.Disconnected
            assertEquals(SessionUi.Cause.CONNECT_FAILED, d.cause)
            delays += d.retryInMs
            gen = step(Event.Tick(0), d.retryInMs * 1000).only<Action.OpenControl>().gen
        }
        assertEquals(listOf(1000L, 2000L, 4000L, 5000L, 5000L), delays)
    }

    @Test fun frameCounterShownThrottled() {
        val gen = connectAccepted()
        step(Event.Received(gen, cfg(1)))
        val r = step(Event.Tick(42), 300_000)
        assertEquals(SessionUi.Connected("Mac mini", 42), r.ui().single())
        assertTrue(step(Event.Tick(43), 50_000).ui().isEmpty())
    }

    @Test fun restartDuringSessionClosesOldAndOpensNew() {
        val gen = connectAccepted()
        val r = step(Event.Start(Endpoint("10.0.0.9", 7420)))
        assertTrue(r.has<Action.CloseControl>())
        assertNotEquals(gen, r.only<Action.OpenControl>().gen)
    }
}
