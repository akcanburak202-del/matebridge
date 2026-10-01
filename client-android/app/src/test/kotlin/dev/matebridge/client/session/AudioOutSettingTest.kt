package dev.matebridge.client.session

import dev.matebridge.client.audio.AudioOutPref
import org.junit.Assert.assertEquals
import org.junit.Test

/** T-101: the persisted "Ses çıkışı" setting. */
class AudioOutSettingTest {
    private val map = HashMap<String, String>()
    private val settings = Settings(object : KeyValueStore {
        override fun getString(key: String): String? = map[key]
        override fun putString(key: String, value: String) { map[key] = value }
    })

    @Test fun defaultIsLowLatency() {
        assertEquals(AudioOutPref.AUTO, settings.audioOut())
    }

    @Test fun persistsBothChoices() {
        settings.setAudioOut(AudioOutPref.TRACK)
        assertEquals("track", map["audio_out"])
        assertEquals(AudioOutPref.TRACK, settings.audioOut())
        settings.setAudioOut(AudioOutPref.AUTO)
        assertEquals(AudioOutPref.AUTO, settings.audioOut())
    }

    @Test fun unknownStoredValueIsLowLatency() {
        map["audio_out"] = "oboe"
        assertEquals(AudioOutPref.AUTO, settings.audioOut())
    }

    @Test fun launchExtraIsNotStored() {
        settings.setAudioOut(AudioOutPref.TRACK)
        val r = AudioOutPref.resolve("aaudio", settings.audioOut())
        assertEquals(AudioOutPref.AAUDIO, r.pref)
        assertEquals(AudioOutPref.TRACK, settings.audioOut())
        assertEquals("track", map["audio_out"])
    }
}
