package dev.matebridge.client.cursor

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class CursorStatsTest {
    @Test fun anIdleWindowIsRecognisedAndWritesNothing() {
        val s = CursorStats().take()
        assertTrue(s.idle)
        assertEquals(-1L, s.ageP50Us)
        assertEquals(-1L, s.drawAvgUs)
        assertTrue(s.fields().contains("draw_ms_avg=- "))
    }

    @Test fun countersAndTheDrawCostAreSummarisedAndReset() {
        val st = CursorStats()
        repeat(120) { st.onState() }
        st.onShape()
        repeat(3) { st.onStale() }
        st.onDraw(100); st.onDraw(300); st.onDraw(2_000)
        val s = st.take()
        assertEquals(120, s.states)
        assertEquals(1, s.shapes)
        assertEquals(3, s.stale)
        assertEquals(3, s.draws)
        assertEquals(800L, s.drawAvgUs)
        assertEquals(2_000L, s.drawMaxUs)
        assertFalse(s.idle)
        assertTrue(st.take().idle) // reset
    }

    @Test fun agePercentilesUseNearestRank() {
        val st = CursorStats()
        for (us in 1L..100L) st.onAge(us * 1_000) // 1..100 ms
        val s = st.take()
        assertEquals(100, s.ageSamples)
        assertEquals(51_000L, s.ageP50Us) // nearest rank over (n-1)
        assertEquals(95_000L, s.ageP95Us)
    }

    @Test fun fieldsHaveTheDocumentedShapeAndNeverCarryPositions() {
        val st = CursorStats()
        st.onState(); st.onDraw(1_500); st.onAge(8_100); st.onAge(14_200)
        val f = st.take().fields()
        assertEquals(
            "states=1 shapes=0 stale=0 draws=1 draw_ms_avg=1.50 draw_ms_max=1.50 age_ms_p50=14.20 age_ms_p95=14.20 age_n=2", f,
        )
    }

    @Test fun anAgeMayBeNegativeWhileTheClockOffsetIsRough() {
        val st = CursorStats()
        st.onAge(-2_000)
        assertEquals(-2_000L, st.take().ageP50Us)
    }

    @Test fun ageSamplesAreBounded() {
        val st = CursorStats()
        repeat(CursorStats.MAX_AGE_SAMPLES * 3) { st.onAge(1_000L) }
        assertEquals(CursorStats.MAX_AGE_SAMPLES, st.take().ageSamples)
    }
}
