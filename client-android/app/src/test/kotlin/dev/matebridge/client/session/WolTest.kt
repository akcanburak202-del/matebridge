package dev.matebridge.client.session

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class WolTest {
    private fun ip(vararg b: Int) = ByteArray(4) { b[it].toByte() }

    // ---- magic packet ----

    @Test fun magicPacketLayout() {
        val mac = byteArrayOf(0x02, 0x00, 0x00, 0xAA.toByte(), 0xBB.toByte(), 0x01)
        val p = WolPacket.magic(mac)
        assertEquals(102, p.size)
        assertEquals(WolPacket.SIZE, p.size)
        for (i in 0 until 6) assertEquals(0xFF.toByte(), p[i])
        for (r in 0 until 16) assertArrayEquals(mac, p.copyOfRange(6 + r * 6, 12 + r * 6))
        assertEquals(9, WolPacket.PORT)
    }

    @Test fun magicPacketExactBytes() {
        val p = WolPacket.magic(WolTxt.bytes("01:23:45:67:89:ab")!!)
        val hex = p.joinToString("") { "%02x".format(it.toInt() and 0xFF) }
        assertEquals("ffffffffffff" + "0123456789ab".repeat(16), hex)
    }

    @Test(expected = IllegalArgumentException::class)
    fun magicPacketRejectsWrongLength() { WolPacket.magic(ByteArray(5)) }

    // ---- TXT parsing ----

    @Test fun parsesProtocolExample() {
        assertEquals(listOf("02:00:00:aa:bb:01", "02:00:00:aa:bb:02"), WolTxt.parse("02:00:00:aa:bb:01,02:00:00:aa:bb:02"))
    }

    @Test fun parseNormalisesCaseAndWhitespace() {
        assertEquals(listOf("02:00:00:aa:bb:01"), WolTxt.parse(" 02:00:00:AA:bB:01 "))
    }

    @Test fun parseSkipsInvalid() {
        val raw = listOf(
            "", "zz:00:00:00:00:01", "02:00:00:aa:bb", "02:00:00:aa:bb:01:02", "02-00-00-aa-bb-01", "2:00:00:aa:bb:01",
            "00:00:00:00:00:00", "ff:ff:ff:ff:ff:ff", "01:00:5e:00:00:01", // zero, broadcast, multicast
            "02:00:00:aa:bb:03", "02:00:00:aa:bb:03", // duplicate kept once
        ).joinToString(",")
        assertEquals(listOf("02:00:00:aa:bb:03"), WolTxt.parse(raw))
    }

    @Test fun parseKeepsAtMostFour() {
        val raw = (1..6).joinToString(",") { "02:00:00:00:00:0$it" }
        assertEquals((1..4).map { "02:00:00:00:00:0$it" }, WolTxt.parse(raw))
    }

    @Test fun parseInvalidDoesNotCountTowardsLimit() {
        val raw = "bad,bad2,bad3,bad4,02:00:00:00:00:01"
        assertEquals(listOf("02:00:00:00:00:01"), WolTxt.parse(raw))
    }

    @Test fun parseNullAndEmpty() {
        assertTrue(WolTxt.parse(null).isEmpty())
        assertTrue(WolTxt.parse("").isEmpty())
        assertTrue(WolTxt.parse(",,,").isEmpty())
    }

    // ---- targets ----

    @Test fun parsesIpv4() {
        assertArrayEquals(ip(192, 168, 1, 20), WolTargets.parseIpv4("192.168.1.20"))
        assertNull(WolTargets.parseIpv4("192.168.1"))
        assertNull(WolTargets.parseIpv4("192.168.1.256"))
        assertNull(WolTargets.parseIpv4("fe80::1"))
        assertNull(WolTargets.parseIpv4("mac.local"))
        assertNull(WolTargets.parseIpv4("1.2.3.-4"))
        assertNull(WolTargets.parseIpv4(null))
    }

    @Test fun subnetBroadcast() {
        assertArrayEquals(ip(192, 168, 1, 255), WolTargets.subnetBroadcast(ip(192, 168, 1, 20), 24))
        assertArrayEquals(ip(10, 0, 3, 255), WolTargets.subnetBroadcast(ip(10, 0, 1, 7), 22))
        assertArrayEquals(ip(172, 16, 0, 3), WolTargets.subnetBroadcast(ip(172, 16, 0, 1), 30))
        assertArrayEquals(ip(255, 255, 255, 255), WolTargets.subnetBroadcast(ip(10, 0, 0, 1), 0))
        assertNull(WolTargets.subnetBroadcast(ip(10, 0, 0, 1), 31))
        assertNull(WolTargets.subnetBroadcast(ip(10, 0, 0, 1), 32))
        assertNull(WolTargets.subnetBroadcast(ip(10, 0, 0, 1), -1))
        assertNull(WolTargets.subnetBroadcast(ByteArray(16), 64))
    }

    @Test fun targetsOrderAndDedupe() {
        val t = WolTargets.build(listOf(ip(192, 168, 1, 255), ip(192, 168, 1, 255)), "192.168.1.20")
        assertEquals(3, t.size)
        assertArrayEquals(ip(255, 255, 255, 255), t[0])
        assertArrayEquals(ip(192, 168, 1, 255), t[1])
        assertArrayEquals(ip(192, 168, 1, 20), t[2])
    }

    @Test fun targetsWithoutHostOrSubnet() {
        val t = WolTargets.build(emptyList(), "not-an-ip")
        assertEquals(1, t.size)
        assertArrayEquals(WolTargets.LIMITED_BROADCAST, t[0])
    }

    // ---- store ----

    private class MapStore : KeyValueStore {
        val map = HashMap<String, String>()
        override fun getString(key: String) = map[key]
        override fun putString(key: String, value: String) { map[key] = value }
    }

    private val home = Ipv4Subnet.of(ip(192, 168, 1, 0), 24)!!
    private val other = Ipv4Subnet.of(ip(10, 0, 0, 0), 8)!!

    @Test fun storeSavesAndReloads() {
        val kv = MapStore()
        val s = WolStore(kv)
        assertFalse(s.hasMacs())
        assertTrue(s.onResolved("192.168.1.20", "02:00:00:aa:bb:01", home))
        assertEquals(listOf("02:00:00:aa:bb:01"), s.macs())
        assertEquals("192.168.1.20", s.host())
        assertEquals(home, s.subnet())
        val again = WolStore(kv)
        assertTrue(again.hasMacs())
        assertEquals(listOf("02:00:00:aa:bb:01"), again.macs())
        assertEquals("192.168.1.20", again.host())
        assertEquals(home, again.subnet())
    }

    @Test fun missingOrInvalidTxtKeepsEverythingStored() {
        val s = WolStore(MapStore())
        s.onResolved("192.168.1.20", "02:00:00:aa:bb:01", home)
        assertFalse(s.onResolved("10.0.0.21", null, other))
        assertFalse(s.onResolved("10.0.0.22", "garbage", other))
        assertEquals(listOf("02:00:00:aa:bb:01"), s.macs())
        assertEquals("192.168.1.20", s.host())
        assertEquals(home, s.subnet())
    }

    @Test fun newValueReplaces() {
        val s = WolStore(MapStore())
        s.onResolved("192.168.1.20", "02:00:00:aa:bb:01", home)
        assertFalse(s.onResolved("192.168.1.20", "02:00:00:aa:bb:01", home)) // same: no change
        assertTrue(s.onResolved("192.168.1.20", "02:00:00:aa:bb:02,02:00:00:aa:bb:03", home))
        assertEquals(listOf("02:00:00:aa:bb:02", "02:00:00:aa:bb:03"), s.macs())
    }

    @Test fun hostAndSubnetFollowAValidValue() {
        val s = WolStore(MapStore())
        s.onResolved("192.168.1.20", "02:00:00:aa:bb:01", home)
        assertTrue(s.onResolved("10.0.0.5", "02:00:00:aa:bb:01", other)) // moved: same MACs, new home
        assertEquals("10.0.0.5", s.host())
        assertEquals(other, s.subnet())
        assertFalse(s.onResolved("10.0.0.6", "02:00:00:aa:bb:01", null)) // subnet unknown: stored one kept
        assertEquals("10.0.0.6", s.host())
        assertEquals(other, s.subnet())
    }

    @Test fun portIsStoredWithTheHostAndDefaultsTo47001() {
        val kv = MapStore()
        val s = WolStore(kv)
        assertNull(s.wakeEndpoint())
        assertEquals(47001, s.port())
        s.onResolved("192.168.1.20", "02:00:00:aa:bb:01", home) // no port from the resolution: default
        assertEquals(Endpoint("192.168.1.20", 47001), s.wakeEndpoint())
        s.onResolved("192.168.1.20", "02:00:00:aa:bb:01", home, 47011)
        assertEquals(Endpoint("192.168.1.20", 47011), s.wakeEndpoint())
        assertEquals(Endpoint("192.168.1.20", 47011), WolStore(kv).wakeEndpoint()) // persisted
        s.onResolved("192.168.1.20", "02:00:00:aa:bb:01", home, 0) // out of range: kept
        s.onResolved("192.168.1.21", null, home, 47099) // no usable TXT: nothing stored
        assertEquals(Endpoint("192.168.1.20", 47011), s.wakeEndpoint())
        s.onResolved("fe80::1", "02:00:00:aa:bb:01", home, 47099) // not an IPv4 host: its port is not stored either
        assertEquals(Endpoint("192.168.1.20", 47011), s.wakeEndpoint())
        kv.map["wol_port"] = "99999"
        assertEquals(47001, WolStore(kv).port())
    }

    @Test fun nonIpv4HostIsNotStored() {
        val kv = MapStore()
        val s = WolStore(kv)
        s.onResolved("fe80::1", "02:00:00:aa:bb:01", home)
        assertNull(s.host())
        kv.map["wol_host"] = "bogus"
        kv.map["wol_subnet"] = "bogus"
        assertNull(WolStore(kv).host())
        assertNull(WolStore(kv).subnet())
    }

    // ---- home network ----

    @Test fun subnetOfClearsHostBitsAndRoundTrips() {
        val s = Ipv4Subnet.of(ip(192, 168, 1, 37), 24)!!
        assertEquals("192.168.1.0/24", s.toString())
        assertEquals(s, Ipv4Subnet.parse("192.168.1.0/24"))
        assertEquals(s, Ipv4Subnet.parse("192.168.1.99/24"))
        assertEquals("10.0.0.0/22", Ipv4Subnet.of(ip(10, 0, 3, 200), 22).toString())
        assertTrue(s.contains(ip(192, 168, 1, 20)))
        assertFalse(s.contains(ip(192, 168, 2, 20)))
        assertNull(Ipv4Subnet.of(ip(1, 2, 3, 4), 0))
        assertNull(Ipv4Subnet.of(ip(1, 2, 3, 4), 33))
        assertNull(Ipv4Subnet.parse("192.168.1.0"))
        assertNull(Ipv4Subnet.parse("192.168.1.0/"))
        assertNull(Ipv4Subnet.parse("192.168.1.0/x"))
        assertNull(Ipv4Subnet.parse("/24"))
        assertNull(Ipv4Subnet.parse(null))
    }

    @Test fun pickPrefersTheSubnetContainingTheHost() {
        assertEquals(home, HomeNetwork.pick(listOf(other, home), "192.168.1.20"))
        assertEquals(other, HomeNetwork.pick(listOf(other, home), "172.16.0.1")) // routed: first one
        assertNull(HomeNetwork.pick(emptyList(), "192.168.1.20"))
    }

    @Test fun skipReasons() {
        assertNull(HomeNetwork.skipReason(home, listOf(other, home)))
        assertEquals(HomeNetwork.SKIP_OTHER_NETWORK, HomeNetwork.skipReason(home, listOf(other)))
        assertEquals(HomeNetwork.SKIP_NO_WIFI, HomeNetwork.skipReason(home, emptyList()))
        assertEquals(HomeNetwork.SKIP_HOME_UNKNOWN, HomeNetwork.skipReason(null, listOf(home)))
        // Same network address with another prefix is another network.
        assertEquals(HomeNetwork.SKIP_OTHER_NETWORK, HomeNetwork.skipReason(home, listOf(Ipv4Subnet.of(ip(192, 168, 1, 0), 23)!!)))
    }
}
