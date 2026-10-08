package dev.matebridge.client.protocol

/*
 * Message model for docs/PROTOCOL.md v1. Pure Kotlin, no Android dependencies.
 *
 * Integer mapping (all little-endian on the wire):
 *   u8, u16, i16 -> Int      u32 -> Long (0..4294967295)      u64 -> Long (unsigned bit pattern;
 *   timestamps fit comfortably in the positive range, so no unsigned arithmetic is needed).
 * Reserved fields are not modelled: encoders write 0, decoders ignore them.
 * Enum-like fields (status, reason, codec, phase...) stay raw Ints so that values added by a newer
 * peer do not break decoding; constants are provided for the known ones.
 * Privacy: Key (and Hello.deviceName) must not be logged; key codes only at debug level.
 */

sealed interface Message {
    /** Wire type byte (PROTOCOL.md section 4). */
    val type: Int
}

object MsgType {
    const val HELLO = 0x01
    const val HELLO_ACK = 0x02
    const val STREAM_CONFIG = 0x03
    const val BYE = 0x04
    const val STREAM_PREFS = 0x05
    const val CLIPBOARD = 0x06
    const val DISPLAY_RATE = 0x07
    const val SETTINGS_OPEN = 0x08
    const val FILES_INFO = 0x09
    const val FILES_NET = 0x0A
    const val CURSOR_PREFS = 0x0B
    const val CURSOR_SHAPE = 0x0C
    const val CURSOR_STATE = 0x0D
    const val PEN = 0x10
    const val KEY = 0x11
    const val POINTER_REL = 0x12
    const val POINTER_ABS = 0x13
    const val SCROLL = 0x14
    const val PEN_GESTURE = 0x15
    const val RELEASE_ALL = 0x16
    const val PINCH = 0x17
    const val PING = 0x20
    const val PONG = 0x21
    const val STATS = 0x22
    const val KEYFRAME_REQUEST = 0x23
    const val AUDIO_PREFS = 0x30
    const val AUDIO_CONFIG = 0x31
    const val AUDIO_FRAME = 0x32
    const val VIDEO_HELLO = 0x40
    const val VIDEO_FRAME = 0x41
    const val FILES_HELLO = 0x50
    const val FILES_HELLO_ACK = 0x51
    const val FILES_DATA = 0x52
}

object Limits {
    const val CONTROL_MAX_PAYLOAD = 65_536
    const val VIDEO_MAX_PAYLOAD = 16_777_216
    const val STR8_MAX_BYTES = 64
    const val PEN_MAX_SAMPLES = 64
    const val DEVICE_ID_BYTES = 16
    const val NONCE_BYTES = 16
    const val EPH_PUB_BYTES = 65
    const val PROTOCOL_VERSION = 1
}

/** Byte array wrapper with content equality, so messages holding raw bytes compare sensibly. */
class Bytes(val value: ByteArray) {
    val size: Int get() = value.size
    override fun equals(other: Any?) = other is Bytes && value.contentEquals(other.value)
    override fun hashCode() = value.contentHashCode()
    override fun toString() = "Bytes(${value.size})"
}

object Capabilities {
    const val PEN = 1 shl 0
    const val PEN_HOVER = 1 shl 1
    const val PEN_TILT = 1 shl 2
    const val KEYBOARD = 1 shl 3
    const val TOUCHPAD = 1 shl 4
    const val TOUCH = 1 shl 5
    const val DECODE_H264 = 1 shl 6
    const val DECODE_HEVC = 1 shl 7

    /** Handles the audio messages (0x30-0x32) and plays PCM s16le 48 kHz stereo (T-095; off with `--ez audio false`). */
    const val AUDIO_PCM = 1 shl 8

    /** Opens the settings panel while streaming and handles SETTINGS_OPEN (decision 0013, sent since T-105). */
    const val SETTINGS_PANEL = 1 shl 9

    /** Can run the tablet-files WebDAV server and sends FILES_INFO (decision 0015, T-135). */
    const val FILES = 1 shl 10

    /** Handles `chroma_layout = 1` (two streams, `VIDEO_FRAME.view`) and passed the capability self-test (decision 0034, T-259). */
    const val FULL_CHROMA = 1 shl 11

    /** Sends `FILES_INFO` STANDBY, handles `FILES_NET` and opens encrypted file connections on Wi-Fi (decision 0035, T-269). */
    const val FILES_NET = 1 shl 12

    /** Draws the cursor itself: sends `CURSOR_PREFS`, handles `CURSOR_SHAPE` and `CURSOR_STATE` (decision 0036, T-276). */
    const val LOCAL_CURSOR = 1 shl 13
}

// ---- Session ----

data class Hello(
    val protocolVersion: Int,
    val deviceId: Bytes, // exactly 16 bytes
    val screenWidthPx: Int,
    val screenHeightPx: Int,
    val densityDpi: Int,
    val maxRefreshHz: Int,
    val capabilities: Long, // u32
    val deviceName: String, // never log
    /** Fresh random value per connection (section 9). The session controller fills it; templates may leave the zero default. */
    val clientNonce: Bytes = Bytes(ByteArray(Limits.NONCE_BYTES)),
    /** Ephemeral P-256 public key, uncompressed (0x04 || X || Y). */
    val clientEphPub: Bytes = Bytes(ByteArray(Limits.EPH_PUB_BYTES)),
) : Message {
    override val type get() = MsgType.HELLO
}

data class HelloAck(
    val protocolVersion: Int,
    val status: Int,
    val sessionId: Long, // u32
    val videoPort: Int,
    val hostName: String,
    val keyMode: Int = KEY_NONE,
    val hostId: Bytes = Bytes(ByteArray(Limits.DEVICE_ID_BYTES)),
    val hostNonce: Bytes = Bytes(ByteArray(Limits.NONCE_BYTES)),
    val hostEphPub: Bytes = Bytes(ByteArray(Limits.EPH_PUB_BYTES)),
) : Message {
    override val type get() = MsgType.HELLO_ACK

    companion object {
        const val KEY_NONE = 0
        const val KEY_PAIRED = 1
        const val KEY_PAIRING = 2

        const val ACCEPTED = 0
        const val PENDING_APPROVAL = 1
        const val REJECTED = 2
        const val VERSION_MISMATCH = 3
        const val BUSY = 4
    }
}

data class StreamConfig(
    val configId: Int,
    val codec: Int,
    val widthPx: Int,
    val heightPx: Int,
    val widthPt: Int,
    val heightPt: Int,
    val fps: Int,
    val bitrateKbps: Long, // u32
    val colorPrimaries: Int,
    val transfer: Int,
    val matrix: Int,
    val fullRange: Int,
    /** Decision 0034: `0` normal single 4:2:0 stream, `1` packed full colour (main + auxiliary streams). Other values: treat as 0. */
    val chromaLayout: Int = CHROMA_LAYOUT_420,
) : Message {
    override val type get() = MsgType.STREAM_CONFIG

    /** True only for the known packed layout; unknown values behave as 0 (PROTOCOL.md 0x03). */
    val isPacked444: Boolean get() = chromaLayout == CHROMA_LAYOUT_PACKED_444

    /** Decision 0032: the host applied HDR10 (PQ transfer); anything else is SDR (PROTOCOL.md 0x03). */
    val isHdr10: Boolean get() = transfer == TRANSFER_PQ

    companion object {
        const val CODEC_H264 = 1
        const val CODEC_HEVC = 2
        const val CHROMA_LAYOUT_420 = 0
        const val CHROMA_LAYOUT_PACKED_444 = 1

        /** H.273 codes of an HDR10 stream (decision 0032): BT.2020 primaries, SMPTE ST 2084 (PQ), BT.2020 NCL matrix. */
        const val PRIMARIES_BT2020 = 9
        const val TRANSFER_PQ = 16
        const val MATRIX_BT2020_NCL = 9
    }
}

/**
 * Client display-mode request (C to H, PROTOCOL.md 0x05): stream [fps] (60/120/144), encoded size in permille of the
 * display, and the user's target [bitrateKbps] (u32, decision 0013; 0 = host default for the mode).
 * [displayWidthPx]/[displayHeightPx] are the optional trailing group (decision 0029, "game display"): the requested 1x
 * virtual display size in pixels; 0x0 = the native display. Absent on the wire = 0x0; encoded only when either is
 * non-zero or when the dynamic range group follows (PROTOCOL.md 2, optional trailing group).
 * [dynamicRange] is the second optional group (decision 0032): [DYNAMIC_RANGE_SDR] or [DYNAMIC_RANGE_HDR10]; absent on
 * the wire = SDR; encoded only when non-zero (with the display group before it, 0x0 allowed). A decoded unknown value is
 * kept as is (the host treats it as SDR).
 */
data class StreamPrefs(
    val fps: Int,
    val scalePermille: Int,
    val bitrateKbps: Long = 0,
    val displayWidthPx: Int = 0,
    val displayHeightPx: Int = 0,
    val dynamicRange: Int = DYNAMIC_RANGE_SDR,
    /**
     * Decision 0033: `0` normal 4:2:0, `1` sharp colour edges (host luma-adjusted 4:2:0), `2` packed full colour
     * (decision 0034, [CHROMA_FULL]). Same group as [dynamicRange].
     */
    val chroma: Int = CHROMA_NORMAL,
) : Message {
    override val type get() = MsgType.STREAM_PREFS

    companion object {
        const val DYNAMIC_RANGE_SDR = 0
        const val DYNAMIC_RANGE_HDR10 = 1
        const val CHROMA_NORMAL = 0
        const val CHROMA_SHARP = 1

        /** Decision 0034: packed full colour (only sent in Gunluk 60, native display, SDR, capability passed). */
        const val CHROMA_FULL = 2
    }
}

/** Host asks the tablet to show its settings panel while streaming (H to C, PROTOCOL.md 0x08, decision 0013). */
data object SettingsOpen : Message {
    override val type get() = MsgType.SETTINGS_OPEN
}

/**
 * State of the tablet's WebDAV file server (C to H, PROTOCOL.md 0x09, decision 0015). [port] is the server's TCP port on
 * the tablet's 127.0.0.1 (0 when OFF or STANDBY); [token] is the HTTP auth password (32 lowercase hex chars, empty when
 * OFF or STANDBY). Unknown [state] values decode fine and mean OFF. STANDBY (decision 0035, only with HELLO bit12): Wi-Fi
 * session, sharing allowed, the server is off and waits for the Mac's `FILES_NET(OPEN)`. Never log [token]: [toString]
 * leaves it out.
 */
data class FilesInfo(val state: Int, val port: Int, val token: String) : Message {
    override val type get() = MsgType.FILES_INFO

    val ready: Boolean get() = state == STATE_READY

    override fun toString() = "FilesInfo(state=$state, port=$port, token=<${token.length} chars>)"

    companion object {
        const val STATE_OFF = 0
        const val STATE_READY = 1
        const val STATE_STANDBY = 2
        val OFF = FilesInfo(STATE_OFF, 0, "")
        val STANDBY = FilesInfo(STATE_STANDBY, 0, "")
    }
}

/**
 * The Mac opens or closes the tablet files over Wi-Fi (H to C, PROTOCOL.md 0x0A, decision 0035). [port] is the host's
 * file listener (OPEN), [pool] the idle file connections to keep ready, [max] the total limit; all 0 on CLOSE. An
 * unknown [state] counts as CLOSE ([isOpen] is true only for [STATE_OPEN]).
 */
data class FilesNet(val state: Int, val port: Int, val pool: Int, val max: Int) : Message {
    override val type get() = MsgType.FILES_NET

    val isOpen: Boolean get() = state == STATE_OPEN

    companion object {
        const val STATE_CLOSE = 0
        const val STATE_OPEN = 1
        const val POOL_MIN = 1
        const val POOL_MAX = 4
        const val MAX_MAX = 16
    }
}

/**
 * The client asks the host to stop drawing the cursor in the video and stream it instead (C to H, PROTOCOL.md 0x0B,
 * decision 0036). [enabled] true = the tablet draws it; false = the cursor stays in the video (the default of a session).
 */
data class CursorPrefs(val enabled: Boolean) : Message {
    override val type get() = MsgType.CURSOR_PREFS
}

/**
 * One cursor image (H to C, PROTOCOL.md 0x0C, decision 0036). Sizes and hotspot are in 1/16 Mac points. [format] 1 is PNG;
 * any other value decodes fine and counts as "unsupported" (the client draws its built-in arrow for that id).
 * [data] is 1..[MAX_DATA_BYTES] bytes. [toString] leaves the image out.
 */
data class CursorShape(
    val shapeId: Long, // u32, never 0
    val widthPt16: Int,
    val heightPt16: Int,
    val hotXPt16: Int,
    val hotYPt16: Int,
    val format: Int,
    val data: Bytes,
) : Message {
    override val type get() = MsgType.CURSOR_SHAPE

    override fun toString() = "CursorShape(id=$shapeId, ${widthPt16}x$heightPt16, format=$format, ${data.size} bytes)"

    companion object {
        const val FORMAT_PNG = 1
        const val MAX_DATA_BYTES = 61_440
    }
}

/**
 * The host's cursor right now (H to C, PROTOCOL.md 0x0D, decision 0036). [x]/[y]: hotspot in normalized video-surface
 * coordinates (PROTOCOL.md section 1). [hostTimeUs] is for measurement only. Positions are never logged.
 */
data class CursorState(
    val seq: Long, // u32
    val x: Int,
    val y: Int,
    val visible: Boolean,
    val shapeId: Long, // u32
    val hostTimeUs: Long,
) : Message {
    override val type get() = MsgType.CURSOR_STATE

    override fun toString() = "CursorState(seq=$seq, visible=$visible)"
}

/** First message of a file connection (C to H, plain; PROTOCOL.md 0x50). A fresh [clientFilesNonce] per connection. */
data class FilesHello(
    val protocolVersion: Int,
    val sessionId: Long, // u32
    val clientFilesNonce: Bytes,
) : Message {
    override val type get() = MsgType.FILES_HELLO
}

/** The host's answer on a file connection (H to C, plain; PROTOCOL.md 0x51). Any [status] other than [OK] counts as rejected. */
data class FilesHelloAck(val status: Int, val hostFilesNonce: Bytes) : Message {
    override val type get() = MsgType.FILES_HELLO_ACK

    val ok: Boolean get() = status == OK

    companion object {
        const val OK = 0
        const val REJECTED = 1
    }
}

/**
 * Opaque HTTP bytes of the paired local connection (both directions, PROTOCOL.md 0x52). [data] is 1..[MAX_DATA_BYTES]
 * bytes (an empty record is a protocol error). Never log [data].
 */
data class FilesData(val data: Bytes) : Message {
    override val type get() = MsgType.FILES_DATA

    companion object {
        /** The u16 size of a record is at most the payload limit minus its own two bytes. */
        const val MAX_DATA_BYTES = Limits.CONTROL_MAX_PAYLOAD - 2
    }
}

/** Current panel refresh rate of the tablet (C to H, PROTOCOL.md 0x07): [hz] rounded to an integer, 0 = unknown. */
data class DisplayRate(val hz: Int) : Message {
    override val type get() = MsgType.DISPLAY_RATE
}

/** Shared text clipboard (both directions, PROTOCOL.md 0x06). [data] holds UTF-8 text for [KIND_TEXT_UTF8], nothing for [KIND_EMPTY]. Never log [data]. */
data class Clipboard(val seq: Long, val kind: Int, val data: Bytes) : Message {
    override val type get() = MsgType.CLIPBOARD

    companion object {
        const val KIND_EMPTY = 0
        const val KIND_TEXT_UTF8 = 1
        const val MAX_DATA_BYTES = 60_000
    }
}

data class Bye(val reason: Int) : Message {
    override val type get() = MsgType.BYE

    companion object {
        const val NORMAL = 0
        const val PROTOCOL_ERROR = 1
        const val REJECTED = 2
        const val TIMEOUT = 3
        const val SHUTTING_DOWN = 4
        const val SUPERSEDED = 5
        /** The Mac is going to system sleep (PROTOCOL.md 0x04): no automatic reconnect or wake. */
        const val HOST_SLEEP = 6
    }
}

// ---- Input ----

data class PenSample(
    val dtUs: Long, // u32, offset from base time
    val x: Int, // u16 normalized
    val y: Int, // u16 normalized
    val pressure: Int, // u16
    val tiltX: Int, // i16, -32767..32767
    val tiltY: Int, // i16
    val flags: Int, // u8
) {
    companion object {
        const val IN_RANGE = 1
        const val CONTACT = 2
        const val BUTTON = 4
        const val STROKE_START = 8
    }
}

data class Pen(
    val tool: Int, // 0 PEN, 1 ERASER
    val baseTimeUs: Long,
    val samples: List<PenSample>, // 1..64, dtUs non-decreasing
) : Message {
    override val type get() = MsgType.PEN

    companion object {
        const val TOOL_PEN = 0
        const val TOOL_ERASER = 1
    }
}

data class Key(
    val timeUs: Long,
    val scanCode: Int,
    val androidKeyCode: Int,
    val action: Int, // 0 UP, 1 DOWN
    val lockState: Int,
) : Message {
    override val type get() = MsgType.KEY

    companion object {
        const val UP = 0
        const val DOWN = 1
        const val LOCK_CAPS = 1
    }
}

data class PointerRel(
    val timeUs: Long,
    val dx: Float,
    val dy: Float,
    val buttons: Int,
) : Message {
    override val type get() = MsgType.POINTER_REL
}

data class PointerAbs(
    val timeUs: Long,
    val x: Int,
    val y: Int,
    val buttons: Int,
    val source: Int, // 0 TOUCH, 1 MOUSE
) : Message {
    override val type get() = MsgType.POINTER_ABS

    companion object {
        const val SOURCE_TOUCH = 0
        const val SOURCE_MOUSE = 1
    }
}

object Buttons {
    const val LEFT = 1
    const val RIGHT = 2
    const val MIDDLE = 4
    const val BACK = 8
    const val FORWARD = 16
}

data class Scroll(
    val timeUs: Long,
    val dx: Float,
    val dy: Float,
    val phase: Int,
) : Message {
    override val type get() = MsgType.SCROLL

    companion object {
        const val NONE = 0
        const val BEGAN = 1
        const val CHANGED = 2
        const val ENDED = 3
        const val CANCELLED = 4
    }
}

/** Two-finger pinch (PROTOCOL.md section 4 PINCH). [scale] is relative to the previous PINCH message, clamped to [MIN_SCALE, MAX_SCALE]. */
data class Pinch(
    val timeUs: Long,
    val scale: Float,
    val x: Int,
    val y: Int,
    val phase: Int,
    val source: Int,
) : Message {
    override val type get() = MsgType.PINCH

    companion object {
        const val BEGAN = 1
        const val CHANGED = 2
        const val ENDED = 3
        const val CANCELLED = 4
        const val SOURCE_TOUCH = 0
        const val SOURCE_TOUCHPAD = 1
        const val MIN_SCALE = -0.5f
        const val MAX_SCALE = 1.0f
    }
}

data class PenGesture(val timeUs: Long, val gesture: Int) : Message {
    override val type get() = MsgType.PEN_GESTURE

    companion object {
        const val DOUBLE_TAP = 1
    }
}

data class ReleaseAll(val reason: Int) : Message {
    override val type get() = MsgType.RELEASE_ALL

    companion object {
        const val USER = 0
        const val BACKGROUND = 1
        const val FOCUS_LOST = 2
        const val DEVICE_DETACHED = 3
    }
}

// ---- Maintenance ----

data class Ping(val seq: Long, val senderTimeUs: Long) : Message {
    override val type get() = MsgType.PING
}

data class Pong(val seq: Long, val echoTimeUs: Long, val responderTimeUs: Long) : Message {
    override val type get() = MsgType.PONG
}

data class Stats(
    val intervalMs: Long,
    val framesReceived: Long,
    val framesDecoded: Long,
    val framesRendered: Long,
    val framesDropped: Long,
    val decodeTimeAvgUs: Long,
    val latencyAvgUs: Long,
    val bytesReceived: Long,
) : Message {
    override val type get() = MsgType.STATS
}

/**
 * [view] is the optional trailing byte (decision 0034): [VIEW_MAIN], [VIEW_AUX], [VIEW_BOTH]; [VIEW_UNSPECIFIED] = absent on
 * the wire (single stream, or an old peer). The client writes it only while `chroma_layout = 1`.
 */
data class KeyframeRequest(val reason: Int, val view: Int = VIEW_UNSPECIFIED) : Message {
    override val type get() = MsgType.KEYFRAME_REQUEST

    companion object {
        const val VIEW_UNSPECIFIED = -1
        const val VIEW_MAIN = 0
        const val VIEW_AUX = 1
        const val VIEW_BOTH = 2

        const val STARTUP = 0
        const val DECODE_ERROR = 1
        const val FRAMES_DROPPED = 2
    }
}

// ---- Audio (decision 0011) ----

/** Client audio request (C to H, PROTOCOL.md 0x30). On the wire any value other than 1 decodes as false. */
data class AudioPrefs(val enabled: Boolean) : Message {
    override val type get() = MsgType.AUDIO_PREFS
}

/**
 * Audio stream start/stop (H to C, PROTOCOL.md 0x31). [state] and [format] stay raw: unknown values decode
 * fine and the client ignores such a stream (not a protocol error).
 */
data class AudioConfig(
    val streamId: Int,
    val state: Int,
    val format: Int,
    val sampleRate: Long, // u32, Hz
    val channels: Int,
    val framesPerPacket: Int, // informational; every AUDIO_FRAME carries its own frame_count
) : Message {
    override val type get() = MsgType.AUDIO_CONFIG

    companion object {
        const val STATE_STOPPED = 0
        const val STATE_STARTED = 1
        const val FORMAT_PCM_S16LE = 1

        fun stopped(streamId: Int) = AudioConfig(streamId, STATE_STOPPED, 0, 0, 0, 0)
    }
}

/** One PCM packet (H to C, PROTOCOL.md 0x32). data_len on the wire is [data].size. Never log [data]. */
data class AudioFrame(
    val streamId: Int,
    val seq: Long, // u32
    val sampleIndex: Long, // u64, first frame's index in the stream
    val captureTimeUs: Long, // u64, host clock shared with VIDEO_FRAME.capture_time_us
    val frameCount: Int, // 1..960
    val data: Bytes,
) : Message {
    override val type get() = MsgType.AUDIO_FRAME

    companion object {
        /** stream_id, reserved, seq, sample_index, capture_time_us, frame_count, data_len. */
        const val FIXED_BYTES = 28
        const val MAX_FRAMES = 960
    }
}

// ---- Video ----

data class VideoHello(
    val protocolVersion: Int,
    val configId: Int,
    val sessionId: Long, // u32
    /** Fresh random value per video connection (section 9). The controller fills it; templates may leave the zero default. */
    val videoNonce: Bytes = Bytes(ByteArray(Limits.NONCE_BYTES)),
) : Message {
    override val type get() = MsgType.VIDEO_HELLO
}

data class VideoFrame(
    val frameSeq: Long, // u32
    val captureTimeUs: Long,
    val flags: Int,
    val fragmentIndex: Int,
    val fragmentCount: Int,
    val frameSize: Long, // u32
    val data: Bytes,
    /** Decision 0034: [VIEW_MAIN] or [VIEW_AUX]; any other value is unknown (the receiver skips the frame). */
    val view: Int = VIEW_MAIN,
) : Message {
    override val type get() = MsgType.VIDEO_FRAME

    val isKeyframe get() = flags and KEYFRAME != 0
    val isCodecConfig get() = flags and CODEC_CONFIG != 0

    companion object {
        const val KEYFRAME = 1
        const val CODEC_CONFIG = 2
        const val VIEW_MAIN = 0
        const val VIEW_AUX = 1
    }
}
