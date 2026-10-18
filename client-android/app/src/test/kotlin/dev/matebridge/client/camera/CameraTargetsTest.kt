package dev.matebridge.client.camera

import dev.matebridge.client.protocol.CameraPrefs
import dev.matebridge.client.protocol.Codec
import dev.matebridge.client.protocol.MsgType
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class CameraTargetsTest {
    private val front = CamInfo("1", back = false, focalMm = 2.7f)
    // The MatePad: back "0" is a logical multi-camera over physical "2" (6.98 mm) and "4" (1.95 mm).
    private val logicalBack = CamInfo("0", back = true, focalMm = 6.98f, physical = mapOf("2" to 6.98f, "4" to 1.95f))

    @Test fun plainPicksTheFirstCameraOfTheFacing() {
        val cams = listOf(logicalBack, front)
        assertEquals(CameraTarget("0", null, "0"), CameraTargets.resolve(cams, CameraFacing.BACK))
        assertEquals(CameraTarget("1", null, "1"), CameraTargets.resolve(cams, CameraFacing.FRONT))
        assertNull(CameraTargets.resolve(listOf(front), CameraFacing.BACK))
    }

    @Test fun pathAUsesASeparateShorterFocalBackCamera() {
        val cams = listOf(CamInfo("0", true, 6.0f), front, CamInfo("2", true, 2.0f), CamInfo("3", true, 4.5f))
        assertEquals(CameraTarget("2", null, "2"), CameraTargets.wide(cams))
    }

    @Test fun pathBOpensTheLogicalCameraWithTheShortestFocalPhysicalId() {
        assertEquals(CameraTarget("0", "4", "4"), CameraTargets.wide(listOf(logicalBack, front)))
    }

    @Test fun pathATakesPrecedenceOverPathB() {
        val cams = listOf(logicalBack, CamInfo("5", true, 6.5f), CamInfo("6", true, 1.8f))
        assertEquals(CameraTarget("6", null, "6"), CameraTargets.wide(cams))
    }

    @Test fun noWideWhenThereIsNothingToChooseFrom() {
        assertNull(CameraTargets.wide(listOf(CamInfo("0", true, 4.0f), front))) // one plain back camera
        assertNull(CameraTargets.wide(listOf(CamInfo("0", true, 4.0f), CamInfo("2", true, 4.0f)))) // same focal length
        assertNull(CameraTargets.wide(listOf(CamInfo("0", true, 4.0f, mapOf("2" to 4.0f, "3" to 4.0f)))))
        assertNull(CameraTargets.wide(listOf(CamInfo("0", true, 4.0f, mapOf("2" to null, "3" to 3.0f))))) // unknown focal length
        assertNull(CameraTargets.wide(listOf(front, CamInfo("3", false, 1.0f)))) // front cameras never count
        assertNull(CameraTargets.resolve(emptyList(), CameraFacing.BACK_WIDE))
    }

    @Test fun facingWireValuesAndStorage() {
        assertEquals(2, CameraFacing.BACK_WIDE.wire)
        assertEquals(CameraFacing.BACK_WIDE, CameraFacing.parse("back_wide")) // the stored id round-trips
        assertEquals(CameraFacing.FRONT, CameraFacing.parse("nonsense"))
        assertEquals(
            CameraPrefs(CameraPrefs.MODE_AUTO, CameraPrefs.FACING_BACK_WIDE),
            CameraPrefsPolicy.wire(CameraWish(CameraMode.AUTO, CameraFacing.BACK_WIDE), true, false),
        )
    }

    @Test fun codecKeepsFacingTwoAndMapsUnknownToFront() {
        val wide = CameraPrefs(CameraPrefs.MODE_AUTO, CameraPrefs.FACING_BACK_WIDE, 3)
        assertEquals(wide, Codec.decodePayload(MsgType.CAMERA_PREFS, Codec.encodePayload(wide)))
        val unknown = Codec.encodePayload(wide).also { it[1] = 9 }
        assertEquals(CameraPrefs.FACING_FRONT, (Codec.decodePayload(MsgType.CAMERA_PREFS, unknown) as CameraPrefs).facing)
    }

    @Test fun onlyWideFallsBackToBackOnFailure() {
        assertEquals(CameraFacing.BACK, CameraTargets.fallbackOnFailure(CameraFacing.BACK_WIDE))
        assertNull(CameraTargets.fallbackOnFailure(CameraFacing.BACK))
        assertNull(CameraTargets.fallbackOnFailure(CameraFacing.FRONT))
    }
}
