package dev.matebridge.client.session

import dev.matebridge.client.protocol.Bytes
import dev.matebridge.client.protocol.CameraControl
import dev.matebridge.client.protocol.CameraPrefs
import dev.matebridge.client.protocol.Hello
import dev.matebridge.client.protocol.HelloAck
import dev.matebridge.client.session.SessionMachine.Action
import dev.matebridge.client.session.SessionMachine.Event
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** T-355: CAMERA_PREFS production and CAMERA_CONTROL routing in the session machine (decision 0040). */
class CameraSessionMachineTest {
    private val hello = Hello(0, Bytes(ByteArray(16) { it.toByte() }), 2800, 1840, 360, 144, 0xFF, "MatePad")
    private val ep = Endpoint("10.0.0.5", 7420)
    private var now = 1_000_000L

    private fun machine(camera: CameraPrefs? = CameraPrefs.OFF) = SessionMachine(hello, initialCamera = camera)

    private fun SessionMachine.step(e: Event): List<Action> {
        now += 1_000
        return handle(e, now)
    }

    private fun SessionMachine.accept(remote: RemoteProfile? = null): Int {
        val open = step(Event.Start(ep, remote = remote)).filterIsInstance<Action.OpenControl>().single()
        step(Event.ControlOpened(open.gen))
        step(Event.Received(open.gen, HelloAck(0, HelloAck.ACCEPTED, 77, 7421, "Mac mini")))
        return open.gen
    }

    private fun List<Action>.sent() = filterIsInstance<Action.Send>().map { it.msg }
    private fun accepted(m: SessionMachine, remote: RemoteProfile? = null): List<Action> {
        val open = m.step(Event.Start(ep, remote = remote)).filterIsInstance<Action.OpenControl>().single()
        m.step(Event.ControlOpened(open.gen))
        return m.step(Event.Received(open.gen, HelloAck(0, HelloAck.ACCEPTED, 77, 7421, "Mac mini")))
    }

    private val start = CameraControl(CameraControl.STATE_START, 1, 47004, 1920, 1080, 30, 6000)

    @Test fun cameraPrefsFollowTheProofAndTheOtherSettingsWhenAccepted() {
        val m = machine(CameraPrefs(CameraPrefs.MODE_AUTO, CameraPrefs.FACING_BACK))
        val sent = accepted(m).sent()
        assertTrue(CameraPrefs(CameraPrefs.MODE_AUTO, CameraPrefs.FACING_BACK) in sent)
        // after the proof PING and the display messages, never before
        assertEquals(dev.matebridge.client.protocol.Ping::class, sent.first()::class)
    }

    @Test fun aClientWithoutACameraSendsNothingAndIgnoresControl() {
        val m = machine(camera = null)
        val gen = m.accept()
        assertTrue(m.step(Event.Received(gen, start)).none { it is Action.CameraControlReceived })
        assertTrue(m.step(Event.SetCamera(CameraPrefs(CameraPrefs.MODE_AUTO, 0))).isEmpty())
        val again = machine(camera = null)
        assertTrue(accepted(again).sent().none { it is CameraPrefs })
    }

    @Test fun aChangeIsSentWhileAcceptedAndRememberedOtherwise() {
        val m = machine()
        val autoFront = CameraPrefs(CameraPrefs.MODE_AUTO, CameraPrefs.FACING_FRONT)
        val autoBack = CameraPrefs(CameraPrefs.MODE_AUTO, CameraPrefs.FACING_BACK)
        // not connected: remembered, nothing sent
        assertTrue(m.step(Event.SetCamera(autoFront)).isEmpty())
        // the remembered wish is what the session announces when it is accepted
        assertTrue(autoFront in accepted(m).sent())
        assertEquals(listOf<Any>(autoBack), m.step(Event.SetCamera(autoBack)).sent())
        assertTrue(m.step(Event.SetCamera(autoBack)).isEmpty()) // unchanged: not repeated
        assertEquals(listOf<Any>(CameraPrefs.OFF), m.step(Event.SetCamera(CameraPrefs.OFF)).sent())
    }

    @Test fun aRemoteSessionAlwaysSaysOffEvenWithTheSettingOn() {
        val m = machine(CameraPrefs(CameraPrefs.MODE_AUTO, CameraPrefs.FACING_BACK))
        val sent = accepted(m, remote = RemoteProfile(1000, false)).sent()
        val prefs = sent.filterIsInstance<CameraPrefs>().single()
        assertEquals(CameraPrefs.MODE_OFF, prefs.mode)
        assertEquals(CameraPrefs.FACING_BACK, prefs.facing)
        // a later wish change can only ever put OFF on the wire (here with the new facing); the mode never turns on
        val later = m.step(Event.SetCamera(CameraPrefs(CameraPrefs.MODE_AUTO, CameraPrefs.FACING_FRONT))).sent().filterIsInstance<CameraPrefs>()
        assertTrue(later.all { it.mode == CameraPrefs.MODE_OFF })
        assertTrue(m.step(Event.SetCamera(CameraPrefs(CameraPrefs.MODE_AUTO, CameraPrefs.FACING_FRONT))).isEmpty())
    }

    @Test fun cameraControlOfAnAcceptedSessionReachesTheCamera() {
        val m = machine()
        val gen = m.accept()
        val a = m.step(Event.Received(gen, start))
        val got = a.filterIsInstance<Action.CameraControlReceived>().single()
        assertEquals(start, got.msg)
        assertEquals(gen, got.gen)
        assertEquals("10.0.0.5", got.host)
        assertEquals(77L, got.sessionId)
        val stop = m.step(Event.Received(gen, CameraControl(CameraControl.STATE_STOP, 1, 0, 0, 0, 0, 0)))
        assertTrue(stop.any { it is Action.CameraControlReceived })
    }

    @Test fun cameraControlBeforeAcceptanceIsDropped() {
        val m = machine()
        val open = m.step(Event.Start(ep)).filterIsInstance<Action.OpenControl>().single()
        m.step(Event.ControlOpened(open.gen))
        assertTrue(m.step(Event.Received(open.gen, start)).none { it is Action.CameraControlReceived })
    }

    @Test fun aStartInARemoteSessionIsIgnoredButAStopStillGoesThrough() {
        val m = machine()
        val gen = m.accept(remote = RemoteProfile(1000, false))
        assertTrue(m.step(Event.Received(gen, start)).none { it is Action.CameraControlReceived })
        assertTrue(m.step(Event.Received(gen, CameraControl.STOP)).any { it is Action.CameraControlReceived })
    }
}
