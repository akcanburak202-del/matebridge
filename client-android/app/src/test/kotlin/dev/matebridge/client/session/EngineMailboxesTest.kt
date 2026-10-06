package dev.matebridge.client.session

import dev.matebridge.client.protocol.Bytes
import dev.matebridge.client.protocol.CursorPrefs
import dev.matebridge.client.protocol.Hello
import dev.matebridge.client.protocol.HelloAck
import dev.matebridge.client.protocol.StreamPrefs
import dev.matebridge.client.session.SessionMachine.Action
import dev.matebridge.client.session.SessionMachine.Event
import dev.matebridge.client.stream.StreamMode
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** T-276 review: switching to Oyun sends CURSOR_PREFS(0) before STREAM_PREFS (PROTOCOL.md 0x0D), whatever the engine's timing. */
class EngineMailboxesTest {
    private val oyun = StreamMode.GAME.toPrefs()

    @Test fun aPendingCursorWishIsDrainedBeforeAPendingDisplayMode() {
        // MainActivity.setStreamMode posts the cursor wish first, then STREAM_PREFS; the engine may wake after both.
        val m = EngineMailboxes()
        m.cursor.post(Event.SetCursor(false))
        m.prefs.post(Event.SetPrefs(oyun))
        assertEquals(Event.SetCursor(false), m.take())
        assertEquals(Event.SetPrefs(oyun), m.take())
        assertNull(m.take())
    }

    @Test fun theCursorWishStillComesFirstWhenTheOlderDisplayModeWasPostedEarlier() {
        val m = EngineMailboxes()
        m.prefs.post(Event.SetPrefs(oyun))
        m.cursor.post(Event.SetCursor(false))
        assertEquals(Event.SetCursor(false), m.take())
        assertEquals(Event.SetPrefs(oyun), m.take())
    }

    @Test fun theOtherCommandsKeepTheirOrder() {
        val m = EngineMailboxes()
        m.migrate.post(Event.CancelMigration)
        m.files.post(Event.ForgetFilesNet(1))
        m.audio.post(Event.SetAudio(true))
        m.rate.post(Event.SetDisplayRate(120))
        m.prefs.post(Event.SetPrefs(oyun))
        m.promptVisible.post(Event.ConfirmPromptVisible(true))
        m.expect.post(Event.ForgetHost)
        m.intent.post(Event.Stop)
        m.trust.post(Event.ForgetHost)
        val order = generateSequence { m.take() }.map { it.javaClass.simpleName }.toList()
        assertEquals(
            listOf(
                "ForgetHost", "Stop", "ForgetHost", "ConfirmPromptVisible", "SetPrefs", "SetDisplayRate", "SetAudio",
                "ForgetFilesNet", "CancelMigration",
            ),
            order,
        )
    }

    @Test fun theMachineSendsCursorPrefsZeroBeforeStreamPrefsInThatOrder() {
        val hello = Hello(1, Bytes(ByteArray(16)), 2800, 1840, 360, 144, 0x3FFF, "MatePad")
        val ep = Endpoint("10.0.0.5", 7420)
        val m = SessionMachine(hello, initialCursor = true)
        val gen = m.handle(Event.Start(ep), 1L).filterIsInstance<Action.OpenControl>().single().gen
        m.handle(Event.ControlOpened(gen), 1L)
        m.handle(Event.Received(gen, HelloAck(1, HelloAck.ACCEPTED, 5, 7421, "Mac")), 1L)
        val mail = EngineMailboxes()
        mail.cursor.post(Event.SetCursor(false))
        mail.prefs.post(Event.SetPrefs(oyun))
        val sent = ArrayList<Any>()
        while (true) {
            val e = mail.take() ?: break
            m.handle(e, 2L).filterIsInstance<Action.Send>().forEach { sent += it.msg }
        }
        assertEquals(listOf<Any>(CursorPrefs(false), oyun), sent)
    }
}
