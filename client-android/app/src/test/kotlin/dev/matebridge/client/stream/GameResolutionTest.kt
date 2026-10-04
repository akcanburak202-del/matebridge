package dev.matebridge.client.stream

import dev.matebridge.client.protocol.Codec
import dev.matebridge.client.protocol.FixtureTest
import dev.matebridge.client.protocol.StreamConfig
import dev.matebridge.client.protocol.StreamPrefs
import dev.matebridge.client.session.KeyValueStore
import dev.matebridge.client.session.Settings
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** T-215 (decision 0029): "Oyun çözünürlüğü" and the game display group in STREAM_PREFS. */
class GameResolutionTest {
    private class MemStore : KeyValueStore {
        val map = HashMap<String, String>()
        override fun getString(key: String) = map[key]
        override fun putString(key: String, value: String) { map[key] = value }
        override fun remove(key: String) { map.remove(key) }
    }

    private val store = MemStore()
    private val settings = Settings(store)

    private val nonGame = StreamMode.entries.filter { !it.isGame }

    @Test fun r2240IsAValidOptionWithTheExactPanelShape() {
        assertTrue(GameResolution.entries.contains(GameResolution.R2240))
        assertEquals(GameResolution.R2240, GameResolution.parse("2240x1472"))
        assertEquals(2240L * 1840, 1472L * 2800) // exactly 35:23
        assertTrue(GameResolution.R2240.appliedIn(cfg1x(2240, 1472)))
        assertNull(VideoLayout.surfaceSize(2800, 1840, cfg1x(2240, 1472)))
        settings.setGameResolution(GameResolution.R2240)
        val g = GameModeSettings(settings)
        g.onModeChanged(StreamMode.GAME)
        assertEquals(StreamPrefs(60, 1000, 60_000, 2240, 1472), g.prefs(StreamMode.GAME))
    }

    @Test fun sizesIdsAndDefault() {
        assertEquals(
            listOf(1400 to 920, 1848 to 1214, 2100 to 1380, 2240 to 1472),
            GameResolution.entries.map { it.widthPx to it.heightPx },
        )
        assertEquals(listOf("1400x920", "1848x1214", "2100x1380", "2240x1472"), GameResolution.entries.map { it.id })
        assertEquals(listOf("1400×920", "1848×1214", "2100×1380", "2240×1472"), GameResolution.entries.map { it.label })
        assertEquals(GameResolution.R1848, GameResolution.DEFAULT)
        for (r in GameResolution.entries) assertEquals(r, GameResolution.parse(r.id))
        assertEquals(GameResolution.DEFAULT, GameResolution.parse(null))
        assertEquals(GameResolution.DEFAULT, GameResolution.parse("2800x1840"))
        assertEquals(GameResolution.DEFAULT, GameResolution.parse(""))
    }

    @Test fun everySizeIsWithinTheHostAspectAndRangeRules() {
        // PROTOCOL §0x05 host rules against HELLO 2800×1840: half..full size, aspect within 0.5%.
        for (r in GameResolution.entries) {
            assertTrue(r.id, r.widthPx in 1400..2800 && r.heightPx in 920..1840)
            assertTrue(r.id, Math.abs(r.widthPx.toLong() * 1840 - r.heightPx.toLong() * 2800) <= 0.005 * r.heightPx * 2800)
        }
    }

    @Test fun settingPersistsAndUnknownFallsBack() {
        assertEquals(GameResolution.R1848, settings.gameResolution())
        settings.setGameResolution(GameResolution.R1400)
        assertEquals("1400x920", store.map["game_resolution"])
        assertEquals(GameResolution.R1400, Settings(store).gameResolution())
        store.map["game_resolution"] = "garbage"
        assertEquals(GameResolution.R1848, Settings(store).gameResolution())
    }

    @Test fun resetBringsTheDefaultBack() {
        settings.setGameResolution(GameResolution.R2100)
        assertEquals(1, settings.resetToDefaults())
        assertNull(store.map["game_resolution"])
        assertEquals(GameResolution.DEFAULT, settings.gameResolution())
    }

    @Test fun gameModeSendsTheDefaultGameDisplay() {
        val g = GameModeSettings(settings)
        g.onModeChanged(StreamMode.GAME)
        assertEquals(StreamPrefs(60, 1000, 60_000, 1848, 1214), g.prefs(StreamMode.GAME))
        g.selectFrameRate(StreamMode.GAME, 120)
        assertEquals(StreamPrefs(120, 1000, 60_000, 1848, 1214), g.prefs(StreamMode.GAME))
        // The wire did not change, only the mode concept: the bit rate and display group are byte for byte the golden
        // vector of T-213 (its fps/scale words, 120/660, are not a mode's any more, so only the tail is compared).
        g.selectFrameRate(StreamMode.GAME, 60)
        val golden = FixtureTest.fixture("stream_prefs_game_display")
        val bytes = Codec.encode(g.prefs(StreamMode.GAME))
        assertEquals(golden.size, bytes.size)
        assertArrayEquals(golden.copyOfRange(0, 5), bytes.copyOfRange(0, 5)) // header: type and length 12
        assertArrayEquals(golden.copyOfRange(9, golden.size), bytes.copyOfRange(9, bytes.size)) // bitrate + display_*
        assertEquals(60, bytes[5].toInt()) // fps 60
        assertEquals(StreamMode.SCALE_PERMILLE, (bytes[7].toInt() and 0xFF) or ((bytes[8].toInt() and 0xFF) shl 8))
    }

    @Test fun gameModesSendTheStoredSize() {
        settings.setGameResolution(GameResolution.R1400)
        val g = GameModeSettings(settings)
        g.onModeChanged(StreamMode.GAME)
        settings.setBitrateKbps(30_000) // stored, outside the layer: the layer keeps 60 Mbps
        assertEquals(StreamPrefs(60, 1000, 60_000, 1400, 920), g.prefs(StreamMode.GAME))
        assertEquals(GameResolution.R1400, g.display(StreamMode.GAME))
    }

    @Test fun nonGameModesSendNoGameDisplay() {
        settings.setGameResolution(GameResolution.R2100)
        val g = GameModeSettings(settings)
        for (bitrate in listOf(0L, 30_000L)) {
            settings.setBitrateKbps(bitrate)
            for (m in nonGame) {
                g.onModeChanged(m)
                val p = g.prefs(m)
                assertEquals(0, p.displayWidthPx)
                assertEquals(0, p.displayHeightPx)
                assertNull(g.display(m))
                val bytes = Codec.encodePayload(p)
                assertEquals(8, bytes.size)
                assertArrayEquals(Codec.encodePayload(StreamPrefs(120, 1000, p.bitrateKbps)), bytes)
            }
        }
        settings.setBitrateKbps(0)
        g.onModeChanged(StreamMode.DAILY)
        assertArrayEquals(Codec.encodePayload(StreamPrefs(120, 1000, 0)), Codec.encodePayload(g.prefs(StreamMode.DAILY)))
    }

    @Test fun gameDisplayOffGivesTodaysGameBytes() {
        // `--ez dev true --ei game_display 0`: the A/B base, Oyun without the display group (native HiDPI display).
        settings.setGameResolution(GameResolution.R1400)
        val g = GameModeSettings(settings, gameDisplay = false)
        g.onModeChanged(StreamMode.GAME)
        assertEquals(StreamPrefs(60, 1000, 60_000), g.prefs(StreamMode.GAME))
        assertEquals(8, Codec.encodePayload(g.prefs(StreamMode.GAME)).size)
        assertNull(g.display(StreamMode.GAME))
        assertNull(g.selectGameResolution(GameResolution.R2100, StreamMode.GAME)) // stored, nothing sent
        assertEquals(GameResolution.R2100, settings.gameResolution())
    }

    @Test fun changingTheSizeSendsOneCompletePrefsOnlyInAGameMode() {
        val g = GameModeSettings(settings)
        for (m in nonGame) {
            g.onModeChanged(m)
            assertNull(m.id, g.selectGameResolution(GameResolution.R1400, m))
        }
        assertEquals(GameResolution.R1400, settings.gameResolution()) // stored for the next game-mode entry
        g.onModeChanged(StreamMode.GAME)
        g.setBitrateKbps(15_000) // the layer's bit rate goes along
        assertEquals(StreamPrefs(60, 1000, 15_000, 2100, 1380), g.selectGameResolution(GameResolution.R2100, StreamMode.GAME))
        g.selectFrameRate(StreamMode.GAME, 120)
        assertEquals(StreamPrefs(120, 1000, 15_000, 2240, 1472), g.selectGameResolution(GameResolution.R2240, StreamMode.GAME))
        assertEquals(StreamPrefs(120, 1000, 15_000, 1848, 1214), g.selectGameResolution(GameResolution.R1848, StreamMode.GAME))
        assertEquals(GameResolution.R1848, settings.gameResolution())
    }

    @Test fun toastShowsTheGameDisplay() {
        assertEquals("Oyun: 120 fps, 1848×1214", StreamMode.GAME.toastText(120, GameResolution.R1848))
        assertEquals("Oyun: 60 fps, 1400×920", StreamMode.GAME.toastText(60, GameResolution.R1400))
        assertEquals("Oyun: 60 fps", StreamMode.GAME.toastText(60, null)) // game display off
        val g = GameModeSettings(settings)
        assertEquals("Günlük: 120 fps", StreamMode.DAILY.toastText(g.fps(StreamMode.DAILY), g.display(StreamMode.DAILY)))
        assertEquals("Oyun: 60 fps, 1848×1214", StreamMode.GAME.toastText(g.fps(StreamMode.GAME), g.display(StreamMode.GAME)))
    }

    // ---- applied check (PROTOCOL §0x05: full geometry) ----

    @Test fun appliedNeedsTheFullGeometry() {
        for (r in GameResolution.entries) assertTrue(r.id, r.appliedIn(cfg1x(r.widthPx, r.heightPx)))
        assertFalse(GameResolution.R1848.appliedIn(cfg1x(1400, 920))) // another 1x size
        assertFalse(GameResolution.R1848.appliedIn(StreamConfig(1, 2, 1848, 1214, 1848, 1215, 120, 1, 1, 1, 1, 1)))
        assertFalse(GameResolution.R1848.appliedIn(StreamConfig(1, 2, 1848, 1213, 1848, 1214, 120, 1, 1, 1, 1, 1)))
    }

    @Test fun r1400IsNotAppliedByANativeHiDpiDisplay() {
        // An old host (or `game_display_failed`) keeps the native HiDPI display: 1400×920 pt, the same as the request.
        val nativeFull = StreamConfig(1, 2, 2800, 1840, 1400, 920, 120, 60_000, 1, 1, 1, 1)
        val nativeScaled = StreamConfig(1, 2, 1848, 1214, 1400, 920, 120, 60_000, 1, 1, 1, 1) // Oyun 120 at 660
        assertEquals(1400, nativeFull.widthPt) // the width_pt-only check would say "applied"
        assertFalse(GameResolution.R1400.appliedIn(nativeFull))
        assertFalse(GameResolution.R1400.appliedIn(nativeScaled))
        assertFalse(GameResolution.R1848.appliedIn(nativeScaled)) // encoded size matches, display does not
        assertTrue(GameResolution.R1400.appliedIn(cfg1x(1400, 920)))
    }

    // ---- layout (VideoLayout.surfaceSize) ----

    /** A 1x game display config: point size = pixel size (PROTOCOL §0x05). */
    private fun cfg1x(w: Int, h: Int) = StreamConfig(1, 2, w, h, w, h, 120, 60_000, 1, 1, 1, 1)

    @Test fun gameDisplaysFillThePanelWithoutBands() {
        for (r in GameResolution.entries) assertNull(r.id, VideoLayout.surfaceSize(2800, 1840, cfg1x(r.widthPx, r.heightPx)))
        // the fitted size alone would leave a 1 px band for 1848×1214
        val vp = VideoViewport(2800, 1840, 1848, 1214)
        assertEquals(2800, Math.round(vp.width))
        assertEquals(1839, Math.round(vp.height))
        // native HiDPI display (1400×920 pt) and a scaled encode fill the root too
        assertNull(VideoLayout.surfaceSize(2800, 1840, StreamConfig(1, 2, 1848, 1214, 1400, 920, 120, 1, 1, 1, 1, 1)))
    }

    @Test fun aReallyDifferentAspectStillLetterboxes() {
        assertEquals(2800 to 1750, VideoLayout.surfaceSize(2800, 1840, cfg1x(2560, 1600))) // 16:10
        assertEquals(2453 to 1840, VideoLayout.surfaceSize(2800, 1840, cfg1x(1920, 1440))) // 4:3
        assertEquals(2800 to 1837, VideoLayout.surfaceSize(2800, 1840, cfg1x(2800, 1837))) // 3 px: beyond the tolerance
        assertNull(VideoLayout.surfaceSize(2800, 1840, cfg1x(2800, 1838))) // 2 px: fills
    }

    @Test fun noConfigOrRootFillsTheRoot() {
        assertNull(VideoLayout.surfaceSize(2800, 1840, null))
        assertNull(VideoLayout.surfaceSize(0, 0, cfg1x(1848, 1214)))
    }

    @Test fun aSmallerRootFitsAsBefore() {
        // e.g. a split-screen window: fitted, centred by the layout gravity
        assertEquals(1400 to 920, VideoLayout.surfaceSize(1400, 1200, cfg1x(1400, 920)))
    }
}
