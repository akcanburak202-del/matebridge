package dev.matebridge.client.protocol

import java.io.File
import java.util.Random
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

// Golden-vector tests against the .hex files in protocol/fixtures (read in place).
class FixtureTest {
    companion object {
        val dir = File(System.getProperty("matebridge.fixtures") ?: "../../protocol/fixtures")

        fun fixture(name: String): ByteArray {
            val text = File(dir, "$name.hex").readText()
            val out = java.io.ByteArrayOutputStream()
            for (line in text.lines()) {
                val data = line.substringBefore('#')
                for (tok in data.trim().split(Regex("\\s+"))) {
                    if (tok.isEmpty()) continue
                    require(tok.length == 2) { "bad hex token '$tok' in $name" }
                    out.write(tok.toInt(16))
                }
            }
            return out.toByteArray()
        }

        private fun hex(s: String) = ByteArray(s.length / 2) { s.substring(it * 2, it * 2 + 2).toInt(16).toByte() }

        private val deviceId = Bytes(hex("0123456789abcdef0123456789abcdef"))

        /** Hand-written expected values (from the fixture comments / PROTOCOL.md). */
        val valid: Map<String, Message> = mapOf(
            "hello" to Hello(0, deviceId, 2800, 1840, 360, 144, 255, "MatePad Pro"),
            "hello_utf8_name" to Hello(
                0, Bytes(hex("000102030405060708090a0b0c0d0e0f")), 2800, 1840, 360, 60, 73, "Çizim Tableti ğüşöı",
            ),
            "hello_ack" to HelloAck(0, HelloAck.ACCEPTED, 2712847316L, 47001, "Mac mini"),
            "hello_ack_pending" to HelloAck(0, HelloAck.PENDING_APPROVAL, 0, 0, "Mac mini"),
            "hello_ack_busy" to HelloAck(0, HelloAck.BUSY, 0, 0, ""),
            "stream_config" to StreamConfig(1, StreamConfig.CODEC_HEVC, 2800, 1840, 1400, 920, 60, 50000, 1, 13, 1, 1),
            "bye" to Bye(Bye.NORMAL),
            "pen_hover_to_contact" to Pen(
                Pen.TOOL_PEN, 1127411618000L,
                listOf(
                    PenSample(0, 22364, 12738, 0, 3000, 2500, PenSample.IN_RANGE),
                    PenSample(3000, 22380, 12750, 288, 3000, 2500, 11),
                    PenSample(6000, 22410, 12771, 32768, 2980, 2490, 3),
                    PenSample(9000, 22430, 12790, 0, 2980, 2490, PenSample.IN_RANGE),
                ),
            ),
            "pen_leave" to Pen(Pen.TOOL_PEN, 1127411700000L, listOf(PenSample(0, 22430, 12790, 0, 0, 0, 0))),
            "pen_eraser" to Pen(
                Pen.TOOL_ERASER, 1127411800000L, listOf(PenSample(0, 1000, 2000, 65535, -32767, 0, 15)),
            ),
            "pen_extremes" to Pen(
                Pen.TOOL_PEN, 0,
                listOf(
                    PenSample(0, 65535, 65535, 65535, 32767, -32767, 3),
                    PenSample(4294967295L, 65535, 65535, 65535, -32767, 32767, 3),
                ),
            ),
            "pen_gesture" to PenGesture(1127465515000L, PenGesture.DOUBLE_TAP),
            "key_down" to Key(1127463498000L, 30, 29, Key.DOWN, 0),
            "key_up_caps" to Key(1127463600000L, 58, 115, Key.UP, Key.LOCK_CAPS),
            "key_no_scan" to Key(1127463700000L, 0, 85, Key.DOWN, 0),
            "pointer_rel" to PointerRel(1127500489000L, 2.5f, -1.25f, Buttons.LEFT),
            "pointer_abs" to PointerAbs(1127500500000L, 32768, 32768, Buttons.LEFT, PointerAbs.SOURCE_TOUCH),
            "scroll_began" to Scroll(1127500590000L, 0f, 0f, Scroll.BEGAN),
            "scroll" to Scroll(1127500600000L, 0f, 12.5f, Scroll.CHANGED),
            "scroll_ended" to Scroll(1127500700000L, 0f, 0f, Scroll.ENDED),
            "release_all" to ReleaseAll(ReleaseAll.BACKGROUND),
            "ping" to Ping(7, 1127500700000L),
            "pong" to Pong(7, 1127500700000L, 98765432100L),
            "stats" to Stats(1000, 60, 60, 59, 1, 4200, 23000, 6250000),
            "keyframe_request" to KeyframeRequest(KeyframeRequest.DECODE_ERROR),
            "video_hello" to VideoHello(0, 1, 2712847316L),
            "video_frame" to VideoFrame(
                1, 98765000000L, VideoFrame.KEYFRAME, 0, 1, 8, Bytes(hex("0000000126010af0")),
            ),
            "video_frame_config" to VideoFrame(
                0, 98764990000L, VideoFrame.CODEC_CONFIG, 0, 1, 6, Bytes(hex("000000014001")),
            ),
        )

        val invalid = setOf("invalid_key_short", "invalid_pen_count_zero")
        val skipped = setOf("unknown_type")

        private fun decoderFor(msg: Message?) =
            if (msg is VideoFrame) FrameDecoder.video() else FrameDecoder.control()
    }

    @Test
    fun everyFixtureFileHasATestCase() {
        val onDisk = dir.listFiles { f -> f.name.endsWith(".hex") }!!.map { it.name.removeSuffix(".hex") }.toSet()
        val covered = valid.keys + invalid + skipped
        assertEquals("fixtures without a test case or stale cases", onDisk, covered)
    }

    @Test
    fun decodeMatchesExpected() {
        for ((name, expected) in valid) {
            val dec = decoderFor(expected)
            dec.feed(fixture(name))
            assertEquals("decode $name", expected, dec.next())
            assertNull("trailing data in $name", dec.next())
        }
    }

    @Test
    fun encodeIsByteIdentical() {
        for ((name, msg) in valid) {
            assertArrayEquals("encode $name", fixture(name), Codec.encode(msg))
        }
    }

    @Test
    fun invalidFixturesAreProtocolErrors() {
        for (name in invalid) {
            val dec = FrameDecoder.control()
            dec.feed(fixture(name))
            try {
                dec.next()
                fail("$name must be rejected")
            } catch (e: ProtocolException) {
                // expected; the decoder stays failed
            }
            try {
                dec.next()
                fail("$name: decoder must stay failed")
            } catch (e: ProtocolException) {
            }
        }
    }

    @Test
    fun unknownTypeIsSkippedAndStreamContinues() {
        val dec = FrameDecoder.control()
        dec.feed(fixture("unknown_type") + fixture("ping"))
        assertEquals(valid["ping"], dec.next())
        assertEquals(1, dec.skippedFrames)
        assertNull(dec.next())
    }

    @Test
    fun byteAtATimeGivesSameResult() {
        for ((name, expected) in valid) {
            val dec = decoderFor(expected)
            val bytes = fixture(name)
            val got = ArrayList<Message>()
            for (b in bytes) {
                dec.feed(byteArrayOf(b))
                got += dec.drain()
            }
            assertEquals("byte-wise $name", listOf(expected), got)
        }
    }

    @Test
    fun randomChunksOfConcatenatedStreamGiveSameResult() {
        val all = valid.entries.filter { it.value !is VideoFrame }
        val stream = java.io.ByteArrayOutputStream()
        stream.write(fixture("unknown_type"))
        for ((name, _) in all) stream.write(fixture(name))
        val bytes = stream.toByteArray()
        val rnd = Random(42)
        repeat(50) {
            val dec = FrameDecoder.control()
            val got = ArrayList<Message>()
            var pos = 0
            while (pos < bytes.size) {
                val n = minOf(1 + rnd.nextInt(40), bytes.size - pos)
                dec.feed(bytes, pos, n)
                got += dec.drain()
                pos += n
            }
            assertEquals(all.map { it.value }, got)
        }
    }

    @Test
    fun videoFramesDecodeOnVideoDecoder() {
        val dec = FrameDecoder.video()
        dec.feed(fixture("video_frame_config") + fixture("video_frame"))
        val a = dec.next() as VideoFrame
        val b = dec.next() as VideoFrame
        assertTrue(a.isCodecConfig && !a.isKeyframe)
        assertTrue(b.isKeyframe && !b.isCodecConfig)
    }
}
