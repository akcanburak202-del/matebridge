package dev.matebridge.client.session

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class WifiKnobsTest {
    private fun parse(ints: Map<String, Int> = emptyMap()) = WifiKnobs.parse({ it in ints }, { ints.getValue(it) })

    @Test fun defaultsKeepTodaysBehaviour() {
        val k = parse()
        assertEquals(WifiKnobs(), k)
        assertEquals(500, k.pingMs)
        assertEquals(SessionMachine.PING_INTERVAL_US, k.pingIntervalUs)
        assertEquals("ping_ms=500", k.logFields())
    }

    @Test fun parsesPing() {
        val k = parse(mapOf("ping_ms" to 100))
        assertEquals(WifiKnobs(100), k)
        assertEquals(100_000L, k.pingIntervalUs)
        assertEquals("ping_ms=100", k.logFields())
    }

    @Test fun pingIsClamped() {
        assertEquals(WifiKnobs.MIN_PING_MS, parse(mapOf("ping_ms" to 0)).pingMs)
        assertEquals(WifiKnobs.MIN_PING_MS, parse(mapOf("ping_ms" to -5)).pingMs)
        assertEquals(WifiKnobs.MAX_PING_MS, parse(mapOf("ping_ms" to 60_000)).pingMs)
    }

    // ---- TrafficClass ----

    @Test fun trafficClassUntouchedWhenNotRequested() {
        var calls = 0
        assertNull(TrafficClass.trySet(null) { calls++ })
        assertEquals(0, calls)
    }

    @Test fun trafficClassAppliedAndFailureIsNotFatal() {
        var tc = 0
        assertNull(TrafficClass.trySet(0x20) { tc = it })
        assertEquals(0x20, tc)
        assertEquals("SocketException", TrafficClass.trySet(0x88) { throw java.net.SocketException("nope") })
    }

    // ---- RttStats ----

    @Test fun emptyWindow() {
        val s = RttStats().snapshot(reset = true)
        assertEquals(0, s.count)
        assertEquals("rtt_ms_p50_95_max=- rtt_n=0", s.fields())
    }

    @Test fun percentilesNearestRank() {
        val r = RttStats()
        for (v in 1..20) r.add(v * 1000L) // 1..20 ms, out of order does not matter
        val s = r.snapshot(reset = false)
        assertEquals(20, s.count)
        assertEquals(10_000L, s.p50Us)
        assertEquals(19_000L, s.p95Us)
        assertEquals(20_000L, s.maxUs)
        assertEquals("rtt_ms_p50_95_max=10.00/19.00/20.00 rtt_n=20", s.fields())
    }

    @Test fun twoSamplesPerSecondAtDefaultPing() {
        val r = RttStats()
        r.add(3_400)
        r.add(1_200)
        assertEquals("rtt_ms_p50_95_max=1.20/3.40/3.40 rtt_n=2", r.snapshot(reset = true).fields())
    }

    @Test fun resetStartsNewWindowAndNegativeIgnored() {
        val r = RttStats()
        r.add(5_000)
        r.snapshot(reset = true)
        r.add(-1)
        assertEquals(0, r.snapshot(reset = true).count)
        r.add(7_000)
        r.reset()
        assertEquals(0, r.snapshot(reset = false).count)
    }

    @Test fun windowIsBounded() {
        val r = RttStats(cap = 4)
        for (v in 1..10) r.add(v.toLong())
        val s = r.snapshot(reset = true)
        assertEquals(4, s.count)
        assertEquals(10L, s.maxUs)
        assertEquals(8L, s.p50Us) // 7,8,9,10 kept
    }
}
