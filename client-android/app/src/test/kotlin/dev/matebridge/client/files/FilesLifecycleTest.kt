package dev.matebridge.client.files

import dev.matebridge.client.protocol.FilesInfo
import dev.matebridge.client.session.Transport
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

/** T-153: the file server runs only during a trusted USB session. */
class FilesLifecycleTest {
    // ---- FilesSwitch ----

    @Test fun shouldRunOnlyWhenEverythingHoldsOnUsb() {
        val bools = listOf(false, true)
        var trueCount = 0
        for (enabled in bools) for (permission in bools) for (foreground in bools) for (trusted in bools)
            for (transport in listOf(Transport.USB, Transport.WIFI, null)) {
                val run = FilesSwitch.shouldRun(enabled, permission, foreground, trusted, transport)
                val expected = enabled && permission && foreground && trusted && transport == Transport.USB
                assertEquals("e=$enabled p=$permission f=$foreground t=$trusted tr=$transport", expected, run)
                if (run) trueCount++
            }
        assertEquals(1, trueCount)
    }

    @Test fun idleStatusNamesTheFirstMissingCondition() {
        assertEquals(FilesStatus.DISABLED, FilesSwitch.idleStatus(enabled = false, permission = false, foreground = false))
        assertEquals(FilesStatus.NO_PERMISSION, FilesSwitch.idleStatus(enabled = true, permission = false, foreground = true))
        assertEquals(FilesStatus.PAUSED, FilesSwitch.idleStatus(enabled = true, permission = true, foreground = false))
        assertEquals(FilesStatus.NO_USB_SESSION, FilesSwitch.idleStatus(enabled = true, permission = true, foreground = true))
        val texts = listOf(FilesStatus.DISABLED, FilesStatus.NO_PERMISSION, FilesStatus.PAUSED, FilesStatus.NO_USB_SESSION)
            .map { FilesSwitch.statusText(it) }
        assertEquals(texts.size, texts.toSet().size)
        assertEquals("Durum: Mac'e USB ile bağlanınca açılır", FilesSwitch.statusText(FilesStatus.NO_USB_SESSION))
    }

    @Test fun stopReasons() {
        assertEquals("disabled", FilesSwitch.stopReason(enabled = false, permission = true, foreground = true, sessionTrusted = true))
        assertEquals("no_permission", FilesSwitch.stopReason(enabled = true, permission = false, foreground = true, sessionTrusted = true))
        assertEquals("background", FilesSwitch.stopReason(enabled = true, permission = true, foreground = false, sessionTrusted = true))
        assertEquals("no_session", FilesSwitch.stopReason(enabled = true, permission = true, foreground = true, sessionTrusted = false))
        assertEquals("wifi", FilesSwitch.stopReason(enabled = true, permission = true, foreground = true, sessionTrusted = true))
    }

    // ---- FilesSessionGate ----

    @Test fun connectedWithoutStreamConfigIsNotTrusted() {
        val g = FilesSessionGate()
        assertFalse(g.trusted)
        assertNull(g.transport)
        assertFalse(g.onConnectionGen(3, Transport.USB))
        assertFalse(g.onUi(connected = true)) // a PAIRED connection's plaintext ack: no sealed record yet
        assertFalse(g.trusted)
        assertTrue(g.onConfigApplied())
        assertTrue(g.trusted)
        assertEquals(Transport.USB, g.transport)
        assertFalse(g.onUi(connected = true)) // frame-count updates change nothing
        assertFalse(g.onConfigApplied()) // a reconfiguration of the same connection either
    }

    @Test fun anyNonConnectedStateDropsTrustUntilTheNextConfig() {
        val g = trustedGate(1, Transport.USB)
        assertTrue(g.onUi(connected = false))
        assertFalse(g.trusted)
        assertFalse(g.onUi(connected = true)) // the same generation reconnected? still needs its own config
        assertFalse(g.trusted)
        assertTrue(g.onConfigApplied())
        assertTrue(g.trusted)
    }

    @Test fun aNewConnectionGenerationIsUntrustedUntilItsConfig() {
        // Migration (stays Connected): the promoted candidate is a new generation.
        val g = trustedGate(4, Transport.WIFI)
        assertTrue(g.onConnectionGen(5, Transport.USB))
        assertFalse(g.trusted)
        assertFalse(g.onUi(connected = true))
        assertFalse(g.trusted)
        assertTrue(g.onConfigApplied())
        assertTrue(g.trusted)
        assertEquals(Transport.USB, g.transport)
        // USB -> Wi-Fi: trust drops at the switch; the Wi-Fi config is trusted, but on Wi-Fi.
        assertTrue(g.onConnectionGen(6, Transport.WIFI))
        assertFalse(g.trusted)
        assertTrue(g.onConfigApplied())
        assertTrue(g.trusted)
        assertEquals(Transport.WIFI, g.transport)
    }

    @Test fun configBeforeAnyConnectionIsNotTrusted() {
        val g = FilesSessionGate()
        assertFalse(g.onConfigApplied())
        assertFalse(g.onUi(connected = true))
        assertFalse(g.trusted)
    }

    // ---- FilesLifecycle ----

    private class FakeServer(val token: String, val events: FilesLifecycle.Events, val after: FakeServer?, val log: MutableList<String>) :
        FilesLifecycle.Server {
        var started = false
        var stopped = false
        override fun start() { started = true; log += "start:$token" }
        override fun stop() { stopped = true; log += "stop:$token" }
    }

    private class Rig {
        val events = mutableListOf<String>()
        val published = mutableListOf<FilesInfo>()
        val servers = mutableListOf<FakeServer>()
        var statusCalls = 0
        private var n = 0
        val lc = FilesLifecycle<FakeServer>(
            factory = { token, ev, after -> FakeServer(token, ev, after, events).also { servers += it } },
            newToken = { "tok${++n}" },
            publish = { published += it; events += if (it.ready) "ready:${it.token}" else "off" },
            onStatus = { statusCalls++ },
            log = { _, _, _ -> },
        )

        fun sync(trusted: Boolean = true, transport: Transport? = Transport.USB, enabled: Boolean = true, foreground: Boolean = true) =
            lc.sync(enabled, permission = true, foreground = foreground, sessionTrusted = trusted, transport = transport)
    }

    @Test fun startsOnTrustedUsbAndPublishesReadyOnlyWhenListening() {
        val r = Rig()
        r.sync()
        assertEquals(1, r.servers.size)
        assertTrue(r.servers[0].started)
        assertEquals(FilesStatus.STARTING, r.lc.status)
        assertTrue(r.published.isEmpty())
        r.servers[0].events.onListening(47100)
        assertEquals(listOf(FilesInfo(FilesInfo.STATE_READY, 47100, "tok1")), r.published)
        assertEquals(FilesStatus.READY, r.lc.status)
        r.sync() // already running: no second server
        assertEquals(1, r.servers.size)
    }

    @Test fun neverStartsOnWifiOrUntrusted() {
        val r = Rig()
        r.sync(transport = Transport.WIFI)
        r.sync(trusted = false)
        r.sync(trusted = false, transport = null)
        assertTrue(r.servers.isEmpty())
        assertTrue(r.published.isEmpty())
        assertEquals(FilesStatus.NO_USB_SESSION, r.lc.status)
    }

    @Test fun sessionEndPublishesOffBeforeStopAndTheNextStartHasANewToken() {
        val r = Rig()
        r.sync()
        r.servers[0].events.onListening(1)
        r.events.clear()
        r.sync(trusted = false) // session end / loss of the trusted signal
        assertEquals(listOf("off", "stop:tok1"), r.events)
        assertEquals(FilesStatus.NO_USB_SESSION, r.lc.status)
        r.sync()
        assertEquals(2, r.servers.size)
        assertNotEquals(r.servers[0].token, r.servers[1].token)
        assertSame(r.servers[0], r.servers[1].after) // waits for the old workers
        r.servers[1].events.onListening(2)
        assertEquals(FilesInfo(FilesInfo.STATE_READY, 2, "tok2"), r.published.last())
    }

    @Test fun switchToWifiStopsWithOffFirst() {
        val r = Rig()
        r.sync()
        r.servers[0].events.onListening(1)
        r.events.clear()
        r.sync(transport = Transport.WIFI)
        assertEquals(listOf("off", "stop:tok1"), r.events)
        assertTrue(r.servers[0].stopped)
    }

    @Test fun otherStopsAlsoPublishOffFirst() {
        for (stop in listOf<(Rig) -> Unit>({ it.sync(enabled = false) }, { it.sync(foreground = false) }, { it.lc.shutdown() })) {
            val r = Rig()
            r.sync()
            r.events.clear()
            stop(r)
            assertEquals(listOf("off", "stop:tok1"), r.events)
        }
    }

    @Test fun lateCallbacksOfAStoppedServerAreIgnored() {
        val r = Rig()
        r.sync()
        val old = r.servers[0]
        r.sync(trusted = false)
        r.published.clear()
        old.events.onListening(9) // its listen raced the stop
        old.events.onStopped(failed = false)
        assertTrue(r.published.isEmpty())
        assertEquals(FilesStatus.NO_USB_SESSION, r.lc.status)
    }

    @Test fun aServerThatFailsReportsOffAndFailedAndRestartsOnTheNextSync() {
        val r = Rig()
        r.sync()
        r.servers[0].events.onStopped(failed = true)
        assertEquals(listOf(FilesInfo.OFF), r.published)
        assertEquals(FilesStatus.FAILED, r.lc.status)
        r.sync()
        assertEquals(2, r.servers.size)
        assertNotEquals("tok1", r.servers[1].token)
        assertSame(r.servers[0], r.servers[1].after)
    }

    @Test fun stopWithoutServerPublishesNothing() {
        val r = Rig()
        r.sync(trusted = false)
        r.lc.shutdown()
        assertTrue(r.events.isEmpty())
    }

    private fun trustedGate(gen: Int, transport: Transport) = FilesSessionGate().also {
        it.onConnectionGen(gen, transport)
        it.onUi(connected = true)
        it.onConfigApplied()
        assertTrue(it.trusted)
    }
}
