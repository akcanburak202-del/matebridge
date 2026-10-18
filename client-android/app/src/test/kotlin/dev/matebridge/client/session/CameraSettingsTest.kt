package dev.matebridge.client.session

import dev.matebridge.client.camera.CameraFacing
import dev.matebridge.client.camera.CameraMode
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** T-355: the camera settings persist, default to Kapalı / Ön, and "Varsayılanlara dön" turns the camera off. */
class CameraSettingsTest {
    private val map = HashMap<String, String>()
    private val store = object : KeyValueStore {
        override fun getString(key: String): String? = map[key]
        override fun putString(key: String, value: String) { map[key] = value }
        override fun remove(key: String) { map.remove(key) }
    }

    @Test fun defaultsAreOffAndFront() {
        val s = Settings(store)
        assertEquals(CameraMode.OFF, s.cameraMode())
        assertEquals(CameraFacing.FRONT, s.cameraFacing())
    }

    @Test fun choicesPersistAndUnknownValuesFallBack() {
        Settings(store).setCameraMode(CameraMode.AUTO)
        Settings(store).setCameraFacing(CameraFacing.BACK)
        assertEquals(CameraMode.AUTO, Settings(store).cameraMode())
        assertEquals(CameraFacing.BACK, Settings(store).cameraFacing())
        map["camera_mode"] = "bogus"
        map["camera_facing"] = "sideways"
        assertEquals(CameraMode.OFF, Settings(store).cameraMode())
        assertEquals(CameraFacing.FRONT, Settings(store).cameraFacing())
    }

    @Test fun resetToDefaultsTurnsTheCameraOff() {
        val s = Settings(store)
        s.setCameraMode(CameraMode.AUTO)
        s.setCameraFacing(CameraFacing.BACK)
        assertTrue(s.resetToDefaults() >= 2)
        assertEquals(CameraMode.OFF, s.cameraMode())
        assertEquals(CameraFacing.FRONT, s.cameraFacing())
    }
}
