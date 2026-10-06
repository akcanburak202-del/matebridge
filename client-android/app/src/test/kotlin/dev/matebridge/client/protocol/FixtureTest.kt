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
        private val clientNonce = Bytes(hex("c0c1c2c3c4c5c6c7c8c9cacbcccdcecf"))
        private val clientEphPub = Bytes(
            hex("043b2e3be924f7393ba036956d4f154be45d37e6c02baecfc991a3c6ae4213629e7ab47261459f5823e7e72769597493bc607eb317d9ef1ca4ddb85f3cc2a35538"),
        )
        private val hostId = Bytes(hex("303132333435363738393a3b3c3d3e3f"))
        private val hostNonce = Bytes(hex("e0e1e2e3e4e5e6e7e8e9eaebecedeeef"))
        private val hostEphPub = Bytes(
            hex("04a417215b2ffac23f26ff2b85372f155fc16a7aa6b79ffbf4a37e5bb82cd72453761d437b3fe609bf5d0cefdfd95463724938ae81a3f04c8dbc2af6be0cac5efb"),
        )
        private val zeros16 = Bytes(ByteArray(16))
        private val zeros65 = Bytes(ByteArray(65))

        /** Hand-written expected values (from the fixture comments / PROTOCOL.md). */
        val valid: Map<String, Message> = mapOf(
            "hello" to Hello(1, deviceId, 2800, 1840, 360, 144, 255, "MatePad Pro", clientNonce, clientEphPub),
            "hello_utf8_name" to Hello(
                1, Bytes(hex("000102030405060708090a0b0c0d0e0f")), 2800, 1840, 360, 60, 73, "Çizim Tableti ğüşöı",
                clientNonce, clientEphPub,
            ),
            "hello_ack" to HelloAck(
                1, HelloAck.ACCEPTED, 2712847316L, 47001, "Mac mini", HelloAck.KEY_PAIRED, hostId, hostNonce, hostEphPub,
            ),
            "hello_ack_pending" to HelloAck(
                1, HelloAck.PENDING_APPROVAL, 0, 0, "Mac mini", HelloAck.KEY_PAIRING, hostId, hostNonce, hostEphPub,
            ),
            "hello_ack_busy" to HelloAck(1, HelloAck.BUSY, 0, 0, "", HelloAck.KEY_NONE, zeros16, zeros16, zeros65),
            "stream_config" to StreamConfig(1, StreamConfig.CODEC_HEVC, 2800, 1840, 1400, 920, 60, 50000, 1, 13, 1, 1),
            "stream_config_game_display" to StreamConfig(
                2, StreamConfig.CODEC_HEVC, 1848, 1214, 1848, 1214, 120, 60000, 1, 13, 1, 1,
            ),
            // Decision 0032: HDR10 applied (BT.2020 / PQ / BT.2020 NCL, limited range).
            "stream_config_hdr10" to StreamConfig(
                3, StreamConfig.CODEC_HEVC, 1848, 1214, 1848, 1214, 120, 60000, 9, 16, 9, 0,
            ),
            "stream_config_packed444" to StreamConfig(
                4, StreamConfig.CODEC_HEVC, 2800, 1840, 1400, 920, 60, 30000, 1, 13, 1, 1, StreamConfig.CHROMA_LAYOUT_PACKED_444,
            ),
            "bye" to Bye(Bye.NORMAL),
            "bye_host_sleep" to Bye(Bye.HOST_SLEEP),
            "stream_prefs" to StreamPrefs(120, 750, 0),
            "stream_prefs_bitrate" to StreamPrefs(120, 1000, 40000),
            "stream_prefs_game_display" to StreamPrefs(120, 660, 60000, 1848, 1214),
            "stream_prefs_hdr" to StreamPrefs(120, 660, 0, 1848, 1214, StreamPrefs.DYNAMIC_RANGE_HDR10),
            "stream_prefs_sharp_chroma" to StreamPrefs(60, 1000, 0, 0, 0, StreamPrefs.DYNAMIC_RANGE_SDR, StreamPrefs.CHROMA_SHARP),
            "stream_prefs_full_chroma" to StreamPrefs(60, 1000, 0, 0, 0, StreamPrefs.DYNAMIC_RANGE_SDR, StreamPrefs.CHROMA_FULL),
            "display_rate" to DisplayRate(60),
            "settings_open" to SettingsOpen,
            "files_info_ready" to FilesInfo(FilesInfo.STATE_READY, 47010, "0123456789abcdef0123456789abcdef"),
            "files_info_off" to FilesInfo.OFF,
            "files_info_standby" to FilesInfo.STANDBY,
            "files_net_open" to FilesNet(FilesNet.STATE_OPEN, 47003, 2, 12),
            "files_net_close" to FilesNet(FilesNet.STATE_CLOSE, 0, 0, 0),
            "cursor_prefs_on" to CursorPrefs(true),
            "cursor_prefs_off" to CursorPrefs(false),
            "cursor_shape" to CursorShape(
                0x67BAAA67L, 144, 288, 64, 144, CursorShape.FORMAT_PNG,
                Bytes(hex("89504e470d0a1a0a0000000d494844520000001200000024080600000084ed6ae7000000274944415478da6360200cfe4331c560d4a05183460d1a3568d4a05183460d1a3568d4a061611000d2a147b94dc703e80000000049454e44ae426082")),
            ),
            "cursor_state" to CursorState(42, 32768, 32768, true, 0x67BAAA67L, 123456789012L),
            "cursor_state_hidden" to CursorState(43, 32768, 65535, false, 0x67BAAA67L, 123456799012L),
            "files_hello" to FilesHello(1, 2712847316L, Bytes(hex("707172737475767778797a7b7c7d7e7f"))),
            "files_hello_ack" to FilesHelloAck(FilesHelloAck.OK, Bytes(hex("808182838485868788898a8b8c8d8e8f"))),
            "files_hello_ack_rejected" to FilesHelloAck(FilesHelloAck.REJECTED, zeros16),
            "files_data" to FilesData(Bytes("OPTIONS / HTTP/1.1".toByteArray(Charsets.US_ASCII))),
            "clipboard_text" to Clipboard(3, Clipboard.KIND_TEXT_UTF8, Bytes("Merhaba ğüşıöç — kopyala".toByteArray())),
            "clipboard_empty" to Clipboard(4, Clipboard.KIND_EMPTY, Bytes(ByteArray(0))),
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
            "pinch_began" to Pinch(1127500800000L, 0f, 24576, 32768, Pinch.BEGAN, Pinch.SOURCE_TOUCH),
            "pinch" to Pinch(1127500816000L, 0.05f, 24576, 32768, Pinch.CHANGED, Pinch.SOURCE_TOUCH),
            "pinch_ended" to Pinch(1127500900000L, 0f, 0, 0, Pinch.ENDED, Pinch.SOURCE_TOUCHPAD),
            "release_all" to ReleaseAll(ReleaseAll.BACKGROUND),
            "ping" to Ping(7, 1127500700000L),
            "pong" to Pong(7, 1127500700000L, 98765432100L),
            "stats" to Stats(1000, 60, 60, 59, 1, 4200, 23000, 6250000),
            "keyframe_request" to KeyframeRequest(KeyframeRequest.DECODE_ERROR),
            "keyframe_request_view" to KeyframeRequest(KeyframeRequest.DECODE_ERROR, KeyframeRequest.VIEW_AUX),
            "audio_prefs" to AudioPrefs(true),
            "audio_config" to AudioConfig(3, AudioConfig.STATE_STARTED, AudioConfig.FORMAT_PCM_S16LE, 48000, 2, 480),
            "audio_config_stopped" to AudioConfig.stopped(3),
            "audio_frame" to AudioFrame(3, 7, 3360, 123456789012L, 4, Bytes(hex("00000000e80318fcff7f0080ffff0100"))),
            "video_hello" to VideoHello(1, 1, 2712847316L, Bytes(hex("0f0e0d0c0b0a09080706050403020100"))),
            "video_frame" to VideoFrame(
                1, 98765000000L, VideoFrame.KEYFRAME, 0, 1, 8, Bytes(hex("0000000126010af0")),
            ),
            "video_frame_config" to VideoFrame(
                0, 98764990000L, VideoFrame.CODEC_CONFIG, 0, 1, 6, Bytes(hex("000000014001")),
            ),
            "video_frame_aux" to VideoFrame(
                1, 98765000000L, VideoFrame.KEYFRAME, 0, 1, 8, Bytes(hex("0000000126010af0")), VideoFrame.VIEW_AUX,
            ),
            "video_frame_aux_config" to VideoFrame(
                0, 98764990000L, VideoFrame.CODEC_CONFIG, 0, 1, 6, Bytes(hex("000000014001")), VideoFrame.VIEW_AUX,
            ),
        )

        val invalid = setOf(
            "invalid_key_short", "invalid_pen_count_zero", "invalid_audio_frame_short", "invalid_stream_prefs_partial",
            "invalid_stream_prefs_hdr_partial", "invalid_files_hello_short", "invalid_files_data_empty", "invalid_cursor_shape_short",
        )
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
