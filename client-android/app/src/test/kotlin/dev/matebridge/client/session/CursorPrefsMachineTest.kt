package dev.matebridge.client.session

import dev.matebridge.client.protocol.AudioPrefs
import dev.matebridge.client.protocol.Bytes
import dev.matebridge.client.protocol.CursorPrefs
import dev.matebridge.client.protocol.Hello
import dev.matebridge.client.protocol.HelloAck
import dev.matebridge.client.protocol.Ping
import dev.matebridge.client.protocol.StreamConfig
import dev.matebridge.client.protocol.StreamPrefs
import dev.matebridge.client.session.SessionMachine.Action
import dev.matebridge.client.session.SessionMachine.Event
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** T-276 (decision 0036): CURSOR_PREFS goes out after ACCEPTED and on change, never before approval and never without support. */
class CursorPrefsMachineTest {
    private val hello = Hello(1, Bytes(ByteArray(16)), 2800, 1840, 360, 144, 0x3FFF, "MatePad")
    private val ep = Endpoint("10.0.0.5", 7420)
    private val now = 1_000_000L

    private fun sends(a: List<Action>) = a.filterIsInstance<Action.Send>().map { it.msg }

    private fun open(m: SessionMachine): Int {
        val gen = m.handle(Event.Start(ep), now).filterIsInstance<Action.OpenControl>().single().gen
        m.handle(Event.ControlOpened(gen), now)
        return gen
    }

    private fun accept(m: SessionMachine): List<Action> {
        val gen = open(m)
        return m.handle(Event.Received(gen, HelloAck(1, HelloAck.ACCEPTED, 5, 7421, "Mac")), now)
    }

    @Test fun sentRightAfterTheSettingsOnAccept() {
        val m = SessionMachine(hello, initialAudio = true, initialCursor = true)
        val s = sends(accept(m))
        assertEquals(
            listOf(Ping::class.java, StreamPrefs::class.java, AudioPrefs::class.java, CursorPrefs::class.java),
            s.map { it.javaClass },
        )
        assertEquals(CursorPrefs(true), s.last())
    }

    @Test fun disabledWishIsSentAsZeroToo() {
        assertEquals(CursorPrefs(false), sends(accept(SessionMachine(hello, initialCursor = false))).last())
    }

    @Test fun neverSentWithoutSupport() {
        val m = SessionMachine(hello) // initialCursor = null
        assertTrue(sends(accept(m)).none { it is CursorPrefs })
        assertTrue(m.handle(Event.SetCursor(true), now).isEmpty())
    }

    @Test fun nothingGoesOutBeforeTheSessionIsAcceptedButTheValueIsRemembered() {
        val m = SessionMachine(hello, initialCursor = true)
        assertTrue(m.handle(Event.SetCursor(false), now).isEmpty()) // not connected: remembered
        val gen = open(m)
        assertTrue(m.handle(Event.SetCursor(true), now).isEmpty()) // awaiting the ack: remembered
        val acc = m.handle(Event.Received(gen, HelloAck(1, HelloAck.ACCEPTED, 5, 7421, "Mac")), now)
        assertEquals(CursorPrefs(true), sends(acc).last())
    }

    @Test fun aChangeIsSentOnceAndARepeatIsNot() {
        val m = SessionMachine(hello, initialCursor = true)
        val gen = open(m)
        m.handle(Event.Received(gen, HelloAck(1, HelloAck.ACCEPTED, 5, 7421, "Mac")), now)
        assertEquals(listOf<Any>(CursorPrefs(false)), sends(m.handle(Event.SetCursor(false), now)))
        assertTrue(m.handle(Event.SetCursor(false), now).isEmpty()) // the host already has it
        m.handle(Event.Received(gen, StreamConfig(1, 1, 2800, 1840, 1400, 920, 60, 20000, 1, 1, 1, 1)), now)
        assertEquals(listOf<Any>(CursorPrefs(true)), sends(m.handle(Event.SetCursor(true), now))) // streaming too
    }

    @Test fun theLatestValueStartsTheNextSession() {
        val m = SessionMachine(hello, initialCursor = true)
        assertEquals(CursorPrefs(true), sends(accept(m)).last())
        m.handle(Event.SetCursor(false), now) // e.g. the timeout fell back, or Oyun was chosen
        m.handle(Event.Stop, now)
        assertEquals(CursorPrefs(false), sends(accept(m)).last())
    }

    @Test fun gateForTheReader() {
        assertTrue(SessionMachine.deliversCursor(3, 3))
        assertFalse(SessionMachine.deliversCursor(-1, 3)) // nothing accepted
        assertFalse(SessionMachine.deliversCursor(2, 3)) // another generation
    }
}
