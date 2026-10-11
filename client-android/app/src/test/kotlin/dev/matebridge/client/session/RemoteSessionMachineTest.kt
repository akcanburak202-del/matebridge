package dev.matebridge.client.session

import dev.matebridge.client.files.FilesServerScope
import dev.matebridge.client.protocol.AudioPrefs
import dev.matebridge.client.protocol.Bytes
import dev.matebridge.client.protocol.Codec
import dev.matebridge.client.protocol.FilesInfo
import dev.matebridge.client.protocol.FixtureTest
import dev.matebridge.client.protocol.Hello
import dev.matebridge.client.protocol.HelloAck
import dev.matebridge.client.protocol.Message
import dev.matebridge.client.protocol.Ping
import dev.matebridge.client.protocol.Pong
import dev.matebridge.client.protocol.StreamPrefs
import dev.matebridge.client.session.SessionMachine.Action
import dev.matebridge.client.session.SessionMachine.Event
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** T-339 (decision 0038): the remote session's profile, PING cadence, PONG timeout and isolation from the normal settings. */
class RemoteSessionMachineTest {
    private val hello = Hello(1, Bytes(ByteArray(16)), 2800, 1840, 360, 144, 0x7FF, "MatePad")
    private val ep = Endpoint("mac.example.ts.net", 47001)
    private val normal = StreamPrefs(120, 1000, 60_000)
    private val profile = RemoteProfile(1000, audio = false)
    private val ms = 1000L

    private fun sends(a: List<Action>): List<Message> = a.filterIsInstance<Action.Send>().map { it.msg }

    private fun machine(inputActive: (Long) -> Boolean = { true }, audio: Boolean? = true, files: FilesInfo? = null) =
        SessionMachine(hello, normal, initialAudio = audio, initialFiles = files, inputActive = inputActive)

    private fun start(m: SessionMachine, now: Long, remote: RemoteProfile?): Int {
        val gen = m.handle(Event.Start(ep, remote = remote), now).filterIsInstance<Action.OpenControl>().single().gen
        m.handle(Event.ControlOpened(gen), now)
        return gen
    }

    private fun accept(m: SessionMachine, gen: Int, now: Long) =
        m.handle(Event.Received(gen, HelloAck(1, HelloAck.ACCEPTED, 5, 7421, "Mac")), now)

    @Test fun remoteStreamPrefsMatchTheFixtureAndTheNormalSessionKeepsItsBytes() {
        assertArrayEquals(FixtureTest.fixture("stream_prefs_remote"), Codec.encode(profile.streamPrefs()))
        assertEquals(StreamPrefs(15, 1000, 1000, 1400, 920, 0, 0, 1), profile.streamPrefs())

        val r = machine()
        val rs = sends(accept(r, start(r, 0, profile), 0))
        assertEquals(profile.streamPrefs(), rs[1])
        assertEquals(AudioPrefs(false, AudioPrefs.CODEC_PCM), rs[2]) // remote audio defaults off
        // the normal session of the same machine is unchanged (no link group, the user's own prefs)
        val n = machine()
        val ns = sends(accept(n, start(n, 0, null), 0))
        assertEquals(normal, ns[1])
        assertEquals(0, (ns[1] as StreamPrefs).link)
        assertEquals(AudioPrefs(true), ns[2])
        assertEquals(8 + 4 + 2 + 2, Codec.encodePayload(profile.streamPrefs()).size)
    }

    @Test fun remoteAudioDefaultsOffAndTheProfileChangeIsSentOnlyInARemoteSession() {
        assertFalse(RemoteProfile().audio)
        assertFalse(Settings(object : KeyValueStore {
            override fun getString(key: String): String? = null
            override fun putString(key: String, value: String) {}
        }).remoteAudio())
        val m = machine()
        val gen = start(m, 0, profile)
        accept(m, gen, 0)
        assertEquals(
            listOf<Message>(RemoteProfile(500, false).streamPrefs()),
            sends(m.handle(Event.SetRemote(RemoteProfile(500, false)), 1_000)),
        )
        assertEquals(
            listOf<Message>(AudioPrefs(true, AudioPrefs.CODEC_PCM)),
            sends(m.handle(Event.SetRemote(RemoteProfile(500, true)), 2_000)),
        )
        assertTrue(m.handle(Event.SetRemote(RemoteProfile(500, true)), 3_000).isEmpty())
        // a normal session ignores the remote profile
        val n = machine()
        accept(n, start(n, 0, null), 0)
        assertTrue(n.handle(Event.SetRemote(RemoteProfile(500, true)), 1_000).isEmpty())
    }

    @Test fun normalPrefsAndAudioChangesDuringARemoteSessionAreRememberedNotSent() {
        val m = machine()
        accept(m, start(m, 0, profile), 0)
        assertTrue(sends(m.handle(Event.SetPrefs(StreamPrefs(60, 1000, 0)), 1_000)).isEmpty())
        assertTrue(sends(m.handle(Event.SetAudio(false), 1_000)).isEmpty())
        // the next normal session starts with the remembered choices
        val gen = start(m, 5_000_000, null)
        val s = sends(accept(m, gen, 5_000_000))
        assertEquals(StreamPrefs(60, 1000, 0), s[1])
        assertEquals(AudioPrefs(false), s[2])
    }

    @Test fun filesInfoIsOffInARemoteSession() {
        val ready = FilesInfo(FilesInfo.STATE_READY, 47010, "0123456789abcdef0123456789abcdef")
        val m = machine(files = FilesInfo.OFF)
        val gen = start(m, 0, profile)
        val s = sends(accept(m, gen, 0))
        assertEquals(FilesInfo.OFF, s.last())
        // the server comes up later: the Mac is still told OFF
        val sent = sends(m.handle(Event.SetFiles(ready, FilesServerScope(false, gen)), 1_000))
        assertTrue(sent.all { it == FilesInfo.OFF })
    }

    @Test fun idleRemotePingsEveryTwoSecondsAndFastWhileInputIsActive() {
        var active = false
        val m = machine(inputActive = { active })
        val gen = start(m, 0, profile)
        accept(m, gen, 0)
        var now = 0L
        fun pong() { m.handle(Event.Received(gen, Pong(1, 1, 1)), now) }
        fun pings() = sends(m.handle(Event.Tick(0), now)).count { it is Ping }
        now = 600 * ms; pong(); assertEquals(0, pings())
        now = 1_900 * ms; pong(); assertEquals(0, pings())
        now = 2_000 * ms; pong(); assertEquals(1, pings()) // idle: 2 s after the proof PING
        now = 2_500 * ms; pong(); assertEquals(0, pings()) // not yet
        // an input event right after that PING: the fast rate returns at once (500 ms after the last PING)
        active = true
        now = 2_500 * ms; pong(); assertEquals(1, pings())
        now = 2_700 * ms; assertEquals(0, pings())
        now = 3_000 * ms; pong(); assertEquals(1, pings())
        now = 3_500 * ms; pong(); assertEquals(1, pings())
        // input stops: back to 2 s
        active = false
        now = 4_000 * ms; pong(); assertEquals(0, pings())
        now = 5_500 * ms; pong(); assertEquals(1, pings())
    }

    /** AGENTS.md: a held input must never be released by the host's 1.5 s silence rule because the PING was thinned. */
    @Test fun aHeldInputKeepsTheFastPingForever() {
        val m = machine(inputActive = { true })
        val gen = start(m, 0, profile)
        accept(m, gen, 0)
        var last = 0L
        var maxGap = 0L
        var now = 0L
        while (now < 60_000 * ms) {
            now += 100 * ms
            m.handle(Event.Received(gen, Pong(1, 1, 1)), now)
            if (sends(m.handle(Event.Tick(0), now)).any { it is Ping }) {
                maxGap = maxOf(maxGap, now - last)
                last = now
            }
        }
        assertTrue("max PING gap $maxGap us", maxGap <= 600 * ms)
    }

    @Test fun inputActivityRuleHeldOrWithinTwoSeconds() {
        val s = 1_000_000L
        assertTrue(RemoteTimings.inputActive(held = true, lastInputUs = 0, nowUs = 100 * s))
        assertTrue(RemoteTimings.inputActive(held = false, lastInputUs = 100 * s, nowUs = 101 * s + 999_000))
        assertFalse(RemoteTimings.inputActive(held = false, lastInputUs = 100 * s, nowUs = 102 * s))
        assertFalse(RemoteTimings.inputActive(held = false, lastInputUs = 0, nowUs = 5 * s)) // never any input
        assertEquals(500 * ms, RemoteTimings.pingIntervalUs(true))
        assertEquals(2_000 * ms, RemoteTimings.pingIntervalUs(false))
    }

    @Test fun normalSessionPingStaysFiveHundredMilliseconds() {
        val m = machine(inputActive = { false }) // would be slow if it were remote
        val gen = start(m, 0, null)
        accept(m, gen, 0)
        var now = 0L
        var count = 0
        while (now < 5_000 * ms) {
            now += 100 * ms
            m.handle(Event.Received(gen, Pong(1, 1, 1)), now)
            count += sends(m.handle(Event.Tick(0), now)).count { it is Ping }
        }
        assertTrue("pings=$count", count in 9..10)
    }

    @Test fun pongTimeoutIsTenSecondsRemoteAndThreeNormal() {
        val remote = machine()
        val rg = start(remote, 0, profile)
        accept(remote, rg, 0)
        assertFalse(remote.handle(Event.Tick(0), 9_900 * ms).any { it is Action.CloseControl })
        assertTrue(remote.handle(Event.Tick(0), 10_000 * ms).any { it is Action.CloseControl })

        val n = machine()
        val ng = start(n, 0, null)
        accept(n, ng, 0)
        assertFalse(n.handle(Event.Tick(0), 2_900 * ms).any { it is Action.CloseControl })
        assertTrue(n.handle(Event.Tick(0), 3_000 * ms).any { it is Action.CloseControl })
    }

    @Test fun aRemoteSessionNeverMigrates() {
        val m = machine()
        val gen = start(m, 0, profile)
        accept(m, gen, 0)
        val r = m.handle(Event.Migrate(ConnectMode.usbEndpoint), 1_000).filterIsInstance<Action.MigrationResult>().single()
        assertFalse(r.ok)
        assertEquals(SessionMachine.REASON_REMOTE, r.reason)
        assertTrue(m.handle(Event.Migrate(ConnectMode.usbEndpoint), 2_000).none { it is Action.OpenCandidate })
    }

    @Test fun remoteEndsWithTheStopAndTheNextStartIsNormalAgain() {
        val m = machine(inputActive = { false })
        accept(m, start(m, 0, profile), 0)
        m.handle(Event.Stop, 1_000)
        val gen = start(m, 2_000_000, null)
        val s = sends(accept(m, gen, 2_000_000))
        assertEquals(normal, s[1])
    }

    @Test fun remoteAddressParsing() {
        assertEquals(Endpoint("100.101.102.103", 47001), RemoteAddress.parse("100.101.102.103"))
        assertEquals(Endpoint("100.64.0.1", 5000), RemoteAddress.parse(" 100.64.0.1:5000 "))
        assertEquals(Endpoint("mac-mini.tail1234.ts.net", 47001), RemoteAddress.parse("mac-mini.tail1234.ts.net"))
        assertEquals(Endpoint("mac-mini.tail1234.ts.net", 47001), RemoteAddress.parse("Mac-Mini.tail1234.ts.net."))
        assertEquals(Endpoint("mac", 1), RemoteAddress.parse("mac:1"))
        assertEquals(Endpoint("mac", 65535), RemoteAddress.parse("mac.:65535"))
        for (bad in listOf("", " ", ":47001", "mac:", "mac:0", "mac:65536", "mac:abc", "999.1.1.1", "1.2.3", "1.2.3.4.5", "::1", "[::1]:47001",
            "fe80::1", "a b", "-bad.example", "bad-.example", "a..b", "..", ".", "under_score.example", "mac:47001:1")) {
            assertEquals("'$bad'", null, RemoteAddress.parse(bad))
        }
        assertEquals("mac.ts.net", RemoteAddress.display(Endpoint("mac.ts.net", 47001)))
        assertEquals("mac.ts.net:5", RemoteAddress.display(Endpoint("mac.ts.net", 5)))
    }

    @Test fun remoteUiRefusesPairingStatesOnly() {
        assertTrue(RemoteUi.pairingRefused(SessionUi.Failed(SessionUi.Cause.REJECTED)))
        assertTrue(RemoteUi.pairingRefused(SessionUi.PairingNeedsUser("Mac", false)))
        assertTrue(RemoteUi.pairingRefused(SessionUi.StoredTrust("123456", false)))
        assertTrue(RemoteUi.pairingRefused(SessionUi.AwaitingApproval("Mac", "123456")))
        assertFalse(RemoteUi.pairingRefused(SessionUi.Failed(SessionUi.Cause.BUSY)))
        assertFalse(RemoteUi.pairingRefused(SessionUi.Disconnected(SessionUi.Cause.LOST, 1000)))
        assertFalse(RemoteUi.pairingRefused(SessionUi.Connected("Mac", 3)))
    }

    @Test fun remoteSettingsAreSeparateFromTheNormalOnes() {
        val map = HashMap<String, String>()
        val s = Settings(object : KeyValueStore {
            override fun getString(key: String): String? = map[key]
            override fun putString(key: String, value: String) { map[key] = value }
            override fun remove(key: String) { map.remove(key) }
        })
        assertEquals(null, s.remoteEndpoint())
        assertEquals(1000L, s.remoteBitrateKbps())
        assertEquals(RemoteProfile(1000, false), s.remoteProfile())
        s.saveRemoteEndpoint(Endpoint("mac.ts.net", 47001))
        s.saveEndpoint(Endpoint("192.168.1.5", 47001))
        s.setBitrateKbps(60_000)
        s.setRemoteBitrateKbps(500)
        s.setRemoteAudio(true)
        assertEquals(Endpoint("mac.ts.net", 47001), s.remoteEndpoint())
        assertEquals(Endpoint("192.168.1.5", 47001), s.lastEndpoint())
        assertEquals(60_000L, s.bitrateKbps())
        assertEquals(RemoteProfile(500, true), s.remoteProfile())
        s.setRemoteBitrateKbps(7)
        assertEquals(1000L, s.remoteBitrateKbps()) // not an option: the default
        s.resetToDefaults()
        assertEquals(Endpoint("mac.ts.net", 47001), s.remoteEndpoint()) // an address is not a setting to reset
        assertEquals(RemoteProfile(), s.remoteProfile())
    }

    @Test fun startLogLineNeverCarriesTheRemoteAddress() {
        val line = SessionController.eventLogLine(Event.Start(ep, remote = profile), "")!!
        assertFalse(line.fields.contains("mac.example"))
        assertTrue(line.fields.contains("host=remote"))
    }
}
