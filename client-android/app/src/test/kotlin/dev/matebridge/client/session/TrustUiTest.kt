package dev.matebridge.client.session

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/** T-151 (decision 0018): the pure trust UI — texts and buttons, connect origins, the pick gate, visibility, forget. */
class TrustUiTest {
    private val impostor = Endpoint("192.168.1.66", 47001)
    private val realMac = Endpoint("192.168.1.106", 47001)

    private fun texts(v: TrustView?) = v!!.lines.map { (it as? TrustLine.Text)?.id }
    private fun code(v: TrustView?) = v!!.lines.filterIsInstance<TrustLine.Code>().single().code

    // ---- state -> text/buttons ----

    @Test fun livePromptShowsTheCodeWithConfirmAndCancel() {
        val v = TrustUiText.view(SessionUi.AwaitingApproval("Mac mini", "123456", needsLocalConfirm = true))
        assertEquals("123456", code(v))
        assertEquals(listOf(TrustButton.CONFIRM, TrustButton.CANCEL), v!!.buttons)
        assertEquals(listOf(TrustText.COMPARE_CODE, null, TrustText.CONFIRM_HINT, TrustText.PARSEC_HINT), texts(v))
    }

    @Test fun knownHostIdWarnsThatTheKeyChanged() {
        val v = TrustUiText.view(SessionUi.AwaitingApproval("Mac mini", "123456", rePairing = true, needsLocalConfirm = true))
        assertEquals(TrustText.KEY_CHANGED, texts(v).first()) // above the code, replacing "Mac bu tableti tanımıyor"
        assertEquals(listOf(TrustButton.CONFIRM, TrustButton.CANCEL), v!!.buttons)
    }

    @Test fun afterTheLocalConfirmOnlyTheMacIsAwaited() {
        val v = TrustUiText.view(SessionUi.AwaitingApproval("Mac mini", "123456", needsLocalConfirm = false))
        assertEquals(TrustText.WAIT_MAC_ALLOW, texts(v).last())
        assertTrue(v!!.buttons.isEmpty())
        assertNull(TrustUiText.view(SessionUi.AwaitingApproval("Mac mini"))) // no code: the plain approval text
    }

    @Test fun pickPromptShowsTheNameAsAClaimWithPairAndIgnore() {
        val v = TrustUiText.view(SessionUi.PairingNeedsUser("Mac mini", rePair = false))!!
        assertEquals(listOf(TrustLine.Text(TrustText.NEW_HOST_CLAIM, "Mac mini")), v.lines)
        assertEquals(listOf(TrustButton.PAIR, TrustButton.IGNORE), v.buttons)
        val re = TrustUiText.view(SessionUi.PairingNeedsUser("Mac mini", rePair = true))!!
        assertEquals(TrustText.RE_PAIR_CLAIM, (re.lines.single() as TrustLine.Text).id)
    }

    @Test fun storedPromptShowsTheStoredCodeOrTheConnectText() {
        val v = TrustUiText.view(SessionUi.StoredTrust("654321", confirmed = false))
        assertEquals("654321", code(v))
        assertEquals(listOf(TrustText.STORED_CODE, null, TrustText.PARSEC_HINT), texts(v))
        assertEquals(listOf(TrustButton.CONFIRM, TrustButton.CANCEL, TrustButton.REPAIR), v!!.buttons)
        val c = TrustUiText.view(SessionUi.StoredTrust(null, confirmed = true))!!
        assertEquals(listOf(TrustLine.Text(TrustText.STORED_CONFIRMED)), c.lines)
        assertEquals(listOf(TrustButton.CONNECT), c.buttons)
    }

    @Test fun cancelledPairingHasItsOwnText() {
        val v = TrustUiText.view(SessionUi.Failed(SessionUi.Cause.PAIR_CANCELLED))!!
        assertEquals(listOf(TrustLine.Text(TrustText.PAIR_CANCELLED)), v.lines)
        assertTrue(v.buttons.isEmpty())
        assertNull(TrustUiText.view(SessionUi.Failed(SessionUi.Cause.REJECTED)))
    }

    @Test fun otherStatesKeepTheirUsualText() {
        for (s in listOf(
            SessionUi.Idle, SessionUi.Searching, SessionUi.Connecting(realMac), SessionUi.Connected("m", 3),
            SessionUi.Disconnected(SessionUi.Cause.LOST, 1000),
        )) assertNull(TrustUiText.view(s))
    }

    @Test fun pendingPickIsABannerExceptOverAStream() {
        val p = PairPrompt(impostor, "Evil", rePair = false)
        assertEquals(TrustUiText.pickView(p), TrustUiText.screen(SessionUi.Connecting(realMac), p))
        assertEquals(TrustUiText.pickView(p), TrustUiText.screen(SessionUi.Searching, p))
        assertNull(TrustUiText.screen(SessionUi.Connected("m", 0), p))
        val stored = SessionUi.StoredTrust("111222", false)
        assertEquals(TrustUiText.view(stored), TrustUiText.screen(stored, p)) // the state's own prompt wins
    }

    @Test fun claimedNameCannotFakeTheSurroundingText() {
        assertEquals("Mac mini", TrustUiText.claimName("  Mac\n\tmini "))
        assertEquals("evil", TrustUiText.claimName("‮evil‏"))
        assertEquals("?", TrustUiText.claimName("\u0000\n"))
        val long = TrustUiText.claimName("x".repeat(100))
        assertEquals(TrustUiText.CLAIM_MAX + 1, long.length)
        assertTrue(long.endsWith("…"))
        assertEquals("a\uD835\uDC00b", TrustUiText.claimName("a\uD835\uDC00b")) // a supplementary code point stays whole
    }

    @Test fun codeIsHiddenFromToString() {
        assertFalse(TrustLine.Code("123456").toString().contains("123456"))
        assertFalse(TrustUiText.view(SessionUi.StoredTrust("123456", false)).toString().contains("123456"))
    }

    @Test fun usbHintNeverReplacesAPrompt() {
        for (s in listOf(
            SessionUi.PairingNeedsUser("m", false), SessionUi.StoredTrust("123456", false), SessionUi.StoredTrust(null, true),
            SessionUi.AwaitingApproval("m", "123456", needsLocalConfirm = true), SessionUi.Connected("m", 0),
            SessionUi.Failed(SessionUi.Cause.PAIR_CANCELLED),
        )) assertTrue(s.toString(), TrustUiText.hostReached(s))
        for (s in listOf(SessionUi.Idle, SessionUi.Searching, SessionUi.Connecting(realMac), SessionUi.Disconnected(SessionUi.Cause.LOST, 0))) {
            assertFalse(TrustUiText.hostReached(s))
        }
    }

    // ---- connect origins ----

    @Test fun onlyTapsThatChoseThisPairingAreUserInitiated() {
        assertEquals(
            setOf(
                ConnectOrigin.PAIR, ConnectOrigin.STORED_REPAIR, ConnectOrigin.STORED_CONNECT, ConnectOrigin.TYPED_ADDRESS,
                ConnectOrigin.CONNECT_AFTER_CANCEL, ConnectOrigin.CONNECT_AFTER_MISMATCH,
            ),
            ConnectOrigin.entries.filter { it.userInitiated }.toSet(),
        )
        for (o in listOf(ConnectOrigin.DISCOVERY, ConnectOrigin.SAVED_WIFI, ConnectOrigin.USB_MODE, ConnectOrigin.AUTO_SWITCH, ConnectOrigin.WAKE)) {
            assertFalse(o.userInitiated)
            assertTrue(o.automatic) // and they skip an endpoint that already answered PAIRING
        }
        assertFalse(ConnectOrigin.CONNECT_BUTTON.userInitiated)
        assertFalse(ConnectOrigin.CONNECT_BUTTON.automatic)
        assertTrue(ConnectOrigin.CONNECT_BUTTON.clearsGate)
        assertTrue(ConnectOrigin.TYPED_ADDRESS.clearsGate)
        assertTrue(ConnectOrigin.entries.none { it.userInitiated && it.automatic })
    }

    @Test fun connectButtonPairsOnlyWithAnAddressTypedIntoTheOpenField() {
        val s = SessionUi.Disconnected(SessionUi.Cause.LOST, 1000)
        assertEquals(ConnectOrigin.TYPED_ADDRESS, ConnectOrigin.forConnectButton("10.0.0.5:47001", fieldVisible = true, s))
        assertEquals(ConnectOrigin.CONNECT_BUTTON, ConnectOrigin.forConnectButton("10.0.0.5:47001", fieldVisible = false, s))
        assertEquals(ConnectOrigin.CONNECT_BUTTON, ConnectOrigin.forConnectButton(" ", fieldVisible = true, s))
        assertEquals(ConnectOrigin.CONNECT_BUTTON, ConnectOrigin.forConnectButton("", false, SessionUi.Failed(SessionUi.Cause.REJECTED)))
    }

    @Test fun connectAfterACancelReleasesTheLatch() { // T-150 latch: only a user start reconnects after "İptal"
        val o = ConnectOrigin.forConnectButton("", fieldVisible = false, SessionUi.Failed(SessionUi.Cause.PAIR_CANCELLED))
        assertEquals(ConnectOrigin.CONNECT_AFTER_CANCEL, o)
        assertTrue(o.userInitiated)
        assertFalse(o.automatic)
        assertTrue(o.clearsGate)
        // a typed address stays a typed address
        assertEquals(ConnectOrigin.TYPED_ADDRESS, ConnectOrigin.forConnectButton("10.0.0.5:47001", true, SessionUi.Failed(SessionUi.Cause.PAIR_CANCELLED)))
    }

    @Test fun tapsCarryTheGenerationOfTheRenderedPrompt() {
        assertEquals(7, TrustUiText.promptGen(SessionUi.AwaitingApproval("m", "123456", needsLocalConfirm = true, promptGen = 7)))
        assertEquals(9, TrustUiText.promptGen(SessionUi.StoredTrust("123456", confirmed = false, promptGen = 9)))
        assertEquals(-1, TrustUiText.promptGen(SessionUi.PairingNeedsUser("m", false)))
        assertEquals(-1, TrustUiText.promptGen(SessionUi.Connected("m", 0)))
    }

    // ---- the pick gate (QA-1 T-151 #1) ----

    @Test fun pairGoesToTheEndpointThatAnswered() {
        val g = PairPick()
        g.onUi(SessionUi.Connecting(impostor))
        g.onUi(SessionUi.Connecting(realMac)) // a later start replaced it before any answer
        assertTrue(g.onUi(SessionUi.PairingNeedsUser("Mac", rePair = true)))
        assertEquals(PairPrompt(realMac, "Mac", true), g.prompt)
        assertFalse(g.allowsAuto(realMac))
        val p = g.pair()!!
        assertEquals(realMac, p.endpoint) // "Eşleş" -> start(realMac, userInitiated = true)
        assertTrue(ConnectOrigin.PAIR.userInitiated)
        assertTrue(g.allowsAuto(realMac))
        assertNull(g.prompt)
    }

    @Test fun anImpostorCannotParkTheTablet() {
        val g = PairPick()
        val w = WakeConnect()
        // Discovery found both; the impostor was tried first and the real Mac's report was ignored while it connected.
        g.onDiscovered(realMac)
        g.onDiscovered(impostor)
        g.onUi(SessionUi.Connecting(impostor))
        assertFalse(w.onDiscovered(impostor, disconnected = false)) // busy connecting: the real Mac is not tried yet
        assertTrue(g.onUi(SessionUi.PairingNeedsUser("Mac mini", rePair = false)))
        // The prompt counts as asked: no automatic connect goes back to the impostor ...
        assertFalse(g.allowsAuto(impostor))
        // ... while the remembered real Mac is tried at once (NSD reported it only once) ...
        assertEquals(realMac, g.nextAuto())
        // ... and a newly discovered one may replace the prompt's (connection-less) session.
        assertTrue(w.onDiscovered(impostor, disconnected = false, atPairPrompt = true))
        g.onUi(SessionUi.Connecting(realMac))
        assertNotNull(g.prompt) // still shown as a banner meanwhile
        assertEquals(TrustUiText.pickView(g.prompt!!), TrustUiText.screen(SessionUi.Connecting(realMac), g.prompt))
        g.onUi(SessionUi.Connected("Mac mini", 0)) // PAIRED with the trusted key: silent, replaces the prompt
        assertNull(g.prompt)
        assertFalse(g.allowsAuto(impostor)) // never again on its own
        assertNull(g.nextAuto(except = realMac))
    }

    @Test fun ignoreDismissesAndKeepsTheEndpointOutUntilAUserStart() {
        val g = PairPick()
        g.onUi(SessionUi.Connecting(ConnectMode.usbEndpoint))
        g.onUi(SessionUi.PairingNeedsUser("Mac", rePair = false))
        assertTrue(g.isAsked(ConnectMode.usbEndpoint)) // AUTO: no probe switch / migration back to it
        assertNotNull(g.ignore())
        assertNull(g.prompt)
        assertFalse(g.allowsAuto(ConnectMode.usbEndpoint))
        g.onDiscovered(ConnectMode.usbEndpoint)
        assertNull(g.nextAuto())
        g.onUserStart() // "Bağlan" or a typed address
        assertTrue(g.allowsAuto(ConnectMode.usbEndpoint))
    }

    @Test fun ignoreBringsBackTheOrdinaryScreenAndKeepsTheEndpointSkipped() { // Codex P2: ignore -> render -> buttons
        val g = PairPick()
        g.onDiscovered(impostor)
        g.onUi(SessionUi.Connecting(impostor))
        val pick = SessionUi.PairingNeedsUser("Mac mini", rePair = false)
        g.onUi(pick)
        assertEquals(listOf(TrustButton.PAIR, TrustButton.IGNORE), TrustUiText.screen(pick, g.prompt)!!.buttons)
        g.ignore()
        // Even before the new state renders, a dismissed pick shows no (dead) buttons: "Bağlan" is not hidden.
        assertNull(TrustUiText.screen(pick, g.prompt))
        for (running in listOf(true, false)) {
            val next = TrustUiText.afterIgnore(discoveryRunning = running)
            assertEquals(if (running) SessionUi.Searching else SessionUi.Idle, next)
            g.onUi(next)
            assertNull(TrustUiText.screen(next, g.prompt)) // ordinary text, no trust row
            assertTrue(TrustUiText.screen(next, g.prompt)?.buttons.orEmpty().isEmpty())
        }
        assertFalse(g.allowsAuto(impostor)) // still skipped by discovery, wake, the saved endpoint and AUTO
        assertNull(g.nextAuto())
        // With the endpoint dropped by the UI, another discovered Mac connects (nothing is chosen any more).
        assertTrue(WakeConnect().onDiscovered(current = null, disconnected = false))
        g.onUserStart() // "Bağlan"
        assertTrue(g.allowsAuto(impostor))
    }

    @Test fun anUnattributablePickShowsNoButtons() {
        val g = PairPick()
        val pick = SessionUi.PairingNeedsUser("m", false)
        assertFalse(g.onUi(pick)) // no Connecting seen: no endpoint for "Eşleş"
        assertNull(TrustUiText.screen(pick, g.prompt))
    }

    @Test fun promptGoesWhenTheSessionGetsFurther() {
        for (s in listOf(SessionUi.Connected("m", 0), SessionUi.AwaitingApproval("m", "1", needsLocalConfirm = true), SessionUi.StoredTrust("1", false))) {
            val g = PairPick()
            g.onUi(SessionUi.Connecting(impostor))
            g.onUi(SessionUi.PairingNeedsUser("m", false))
            g.onUi(SessionUi.Disconnected(SessionUi.Cause.LOST, 1000))
            g.onUi(SessionUi.Searching)
            assertNotNull(g.prompt)
            g.onUi(s)
            assertNull(s.toString(), g.prompt)
        }
        val g = PairPick()
        assertFalse(g.onUi(SessionUi.PairingNeedsUser("m", false))) // no known endpoint: nothing to attribute
        assertNull(g.prompt)
    }

    @Test fun gateMemoryIsBounded() {
        val g = PairPick(maxAsked = 2, maxSeen = 2)
        for (i in 1..3) {
            g.onUi(SessionUi.Connecting(Endpoint("10.0.0.$i", 47001)))
            g.onUi(SessionUi.PairingNeedsUser("m", false))
            g.onDiscovered(Endpoint("10.0.1.$i", 47001))
        }
        assertTrue(g.allowsAuto(Endpoint("10.0.0.1", 47001))) // the oldest left the bounded set
        assertFalse(g.allowsAuto(Endpoint("10.0.0.3", 47001)))
        assertEquals(Endpoint("10.0.1.3", 47001), g.nextAuto())
        g.clearSeen()
        assertNull(g.nextAuto())
    }

    @Test fun storedPromptBlocksAutomaticConnects() {
        // While StoredTrust is shown nothing automatic opens a connection: no AUTO step, no discovery replacement.
        val s = SessionUi.StoredTrust("123456", confirmed = false)
        assertEquals(AutoUsbPolicy.Step.NONE, AutoUsbPolicy().next(false, AutoUsbPolicy.stageOf(s), 0))
        assertFalse(WakeConnect().onDiscovered(realMac, disconnected = false, atPairPrompt = s is SessionUi.PairingNeedsUser))
    }

    // ---- prompt visibility ----

    @Test fun promptVisibilityIsPostedOnChangeOnly() {
        val v = PromptVisibility()
        assertNull(v.onRender(SessionUi.Searching, started = true))
        assertEquals(true, v.onRender(SessionUi.AwaitingApproval("m", "1", needsLocalConfirm = true), started = true))
        assertNull(v.onRender(SessionUi.AwaitingApproval("m", "1", needsLocalConfirm = true), started = true))
        assertEquals(false, v.onRender(SessionUi.AwaitingApproval("m", "1", needsLocalConfirm = false), started = true))
        assertEquals(true, v.onRender(SessionUi.StoredTrust("1", false), started = true))
        assertNull(v.onRender(SessionUi.StoredTrust(null, true), started = true)) // another prompt: still visible
        assertEquals(false, v.onStop())
        assertNull(v.onStop())
        assertNull(v.onRender(SessionUi.StoredTrust("1", false), started = false))
        assertEquals(true, v.onRender(SessionUi.StoredTrust("1", false), started = true))
        assertEquals(false, v.onRender(SessionUi.Connected("m", 0), started = true)) // replaced
        assertFalse(PromptVisibility.isConfirmPrompt(SessionUi.PairingNeedsUser("m", false)))
    }

    // ---- "Bu Mac'i unut" ----

    @Test fun forgetRunsOnlyAfterTwoConfirmations() {
        var calls = 0
        val f = ForgetFlow({ calls++; true })
        assertNull(f.confirm(0)) // nothing open
        f.open(); f.cancel()
        assertNull(f.confirm(0))
        f.open(); assertNull(f.confirm(0)); f.cancel()
        assertEquals(ForgetFlow.Step.IDLE, f.step)
        assertEquals(0, calls)
        f.open()
        assertNull(f.confirm(0))
        assertEquals(ForgetFlow.Step.ASK_SECOND, f.step)
        assertNull(f.confirm(0)) // queued only: no text yet
        assertEquals(1, calls)
        assertEquals(ForgetFlow.Step.WAITING, f.step)
        assertNull(f.confirm(0))
        f.open(); f.cancel() // a waiting request is not reopened or dropped by the dialog
        assertEquals(ForgetFlow.Step.WAITING, f.step)
        assertEquals(1, calls)
    }

    @Test fun forgetIsDoneOnlyWhenTheResultingStateArrives() {
        val f = ForgetFlow({ true })
        f.open(); f.confirm(0); f.confirm(0)
        assertNull(f.onUi(SessionUi.Connected("m", 5), 10)) // not a result
        assertNull(f.onTick(ForgetFlow.SETTLE_MS - 1))
        assertEquals(TrustText.FORGET_DONE, f.onUi(SessionUi.Idle, 20)) // a live session ended and the records went
        assertEquals(ForgetFlow.Step.IDLE, f.step)
        assertNull(f.onTick(ForgetFlow.SETTLE_MS * 2))
        assertNull(f.onUi(SessionUi.Idle, 30))
    }

    @Test fun forgetFailureShowsTheFailureAndTheRowStaysUsable() {
        var calls = 0
        val f = ForgetFlow({ calls++; true })
        f.open(); f.confirm(0); f.confirm(0)
        assertEquals(TrustText.FORGET_FAILED, f.onUi(SessionUi.Failed(SessionUi.Cause.KEY_STORE_FAILED), 50))
        assertEquals(ForgetFlow.Step.IDLE, f.step)
        f.open(); f.confirm(100); f.confirm(100) // retry: the Mac is still forgettable
        assertEquals(2, calls)
        assertEquals(ForgetFlow.Step.WAITING, f.step)
    }

    @Test fun anIdleMachineSucceedsSilentlyButALateFailureStillCounts() {
        val f = ForgetFlow({ true }, settleMs = 1_000, lateMs = 5_000)
        f.open(); f.confirm(0); f.confirm(0)
        assertNull(f.onTick(999))
        assertEquals(TrustText.FORGET_DONE, f.onTick(1_000)) // no state on success when already idle
        assertEquals(TrustText.FORGET_FAILED, f.onUi(SessionUi.Failed(SessionUi.Cause.KEY_STORE_FAILED), 3_000))
        assertNull(f.onUi(SessionUi.Failed(SessionUi.Cause.KEY_STORE_FAILED), 3_100)) // once
        // after the late window a KEY_STORE_FAILED is someone else's (e.g. a pairing confirm)
        val g = ForgetFlow({ true }, settleMs = 1_000, lateMs = 5_000)
        g.open(); g.confirm(0); g.confirm(0); g.onTick(1_000)
        assertNull(g.onUi(SessionUi.Failed(SessionUi.Cause.KEY_STORE_FAILED), 6_001))
        // and without any request it is never a forget result
        assertNull(ForgetFlow({ true }).onUi(SessionUi.Failed(SessionUi.Cause.KEY_STORE_FAILED), 0))
    }

    @Test fun forgetStoppedBeforeTheResultReportsNothing() {
        val f = ForgetFlow({ true })
        f.open(); f.confirm(0); f.confirm(0)
        f.abandon()
        assertEquals(ForgetFlow.Step.IDLE, f.step)
        assertNull(f.onUi(SessionUi.Idle, 10))
        assertNull(f.onTick(ForgetFlow.SETTLE_MS * 2))
    }

    @Test fun forgetWithoutAKnownMacSaysSo() {
        val f = ForgetFlow({ false })
        f.open(); f.confirm(0)
        assertEquals(TrustText.FORGET_NONE, f.confirm(0))
        assertEquals(ForgetFlow.Step.IDLE, f.step)
    }

    // ---- logs: the action only, never a value ----

    @Test fun pairUiLogCarriesNoValue() {
        assertEquals("action=confirm", TrustUiText.pairUiFields(TrustButton.CONFIRM.logAction))
        for (b in TrustButton.entries) assertTrue(b.logAction.matches(Regex("[a-z_]+")))
        val src = sources()
        assertFalse("TrustUiText must not log", src.getValue("TrustUiText.kt").contains("MbLog"))
        val main = src.getValue("MainActivity.kt")
        val lines = main.lines().filter { it.contains("\"pair_ui\"") || it.contains("\"pair_auto_skip\"") }
        assertTrue(lines.size >= 3)
        for (l in lines) {
            assertTrue(l, l.contains("TrustUiText.pairUiFields(") || l.contains("\"origin=\${origin.logName}\""))
        }
        // No log call in MainActivity passes a code, a pairing prompt or a claimed name.
        for (l in main.lines().filter { it.contains("MbLog.") }) {
            for (bad in listOf(".code", "hostName", "claimName", "prompt", "TrustLine")) assertFalse(l, l.contains(bad))
        }
    }

    // ---- T-207: the asked mark after the Mac is trusted ----

    private val usb = ConnectMode.usbEndpoint
    private val macId = HostTag.of(ByteArray(16) { (0x40 + it).toByte() })!!
    private val otherId = HostTag.of(ByteArray(16) { 0x77 })!!

    private fun PairPick.asked(ep: Endpoint, claimed: HostTag?) {
        onUi(SessionUi.Connecting(ep))
        assertTrue(onUi(SessionUi.PairingNeedsUser("Mac mini", rePair = true, claimed)))
    }

    @Test fun aProvenSessionClearsOnlyTheEndpointsThatClaimedThatMac() {
        val g = PairPick()
        g.asked(usb, macId) // AUTO: the USB tunnel asked while the Mac had forgotten the tablet
        g.asked(impostor, otherId) // another host_id
        g.asked(Endpoint("192.168.1.7", 47001), null) // no identity known
        g.asked(realMac, macId) // the Wi-Fi prompt the user pairs on
        assertEquals(realMac, g.pair()!!.endpoint)
        g.onUi(SessionUi.Connecting(realMac))
        g.onUi(SessionUi.AwaitingApproval("Mac mini", "123456", rePairing = true, needsLocalConfirm = true))
        assertTrue(g.takeCleared().isEmpty()) // a code on screen proves nothing
        g.onUi(SessionUi.Connected("Mac mini", 0)) // plaintext PAIRED ack: not proven yet
        assertTrue(g.takeCleared().isEmpty())
        assertTrue(g.isAsked(usb))
        g.onUi(SessionUi.Connected("Mac mini", 0, macId)) // proven: trusted key / locally confirmed and accepted
        assertEquals(listOf(usb), g.takeCleared())
        assertTrue(g.takeCleared().isEmpty()) // taken once
        assertTrue(g.allowsAuto(usb))
        assertFalse(g.allowsAuto(impostor)) // decision 0018: another Mac stays out of automatic connects
        assertFalse(g.allowsAuto(Endpoint("192.168.1.7", 47001)))
        assertEquals("count=1 usb=1", TrustUiText.askedClearedFields(listOf(usb)))
        assertEquals("count=2 usb=0", TrustUiText.askedClearedFields(listOf(realMac, impostor)))
    }

    @Test fun clearingRunsOncePerProvenSession() {
        val g = PairPick()
        g.asked(usb, macId)
        g.onUi(SessionUi.Connected("Mac mini", 0, macId))
        assertEquals(listOf(usb), g.takeCleared())
        // Frame updates of the same session clear nothing more.
        g.onUi(SessionUi.Connected("Mac mini", 5, macId))
        g.onUi(SessionUi.Connected("Mac mini", 9, macId))
        assertTrue(g.takeCleared().isEmpty())
        // It asks again (e.g. an impostor copying the host_id, after the session dropped): marked again, and only the
        // next proven session clears it (bounded: one automatic try per session that the Mac proves).
        g.onUi(SessionUi.Disconnected(SessionUi.Cause.LOST, 1000))
        g.asked(usb, macId)
        assertTrue(g.isAsked(usb))
        g.onUi(SessionUi.Searching)
        assertTrue(g.takeCleared().isEmpty())
        g.onUi(SessionUi.Connected("Mac mini", 0, macId))
        assertEquals(listOf(usb), g.takeCleared())
    }

    @Test fun anotherMacsSessionDoesNotClearTheMark() {
        val g = PairPick()
        g.asked(usb, macId)
        g.onUi(SessionUi.Connected("Other", 0, otherId))
        assertTrue(g.isAsked(usb))
        assertTrue(g.takeCleared().isEmpty())
        assertEquals("HostTag", macId.toString()) // a logged UI state never carries the host_id
        assertNull(HostTag.of(ByteArray(16)))
        assertNull(HostTag.of(null))
    }

    @Test fun askedClearedLogCarriesNoValue() {
        val main = sources().getValue("MainActivity.kt")
        val lines = main.lines().filter { it.contains("\"pair_asked_cleared\"") }
        assertEquals(1, lines.size)
        assertTrue(lines.single(), lines.single().contains("TrustUiText.askedClearedFields("))
    }

    private fun sources(): Map<String, String> {
        val roots = listOf(File("src/main/kotlin/dev/matebridge/client"), File("app/src/main/kotlin/dev/matebridge/client"))
        val root = roots.first { it.isDirectory }
        return mapOf(
            "MainActivity.kt" to File(root, "MainActivity.kt").readText(),
            "TrustUiText.kt" to File(root, "session/TrustUiText.kt").readText(),
        )
    }
}
