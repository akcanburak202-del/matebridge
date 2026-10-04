package dev.matebridge.client.session

import dev.matebridge.client.protocol.Bytes
import dev.matebridge.client.protocol.Hello
import dev.matebridge.client.protocol.HelloAck
import dev.matebridge.client.session.SessionMachine.Action
import dev.matebridge.client.session.SessionMachine.Event
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * T-227 (review #1): a start with `expectHost` (rediscovery after the Mac's address changed) refuses any other host at
 * its first answer, before HELLO_ACK, so no session state (clipboard, files, input) is ever enabled for it.
 */
class WrongHostGateTest {
    private val hello = Hello(0, Bytes(ByteArray(16) { it.toByte() }), 2800, 1840, 360, 144, 0xFF, "MatePad")
    private val candidate = Endpoint("192.168.1.106", 47001)
    private val idA = ByteArray(16) { (0x40 + it).toByte() }
    private val idB = ByteArray(16) { (0x70 + it).toByte() }
    private val tagA = HostTag.of(idA)!!
    private val logs = ArrayList<String>()
    private val m = SessionMachine(hello, recordAuthenticated = { false }) { level, ev, fields -> logs += "$level $ev $fields" }
    private var now = 1_000_000L
    private val wrongHost = SessionUi.Failed(SessionUi.Cause.WRONG_HOST)

    private fun step(e: Event, advanceUs: Long = 0): List<Action> {
        now += advanceUs
        return m.handle(e, now)
    }

    private fun List<Action>.ui() = filterIsInstance<Action.Ui>().map { it.state }
    private fun genOf(a: List<Action>) = a.filterIsInstance<Action.OpenControl>().single().gen
    private fun ack() = HelloAck(0, HelloAck.ACCEPTED, 77, 7421, "Mac mini")

    private fun start(expect: HostTag?): Int {
        val gen = genOf(step(Event.Start(candidate, expectHost = expect)))
        step(Event.ControlOpened(gen))
        return gen
    }

    private fun assertNoReconnect() {
        repeat(5) { assertFalse(step(Event.Tick(0), 10_000_000).any { it is Action.OpenControl }) }
    }

    @Test fun anotherPairedHostIsRefusedBeforeItsAck() {
        val gen = start(expect = tagA)
        val key = ByteArray(32) { 9 }
        val r = step(Event.Secured(gen, null, false, Bytes(idB.copyOf()), Bytes(key)))
        assertEquals(listOf<SessionUi>(wrongHost), r.ui())
        assertEquals(false, r.filterIsInstance<Action.CloseControl>().single().graceful)
        assertTrue(key.all { it == 0.toByte() }) // a handed-over key is wiped, never kept
        // Its HELLO_ACK (already in flight) belongs to a closed connection: no Connected, nothing sent.
        val late = step(Event.Received(gen, ack()))
        assertTrue(late.ui().isEmpty())
        assertFalse(late.any { it is Action.Send })
        assertNoReconnect()
        assertTrue(logs.contains("W wrong_host "))
    }

    @Test fun theExpectedHostConnectsAsUsual() {
        val gen = start(expect = tagA)
        assertTrue(step(Event.Secured(gen, null, false, Bytes(idA.copyOf()))).ui().isEmpty())
        val r = step(Event.Received(gen, ack()))
        assertTrue(r.ui().any { it is SessionUi.Connected })
    }

    @Test fun aMissingHostIdIsNotTheExpectedHost() {
        val gen = start(expect = tagA)
        assertEquals(listOf<SessionUi>(wrongHost), step(Event.Secured(gen, null, false, null)).ui())
    }

    @Test fun anotherMacAskingToPairIsRefusedButOurOwnHostGetsThePrompt() {
        var gen = start(expect = tagA)
        assertEquals(listOf<SessionUi>(wrongHost), step(Event.PairingNeedsUser(gen, "Other", false, Bytes(idB.copyOf()))).ui())
        gen = start(expect = tagA)
        val r = step(Event.PairingNeedsUser(gen, "Mac mini", true, Bytes(idA.copyOf()))).ui()
        assertEquals(1, r.size)
        assertTrue(r.single() is SessionUi.PairingNeedsUser)
    }

    @Test fun automaticRetriesKeepTheGate() {
        var gen = start(expect = tagA)
        step(Event.Secured(gen, null, false, Bytes(idA.copyOf())))
        step(Event.Received(gen, ack()))
        assertTrue(step(Event.ControlClosed(gen)).ui().single() is SessionUi.Disconnected)
        gen = genOf(step(Event.Tick(0), SessionMachine.BACKOFF_MAX_US))
        step(Event.ControlOpened(gen))
        assertEquals(listOf<SessionUi>(wrongHost), step(Event.Secured(gen, null, false, Bytes(idB.copyOf()))).ui())
    }

    @Test fun withoutAnExpectationAnyHostIsAcceptedAsBefore() {
        step(Event.Start(candidate, expectHost = tagA))
        step(Event.Stop)
        val gen = start(expect = null)
        assertTrue(step(Event.Secured(gen, null, false, Bytes(idB.copyOf()))).ui().isEmpty())
        assertTrue(step(Event.Received(gen, ack())).ui().any { it is SessionUi.Connected })
    }
}
