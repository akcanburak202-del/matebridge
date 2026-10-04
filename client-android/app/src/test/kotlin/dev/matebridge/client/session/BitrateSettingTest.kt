package dev.matebridge.client.session

import dev.matebridge.client.protocol.Bytes
import dev.matebridge.client.protocol.Codec
import dev.matebridge.client.protocol.FixtureTest
import dev.matebridge.client.protocol.Hello
import dev.matebridge.client.protocol.HelloAck
import dev.matebridge.client.protocol.SettingsOpen
import dev.matebridge.client.protocol.StreamConfig
import dev.matebridge.client.protocol.StreamPrefs
import dev.matebridge.client.session.SessionMachine.Action
import dev.matebridge.client.session.SessionMachine.Event
import dev.matebridge.client.stream.Bitrate
import dev.matebridge.client.stream.StreamMode
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** T-105: bit rate persistence and STREAM_PREFS, SETTINGS_OPEN handling, transport switch decision. */
class BitrateSettingTest {
    private val map = HashMap<String, String>()
    private val settings = Settings(object : KeyValueStore {
        override fun getString(key: String): String? = map[key]
        override fun putString(key: String, value: String) { map[key] = value }
    })

    private val hello = Hello(0, Bytes(ByteArray(16)), 2800, 1840, 360, 144, 0xFF, "MatePad")
    private val ep = Endpoint("10.0.0.5", 7420)
    private var now = 1_000_000L

    private fun sends(a: List<Action>) = a.filterIsInstance<Action.Send>().map { it.msg }

    private fun accepted(m: SessionMachine): Pair<Int, List<Action>> {
        val gen = m.handle(Event.Start(ep), now).filterIsInstance<Action.OpenControl>().single().gen
        m.handle(Event.ControlOpened(gen), now)
        return gen to m.handle(Event.Received(gen, HelloAck(0, HelloAck.ACCEPTED, 5, 7421, "Mac")), now)
    }

    @Test fun defaultIsAutoAndChoicesPersist() {
        assertEquals(0L, settings.bitrateKbps())
        for (v in Bitrate.OPTIONS_KBPS) {
            settings.setBitrateKbps(v)
            assertEquals(v, settings.bitrateKbps())
        }
        settings.setBitrateKbps(60_000)
        assertEquals("60000", map["bitrate_kbps"])
    }

    @Test fun invalidStoredOrRequestedValueIsAuto() {
        map["bitrate_kbps"] = "abc"
        assertEquals(0L, settings.bitrateKbps())
        map["bitrate_kbps"] = "45000"
        assertEquals(0L, settings.bitrateKbps())
        map["bitrate_kbps"] = "-1"
        assertEquals(0L, settings.bitrateKbps())
        settings.setBitrateKbps(7)
        assertEquals("0", map["bitrate_kbps"])
    }

    @Test fun labels() {
        assertEquals("Otomatik", Bitrate.label(0))
        assertEquals("15 Mbps", Bitrate.label(15_000))
        assertEquals("100 Mbps", Bitrate.label(100_000))
        assertEquals("12,5 Mbps", Bitrate.mbps(12_500))
        assertEquals("Uygulanan: 60 Mbps", Bitrate.appliedLabel(60_000))
        assertEquals("Uygulanan: —", Bitrate.appliedLabel(null))
        assertEquals("Uygulanan: —", Bitrate.appliedLabel(0))
    }

    @Test fun streamPrefsCarryTheBitrateOnTheWire() {
        assertEquals(StreamPrefs(120, 1000, 40_000), StreamMode.DAILY.toPrefs(bitrateKbps = 40_000))
        assertArrayEquals(FixtureTest.fixture("stream_prefs_bitrate"), Codec.encode(StreamMode.DAILY.toPrefs(bitrateKbps = 40_000)))
        assertEquals(StreamPrefs(120, 1000, 0), StreamMode.DAILY.toPrefs()) // Otomatik = 0
        assertArrayEquals(FixtureTest.fixture("stream_prefs"), Codec.encode(StreamPrefs(120, 750)))
    }

    @Test fun initialBitrateGoesOutOnAcceptAndAChangeAtOnce() {
        val m = SessionMachine(hello, StreamMode.DAILY.toPrefs(fps = 60, bitrateKbps = 60_000))
        val (gen, acc) = accepted(m)
        assertEquals(StreamPrefs(60, 1000, 60_000), sends(acc)[1])
        m.handle(Event.Received(gen, StreamConfig(1, 2, 2800, 1840, 1400, 920, 60, 60_000, 1, 1, 1, 1)), now)
        // bit rate changed while streaming: sent now; the same again: nothing
        assertEquals(listOf<Any>(StreamPrefs(60, 1000, 100_000)), sends(m.handle(Event.SetPrefs(StreamMode.DAILY.toPrefs(fps = 60, bitrateKbps = 100_000)), now)))
        assertTrue(m.handle(Event.SetPrefs(StreamMode.DAILY.toPrefs(fps = 60, bitrateKbps = 100_000)), now).isEmpty())
        // back to Otomatik
        assertEquals(listOf<Any>(StreamPrefs(60, 1000, 0)), sends(m.handle(Event.SetPrefs(StreamMode.DAILY.toPrefs(fps = 60)), now)))
    }

    @Test fun settingsOpenOnlyOnAnAcceptedSession() {
        val m = SessionMachine(hello)
        val gen = m.handle(Event.Start(ep), now).filterIsInstance<Action.OpenControl>().single().gen
        m.handle(Event.ControlOpened(gen), now)
        assertFalse(m.handle(Event.Received(gen, SettingsOpen), now).contains(Action.OpenSettings)) // before ACCEPTED
        m.handle(Event.Received(gen, HelloAck(0, HelloAck.ACCEPTED, 5, 7421, "Mac")), now)
        assertEquals(listOf<Action>(Action.OpenSettings), m.handle(Event.Received(gen, SettingsOpen), now))
        // a stale connection's SETTINGS_OPEN is ignored
        assertTrue(m.handle(Event.Received(gen + 100, SettingsOpen), now).isEmpty())
        // streaming: still delivered (the UI decides whether the stream is visible)
        m.handle(Event.Received(gen, StreamConfig(1, 2, 2800, 1840, 1400, 920, 60, 60_000, 1, 1, 1, 1)), now)
        assertEquals(listOf<Action>(Action.OpenSettings), m.handle(Event.Received(gen, SettingsOpen), now))
    }

    @Test fun transportChoiceKeepsAFittingSession() {
        // AUTO always fits an accepted session
        assertTrue(TransportSwitch.keepsSession(TransportMode.AUTO, true, Transport.USB))
        assertTrue(TransportSwitch.keepsSession(TransportMode.AUTO, true, Transport.WIFI))
        assertTrue(TransportSwitch.keepsSession(TransportMode.USB, true, Transport.USB))
        assertFalse(TransportSwitch.keepsSession(TransportMode.USB, true, Transport.WIFI))
        assertTrue(TransportSwitch.keepsSession(TransportMode.WIFI, true, Transport.WIFI))
        assertFalse(TransportSwitch.keepsSession(TransportMode.WIFI, true, Transport.USB))
        // not accepted: always re-applied
        for (m in TransportMode.entries) assertFalse(TransportSwitch.keepsSession(m, false, Transport.WIFI))
        assertFalse(TransportSwitch.keepsSession(TransportMode.USB, true, null))
    }
}
