package dev.matebridge.aaudioprobe

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class NativeResultTest {
    private fun header(): LongArray = LongArray(NativeResult.H_COUNT).also {
        it[NativeResult.H_LEN] = NativeResult.H_COUNT.toLong()
        it[NativeResult.H_REQ_SHARING] = 0
        it[NativeResult.H_SHARING] = 0
        it[NativeResult.H_PERF] = 12
        it[NativeResult.H_MMAP] = 1
        it[NativeResult.H_BURST] = 96
        it[NativeResult.H_CAPACITY] = 3072
        it[NativeResult.H_BUF_DEFAULT] = 3072
        it[NativeResult.H_BUF_START] = 192
        it[NativeResult.H_BUF_FINAL] = 288
        it[NativeResult.H_RATE] = 48_000
        it[NativeResult.H_CHANNELS] = 2
        it[NativeResult.H_FORMAT] = 1
        it[NativeResult.H_XRUNS] = 1
        it[NativeResult.H_FRAMES_WRITTEN] = 240_000
        it[NativeResult.H_TS_FAIL] = 3
        it[NativeResult.H_START_NS] = 1_000_000_000
    }

    @Test
    fun parsesHeaderAndSamples() {
        val h = header()
        h[NativeResult.H_SAMPLES] = 2
        val a = h + longArrayOf(192, 0, 2_000_000_000, 2_000_000_000, 288, 96, 2_002_000_000, 2_002_000_000)
        val r = NativeResult.parse("a_excl", a)
        assertEquals("aaudio", r.api)
        assertEquals("exclusive", r.reqSharing)
        assertEquals("exclusive", r.sharing)
        assertEquals("low_latency", r.perf)
        assertEquals(1, r.mmap)
        assertEquals(96, r.burst)
        assertEquals(288, r.bufFinal)
        assertEquals("i16", r.format)
        assertEquals("none", r.stage)
        assertEquals(2, r.samples.size)
        assertEquals(Sample(288, 96, 2_002_000_000, 2_002_000_000), r.samples[1])
        val s = r.stats()!!
        assertEquals(2, s.count)
        assertEquals(4.0, s.mean, 1e-9) // 192 frames / 48 kHz = 4 ms each
    }

    @Test
    fun openFailureHidesUnsetModes() {
        val h = header()
        h[NativeResult.H_ERROR] = -896
        h[NativeResult.H_STAGE] = 2
        val r = NativeResult.parse("a_excl", h)
        assertEquals("-", r.sharing)
        assertEquals("-", r.perf)
        assertEquals("open", r.stage)
        assertEquals("-896", r.error)
    }

    @Test(expected = IllegalArgumentException::class)
    fun rejectsTruncatedSamples() {
        val h = header()
        h[NativeResult.H_SAMPLES] = 2
        NativeResult.parse("x", h + longArrayOf(1, 2, 3, 4))
    }

    @Test(expected = IllegalArgumentException::class)
    fun rejectsWrongHeaderLength() {
        val h = header()
        h[NativeResult.H_LEN] = 19
        NativeResult.parse("x", h)
    }

    @Test
    fun resultLineHasAllKeys() {
        val h = header()
        h[NativeResult.H_SAMPLES] = 1
        val r = NativeResult.parse("a_excl", h + longArrayOf(192, 0, 2_000_000_000, 2_000_000_000))
        val f = ResultFormat.resultFields(r, r.stats())
        for (k in listOf("case=a_excl", "sharing=exclusive", "perf=low_latency", "mmap=yes", "burst=96", "capacity=3072",
            "buf_final=288", "rate=48000", "xruns=1", "lat_mean_ms=4.00", "lat_p95_ms=4.00", "err=0")) {
            assertTrue("missing $k in $f", f.contains(k))
        }
        assertEquals("12 I aaprobe sid=- gen=0 ev=result $f", ResultFormat.line(12, 'I', "result", f))
    }

    @Test
    fun summaryGainIsTrackMinusAaudio() {
        fun res(case: String, api: String) = ProbeResult(case, api, "-", "-", "-", null, 0, 0, 0, 0, 0, 48_000, 2,
            "i16", 0, 0, 0, "0", "none", 0, emptyList())
        fun st(mean: Double) = LatencyStats(1, mean, mean, mean, mean, mean)
        val f = ResultFormat.summaryFields(listOf(
            res("a_excl", "aaudio") to st(8.0),
            res("b_shared", "aaudio") to null,
            res("c_track", "audiotrack") to st(50.0),
        ))
        assertEquals("a_excl_mean_ms=8.00 b_shared_mean_ms=na c_track_mean_ms=50.00 gain_a_excl_ms=42.00 gain_b_shared_ms=na", f)
    }
}
