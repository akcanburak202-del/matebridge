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

    @Test fun storeSavesAndReloads() {
        val kv = MapStore()
        val s = WolStore(kv)
        assertFalse(s.hasMacs())
        assertTrue(s.onResolved("192.168.1.20", "02:00:00:aa:bb:01"))
        assertEquals(listOf("02:00:00:aa:bb:01"), s.macs())
        assertEquals("192.168.1.20", s.host())
        val again = WolStore(kv)
        assertTrue(again.hasMacs())
        assertEquals(listOf("02:00:00:aa:bb:01"), again.macs())
        assertEquals("192.168.1.20", again.host())
    }

    @Test fun missingOrInvalidTxtKeepsStoredMacsButUpdatesHost() {
        val s = WolStore(MapStore())
        s.onResolved("192.168.1.20", "02:00:00:aa:bb:01")
        assertFalse(s.onResolved("192.168.1.21", null))
        assertFalse(s.onResolved("192.168.1.22", "garbage"))
        assertEquals(listOf("02:00:00:aa:bb:01"), s.macs())
        assertEquals("192.168.1.22", s.host())
    }

    @Test fun newValueReplaces() {
        val s = WolStore(MapStore())
        s.onResolved("192.168.1.20", "02:00:00:aa:bb:01")
        assertFalse(s.onResolved("192.168.1.20", "02:00:00:aa:bb:01")) // same: no change
        assertTrue(s.onResolved("192.168.1.20", "02:00:00:aa:bb:02,02:00:00:aa:bb:03"))
        assertEquals(listOf("02:00:00:aa:bb:02", "02:00:00:aa:bb:03"), s.macs())
    }

    @Test fun nonIpv4HostIsNotStored() {
        val kv = MapStore()
        val s = WolStore(kv)
        s.onResolved("fe80::1", "02:00:00:aa:bb:01")
        assertNull(s.host())
        kv.map["wol_host"] = "bogus"
        assertNull(WolStore(kv).host())
    }
}
