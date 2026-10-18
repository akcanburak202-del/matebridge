package dev.matebridge.client.camera

import dev.matebridge.client.files.WriteWatchdog
import dev.matebridge.client.protocol.Bytes
import dev.matebridge.client.protocol.CamFrame
import dev.matebridge.client.protocol.CamHello
import dev.matebridge.client.protocol.CamHelloAck
import dev.matebridge.client.protocol.CamKeyframeRequest
import dev.matebridge.client.protocol.Codec
import dev.matebridge.client.protocol.Limits
import dev.matebridge.client.protocol.MsgType
import dev.matebridge.client.protocol.Ping
import dev.matebridge.client.protocol.ProtocolException
import dev.matebridge.client.security.CameraChannel
import dev.matebridge.client.security.PlainFrames
import dev.matebridge.client.security.SessionSecrets
import java.io.IOException
import java.net.InetSocketAddress
import java.net.Socket
import java.security.SecureRandom
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong

/**
 * What a camera connection ended with. [proven]: the handshake and the key proof went through (the connection carried the
 * stream for [provenMs]); [terminal]: retrying is pointless (the host refused it).
 */
class CameraConnectionOutcome(val reason: String, val proven: Boolean, val provenMs: Long, val terminal: Boolean)

/**
 * One encrypted camera connection (PROTOCOL.md "Kamera bağlantısı", decision 0040), client side. [run] blocks the calling
 * thread (the streamer's link thread) through the whole life of the connection:
 *
 * connect -> plain `CAM_HELLO` -> plain `CAM_HELLO_ACK` within [ackTimeoutMs] -> keys from the session's `prk` and the two
 * fresh nonces -> sealed `PING` as proof -> frames taken from the [queue] (config first, then keyframe, then frames) until
 * the connection ends. A reader thread handles `CAM_KEYFRAME_REQUEST`; any other known type from the host (`PING` aside)
 * closes the connection. No `PONG` is expected or sent. Writes are bracketed by a [WriteWatchdog] watch, so a host that
 * stops reading does not block the writer for ever. Frame contents are never logged.
 */
class CameraConnection(
    private val host: String,
    private val port: Int,
    private val sessionId: Long,
    private val camId: Int,
    private val secrets: SessionSecrets,
    private val queue: CamSendQueue,
    private val watchdog: WriteWatchdog,
    /** Called (reader thread) with the reason of every host keyframe request; the owner asks the encoder. */
    private val onKeyframeRequest: (Int) -> Unit,
    /** Called once when the proof went out and the queue was activated (link thread). */
    private val onProven: () -> Unit = {},
    private val newSocket: () -> Socket = { Socket() },
    private val tune: (Socket) -> Unit = {},
    private val threadStarted: () -> Unit = {},
    private val random: SecureRandom = SecureRandom(),
    private val nowUs: () -> Long = { System.nanoTime() / 1000 },
    private val nowMs: () -> Long = { System.nanoTime() / 1_000_000 },
    private val ackTimeoutMs: Int = ACK_TIMEOUT_MS,
    private val connectTimeoutMs: Int = CONNECT_TIMEOUT_MS,
) {
    private val socket: Socket = newSocket()
    private val closing = AtomicBoolean(false)
    @Volatile private var ended = false
    @Volatile private var stalled = false

    private val sentFrames = AtomicLong()
    private val sentBytes = AtomicLong()

    /** Frames (config excluded) and bytes written on this connection. */
    fun sentFrames(): Long = sentFrames.get()
    fun sentBytes(): Long = sentBytes.get()

    private val watch = watchdog.Watch {
        stalled = true
        shutdownSocket()
    }

    /** Closes the socket (idempotent, any thread) and ends [run] shortly after; the caller asked for it. */
    fun close() {
        closing.set(true)
        shutdownSocket()
    }

    private fun shutdownSocket() {
        try { socket.close() } catch (_: IOException) {}
    }

    fun run(): CameraConnectionOutcome {
        var proven = false
        var provenAt = 0L
        var reason = "error"
        var terminal = false
        try {
            socket.connect(InetSocketAddress(host, port), connectTimeoutMs)
            socket.tcpNoDelay = true
            tune(socket)
            if (closing.get()) return CameraConnectionOutcome("closed", false, 0, false)
            val out = socket.getOutputStream()
            val input = socket.getInputStream()
            val clientNonce = ByteArray(Limits.NONCE_BYTES).also { random.nextBytes(it) }
            out.write(Codec.encode(CamHello(Limits.PROTOCOL_VERSION, sessionId, camId, Bytes(clientNonce))))
            out.flush()
            socket.soTimeout = ackTimeoutMs
            val frame = try {
                PlainFrames.read(input)
            } catch (e: java.net.SocketTimeoutException) {
                return CameraConnectionOutcome("ack_timeout", false, 0, false)
            }
            socket.soTimeout = 0
            if (frame.type != MsgType.CAM_HELLO_ACK) throw ProtocolException(ProtocolException.Kind.INVALID_VALUE, "first host message is not CAM_HELLO_ACK")
            val ack = Codec.decodePayload(frame.type, frame.payload) as CamHelloAck
            if (!ack.ok) return CameraConnectionOutcome("rejected", false, 0, true)
            val channel = CameraChannel(secrets.cameraKeys(clientNonce, ack.hostCamNonce.value))
            // The proof: the first sealed record is a PING (the host answers no PING here).
            guardedWrite(out, channel.sealer.sealFrame(Codec.encode(Ping(0, nowUs()))))
            proven = true
            provenAt = nowMs()
            queue.setActive(true)
            onProven()
            startReader(channel, input)
            reason = writeLoop(channel, out)
        } catch (e: ProtocolException) {
            reason = "protocol"
        } catch (e: IllegalStateException) {
            reason = "keys_gone" // the session's secrets were wiped: the session is over
            terminal = true
        } catch (e: IOException) {
            reason = when {
                stalled -> "write_stall"
                closing.get() -> "closed"
                else -> "io"
            }
        } catch (e: RuntimeException) {
            reason = "error"
        } finally {
            ended = true
            if (proven) queue.setActive(false)
            shutdownSocket()
        }
        return CameraConnectionOutcome(reason, proven, if (proven) nowMs() - provenAt else 0, terminal)
    }

    private fun guardedWrite(out: java.io.OutputStream, bytes: ByteArray) {
        watch.begin()
        try {
            out.write(bytes)
            out.flush()
        } finally {
            watch.end()
        }
    }

    private fun writeLoop(channel: CameraChannel, out: java.io.OutputStream): String {
        var seq = 0L
        while (!closing.get() && !ended) {
            val unit = queue.take(POLL_MS) ?: continue
            unit.config?.let { cfg ->
                val rec = channel.sealer.seal(MsgType.CAM_FRAME, Codec.encodePayload(CamFrame(seq++, unit.configTimeUs, CamFrame.CODEC_CONFIG, Bytes(cfg))))
                guardedWrite(out, rec)
            }
            val flags = if (unit.keyframe) CamFrame.KEYFRAME else 0
            val rec = channel.sealer.seal(MsgType.CAM_FRAME, Codec.encodePayload(CamFrame(seq++, unit.captureTimeUs, flags, Bytes(unit.data))))
            guardedWrite(out, rec)
            sentFrames.incrementAndGet()
            sentBytes.addAndGet(unit.data.size.toLong())
        }
        return if (closing.get()) "closed" else "host_eof"
    }

    @Volatile private var reader: Thread? = null

    private fun startReader(channel: CameraChannel, input: java.io.InputStream) {
        val t = Thread({
            try { threadStarted() } catch (_: RuntimeException) {}
            val buf = ByteArray(4096)
            try {
                while (true) {
                    val n = input.read(buf)
                    if (n < 0) break
                    channel.decoder.feed(buf, 0, n)
                    while (true) {
                        val msg = channel.decoder.next() ?: break
                        when (msg) {
                            is CamKeyframeRequest -> {
                                queue.onKeyframeRequested()
                                onKeyframeRequest(msg.reason)
                            }
                            is Ping -> Unit // no PONG on a camera connection
                            else -> throw ProtocolException(ProtocolException.Kind.INVALID_VALUE, "unexpected message type ${msg.type} on the camera connection")
                        }
                    }
                }
            } catch (_: IOException) {
            } catch (_: ProtocolException) {
            } catch (_: RuntimeException) {
            }
            ended = true // the writer notices within one poll
            shutdownSocket()
        }, "mb-cam-read")
        t.isDaemon = true
        reader = t
        t.start()
    }

    companion object {
        const val ACK_TIMEOUT_MS = 5_000
        const val CONNECT_TIMEOUT_MS = 5_000
        const val POLL_MS = 250L
    }
}
