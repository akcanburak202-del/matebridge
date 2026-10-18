package dev.matebridge.client.camera

import dev.matebridge.client.protocol.CameraPrefs
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class CameraMathTest {
    @Test fun backCameraRotationFollowsTheDisplay() {
        // sensor mounted at 90 (typical): portrait needs 90, a landscape display needs none or a half turn
        assertEquals(90, CameraMath.rotationDegrees(90, 0, front = false))
        assertEquals(0, CameraMath.rotationDegrees(90, 90, front = false))
        assertEquals(270, CameraMath.rotationDegrees(90, 180, front = false))
        assertEquals(180, CameraMath.rotationDegrees(90, 270, front = false))
    }

    @Test fun frontCameraRotationRunsTheOtherWayAndIsNotMirrored() {
        assertEquals(270, CameraMath.rotationDegrees(270, 0, front = true))
        assertEquals(0, CameraMath.rotationDegrees(270, 90, front = true))
        assertEquals(90, CameraMath.rotationDegrees(270, 180, front = true))
        assertEquals(180, CameraMath.rotationDegrees(270, 270, front = true))
    }

    @Test fun surfaceRotationMapsToDegrees() {
        assertEquals(listOf(0, 90, 180, 270, 0), listOf(0, 1, 2, 3, 7).map { CameraMath.degreesOfSurfaceRotation(it) })
    }

    @Test fun rotationNormalisesOddInputs() {
        assertEquals(90, CameraMath.rotationDegrees(450, 360, front = false))
        assertEquals(270, CameraMath.rotationDegrees(-90, 0, front = false))
    }

    private fun corner(m: FloatArray, x: Float, y: Float) = CameraMath.apply(m, x, y).let { (a, b) -> Pair(Math.round(a * 1000) / 1000f, Math.round(b * 1000) / 1000f) }

    @Test fun mvpWithoutRotationFillsTheFrame() {
        val m = CameraMath.mvp(1920, 1080, 0, 1920, 1080)
        assertEquals(Pair(1f, 1f), corner(m, 1f, 1f))
        assertEquals(Pair(-1f, -1f), corner(m, -1f, -1f))
    }

    @Test fun mvpRotatesClockwise() {
        // a 1080x1920 buffer turned 90 degrees clockwise is a 1920x1080 landscape picture: corners map to corners
        val m = CameraMath.mvp(1080, 1920, 90, 1920, 1080)
        // buffer top-right (1,1) goes to bottom-right after a clockwise quarter turn
        assertEquals(Pair(1f, -1f), corner(m, 1f, 1f))
        // buffer top-left (-1,1) goes to top-right
        assertEquals(Pair(1f, 1f), corner(m, -1f, 1f))
        val half = CameraMath.mvp(1920, 1080, 180, 1920, 1080)
        assertEquals(Pair(-1f, -1f), corner(half, 1f, 1f))
    }

    @Test fun mvpCropsTheOverflowOfADifferentAspect() {
        // a 4:3 buffer into a 16:9 frame: the width fills the frame, the height overflows (centre crop)
        val m = CameraMath.mvp(1600, 1200, 0, 1920, 1080)
        val (x, y) = CameraMath.apply(m, 1f, 1f)
        assertEquals(1f, x, 0.001f)
        assertTrue(y > 1f)
        // a 21:9 buffer: the height fills the frame, the width overflows
        val w = CameraMath.mvp(2560, 1080, 0, 1920, 1080)
        val (wx, wy) = CameraMath.apply(w, 1f, 1f)
        assertTrue(wx > 1f)
        assertEquals(1f, wy, 0.001f)
    }

    @Test fun encoderSizeIsTheRequestedOneWhenSupported() {
        assertEquals(1920 to 1080, CameraMath.pickEncoderSize(1920, 1080) { _, _ -> true })
        assertEquals(1280 to 720, CameraMath.pickEncoderSize(1280, 720) { _, _ -> true })
    }

    @Test fun encoderSizeFallsBackToTheLargestSupportedSixteenByNine() {
        val upTo720 = { w: Int, _: Int -> w <= 1280 }
        assertEquals(1280 to 720, CameraMath.pickEncoderSize(1920, 1080, upTo720))
        val upTo500 = { w: Int, _: Int -> w <= 900 }
        assertEquals(854 to 480, CameraMath.pickEncoderSize(1920, 1080, upTo500))
        assertNull(CameraMath.pickEncoderSize(1920, 1080) { _, _ -> false })
        // the request is never exceeded
        assertEquals(960 to 540, CameraMath.pickEncoderSize(1000, 560) { w, _ -> w <= 960 })
    }

    @Test fun sourceSizeIsTheSmallestSixteenByNineAtLeastAsWide() {
        val sizes = listOf(640 to 480, 1280 to 720, 1920 to 1080, 3840 to 2160, 4000 to 3000)
        assertEquals(1920 to 1080, CameraMath.pickSource(sizes, 1920))
        assertEquals(1280 to 720, CameraMath.pickSource(sizes, 1280))
        assertEquals(3840 to 2160, CameraMath.pickSource(sizes, 3000))
        // nothing wide enough: the largest 16:9 one
        assertEquals(3840 to 2160, CameraMath.pickSource(sizes, 5000))
        // no 16:9 at all: the smallest wide enough
        assertEquals(4000 to 3000, CameraMath.pickSource(listOf(640 to 480, 4000 to 3000), 1920))
        assertNull(CameraMath.pickSource(emptyList(), 1920))
    }

    @Test fun fpsRangePrefersASteadyRate() {
        assertEquals(30 to 30, CameraMath.pickFpsRange(listOf(15 to 30, 30 to 30, 7 to 60), 30))
        assertEquals(24 to 30, CameraMath.pickFpsRange(listOf(15 to 30, 24 to 30), 30))
        assertEquals(15 to 30, CameraMath.pickFpsRange(listOf(15 to 30), 24)) // contains it, upper above
        assertEquals(15 to 24, CameraMath.pickFpsRange(listOf(10 to 15, 15 to 24), 30)) // all below: the highest
        assertNull(CameraMath.pickFpsRange(emptyList(), 30))
    }

    @Test fun prefsPolicyIsOffWithoutPermissionOrInARemoteSession() {
        val auto = CameraWish(CameraMode.AUTO, CameraFacing.BACK)
        assertEquals(CameraPrefs(CameraPrefs.MODE_AUTO, CameraPrefs.FACING_BACK), CameraPrefsPolicy.wire(auto, permissionGranted = true, remote = false))
        assertEquals(CameraPrefs(CameraPrefs.MODE_OFF, CameraPrefs.FACING_BACK), CameraPrefsPolicy.wire(auto, permissionGranted = false, remote = false))
        assertEquals(CameraPrefs(CameraPrefs.MODE_OFF, CameraPrefs.FACING_BACK), CameraPrefsPolicy.wire(auto, permissionGranted = true, remote = true))
        val off = CameraWish(CameraMode.OFF, CameraFacing.FRONT)
        assertEquals(CameraPrefs.OFF, CameraPrefsPolicy.wire(off, permissionGranted = true, remote = false))
        assertEquals(CameraPrefs.OFF, CameraPrefsPolicy.wire(CameraWish(), permissionGranted = true, remote = false)) // the defaults
    }

    @Test fun settingsParseToTheirDefaults() {
        assertEquals(CameraMode.OFF, CameraMode.parse(null))
        assertEquals(CameraMode.OFF, CameraMode.parse("garbage"))
        assertEquals(CameraMode.AUTO, CameraMode.parse("auto"))
        assertEquals(CameraFacing.FRONT, CameraFacing.parse(null))
        assertEquals(CameraFacing.BACK, CameraFacing.parse("back"))
    }

    @Test fun statusTextFollowsModePermissionAndState() {
        fun t(m: CameraMode, perm: Boolean, denied: Boolean, s: CameraUiState) = CameraStatusText.text(m, perm, denied, s)
        assertEquals("Kamera kapalı", t(CameraMode.OFF, true, false, CameraUiState.IDLE))
        assertEquals("Kamera izni yok", t(CameraMode.OFF, false, true, CameraUiState.IDLE)) // refused: back to Kapalı, says why
        assertEquals("Kamera izni yok", t(CameraMode.AUTO, false, false, CameraUiState.IDLE)) // revoked later
        assertEquals("Mac kamerayı kullanmıyor", t(CameraMode.AUTO, true, false, CameraUiState.IDLE))
        assertEquals("Kamera açık", t(CameraMode.AUTO, true, false, CameraUiState.ACTIVE))
        assertEquals("Mac'te OBS sanal kamera yok", t(CameraMode.AUTO, true, false, CameraUiState.UNAVAILABLE))
    }

    @Test fun releaseCounterGrowsFromZeroAndWrapsAtU16() {
        val c = CameraReleaseCounter()
        assertEquals(0, c.value)
        assertEquals(1, c.bump())
        assertEquals(2, c.bump())
        assertEquals(2, c.value)
        repeat(0xFFFF - 2) { c.bump() }
        assertEquals(0xFFFF, c.value)
        assertEquals(0, c.bump())
    }

    @Test fun policyCarriesTheReleaseSeqEvenWhenOff() {
        val auto = CameraWish(CameraMode.AUTO, CameraFacing.BACK)
        assertEquals(CameraPrefs(CameraPrefs.MODE_AUTO, CameraPrefs.FACING_BACK, 3), CameraPrefsPolicy.wire(auto, true, false, 3))
        assertEquals(CameraPrefs(CameraPrefs.MODE_OFF, CameraPrefs.FACING_BACK, 3), CameraPrefsPolicy.wire(auto, true, true, 3))
    }

    @Test fun openGenerationMakesEarlierAttemptsStale() {
        val g = OpenGeneration()
        val first = g.next()
        assertTrue(g.isCurrent(first))
        val second = g.next() // a facing switch while the first open is in flight
        assertFalse(g.isCurrent(first))
        assertTrue(g.isCurrent(second))
        g.next() // closeCameraOnly invalidates the pending open too
        assertFalse(g.isCurrent(second))
    }
}
