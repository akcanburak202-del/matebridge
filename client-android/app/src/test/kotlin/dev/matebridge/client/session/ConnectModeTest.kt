package dev.matebridge.client.session

import org.junit.Test
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue

class ConnectModeTest {
    @Test fun usbEndpointIsLoopback47001() {
        assertEquals("127.0.0.1:47001", ConnectMode.usbEndpoint.toString())
    }

    @Test fun transportOfEndpoint() {
        assertEquals(Transport.USB, ConnectMode.transportOf(Endpoint("127.0.0.1", 47001)))
        assertEquals(Transport.WIFI, ConnectMode.transportOf(Endpoint("192.168.1.20", 47001)))
    }

    @Test fun onlyWifiAutoDiscovers() {
        assertTrue(ConnectMode.autoDiscover(Transport.WIFI))
        assertFalse(ConnectMode.autoDiscover(Transport.USB))
    }

    @Test fun usbHintAfterTimeoutOnly() {
        assertFalse(ConnectMode.showUsbHint(Transport.USB, 2999, false))
        assertTrue(ConnectMode.showUsbHint(Transport.USB, 3000, false))
        assertFalse(ConnectMode.showUsbHint(Transport.USB, 5000, true))
        assertFalse(ConnectMode.showUsbHint(Transport.WIFI, 5000, false))
    }

    @Test fun transportPersistsAndDefaultsToWifi() {
        val map = HashMap<String, String>()
        val s = Settings(object : KeyValueStore {
            override fun getString(key: String) = map[key]
            override fun putString(key: String, value: String) { map[key] = value }
        })
        assertEquals(Transport.WIFI, s.transport())
        s.setTransport(Transport.USB)
        assertEquals(Transport.USB, s.transport())
        s.setTransport(Transport.WIFI)
        assertEquals(Transport.WIFI, s.transport())
    }
}
