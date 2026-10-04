package dev.matebridge.client.idle

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** T-234 (decision 0031): idle stages, the counter rules and the first-input swallow rules. */
class IdleDimPolicyTest {
    /** The binding layer's view: brightness and FLAG_KEEP_SCREEN_ON as the window would hold them. */
    class FakeWindow : IdleWindow {
        var dark = false
        var keepOn = true
        val calls = ArrayList<String>()
        override fun setDimmed(dimmed: Boolean) { dark = dimmed; calls += "dim=$dimmed" }
        override fun setKeepScreenOn(on: Boolean) { keepOn = on; calls += "keep=$on" }
    }

    private val win = FakeWindow()
    private val logs = ArrayList<String>()
    private val p = IdleDimPolicy(win, 0, IdleTimeout.MIN_2) { logs += it }

    private val touch = IdleChannel.of(IdleChannel.TOUCH, 2)
    private val pen = IdleChannel.of(IdleChannel.PEN, 1)
    private val keyA = IdleChannel.of(IdleChannel.KEY, 7, 30)
    private val keyB = IdleChannel.of(IdleChannel.KEY, 7, 48)
    private val mouse = IdleChannel.of(IdleChannel.MOUSE, 9)

    private val twoMin = 120_000L

    /** Ticks every 25 ms like the input ticker, from [from] to [to] inclusive. */
    private fun run(from: Long, to: Long) {
        var t = from
        while (t <= to) { p.tick(t); t += 25 }
    }

    private fun dimAt(t: Long = twoMin) { p.tick(t); assertEquals(IdleStage.DIM, p.stage) }

    // touch helpers: engaged = pressed = any finger still down after the event
    private fun tDown(t: Long, fresh: Boolean = true) = p.admit(touch, IdleSource.TOUCH, true, true, false, t, fresh)
    private fun tMove(t: Long) = p.admit(touch, IdleSource.TOUCH, true, true, false, t)
    private fun tUp(t: Long, othersDown: Boolean = false) = p.admit(touch, IdleSource.TOUCH, othersDown, othersDown, true, t)
    private fun hover(t: Long) = p.admit(pen, IdleSource.PEN, true, false, false, t)
    private fun hoverExit(t: Long) = p.admit(pen, IdleSource.PEN, true, false, true, t)
    private fun penDown(t: Long) = p.admit(pen, IdleSource.PEN, true, true, false, t)
    private fun penUp(t: Long) = p.admit(pen, IdleSource.PEN, false, false, true, t)
    private fun key(ch: Long, down: Boolean, t: Long, repeat: Boolean = false) =
        p.admit(ch, IdleSource.KEY, down, down, !down, t, fresh = down && !repeat)

    // ---- stages and the counter ----

    @Test fun dimsWhenTheTimeoutPassesThenDropsTheFlagOneMinuteLater() {
        run(0, twoMin - 25)
        assertEquals(IdleStage.ACTIVE, p.stage)
        p.tick(twoMin)
        assertEquals(IdleStage.DIM, p.stage)
        assertTrue(win.dark); assertTrue(win.keepOn)
        run(twoMin, twoMin + IdleDimPolicy.OFF_AFTER_MS - 25)
        assertEquals(IdleStage.DIM, p.stage)
        p.tick(twoMin + IdleDimPolicy.OFF_AFTER_MS)
        assertEquals(IdleStage.OFF, p.stage)
        assertTrue(win.dark); assertFalse(win.keepOn)
        assertEquals(listOf("stage=dim reason=timeout idle_ms=120000", "stage=off reason=timeout"), logs)
    }

    @Test fun defaultIsFiveMinutes() {
        val q = IdleDimPolicy(FakeWindow(), 0)
        assertEquals(IdleTimeout.MIN_5, q.timeout)
        q.tick(5 * 60_000L - 1); assertEquals(IdleStage.ACTIVE, q.stage)
        q.tick(5 * 60_000L); assertEquals(IdleStage.DIM, q.stage)
    }

    @Test fun inputRestartsTheCounter() {
        p.onInput(IdleSource.UI, 100_000)
        p.tick(twoMin); assertEquals(IdleStage.ACTIVE, p.stage)
        p.tick(100_000 + twoMin); assertEquals(IdleStage.DIM, p.stage)
    }

    @Test fun theCounterStandsStillWhileSomethingIsHeld() {
        assertTrue(tDown(1_000)) // a finger on the glass, sent to the Mac
        run(1_000, 10 * 60_000L)
        assertEquals(IdleStage.ACTIVE, p.stage)
        assertTrue(tUp(10 * 60_000L))
        p.tick(10 * 60_000L + twoMin - 25); assertEquals(IdleStage.ACTIVE, p.stage)
        p.tick(10 * 60_000L + twoMin); assertEquals(IdleStage.DIM, p.stage) // counted from the release
    }

    @Test fun aHeldKeyAndAPenContactStopTheCounterButHoverDoesNot() {
        assertTrue(key(keyA, true, 0))
        run(0, 5 * 60_000L); assertEquals(IdleStage.ACTIVE, p.stage)
        assertTrue(key(keyA, false, 5 * 60_000L))
        assertTrue(penDown(5 * 60_000L))
        run(5 * 60_000L, 10 * 60_000L); assertEquals(IdleStage.ACTIVE, p.stage)
        assertTrue(penUp(10 * 60_000L))
        assertTrue(hover(10 * 60_000L)) // in range, not pressed
        p.tick(10 * 60_000L + twoMin); assertEquals(IdleStage.DIM, p.stage)
    }

    @Test fun noStagesInGameMode() {
        p.setGameMode(true, 0)
        run(0, 30 * 60_000L)
        assertEquals(IdleStage.ACTIVE, p.stage)
        assertTrue(win.calls.isEmpty())
        // and no swallowing either: the first touch goes to the Mac
        assertTrue(tDown(30 * 60_000L))
    }

    @Test fun enteringGameModeWhileDimmedRestoresAndLeavingItRestartsTheCounter() {
        dimAt()
        p.setGameMode(true, 130_000)
        assertEquals(IdleStage.ACTIVE, p.stage)
        assertFalse(win.dark); assertTrue(win.keepOn)
        assertTrue(logs.any { it.startsWith("stage=wake reason=game swallowed=0") })
        p.setGameMode(false, 200_000)
        p.tick(200_000 + twoMin - 1); assertEquals(IdleStage.ACTIVE, p.stage)
        p.tick(200_000 + twoMin); assertEquals(IdleStage.DIM, p.stage)
    }

    @Test fun noStagesWithTheSettingOff() {
        p.setTimeout(IdleTimeout.OFF, 0)
        run(0, 60 * 60_000L)
        assertEquals(IdleStage.ACTIVE, p.stage)
        assertFalse(p.enabled)
        assertTrue(tDown(60 * 60_000L))
    }

    @Test fun aSettingChangeRestartsTheCounterAndBringsADimmedWindowBack() {
        p.tick(100_000)
        p.setTimeout(IdleTimeout.MIN_5, 100_000)
        p.tick(100_000 + twoMin); assertEquals(IdleStage.ACTIVE, p.stage)
        p.tick(100_000 + 5 * 60_000L); assertEquals(IdleStage.DIM, p.stage)
        p.setTimeout(IdleTimeout.MIN_10, 500_000)
        assertEquals(IdleStage.ACTIVE, p.stage)
        assertFalse(win.dark)
        assertTrue(logs.contains("stage=config reason=setting timeout_min=10 game=0"))
        p.tick(500_000 + 10 * 60_000L - 1); assertEquals(IdleStage.ACTIVE, p.stage)
    }

    @Test fun wakeFromOffBringsBackTheFlagAndBrightnessAndRestartsTheCounter() {
        dimAt()
        p.tick(twoMin + IdleDimPolicy.OFF_AFTER_MS)
        assertFalse(win.keepOn)
        assertFalse(tDown(200_000))
        assertEquals(IdleStage.ACTIVE, p.stage)
        assertTrue(win.keepOn); assertFalse(win.dark)
        assertFalse(tUp(200_100))
        p.tick(200_100 + twoMin - 25); assertEquals(IdleStage.ACTIVE, p.stage)
        p.tick(200_100 + twoMin); assertEquals(IdleStage.DIM, p.stage)
    }

    @Test fun restartOnStartRestoresTheWindowWhateverTheStage() {
        dimAt()
        p.tick(twoMin + IdleDimPolicy.OFF_AFTER_MS)
        p.restart(400_000)
        assertEquals(IdleStage.ACTIVE, p.stage)
        assertTrue(win.keepOn); assertFalse(win.dark)
        assertTrue(logs.last().startsWith("stage=wake reason=start swallowed=0"))
        p.tick(400_000 + twoMin - 1); assertEquals(IdleStage.ACTIVE, p.stage)
    }

    // ---- swallowing ----

    @Test fun aWholeTouchWhileDimmedIsSwallowedDownToTheLastFingerUp() {
        dimAt()
        assertFalse(tDown(130_000))
        assertFalse(win.dark) // woke at once
        assertFalse(tMove(130_010))
        assertFalse(tDown(130_020, fresh = false)) // a second finger joins
        assertFalse(tUp(130_030, othersDown = true)) // one finger leaves, one stays
        assertFalse(tMove(130_040))
        assertFalse(tUp(130_050)) // the last finger
        assertEquals("stage=wake reason=touch swallowed=6 held_ms=50", logs.last())
        // the next touch is an ordinary one
        assertTrue(tDown(131_000))
        assertTrue(tUp(131_100))
    }

    @Test fun aPenTapWhileDimmedIsSwallowedFromHoverToLift() {
        dimAt()
        assertFalse(hover(130_000))
        assertFalse(hover(130_010))
        assertFalse(hoverExit(130_020)) // Android: HOVER_EXIT right before the tip's DOWN
        assertFalse(penDown(130_025))
        assertFalse(penDown(130_030)) // MOVE in contact
        assertFalse(penUp(130_060))
        assertTrue(logs.last().startsWith("stage=wake reason=pen swallowed=6"))
        assertTrue(hover(130_070)) // after the lift: ordinary
        assertTrue(penDown(130_100))
        assertTrue(penUp(130_200))
    }

    @Test fun aSwallowedHoverEndsOnceThePenHasLeftRange() {
        dimAt()
        assertFalse(hover(130_000))
        assertFalse(hoverExit(130_010))
        assertTrue(p.swallowingAny)
        p.tick(130_010 + IdleDimPolicy.LINGER_MS)
        assertFalse(p.swallowingAny)
        assertTrue(penDown(133_000)) // a later stroke draws
    }

    @Test fun aPalmPutDownWhileTheWakingPenIsSwallowedIsSwallowedToo() {
        dimAt()
        assertFalse(hover(130_000))
        assertFalse(tDown(130_010)) // palm: the finger gate never saw the swallowed pen
        assertFalse(penDown(130_020))
        assertFalse(penUp(130_200))
        assertFalse(tMove(130_210)) // the palm's motion stays swallowed to its end
        assertTrue(hover(130_220))
        assertFalse(tUp(130_300))
        assertTrue(tDown(131_000))
    }

    @Test fun aPalmThatWokeTheWindowDoesNotKeepThePenFromDrawing() {
        dimAt()
        assertFalse(tDown(130_000)) // palm first
        assertTrue(hover(130_100))
        assertTrue(penDown(130_200))
        assertTrue(penUp(130_300))
        assertFalse(tMove(130_310))
        assertFalse(tUp(130_400))
    }

    @Test fun aKeyWhileDimmedIsSwallowedDownRepeatsAndUp() {
        dimAt()
        assertFalse(key(keyA, true, 130_000))
        assertFalse(key(keyA, true, 130_500, repeat = true))
        assertTrue(key(keyB, true, 130_600)) // another key is its own motion
        assertTrue(key(keyB, false, 130_700))
        assertFalse(key(keyA, false, 131_000))
        assertTrue(logs.last().startsWith("stage=wake reason=key swallowed=3"))
        assertTrue(key(keyA, true, 132_000))
        assertTrue(key(keyA, false, 132_100))
    }

    @Test fun aReleaseWhosePressWentOutIsNeverSwallowedEvenWhileDimmed() {
        // The counter cannot reach the dim stage under a held key; this is the rule behind it for a press the gate missed.
        dimAt()
        assertTrue(key(keyA, false, 130_000)) // a release with no swallowed press: passes (and wakes)
        assertEquals(IdleStage.ACTIVE, p.stage)
        assertTrue(logs.last().startsWith("stage=wake reason=key swallowed=0"))
    }

    @Test fun aHeldKeyKeepsTheWindowAwakeAndItsRepeatsAndUpPass() {
        assertTrue(penDown(0))
        assertTrue(penUp(10))
        assertTrue(key(keyA, true, 20)) // held: the counter stands still
        run(20, 10 * 60_000L)
        assertEquals(IdleStage.ACTIVE, p.stage)
        assertTrue(key(keyA, true, 10 * 60_000L, repeat = true))
        assertTrue(key(keyA, false, 10 * 60_000L + 10))
    }

    @Test fun aMouseMoveWakesAndIsTheOnlyEventSwallowed() {
        dimAt()
        assertFalse(p.admit(mouse, IdleSource.MOUSE, false, false, false, 130_000))
        assertEquals("stage=wake reason=mouse swallowed=1 held_ms=0", logs.last())
        assertTrue(p.admit(mouse, IdleSource.MOUSE, false, false, false, 130_010))
    }

    @Test fun inputThatDoesNotGoToTheMacWakesWithoutSwallowing() {
        dimAt()
        assertTrue(p.onInput(IdleSource.UI, 130_000))
        assertEquals("stage=wake reason=ui swallowed=0 held_ms=0", logs.last())
        assertTrue(tDown(130_100))
        assertFalse(p.onInput(IdleSource.UI, 130_200)) // already awake
    }

    @Test fun forgettingTheModelEndsEverySwallow() {
        dimAt()
        assertFalse(tDown(130_000))
        p.forgetGestures() // RELEASE_ALL: the trackers ignore the late UP anyway
        assertFalse(p.swallowingAny)
        assertTrue(tUp(130_100))
    }

    @Test fun aFreshTouchEndsASwallowWhoseReleaseNeverArrived() {
        dimAt()
        assertFalse(tDown(130_000))
        // the UP was lost; a new first finger starts an ordinary touch
        assertTrue(tDown(135_000))
        assertTrue(tUp(135_100))
    }

    @Test fun aDetachedDeviceIsForgottenAndOthersKeepTheirs() {
        val otherKb = IdleChannel.of(IdleChannel.KEY, 8, 30)
        assertTrue(key(keyA, true, 0))
        assertTrue(key(otherKb, true, 0))
        p.forgetDevice(7)
        assertTrue(p.held) // keyboard 8 still holds its key
        p.forgetDevice(8)
        assertFalse(p.held)
        p.tick(twoMin); assertEquals(IdleStage.DIM, p.stage)
        // a swallowed motion of a detached device is forgotten too
        assertFalse(tDown(130_000))
        p.forgetDevice(2)
        assertFalse(p.swallowingAny)
    }

    @Test fun forgettingAKindReleasesItsChannelsOnly() {
        assertTrue(p.admit(mouse, IdleSource.MOUSE, true, true, false, 0)) // a button held
        assertTrue(key(keyA, true, 0))
        p.forgetKinds(IdleChannel.PAD, IdleChannel.MOUSE)
        assertTrue(p.held)
        assertTrue(key(keyA, false, 10))
        assertFalse(p.held)
    }

    @Test fun aSilentSwallowedPressStopsHoldingTheCounterButItsContinuationStaysSwallowed() {
        dimAt()
        assertFalse(tDown(130_000))
        assertTrue(p.held)
        run(130_000, 130_000 + IdleDimPolicy.STALE_MS - 25)
        assertTrue(p.held)
        p.tick(130_000 + IdleDimPolicy.STALE_MS)
        assertTrue(p.swallowingAny)
        assertFalse(p.held)
        assertTrue(logs.last().startsWith("stage=wake reason=touch swallowed=1"))
        val end = 130_000 + IdleDimPolicy.STALE_MS // the counter stood still while the press was believed held
        p.tick(end + twoMin - 100); assertEquals(IdleStage.ACTIVE, p.stage) // last held tick was 25 ms before the expiry
        p.tick(end + twoMin); assertEquals(IdleStage.DIM, p.stage)
    }

    @Test fun aStaleSwallowEndsAtItsRealReleaseOrAFreshPress() {
        dimAt()
        assertFalse(tDown(130_000))
        p.tick(130_000 + IdleDimPolicy.STALE_MS)
        assertFalse(p.held)
        assertFalse(tMove(145_000)) // the finger moves again: still the waking motion
        assertTrue(p.held) // and it is alive again
        assertFalse(tUp(145_100)) // its real release
        assertFalse(p.swallowingAny)
        assertTrue(tDown(146_000))
        assertTrue(tUp(146_100))
        // a lost release: the next first finger is ordinary
        p.tick(146_100 + twoMin)
        assertFalse(tDown(400_000))
        p.tick(400_000 + IdleDimPolicy.STALE_MS)
        assertTrue(tDown(500_000, fresh = true))
    }

    @Test fun retainSentDropsOnlyWhatTheTrackerNoLongerHolds() {
        assertTrue(tDown(0))
        assertTrue(key(keyA, true, 0))
        p.retainSent { IdleChannel.kindOf(it) != IdleChannel.TOUCH } // the touch tracker released its stale press
        assertTrue(p.held) // the key is genuinely held
        assertTrue(key(keyA, false, 10))
        assertFalse(p.held)
        p.tick(10 + twoMin); assertEquals(IdleStage.DIM, p.stage)
    }

    @Test fun aSwallowedPressThatKeepsSendingEventsIsNotExpired() {
        dimAt()
        assertFalse(key(keyA, true, 130_000))
        var t = 130_000L
        while (t < 130_000 + 3 * IdleDimPolicy.STALE_MS) { t += 50; assertFalse(key(keyA, true, t, repeat = true)); p.tick(t) }
        assertTrue(p.isSwallowing(keyA))
        assertFalse(key(keyA, false, t + 10))
    }

    @Test fun channelIdsKeepKindDeviceAndCodeApart() {
        assertEquals(IdleChannel.TOUCH, IdleChannel.kindOf(touch))
        assertEquals(IdleChannel.KEY, IdleChannel.kindOf(IdleChannel.of(IdleChannel.KEY, -5, 0x10000 + 700)))
        assertTrue(IdleChannel.of(IdleChannel.KEY, 7, 30) != IdleChannel.of(IdleChannel.KEY, 8, 30))
        assertTrue(IdleChannel.of(IdleChannel.TOUCH, 1) != IdleChannel.of(IdleChannel.PEN, 1))
        assertEquals(-5, IdleChannel.deviceOf(IdleChannel.of(IdleChannel.KEY, -5, 0x10000 + 700)))
        assertEquals(7, IdleChannel.deviceOf(keyA))
    }

    @Test fun timeoutChoicesParseAndPersist() {
        assertEquals(listOf("2 dk", "5 dk", "10 dk", "15 dk", "Kapalı"), IdleTimeout.entries.map { it.label })
        assertEquals(IdleTimeout.MIN_5, IdleTimeout.parse(null))
        assertEquals(IdleTimeout.MIN_5, IdleTimeout.parse("7"))
        assertEquals(IdleTimeout.OFF, IdleTimeout.parse("off"))
        val kv = HashMap<String, String>()
        val store = IdleTimeoutStore(object : dev.matebridge.client.session.KeyValueStore {
            override fun getString(key: String) = kv[key]
            override fun putString(key: String, value: String) { kv[key] = value }
            override fun remove(key: String) { kv.remove(key) }
        })
        assertEquals(IdleTimeout.MIN_5, store.get())
        store.set(IdleTimeout.MIN_15)
        assertEquals(IdleTimeout.MIN_15, store.get())
        store.reset()
        assertEquals(IdleTimeout.MIN_5, store.get())
    }
}
