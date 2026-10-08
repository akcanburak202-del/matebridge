package dev.matebridge.client.session

import dev.matebridge.client.protocol.Bytes
import dev.matebridge.client.protocol.CursorPrefs
import dev.matebridge.client.protocol.Hello
import dev.matebridge.client.protocol.HelloAck
import dev.matebridge.client.session.SessionMachine.Action
import dev.matebridge.client.session.SessionMachine.Event
import dev.matebridge.client.stream.StreamMode
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** T-276 review: switching to Oyun sends CURSOR_PREFS(0) before STREAM_PREFS (PROTOCOL.md 0x0D), whatever the engine's timing. */
class EngineMailboxesTest {
    private val oyun = StreamMode.GAME.toPrefs()
    private val daily = StreamMode.DAILY.toPrefs()

    private val hello = Hello(1, Bytes(ByteArray(16)), 2800, 1840, 360, 144, 0x3FFF, "MatePad")
    private val ep = Endpoint("10.0.0.5", 7420)

    private fun acceptedMachine(): SessionMachine {
        val m = SessionMachine(hello, initialCursor = true)
        val gen = m.handle(Event.Start(ep), 1L).filterIsInstance<Action.OpenControl>().single().gen
        m.handle(Event.ControlOpened(gen), 1L)
        m.handle(Event.Received(gen, HelloAck(1, HelloAck.ACCEPTED, 5, 7421, "Mac")), 1L)
        return m
    }

    private fun wire(m: SessionMachine, events: List<Event>): List<Any> =
        events.flatMap { m.handle(it, 2L) }.filterIsInstance<Action.Send>().map { it.msg }

    @Test fun cursorWishAndDisplayModeArePublishedAsOneOrderedCommand() {
        val box = EngineMailboxes()
        box.mode.setCursor(false) // MainActivity.setStreamMode: the cursor wish first,
        box.mode.setPrefs(oyun) // then the display mode
        assertEquals(Event.SetMode(false, oyun), box.take())
        assertNull(box.take())
    }

    /** T-294 review round 3: the retry tap's reset is a mail slot, so it is never dropped and repeats coalesce. */
    @Test fun theVideoBackoffResetIsAMailSlotThatIsNeverDropped() {
        val box = EngineMailboxes()
        box.videoBackoff.post(Event.ResetVideoBackoff)
        box.videoBackoff.post(Event.ResetVideoBackoff)
        assertEquals(Event.ResetVideoBackoff, box.take())
        assertNull(box.take())
    }

    @Test fun anEngineThatLookedBeforeThePostsSeesBothTogetherOrTheCursorFirst() {
        // The engine's check finds nothing; the UI posts afterwards; the next take gets the whole command, never prefs alone.
        val box = EngineMailboxes()
        assertNull(box.take())
        box.mode.setCursor(false)
        box.mode.setPrefs(oyun)
        assertEquals(Event.SetMode(false, oyun), box.take())
        // ...or the engine takes right between the two posts: the cursor part goes alone, the display mode follows.
        box.mode.setCursor(false)
        assertEquals(Event.SetMode(false, null), box.take())
        box.mode.setPrefs(oyun)
        assertEquals(Event.SetMode(null, oyun), box.take())
    }

    @Test fun aPostThatRacesAnotherTakeMergesInsteadOfLosingAPart() {
        // Deterministic interleaving: the UI read the pending command, then the engine took it, then the UI published.
        val box = EngineMailboxes()
        box.mode.setCursor(false)
        var taken: Event? = null
        box.mode.merge(null, oyun) { if (taken == null) taken = box.take() } // the engine wins the race once
        assertEquals(Event.SetMode(false, null), taken) // it saw the cursor part only, before the display mode
        assertEquals(Event.SetMode(null, oyun), box.take()) // the retry published the display mode alone: nothing lost
    }

    @Test fun aPostThatRacesAnotherPostKeepsBothParts() {
        val box = EngineMailboxes()
        var other = false
        box.mode.merge(false, null) { if (!other) { other = true; box.mode.setPrefs(oyun) } }
        assertEquals(Event.SetMode(false, oyun), box.take())
    }

    @Test fun theNewestValueOfEachPartWinsAndAPartNotPostedAgainStays() {
        val box = EngineMailboxes()
        box.mode.setCursor(false)
        box.mode.setPrefs(oyun)
        box.mode.setPrefs(daily)
        box.mode.setCursor(true)
        assertEquals(Event.SetMode(true, daily), box.take())
        box.mode.setPrefs(oyun) // no cursor part now: nothing to send for it
        assertEquals(Event.SetMode(null, oyun), box.take())
    }

    @Test fun theOtherCommandsKeepTheirOrder() {
        val m = EngineMailboxes()
        m.migrate.post(Event.CancelMigration)
        m.files.post(Event.ForgetFilesNet(1))
        m.audio.post(Event.SetAudio(true))
        m.rate.post(Event.SetDisplayRate(120))
        m.mode.setPrefs(oyun)
        m.promptVisible.post(Event.ConfirmPromptVisible(true))
        m.expect.post(Event.ForgetHost)
        m.intent.post(Event.Stop)
        m.trust.post(Event.ForgetHost)
        val order = generateSequence { m.take() }.map { it.javaClass.simpleName }.toList()
        assertEquals(
            listOf(
                "ForgetHost", "Stop", "ForgetHost", "ConfirmPromptVisible", "SetMode", "SetDisplayRate", "SetAudio",
                "ForgetFilesNet", "CancelMigration",
            ),
            order,
        )
    }

    @Test fun theMachineSendsCursorPrefsZeroBeforeStreamPrefsFromOneCommand() {
        val m = acceptedMachine()
        assertEquals(listOf<Any>(CursorPrefs(false), oyun), wire(m, listOf(Event.SetMode(false, oyun))))
    }

    @Test fun theMachineSendsCursorPrefsZeroBeforeStreamPrefsEvenWhenTheEngineTookBetweenThePosts() {
        val box = EngineMailboxes()
        val m = acceptedMachine()
        box.mode.setCursor(false)
        val first = box.take()!!
        box.mode.setPrefs(oyun)
        val second = box.take()!!
        assertEquals(listOf<Any>(CursorPrefs(false), oyun), wire(m, listOf(first, second)))
    }

    @Test fun setModeWithOnePartIsTheSameAsThatEvent() {
        val m = acceptedMachine()
        assertEquals(listOf<Any>(oyun), wire(m, listOf(Event.SetMode(null, oyun))))
        assertEquals(listOf<Any>(CursorPrefs(false)), wire(m, listOf(Event.SetMode(false, null))))
        assertEquals(emptyList<Any>(), wire(m, listOf(Event.SetMode(false, oyun)))) // both already held by the host
    }
}
