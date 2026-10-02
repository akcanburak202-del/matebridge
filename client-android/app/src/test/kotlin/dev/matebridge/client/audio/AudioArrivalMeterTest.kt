package dev.matebridge.client.audio

import dev.matebridge.client.audio.AudioArrivalMeter.Companion.NONE
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class AudioArrivalMeterTest {
    private val ms = 1_000_000L // ns

    /** Feeds one packet per read: arrival at [atMs] (client), captured at host [capUs], 480 frames (10 ms). */
    private fun AudioArrivalMeter.packet(atMs: Long, capUs: Long = atMs * 1000, decodeNs: Long = 50_000): Boolean {
        val readNs = atMs * ms
        onPacket(readNs, readNs + 10_000, readNs + 10_000 + decodeNs, capUs, 480)
        return endRead(1, readNs + 20_000 + decodeNs)
    }

    private fun AudioArrivalMeter.window() = AudioArrivalMeter.Window().also { takeWindow(it) }

    @Test fun steadyPacketsGiveTenMsIntervals() {
        val m = AudioArrivalMeter()
        for (i in 0 until 100) assertFalse(m.packet(1000 + i * 10L))
        val w = m.window()
        assertEquals(100, w.packets)
        assertEquals(99, w.intervals)
        assertEquals(10_000, w.intP50Us)
        assertEquals(10_000, w.intMaxUs)
        assertEquals(1, w.perReadMax)
        assertEquals(50, w.decryptMaxUs)
        assertEquals(0, w.gaps)
        assertEquals(NONE, w.owdP50Us) // no clock offset yet
        assertEquals(0, w.owdN)
    }

    @Test fun oneWayDelayUsesOffsetAndPacketDuration() {
        val m = AudioArrivalMeter()
        m.setOffset(5_000_000) // host = client + 5 s
        // Captured (host) 15 ms before arrival; the last frame is 10 ms later, so it is 5 ms old on arrival.
        m.packet(atMs = 1000, capUs = 5_000_000 + 1_000_000 - 15_000)
        val w = m.window()
        assertEquals(1, w.owdN)
        assertEquals(5_000, w.owdP50Us)
        assertEquals(5_000, w.owdP95Us)
        assertEquals(5_000, w.owdMaxUs)
    }

    @Test fun owdPercentilesAreNearestRank() {
        val m = AudioArrivalMeter()
        m.setOffset(0)
        // owd = (i + 1) ms for i in 0..99 (capture = arrival - 10 ms duration - owd)
        for (i in 0 until 100) {
            val at = 1000 + i * 10L
            m.packet(atMs = at, capUs = at * 1000 - 10_000 - (i + 1) * 1000L)
        }
        val w = m.window()
        assertEquals(50_000, w.owdP50Us)
        assertEquals(95_000, w.owdP95Us)
        assertEquals(100_000, w.owdMaxUs)
    }

    @Test fun negativeOwdIsKept() {
        val m = AudioArrivalMeter()
        m.setOffset(-2_000) // a slightly wrong offset can make the delay negative; it is reported as is
        m.packet(atMs = 1000, capUs = 1_000_000 - 10_000)
        assertEquals(-2_000, m.window().owdMaxUs)
    }

    @Test fun gapAboveTwentyMsIsReportedWithItsDetails() {
        val m = AudioArrivalMeter()
        m.setOffset(0)
        assertFalse(m.packet(1000, capUs = 990_000 - 1_000))
        assertFalse(m.packet(1020, capUs = 1_010_000 - 1_000)) // exactly 20 ms: not a gap
        // 35 ms later; two packets arrive in one read
        val readNs = 1055 * ms
        m.onPacket(readNs, readNs, readNs + 30_000, 1_020_000 - 10_000, 480) // owd = 1055 - 1020 = 35 ms
        m.onPacket(readNs, readNs + 30_000, readNs + 60_000, 1_030_000 - 10_000, 480)
        assertTrue(m.endRead(2, readNs + 70_000))
        assertEquals(35_000, m.gap.gapUs)
        assertEquals(35_000, m.gap.owdUs)
        assertEquals(2, m.gap.perRead)
        assertEquals(30, m.gap.decryptUs)
        assertEquals(0, m.gap.suppressed)
        val w = m.window()
        assertEquals(1, w.gaps)
        assertEquals(35_000, w.intMaxUs)
        assertEquals(2, w.perReadMax)
        assertEquals(3, w.intervals) // 20, 35, 0 (same read)
    }

    @Test fun gapLinesAreRateLimitedToFivePerSecond() {
        val m = AudioArrivalMeter()
        var logged = 0
        var t = 1000L
        m.packet(t)
        for (i in 0 until 8) { t += 30; if (m.packet(t)) logged++ } // 8 gaps within 240 ms
        assertEquals(5, logged)
        t += 1000 // next second: allowed again, and it reports the suppressed ones
        // stay under the idle limit: an interval of 1 s exactly still counts
        assertTrue(m.packet(t))
        assertEquals(3, m.gap.suppressed)
        assertEquals(9, m.window().gaps)
    }

    @Test fun longPauseIsNotAnInterval() {
        val m = AudioArrivalMeter()
        m.packet(1000)
        assertFalse(m.packet(3000)) // 2 s: the stream paused, not a gap
        assertFalse(m.packet(3010))
        val w = m.window()
        assertEquals(1, w.intervals)
        assertEquals(10_000, w.intMaxUs)
        assertEquals(0, w.gaps)
    }

    @Test fun resetStartsAFreshChainAndWindow() {
        val m = AudioArrivalMeter()
        m.packet(1000)
        m.packet(1010)
        m.reset()
        assertFalse(m.packet(1050)) // first packet after reset: no interval
        val w = m.window()
        assertEquals(1, w.packets)
        assertEquals(0, w.intervals)
        assertEquals(NONE, w.intMaxUs)
    }

    @Test fun takeWindowStartsANewWindow() {
        val m = AudioArrivalMeter()
        m.packet(1000)
        m.packet(1010)
        m.window()
        val w = m.window()
        assertEquals(0, w.packets)
        assertEquals(NONE, w.intP50Us)
        assertEquals(NONE, w.decryptMaxUs)
        assertEquals(
            "arr_int_ms_p50=- arr_int_ms_max=- owd_ms_p50=- owd_ms_p95=- owd_ms_max=- per_read_max=- decrypt_ms_max=- arr_gaps=0 arr_n=0",
            w.logFields(),
        )
        m.packet(1020) // the chain continues across windows
        assertEquals(10_000, m.window().intMaxUs)
    }

    @Test fun fullWindowKeepsExactMaximum() {
        val m = AudioArrivalMeter(capacity = 4)
        for (i in 0 until 10) m.packet(1000 + i * 10L)
        m.packet(1000 + 9 * 10L + 18)
        val w = m.window()
        assertEquals(10, w.intervals)
        assertEquals(18_000, w.intMaxUs)
        assertEquals(10_000, w.intP50Us) // from the first 4 samples
    }

    @Test fun logFieldsFormat() {
        val m = AudioArrivalMeter()
        m.setOffset(0)
        m.packet(1000, capUs = 1_000_000 - 10_000 - 3_250)
        m.packet(1012, capUs = 1_012_000 - 10_000 - 4_000, decodeNs = 120_000)
        assertEquals(
            "arr_int_ms_p50=12.0 arr_int_ms_max=12.0 owd_ms_p50=3.2 owd_ms_p95=4.0 owd_ms_max=4.0 " +
                "per_read_max=1 decrypt_ms_max=0.1 arr_gaps=0 arr_n=2",
            m.window().logFields(),
        )
    }

    @Test fun ms1FormatsSignedTenths() {
        assertEquals("-", AudioArrivalMeter.ms1(NONE))
        assertEquals("0.0", AudioArrivalMeter.ms1(0))
        assertEquals("12.3", AudioArrivalMeter.ms1(12_345))
        assertEquals("-2.5", AudioArrivalMeter.ms1(-2_500))
    }

    @Test fun readsWithoutAudioDoNotCount() {
        val m = AudioArrivalMeter()
        assertFalse(m.endRead(0, 1000 * ms))
        assertEquals(0, m.window().perReadMax)
    }
}
