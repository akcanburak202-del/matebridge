package dev.matebridge.client.session

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class WifiKnobsTest {
    private fun parse(ints: Map<String, Int> = emptyMap(), bools: Map<String, Boolean> = emptyMap()) =
        WifiKnobs.parse({ it in ints || it in bools }, { ints.getValue(it) }, { bools.getValue(it) })

    @Test fun defaultsKeepTodaysBehaviour() {
        val k = parse()
        assertEquals(WifiKnobs(), k)
        assertEquals(500, k.pingMs)
        assertEquals(SessionMachine.PING_INTERVAL_US, k.pingIntervalUs)
        assertNull(k.tosCtl)
        assertNull(k.tosVideo)
        assertFalse(k.wifiLowLatency)
        assertEquals("ping_ms=500 tos_ctl=- tos_video=- wifi_ll=0", k.logFields())
    }

    @Test fun parsesAllKnobs() {
        val k = parse(mapOf("ping_ms" to 100, "tos_ctl" to 0xB8, "tos_video" to 0x88), mapOf("wifi_ll" to true))
        assertEquals(WifiKnobs(100, 0xB8, 0x88, true), k)
        assertEquals(100_000L, k.pingIntervalUs)
        assertEquals("ping_ms=100 tos_ctl=0xb8 tos_video=0x88 wifi_ll=1", k.logFields())
    }

    @Test fun pingIsClamped() {
        assertEquals(WifiKnobs.MIN_PING_MS, parse(mapOf("ping_ms" to 0)).pingMs)
        assertEquals(WifiKnobs.MIN_PING_MS, parse(mapOf("ping_ms" to -5)).pingMs)
        assertEquals(WifiKnobs.MAX_PING_MS, parse(mapOf("ping_ms" to 60_000)).pingMs)
    }

    @Test fun outOfRangeTosIsIgnored() {
        val k = parse(mapOf("tos_ctl" to 256, "tos_video" to -1))
        assertNull(k.tosCtl)
        assertNull(k.tosVideo)
        assertEquals(0, parse(mapOf("tos_ctl" to 0)).tosCtl) // 0 is an explicit request, not "absent"
    }

    @Test fun wifiLlFalseWhenExplicitlyOff() {
        assertFalse(parse(bools = mapOf("wifi_ll" to false)).wifiLowLatency)
    }

    // ---- TrafficClass ----

    @Test fun trafficClassUntouchedWhenNotRequested() {
        var calls = 0
        assertNull(TrafficClass.trySet(null) { calls++ })
        assertEquals(0, calls)
    }

    @Test fun trafficClassAppliedAndLogged() {
        var tc = 0
        assertNull(TrafficClass.trySet(0xB8) { tc = it })
        assertEquals(0xB8, tc)
        assertEquals("sock=control requested=0xb8 applied=0xb8", TrafficClass.logFields("control", 0xB8, null) { tc })
    }

    @Test fun trafficClassFailureIsNotFatal() {
        val err = TrafficClass.trySet(0x88) { throw java.net.SocketException("nope") }
        assertEquals("SocketException", err)
        assertEquals(
            "sock=video requested=0x88 applied=-1 err=SocketException",
            TrafficClass.logFields("video", 0x88, err) { throw java.net.SocketException("closed") },
        )
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

    // ---- Wi-Fi lock ----

    private val connected = SessionUi.Connected("Mac", 1)

    @Test fun policyHoldsOnlyForConnectedWifiSessionWhileStarted() {
        assertTrue(WifiLockPolicy.shouldHold(true, Transport.WIFI, true, connected))
        assertFalse(WifiLockPolicy.shouldHold(false, Transport.WIFI, true, connected)) // knob off (default)
        assertFalse(WifiLockPolicy.shouldHold(true, Transport.USB, true, connected)) // USB
        assertFalse(WifiLockPolicy.shouldHold(true, Transport.WIFI, false, connected)) // background
        for (ui in listOf(
            SessionUi.Idle, SessionUi.Searching, SessionUi.Connecting(Endpoint("10.0.0.5", 7420)),
            SessionUi.Disconnected(SessionUi.Cause.LOST, 1000), SessionUi.Failed(SessionUi.Cause.REJECTED),
        )) {
            assertFalse(ui.toString(), WifiLockPolicy.shouldHold(true, Transport.WIFI, true, ui))
        }
    }

    private class FakeLock(var failAcquire: Boolean = false, var failRelease: Boolean = false) : WifiLockHolder.Backend {
        var held = false
        var acquires = 0
        override fun acquire() {
            acquires++
            if (failAcquire) throw IllegalStateException("x")
            held = true
        }
        override fun release() {
            held = false
            if (failRelease) throw IllegalStateException("y")
        }
    }

    @Test fun holderIsIdempotentAndLogsChanges() {
        val lock = FakeLock()
        val log = mutableListOf<String>()
        val h = WifiLockHolder(lock) { log += it }
        h.sync(true, "connected")
        h.sync(true, "connected")
        assertTrue(lock.held)
        assertEquals(1, lock.acquires)
        h.sync(false, "disconnected")
        h.sync(false, "stopped")
        assertFalse(lock.held)
        assertFalse(h.held)
        assertEquals(listOf("held=1 reason=connected", "held=0 reason=disconnected"), log)
    }

    @Test fun failedAcquireIsNotRetried() {
        val lock = FakeLock(failAcquire = true)
        val log = mutableListOf<String>()
        val h = WifiLockHolder(lock) { log += it }
        h.sync(true, "connected")
        h.sync(true, "connected")
        assertFalse(h.held)
        assertEquals(1, lock.acquires)
        assertEquals(listOf("held=0 reason=connected err=IllegalStateException"), log)
    }

    @Test fun failedReleaseStillCountsAsReleased() {
        val lock = FakeLock(failRelease = true)
        val log = mutableListOf<String>()
        val h = WifiLockHolder(lock) { log += it }
        h.sync(true, "connected")
        h.sync(false, "background")
        assertFalse(h.held)
        assertEquals("held=0 reason=background err=IllegalStateException", log.last())
    }
}
