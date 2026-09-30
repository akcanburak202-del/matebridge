package dev.matebridge.client.protocol

import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.charset.CharacterCodingException
import java.nio.charset.CodingErrorAction

/** A protocol violation (PROTOCOL.md section 2). The caller reacts per connection kind. */
class ProtocolException(val kind: Kind, message: String) : Exception(message) {
    enum class Kind {
        /** Payload shorter than the message layout requires. */
        SHORT_PAYLOAD,

        /** Frame length above the connection's payload limit. */
        OVERSIZE,

        /** Non-finite f32. */
        NON_FINITE,

        /** Invalid enum-like value (tool, action) or count. */
        INVALID_VALUE,

        /** PEN samples with decreasing dt_us. */
        DECREASING_TIME,

        /** Malformed str8 (too long, bad UTF-8). */
        INVALID_STRING,

        /** Decoder fed past its buffer cap without being drained. */
        BUFFER_OVERFLOW,

        /** Invalid public key, inconsistent HELLO_ACK, or an encrypted record that failed authentication (section 9). */
        AUTH_FAILED,
    }
}

/** Sequential little-endian reader over a payload. Throws SHORT_PAYLOAD when running out. */
internal class Reader(bytes: ByteArray) {
    private val buf = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN)

    private fun need(n: Int) {
        if (buf.remaining() < n) {
            throw ProtocolException(ProtocolException.Kind.SHORT_PAYLOAD, "need $n bytes, have ${buf.remaining()}")
        }
    }

    fun u8(): Int { need(1); return buf.get().toInt() and 0xFF }
    fun u16(): Int { need(2); return buf.short.toInt() and 0xFFFF }
    fun i16(): Int { need(2); return buf.short.toInt() }
    fun u32(): Long { need(4); return buf.int.toLong() and 0xFFFFFFFFL }
    fun u64(): Long { need(8); return buf.long }
    fun f32(): Float {
        need(4)
        val v = buf.float
        if (v.isNaN() || v.isInfinite()) {
            throw ProtocolException(ProtocolException.Kind.NON_FINITE, "non-finite f32")
        }
        return v
    }

    fun bytes(n: Int): ByteArray { need(n); return ByteArray(n).also { buf.get(it) } }
    fun skip(n: Int) { need(n); buf.position(buf.position() + n) }
    fun remaining(): Int = buf.remaining()

    fun str8(): String {
        val len = u8()
        if (len > Limits.STR8_MAX_BYTES) {
            throw ProtocolException(ProtocolException.Kind.INVALID_STRING, "str8 length $len > 64")
        }
        val raw = bytes(len)
        return try {
            Charsets.UTF_8.newDecoder()
                .onMalformedInput(CodingErrorAction.REPORT)
                .onUnmappableCharacter(CodingErrorAction.REPORT)
                .decode(ByteBuffer.wrap(raw)).toString()
        } catch (e: CharacterCodingException) {
            throw ProtocolException(ProtocolException.Kind.INVALID_STRING, "str8 is not valid UTF-8")
        }
    }
}

/** Growable little-endian writer. Encoders validate their input with IllegalArgumentException. */
internal class Writer(capacity: Int = 64) {
    private var buf = ByteBuffer.allocate(capacity).order(ByteOrder.LITTLE_ENDIAN)

    private fun ensure(n: Int) {
        if (buf.remaining() < n) {
            val bigger = ByteBuffer.allocate(maxOf(buf.capacity() * 2, buf.position() + n)).order(ByteOrder.LITTLE_ENDIAN)
            buf.flip()
            bigger.put(buf)
            buf = bigger
        }
    }

    private fun range(v: Long, lo: Long, hi: Long, what: String) =
        require(v in lo..hi) { "$what out of range: $v" }

    fun u8(v: Int) { range(v.toLong(), 0, 0xFF, "u8"); ensure(1); buf.put(v.toByte()) }
    fun u16(v: Int) { range(v.toLong(), 0, 0xFFFF, "u16"); ensure(2); buf.putShort(v.toShort()) }
    fun i16(v: Int) { range(v.toLong(), -32767, 32767, "i16"); ensure(2); buf.putShort(v.toShort()) }
    fun u32(v: Long) { range(v, 0, 0xFFFFFFFFL, "u32"); ensure(4); buf.putInt(v.toInt()) }
    fun u64(v: Long) { ensure(8); buf.putLong(v) }
    fun f32(v: Float) {
        require(!v.isNaN() && !v.isInfinite()) { "non-finite f32" }
        ensure(4); buf.putFloat(v)
    }

    fun zeros(n: Int) { ensure(n); repeat(n) { buf.put(0) } }
    fun bytes(b: ByteArray) { ensure(b.size); buf.put(b) }

    fun str8(s: String) {
        val raw = s.toByteArray(Charsets.UTF_8)
        require(raw.size <= Limits.STR8_MAX_BYTES) { "str8 longer than 64 bytes" }
        u8(raw.size)
        bytes(raw)
    }

    fun toByteArray(): ByteArray = buf.array().copyOf(buf.position())
}

object Codec {
    private fun checkEnum(v: Int, range: IntRange, what: String) {
        if (v !in range) throw ProtocolException(ProtocolException.Kind.INVALID_VALUE, "unknown $what $v")
    }

    private fun requireEnum(v: Int, range: IntRange, what: String) =
        require(v in range) { "unknown $what $v" }

    /** Encodes a full frame: 5-byte header plus payload. */
    fun encode(msg: Message): ByteArray {
        val payload = encodePayload(msg)
        val limit = if (msg is VideoHello || msg is VideoFrame) Limits.VIDEO_MAX_PAYLOAD else Limits.CONTROL_MAX_PAYLOAD
        require(payload.size <= limit) { "payload ${payload.size} exceeds limit $limit" }
        val out = Writer(payload.size + 5)
        out.u8(msg.type)
        out.u32(payload.size.toLong())
        out.bytes(payload)
        return out.toByteArray()
    }

    fun encodePayload(msg: Message): ByteArray {
        val w = Writer()
        when (msg) {
            is Hello -> {
                require(msg.deviceId.size == Limits.DEVICE_ID_BYTES) { "device_id must be 16 bytes" }
                w.u16(msg.protocolVersion)
                w.bytes(msg.deviceId.value)
                w.u16(msg.screenWidthPx); w.u16(msg.screenHeightPx)
                w.u16(msg.densityDpi); w.u16(msg.maxRefreshHz)
                w.u32(msg.capabilities)
                w.str8(msg.deviceName)
                require(msg.clientNonce.size == Limits.NONCE_BYTES) { "client_nonce must be 16 bytes" }
                require(msg.clientEphPub.size == Limits.EPH_PUB_BYTES) { "client_eph_pub must be 65 bytes" }
                w.bytes(msg.clientNonce.value)
                w.bytes(msg.clientEphPub.value)
            }
            is HelloAck -> {
                requireEnum(msg.status, 0..4, "HELLO_ACK.status")
                w.u16(msg.protocolVersion); w.u8(msg.status); w.u8(0)
                w.u32(msg.sessionId); w.u16(msg.videoPort)
                w.str8(msg.hostName)
                requireEnum(msg.keyMode, 0..2, "HELLO_ACK.key_mode")
                require(msg.hostId.size == Limits.DEVICE_ID_BYTES) { "host_id must be 16 bytes" }
                require(msg.hostNonce.size == Limits.NONCE_BYTES) { "host_nonce must be 16 bytes" }
                require(msg.hostEphPub.size == Limits.EPH_PUB_BYTES) { "host_eph_pub must be 65 bytes" }
                w.u8(msg.keyMode)
                w.bytes(msg.hostId.value); w.bytes(msg.hostNonce.value); w.bytes(msg.hostEphPub.value)
            }
            is StreamConfig -> {
                requireEnum(msg.codec, 1..2, "STREAM_CONFIG.codec")
                w.u16(msg.configId); w.u8(msg.codec); w.u8(0)
                w.u16(msg.widthPx); w.u16(msg.heightPx)
                w.u16(msg.widthPt); w.u16(msg.heightPt)
                w.u16(msg.fps); w.u32(msg.bitrateKbps)
                w.u8(msg.colorPrimaries); w.u8(msg.transfer); w.u8(msg.matrix); w.u8(msg.fullRange)
            }
            is Clipboard -> {
                require(msg.data.size <= Clipboard.MAX_DATA_BYTES) { "clipboard data exceeds ${Clipboard.MAX_DATA_BYTES} bytes" }
                w.u32(msg.seq); w.u8(msg.kind); w.u8(0); w.u16(msg.data.size); w.bytes(msg.data.value)
            }
            is Bye -> w.u8(msg.reason)
            is StreamPrefs -> { w.u16(msg.fps); w.u16(msg.scalePermille); w.u32(0) }
            is Pen -> {
                require(msg.tool == Pen.TOOL_PEN || msg.tool == Pen.TOOL_ERASER) { "invalid tool" }
                require(msg.samples.size in 1..Limits.PEN_MAX_SAMPLES) { "sample count must be 1..64" }
                var prev = 0L
                w.u8(msg.tool); w.u8(msg.samples.size); w.u16(0)
                w.u64(msg.baseTimeUs)
                for (s in msg.samples) {
                    require(s.dtUs >= prev) { "dt_us must not decrease" }
                    prev = s.dtUs
                    w.u32(s.dtUs); w.u16(s.x); w.u16(s.y); w.u16(s.pressure)
                    w.i16(s.tiltX); w.i16(s.tiltY); w.u8(s.flags); w.u8(0)
                }
            }
            is Key -> {
                require(msg.action == Key.UP || msg.action == Key.DOWN) { "invalid action" }
                w.u64(msg.timeUs); w.u16(msg.scanCode); w.u16(msg.androidKeyCode)
                w.u8(msg.action); w.u8(msg.lockState); w.u16(0)
            }
            is PointerRel -> {
                w.u64(msg.timeUs); w.f32(msg.dx); w.f32(msg.dy)
                w.u8(msg.buttons); w.u8(0); w.u16(0)
            }
            is PointerAbs -> {
                requireEnum(msg.source, 0..1, "POINTER_ABS.source")
                w.u64(msg.timeUs); w.u16(msg.x); w.u16(msg.y)
                w.u8(msg.buttons); w.u8(msg.source); w.u16(0)
            }
            is Scroll -> {
                requireEnum(msg.phase, 0..4, "SCROLL.phase")
                w.u64(msg.timeUs); w.f32(msg.dx); w.f32(msg.dy)
                w.u8(msg.phase); w.u8(0); w.u16(0)
            }
            is Pinch -> {
                requireEnum(msg.phase, 1..4, "PINCH.phase")
                requireEnum(msg.source, 0..1, "PINCH.source")
                w.u64(msg.timeUs); w.f32(msg.scale); w.u16(msg.x); w.u16(msg.y)
                w.u8(msg.phase); w.u8(msg.source); w.u16(0)
            }
            is PenGesture -> { w.u64(msg.timeUs); w.u8(msg.gesture); w.u8(0); w.u16(0) }
            is ReleaseAll -> w.u8(msg.reason)
            is Ping -> { w.u32(msg.seq); w.u64(msg.senderTimeUs) }
            is Pong -> { w.u32(msg.seq); w.u64(msg.echoTimeUs); w.u64(msg.responderTimeUs) }
            is Stats -> {
                w.u32(msg.intervalMs); w.u32(msg.framesReceived); w.u32(msg.framesDecoded)
                w.u32(msg.framesRendered); w.u32(msg.framesDropped)
                w.u32(msg.decodeTimeAvgUs); w.u32(msg.latencyAvgUs); w.u32(msg.bytesReceived)
            }
            is KeyframeRequest -> w.u8(msg.reason)
            is VideoHello -> {
                require(msg.videoNonce.size == Limits.NONCE_BYTES) { "video_nonce must be 16 bytes" }
                w.u16(msg.protocolVersion); w.u16(msg.configId); w.u32(msg.sessionId)
                w.bytes(msg.videoNonce.value)
            }
            is VideoFrame -> {
                require(msg.fragmentIndex == 0 && msg.fragmentCount == 1 && msg.frameSize == msg.data.size.toLong()) {
                    "VIDEO_FRAME must be a single fragment with frame_size == data length"
                }
                w.u32(msg.frameSeq); w.u64(msg.captureTimeUs); w.u8(msg.flags); w.u8(0)
                w.u16(msg.fragmentIndex); w.u16(msg.fragmentCount); w.u16(0)
                w.u32(msg.frameSize); w.bytes(msg.data.value)
            }
        }
        return w.toByteArray()
    }

    /**
     * Decodes one payload of a known [type]. Returns null for an unknown type (caller skips it).
     * Longer-than-expected payloads are accepted and the excess ignored; shorter ones throw.
     */
    fun decodePayload(type: Int, payload: ByteArray): Message? {
        val r = Reader(payload)
        return when (type) {
            MsgType.HELLO -> Hello(
                protocolVersion = r.u16(),
                deviceId = Bytes(r.bytes(Limits.DEVICE_ID_BYTES)),
                screenWidthPx = r.u16(), screenHeightPx = r.u16(),
                densityDpi = r.u16(), maxRefreshHz = r.u16(),
                capabilities = r.u32(),
                deviceName = r.str8(),
                clientNonce = Bytes(r.bytes(Limits.NONCE_BYTES)),
                clientEphPub = Bytes(r.bytes(Limits.EPH_PUB_BYTES)),
            )
            MsgType.HELLO_ACK -> {
                val version = r.u16(); val status = r.u8(); r.skip(1)
                checkEnum(status, 0..4, "HELLO_ACK.status")
                val sessionId = r.u32(); val videoPort = r.u16(); val hostName = r.str8()
                val keyMode = r.u8()
                checkEnum(keyMode, 0..2, "HELLO_ACK.key_mode")
                HelloAck(
                    version, status, sessionId, videoPort, hostName, keyMode,
                    hostId = Bytes(r.bytes(Limits.DEVICE_ID_BYTES)),
                    hostNonce = Bytes(r.bytes(Limits.NONCE_BYTES)),
                    hostEphPub = Bytes(r.bytes(Limits.EPH_PUB_BYTES)),
                )
            }
            MsgType.STREAM_CONFIG -> {
                val configId = r.u16(); val codec = r.u8(); r.skip(1)
                checkEnum(codec, 1..2, "STREAM_CONFIG.codec")
                StreamConfig(
                    configId, codec,
                    widthPx = r.u16(), heightPx = r.u16(), widthPt = r.u16(), heightPt = r.u16(),
                    fps = r.u16(), bitrateKbps = r.u32(),
                    colorPrimaries = r.u8(), transfer = r.u8(), matrix = r.u8(), fullRange = r.u8(),
                )
            }
            MsgType.CLIPBOARD -> {
                val seq = r.u32(); val kind = r.u8(); r.skip(1); val len = r.u16()
                Clipboard(seq, kind, Bytes(r.bytes(len)))
            }
            MsgType.BYE -> Bye(r.u8())
            MsgType.STREAM_PREFS -> { val fps = r.u16(); val pm = r.u16(); r.skip(4); StreamPrefs(fps, pm) }
            MsgType.PEN -> decodePen(r)
            MsgType.KEY -> {
                val time = r.u64(); val scan = r.u16(); val code = r.u16()
                val action = r.u8(); val lock = r.u8(); r.skip(2)
                if (action != Key.UP && action != Key.DOWN) {
                    throw ProtocolException(ProtocolException.Kind.INVALID_VALUE, "invalid key action")
                }
                Key(time, scan, code, action, lock)
            }
            MsgType.POINTER_REL -> {
                val time = r.u64(); val dx = r.f32(); val dy = r.f32(); val buttons = r.u8(); r.skip(3)
                PointerRel(time, dx, dy, buttons)
            }
            MsgType.POINTER_ABS -> {
                val time = r.u64(); val x = r.u16(); val y = r.u16(); val buttons = r.u8(); val source = r.u8(); r.skip(2)
                checkEnum(source, 0..1, "POINTER_ABS.source")
                PointerAbs(time, x, y, buttons, source)
            }
            MsgType.SCROLL -> {
                val time = r.u64(); val dx = r.f32(); val dy = r.f32(); val phase = r.u8(); r.skip(3)
                checkEnum(phase, 0..4, "SCROLL.phase")
                Scroll(time, dx, dy, phase)
            }
            MsgType.PINCH -> {
                val time = r.u64(); val scale = r.f32(); val x = r.u16(); val y = r.u16()
                val phase = r.u8(); val source = r.u8(); r.skip(2)
                checkEnum(phase, 1..4, "PINCH.phase")
                checkEnum(source, 0..1, "PINCH.source")
                Pinch(time, scale, x, y, phase, source)
            }
            MsgType.PEN_GESTURE -> {
                val time = r.u64(); val gesture = r.u8(); r.skip(3)
                PenGesture(time, gesture)
            }
            MsgType.RELEASE_ALL -> ReleaseAll(r.u8())
            MsgType.PING -> Ping(r.u32(), r.u64())
            MsgType.PONG -> Pong(r.u32(), r.u64(), r.u64())
            MsgType.STATS -> Stats(r.u32(), r.u32(), r.u32(), r.u32(), r.u32(), r.u32(), r.u32(), r.u32())
            MsgType.KEYFRAME_REQUEST -> KeyframeRequest(r.u8())
            MsgType.VIDEO_HELLO -> VideoHello(r.u16(), r.u16(), r.u32(), Bytes(r.bytes(Limits.NONCE_BYTES)))
            MsgType.VIDEO_FRAME -> {
                val seq = r.u32(); val capture = r.u64(); val flags = r.u8(); r.skip(1)
                val index = r.u16(); val count = r.u16(); r.skip(2)
                val size = r.u32()
                // TCP v0: single fragment; data is exactly frame_size bytes.
                if (index != 0 || count != 1) {
                    throw ProtocolException(ProtocolException.Kind.INVALID_VALUE, "bad video fragment fields")
                }
                if (size > r.remaining()) {
                    throw ProtocolException(ProtocolException.Kind.SHORT_PAYLOAD, "video data shorter than frame_size")
                }
                val data = r.bytes(size.toInt()) // exactly frame_size bytes; trailing bytes are future fields
                VideoFrame(seq, capture, flags, index, count, size, Bytes(data))
            }
            else -> null
        }
    }

    private fun decodePen(r: Reader): Pen {
        val tool = r.u8(); val count = r.u8(); r.skip(2)
        val base = r.u64()
        if (tool != Pen.TOOL_PEN && tool != Pen.TOOL_ERASER) {
            throw ProtocolException(ProtocolException.Kind.INVALID_VALUE, "invalid pen tool $tool")
        }
        if (count < 1 || count > Limits.PEN_MAX_SAMPLES) {
            throw ProtocolException(ProtocolException.Kind.INVALID_VALUE, "invalid pen count $count")
        }
        var prev = 0L
        val samples = ArrayList<PenSample>(count)
        repeat(count) {
            val dt = r.u32()
            if (dt < prev) {
                throw ProtocolException(ProtocolException.Kind.DECREASING_TIME, "pen dt_us decreased")
            }
            prev = dt
            val x = r.u16(); val y = r.u16(); val pressure = r.u16()
            val tx = r.i16().coerceAtLeast(-32767) // -32768 counts as -32767 (section 1)
            val ty = r.i16().coerceAtLeast(-32767)
            val flags = r.u8(); r.skip(1)
            samples += PenSample(dt, x, y, pressure, tx, ty, flags)
        }
        return Pen(tool, base, samples)
    }
}
