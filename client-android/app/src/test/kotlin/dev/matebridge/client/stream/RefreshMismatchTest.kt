package dev.matebridge.client.stream

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** T-169: target vs measured refresh in the stats line and the `ev=refresh_mismatch` episodes. */
class RefreshMismatchTest {
    private val p60 = 16_667L // µs, a 60 Hz vsync gap
    private val p120 = 8_333L

    /** Feeds one sample per second for [fromS] until [toS] (inclusive) and returns the events with their times. */
    private fun RefreshMismatch.run(fromS: Int, toS: Int, target: Int = 120, p50: Long? = p60, streaming: Boolean = true) =
        (fromS..toS).mapNotNull { s -> update(target, p50, streaming, s * 1000L)?.let { s to it } }

    @Test fun statsFieldsCarryTargetDisplayMeasuredAndMode() {
        assertEquals(
            "hz=120 target_hz=120 vsync_period_us=8333 display_hz=120.0 vsync_ms_p50=8.33 stream_mode=smooth",
            RefreshMismatch.statsFields(120, 120.0f, 8_333, 8_333, "smooth"),
        )
        assertEquals(
            "hz=60 target_hz=0 vsync_period_us=0 display_hz=59.9 vsync_ms_p50=- stream_mode=game60",
            RefreshMismatch.statsFields(0, 59.94f, 0, null, "game60"),
        )
    }

    @Test fun eventFields() {
        assertEquals("target_hz=120 measured_hz=60.0 dur_ms=6000", RefreshMismatch.Event(120, 59.998, 6_000).fields())
    }

    @Test fun sustainedMismatchLogsExactlyOnceAfterFiveSeconds() {
        val m = RefreshMismatch()
        assertNull(m.update(120, p120, true, 0))
        val events = m.run(1, 120)
        assertEquals(1, events.size)
        val (at, e) = events.single()
        assertEquals(6, at) // mismatch since 0 s (the window before the 1 s sample): first > 5 s at 6 s
        assertEquals(120, e.targetHz)
        assertEquals(60.0, e.measuredHz, 0.01)
        assertEquals(6_000L, e.durMs)
    }

    @Test fun shortMismatchLogsNothing() {
        val m = RefreshMismatch()
        assertNull(m.update(120, p120, true, 0))
        assertEquals(emptyList<Any>(), m.run(1, 5)) // exactly 5 s is not more than 5 s
        assertEquals(emptyList<Any>(), m.run(6, 30, p50 = p120))
    }

    @Test fun withinToleranceIsNoMismatch() {
        val m = RefreshMismatch()
        assertEquals(emptyList<Any>(), m.run(0, 30, p50 = 8_700)) // 114.9 Hz vs 120: inside ±10 %
        assertEquals(emptyList<Any>(), m.run(31, 60, target = 60, p50 = 16_000)) // 62.5 Hz vs 60
    }

    @Test fun targetZeroNeverMismatches() {
        assertEquals(emptyList<Any>(), RefreshMismatch().run(0, 120, target = 0))
    }

    @Test fun nonStreamingTimeLogsNothingAndBreaksTheEpisode() {
        val m = RefreshMismatch()
        assertEquals(emptyList<Any>(), m.run(0, 120, streaming = false))
        assertEquals(emptyList<Any>(), m.run(121, 124))
        assertEquals(emptyList<Any>(), m.run(125, 125, streaming = false))
        assertEquals(emptyList<Any>(), m.run(126, 130)) // 4 s, then 5 s: never > 5 s in one piece
        assertEquals(listOf(131), m.run(131, 140).map { it.first })
    }

    @Test fun secondEpisodeAfterRecoveryLogsOnceMore() {
        val m = RefreshMismatch()
        assertNull(m.update(120, p120, true, 0))
        assertEquals(listOf(6), m.run(1, 20).map { it.first })
        assertEquals(emptyList<Any>(), m.run(21, 80, p50 = p120)) // recovered
        assertEquals(listOf(86), m.run(81, 120).map { it.first })
    }

    @Test fun secondEpisodeInsideTheRateLimitWaitsForIt() {
        val m = RefreshMismatch()
        assertNull(m.update(120, p120, true, 0))
        assertEquals(listOf(6), m.run(1, 10).map { it.first })
        assertEquals(emptyList<Any>(), m.run(11, 15, p50 = p120))
        assertEquals(emptyList<Any>(), m.run(16, 30)) // a whole episode inside the 60 s limit: nothing
        assertEquals(emptyList<Any>(), m.run(31, 35, p50 = p120))
        val late = m.run(36, 80) // still mismatching when the limit ends: one line then
        assertEquals(listOf(66), late.map { it.first })
        assertEquals(31_000L, late.single().second.durMs)
    }

    @Test fun secondsWithoutMeasurementKeepTheEpisodeButLongGapsRestartIt() {
        val m = RefreshMismatch()
        assertNull(m.update(120, p120, true, 0))
        assertEquals(emptyList<Any>(), m.run(1, 3))
        assertEquals(emptyList<Any>(), m.run(4, 4, p50 = null)) // idle vsync loop for a second
        assertEquals(listOf(6), m.run(5, 8).map { it.first })

        val n = RefreshMismatch()
        assertNull(n.update(120, p120, true, 0))
        assertEquals(emptyList<Any>(), n.run(1, 3))
        assertEquals(emptyList<Any>(), n.run(4, 10, p50 = null)) // 7 s without measurement
        assertEquals(listOf(16), n.run(11, 20).map { it.first }) // restarts from the 10 s tick: > 5 s at 16 s
    }

    @Test fun targetChangeRestartsTheEpisode() {
        val m = RefreshMismatch()
        assertNull(m.update(120, p120, true, 0))
        assertEquals(emptyList<Any>(), m.run(1, 4, p50 = 25_000)) // 40 Hz vs 120
        assertEquals(listOf(10), m.run(5, 12, target = 60, p50 = 25_000).map { it.first })
    }
}
