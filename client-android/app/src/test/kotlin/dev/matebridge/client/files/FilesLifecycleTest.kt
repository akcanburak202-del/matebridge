package dev.matebridge.client.files

import dev.matebridge.client.protocol.FilesInfo
import dev.matebridge.client.protocol.FilesNet
import dev.matebridge.client.session.Transport
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

/** T-153: the file server runs only during a trusted USB session; T-269 (decision 0035): or a Wi-Fi one the Mac opened. */
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

    @Test fun overWifiTheServerRunsOnlyAfterTheMacOpenedIt() {
        val bools = listOf(false, true)
        var trueCount = 0
        for (enabled in bools) for (permission in bools) for (foreground in bools) for (trusted in bools)
            for (transport in listOf(Transport.USB, Transport.WIFI, null)) for (netOpen in bools) {
                val run = FilesSwitch.shouldRun(enabled, permission, foreground, trusted, transport, netOpen)
                val base = enabled && permission && foreground && trusted
                val expected = base && (transport == Transport.USB || (transport == Transport.WIFI && netOpen))
                assertEquals("e=$enabled p=$permission f=$foreground t=$trusted tr=$transport n=$netOpen", expected, run)
                if (run) trueCount++
                // STANDBY is the Wi-Fi state in which everything holds but the Mac has not opened it; never on USB
                val standby = FilesSwitch.standbyEligible(enabled, permission, foreground, trusted, transport)
                assertEquals(base && transport == Transport.WIFI, standby)
            }
        assertEquals(3, trueCount) // USB with netOpen either way, and Wi-Fi with netOpen
    }

    @Test fun idleStatusNamesTheFirstMissingCondition() {
        assertEquals(FilesStatus.DISABLED, FilesSwitch.idleStatus(enabled = false, permission = false, foreground = false))
        assertEquals(FilesStatus.NO_PERMISSION, FilesSwitch.idleStatus(enabled = true, permission = false, foreground = true))
        assertEquals(FilesStatus.PAUSED, FilesSwitch.idleStatus(enabled = true, permission = true, foreground = false))
        assertEquals(FilesStatus.NO_USB_SESSION, FilesSwitch.idleStatus(enabled = true, permission = true, foreground = true))
        val texts = listOf(FilesStatus.DISABLED, FilesStatus.NO_PERMISSION, FilesStatus.PAUSED, FilesStatus.NO_USB_SESSION)
            .map { FilesSwitch.statusText(it) }
        assertEquals(texts.size, texts.toSet().size)
        assertEquals(
            "Durum: Mac'e bağlanınca açılır (USB'de hemen, Wi-Fi'da Mac'ten açılınca)",
            FilesSwitch.statusText(FilesStatus.NO_USB_SESSION),
        )
    }

    @Test fun wifiStatusLinesAreTheTurkishTextsOfTheCard() {
        // a trusted Wi-Fi session that the Mac has not opened: standby; with a server up: open on the Wi-Fi folder
        assertEquals(
            FilesStatus.WIFI_STANDBY,
            FilesSwitch.idleStatus(enabled = true, permission = true, foreground = true, sessionTrusted = true, transport = Transport.WIFI),
        )
        assertEquals(
            FilesStatus.NO_USB_SESSION,
            FilesSwitch.idleStatus(enabled = true, permission = true, foreground = true, sessionTrusted = true, transport = Transport.USB),
        )
        assertEquals("Durum: Mac'ten açılmayı bekliyor (Wi-Fi)", FilesSwitch.statusText(FilesStatus.WIFI_STANDBY))
        assertEquals("Durum: Mac'e açık (Wi-Fi, MateBridge/Wi-Fi)", FilesSwitch.statusText(FilesStatus.WIFI_READY))
        val all = FilesStatus.entries.map { FilesSwitch.statusText(it) }
        assertEquals(all.size, all.toSet().size)
    }

    @Test fun stopReasons() {
        assertEquals("disabled", FilesSwitch.stopReason(enabled = false, permission = true, foreground = true, sessionTrusted = true))
        assertEquals("no_permission", FilesSwitch.stopReason(enabled = true, permission = false, foreground = true, sessionTrusted = true))
        assertEquals("background", FilesSwitch.stopReason(enabled = true, permission = true, foreground = false, sessionTrusted = true))
        assertEquals("no_session", FilesSwitch.stopReason(enabled = true, permission = true, foreground = true, sessionTrusted = false))
        assertEquals("wifi", FilesSwitch.stopReason(enabled = true, permission = true, foreground = true, sessionTrusted = true))
        assertEquals("net_closed", FilesSwitch.stopReason(true, true, true, true, Transport.WIFI))
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

    @Test fun theMacsOpenRequestBelongsToTheConnectionAndIsForgottenWithIt() {
        val open = FilesNet(FilesNet.STATE_OPEN, 47003, 2, 12)
        val g = trustedGate(4, Transport.WIFI)
        assertFalse(g.netOpen)
        assertTrue(g.onFilesNet(4, open))
        assertTrue(g.netOpen)
        assertFalse(g.onFilesNet(4, open)) // a repeat changes nothing
        assertTrue(g.onFilesNet(4, open.copy(port = 47004))) // another listener port: a change
        assertFalse(g.onFilesNet(3, FilesNet(FilesNet.STATE_CLOSE, 0, 0, 0))) // an old generation is ignored
        assertTrue(g.netOpen)
        assertTrue(g.onFilesNet(4, FilesNet(FilesNet.STATE_CLOSE, 0, 0, 0)))
        assertFalse(g.netOpen)
        assertTrue(g.onFilesNet(4, open))
        assertTrue(g.onFilesNet(4, FilesNet(77, 0, 0, 0))) // an unknown state is CLOSE
        assertFalse(g.netOpen)
        // a new connection generation and any non-Connected state forget an OPEN
        g.onFilesNet(4, open)
        assertTrue(g.onConnectionGen(5, Transport.WIFI))
        assertFalse(g.netOpen)
        g.onConfigApplied()
        g.onFilesNet(5, open)
        assertTrue(g.onUi(connected = false))
        assertFalse(g.netOpen)
    }

    @Test fun aForgottenOpenDoesNotRestartTheServerWhenSharingIsSwitchedBackOn() {
        val g = trustedGate(2, Transport.WIFI)
        g.onFilesNet(2, FilesNet(FilesNet.STATE_OPEN, 47003, 2, 12))
        assertTrue(g.netOpen)
        assertTrue(g.forgetNet())
        assertFalse(g.netOpen)
        assertFalse(g.forgetNet()) // nothing left to forget
        assertTrue(g.trusted) // the session itself is untouched
    }

    @Test fun anOpenBeforeTheConfigIsKeptAndCountsOnceTrusted() {
        val g = FilesSessionGate()
        g.onConnectionGen(1, Transport.WIFI)
        g.onUi(connected = true)
        assertFalse(g.onFilesNet(1, FilesNet(FilesNet.STATE_OPEN, 1, 1, 1))) // untrusted: no visible change yet
        assertTrue(g.netOpen)
        assertTrue(g.onConfigApplied())
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
            publish = {
                published += it
                events += when (it.state) {
                    FilesInfo.STATE_READY -> "ready:${it.token}"
                    FilesInfo.STATE_STANDBY -> "standby"
                    else -> "off"
                }
            },
            onStatus = { statusCalls++ },
            log = { _, _, _ -> },
        )

        fun sync(
            trusted: Boolean = true, transport: Transport? = Transport.USB, enabled: Boolean = true, foreground: Boolean = true,
            netOpen: Boolean = false,
        ) = lc.sync(enabled, permission = true, foreground = foreground, sessionTrusted = trusted, transport = transport, netOpen = netOpen)
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

    @Test fun neverStartsOnWifiWithoutTheMacOrWhenUntrusted() {
        val r = Rig()
        r.sync(transport = Transport.WIFI) // allowed, not opened: STANDBY, no server
        r.sync(trusted = false)
        r.sync(trusted = false, transport = null)
        assertTrue(r.servers.isEmpty())
        assertEquals(listOf(FilesInfo.STANDBY, FilesInfo.OFF), r.published) // standby once, then off when the session is untrusted
        assertEquals(FilesStatus.NO_USB_SESSION, r.lc.status)
    }

    @Test fun standbyIsPublishedOnceForAnAllowedWifiSessionAndNeverOnUsb() {
        val r = Rig()
        r.sync(trusted = false) // USB, untrusted: nothing, exactly as before
        r.sync(transport = null, trusted = false)
        assertTrue(r.published.isEmpty())
        r.sync(transport = Transport.WIFI)
        r.sync(transport = Transport.WIFI)
        r.sync(transport = Transport.WIFI)
        assertEquals(listOf(FilesInfo.STANDBY), r.published)
        assertEquals(FilesStatus.WIFI_STANDBY, r.lc.status)
        // switch off in the settings (or no permission / background): OFF once
        r.sync(transport = Transport.WIFI, enabled = false)
        r.sync(transport = Transport.WIFI, enabled = false)
        assertEquals(listOf(FilesInfo.STANDBY, FilesInfo.OFF), r.published)
        assertEquals(FilesStatus.DISABLED, r.lc.status)
        // allowed again, then the background ends it
        r.sync(transport = Transport.WIFI)
        r.sync(transport = Transport.WIFI, foreground = false)
        assertEquals(listOf(FilesInfo.STANDBY, FilesInfo.OFF, FilesInfo.STANDBY, FilesInfo.OFF), r.published)
        assertTrue(r.servers.isEmpty())
    }

    @Test fun theMacsOpenStartsAWifiServerAndReadySupersedesStandby() {
        val r = Rig()
        r.sync(transport = Transport.WIFI)
        r.sync(transport = Transport.WIFI, netOpen = true)
        assertEquals(1, r.servers.size)
        assertTrue(r.servers[0].events.wifi)
        assertEquals(FilesStatus.STARTING, r.lc.status)
        assertEquals(listOf(FilesInfo.STANDBY), r.published) // nothing before the socket listens
        r.servers[0].events.onListening(47100)
        assertEquals(FilesInfo(FilesInfo.STATE_READY, 47100, "tok1"), r.published.last())
        assertEquals(FilesStatus.WIFI_READY, r.lc.status)
        r.sync(transport = Transport.WIFI, netOpen = true) // running: nothing new
        assertEquals(1, r.servers.size)
        assertEquals(2, r.published.size)
    }

    @Test fun theMacsCloseStopsTheWifiServerAndGoesBackToStandbyWithoutAnOff() {
        val r = Rig()
        r.sync(transport = Transport.WIFI, netOpen = true)
        r.servers[0].events.onListening(1)
        r.events.clear()
        r.sync(transport = Transport.WIFI, netOpen = false) // FILES_NET(CLOSE)
        assertEquals(listOf("standby", "stop:tok1"), r.events)
        assertTrue(r.servers[0].stopped)
        assertEquals(FilesStatus.WIFI_STANDBY, r.lc.status)
        // a later open starts a new server with a new token, waiting for the old one's workers
        r.sync(transport = Transport.WIFI, netOpen = true)
        assertEquals(2, r.servers.size)
        assertNotEquals(r.servers[0].token, r.servers[1].token)
        assertSame(r.servers[0], r.servers[1].after)
    }

    @Test fun aWifiSessionEndPublishesOffNotStandby() {
        val r = Rig()
        r.sync(transport = Transport.WIFI, netOpen = true)
        r.servers[0].events.onListening(1)
        r.events.clear()
        r.sync(trusted = false, transport = Transport.WIFI)
        assertEquals(listOf("off", "stop:tok1"), r.events)
        assertEquals(FilesStatus.NO_USB_SESSION, r.lc.status)
    }

    @Test fun aUsbServerIsNotAWifiServer() {
        val r = Rig()
        r.sync()
        assertFalse(r.servers[0].events.wifi)
        r.servers[0].events.onListening(5)
        assertEquals(FilesStatus.READY, r.lc.status)
    }

    @Test fun aWifiServerThatFailsReportsOffAndRestartsWhileTheMacStillWantsIt() {
        val r = Rig()
        r.sync(transport = Transport.WIFI, netOpen = true)
        r.servers[0].events.onStopped(failed = true)
        assertEquals(FilesInfo.OFF, r.published.last())
        assertEquals(FilesStatus.FAILED, r.lc.status)
        r.sync(transport = Transport.WIFI, netOpen = true)
        assertEquals(2, r.servers.size)
        assertSame(r.servers[0], r.servers[1].after)
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

    @Test fun switchToWifiStopsWithOffFirstThenStandby() {
        val r = Rig()
        r.sync()
        r.servers[0].events.onListening(1)
        r.events.clear()
        r.sync(transport = Transport.WIFI)
        assertEquals(listOf("off", "stop:tok1", "standby"), r.events) // the USB server is no Wi-Fi server: OFF, then STANDBY
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
