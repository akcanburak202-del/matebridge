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

    @Test fun usbHintAfterTimeoutOnlyInManualUsbMode() {
        assertFalse(ConnectMode.showUsbHint(TransportMode.USB, 2999, false))
        assertTrue(ConnectMode.showUsbHint(TransportMode.USB, 3000, false))
        assertFalse(ConnectMode.showUsbHint(TransportMode.USB, 5000, true))
        assertFalse(ConnectMode.showUsbHint(TransportMode.WIFI, 5000, false))
        assertFalse(ConnectMode.showUsbHint(TransportMode.AUTO, 5000, false)) // AUTO falls back to Wi-Fi instead
    }

    @Test fun transportModePersistsAndDefaultsToAuto() {
        val map = HashMap<String, String>()
        val s = Settings(object : KeyValueStore {
            override fun getString(key: String) = map[key]
            override fun putString(key: String, value: String) { map[key] = value }
        })
        assertEquals(TransportMode.AUTO, s.transportMode())
        s.setTransportMode(TransportMode.USB)
        assertEquals(TransportMode.USB, s.transportMode())
        s.setTransportMode(TransportMode.WIFI)
        assertEquals(TransportMode.WIFI, s.transportMode())
        s.setTransportMode(TransportMode.AUTO)
        assertEquals(TransportMode.AUTO, s.transportMode())
    }

    private fun settingsWith(map: HashMap<String, String>) = Settings(object : KeyValueStore {
        override fun getString(key: String) = map[key]
        override fun putString(key: String, value: String) { map[key] = value }
    })

    @Test fun storedPreT096ChoiceIsMigratedToAutoExactlyOnce() {
        for (stored in listOf("usb", "wifi")) {
            val map = hashMapOf("transport" to stored)
            val s = settingsWith(map)
            assertEquals(stored, s.migrateTransportToAutoOnce())
            assertEquals(TransportMode.AUTO, s.transportMode())
            // afterwards an explicit panel choice is respected, also across restarts
            s.setTransportMode(TransportMode.WIFI)
            assertEquals(null, s.migrateTransportToAutoOnce())
            assertEquals(null, settingsWith(map).migrateTransportToAutoOnce())
            assertEquals(TransportMode.WIFI, settingsWith(map).transportMode())
        }
    }

    @Test fun migrationOnAFreshInstallChangesNothingButSetsTheFlag() {
        val map = HashMap<String, String>()
        val s = settingsWith(map)
        assertEquals(null, s.migrateTransportToAutoOnce())
        assertEquals(TransportMode.AUTO, s.transportMode())
        s.setTransportMode(TransportMode.USB)
        assertEquals(null, s.migrateTransportToAutoOnce())
        assertEquals(TransportMode.USB, s.transportMode())
    }
}
