package dev.matebridge.client.session

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** T-218: keepalive bounds a half-open video socket; the settings and the failure handling (never fatal). */
class VideoKeepaliveTest {
    @Test fun setsKeepaliveThenTheLinuxTimersInOrder() {
        val calls = ArrayList<String>()
        val err = VideoKeepalive.apply({ calls += "so_keepalive" }) { opt, v -> calls += "$opt=$v" }
        assertNull(err)
        assertEquals(listOf("so_keepalive", "4=3", "5=1", "6=3"), calls) // TCP_KEEPIDLE 3 s, KEEPINTVL 1 s, KEEPCNT 3
    }

    @Test fun aDeadPeerIsDetectedLaterThanTheControlHeartbeatButWithinSeconds() {
        val boundS = VideoKeepalive.IDLE_S + VideoKeepalive.INTERVAL_S * VideoKeepalive.COUNT
        assertTrue("never stricter than the PONG timeout", boundS * 1_000_000L > SessionMachine.PONG_TIMEOUT_US)
        assertTrue("a half-open socket is bounded", boundS <= 10)
    }

    @Test fun aFailureNamesTheStepAndStopsThere() {
        val calls = ArrayList<Int>()
        val err = VideoKeepalive.apply({}) { opt, _ ->
            calls += opt
            if (opt == VideoKeepalive.TCP_KEEPINTVL) throw IllegalStateException("EINVAL")
        }
        assertEquals("keepintvl:IllegalStateException", err)
        assertEquals(listOf(VideoKeepalive.TCP_KEEPIDLE, VideoKeepalive.TCP_KEEPINTVL), calls)
        assertEquals("so_keepalive:SocketException", VideoKeepalive.apply({ throw java.net.SocketException("closed") }) { _, _ -> })
    }
}
