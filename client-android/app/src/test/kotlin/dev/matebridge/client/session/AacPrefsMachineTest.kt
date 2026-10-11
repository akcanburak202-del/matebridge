package dev.matebridge.client.session

import dev.matebridge.client.protocol.AudioPrefs
import dev.matebridge.client.protocol.Bytes
import dev.matebridge.client.protocol.Capabilities
import dev.matebridge.client.protocol.Hello
import dev.matebridge.client.protocol.HelloAck
import dev.matebridge.client.protocol.Message
import dev.matebridge.client.protocol.StreamPrefs
import dev.matebridge.client.session.SessionMachine.Action
import dev.matebridge.client.session.SessionMachine.Event
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** T-341 (decision 0038 section 4): when AUDIO_PREFS asks for AAC. */
class AacPrefsMachineTest {
    private fun hello(aac: Boolean) =
        Hello(1, Bytes(ByteArray(16)), 2800, 1840, 360, 144, 0x7FFL or (if (aac) Capabilities.AUDIO_AAC.toLong() else 0L), "MatePad")

    private val ep = Endpoint("mac.example.ts.net", 47001)
    private val normal = StreamPrefs(120, 1000, 60_000)

    private fun sends(a: List<Action>): List<Message> = a.filterIsInstance<Action.Send>().map { it.msg }

    private fun audioSent(aac: Boolean, remote: RemoteProfile?): AudioPrefs {
        val m = SessionMachine(hello(aac), normal, initialAudio = true)
        val gen = m.handle(Event.Start(ep, remote = remote), 0).filterIsInstance<Action.OpenControl>().single().gen
        m.handle(Event.ControlOpened(gen), 0)
        val s = sends(m.handle(Event.Received(gen, HelloAck(1, HelloAck.ACCEPTED, 5, 7421, "Mac")), 0))
        return s.filterIsInstance<AudioPrefs>().single()
    }

    @Test fun remoteSessionWithAudioAsksForAacOnlyWithBit14() {
        assertEquals(AudioPrefs(true, AudioPrefs.CODEC_AAC), audioSent(aac = true, remote = RemoteProfile(1000, audio = true)))
        assertEquals(AudioPrefs(true, AudioPrefs.CODEC_PCM), audioSent(aac = false, remote = RemoteProfile(1000, audio = true)))
    }

    @Test fun remoteSessionWithAudioOffStaysPcm() {
        assertEquals(AudioPrefs(false, AudioPrefs.CODEC_PCM), audioSent(aac = true, remote = RemoteProfile(1000, audio = false)))
    }

    @Test fun normalSessionIsAlwaysPcm() {
        assertEquals(AudioPrefs(true, AudioPrefs.CODEC_PCM), audioSent(aac = true, remote = null))
    }

    @Test fun turningRemoteAudioOnMidSessionSendsAac() {
        val m = SessionMachine(hello(true), normal, initialAudio = true)
        val gen = m.handle(Event.Start(ep, remote = RemoteProfile(1000, audio = false)), 0).filterIsInstance<Action.OpenControl>().single().gen
        m.handle(Event.ControlOpened(gen), 0)
        m.handle(Event.Received(gen, HelloAck(1, HelloAck.ACCEPTED, 5, 7421, "Mac")), 0)
        val s = sends(m.handle(Event.SetRemote(RemoteProfile(1000, audio = true)), 1_000))
        assertTrue(s.contains(AudioPrefs(true, AudioPrefs.CODEC_AAC)))
    }
}
