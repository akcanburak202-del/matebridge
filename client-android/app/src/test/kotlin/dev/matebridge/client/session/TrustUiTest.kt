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
            setOf(ConnectOrigin.PAIR, ConnectOrigin.STORED_REPAIR, ConnectOrigin.STORED_CONNECT, ConnectOrigin.TYPED_ADDRESS),
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
        assertEquals(ConnectOrigin.TYPED_ADDRESS, ConnectOrigin.forConnectButton("10.0.0.5:47001", fieldVisible = true))
        assertEquals(ConnectOrigin.CONNECT_BUTTON, ConnectOrigin.forConnectButton("10.0.0.5:47001", fieldVisible = false))
        assertEquals(ConnectOrigin.CONNECT_BUTTON, ConnectOrigin.forConnectButton(" ", fieldVisible = true))
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
        val f = ForgetFlow { calls++; true }
        assertNull(f.confirm()) // nothing open
        f.open(); f.cancel()
        assertNull(f.confirm())
        f.open(); assertNull(f.confirm()); f.cancel()
        assertEquals(ForgetFlow.Step.IDLE, f.step)
        assertEquals(0, calls)
        f.open()
        assertNull(f.confirm())
        assertEquals(ForgetFlow.Step.ASK_SECOND, f.step)
        assertEquals(TrustText.FORGET_DONE, f.confirm())
        assertEquals(1, calls)
        assertEquals(ForgetFlow.Step.IDLE, f.step)
        assertNull(f.confirm())
        assertEquals(1, calls)
    }

    @Test fun forgetWithoutAKnownMacSaysSo() {
        val f = ForgetFlow { false }
        f.open(); f.confirm()
        assertEquals(TrustText.FORGET_NONE, f.confirm())
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

    private fun sources(): Map<String, String> {
        val roots = listOf(File("src/main/kotlin/dev/matebridge/client"), File("app/src/main/kotlin/dev/matebridge/client"))
        val root = roots.first { it.isDirectory }
        return mapOf(
            "MainActivity.kt" to File(root, "MainActivity.kt").readText(),
            "TrustUiText.kt" to File(root, "session/TrustUiText.kt").readText(),
        )
    }
}
