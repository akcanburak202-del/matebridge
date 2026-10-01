package dev.matebridge.client.session

import dev.matebridge.client.protocol.AudioPrefs
import dev.matebridge.client.protocol.Bytes
import dev.matebridge.client.protocol.DisplayRate
import dev.matebridge.client.protocol.Hello
import dev.matebridge.client.protocol.HelloAck
import dev.matebridge.client.protocol.Ping
import dev.matebridge.client.protocol.StreamConfig
import dev.matebridge.client.protocol.StreamPrefs
import dev.matebridge.client.session.SessionMachine.Action
import dev.matebridge.client.session.SessionMachine.Event
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** T-095: AUDIO_PREFS goes out after ACCEPTED (after the display messages) and on change, never before approval. */
class AudioPrefsMachineTest {
    private val hello = Hello(1, Bytes(ByteArray(16)), 2800, 1840, 360, 144, 0x1FF, "MatePad")
    private val ep = Endpoint("10.0.0.5", 7420)
    private val now = 1_000_000L

    private fun sends(a: List<Action>) = a.filterIsInstance<Action.Send>().map { it.msg }

    private fun accept(m: SessionMachine): List<Action> {
        val gen = m.handle(Event.Start(ep), now).filterIsInstance<Action.OpenControl>().single().gen
        m.handle(Event.ControlOpened(gen), now)
        return m.handle(Event.Received(gen, HelloAck(1, HelloAck.ACCEPTED, 5, 7421, "Mac")), now)
    }

    @Test fun sentAfterDisplayMessagesOnAccept() {
        val m = SessionMachine(hello, initialAudio = true)
        m.handle(Event.SetDisplayRate(120), now)
        val s = sends(accept(m))
        assertEquals(
            listOf(Ping::class.java, StreamPrefs::class.java, DisplayRate::class.java, AudioPrefs::class.java),
            s.map { it.javaClass },
        )
        assertEquals(AudioPrefs(true), s.last())
    }

    @Test fun disabledSettingIsSentAsZero() {
        val m = SessionMachine(hello, initialAudio = false)
        assertEquals(AudioPrefs(false), sends(accept(m)).last())
    }

    @Test fun neverSentWithoutAudioSupport() {
        val m = SessionMachine(hello) // initialAudio = null
        assertTrue(sends(accept(m)).none { it is AudioPrefs })
        assertTrue(m.handle(Event.SetAudio(true), now).isEmpty())
    }

    @Test fun changeIsSentWhenAcceptedAndRememberedOtherwise() {
        val m = SessionMachine(hello, initialAudio = true)
        assertTrue(m.handle(Event.SetAudio(false), now).isEmpty()) // not connected: remembered
        val gen = m.handle(Event.Start(ep), now).filterIsInstance<Action.OpenControl>().single().gen
        m.handle(Event.ControlOpened(gen), now)
        assertTrue(m.handle(Event.SetAudio(true), now).isEmpty()) // awaiting the ack: remembered
        val acc = m.handle(Event.Received(gen, HelloAck(1, HelloAck.ACCEPTED, 5, 7421, "Mac")), now)
        assertEquals(AudioPrefs(true), sends(acc).last())
        assertEquals(listOf<Any>(AudioPrefs(false)), sends(m.handle(Event.SetAudio(false), now)))
        assertTrue(m.handle(Event.SetAudio(false), now).isEmpty()) // unchanged
        m.handle(Event.Received(gen, StreamConfig(1, 1, 2800, 1840, 1400, 920, 60, 20000, 1, 1, 1, 1)), now)
        assertEquals(listOf<Any>(AudioPrefs(true)), sends(m.handle(Event.SetAudio(true), now))) // streaming too
    }

    @Test fun resentOnEveryConnection() {
        val m = SessionMachine(hello, initialAudio = true)
        repeat(2) { assertEquals(AudioPrefs(true), sends(accept(m)).last()) }
    }
}
