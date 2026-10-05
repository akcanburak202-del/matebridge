package dev.matebridge.yuv444probe

import java.nio.ByteBuffer
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class Y444ProbeTest {
    private val ms = 1_000_000L

    @Test fun percentileNearestRank() {
        val v = longArrayOf(5, 1, 4, 2, 3, 10, 9, 8, 7, 6)
        assertEquals(5, percentile(v, 50.0))
        assertEquals(10, percentile(v, 95.0))
        assertEquals(10, percentile(v, 100.0))
        assertEquals(1, percentile(v, 0.0))
        assertEquals(0, percentile(LongArray(0), 50.0))
    }

    @Test fun msDistFormats() {
        assertEquals("-", msDist(LongArray(0)))
        assertEquals("2.00/2.00/2.00/2.00", msDist(longArrayOf(2 * ms)))
        assertEquals(1.5, meanMs(longArrayOf(1 * ms, 2 * ms)), 1e-9)
    }

    @Test fun longListGrows() {
        val l = LongList(2)
        for (i in 0 until 10) l.add(i.toLong())
        assertEquals(10, l.size)
        assertArrayEquals(LongArray(10) { it.toLong() }, l.toArray())
    }

    @Test fun pairLatencyDual() {
        val period = 16 * ms
        val t0 = 1000 * ms
        // frame 0: main +5, aux +9; frame 1: main +6, aux missing; frame 2: aux only +7; frame 3: neither
        val main = longArrayOf(t0 + 5 * ms, t0 + period + 6 * ms, 0, 0)
        val aux = longArrayOf(t0 + 9 * ms, 0, t0 + 2 * period + 7 * ms, 0)
        val r = PairLatency.compute(t0, period, main, aux, 0, 4)
        assertArrayEquals(longArrayOf(9 * ms), r.pairNs)
        assertArrayEquals(longArrayOf(4 * ms), r.auxAfterMainNs)
        assertArrayEquals(longArrayOf(5 * ms, 6 * ms), r.mainNs)
        assertArrayEquals(longArrayOf(9 * ms, 7 * ms), r.auxNs)
        assertEquals(1, r.mainOnly)
        assertEquals(1, r.auxOnly)
        assertEquals(1, r.neither)
    }

    @Test fun pairLatencySingleAndRange() {
        val period = 10 * ms
        val main = longArrayOf(3 * ms, period + 4 * ms, 2 * period + 5 * ms)
        val r = PairLatency.compute(0, period, main, null, 1, 3)
        assertArrayEquals(longArrayOf(4 * ms, 5 * ms), r.pairNs)
        assertEquals(0, r.auxNs.size)
    }

    @Test fun presentStatsGapsAndUnresolved() {
        val period = 16 * ms
        // arrival, latch, present, renderComplete
        val q = longArrayOf(
            0, 8 * ms, 20 * ms, 4 * ms,
            16 * ms, 24 * ms, 36 * ms, 20 * ms,
            32 * ms, -2, -2, 0,                      // pending: unresolved
            48 * ms, 56 * ms, 100 * ms, 52 * ms,     // gap 64 ms = skipped
        )
        val r = PresentStats.analyze(q, period)
        assertEquals(1, r.unresolved)
        assertArrayEquals(longArrayOf(8 * ms, 8 * ms, 8 * ms), r.arrivalToLatchNs)
        assertArrayEquals(longArrayOf(16 * ms, 64 * ms), r.presentGapNs)
        assertEquals(1, r.skippedGaps)
    }

    @Test fun clipNames() {
        val c = ClipName.parse("full_2800x1840_8_60m.h265")!!
        assertEquals("full_2800x1840_8_60m", c.id)
        assertEquals(2800, c.width)
        assertEquals(1840, c.height)
        assertEquals(1848, ClipName.parse("aux_v2_1848x1214.hevc")!!.width)
        assertNull(ClipName.parse("notes.txt"))
        assertNull(ClipName.parse("clip.h265"))
    }

    @Test fun clipLookup() {
        val names = listOf("b_2800x1840.h265", "a_2800x1840.h265", "half_1400x1840.h265", "readme.txt")
        assertEquals("a_2800x1840.h265", ClipName.ofSize(names, 2800, 1840, 0)!!.fileName)
        assertEquals("b_2800x1840.h265", ClipName.ofSize(names, 2800, 1840, 1)!!.fileName)
        assertNull(ClipName.ofSize(names, 2800, 1840, 2))
        assertNull(ClipName.ofSize(listOf("x_2800x1840_10pq_60m.h265"), 2800, 1840))
        assertEquals("half_1400x1840.h265", ClipName.find(names, "half")!!.fileName)
        assertEquals("b_2800x1840.h265", ClipName.find(names, "b_2800x1840")!!.fileName)
        assertNull(ClipName.find(names, "zzz"))
    }

    @Test fun sizeSpec() {
        assertEquals(2800 to 1840, SizeSpec.parse(null))
        assertEquals(1848 to 1214, SizeSpec.parse("small"))
        assertEquals(1400 to 920, SizeSpec.parse("1400x920"))
        assertNull(SizeSpec.parse("huge"))
    }

    @Test fun testListParsing() {
        val (ok, bad) = TestKind.parseList("t2, T3,direct,bogus")
        assertEquals(listOf(TestKind.T2, TestKind.T3, TestKind.DIRECT), ok)
        assertEquals(listOf("bogus"), bad)
        assertEquals(listOf(TestKind.T2, TestKind.T1, TestKind.DIRECT, TestKind.T3), TestKind.parseList(null).first)
    }

    @Test fun argsDefaultsAndOverrides() {
        val d = Args(emptyMap())
        assertEquals(60, d.fps)
        assertEquals(20.0, d.seconds(TestKind.T3), 0.0)
        assertEquals(300.0, d.seconds(TestKind.T4), 0.0)
        assertEquals(GlMode.MERGE, d.gl)
        assertEquals(listOf(12, 24, 36), d.frames)
        assertTrue(d.needsSurface)
        val a = Args(mapOf("test" to "t2,t1", "fps" to "30", "gl" to "oes", "frames" to "5,x,7", "out" to "buffer"))
        assertFalse(a.needsSurface)
        assertEquals(30, a.fps)
        assertEquals(GlMode.OES, a.gl)
        assertEquals(listOf(5, 7), a.frames)
        assertTrue(a.bufferOut)
        assertNull(Args(mapOf("gl" to "nope")).gl)
    }

    @Test fun rawVerdict() {
        val ok = "ok=1 flip=0 ahb_fmt=0x23 y_mis=0/5152000 y_max=0 cb_mis=0/1288000 cb_max=0 cr_mis=0/1288000 cr_max=0 " +
            "fullres_cb_mis=900/5152000 fullres_cr_mis=0/5152000 glerr=0x0"
        assertEquals(true, RawVerdict.exact(ok))
        assertEquals(false, RawVerdict.exact(ok.replace("cb_mis=0/1288000", "cb_mis=3/1288000")))
        assertNull(RawVerdict.exact("ok=0 err=shader:boom"))
    }

    @Test fun planeCopyHandlesStrides() {
        // 3x2 plane, rowStride 5, pixelStride 1
        val a = ByteBuffer.wrap(byteArrayOf(1, 2, 3, 9, 9, 4, 5, 6, 9, 9))
        assertArrayEquals(byteArrayOf(1, 2, 3, 4, 5, 6), PlaneCopy.tight(a, 5, 1, 3, 2))
        // semi-planar chroma: pixelStride 2, rowStride 6
        val b = ByteBuffer.wrap(byteArrayOf(1, 0, 2, 0, 3, 0, 4, 0, 5, 0, 6, 0))
        assertArrayEquals(byteArrayOf(1, 2, 3, 4, 5, 6), PlaneCopy.tight(b, 6, 2, 3, 2))
    }

    @Test fun annexBAccessUnits() {
        val sc = byteArrayOf(0, 0, 0, 1)
        fun nal(type: Int, first: Boolean) = sc + byteArrayOf((type shl 1).toByte(), 1, if (first) 0x80.toByte() else 0)
        val data = nal(32, false) + nal(33, false) + nal(34, false) + nal(19, true) + nal(1, true) + nal(1, true)
        val units = AnnexB.accessUnits(data)
        assertEquals(3, units.size)
        val irap = AnnexB.irapFlags(data, units)
        assertTrue(irap[0])
        assertFalse(irap[1])
        assertTrue(AnnexB.codecConfig(data)!!.isNotEmpty())
    }
}
