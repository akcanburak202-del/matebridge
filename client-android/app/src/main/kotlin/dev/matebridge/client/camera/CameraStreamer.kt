package dev.matebridge.client.camera

import dev.matebridge.client.files.WriteWatchdog
import dev.matebridge.client.security.SessionSecrets
import java.net.Socket
import java.security.SecureRandom
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledExecutorService
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong

/**
 * Camera to encoder to bytes: the Android implementation is `Camera2Pipeline` (Camera2 -> SurfaceTexture -> GL -> H.264
 * `MediaCodec` surface input). Everything the streamer needs is here, so it is JVM-tested with a fake. Contract:
 * [start] and [stop] never block the caller for long (the work happens on the pipeline's own threads) and [stop]
 * releases the camera, encoder and GL objects. The pipeline reports through [Sink] from its encoder thread.
 */
interface CameraPipeline {
    interface Sink {
        /** SPS/PPS as Annex-B. Called once at the start and again (same bytes) after a facing switch. */
        fun onConfig(data: ByteArray, captureTimeUs: Long)

        /** One encoded access unit (Annex-B), [captureTimeUs] the sensor timestamp. */
        fun onFrame(data: ByteArray, captureTimeUs: Long, keyframe: Boolean)

        /** The camera or encoder failed for good; the owner closes the pipeline. [reason] is a short code, never frame data. */
        fun onError(reason: String)
    }

    fun start(facing: CameraFacing, width: Int, height: Int, fps: Int, bitrateKbps: Int, sink: Sink)

    /** Opens the other camera; the encoder and its connection stay. The pipeline then re-announces the config and produces a keyframe. */
    fun switchFacing(facing: CameraFacing)

    /** The next encoded frame is a keyframe (`PARAMETER_KEY_REQUEST_SYNC_FRAME`). Any thread. */
    fun requestKeyframe()

    fun stop()
}

/** What the Mac asked for with a `CAMERA_CONTROL(START)` (PROTOCOL.md 0x0F). */
data class CameraPlan(val camId: Int, val port: Int, val width: Int, val height: Int, val fps: Int, val bitrateKbps: Long)

/** The session a camera belongs to: its control generation, the Mac's address, the session id and the key material. */
class CameraSessionCtx(val gen: Int, val host: String, val sessionId: Long, val secrets: SessionSecrets)

/** A running camera stream ([CameraStreamer]); the [CameraController] sees only this. */
interface CameraRun {
    /** Switches the camera while streaming; the connection and `cam_id` stay. */
    fun switchFacing(facing: CameraFacing)

    /** Closes the camera, encoder, GL, socket and threads now. Idempotent, never blocks on the network, any thread. */
    fun close(reason: String)
}

/** Creates and starts a [CameraRun]; [onGaveUp] is called (once, on a streamer thread) when the stream ended on its own. */
fun interface CameraRunFactory {
    fun start(plan: CameraPlan, ctx: CameraSessionCtx, facing: CameraFacing, onGaveUp: (CameraRun, String) -> Unit): CameraRun
}

/**
 * The tablet camera stream of one `cam_id` (decision 0040): a [CameraPipeline], the bounded [CamSendQueue] and the camera
 * connection with its retry rule (PROTOCOL.md "Kamera bağlantısı" 6: after a break the same `cam_id` is dialled again
 * with 1 s between tries, at most 3 times; then the camera is closed and a new START is awaited).
 *
 * Threads: the pipeline's, one link thread (connect, handshake, writer), one reader per connection, the write watchdog
 * and a stats scheduler; [close] ends all of them. Logs only counters (frames, bytes), never content.
 */
class CameraStreamer(
    private val plan: CameraPlan,
    private val ctx: CameraSessionCtx,
    private val facing: CameraFacing,
    private val pipeline: CameraPipeline,
    private val onGaveUp: (CameraRun, String) -> Unit,
    private val newSocket: () -> Socket = { Socket() },
    private val tune: (Socket) -> Unit = {},
    private val threadStarted: () -> Unit = {},
    private val log: (warn: Boolean, ev: String, fields: String) -> Unit = { _, _, _ -> },
    private val random: SecureRandom = SecureRandom(),
    private val nowMs: () -> Long = { System.nanoTime() / 1_000_000 },
    private val retryDelayMs: Long = RETRY_DELAY_MS,
    private val maxRetries: Int = MAX_RETRIES,
    private val statsIntervalMs: Long = STATS_INTERVAL_MS,
    private val writeTimeoutMs: Long = WRITE_TIMEOUT_MS,
    private val ackTimeoutMs: Int = CameraConnection.ACK_TIMEOUT_MS,
    private val connectTimeoutMs: Int = CameraConnection.CONNECT_TIMEOUT_MS,
) : CameraRun {
    private val queue = CamSendQueue()
    private val closed = AtomicBoolean(false)
    private val watchdog = WriteWatchdog(writeTimeoutMs)
    private val lock = Object()
    @Volatile private var current: CameraConnection? = null
    private var scheduler: ScheduledExecutorService? = null

    private val encoded = AtomicLong()
    private val encodedBytes = AtomicLong()
    private var lastEncoded = 0L
    private var lastBytes = 0L
    private var lastSent = 0L
    private var lastDropped = 0L
    @Volatile private var sentTotal = 0L

    private val sink = object : CameraPipeline.Sink {
        override fun onConfig(data: ByteArray, captureTimeUs: Long) {
            if (closed.get()) return
            queue.onConfig(data, captureTimeUs)
            pipeline.requestKeyframe() // the host needs a keyframe behind every config
        }

        override fun onFrame(data: ByteArray, captureTimeUs: Long, keyframe: Boolean) {
            if (closed.get()) return
            encoded.incrementAndGet()
            encodedBytes.addAndGet(data.size.toLong())
            if (queue.offer(data, captureTimeUs, keyframe) == CamSendQueue.Offer.DROPPED_NEED_KEYFRAME) pipeline.requestKeyframe()
        }

        override fun onError(reason: String) {
            if (closed.get()) return
            log(true, "camera", "state=error reason=$reason cam_id=${plan.camId}")
            giveUp("pipeline_$reason")
        }
    }

    /** Starts the pipeline, the link thread and the stats timer. Call once. */
    fun start(): CameraStreamer {
        log(false, "camera", "state=start reason=control cam_id=${plan.camId} size=${plan.width}x${plan.height} fps=${plan.fps} facing=${facing.id}")
        startThread("mb-cam-watchdog") { watchdog.runLoop() }
        startThread("mb-cam-link") { linkLoop() }
        val sched = Executors.newSingleThreadScheduledExecutor { r -> Thread(r, "mb-cam-stats").also { it.isDaemon = true } }
        scheduler = sched
        sched.scheduleWithFixedDelay({ statsLine() }, statsIntervalMs, statsIntervalMs, TimeUnit.MILLISECONDS)
        pipeline.start(facing, plan.width, plan.height, plan.fps, plan.bitrateKbps.coerceIn(100, Int.MAX_VALUE.toLong()).toInt(), sink)
        return this
    }

    private fun startThread(name: String, body: () -> Unit) {
        Thread({
            try { threadStarted() } catch (_: RuntimeException) {}
            body()
        }, name).also { it.isDaemon = true; it.start() }
    }

    override fun switchFacing(facing: CameraFacing) {
        if (closed.get()) return
        log(false, "camera", "state=switch cam_id=${plan.camId} facing=${facing.id}")
        queue.onKeyframeRequested()
        pipeline.switchFacing(facing)
    }

    private fun linkLoop() {
        var retries = 0
        while (!closed.get()) {
            val conn = CameraConnection(
                ctx.host, plan.port, ctx.sessionId, plan.camId, ctx.secrets, queue, watchdog,
                onKeyframeRequest = { reason ->
                    log(false, "camera", "state=keyframe_request cam_id=${plan.camId} reason=$reason")
                    pipeline.requestKeyframe()
                },
                onProven = {
                    log(false, "camera", "state=link_up cam_id=${plan.camId}")
                    pipeline.requestKeyframe() // STARTUP: the first frame the host sees must be a keyframe
                },
                newSocket = newSocket, tune = tune, threadStarted = threadStarted, random = random, nowMs = nowMs,
                ackTimeoutMs = ackTimeoutMs, connectTimeoutMs = connectTimeoutMs,
            )
            current = conn
            if (closed.get()) { conn.close(); break }
            val out = conn.run()
            sentTotal += conn.sentFrames()
            current = null
            if (closed.get()) break
            log(out.proven.not(), "camera", "state=link_down cam_id=${plan.camId} reason=${out.reason} up_ms=${out.provenMs}")
            if (out.terminal) { giveUp("link_${out.reason}"); return }
            if (out.provenMs >= STABLE_MS) retries = 0
            if (retries >= maxRetries) { giveUp("link_lost"); return }
            retries++
            log(false, "camera", "state=retry cam_id=${plan.camId} n=$retries")
            synchronized(lock) {
                val until = nowMs() + retryDelayMs
                while (!closed.get() && nowMs() < until) lock.wait(maxOf(1L, until - nowMs()))
            }
        }
    }

    private fun giveUp(reason: String) {
        if (closed.get()) return
        close(reason)
        onGaveUp(this, reason)
    }

    override fun close(reason: String) {
        if (!closed.compareAndSet(false, true)) return
        statsLine(final = true)
        log(false, "camera", "state=stop reason=$reason cam_id=${plan.camId}")
        current?.close()
        queue.close()
        try { pipeline.stop() } catch (_: RuntimeException) {}
        watchdog.stop()
        try { scheduler?.shutdownNow() } catch (_: RuntimeException) {}
        synchronized(lock) { lock.notifyAll() }
    }

    /** The 10 s summary: encoded, sent and dropped frames and the mean encoded frame size. Never frame content. */
    @Synchronized
    private fun statsLine(final: Boolean = false) {
        val enc = encoded.get()
        val bytes = encodedBytes.get()
        val sent = sentTotal + (current?.sentFrames() ?: 0)
        val dropped = queue.counters().second
        val dEnc = enc - lastEncoded
        val avg = if (dEnc > 0) (bytes - lastBytes) / dEnc else 0
        log(
            false, "camera_stats",
            "cam_id=${plan.camId} encoded=$dEnc sent=${sent - lastSent} dropped=${dropped - lastDropped} avg_bytes=$avg" +
                if (final) " final=1 total_encoded=$enc total_sent=$sent total_dropped=$dropped" else "",
        )
        lastEncoded = enc
        lastBytes = bytes
        lastSent = sent
        lastDropped = dropped
    }

    companion object {
        const val RETRY_DELAY_MS = 1_000L
        const val MAX_RETRIES = 3
        const val STATS_INTERVAL_MS = 10_000L
        const val WRITE_TIMEOUT_MS = 5_000L

        /** A connection that carried the stream at least this long resets the retry count. */
        const val STABLE_MS = 5_000L
    }
}
