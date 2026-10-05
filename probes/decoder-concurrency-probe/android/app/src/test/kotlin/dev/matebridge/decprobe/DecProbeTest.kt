package dev.matebridge.decprobe

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class AnnexBTest {
    private fun b(vararg v: Int) = ByteArray(v.size) { v[it].toByte() }
    private val sc4 = b(0, 0, 0, 1)
    private val vps = b(0x40, 0x01, 0x0C)
    private val sps = b(0x42, 0x01, 0x01)
    private val pps = b(0x44, 0x01, 0xC1)
    private val idr = b(0x26, 0x01, 0xAF, 0x00, 0x00, 0x03)   // first slice, ends in an emulation-prevention pattern
    private val p1 = b(0x02, 0x01, 0xD0, 0x11)                 // TRAIL_R, first slice
    private val p1b = b(0x02, 0x01, 0x40, 0x22)                // TRAIL_R, second slice of the same picture
    private val sei = b(0x4E, 0x01, 0x05, 0x01)                // prefix SEI (type 39)
    private val p2 = b(0x02, 0x01, 0x80)

    private fun stream(): ByteArray =
        sc4 + vps + sc4 + sps + sc4 + pps + sc4 + idr + sc4 + p1 + b(0, 0, 1) + p1b + sc4 + sei + sc4 + p2

    @Test fun splitsNals() {
        val s = stream()
        val nals = AnnexB.nals(s)
        assertEquals(listOf(32, 33, 34, 19, 1, 1, 39, 1), nals.map { AnnexB.type(s, it) })
        assertArrayEquals(idr, s.copyOfRange(nals[3].payload, nals[3].end))
        assertEquals(listOf(true, true, false, false, true), nals.drop(3).map { AnnexB.isFirstSlice(s, it) })
    }

    @Test fun groupsAccessUnits() {
        val s = stream()
        val units = AnnexB.accessUnits(s)
        assertEquals(3, units.size)
        // AU 0: parameter sets + IDR; AU 1: both slices of p1; AU 2: SEI + p2 (to the end).
        assertArrayEquals(sc4 + vps + sc4 + sps + sc4 + pps + sc4 + idr, s.copyOfRange(units[0].offset, units[0].offset + units[0].length))
        assertArrayEquals(sc4 + p1 + b(0, 0, 1) + p1b, s.copyOfRange(units[1].offset, units[1].offset + units[1].length))
        assertArrayEquals(sc4 + sei + sc4 + p2, s.copyOfRange(units[2].offset, units[2].offset + units[2].length))
        assertEquals(s.size, units.last().offset + units.last().length)
    }

    @Test fun extractsCodecConfig() {
        assertArrayEquals(sc4 + vps + sc4 + sps + sc4 + pps, AnnexB.codecConfig(stream()))
        assertNull(AnnexB.codecConfig(sc4 + p2))
    }
}

class ScenarioTest {
    @Test fun repeatNotation() {
        assertEquals(listOf("full"), Scenario.parse("1xfull")!!.clips)
        assertEquals(listOf("full", "full"), Scenario.parse("2xfull")!!.clips)
        assertEquals(listOf("half", "half_right"), Scenario.parse("2xhalf")!!.clips)
        assertEquals(listOf("half", "half_right", "half"), Scenario.parse("3xhalf")!!.clips)
        assertEquals(listOf("quarter", "quarter", "quarter", "quarter"), Scenario.parse("4xquarter")!!.clips)
        assertNull(Scenario.parse("0xfull"))
        assertNull(Scenario.parse("9xfull"))
    }

    @Test fun explicitAndList() {
        assertEquals(listOf("full", "half_right"), Scenario.parse("full+half_right")!!.clips)
        val (ok, bad) = Scenario.parseList(Scenario.DEFAULT + ", bogus!,")
        assertEquals(listOf("1xfull", "2xfull", "1xhalf", "2xhalf", "3xhalf"), ok.map { it.name })
        assertEquals(listOf("bogus!"), bad)
    }

    @Test fun clipFileNames() {
        assertEquals(ClipFile("half_right", "half_right_1400x1840.h265", 1400, 1840), ClipFile.parse("half_right_1400x1840.h265"))
        assertEquals(ClipFile("full", "full_2800x1840.h265", 2800, 1840), ClipFile.parse("full_2800x1840.h265"))
        assertNull(ClipFile.parse("full_2800x1840.mp4"))
        val names = listOf("decprobe-results.txt", "half_right_1400x1840.h265", "half_1400x1840.h265")
        assertEquals("half_1400x1840.h265", ClipFile.find(names, "half")!!.fileName)
        assertEquals("half_right_1400x1840.h265", ClipFile.find(names, "half_right")!!.fileName)
        assertNull(ClipFile.find(names, "full"))
    }
}

/** Parses the real clips from `decprobe-clips` when they exist on this machine (skipped otherwise). */
class RealClipTest {
    @Test fun clipsSplitIntoOneUnitPerFrame() {
        val dir = java.io.File(System.getProperty("user.home"), ".cache/matebridge-tools/data/decprobe")
        val files = dir.listFiles { f -> ClipFile.parse(f.name) != null }?.toList().orEmpty()
        org.junit.Assume.assumeTrue("no clips in $dir", files.isNotEmpty())
        for (f in files) {
            val clip = LoadedClip(ClipFile.parse(f.name)!!, f.readBytes())
            assertEquals(f.name, 600, clip.units.size)
            assertTrue(f.name, (clip.csd?.size ?: 0) > 20)
            assertEquals(f.name, 0, clip.units.first().offset)
            assertEquals(f.name, clip.data.size, clip.units.last().offset + clip.units.last().length)
        }
    }
}

class StatsTest {
    @Test fun percentiles() {
        val v = longArrayOf(5, 1, 4, 2, 3, 10, 9, 8, 7, 6)
        assertEquals(5L, percentile(v, 50.0))
        assertEquals(10L, percentile(v, 95.0))
        assertEquals(1L, percentile(v, 0.0))
        assertEquals(0L, percentile(LongArray(0), 50.0))
    }

    @Test fun longListGrows() {
        val l = LongList(2)
        for (i in 0 until 5) l.add(i.toLong())
        assertArrayEquals(longArrayOf(0, 1, 2, 3, 4), l.toArray())
    }

    @Test fun summaryLine() {
        val ms = 1_000_000L
        val a = SessionResult("half", 1400, 1840, 1000, longArrayOf(4 * ms, 5 * ms), longArrayOf(3 * ms, 4 * ms), images = 999)
        val b = SessionResult("half_right", 1400, 1840, 800, longArrayOf(6 * ms), longArrayOf(5 * ms), images = 800)
        val line = Summary.line("2xhalf", "image", 0, 4.0, "OMX.x", listOf(a, b))
        assertTrue(line, line.startsWith("DECPROBE scen=2xhalf out=image pace=0 n=2 ok=2 win=4.0s total_fps=450.0 min_fps=200.0 "))
        // 1800 frames x 1400 x 1840 / 4 s = 1159.2 Mpx/s
        assertTrue(line, line.contains("total_mpxs=1159.2 codec=OMX.x "))
        assertTrue(line, line.contains("s0=half:250.0fps,lat4.00/5.00,gap3.00/4.00,img999"))
        assertTrue(line, line.endsWith("s1=half_right:200.0fps,lat6.00/6.00,gap5.00/5.00,img800"))

        val failed = SessionResult("full", 2800, 1840, 0, LongArray(0), LongArray(0), error = "configure:-12 no resource")
        val l2 = Summary.line("2xfull", "buffer", 120, 4.0, "OMX.x", listOf(a.copy(images = -1), failed))
        assertTrue(l2, l2.contains("n=2 ok=1 "))
        assertTrue(l2, l2.contains("min_fps=0.0"))
        assertTrue(l2, l2.contains("s0=half:250.0fps,lat4.00/5.00,gap3.00/4.00,miss0 s1=full:ERR(configure:-12_no_resource)"))
    }
}
