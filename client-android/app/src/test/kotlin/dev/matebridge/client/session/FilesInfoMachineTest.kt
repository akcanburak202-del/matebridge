package dev.matebridge.client.session

import dev.matebridge.client.files.FilesServerScope
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

    private fun usbScope(gen: Int) = FilesServerScope(false, gen)

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
        assertTrue(m.handle(Event.SetFiles(ready, usbScope(1)), now).isEmpty())
    }

    @Test fun changeBeforeApprovalIsRememberedAndSentOnAccept() {
        val m = SessionMachine(hello, initialFiles = FilesInfo.OFF)
        assertTrue(m.handle(Event.SetFiles(FilesInfo.STANDBY, FilesServerScope.NONE), now).isEmpty()) // idle
        val gen = open(m)
        assertTrue(m.handle(Event.SetFiles(FilesInfo.STANDBY, FilesServerScope.NONE), now).isEmpty()) // awaiting the ack
        assertEquals(FilesInfo.STANDBY, sends(accept(m, gen)).last())
    }

    @Test fun changesAreSentAndRepeatsAreNot() {
        val m = SessionMachine(hello, initialFiles = FilesInfo.OFF)
        val gen = open(m)
        accept(m, gen)
        val scope = usbScope(gen) // the server of THIS connection
        assertEquals(listOf(ready), sends(m.handle(Event.SetFiles(ready, scope), now)))
        assertTrue(m.handle(Event.SetFiles(ready.copy(), scope), now).isEmpty())
        val newToken = ready.copy(token = "ffffffffffffffffffffffffffffffff")
        assertEquals(listOf(newToken), sends(m.handle(Event.SetFiles(newToken, scope), now)))
        assertEquals(listOf(FilesInfo.OFF), sends(m.handle(Event.SetFiles(FilesInfo.OFF, FilesServerScope.NONE), now)))
    }

    @Test fun aReadyOfAnotherSessionsServerIsAnnouncedAsOff() {
        val m = SessionMachine(hello, initialFiles = FilesInfo.OFF)
        val gen = open(m)
        accept(m, gen)
        assertEquals(listOf(FilesInfo.OFF), sends(m.handle(Event.SetFiles(ready, usbScope(gen - 1)), now)))
    }

    @Test fun everySessionGetsTheCurrentStateOnceButNeverAnEarlierSessionsReady() {
        val m = SessionMachine(hello, initialFiles = FilesInfo.OFF)
        val g1 = open(m)
        accept(m, g1)
        m.handle(Event.SetFiles(ready, usbScope(g1)), now)
        m.handle(Event.Stop, now)
        // the UI has not stopped that server yet: the new session still must not hear its READY and token
        assertEquals(FilesInfo.OFF, sends(accept(m, open(m))).last())
        // STANDBY is a state, not a server: it is republished
        val m2 = SessionMachine(hello, initialFiles = FilesInfo.OFF)
        accept(m2, open(m2))
        m2.handle(Event.SetFiles(FilesInfo.STANDBY, FilesServerScope.NONE), now)
        m2.handle(Event.Stop, now)
        assertEquals(FilesInfo.STANDBY, sends(accept(m2, open(m2))).last())
    }

    @Test fun tokenIsNotInToString() {
        assertFalse(ready.toString().contains(ready.token))
        assertFalse(Event.SetFiles(ready, usbScope(1)).toString().contains(ready.token))
    }
}
