package dev.matebridge.client.session

import dev.matebridge.client.protocol.Bytes
import dev.matebridge.client.protocol.Hello
import dev.matebridge.client.protocol.HelloAck
import dev.matebridge.client.protocol.StreamConfig
import dev.matebridge.client.session.SessionMachine.Action
import dev.matebridge.client.session.SessionMachine.Event
import dev.matebridge.client.session.TransportSwitch.MigrationVerdict
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * T-105 review: a connection-mode choice made during an AUTO Wi-Fi -> USB migration cancels it, and a migration that is
 * promoted anyway is rejected when it no longer fits the chosen mode.
 */
class MigrationCancelTest {
    private val hello = Hello(0, Bytes(ByteArray(16)), 2800, 1840, 360, 144, 0xFF, "MatePad")
    private val wifi = Endpoint("10.0.0.5", 47001)
    private val usb = ConnectMode.usbEndpoint
    private val m = SessionMachine(hello)
    private var now = 1_000_000L

    private fun step(e: Event): List<Action> = m.handle(e, now)
    private fun ack() = HelloAck(0, HelloAck.ACCEPTED, 78, 47002, "Mac mini")

    private fun streamingOnWifiWithCandidate(): Pair<Int, Int> {
        val gen = step(Event.Start(wifi)).filterIsInstance<Action.OpenControl>().single().gen
        step(Event.ControlOpened(gen))
        step(Event.Received(gen, ack()))
        step(Event.Received(gen, StreamConfig(1, 2, 2800, 1840, 1400, 920, 60, 20000, 1, 1, 1, 1)))
        val cand = step(Event.Migrate(usb)).filterIsInstance<Action.OpenCandidate>().single().gen
        step(Event.ControlOpened(cand))
        return gen to cand
    }

    @Test fun cancelClosesTheCandidateAndALateAcceptIsIgnored() {
        val (_, cand) = streamingOnWifiWithCandidate()
        assertTrue(m.migrating)
        val r = step(Event.CancelMigration)
        assertEquals(listOf(Action.CloseCandidate, Action.MigrationResult(usb, false, SessionMachine.REASON_CANCELLED)), r)
        assertFalse(m.migrating)
        assertTrue(m.inputAllowed) // the Wi-Fi session is untouched
        // the host's ACCEPTED for the dropped candidate arrives late: nothing is promoted
        val late = step(Event.Received(cand, ack()))
        assertFalse(late.any { it is Action.PromoteCandidate || it is Action.RetireControl })
    }

    @Test fun cancelWithoutCandidateOrAfterPromotionDoesNothing() {
        assertTrue(step(Event.CancelMigration).isEmpty())
        val (_, cand) = streamingOnWifiWithCandidate()
        assertTrue(step(Event.Received(cand, ack())).any { it is Action.PromoteCandidate })
        assertTrue(step(Event.CancelMigration).isEmpty()) // too late: the UI rejects the result instead
    }

    @Test fun transportChoiceCancelsAndChecksMigrations() {
        assertFalse(TransportSwitch.cancelsMigration(TransportMode.AUTO))
        assertTrue(TransportSwitch.cancelsMigration(TransportMode.WIFI))
        assertTrue(TransportSwitch.cancelsMigration(TransportMode.USB))
        // a migration promoted after "Yalnız Wi-Fi" was chosen is rejected: reconnect under the chosen mode
        assertEquals(MigrationVerdict.REJECT_RECONNECT, TransportSwitch.onMigrated(TransportMode.WIFI, Transport.USB))
        assertEquals(MigrationVerdict.ACCEPT, TransportSwitch.onMigrated(TransportMode.AUTO, Transport.USB))
        assertEquals(MigrationVerdict.ACCEPT, TransportSwitch.onMigrated(TransportMode.USB, Transport.USB))
        assertEquals(MigrationVerdict.REJECT_RECONNECT, TransportSwitch.onMigrated(TransportMode.USB, Transport.WIFI))
    }
}
