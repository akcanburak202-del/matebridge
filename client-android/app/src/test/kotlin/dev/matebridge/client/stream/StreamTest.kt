package dev.matebridge.client.stream

import dev.matebridge.client.video.VideoStats
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ClockSyncTest {
    @Test fun noSamplesMeansUnknown() {
        val c = ClockSync()
        assertNull(c.offsetUs())
        assertNull(c.latencyUs(1000, 2000))
    }

    @Test fun offsetFromSymmetricPath() {
        val c = ClockSync()
        // host clock = client clock + 5_000_000; one-way 2 ms each way
        c.onPong(echoUs = 1_000_000, responderUs = 1_000_000 + 2_000 + 5_000_000, nowUs = 1_004_000)
        assertEquals(5_000_000L, c.offsetUs())
        assertEquals(4_000L, c.bestRttUs())
    }

    @Test fun lowestRttSampleWins() {
        val c = ClockSync()
        c.onPong(0, 5_000_000 + 50_000, 100_000) // rtt 100 ms, asymmetric: offset off by 0 -> 5_000_000
        c.onPong(1_000_000, 1_000_000 + 1_000 + 5_000_000 + 300, 1_002_000) // rtt 2 ms
        assertEquals(5_000_300L, c.offsetUs())
    }

    @Test fun windowEvictsOldSamples() {
        val c = ClockSync(windowSize = 2)
        c.onPong(0, 1_000, 2_000) // rtt 2000, offset 0
        c.onPong(10_000, 10_000 + 500 + 7, 11_000) // rtt 1000
        c.onPong(20_000, 20_000 + 900 + 9, 21_800) // rtt 1800; the first sample is evicted
        assertEquals(7L, c.offsetUs())
        c.onPong(30_000, 30_000 + 5000 + 100, 40_000) // evicts the rtt-1000 sample
        assertEquals(1_800L, c.bestRttUs())
    }

    @Test fun negativeRttIgnored() {
        val c = ClockSync()
        c.onPong(2_000, 0, 1_000)
        assertNull(c.offsetUs())
    }

    @Test fun latencyUsesOffsetAndClampsAtZero() {
        val c = ClockSync()
        c.onPong(0, 1_000 + 10_000_000, 2_000) // offset 10_000_000
        // frame captured at host time 10_100_000 = client 100_000; displayed at client 130_000 -> 30 ms
        assertEquals(30_000L, c.latencyUs(10_100_000, 130_000))
        assertEquals(0L, c.latencyUs(10_500_000, 130_000)) // future capture (estimation error) clamps
    }
}

class VideoViewportTest {
    @Test fun sameAspectFillsView() {
        val v = VideoViewport(2800, 1840, 2800, 1840)
        assertEquals(0f, v.left, 0.001f)
        assertEquals(2800f, v.width, 0.001f)
        assertEquals(0, v.normX(0f))
        assertEquals(65535, v.normX(2800f))
        assertEquals(65535, v.normY(1840f))
    }

    @Test fun pillarboxExcludesSideBands() {
        // 4:3 video on a 2000x1000 view: 1333.33 wide, bands of 333.33 left and right
        val v = VideoViewport(2000, 1000, 1600, 1200)
        assertEquals(1333.333f, v.width, 0.01f)
        assertEquals(333.333f, v.left, 0.01f)
        assertEquals(0, v.normX(100f)) // inside the left band clamps to the edge
        assertEquals(0, v.normX(333.333f))
        assertEquals(65535, v.normX(1900f))
        assertTrue(v.normX(1000f) in 32767..32768) // center (float error either side of .5)
        assertEquals(32768, v.normY(500f))
    }

    @Test fun letterboxExcludesTopBottomBands() {
        val v = VideoViewport(1000, 1000, 2000, 1000)
        assertEquals(1000f, v.width, 0.001f)
        assertEquals(500f, v.height, 0.001f)
        assertEquals(250f, v.top, 0.001f)
        assertEquals(0, v.normY(100f))
        assertEquals(65535, v.normY(900f))
        assertEquals(32768, v.normY(500f))
    }

    @Test fun laidOutRectIsRootCoordinates() {
        val v = VideoViewport.ofRect(100, 50, 800, 400)
        assertEquals(0, v.normX(100f))
        assertEquals(65535, v.normX(900f))
        assertEquals(0, v.normY(50f))
        assertEquals(65535, v.normY(450f))
    }

    @Test fun degenerateIsEmptyAndSafe() {
        val v = VideoViewport(0, 0, 0, 0)
        assertTrue(v.isEmpty)
        assertEquals(0, v.normX(10f))
    }
}

class StatsFormatTest {
    private val snap = VideoStats.Snapshot(60, 59, 58, 2, 4_500, 1_250_000, 30_000)

    @Test fun messageMapsFields() {
        val m = StatsFormat.toMessage(snap, 1000, 30_000)
        assertEquals(1000L, m.intervalMs)
        assertEquals(60L, m.framesReceived)
        assertEquals(59L, m.framesDecoded)
        assertEquals(58L, m.framesRendered)
        assertEquals(2L, m.framesDropped)
        assertEquals(4_500L, m.decodeTimeAvgUs)
        assertEquals(30_000L, m.latencyAvgUs)
        assertEquals(1_250_000L, m.bytesReceived)
    }

    @Test fun unknownLatencyIsZeroOnTheWireAndQuestionMarkOnScreen() {
        assertEquals(0L, StatsFormat.toMessage(snap, 1000, null).latencyAvgUs)
        assertTrue(StatsFormat.overlay(snap, 1000, null).contains("Yak→çöz ?"))
    }

    @Test fun overlayShowsRatesAndClampsU32() {
        val text = StatsFormat.overlay(snap, 1000, 30_000)
        assertTrue(text, text.contains("FPS 58.0"))
        assertTrue(text, text.contains("10.0 Mbps"))
        assertTrue(text, text.contains("4.5 ms"))
        assertTrue(text, text.contains("30 ms"))
        val big = VideoStats.Snapshot(0, 0, 0, 0, 0, 1L shl 40)
        assertEquals(0xFFFF_FFFFL, StatsFormat.toMessage(big, 1000, null).bytesReceived)
    }

    @Test fun videoStatsAveragesLatencyThroughHook() {
        val s = VideoStats()
        s.latencyOf = { cap, _ -> cap * 2 }
        s.onInput(1, 100, 10)
        s.onInput(2, 200, 30)
        s.onOutput(1, 400)
        s.onOutput(2, 500)
        assertEquals(40L, s.snapshot().latencyAvgUs) // (20 + 60) / 2
        assertNull(VideoStats().snapshot().latencyAvgUs)
    }
}
