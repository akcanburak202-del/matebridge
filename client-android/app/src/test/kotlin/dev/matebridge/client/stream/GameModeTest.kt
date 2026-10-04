package dev.matebridge.client.stream

import dev.matebridge.client.audio.AudioOutPref
import dev.matebridge.client.protocol.StreamPrefs
import dev.matebridge.client.session.KeyValueStore
import dev.matebridge.client.session.Settings
import dev.matebridge.client.video.VideoRenderer
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** T-109 (decision 0014) and T-223 (decision 0030): the temporary mode layers (Oyun, Çizim) and the jitter buffer. */
class GameModeTest {
    /** Records every write, so a test can prove the stored settings were never touched. */
    private class MemStore : KeyValueStore {
        val map = HashMap<String, String>()
        val writes = ArrayList<String>()
        override fun getString(key: String) = map[key]
        override fun putString(key: String, value: String) { writes += key; map[key] = value }
    }

    private val store = MemStore()
    private val settings = Settings(store)

    private val enterGame = GameModeSettings.Transition(GameModeSettings.Change.ENTER, StreamMode.GAME)
    private val exitGame = GameModeSettings.Transition(GameModeSettings.Change.EXIT, StreamMode.GAME)
    private val enterDrawing = GameModeSettings.Transition(GameModeSettings.Change.ENTER, StreamMode.DRAWING)
    private val exitDrawing = GameModeSettings.Transition(GameModeSettings.Change.EXIT, StreamMode.DRAWING)

    /** User's stored choices: TRACK audio, trail and dot on, fingers on; bit rate as given. */
    private fun storeUserChoices(bitrateKbps: Long = Bitrate.AUTO_KBPS) {
        settings.setBitrateKbps(bitrateKbps)
        settings.setAudioOut(AudioOutPref.TRACK)
        settings.setPenTrail(true)
        settings.setPenDot(true)
        settings.setFingerTouchDisabled(false)
        store.writes.clear()
    }

    private val stored = {
        GameModeSettings.Values(settings.bitrateKbps(), settings.audioOut(), settings.penTrail(), settings.penDot(), settings.fingerTouchDisabled())
    }

    private fun values(bitrate: Long, audio: AudioOutPref, trail: Boolean, dot: Boolean, finger: Boolean = false) =
        GameModeSettings.Values(bitrate, audio, trail, dot, finger)

    // ---- Oyun layer (decision 0014 §3) ----

    @Test fun enterGameBuildsTheGameDefaults() {
        storeUserChoices()
        val g = GameModeSettings(settings)
        assertFalse(g.active)
        assertEquals(enterGame, g.onModeChanged(StreamMode.GAME))
        assertTrue(g.active)
        assertTrue(g.gameActive)
        assertEquals(StreamMode.GAME, g.modeLayer)
        assertEquals(values(60_000, AudioOutPref.AUTO, trail = false, dot = false), g.effective())
        assertEquals(StreamPrefs(60, 1000, 60_000, 1848, 1214), g.prefs(StreamMode.GAME)) // card: Oyun 60 1848×1214
        assertTrue(store.writes.isEmpty())
    }

    @Test fun gameKeepsTheStoredFingerSwitch() {
        storeUserChoices()
        settings.setFingerTouchDisabled(true)
        val g = GameModeSettings(settings)
        g.onModeChanged(StreamMode.GAME)
        assertTrue(g.fingerOff)
        g.onModeChanged(StreamMode.DAILY)
        settings.setFingerTouchDisabled(false)
        g.onModeChanged(StreamMode.GAME)
        assertFalse(g.fingerOff)
    }

    @Test fun storedNonAutoBitrateIsKept() {
        storeUserChoices(bitrateKbps = 30_000)
        val g = GameModeSettings(settings)
        g.onModeChanged(StreamMode.GAME)
        assertEquals(30_000L, g.bitrateKbps)
        assertEquals(StreamPrefs(60, 1000, 30_000, 1848, 1214), g.prefs(StreamMode.GAME))
        storeUserChoices(bitrateKbps = 100_000)
        val g2 = GameModeSettings(settings)
        g2.onModeChanged(StreamMode.GAME)
        assertEquals(100_000L, g2.bitrateKbps)
    }

    @Test fun changesInAModeLayerOnlyTouchTheLayer() {
        for (mode in listOf(StreamMode.GAME, StreamMode.DRAWING)) {
            storeUserChoices()
            val before = stored()
            val g = GameModeSettings(settings)
            g.onModeChanged(mode)
            g.setBitrateKbps(15_000)
            g.setAudioOut(AudioOutPref.TRACK)
            g.setPenTrail(false)
            g.setPenDot(false)
            g.setFingerOff(true)
            assertEquals(values(15_000, AudioOutPref.TRACK, trail = false, dot = false, finger = true), g.effective())
            g.setBitrateKbps(12_345) // not an option: Otomatik, still only in the layer
            assertEquals(Bitrate.AUTO_KBPS, g.bitrateKbps)
            assertTrue(mode.id, store.writes.isEmpty())
            assertEquals(before, stored())
            assertEquals(before, g.saved())
        }
    }

    @Test fun exitRestoresTheStoredValuesAndReentryStartsFresh() {
        storeUserChoices()
        val before = stored()
        val g = GameModeSettings(settings)
        g.onModeChanged(StreamMode.GAME)
        g.setPenTrail(true)
        g.setBitrateKbps(100_000)
        assertEquals(exitGame, g.onModeChanged(StreamMode.DAILY))
        assertFalse(g.active)
        assertNull(g.modeLayer)
        assertEquals(before, g.effective())
        assertEquals(StreamPrefs(120, 1000, 0), g.prefs(StreamMode.DAILY))
        assertEquals(enterGame, g.onModeChanged(StreamMode.GAME))
        assertEquals(values(60_000, AudioOutPref.AUTO, trail = false, dot = false), g.effective())
        assertTrue(store.writes.isEmpty())
        assertEquals(before, stored())
    }

    @Test fun outsideALayerWritesGoToTheStoredSettings() {
        val g = GameModeSettings(settings)
        g.onModeChanged(StreamMode.DAILY)
        g.setBitrateKbps(30_000)
        g.setAudioOut(AudioOutPref.TRACK)
        g.setPenTrail(true)
        g.setPenDot(true)
        g.setFingerOff(true)
        assertEquals(30_000L, settings.bitrateKbps())
        assertEquals(AudioOutPref.TRACK, settings.audioOut())
        assertTrue(settings.penTrail())
        assertTrue(settings.penDot())
        assertTrue(settings.fingerTouchDisabled())
        assertEquals(StreamPrefs(120, 1000, 30_000), g.prefs(StreamMode.DAILY))
        // and Oyun then starts from those stored values (30 Mbps kept, the rest game defaults, fingers as stored)
        g.onModeChanged(StreamMode.GAME)
        assertEquals(values(30_000, AudioOutPref.AUTO, trail = false, dot = false, finger = true), g.effective())
    }

    // ---- Çizim layer (decision 0030 §1) ----

    @Test fun enterDrawingTurnsFingersOffAndRaisesAutoBitrate() {
        storeUserChoices()
        val g = GameModeSettings(settings)
        assertEquals(enterDrawing, g.onModeChanged(StreamMode.DRAWING))
        assertTrue(g.active)
        assertFalse(g.gameActive)
        assertEquals(StreamMode.DRAWING, g.modeLayer)
        // fingers off + 60 Mbps; audio and pen trail/dot stay the user's
        assertEquals(values(60_000, AudioOutPref.TRACK, trail = true, dot = true, finger = true), g.effective())
        assertTrue(g.fingerOff)
        assertEquals(StreamPrefs(120, 1000, 60_000), g.prefs(StreamMode.DRAWING)) // no game display group
        assertTrue(store.writes.isEmpty())
    }

    @Test fun drawingKeepsAStoredBitrate() {
        storeUserChoices(bitrateKbps = 30_000)
        val g = GameModeSettings(settings)
        g.onModeChanged(StreamMode.DRAWING)
        assertEquals(30_000L, g.bitrateKbps)
        assertEquals(StreamPrefs(120, 1000, 30_000), g.prefs(StreamMode.DRAWING))
    }

    @Test fun leavingDrawingBringsTheStoredValuesBackExactly() {
        storeUserChoices(bitrateKbps = 15_000)
        val before = stored()
        val g = GameModeSettings(settings)
        g.onModeChanged(StreamMode.DRAWING)
        g.setFingerOff(false) // the user turns fingers on again while drawing: layer only
        g.setBitrateKbps(100_000)
        assertFalse(g.fingerOff)
        assertEquals(exitDrawing, g.onModeChanged(StreamMode.DAILY))
        assertEquals(before, g.effective())
        assertFalse(g.fingerOff)
        assertEquals(15_000L, g.bitrateKbps)
        assertEquals(enterDrawing, g.onModeChanged(StreamMode.DRAWING)) // fresh defaults on re-entry
        assertTrue(g.fingerOff)
        assertEquals(15_000L, g.bitrateKbps)
        assertTrue(store.writes.isEmpty())
        assertEquals(before, stored())
    }

    @Test fun storedFingerOffIsStillOffAfterDrawing() {
        settings.setFingerTouchDisabled(true)
        store.writes.clear()
        val g = GameModeSettings(settings)
        g.onModeChanged(StreamMode.DRAWING)
        assertTrue(g.fingerOff)
        g.setFingerOff(false)
        g.onModeChanged(StreamMode.DAILY)
        assertTrue(g.fingerOff) // the user's stored choice
    }

    @Test fun drawingToGameAndBackRebuildsTheLayer() {
        storeUserChoices()
        val g = GameModeSettings(settings)
        g.onModeChanged(StreamMode.DRAWING)
        g.setBitrateKbps(15_000)
        assertEquals(enterGame, g.onModeChanged(StreamMode.GAME)) // a switch is an ENTER of the new layer
        assertEquals(StreamMode.GAME, g.modeLayer)
        assertEquals(values(60_000, AudioOutPref.AUTO, trail = false, dot = false), g.effective()) // fingers on again, fresh
        assertEquals(enterDrawing, g.onModeChanged(StreamMode.DRAWING))
        assertEquals(values(60_000, AudioOutPref.TRACK, trail = true, dot = true, finger = true), g.effective())
        assertTrue(store.writes.isEmpty())
    }

    @Test fun onlyRealTransitionsChangeAnything() {
        val g = GameModeSettings(settings)
        assertNull(g.onModeChanged(StreamMode.DAILY))
        assertEquals(enterGame, g.onModeChanged(StreamMode.GAME))
        g.setPenDot(true)
        assertNull(g.onModeChanged(StreamMode.GAME)) // same mode keeps the layer
        assertTrue(g.penDot)
        assertEquals(exitGame, g.onModeChanged(StreamMode.DAILY))
        assertEquals(enterDrawing, g.onModeChanged(StreamMode.DRAWING))
        g.setFingerOff(false)
        assertNull(g.onModeChanged(StreamMode.DRAWING))
        assertFalse(g.fingerOff)
    }

    @Test fun appStartedWithStoredGameOrDrawingStartsWithTheDefaults() {
        storeUserChoices()
        settings.setStreamMode(StreamMode.GAME)
        store.writes.clear()
        // a new process: fresh objects over the same store
        val s2 = Settings(store)
        val g = GameModeSettings(s2)
        assertEquals(enterGame, g.onModeChanged(s2.streamMode()))
        assertEquals(values(60_000, AudioOutPref.AUTO, trail = false, dot = false), g.effective())
        assertEquals(StreamPrefs(60, 1000, 60_000, 1848, 1214), g.prefs(s2.streamMode()))
        assertTrue(store.writes.isEmpty())
        assertEquals(AudioOutPref.TRACK, s2.audioOut())
        assertTrue(s2.penTrail())

        settings.setStreamMode(StreamMode.DRAWING)
        val s3 = Settings(store)
        val d = GameModeSettings(s3)
        assertEquals(enterDrawing, d.onModeChanged(s3.streamMode()))
        assertTrue(d.fingerOff)
        assertFalse(s3.fingerTouchDisabled())
    }

    // ---- frame rate in the prefs (decision 0030 §2) ----

    @Test fun cardPrefsBytes() {
        val g = GameModeSettings(settings)
        g.onModeChanged(StreamMode.DAILY)
        assertEquals(StreamPrefs(120, 1000, 0, 0, 0), g.prefs(StreamMode.DAILY)) // Günlük 120 = (120, 1000, auto, 0×0)
        assertEquals(StreamPrefs(120, 1000), g.prefs(StreamMode.DAILY))
        g.selectFrameRate(StreamMode.DAILY, 60)
        assertEquals(StreamPrefs(60, 1000), g.prefs(StreamMode.DAILY))
        g.onModeChanged(StreamMode.GAME)
        assertEquals(StreamPrefs(60, 1000, 60_000, 1848, 1214), g.prefs(StreamMode.GAME)) // Oyun 60 1848×1214
    }

    @Test fun selectingTheFrameRateStoresItPerModeAndReturnsOnePrefs() {
        val g = GameModeSettings(settings)
        g.onModeChanged(StreamMode.DAILY)
        assertEquals(StreamPrefs(60, 1000, 0), g.selectFrameRate(StreamMode.DAILY, 60))
        assertEquals("60", store.map["fps_daily"])
        assertNull(store.map["fps_game"])
        g.onModeChanged(StreamMode.GAME)
        assertEquals(StreamPrefs(120, 1000, 60_000, 1848, 1214), g.selectFrameRate(StreamMode.GAME, 120))
        assertEquals(60, g.fps(StreamMode.DAILY))
        assertEquals(120, g.fps(StreamMode.GAME))
        // back to Günlük: its own 60 again
        g.onModeChanged(StreamMode.DAILY)
        assertEquals(StreamPrefs(60, 1000, 0), g.prefs(StreamMode.DAILY))
    }

    @Test fun drawingFrameRateCannotBeChanged() {
        val g = GameModeSettings(settings)
        g.onModeChanged(StreamMode.DRAWING)
        assertNull(g.selectFrameRate(StreamMode.DRAWING, 60))
        assertEquals(120, g.fps(StreamMode.DRAWING))
        assertEquals(120, g.prefs(StreamMode.DRAWING).fps)
        assertNull(g.selectFrameRate(StreamMode.DAILY, 90)) // not an option
        assertTrue(store.writes.isEmpty())
    }

    // ---- markers and logs ----

    @Test fun markersFollowTheLayersOverrides() {
        val o = GameModeSettings.Override.entries
        assertEquals(listOf("", "", "", ""), o.map { GameModeSettings.marker(null, it) })
        assertEquals(
            listOf(" (oyun modu)", " (oyun modu)", " (oyun modu)", ""),
            o.map { GameModeSettings.marker(StreamMode.GAME, it) },
        ) // bitrate, audio, pen; not finger
        assertEquals(
            listOf(" (çizim modu)", "", "", " (çizim modu)"),
            o.map { GameModeSettings.marker(StreamMode.DRAWING, it) },
        ) // bitrate, finger
        assertEquals("", GameModeSettings.marker(StreamMode.DAILY, GameModeSettings.Override.BITRATE))
        assertEquals("bitrate,audio,pen", GameModeSettings.overridesText(StreamMode.GAME))
        assertEquals("bitrate,finger", GameModeSettings.overridesText(StreamMode.DRAWING))
    }

    // ---- jitter ----

    @Test fun game120And60ShareNothingAnyMoreButJitterIsAdaptiveEverywhere() {
        // Decision 0014 §2 amended 2026-10-04 (T-211): the adaptive pacer in every mode, Oyun included.
        val adaptive = VideoRenderer.BUFFER_ADAPTIVE
        val fromMode = GameJitter.Choice(adaptive, GameJitter.Source.MODE)
        assertEquals(fromMode, GameJitter.choose(adaptive, null, game = false))
        assertEquals(fromMode, GameJitter.choose(adaptive, null, game = true))
        val g = GameModeSettings(settings)
        assertEquals(enterGame, g.onModeChanged(StreamMode.GAME))
        val c = GameJitter.choose(adaptive, null, g.gameActive)
        assertEquals(fromMode, c)
        assertEquals(
            "mode=game action=enter overrides=bitrate,audio,pen jitter=adaptive bitrate_kbps=60000 audio_out=auto finger_off=0",
            GameModeSettings.logFields(enterGame, c, g.effective()),
        )
    }

    @Test fun jitterSurvivesExitAndReentry() {
        val adaptive = VideoRenderer.BUFFER_ADAPTIVE
        val g = GameModeSettings(settings)
        for (mode in listOf(StreamMode.GAME, StreamMode.DAILY, StreamMode.DRAWING, StreamMode.GAME)) {
            g.onModeChanged(mode)
            assertEquals(mode.isGame, g.gameActive)
            assertEquals(GameJitter.Choice(adaptive, GameJitter.Source.MODE), GameJitter.choose(adaptive, null, g.gameActive))
        }
        // `--ez dev true --ei jitter 0`: buffer 0 in and out of a layer, across re-entry
        val g2 = GameModeSettings(settings)
        for (mode in listOf(StreamMode.GAME, StreamMode.DAILY, StreamMode.DRAWING)) {
            g2.onModeChanged(mode)
            assertEquals(GameJitter.Choice(0, GameJitter.Source.EXTRA), GameJitter.choose(0, GameJitter.Source.EXTRA, g2.gameActive))
        }
    }

    @Test fun launchJitterWinsOverTheMode() {
        assertEquals(GameJitter.Choice(2, GameJitter.Source.EXTRA), GameJitter.choose(2, GameJitter.Source.EXTRA, game = true))
        assertEquals(GameJitter.Choice(1, GameJitter.Source.EXTRA), GameJitter.choose(1, GameJitter.Source.EXTRA, game = false))
        val adaptive = VideoRenderer.BUFFER_ADAPTIVE
        val c = GameJitter.choose(adaptive, GameJitter.Source.EXTRA, game = true) // T-210
        assertEquals(GameJitter.Choice(adaptive, GameJitter.Source.EXTRA), c)
        assertEquals("adaptive", GameJitter.label(c.bufferFrames))
    }

    @Test fun logLines() {
        val e = values(60_000, AudioOutPref.AUTO, trail = false, dot = false)
        assertEquals(
            "mode=game action=enter overrides=bitrate,audio,pen jitter=0 bitrate_kbps=60000 audio_out=auto finger_off=0",
            GameModeSettings.logFields(enterGame, GameJitter.Choice(0, GameJitter.Source.MODE), e),
        )
        assertEquals(
            "mode=game action=exit overrides=bitrate,audio,pen jitter=adaptive bitrate_kbps=0 audio_out=track finger_off=0",
            GameModeSettings.logFields(
                exitGame,
                GameJitter.Choice(VideoRenderer.BUFFER_ADAPTIVE, GameJitter.Source.MODE),
                e.copy(bitrateKbps = 0, audioOut = AudioOutPref.TRACK),
            ),
        )
        assertEquals(
            "mode=drawing action=enter overrides=bitrate,finger jitter=2 jitter_src=extra bitrate_kbps=60000 audio_out=auto finger_off=1",
            GameModeSettings.logFields(enterDrawing, GameJitter.Choice(2, GameJitter.Source.EXTRA), e.copy(fingerOff = true)),
        )
    }
}
