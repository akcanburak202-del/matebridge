package dev.matebridge.client.input

import dev.matebridge.client.protocol.Key
import dev.matebridge.client.protocol.Pen
import dev.matebridge.client.protocol.PenSample
import dev.matebridge.client.protocol.Pinch
import dev.matebridge.client.protocol.PointerAbs
import dev.matebridge.client.protocol.PointerRel
import dev.matebridge.client.protocol.ReleaseAll
import dev.matebridge.client.protocol.Scroll
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class SendAgeStatsTest {
    private val pen = SendAgeStats.Cls.PEN.ordinal
    private val pointer = SendAgeStats.Cls.POINTER.ordinal
    private val key = SendAgeStats.Cls.KEY.ordinal
    private val scroll = SendAgeStats.Cls.SCROLL.ordinal

    private fun field(s: String, name: String) = Regex("(?:^| )$name=([^ ]+)").find(s)?.groupValues?.get(1)

    @Test fun emptyWindowGivesNoFields() {
        assertEquals("", SendAgeStats().takeFields())
    }

    @Test fun percentilesAndMaxOfOneClass() {
        val s = SendAgeStats()
        for (ms in 1..100) s.record(pointer, 1_000_000L, 1_000_000L + ms * 1000L) // ages 1..100 ms, one each
        val f = s.takeFields()
        assertEquals("100", field(f, "pointer_send_n"))
        // bucket upper edges are within one bucket (0.25 ms) of the exact rank
        assertEquals(50.0, field(f, "pointer_send_age_ms_p50")!!.toDouble(), 0.3)
        assertEquals(95.0, field(f, "pointer_send_age_ms_p95")!!.toDouble(), 0.3)
        assertEquals("100.0", field(f, "pointer_send_age_ms_max"))
    }

    @Test fun classesAreSeparate() {
        val s = SendAgeStats()
        s.record(pen, 1000L, 1000L + 2_000L)
        s.record(key, 1000L, 1000L + 12_000L)
        val f = s.takeFields()
        assertEquals("1", field(f, "pen_send_n"))
        assertEquals("1", field(f, "key_send_n"))
        assertEquals("2.0", field(f, "pen_send_age_ms_max"))
        assertEquals("12.0", field(f, "key_send_age_ms_max"))
        assertNull(field(f, "pointer_send_n")) // no data: no fields
        assertNull(field(f, "scroll_send_n"))
    }

    @Test fun windowIsClearedByTake() {
        val s = SendAgeStats()
        s.record(scroll, 1000L, 50_000L)
        assertTrue(s.takeFields().isNotEmpty())
        assertEquals("", s.takeFields())
        s.record(scroll, 1000L, 3000L)
        assertEquals("2.0", field(s.takeFields(), "scroll_send_age_ms_max")) // the old max did not carry over
    }

    @Test fun invalidInputIsIgnoredAndNegativeAgeClampsToZero() {
        val s = SendAgeStats()
        s.record(-1, 1000L, 2000L)
        s.record(99, 1000L, 2000L)
        s.record(pen, 0L, 2000L) // unknown event time
        assertEquals("", s.takeFields())
        s.record(pen, 5000L, 4000L) // clock skew: written "before" the event
        assertEquals("0.0", field(s.takeFields(), "pen_send_age_ms_max"))
    }

    @Test fun hugeAgesLandInTheLastBucketButKeepTheExactMax() {
        val s = SendAgeStats()
        s.record(key, 1L, 1L + 5_000_000L)
        val f = s.takeFields()
        assertEquals("5000.0", field(f, "key_send_age_ms_max"))
        assertEquals(SendAgeStats.BUCKETS * SendAgeStats.BUCKET_US / 1000.0, field(f, "key_send_age_ms_p50")!!.toDouble(), 0.1)
    }

    @Test fun fieldsCarryOnlyNumbers() {
        val s = SendAgeStats()
        s.record(pen, 1000L, 9000L)
        assertTrue(s.takeFields().matches(Regex("(pen_send_[a-z0-9_]+=[0-9.]+ ?)+")))
    }

    @Test fun classAndEventTimeOfMessages() {
        val sample = PenSample(dtUs = 300, x = 1, y = 2, pressure = 3, tiltX = 0, tiltY = 0, flags = 1)
        val p = Pen(Pen.TOOL_PEN, 10_000L, listOf(sample, sample.copy(dtUs = 800)))
        assertEquals(pen, SendAgeStats.classOf(p))
        assertEquals(10_800L, SendAgeStats.eventTimeUs(p))
        val k = Key(7_000L, 30, 29, Key.DOWN, 0)
        assertEquals(key, SendAgeStats.classOf(k))
        assertEquals(7_000L, SendAgeStats.eventTimeUs(k))
        val abs = PointerAbs(8_000L, 1, 2, 0, PointerAbs.SOURCE_TOUCH)
        assertEquals(pointer, SendAgeStats.classOf(abs))
        assertEquals(8_000L, SendAgeStats.eventTimeUs(abs))
        val rel = PointerRel(9_000L, 1f, 1f, 0)
        assertEquals(pointer, SendAgeStats.classOf(rel))
        assertEquals(9_000L, SendAgeStats.eventTimeUs(rel))
        assertEquals(scroll, SendAgeStats.classOf(Pinch(1L, 0f, 0, 0, Pinch.BEGAN, 0))) // same as the host InputAge.swift
        val sc = Scroll(6_000L, 1f, 1f, Scroll.CHANGED)
        assertEquals(scroll, SendAgeStats.classOf(sc))
        assertEquals(6_000L, SendAgeStats.eventTimeUs(sc))
        assertEquals(-1, SendAgeStats.classOf(ReleaseAll(ReleaseAll.USER)))
        assertEquals(0L, SendAgeStats.eventTimeUs(ReleaseAll(ReleaseAll.USER)))
    }

    @Test fun inputCaptureAppendsTheFieldsToTheSummaryLine() {
        val lines = ArrayList<String>()
        val data = "pen_send_n=3 pen_send_age_ms_p50=1.0 pen_send_age_ms_p95=2.0 pen_send_age_ms_max=2.5"
        var next = data
        val c = InputCapture(FakeSink(), { VP }, sendAgeFields = { next.also { next = "" } }, onStatsLine = { lines += it })
        c.setActive(true, 0)
        c.tick(0)
        c.tick(1500)
        assertEquals(1, lines.size)
        assertTrue(lines[0].endsWith(data))
        assertTrue("interval_ms=" in lines[0])
        // an idle window with no counters and no send-age data prints nothing
        c.tick(3000)
        assertEquals(1, lines.size)
    }
}
