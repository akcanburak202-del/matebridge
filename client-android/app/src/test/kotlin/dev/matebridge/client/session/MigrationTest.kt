package dev.matebridge.client.session

import dev.matebridge.client.protocol.AudioPrefs
import dev.matebridge.client.protocol.Bye
import dev.matebridge.client.protocol.Bytes
import dev.matebridge.client.protocol.DisplayRate
import dev.matebridge.client.protocol.Hello
import dev.matebridge.client.protocol.HelloAck
import dev.matebridge.client.protocol.Ping
import dev.matebridge.client.protocol.Pong
import dev.matebridge.client.protocol.StreamConfig
import dev.matebridge.client.protocol.StreamPrefs
import dev.matebridge.client.session.SessionMachine.Action
import dev.matebridge.client.session.SessionMachine.Event
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** T-096: moving an accepted session to another endpoint via the host's takeover (PROTOCOL.md section 3.3). */
class MigrationTest {
    private val hello = Hello(0, Bytes(ByteArray(16) { it.toByte() }), 2800, 1840, 360, 144, 0xFF, "MatePad")
    private val wifi = Endpoint("10.0.0.5", 47001)
    private val usb = ConnectMode.usbEndpoint
    private val m = SessionMachine(hello, initialAudio = true)
    private var now = 1_000_000L

    private fun step(e: Event, advanceUs: Long = 0): List<Action> {
        now += advanceUs
        return m.handle(e, now)
    }

    private inline fun <reified T : Action> List<Action>.only(): T = filterIsInstance<T>().single()
    private inline fun <reified T : Action> List<Action>.has() = any { it is T }
    private fun ack(status: Int, session: Long = 0, port: Int = 0) = HelloAck(0, status, session, port, "Mac mini")
    private fun cfg(id: Int) = StreamConfig(id, 1, 2800, 1840, 1400, 920, 60, 20000, 1, 1, 1, 1)

    /** Accepted and streaming on Wi-Fi; returns the control generation. */
    private fun streamingOnWifi(): Int {
        val gen = step(Event.Start(wifi)).only<Action.OpenControl>().gen
        step(Event.ControlOpened(gen))
        step(Event.Received(gen, ack(HelloAck.ACCEPTED, 77, 47002)))
        step(Event.SetDisplayRate(120))
        assertTrue(step(Event.Received(gen, cfg(1))).has<Action.OpenVideo>())
        return gen
    }

    /** Starts a migration to USB and opens its candidate; returns the candidate generation. */
    private fun candidateOpen(): Int {
        val open = step(Event.Migrate(usb)).only<Action.OpenCandidate>()
        assertEquals(usb, open.endpoint)
        val hs = step(Event.ControlOpened(open.gen))
        assertEquals(listOf<Action>(Action.SendCandidate(hello)), hs) // HELLO on the candidate, nothing on the session
        return open.gen
    }

    @Test fun successfulMigrationRetiresThenPromotesThenProvesFirst() {
        val old = streamingOnWifi()
        val cand = candidateOpen()
        assertTrue(m.migrating)
        assertTrue(m.inputAllowed) // the Wi-Fi session keeps working while the candidate handshakes

        val r = step(Event.Received(cand, ack(HelloAck.ACCEPTED, 78, 47002)))
        // Order: old video closed, old control retired (never a BYE, never a hard close), then the candidate is promoted,
        // then the proof PING goes out first, then the display/audio settings, then the UI stays Connected.
        val iVideo = r.indexOf(Action.CloseVideo)
        val iRetire = r.indexOf(Action.RetireControl)
        val iPromote = r.indexOfFirst { it is Action.PromoteCandidate }
        val sends = r.withIndex().filter { it.value is Action.Send }
        assertTrue(iVideo in 0 until iPromote && iRetire in 0 until iPromote)
        assertTrue(sends.first().index > iPromote)
        assertEquals(
            listOf(Ping::class.java, StreamPrefs::class.java, DisplayRate::class.java, AudioPrefs::class.java),
            sends.map { (it.value as Action.Send).msg.javaClass },
        )
        assertFalse(sends.any { (it.value as Action.Send).msg is Bye })
        assertFalse(r.has<Action.CloseControl>())
        assertEquals(Action.PromoteCandidate(cand, usb), r[iPromote])
        assertEquals(Action.MigrationResult(usb, true, SessionMachine.REASON_OK), r.last())
        assertEquals(listOf<SessionUi>(SessionUi.Connected("Mac mini", 0)), r.filterIsInstance<Action.Ui>().map { it.state })
        assertTrue(m.inputAllowed)
        assertFalse(m.migrating)
        assertEquals(78L, m.currentSessionId)

        // The old connection's late events are ignored.
        assertTrue(step(Event.ControlClosed(old)).isEmpty())
        assertTrue(step(Event.Received(old, Bye(Bye.SUPERSEDED))).isEmpty())

        // The new session's STREAM_CONFIG (sent by the host only after it superseded the old one) closes the retired one,
        // and video opens on the USB endpoint.
        val c = step(Event.Received(cand, cfg(1)))
        assertTrue(c.indexOf(Action.CloseRetired) in 0 until c.indexOfFirst { it is Action.ApplyConfig })
        assertEquals(Endpoint(usb.host, 47002), c.only<Action.OpenVideo>().endpoint)
        // the generation is the session now: its loss reconnects to USB
        val lost = step(Event.ControlClosed(cand))
        assertTrue(lost.filterIsInstance<Action.Ui>().single().state is SessionUi.Disconnected)
        assertEquals(usb, step(Event.Tick(0), 2_000_000).only<Action.OpenControl>().endpoint)
    }

    @Test fun retiredConnectionIsClosedAfterTimeoutWithoutStreamConfig() {
        streamingOnWifi()
        val cand = candidateOpen()
        step(Event.Received(cand, ack(HelloAck.ACCEPTED, 78, 47002)))
        assertFalse(step(Event.Tick(0), SessionMachine.RETIRE_TIMEOUT_US - 1).has<Action.CloseRetired>())
        assertTrue(step(Event.Tick(0), 1).has<Action.CloseRetired>())
        assertFalse(step(Event.Tick(0), 1_000_000).has<Action.CloseRetired>()) // once
    }

    @Test fun failedCandidateNeverTouchesTheSession() {
        val cases: List<Pair<(Int) -> Event, String>> = listOf(
            { g: Int -> Event.ControlClosed(g, connectFailed = true) } to SessionMachine.REASON_CONNECT_FAILED,
            { g: Int -> Event.ControlClosed(g) } to SessionMachine.REASON_CLOSED,
            { g: Int -> Event.ProtocolError(g) } to SessionMachine.REASON_PROTOCOL_ERROR,
            { g: Int -> Event.KeyMissing(g) } to SessionMachine.REASON_KEY,
            { g: Int -> Event.KeyStoreFailed(g) } to SessionMachine.REASON_KEY,
            { g: Int -> Event.Received(g, ack(HelloAck.BUSY)) } to "ack_${HelloAck.BUSY}",
            { g: Int -> Event.Received(g, ack(HelloAck.PENDING_APPROVAL)) } to "ack_${HelloAck.PENDING_APPROVAL}",
            { g: Int -> Event.Received(g, ack(HelloAck.REJECTED)) } to "ack_${HelloAck.REJECTED}",
            { g: Int -> Event.Received(g, Bye(Bye.NORMAL)) } to SessionMachine.REASON_CLOSED,
        )
        for ((event, reason) in cases) {
            val old = streamingOnWifi()
            val cand = candidateOpen()
            val r = step(event(cand))
            assertEquals(reason, listOf<Action>(Action.CloseCandidate, Action.MigrationResult(usb, false, reason)), r)
            assertTrue(reason, m.inputAllowed)
            assertFalse(reason, m.migrating)
            // the Wi-Fi session is intact: its pings go on, its messages are handled
            assertTrue(reason, step(Event.Tick(0), SessionMachine.PING_INTERVAL_US).any { it is Action.Send && it.msg is Ping })
            assertTrue(reason, step(Event.Received(old, cfg(2))).has<Action.ApplyConfig>())
            // a late ACCEPTED of the dead candidate does nothing
            assertTrue(reason, step(Event.Received(cand, ack(HelloAck.ACCEPTED, 9, 1))).isEmpty())
            step(Event.Stop)
        }
    }

    @Test fun candidateTimesOut() {
        val old = streamingOnWifi()
        val cand = candidateOpen()
        step(Event.Received(old, Pong(0, 0, 0)), 1_500_000) // the Wi-Fi session stays alive meanwhile
        assertFalse(step(Event.Tick(0), SessionMachine.MIGRATE_TIMEOUT_US - 1_500_000 - 1).has<Action.CloseCandidate>())
        val r = step(Event.Tick(0), 1)
        assertTrue(r.has<Action.CloseCandidate>())
        assertEquals(Action.MigrationResult(usb, false, SessionMachine.REASON_TIMEOUT), r.only<Action.MigrationResult>())
        assertTrue(m.inputAllowed)
        assertTrue(step(Event.Received(cand, ack(HelloAck.ACCEPTED, 9, 1))).isEmpty())
    }

    @Test fun migrateIsRefusedUnlessAcceptedAndOneAtATime() {
        assertEquals(
            listOf<Action>(Action.MigrationResult(usb, false, SessionMachine.REASON_NOT_CONNECTED)),
            step(Event.Migrate(usb)),
        )
        val gen = step(Event.Start(wifi)).only<Action.OpenControl>().gen
        step(Event.ControlOpened(gen))
        step(Event.Received(gen, ack(HelloAck.PENDING_APPROVAL)))
        assertEquals(SessionMachine.REASON_NOT_CONNECTED, step(Event.Migrate(usb)).only<Action.MigrationResult>().reason)
        step(Event.Received(gen, ack(HelloAck.ACCEPTED, 5, 47002)))
        assertEquals(SessionMachine.REASON_SAME_ENDPOINT, step(Event.Migrate(wifi)).only<Action.MigrationResult>().reason)
        val first = step(Event.Migrate(usb))
        assertTrue(first.has<Action.OpenCandidate>())
        val second = step(Event.Migrate(usb))
        assertEquals(listOf<Action>(Action.MigrationResult(usb, false, SessionMachine.REASON_IN_PROGRESS)), second)
        assertTrue(m.migrating) // the first one is still running
    }

    @Test fun sessionEndAbortsTheCandidateAndReportsIt() {
        // lost session
        var old = streamingOnWifi()
        candidateOpen()
        var r = step(Event.ControlClosed(old))
        assertTrue(r.indexOf(Action.CloseCandidate) >= 0)
        assertEquals(SessionMachine.REASON_SESSION_CLOSED, r.only<Action.MigrationResult>().reason)
        assertFalse(m.migrating)
        // stop
        old = streamingOnWifi()
        candidateOpen()
        r = step(Event.Stop)
        assertTrue(r.has<Action.CloseCandidate>())
        assertEquals(SessionMachine.REASON_SESSION_CLOSED, r.only<Action.MigrationResult>().reason)
        // a new start
        old = streamingOnWifi()
        candidateOpen()
        r = step(Event.Start(wifi))
        assertTrue(r.has<Action.CloseCandidate>() && r.has<Action.OpenControl>())
        assertEquals(SessionMachine.REASON_SESSION_CLOSED, r.only<Action.MigrationResult>().reason)
        // the PONG timeout of the old session
        old = streamingOnWifi()
        candidateOpen()
        r = step(Event.Tick(0), SessionMachine.PONG_TIMEOUT_US)
        assertTrue(r.has<Action.CloseCandidate>())
        assertTrue(r.filterIsInstance<Action.Ui>().single().state is SessionUi.Disconnected)
        assertTrue(old >= 0)
    }

    @Test fun stopAfterPromotionClosesRetiredAndCurrent() {
        streamingOnWifi()
        val cand = candidateOpen()
        step(Event.Received(cand, ack(HelloAck.ACCEPTED, 78, 47002)))
        val r = step(Event.Stop)
        assertTrue(r.has<Action.CloseRetired>())
        assertEquals(true, r.only<Action.CloseControl>().graceful) // BYE on the new (current) session
        assertTrue(r.any { it is Action.Send && it.msg == Bye(Bye.NORMAL) })
    }

    @Test fun backToBackMigrationsCloseTheEarlierRetiredFirst() {
        streamingOnWifi()
        val c1 = candidateOpen()
        step(Event.Received(c1, ack(HelloAck.ACCEPTED, 78, 47002)))
        // now on USB; migrate back to Wi-Fi before the first retired connection was closed
        val o2 = step(Event.Migrate(wifi)).only<Action.OpenCandidate>()
        step(Event.ControlOpened(o2.gen))
        val r = step(Event.Received(o2.gen, ack(HelloAck.ACCEPTED, 79, 47002)))
        val iClose = r.indexOf(Action.CloseRetired)
        val iRetire = r.indexOf(Action.RetireControl)
        assertTrue(iClose in 0 until iRetire)
        assertEquals(Action.PromoteCandidate(o2.gen, wifi), r.only<Action.PromoteCandidate>())
    }
}
