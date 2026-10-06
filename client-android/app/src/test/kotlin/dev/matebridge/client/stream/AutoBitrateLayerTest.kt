package dev.matebridge.client.stream

import dev.matebridge.client.protocol.StreamPrefs
import dev.matebridge.client.session.KeyValueStore
import dev.matebridge.client.session.Settings
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** T-242 (decisions 0014 §3, 0030 §1): Otomatik picked inside a mode layer means the layer default, not the host formula. */
/** No colour store: the default "Renk" is Keskin kenarlar (decision 0034 addendum), so `chroma` is 1. */
private const val SHARP = StreamPrefs.CHROMA_SHARP

class AutoBitrateLayerTest {
    private class MemStore : KeyValueStore {
        val map = HashMap<String, String>()
        val writes = ArrayList<String>()
        override fun getString(key: String) = map[key]
        override fun putString(key: String, value: String) { writes += key; map[key] = value }
    }

    private val store = MemStore()
    private val settings = Settings(store)

    @Test fun otomatikPickedInsideALayerSendsTheLayerDefault() {
        for (mode in listOf(StreamMode.GAME, StreamMode.DRAWING)) {
            settings.setBitrateKbps(30_000) // stored: a fixed rate, so entry starts at 30 Mbps
            store.writes.clear()
            val g = GameModeSettings(settings)
            g.onModeChanged(mode)
            assertEquals(mode.id, 30_000L, g.prefs(mode).bitrateKbps)
            g.setBitrateKbps(Bitrate.AUTO_KBPS)
            assertEquals(mode.id, GameModeSettings.GAME_BITRATE_KBPS, g.prefs(mode).bitrateKbps) // not 0 (host formula)
            assertEquals(mode.id, GameModeSettings.GAME_BITRATE_KBPS, g.effective().bitrateKbps)
            assertEquals(mode.id, Bitrate.AUTO_KBPS, g.bitrateKbps) // the panel keeps Otomatik selected
            // 0014 §3: the choice stays in the layer
            assertTrue(mode.id, store.writes.isEmpty())
            assertEquals(mode.id, 30_000L, settings.bitrateKbps())
            g.onModeChanged(StreamMode.DAILY)
            assertEquals(mode.id, 30_000L, g.bitrateKbps)
            assertEquals(mode.id, 30_000L, g.prefs(StreamMode.DAILY).bitrateKbps)
        }
    }

    @Test fun enteringWithStoredOtomatikAndPickingItAgainAgree() {
        val g = GameModeSettings(settings)
        g.onModeChanged(StreamMode.GAME)
        assertEquals(Bitrate.AUTO_KBPS, g.bitrateKbps)
        assertEquals(StreamPrefs(60, 1000, 60_000, 1848, 1214).copy(chroma = SHARP), g.prefs(StreamMode.GAME))
        g.setBitrateKbps(15_000)
        assertEquals(15_000L, g.bitrateKbps)
        assertEquals(15_000L, g.prefs(StreamMode.GAME).bitrateKbps)
        g.setBitrateKbps(Bitrate.AUTO_KBPS)
        assertEquals(Bitrate.AUTO_KBPS, g.bitrateKbps)
        assertEquals(StreamPrefs(60, 1000, 60_000, 1848, 1214).copy(chroma = SHARP), g.prefs(StreamMode.GAME)) // same as on entry
        g.setBitrateKbps(60_000) // the fixed 60 Mbps is a different selection with the same rate
        assertEquals(60_000L, g.bitrateKbps)
        assertTrue(store.writes.isEmpty())
    }

    @Test fun switchingLayersKeepsTheRule() {
        val g = GameModeSettings(settings)
        g.onModeChanged(StreamMode.GAME)
        g.setBitrateKbps(100_000)
        g.onModeChanged(StreamMode.DRAWING) // rebuilt from the stored Otomatik
        assertEquals(Bitrate.AUTO_KBPS, g.bitrateKbps)
        assertEquals(60_000L, g.prefs(StreamMode.DRAWING).bitrateKbps)
    }

    @Test fun dailyOtomatikStillAsksForTheHostFormula() {
        settings.setBitrateKbps(30_000)
        val g = GameModeSettings(settings)
        g.onModeChanged(StreamMode.DAILY)
        g.setBitrateKbps(Bitrate.AUTO_KBPS)
        assertEquals(Bitrate.AUTO_KBPS, g.bitrateKbps)
        assertEquals(Bitrate.AUTO_KBPS, g.prefs(StreamMode.DAILY).bitrateKbps)
        assertEquals(Bitrate.AUTO_KBPS, settings.bitrateKbps()) // persisted as before
    }

    @Test fun layerBitrateResolvesOnlyOtomatik() {
        assertEquals(60_000L, GameModeSettings.layerBitrateKbps(Bitrate.AUTO_KBPS))
        for (k in Bitrate.OPTIONS_KBPS.drop(1)) assertEquals(k, GameModeSettings.layerBitrateKbps(k))
    }

    @Test fun optionLabels() {
        val labels = { layer: StreamMode? -> Bitrate.OPTIONS_KBPS.map { GameModeSettings.bitrateOptionLabel(layer, it) } }
        assertEquals(listOf("Otomatik", "15 Mbps", "30 Mbps", "60 Mbps", "100 Mbps"), labels(null))
        assertEquals(listOf("Otomatik (60 Mbps)", "15 Mbps", "30 Mbps", "60 Mbps", "100 Mbps"), labels(StreamMode.GAME))
        assertEquals(listOf("Otomatik (60 Mbps)", "15 Mbps", "30 Mbps", "60 Mbps", "100 Mbps"), labels(StreamMode.DRAWING))
        assertEquals(listOf("Otomatik", "15 Mbps", "30 Mbps", "60 Mbps", "100 Mbps"), labels(StreamMode.DAILY))
    }
}
