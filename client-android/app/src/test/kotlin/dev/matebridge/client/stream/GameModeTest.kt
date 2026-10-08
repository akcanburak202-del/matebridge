package dev.matebridge.client.stream

import dev.matebridge.client.audio.AudioOutPref
import dev.matebridge.client.input.FingerPolicy
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
/** No colour store: the default "Renk" is Keskin kenarlar (decision 0034 addendum), so `chroma` is 1. */
private const val SHARP = StreamPrefs.CHROMA_SHARP

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
        GameModeSettings.Values(
            settings.bitrateKbps(), settings.audioOut(), settings.penTrail(), settings.penDot(),
            if (settings.fingerTouchDisabled()) FingerPolicy.OFF else FingerPolicy.ALL,
        )
    }

    private fun values(bitrate: Long, audio: AudioOutPref, trail: Boolean, dot: Boolean, finger: FingerPolicy = FingerPolicy.ALL) =
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
        assertEquals(StreamPrefs(60, 1000, 60_000, 1848, 1214).copy(chroma = SHARP), g.prefs(StreamMode.GAME)) // card: Oyun 60 1848×1214
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
        assertEquals(StreamPrefs(60, 1000, 30_000, 1848, 1214).copy(chroma = SHARP), g.prefs(StreamMode.GAME))
        storeUserChoices(bitrateKbps = 100_000)
        val g2 = GameModeSettings(settings)
        g2.onModeChanged(StreamMode.GAME)
        assertEquals(100_000L, g2.bitrateKbps)
    }

    @Test fun overriddenSettingsOfTheGameLayerOnlyTouchTheLayer() {
        storeUserChoices()
        val before = stored()
        val g = GameModeSettings(settings)
        g.onModeChanged(StreamMode.GAME)
        g.setBitrateKbps(15_000)
        g.setAudioOut(AudioOutPref.TRACK)
        g.setPenTrail(true)
        g.setPenDot(true)
        assertEquals(values(15_000, AudioOutPref.TRACK, trail = true, dot = true), g.effective())
        g.setBitrateKbps(12_345) // not an option: Otomatik, still only in the layer
        assertEquals(Bitrate.AUTO_KBPS, g.bitrateKbps)
        assertTrue(store.writes.isEmpty())
        assertEquals(before, stored())
        assertEquals(before, g.saved())
    }

    @Test fun overriddenSettingsOfTheDrawingLayerOnlyTouchTheLayer() {
        storeUserChoices()
        val before = stored()
        val g = GameModeSettings(settings)
        g.onModeChanged(StreamMode.DRAWING)
        g.setBitrateKbps(15_000)
        g.setFingerOff(true) // Çizim overrides the finger policy: fully off, layer only
        assertEquals(values(15_000, AudioOutPref.TRACK, trail = true, dot = true, finger = FingerPolicy.OFF), g.effective())
        assertTrue(store.writes.isEmpty())
        assertEquals(before, stored())
    }

    // P2-1 (Codex): a setting the layer does not override is a normal persistent change, never a temporary one.

    @Test fun fingerSwitchChangedInGameIsStoredAndSurvivesTheModeChange() {
        storeUserChoices()
        val g = GameModeSettings(settings)
        g.onModeChanged(StreamMode.GAME)
        g.setFingerOff(true) // Oyun does not override the finger switch
        assertTrue(settings.fingerTouchDisabled())
        assertTrue(g.fingerOff) // and the layer follows
        assertEquals(FingerPolicy.OFF, g.fingers)
        g.onModeChanged(StreamMode.DAILY)
        assertTrue(g.fingerOff)
        assertTrue(Settings(store).fingerTouchDisabled()) // also after a restart
        // and the other direction
        g.onModeChanged(StreamMode.GAME)
        g.setFingerOff(false)
        assertFalse(settings.fingerTouchDisabled())
        assertEquals(FingerPolicy.ALL, g.fingers)
        g.onModeChanged(StreamMode.DAILY)
        assertFalse(g.fingerOff)
    }

    @Test fun audioAndPenOverlayChangedInDrawingAreStoredAndSurviveTheModeChange() {
        storeUserChoices()
        settings.setAudioOut(AudioOutPref.AUTO)
        settings.setPenTrail(false)
        settings.setPenDot(false)
        store.writes.clear()
        val g = GameModeSettings(settings)
        g.onModeChanged(StreamMode.DRAWING) // Çizim overrides only bit rate and fingers
        g.setAudioOut(AudioOutPref.TRACK)
        g.setPenTrail(true)
        g.setPenDot(true)
        assertEquals(AudioOutPref.TRACK, settings.audioOut())
        assertTrue(settings.penTrail())
        assertTrue(settings.penDot())
        assertEquals(AudioOutPref.TRACK, g.audioOut) // the layer's copy follows
        assertTrue(g.penTrail)
        assertTrue(g.penDot)
        assertEquals(setOf("audio_out", "pen_trail", "pen_dot"), store.writes.toSet())
        assertEquals(exitDrawing, g.onModeChanged(StreamMode.DAILY))
        assertEquals(AudioOutPref.TRACK, g.audioOut)
        assertTrue(g.penTrail)
        assertTrue(g.penDot)
        // Çizim's own overrides are still temporary: the bit rate
        g.onModeChanged(StreamMode.DRAWING)
        store.writes.clear()
        g.setBitrateKbps(100_000)
        assertTrue(store.writes.isEmpty())
        assertEquals(Bitrate.AUTO_KBPS, settings.bitrateKbps())
    }

    @Test fun bitrateIsTemporaryInBothLayers() {
        for (mode in listOf(StreamMode.GAME, StreamMode.DRAWING)) {
            val g = GameModeSettings(settings)
            g.onModeChanged(mode)
            store.writes.clear()
            g.setBitrateKbps(30_000)
            assertEquals(mode.id, 30_000L, g.bitrateKbps)
            assertEquals(mode.id, Bitrate.AUTO_KBPS, settings.bitrateKbps())
            assertTrue(mode.id, store.writes.isEmpty())
            g.onModeChanged(StreamMode.DAILY)
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
        assertEquals(StreamPrefs(120, 1000, 0).copy(chroma = SHARP), g.prefs(StreamMode.DAILY))
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
        assertEquals(StreamPrefs(120, 1000, 30_000).copy(chroma = SHARP), g.prefs(StreamMode.DAILY))
        // and Oyun then starts from those stored values (30 Mbps kept, the rest game defaults, fingers as stored)
        g.onModeChanged(StreamMode.GAME)
        assertEquals(values(30_000, AudioOutPref.AUTO, trail = false, dot = false, finger = FingerPolicy.OFF), g.effective())
    }

    // ---- Çizim layer (decision 0030 §1) ----

    @Test fun enterDrawingMakesFingersGesturesOnlyAndRaisesAutoBitrate() {
        storeUserChoices()
        val g = GameModeSettings(settings)
        assertEquals(enterDrawing, g.onModeChanged(StreamMode.DRAWING))
        assertTrue(g.active)
        assertFalse(g.gameActive)
        assertEquals(StreamMode.DRAWING, g.modeLayer)
        // gestures-only fingers + 60 Mbps; audio and pen trail/dot stay the user's
        assertEquals(values(60_000, AudioOutPref.TRACK, trail = true, dot = true, finger = FingerPolicy.GESTURES_ONLY), g.effective())
        assertEquals(FingerPolicy.GESTURES_ONLY, g.fingers)
        assertFalse(g.fingerOff) // not the "tamamen kapat" switch: pinch and two-finger scroll still work
        assertEquals(StreamPrefs(120, 1000, 60_000).copy(chroma = SHARP), g.prefs(StreamMode.DRAWING)) // no game display group
        assertTrue(store.writes.isEmpty())
    }

    @Test fun drawingKeepsAStoredBitrate() {
        storeUserChoices(bitrateKbps = 30_000)
        val g = GameModeSettings(settings)
        g.onModeChanged(StreamMode.DRAWING)
        assertEquals(30_000L, g.bitrateKbps)
        assertEquals(StreamPrefs(120, 1000, 30_000).copy(chroma = SHARP), g.prefs(StreamMode.DRAWING))
    }

    @Test fun leavingDrawingBringsTheStoredValuesBackExactly() {
        storeUserChoices(bitrateKbps = 15_000)
        val before = stored()
        val g = GameModeSettings(settings)
        g.onModeChanged(StreamMode.DRAWING)
        g.setFingerOff(true) // the user turns fingers fully off while drawing: layer only
        g.setBitrateKbps(100_000)
        assertEquals(FingerPolicy.OFF, g.fingers)
        assertEquals(exitDrawing, g.onModeChanged(StreamMode.DAILY))
        assertEquals(before, g.effective())
        assertEquals(FingerPolicy.ALL, g.fingers)
        assertEquals(15_000L, g.bitrateKbps)
        assertEquals(enterDrawing, g.onModeChanged(StreamMode.DRAWING)) // fresh defaults on re-entry
        assertEquals(FingerPolicy.GESTURES_ONLY, g.fingers)
        assertEquals(15_000L, g.bitrateKbps)
        assertTrue(store.writes.isEmpty())
        assertEquals(before, stored())
    }

    @Test fun storedFingerOffStaysFullyOffInAndAfterDrawing() {
        settings.setFingerTouchDisabled(true)
        store.writes.clear()
        val g = GameModeSettings(settings)
        g.onModeChanged(StreamMode.DRAWING)
        assertEquals(FingerPolicy.OFF, g.fingers) // stronger than Çizim's own policy
        g.setFingerOff(false) // inside Çizim: back to Çizim's gestures-only, layer only
        assertEquals(FingerPolicy.GESTURES_ONLY, g.fingers)
        assertTrue(settings.fingerTouchDisabled())
        g.onModeChanged(StreamMode.DAILY)
        assertTrue(g.fingerOff) // the user's stored choice
        assertEquals(FingerPolicy.OFF, g.fingers)
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
        assertEquals(values(60_000, AudioOutPref.TRACK, trail = true, dot = true, finger = FingerPolicy.GESTURES_ONLY), g.effective())
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
        g.setFingerOff(true)
        assertNull(g.onModeChanged(StreamMode.DRAWING))
        assertTrue(g.fingerOff) // the same layer is kept
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
        assertEquals(StreamPrefs(60, 1000, 60_000, 1848, 1214).copy(chroma = SHARP), g.prefs(s2.streamMode()))
        assertTrue(store.writes.isEmpty())
        assertEquals(AudioOutPref.TRACK, s2.audioOut())
        assertTrue(s2.penTrail())

        settings.setStreamMode(StreamMode.DRAWING)
        val s3 = Settings(store)
        val d = GameModeSettings(s3)
        assertEquals(enterDrawing, d.onModeChanged(s3.streamMode()))
        assertEquals(FingerPolicy.GESTURES_ONLY, d.fingers)
        assertFalse(s3.fingerTouchDisabled())
    }

    // ---- frame rate in the prefs (decision 0030 §2) ----

    @Test fun cardPrefsBytes() {
        val g = GameModeSettings(settings)
        g.onModeChanged(StreamMode.DAILY)
        assertEquals(StreamPrefs(120, 1000, 0, 0, 0).copy(chroma = SHARP), g.prefs(StreamMode.DAILY)) // Günlük 120 = (120, 1000, auto, 0×0)
        assertEquals(StreamPrefs(120, 1000).copy(chroma = SHARP), g.prefs(StreamMode.DAILY))
        g.selectFrameRate(StreamMode.DAILY, 60)
        assertEquals(StreamPrefs(60, 1000).copy(chroma = SHARP), g.prefs(StreamMode.DAILY))
        g.onModeChanged(StreamMode.GAME)
        assertEquals(StreamPrefs(60, 1000, 60_000, 1848, 1214).copy(chroma = SHARP), g.prefs(StreamMode.GAME)) // Oyun 60 1848×1214
    }

    @Test fun selectingTheFrameRateStoresItPerModeAndReturnsOnePrefs() {
        val g = GameModeSettings(settings)
        g.onModeChanged(StreamMode.DAILY)
        assertEquals(StreamPrefs(60, 1000, 0).copy(chroma = SHARP), g.selectFrameRate(StreamMode.DAILY, 60))
        assertEquals("60", store.map["fps_daily"])
        assertNull(store.map["fps_game"])
        g.onModeChanged(StreamMode.GAME)
        assertEquals(StreamPrefs(120, 1000, 60_000, 1848, 1214).copy(chroma = SHARP), g.selectFrameRate(StreamMode.GAME, 120))
        assertEquals(60, g.fps(StreamMode.DAILY))
        assertEquals(120, g.fps(StreamMode.GAME))
        // back to Günlük: its own 60 again
        g.onModeChanged(StreamMode.DAILY)
        assertEquals(StreamPrefs(60, 1000, 0).copy(chroma = SHARP), g.prefs(StreamMode.DAILY))
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
    // ---- log line ----

    @Test fun logLines() {
        val e = values(60_000, AudioOutPref.AUTO, trail = false, dot = false)
        assertEquals(
            "mode=game action=enter overrides=bitrate,audio,pen bitrate_kbps=60000 audio_out=auto fingers=all",
            GameModeSettings.logFields(enterGame, e),
        )
        assertEquals(
            "mode=game action=exit overrides=bitrate,audio,pen bitrate_kbps=0 audio_out=track fingers=all",
            GameModeSettings.logFields(exitGame, e.copy(bitrateKbps = 0, audioOut = AudioOutPref.TRACK)),
        )
        assertEquals(
            "mode=drawing action=enter overrides=bitrate,finger bitrate_kbps=60000 audio_out=auto fingers=gestures",
            GameModeSettings.logFields(enterDrawing, e.copy(fingers = FingerPolicy.GESTURES_ONLY)),
        )
    }
}
