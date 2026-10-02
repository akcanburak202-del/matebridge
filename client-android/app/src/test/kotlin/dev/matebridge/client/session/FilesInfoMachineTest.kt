package dev.matebridge.client.session

import dev.matebridge.client.protocol.AudioPrefs
import dev.matebridge.client.protocol.Bytes
import dev.matebridge.client.protocol.FilesInfo
import dev.matebridge.client.protocol.Hello
import dev.matebridge.client.protocol.HelloAck
import dev.matebridge.client.protocol.Ping
import dev.matebridge.client.protocol.StreamPrefs
import dev.matebridge.client.session.SessionMachine.Action
import dev.matebridge.client.session.SessionMachine.Event
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** T-135: FILES_INFO goes out once per accepted session (after AUDIO_PREFS) and on change, never before approval. */
class FilesInfoMachineTest {
    private val hello = Hello(1, Bytes(ByteArray(16)), 2800, 1840, 360, 144, 0x7FF, "MatePad")
    private val ep = Endpoint("127.0.0.1", 7420)
    private val now = 1_000_000L
    private val ready = FilesInfo(FilesInfo.STATE_READY, 47010, "0123456789abcdef0123456789abcdef")

    private fun sends(a: List<Action>) = a.filterIsInstance<Action.Send>().map { it.msg }

    private fun open(m: SessionMachine): Int {
        val gen = m.handle(Event.Start(ep), now).filterIsInstance<Action.OpenControl>().single().gen
        m.handle(Event.ControlOpened(gen), now)
        return gen
    }

    private fun accept(m: SessionMachine, gen: Int) =
        m.handle(Event.Received(gen, HelloAck(1, HelloAck.ACCEPTED, 5, 7421, "Mac")), now)

    @Test fun sentOnceAfterAudioPrefsOnAccept() {
        val m = SessionMachine(hello, initialAudio = true, initialFiles = FilesInfo.OFF)
        val s = sends(accept(m, open(m)))
        assertEquals(
            listOf(Ping::class.java, StreamPrefs::class.java, AudioPrefs::class.java, FilesInfo::class.java),
            s.map { it.javaClass },
        )
        assertEquals(FilesInfo.OFF, s.last())
    }

    @Test fun neverSentWithoutFileServer() {
        val m = SessionMachine(hello) // initialFiles = null
        assertTrue(sends(accept(m, open(m))).none { it is FilesInfo })
        assertTrue(m.handle(Event.SetFiles(ready), now).isEmpty())
    }

    @Test fun changeBeforeApprovalIsRememberedAndSentOnAccept() {
        val m = SessionMachine(hello, initialFiles = FilesInfo.OFF)
        assertTrue(m.handle(Event.SetFiles(ready), now).isEmpty()) // idle
        val gen = open(m)
        assertTrue(m.handle(Event.SetFiles(ready), now).isEmpty()) // awaiting the ack
        assertEquals(ready, sends(accept(m, gen)).last())
    }

    @Test fun changesAreSentAndRepeatsAreNot() {
        val m = SessionMachine(hello, initialFiles = FilesInfo.OFF)
        accept(m, open(m))
        assertEquals(listOf(ready), sends(m.handle(Event.SetFiles(ready), now)))
        assertTrue(m.handle(Event.SetFiles(ready.copy()), now).isEmpty())
        val newToken = ready.copy(token = "ffffffffffffffffffffffffffffffff")
        assertEquals(listOf(newToken), sends(m.handle(Event.SetFiles(newToken), now)))
        assertEquals(listOf(FilesInfo.OFF), sends(m.handle(Event.SetFiles(FilesInfo.OFF), now)))
    }

    @Test fun everySessionGetsTheCurrentStateOnce() {
        val m = SessionMachine(hello, initialFiles = FilesInfo.OFF)
        accept(m, open(m))
        m.handle(Event.SetFiles(ready), now)
        m.handle(Event.Stop, now)
        assertEquals(ready, sends(accept(m, open(m))).last())
    }

    @Test fun tokenIsNotInToString() {
        assertFalse(ready.toString().contains(ready.token))
        assertFalse(Event.SetFiles(ready).toString().contains(ready.token))
    }
}
