package dev.matebridge.client.camera

import dev.matebridge.client.protocol.CameraControl
import dev.matebridge.client.security.SessionSecrets
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class CameraControllerTest {
    private class FakeRun(val plan: CameraPlan, var facing: CameraFacing, val onGaveUp: (CameraRun, String) -> Unit) : CameraRun {
        val closed = ArrayList<String>()
        val switches = ArrayList<CameraFacing>()
        override fun switchFacing(facing: CameraFacing) { switches += facing; this.facing = facing }
        override fun close(reason: String) { closed += reason }
    }

    private val runs = ArrayList<FakeRun>()
    private var permission = true
    private val states = ArrayList<CameraUiState>()
    private val factory = CameraRunFactory { plan, _, facing, gaveUp -> FakeRun(plan, facing, gaveUp).also { runs += it } }
    private val c = CameraController(factory, { permission }, { states += it })
    private val secrets = SessionSecrets(ByteArray(32), pairing = false, hostId = ByteArray(16))
    private fun ctx(gen: Int = 1) = CameraSessionCtx(gen, "10.0.0.5", 77, secrets)

    private fun start(id: Int, port: Int = 47004) = CameraControl(CameraControl.STATE_START, id, port, 1920, 1080, 30, 6000)
    private val stop = CameraControl(CameraControl.STATE_STOP, 1, 0, 0, 0, 0, 0)
    private val unavailable = CameraControl(CameraControl.STATE_UNAVAILABLE, 0, 0, 0, 0, 0, 0)
    private fun auto(facing: CameraFacing = CameraFacing.FRONT) = c.setWish(CameraWish(CameraMode.AUTO, facing))

    @Test fun nothingExistsBeforeAStartOrWhileOff() {
        assertEquals(0, runs.size)
        c.onControl(start(1), ctx()) // mode is Kapalı: a START (a host bug) starts nothing
        assertEquals(0, runs.size)
        auto()
        assertEquals(1, runs.size) // the held START runs as soon as the mode allows it
    }

    @Test fun autoWithoutAStartCreatesNothing() {
        auto()
        c.setForeground(false)
        c.setForeground(true)
        assertEquals(0, runs.size)
        assertFalse(c.running)
        assertEquals(CameraUiState.IDLE, c.uiState)
    }

    @Test fun startOpensOneRunWithThePlanAndTheWishedFacing() {
        auto(CameraFacing.BACK)
        c.onControl(start(3), ctx())
        assertEquals(1, runs.size)
        assertEquals(CameraPlan(3, 47004, 1920, 1080, 30, 6000), runs[0].plan)
        assertEquals(CameraFacing.BACK, runs[0].facing)
        assertTrue(c.running)
        assertEquals(CameraUiState.ACTIVE, c.uiState)
    }

    @Test fun theSameCamIdAgainChangesNothing() {
        auto()
        c.onControl(start(1), ctx())
        c.onControl(start(1), ctx())
        assertEquals(1, runs.size)
        assertTrue(runs[0].closed.isEmpty())
    }

    @Test fun aNewCamIdClosesTheOldRunAndOpensANewOne() {
        auto()
        c.onControl(start(1), ctx())
        c.onControl(start(2, port = 47010), ctx())
        assertEquals(2, runs.size)
        assertEquals(listOf("new_cam_id"), runs[0].closed)
        assertEquals(2, runs[1].plan.camId)
        assertEquals(47010, runs[1].plan.port)
        assertTrue(runs[1].closed.isEmpty())
    }

    @Test fun stopClosesAtOnce() {
        auto()
        c.onControl(start(1), ctx())
        c.onControl(stop, ctx())
        assertEquals(listOf("stop"), runs[0].closed)
        assertFalse(c.running)
        assertEquals(CameraUiState.IDLE, c.uiState)
        c.onControl(start(2), ctx())
        assertEquals(2, runs.size) // a later START is a new stream
    }

    @Test fun unavailableClosesAndShowsWhy() {
        auto()
        c.onControl(start(1), ctx())
        c.onControl(unavailable, ctx())
        assertEquals(listOf("unavailable"), runs[0].closed)
        assertEquals(CameraUiState.UNAVAILABLE, c.uiState)
        c.onControl(start(2), ctx())
        assertEquals(CameraUiState.ACTIVE, c.uiState)
    }

    @Test fun anUnknownStateCountsAsStop() {
        auto()
        c.onControl(start(1), ctx())
        c.onControl(CameraControl(9, 1, 0, 0, 0, 0, 0), ctx())
        assertEquals(1, runs[0].closed.size)
        assertFalse(c.running)
    }

    @Test fun backgroundClosesAtOnceAndForegroundReopensTheSameCamId() {
        auto()
        c.onControl(start(4), ctx())
        c.setForeground(false) // onStop
        assertEquals(listOf("background"), runs[0].closed)
        assertFalse(c.running)
        c.onControl(start(4), ctx()) // a repeat in the background changes nothing and opens nothing
        assertEquals(1, runs.size)
        c.setForeground(true) // onStart: the held START reopens
        assertEquals(2, runs.size)
        assertEquals(4, runs[1].plan.camId)
        assertTrue(c.running)
    }

    @Test fun stopWhileInTheBackgroundIsNotReopened() {
        auto()
        c.onControl(start(4), ctx())
        c.setForeground(false)
        c.onControl(stop, ctx())
        c.setForeground(true)
        assertEquals(1, runs.size)
    }

    @Test fun sessionEndClosesEverythingAndForgetsTheStart() {
        auto()
        c.onControl(start(1), ctx())
        c.onSessionEnd()
        assertEquals(listOf("session_end"), runs[0].closed)
        c.setForeground(false)
        c.setForeground(true)
        assertEquals(1, runs.size) // nothing of the old session comes back
        assertEquals(CameraUiState.IDLE, c.uiState)
    }

    @Test fun aStartFromAnotherSessionGenerationReplacesTheOldSession() {
        auto()
        c.onControl(start(1), ctx(gen = 1))
        c.onControl(start(1), ctx(gen = 2)) // same cam_id, but another session: the old run goes, a new one opens
        assertEquals(2, runs.size)
        assertEquals(listOf("session_switch"), runs[0].closed)
    }

    @Test fun settingOffClosesAtOnceAndTheStartIsSpent() {
        auto()
        c.onControl(start(1), ctx())
        c.setWish(CameraWish(CameraMode.OFF, CameraFacing.FRONT))
        assertEquals(listOf("mode_off"), runs[0].closed)
        auto()
        assertEquals(1, runs.size) // the Mac stops on CAMERA_PREFS(OFF); only a new START opens again
    }

    @Test fun noPermissionNoRunAndRevokingClosesIt() {
        permission = false
        auto()
        c.onControl(start(1), ctx())
        assertEquals(0, runs.size)
        permission = true
        c.onPermissionChanged()
        assertEquals(1, runs.size)
        permission = false
        c.onPermissionChanged()
        assertEquals(listOf("permission"), runs[0].closed)
    }

    @Test fun facingChangeWhileStreamingSwitchesTheSameRun() {
        auto(CameraFacing.FRONT)
        c.onControl(start(1), ctx())
        auto(CameraFacing.BACK)
        assertEquals(1, runs.size)
        assertEquals(listOf(CameraFacing.BACK), runs[0].switches)
        auto(CameraFacing.BACK) // unchanged: no second switch
        assertEquals(1, runs[0].switches.size)
        assertTrue(runs[0].closed.isEmpty())
    }

    @Test fun aRunThatEndsByItselfSpendsTheStart() {
        auto()
        c.onControl(start(1), ctx())
        val r = runs[0]
        r.onGaveUp(r, "link_lost") // retries used up
        assertFalse(c.running)
        assertEquals(CameraUiState.IDLE, c.uiState)
        c.setForeground(false)
        c.setForeground(true)
        assertEquals(1, runs.size) // not reopened by itself
        c.onControl(start(2), ctx())
        assertEquals(2, runs.size)
    }

    @Test fun aLateWordOfAnOldRunIsIgnored() {
        auto()
        c.onControl(start(1), ctx())
        val old = runs[0]
        c.onControl(start(2), ctx())
        old.onGaveUp(old, "link_lost")
        assertTrue(c.running)
    }

    @Test fun uiStateIsPublishedOnChangesOnly() {
        auto()
        c.onControl(start(1), ctx())
        c.onControl(start(2), ctx())
        c.onControl(stop, ctx())
        assertEquals(listOf(CameraUiState.ACTIVE, CameraUiState.IDLE), states)
        assertNotNull(states.firstOrNull())
        assertNull(states.getOrNull(2))
    }
}
