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
/** No colour store: the default "Renk" is Keskin kenarlar (decision 0034 addendum), so `chroma` is 1. */
private const val SHARP = StreamPrefs.CHROMA_SHARP

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

    private val matepad = NativeSize.MATEPAD
    private val xiaomi = NativeSize(3008, 1880)

    @Test fun p80IsAValidOptionWithTheExactPanelShape() {
        assertTrue(GameResolution.entries.contains(GameResolution.P80))
        assertEquals(GameResolution.P80, GameResolution.parse("80"))
        assertEquals(GameResolution.P80, GameResolution.parse("2240x1472")) // pre-T-387 stored value
        val d = GameResolution.P80.on(matepad)
        assertEquals(2240L * 1840, 1472L * 2800) // exactly 35:23
        assertTrue(d.appliedIn(cfg1x(2240, 1472)))
        assertNull(VideoLayout.surfaceSize(2800, 1840, cfg1x(2240, 1472)))
        settings.setGameResolution(GameResolution.P80)
        val g = GameModeSettings(settings)
        g.onModeChanged(StreamMode.GAME)
        assertEquals(StreamPrefs(60, 1000, 60_000, 2240, 1472).copy(chroma = SHARP), g.prefs(StreamMode.GAME))
    }

    @Test fun sizesIdsAndDefault() {
        val sizes = GameResolution.entries.map { it.on(matepad) }
        // MatePad: byte for byte the pre-T-387 list
        assertEquals(listOf(1400 to 920, 1848 to 1214, 2100 to 1380, 2240 to 1472, 2800 to 1840), sizes.map { it.widthPx to it.heightPx })
        assertEquals(listOf("1400×920", "1848×1214", "2100×1380", "2240×1472", "2800×1840"), sizes.map { it.label })
        assertEquals(
            listOf("1400×920", "1848×1214", "2100×1380", "2240×1472", "2800×1840 (deneysel)"),
            sizes.map { it.panelLabel },
        )
        assertEquals(listOf("50", "66", "75", "80", "100"), GameResolution.entries.map { it.id })
        assertEquals(listOf(GameResolution.P100), GameResolution.entries.filter { it.experimental }) // T-245
        assertEquals(GameResolution.P66, GameResolution.DEFAULT)
        for (r in GameResolution.entries) assertEquals(r, GameResolution.parse(r.id))
        assertEquals(GameResolution.DEFAULT, GameResolution.parse(null))
        assertEquals(GameResolution.DEFAULT, GameResolution.parse("2560x1600"))
        assertEquals(GameResolution.DEFAULT, GameResolution.parse(""))
    }

    @Test fun legacyStoredValuesMapToTheirStep() { // T-387 migration
        val legacy = mapOf(
            "1400x920" to GameResolution.P50, "1848x1214" to GameResolution.P66, "2100x1380" to GameResolution.P75,
            "2240x1472" to GameResolution.P80, "2800x1840" to GameResolution.P100,
        )
        for ((old, step) in legacy) {
            store.map["game_resolution"] = old
            assertEquals(old, step, Settings(store).gameResolution())
        }
        store.map["game_resolution"] = "1234x567" // unknown: the default
        assertEquals(GameResolution.DEFAULT, Settings(store).gameResolution())
    }

    @Test fun xiaomiSizes() {
        assertEquals(
            listOf(1504 to 940, 1986 to 1242, 2256 to 1410, 2406 to 1504, 3008 to 1880),
            GameResolution.entries.map { it.on(xiaomi) }.map { it.widthPx to it.heightPx },
        )
        assertEquals("3008×1880 (deneysel)", GameResolution.P100.on(xiaomi).panelLabel)
        settings.setGameResolution(GameResolution.P66)
        val g = GameModeSettings(settings, native = xiaomi)
        g.onModeChanged(StreamMode.GAME)
        assertEquals(StreamPrefs(60, 1000, 60_000, 1986, 1242).copy(chroma = SHARP), g.prefs(StreamMode.GAME))
        assertTrue(g.display(StreamMode.GAME)!!.appliedIn(cfg1x(1986, 1242)))
    }

    @Test fun everySizeSatisfiesTheHostRule() { // GameDisplayPolicy.accepts: even, half..full, aspect within 0.5%
        val natives = listOf(
            matepad, xiaomi, NativeSize(2560, 1600), NativeSize(2000, 1200), NativeSize(2801, 1841), NativeSize(2800, 1839),
            NativeSize(1920, 1080), NativeSize(1280, 800), NativeSize(2961, 1848),
        )
        for (n in natives) for (r in GameResolution.entries) {
            val d = r.on(n)
            assertTrue("$n $r $d", GameDisplay.accepts(d.widthPx, d.heightPx, n))
            // independent restatement of the rule
            val w = d.widthPx.toLong()
            val h = d.heightPx.toLong()
            assertTrue("$n $r $d even", w % 2 == 0L && h % 2 == 0L)
            assertTrue("$n $r $d range", 2 * w >= n.widthPx && w <= n.widthPx && 2 * h >= n.heightPx && h <= n.heightPx)
            assertTrue("$n $r $d aspect", Math.abs(w * n.heightPx - h * n.widthPx) <= 0.005 * h * n.widthPx)
        }
        assertEquals(NativeSize(2800, 1840), NativeSize.landscape(1840, 2800))
    }

    @Test fun settingPersistsAndUnknownFallsBack() {
        assertEquals(GameResolution.P66, settings.gameResolution())
        settings.setGameResolution(GameResolution.P50)
        assertEquals("50", store.map["game_resolution"])
        assertEquals(GameResolution.P50, Settings(store).gameResolution())
        store.map["game_resolution"] = "garbage"
        assertEquals(GameResolution.P66, Settings(store).gameResolution())
    }

    @Test fun resetBringsTheDefaultBack() {
        settings.setGameResolution(GameResolution.P75)
        assertEquals(1, settings.resetToDefaults())
        assertNull(store.map["game_resolution"])
        assertEquals(GameResolution.DEFAULT, settings.gameResolution())
    }

    @Test fun gameModeSendsTheDefaultGameDisplay() {
        val g = GameModeSettings(settings)
        g.onModeChanged(StreamMode.GAME)
        assertEquals(StreamPrefs(60, 1000, 60_000, 1848, 1214).copy(chroma = SHARP), g.prefs(StreamMode.GAME))
        g.selectFrameRate(StreamMode.GAME, 120)
        assertEquals(StreamPrefs(120, 1000, 60_000, 1848, 1214).copy(chroma = SHARP), g.prefs(StreamMode.GAME))
        // The wire did not change, only the mode concept: the bit rate and display group are byte for byte the golden
        // vector of T-213 (its fps/scale words, 120/660, are not a mode's any more, so only the tail is compared).
        g.selectFrameRate(StreamMode.GAME, 60)
        val golden = FixtureTest.fixture("stream_prefs_game_display")
        val bytes = Codec.encode(g.prefs(StreamMode.GAME).copy(chroma = 0)) // the fixture predates `chroma`
        assertEquals(golden.size, bytes.size)
        assertArrayEquals(golden.copyOfRange(0, 5), bytes.copyOfRange(0, 5)) // header: type and length 12
        assertArrayEquals(golden.copyOfRange(9, golden.size), bytes.copyOfRange(9, bytes.size)) // bitrate + display_*
        assertEquals(60, bytes[5].toInt()) // fps 60
        assertEquals(StreamMode.SCALE_PERMILLE, (bytes[7].toInt() and 0xFF) or ((bytes[8].toInt() and 0xFF) shl 8))
    }

    @Test fun gameModesSendTheStoredSize() {
        settings.setGameResolution(GameResolution.P50)
        val g = GameModeSettings(settings)
        g.onModeChanged(StreamMode.GAME)
        settings.setBitrateKbps(30_000) // stored, outside the layer: the layer keeps 60 Mbps
        assertEquals(StreamPrefs(60, 1000, 60_000, 1400, 920).copy(chroma = SHARP), g.prefs(StreamMode.GAME))
        assertEquals(GameResolution.P50.on(NativeSize.MATEPAD), g.display(StreamMode.GAME))
    }

    @Test fun nonGameModesSendNoGameDisplay() {
        settings.setGameResolution(GameResolution.P75)
        val g = GameModeSettings(settings)
        for (bitrate in listOf(0L, 30_000L)) {
            settings.setBitrateKbps(bitrate)
            for (m in nonGame) {
                g.onModeChanged(m)
                val p = g.prefs(m)
                assertEquals(0, p.displayWidthPx)
                assertEquals(0, p.displayHeightPx)
                assertNull(g.display(m))
                val bytes = Codec.encodePayload(p.copy(chroma = 0)) // the length checks look at the display group only
                assertEquals(8, bytes.size)
                assertArrayEquals(Codec.encodePayload(StreamPrefs(120, 1000, p.bitrateKbps)), bytes)
            }
        }
        settings.setBitrateKbps(0)
        g.onModeChanged(StreamMode.DAILY)
        assertArrayEquals(Codec.encodePayload(StreamPrefs(120, 1000, 0).copy(chroma = SHARP)), Codec.encodePayload(g.prefs(StreamMode.DAILY)))
    }

    @Test fun gameDisplayOffGivesTodaysGameBytes() {
        // `--ez dev true --ei game_display 0`: the A/B base, Oyun without the display group (native HiDPI display).
        settings.setGameResolution(GameResolution.P50)
        val g = GameModeSettings(settings, gameDisplay = false)
        g.onModeChanged(StreamMode.GAME)
        assertEquals(StreamPrefs(60, 1000, 60_000).copy(chroma = SHARP), g.prefs(StreamMode.GAME))
        assertEquals(8, Codec.encodePayload(g.prefs(StreamMode.GAME).copy(chroma = 0)).size)
        assertNull(g.display(StreamMode.GAME))
        assertNull(g.selectGameResolution(GameResolution.P75, StreamMode.GAME)) // stored, nothing sent
        assertEquals(GameResolution.P75, settings.gameResolution())
    }

    @Test fun changingTheSizeSendsOneCompletePrefsOnlyInAGameMode() {
        val g = GameModeSettings(settings)
        for (m in nonGame) {
            g.onModeChanged(m)
            assertNull(m.id, g.selectGameResolution(GameResolution.P50, m))
        }
        assertEquals(GameResolution.P50, settings.gameResolution()) // stored for the next game-mode entry
        g.onModeChanged(StreamMode.GAME)
        g.setBitrateKbps(15_000) // the layer's bit rate goes along
        assertEquals(StreamPrefs(60, 1000, 15_000, 2100, 1380).copy(chroma = SHARP), g.selectGameResolution(GameResolution.P75, StreamMode.GAME))
        g.selectFrameRate(StreamMode.GAME, 120)
        assertEquals(StreamPrefs(120, 1000, 15_000, 2240, 1472).copy(chroma = SHARP), g.selectGameResolution(GameResolution.P80, StreamMode.GAME))
        assertEquals(StreamPrefs(120, 1000, 15_000, 1848, 1214).copy(chroma = SHARP), g.selectGameResolution(GameResolution.P66, StreamMode.GAME))
        assertEquals(GameResolution.P66, settings.gameResolution())
    }

    @Test fun toastShowsTheGameDisplay() {
        assertEquals("Oyun: 120 fps, 1848×1214", StreamMode.GAME.toastText(120, GameResolution.P66.on(NativeSize.MATEPAD)))
        assertEquals("Oyun: 60 fps, 1400×920", StreamMode.GAME.toastText(60, GameResolution.P50.on(NativeSize.MATEPAD)))
        assertEquals("Oyun: 60 fps", StreamMode.GAME.toastText(60, null)) // game display off
        val g = GameModeSettings(settings)
        assertEquals("Günlük: 120 fps", StreamMode.DAILY.toastText(g.fps(StreamMode.DAILY), g.display(StreamMode.DAILY)))
        assertEquals("Oyun: 60 fps, 1848×1214", StreamMode.GAME.toastText(g.fps(StreamMode.GAME), g.display(StreamMode.GAME)))
    }

    // ---- T-245/T-250: experimental 2800×1840, every Oyun frame rate ----

    @Test fun experimentalPanelLabel() {
        assertEquals("2800×1840 (deneysel)", GameResolution.P100.on(matepad).panelLabel)
        for (r in GameResolution.entries.filter { !it.experimental }) assertEquals(r.on(matepad).label, r.on(matepad).panelLabel)
    }

    @Test fun oyun60SendsTheNativeSizeAt1x() {
        settings.setGameResolution(GameResolution.P100)
        assertEquals("100", store.map["game_resolution"])
        assertEquals(GameResolution.P100, Settings(store).gameResolution())
        val g = GameModeSettings(settings)
        g.onModeChanged(StreamMode.GAME) // Oyun defaults to 60
        assertEquals(StreamPrefs(60, 1000, 60_000, 2800, 1840).copy(chroma = SHARP), g.prefs(StreamMode.GAME))
        assertEquals(GameResolution.P100.on(NativeSize.MATEPAD), g.display(StreamMode.GAME))
        assertEquals("Oyun: 60 fps, 2800×1840", StreamMode.GAME.toastText(g.fps(StreamMode.GAME), g.display(StreamMode.GAME)))
        // the wire: the 12-byte display group with u16 LE 2800 (0x0AF0) and 1840 (0x0730)
        val bytes = Codec.encodePayload(g.prefs(StreamMode.GAME).copy(chroma = 0))
        assertEquals(12, bytes.size)
        assertArrayEquals(byteArrayOf(0xF0.toByte(), 0x0A, 0x30, 0x07), bytes.copyOfRange(8, 12))
        // the host applies it as a 1x display: full geometry 2800×1840 px = pt (not the native HiDPI 1400×920 pt)
        assertTrue(GameResolution.P100.on(NativeSize.MATEPAD).appliedIn(cfg1x(2800, 1840)))
        assertFalse(GameResolution.P100.on(NativeSize.MATEPAD).appliedIn(StreamConfig(1, 2, 2800, 1840, 1400, 920, 60, 60_000, 1, 1, 1, 1)))
        assertNull(VideoLayout.surfaceSize(2800, 1840, cfg1x(2800, 1840)))
    }

    @Test fun oyun120SendsTheNativeSizeToo() { // T-250
        settings.setGameResolution(GameResolution.P100)
        val g = GameModeSettings(settings)
        g.onModeChanged(StreamMode.GAME)
        // 60 -> 120: only fps changes, display_* stays 2800×1840
        assertEquals(StreamPrefs(120, 1000, 60_000, 2800, 1840).copy(chroma = SHARP), g.selectFrameRate(StreamMode.GAME, 120))
        assertEquals(GameResolution.P100.on(NativeSize.MATEPAD), g.display(StreamMode.GAME))
        assertEquals("Oyun: 120 fps, 2800×1840", StreamMode.GAME.toastText(g.fps(StreamMode.GAME), g.display(StreamMode.GAME)))
        assertEquals(StreamPrefs(60, 1000, 60_000, 2800, 1840).copy(chroma = SHARP), g.selectFrameRate(StreamMode.GAME, 60))
        // entering Oyun with 120 stored asks for 2800×1840 right away
        settings.setModeFps(StreamMode.GAME, 120)
        val g2 = GameModeSettings(settings)
        g2.onModeChanged(StreamMode.GAME)
        assertEquals(StreamPrefs(120, 1000, 60_000, 2800, 1840).copy(chroma = SHARP), g2.prefs(StreamMode.GAME))
    }

    @Test fun picking2800InOyun120SendsAtOnce() { // T-250
        settings.setGameResolution(GameResolution.P80)
        settings.setModeFps(StreamMode.GAME, 120)
        val g = GameModeSettings(settings)
        g.onModeChanged(StreamMode.GAME)
        assertEquals(StreamPrefs(120, 1000, 60_000, 2800, 1840).copy(chroma = SHARP), g.selectGameResolution(GameResolution.P100, StreamMode.GAME))
        assertNull(g.selectGameResolution(GameResolution.P100, StreamMode.GAME)) // the same size again: nothing new
        assertEquals(StreamPrefs(120, 1000, 60_000, 1400, 920).copy(chroma = SHARP), g.selectGameResolution(GameResolution.P50, StreamMode.GAME))
    }

    @Test fun experimentalSizeNeverReachesOtherModes() {
        settings.setGameResolution(GameResolution.P100)
        val g = GameModeSettings(settings)
        for (m in nonGame) {
            g.onModeChanged(m)
            assertNull(m.id, g.display(m))
            assertEquals(m.id, 8, Codec.encodePayload(g.prefs(m).copy(chroma = 0)).size)
            assertNull(m.id, g.selectGameResolution(GameResolution.P100, m))
        }
        val off = GameModeSettings(settings, gameDisplay = false) // `--ei game_display 0`
        off.onModeChanged(StreamMode.GAME)
        assertNull(off.display(StreamMode.GAME))
    }

    // ---- applied check (PROTOCOL §0x05: full geometry) ----

    @Test fun appliedNeedsTheFullGeometry() {
        for (r in GameResolution.entries.map { it.on(matepad) }) assertTrue(r.label, r.appliedIn(cfg1x(r.widthPx, r.heightPx)))
        assertFalse(GameResolution.P66.on(NativeSize.MATEPAD).appliedIn(cfg1x(1400, 920))) // another 1x size
        assertFalse(GameResolution.P66.on(NativeSize.MATEPAD).appliedIn(StreamConfig(1, 2, 1848, 1214, 1848, 1215, 120, 1, 1, 1, 1, 1)))
        assertFalse(GameResolution.P66.on(NativeSize.MATEPAD).appliedIn(StreamConfig(1, 2, 1848, 1213, 1848, 1214, 120, 1, 1, 1, 1, 1)))
    }

    @Test fun r1400IsNotAppliedByANativeHiDpiDisplay() {
        // An old host (or `game_display_failed`) keeps the native HiDPI display: 1400×920 pt, the same as the request.
        val nativeFull = StreamConfig(1, 2, 2800, 1840, 1400, 920, 120, 60_000, 1, 1, 1, 1)
        val nativeScaled = StreamConfig(1, 2, 1848, 1214, 1400, 920, 120, 60_000, 1, 1, 1, 1) // Oyun 120 at 660
        assertEquals(1400, nativeFull.widthPt) // the width_pt-only check would say "applied"
        assertFalse(GameResolution.P50.on(NativeSize.MATEPAD).appliedIn(nativeFull))
        assertFalse(GameResolution.P50.on(NativeSize.MATEPAD).appliedIn(nativeScaled))
        assertFalse(GameResolution.P66.on(NativeSize.MATEPAD).appliedIn(nativeScaled)) // encoded size matches, display does not
        assertTrue(GameResolution.P50.on(NativeSize.MATEPAD).appliedIn(cfg1x(1400, 920)))
    }

    // ---- layout (VideoLayout.surfaceSize) ----

    /** A 1x game display config: point size = pixel size (PROTOCOL §0x05). */
    private fun cfg1x(w: Int, h: Int) = StreamConfig(1, 2, w, h, w, h, 120, 60_000, 1, 1, 1, 1)

    @Test fun gameDisplaysFillThePanelWithoutBands() {
        for (r in GameResolution.entries.map { it.on(matepad) }) assertNull(r.label, VideoLayout.surfaceSize(2800, 1840, cfg1x(r.widthPx, r.heightPx)))
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
