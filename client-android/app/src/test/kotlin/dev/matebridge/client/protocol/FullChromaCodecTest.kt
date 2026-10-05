package dev.matebridge.client.protocol

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** T-259 (decision 0034, PROTOCOL.md): the optional / tolerant parts of the new fields beyond the golden vectors. */
class FullChromaCodecTest {
    private fun roundTrip(m: Message): Message {
        val dec = if (m is VideoFrame) FrameDecoder.video() else FrameDecoder.control()
        dec.feed(Codec.encode(m))
        return dec.next()!!
    }

    @Test fun keyframeRequestWithoutViewIsTheOldWireForm() {
        // single stream (or old host): exactly the pre-0034 bytes
        assertArrayEquals(FixtureTest.fixture("keyframe_request"), Codec.encode(KeyframeRequest(KeyframeRequest.DECODE_ERROR)))
        assertEquals(KeyframeRequest.VIEW_UNSPECIFIED, (roundTrip(KeyframeRequest(KeyframeRequest.STARTUP)) as KeyframeRequest).view)
    }

    @Test fun keyframeRequestViewRoundTrips() {
        for (v in listOf(KeyframeRequest.VIEW_MAIN, KeyframeRequest.VIEW_AUX, KeyframeRequest.VIEW_BOTH)) {
            val m = roundTrip(KeyframeRequest(KeyframeRequest.FRAMES_DROPPED, v)) as KeyframeRequest
            assertEquals(v, m.view)
            assertEquals(KeyframeRequest.FRAMES_DROPPED, m.reason)
        }
        assertEquals(5 + 2, Codec.encode(KeyframeRequest(0, KeyframeRequest.VIEW_AUX)).size)
    }

    @Test fun unknownChromaLayoutDecodesButIsNotPacked() {
        val c = roundTrip(StreamConfig(9, StreamConfig.CODEC_HEVC, 2800, 1840, 1400, 920, 60, 1, 1, 13, 1, 1, chromaLayout = 7)) as StreamConfig
        assertEquals(7, c.chromaLayout)
        assertFalse(c.isPacked444)
        assertTrue(StreamConfig(1, 2, 2800, 1840, 1400, 920, 60, 1, 1, 13, 1, 1, 1).isPacked444)
    }

    @Test fun videoFrameViewIsKeptEvenWhenUnknown() {
        val f = roundTrip(VideoFrame(1, 2, 0, 0, 1, 1, Bytes(byteArrayOf(5)), view = 9)) as VideoFrame
        assertEquals(9, f.view) // the receiver skips it (MainActivity); not a protocol error
    }

    @Test fun capabilityBit11() {
        assertEquals(2048, Capabilities.FULL_CHROMA)
        assertEquals(0, Capabilities.FULL_CHROMA and Capabilities.FILES)
    }

    @Test fun fullChromaPrefsAreFourteenBytes() {
        val bytes = Codec.encode(StreamPrefs(60, 1000, 0, 0, 0, StreamPrefs.DYNAMIC_RANGE_SDR, StreamPrefs.CHROMA_FULL))
        assertEquals(5 + 14, bytes.size)
        assertEquals(2, bytes.last().toInt())
    }
}
