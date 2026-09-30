package dev.matebridge.client.overlay

import dev.matebridge.client.input.PenAction
import dev.matebridge.client.input.PenPoint
import dev.matebridge.client.input.penFrame
import dev.matebridge.client.input.pt
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class PenInkModelTest {
    private val m = PenInkModel()

    private class Seg(val x0: Float, val x1: Float, val p: Float, val a: Float)

    private fun segs(now: Long): List<Seg> {
        val out = ArrayList<Seg>()
        m.forEachSegment(now) { x0, _, x1, _, p, a -> out += Seg(x0, x1, p, a) }
        return out
    }

    private fun move(action: PenAction, vararg pts: PenPoint, eraser: Boolean = false) =
        m.onPenFrame(penFrame(action, *pts, eraser = eraser), eraser)

    @Test fun hoverShowsDotAtLastSampleAndExitHidesIt() {
        move(PenAction.HOVER_MOVE, pt(0, 10f, 20f), pt(3, 30f, 40f))
        assertTrue(m.showDot)
        assertEquals(30f, m.dotX, 0f)
        assertEquals(40f, m.dotY, 0f)
        assertFalse(m.inContact)
        assertTrue(segs(3).isEmpty())
        move(PenAction.HOVER_EXIT, pt(6, 30f, 40f))
        assertFalse(m.showDot)
    }

    @Test fun dotSettingOffHidesDot() {
        m.dotEnabled = false
        move(PenAction.HOVER_MOVE, pt(0))
        assertFalse(m.showDot)
    }

    @Test fun contactBuildsTrailFromAllBatchedSamples() {
        move(PenAction.DOWN, pt(0, 0f))
        move(PenAction.MOVE, pt(3, 10f), pt(6, 20f), pt(9, 30f))
        val s = segs(9)
        assertEquals(listOf(0f, 10f, 20f), s.map { it.x0 })
        assertEquals(listOf(10f, 20f, 30f), s.map { it.x1 })
        assertTrue(m.inContact)
    }

    @Test fun trailWindowKeepsOnlyLast40ms() {
        move(PenAction.DOWN, pt(0, 0f))
        for (i in 1..30) move(PenAction.MOVE, pt(i * 3L, i * 10f))
        val s = segs(90)
        // newest t = 90; segments ending at t >= 50: 51, 54, ..., 90 = 14 of them
        assertTrue(s.all { it.x1 >= 170f })
        assertEquals(14, s.size)
    }

    @Test fun fadesLinearlyAndVanishesAtFadeTime() {
        move(PenAction.DOWN, pt(100, 0f))
        move(PenAction.MOVE, pt(110, 10f))
        assertEquals(PenInkStyle.TRAIL_ALPHA, segs(110)[0].a, 1e-4f)
        val half = segs(110 + PenInkStyle.FADE_MS / 2)[0].a
        assertEquals(PenInkStyle.TRAIL_ALPHA * 0.5f, half, 0.02f)
        assertTrue(segs(110 + PenInkStyle.FADE_MS).isEmpty())
        assertTrue(m.hasLiveTrail(110 + PenInkStyle.FADE_MS - 1))
        assertFalse(m.hasLiveTrail(110 + PenInkStyle.FADE_MS))
    }

    @Test fun strokesAreNotJoined() {
        move(PenAction.DOWN, pt(0, 0f))
        move(PenAction.MOVE, pt(3, 10f))
        move(PenAction.UP, pt(6, 20f, pressure = 0f))
        move(PenAction.HOVER_MOVE, pt(9, 500f))
        move(PenAction.DOWN, pt(12, 900f))
        move(PenAction.MOVE, pt(15, 910f))
        assertEquals(listOf(0f, 10f, 900f), segs(15).map { it.x0 })
    }

    @Test fun upKeepsDotAsHoverAndTrailFades() {
        move(PenAction.DOWN, pt(0, 0f))
        move(PenAction.UP, pt(5, 10f))
        assertTrue(m.showDot)
        assertFalse(m.inContact)
        assertEquals(1, segs(5).size)
    }

    @Test fun eraserRecordsNoTrailButShowsRing() {
        move(PenAction.DOWN, pt(0, 0f), eraser = true)
        move(PenAction.MOVE, pt(3, 10f), eraser = true)
        assertTrue(segs(3).isEmpty())
        assertTrue(m.showDot)
        assertTrue(m.eraser)
    }

    @Test fun trailSettingOffRecordsNothing() {
        m.trailEnabled = false
        move(PenAction.DOWN, pt(0, 0f))
        move(PenAction.MOVE, pt(3, 10f))
        assertTrue(segs(3).isEmpty())
        assertFalse(m.hasLiveTrail(3))
        assertTrue(m.showDot)
    }

    @Test fun clearAndCancelForget() {
        move(PenAction.DOWN, pt(0, 0f))
        move(PenAction.MOVE, pt(3, 10f))
        move(PenAction.CANCEL, pt(4, 10f))
        assertFalse(m.showDot)
        m.onPenClear()
        assertTrue(segs(4).isEmpty())
        assertFalse(m.hasLiveTrail(4))
    }

    @Test fun ringOverflowKeepsNewestAndNeverThrows() {
        move(PenAction.DOWN, pt(0, 0f))
        move(PenAction.MOVE, *Array(1000) { pt(1, it.toFloat()) })
        val s = segs(1)
        assertTrue(s.isNotEmpty())
        assertEquals(999f, s.last().x1, 0f)
    }

    @Test fun widthFollowsPressure() {
        assertEquals(PenInkStyle.MIN_WIDTH_DP, PenInkStyle.widthDp(0f), 0f)
        assertEquals(PenInkStyle.MAX_WIDTH_DP, PenInkStyle.widthDp(2f), 0f)
        assertTrue(PenInkStyle.widthDp(0.7f) > PenInkStyle.widthDp(0.3f))
        assertEquals(PenInkStyle.MIN_WIDTH_DP, PenInkStyle.widthDp(Float.NaN), 0f)
    }
}
