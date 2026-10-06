package dev.matebridge.client.cursor

import dev.matebridge.client.stream.VideoViewport
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test

class CursorGeometryTest {
    // The native tablet: a 2800 x 1840 surface for a 1400 pt wide stream = 2 px per point.
    private val native = VideoViewport.ofRect(0, 0, 2800, 1840)
    private val eps = 0.01f

    @Test fun shapeSizeAndHotspotFollowTheSurfaceOverStreamWidthRatio() {
        // 9 x 18 pt shape, hotspot (4, 9), at the centre of the surface
        val b = CursorGeometry.place(native, 1400, 32768, 32768, 9 * 16, 18 * 16, 4 * 16, 9 * 16)!!
        assertEquals(18f, b.width, eps)
        assertEquals(36f, b.height, eps)
        assertEquals(2800f * 32768 / 65535f - 8f, b.left, eps) // hotspot x minus 4 pt * 2 px
        assertEquals(1840f * 32768 / 65535f - 18f, b.top, eps) // hotspot y minus 9 pt * 2 px
    }

    @Test fun anotherDensityScalesTheShape() {
        // a 1848 px wide game surface for a 1848 pt stream = 1 px per point
        val vp = VideoViewport.ofRect(0, 0, 1848, 1214)
        val b = CursorGeometry.place(vp, 1848, 0, 0, 12 * 16, 19 * 16, 0, 0)!!
        assertEquals(12f, b.width, eps)
        assertEquals(19f, b.height, eps)
        assertEquals(0f, b.left, eps)
        assertEquals(0f, b.top, eps)
    }

    @Test fun hotspotEdgesMapToTheEdgesOfThePicture() {
        assertEquals(0f, CursorGeometry.hotspotX(native, 0), eps)
        assertEquals(2800f, CursorGeometry.hotspotX(native, 65535), eps)
        assertEquals(1840f, CursorGeometry.hotspotY(native, 65535), eps)
        assertEquals(0f, CursorGeometry.hotspotY(native, -5), eps) // clamped
    }

    @Test fun aLetterboxedPictureOffsetsTheHotspot() {
        // a 2800 x 1840 picture fitted into a 3000 x 1840 window: 100 px bands left and right
        val vp = VideoViewport(3000, 1840, 2800, 1840)
        assertEquals(100f, CursorGeometry.hotspotX(vp, 0), eps)
        assertEquals(2900f, CursorGeometry.hotspotX(vp, 65535), eps)
        // the shape scale uses the picture width, not the window width
        assertEquals(2f, CursorGeometry.pixelsPerPoint(vp, 1400), eps)
    }

    @Test fun anOriginedViewportIsInRootCoordinates() {
        val vp = VideoViewport.ofRect(100, 50, 1000, 500)
        val b = CursorGeometry.place(vp, 500, 0, 0, 16, 16, 0, 0)!!
        assertEquals(100f, b.left, eps)
        assertEquals(50f, b.top, eps)
        assertEquals(2f, b.width, eps) // 1 pt * 2 px
    }

    @Test fun unknownGeometryPlacesNothing() {
        assertNull(CursorGeometry.place(VideoViewport(0, 0, 0, 0), 1400, 0, 0, 16, 16, 0, 0))
        assertNull(CursorGeometry.place(native, 0, 0, 0, 16, 16, 0, 0)) // no STREAM_CONFIG yet
        assertNull(CursorGeometry.place(native, 1400, 0, 0, 0, 16, 0, 0)) // empty shape
        assertNotNull(CursorGeometry.place(native, 1400, 0, 0, 16, 16, 0, 0))
    }

    @Test fun dirtyRectCoversBothTheOldAndTheNewPlace() {
        val a = CursorGeometry.Box(10f, 20f, 18f, 36f)
        val b = CursorGeometry.Box(100.4f, 30f, 18f, 36f)
        val d = CursorGeometry.dirty(a, b, pad = 2)!!
        assertEquals(listOf(8, 18, 121, 68), d.toList()) // 10-2, 20-2, ceil(118.4)+2, 66+2
        assertEquals(listOf(8, 18, 30, 58), CursorGeometry.dirty(a, null, pad = 2)!!.toList())
        assertNull(CursorGeometry.dirty(null, null))
    }

    @Test fun theArrowHasItsTipAtTheHotspotAndAllPointsInsideItsBox() {
        assertEquals(0, BuiltinArrow.HOT_X_PT16)
        assertEquals(0f, BuiltinArrow.POINTS[0], 0f)
        assertEquals(0f, BuiltinArrow.POINTS[1], 0f)
        var i = 0
        while (i < BuiltinArrow.POINTS.size) {
            assert(BuiltinArrow.POINTS[i] in 0f..(BuiltinArrow.WIDTH_PT16 / 16f))
            assert(BuiltinArrow.POINTS[i + 1] in 0f..(BuiltinArrow.HEIGHT_PT16 / 16f))
            i += 2
        }
    }
}
