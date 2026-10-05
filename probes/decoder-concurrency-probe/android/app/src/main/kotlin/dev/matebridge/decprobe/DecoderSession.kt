package dev.matebridge.decprobe

import android.hardware.HardwareBuffer
import android.media.ImageReader
import android.media.MediaCodec
import android.media.MediaFormat
import android.os.Handler
import android.os.HandlerThread
import java.nio.ByteBuffer
import java.util.ArrayDeque
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/** A loaded clip: the file bytes, its access units and its csd-0. */
class LoadedClip(val file: ClipFile, val data: ByteArray) {
    val units: List<AnnexB.Unit> = AnnexB.accessUnits(data)
    val csd: ByteArray? = AnnexB.codecConfig(data)
    val maxUnit: Int = units.maxOfOrNull { it.length } ?: 0
    /** IRAP flag per access unit. */
    val idr: BooleanArray = AnnexB.irapFlags(data, units)
}

/**
 * One MediaCodec decoder in asynchronous mode on its own HandlerThread, looping [clip] from its IDR.
 *
 * Output: `image` renders every frame into an ImageReader (PRIVATE, GPU-sampled usage, like a SurfaceView buffer)
 * whose images are closed at once; `buffer` configures no surface and releases each output buffer unrendered.
 * Feeding: [paceFps] 0 = flood (every free input buffer is filled at once: maximum throughput); > 0 = one access
 * unit per tick (per-frame decode time at a stream rate; a tick that finds the previous one still owed counts as
 * missed). All state below is touched only on the session thread.
 */
class DecoderSession(
    private val index: Int,
    private val clip: LoadedClip,
    private val codecName: String,
    private val output: String,
    private val paceFps: Int,
    /** ImageReader pixel format of the `image` output (see [ImgFormat]). */
    private val imgFormat: Int,
    /** 10-bit clips: also tell the decoder the profile and the BT.2020 / PQ colour description. */
    private val colorKeys: Boolean,
    private val priority: Int?,
    private val operatingRate: Int?,
    private val log: (String) -> Unit,
) {
    private val thread = HandlerThread("decprobe-$index").also { it.start() }
    private val handler = Handler(thread.looper)
    private var codec: MediaCodec? = null
    private var reader: ImageReader? = null
    private var configureError: String? = null
    private var error: String? = null

    private var winStartNs = 0L
    private var winEndNs = Long.MAX_VALUE
    private var endNs = Long.MAX_VALUE
    private var stopped = false
    private val queuedAt = LongArray(RING)
    private val queuedIdr = BooleanArray(RING)
    private val idrLat = LongList(64)
    private var nextUnit = 0
    private var frameNo = 0L
    private val free = ArrayDeque<Int>()
    private var owed = 0
    private var nextTickNs = 0L
    private val lat = LongList()
    private val gap = LongList()
    private var lastOutNs = 0L
    private var frames = 0
    private var images = 0
    private var missed = 0
    private var loggedFormat = false

    private fun <T> onThread(block: () -> T): T {
        var result: Result<T>? = null
        val done = CountDownLatch(1)
        handler.post {
            result = runCatching(block)
            done.countDown()
        }
        if (!done.await(5, TimeUnit.SECONDS)) throw IllegalStateException("session $index thread timeout")
        return result!!.getOrThrow()
    }

    /** Creates and configures the codec; returns null on success or the failure text. */
    fun configure(): String? = onThread {
        try {
            val f = clip.file
            val fmt = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_HEVC, f.width, f.height)
            fmt.setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, clip.maxUnit + 4096)
            fmt.setInteger(MediaFormat.KEY_FRAME_RATE, if (paceFps > 0) paceFps else STREAM_FPS)
            clip.csd?.let { fmt.setByteBuffer("csd-0", ByteBuffer.wrap(it)) }
            if (colorKeys && f.bitDepth == 10) {
                fmt.setInteger(MediaFormat.KEY_PROFILE, HevcProfiles.forClip(f))
                fmt.setInteger(MediaFormat.KEY_COLOR_RANGE, MediaFormat.COLOR_RANGE_LIMITED)
                if (f.depth == "10pq") {
                    fmt.setInteger(MediaFormat.KEY_COLOR_STANDARD, MediaFormat.COLOR_STANDARD_BT2020)
                    fmt.setInteger(MediaFormat.KEY_COLOR_TRANSFER, MediaFormat.COLOR_TRANSFER_ST2084)
                } else {
                    fmt.setInteger(MediaFormat.KEY_COLOR_STANDARD, MediaFormat.COLOR_STANDARD_BT709)
                    fmt.setInteger(MediaFormat.KEY_COLOR_TRANSFER, MediaFormat.COLOR_TRANSFER_SDR_VIDEO)
                }
            }
            priority?.let { fmt.setInteger(MediaFormat.KEY_PRIORITY, it) }
            operatingRate?.let { fmt.setInteger(MediaFormat.KEY_OPERATING_RATE, it) }
            val c = MediaCodec.createByCodecName(codecName)
            codec = c
            c.setCallback(callback, handler)
            val surface = if (output == "image") {
                // No silent fallback: an unsupported format fails here and shows up as ERR(configure:...).
                val r = ImageReader.newInstance(f.width, f.height, imgFormat, 4,
                    HardwareBuffer.USAGE_GPU_SAMPLED_IMAGE)
                r.setOnImageAvailableListener({ onImage(it) }, handler)
                reader = r
                r.surface
            } else {
                null
            }
            c.configure(fmt, surface, null, 0)
            null
        } catch (e: MediaCodec.CodecException) {
            "configure:${e.errorCode}:${e.diagnosticInfo}"
        } catch (t: Throwable) {
            "configure:${t.javaClass.simpleName}:${t.message}"
        }.also { configureError = it }
    }

    /** Starts decoding; frames are counted in [winStart, winEnd), feeding stops at [end]. */
    fun start(t0Ns: Long, winStart: Long, winEnd: Long, end: Long) = onThread {
        winStartNs = winStart
        winEndNs = winEnd
        endNs = end
        try {
            codec!!.start()
            if (paceFps > 0) {
                nextTickNs = t0Ns
                scheduleTick()
            }
        } catch (t: Throwable) {
            error = "start:${t.javaClass.simpleName}:${t.message}"
        }
    }

    /** Stops counting and feeding, releases everything and returns the measurements. */
    fun stop(): SessionResult {
        val result = try {
            onThread {
                stopped = true
                handler.removeCallbacksAndMessages(TICK)
                SessionResult(
                    clip = clip.file.id, width = clip.file.width, height = clip.file.height, frames = frames,
                    latNs = lat.toArray(), gapNs = gap.toArray(), images = if (output == "image") images else -1,
                    missedTicks = missed, error = configureError ?: error,
                    idrLatNs = idrLat.toArray(), profile = clip.file.profileName,
                )
            }
        } catch (t: Throwable) {
            SessionResult(clip.file.id, clip.file.width, clip.file.height, 0, LongArray(0), LongArray(0),
                error = "stop:${t.message}")
        }
        // Outside the callback thread (callbacks catch IllegalStateException from a concurrent stop).
        try { codec?.stop() } catch (_: Throwable) {}
        try { codec?.release() } catch (_: Throwable) {}
        try { reader?.close() } catch (_: Throwable) {}
        thread.quitSafely()
        thread.join(1000)
        return result
    }

    private fun scheduleTick() {
        val delayMs = ((nextTickNs - System.nanoTime()) / 1_000_000).coerceAtLeast(0)
        handler.postAtTime({ tick() }, TICK, android.os.SystemClock.uptimeMillis() + delayMs)
    }

    private fun tick() {
        if (stopped || System.nanoTime() >= endNs) return
        val now = System.nanoTime()
        if (owed > 0 && now in winStartNs until winEndNs) missed++
        owed++
        drainOwed()
        nextTickNs += 1_000_000_000L / paceFps
        scheduleTick()
    }

    private fun drainOwed() {
        val c = codec ?: return
        while (owed > 0 && free.isNotEmpty()) {
            queue(c, free.removeFirst())
            owed--
        }
    }

    private fun queue(c: MediaCodec, idx: Int) {
        val u = clip.units[nextUnit]
        val buf = c.getInputBuffer(idx) ?: return
        buf.clear()
        buf.put(clip.data, u.offset, u.length)
        val slot = (frameNo and (RING - 1).toLong()).toInt()
        queuedAt[slot] = System.nanoTime()
        queuedIdr[slot] = clip.idr[nextUnit]
        c.queueInputBuffer(idx, 0, u.length, frameNo * PTS_STEP_US, 0)
        frameNo++
        nextUnit = (nextUnit + 1) % clip.units.size
    }

    private fun onImage(r: ImageReader) {
        try {
            val img = r.acquireNextImage() ?: return
            img.close()
            val now = System.nanoTime()
            if (!stopped && now in winStartNs until winEndNs) images++
        } catch (_: Throwable) {
        }
    }

    private val callback = object : MediaCodec.Callback() {
        override fun onInputBufferAvailable(c: MediaCodec, idx: Int) {
            try {
                if (stopped || System.nanoTime() >= endNs) return
                if (paceFps > 0) {
                    free.add(idx)
                    drainOwed()
                } else {
                    queue(c, idx)
                }
            } catch (_: IllegalStateException) {
            }
        }

        override fun onOutputBufferAvailable(c: MediaCodec, idx: Int, info: MediaCodec.BufferInfo) {
            try {
                val now = System.nanoTime()
                if (info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG == 0 && !stopped) {
                    if (now in winStartNs until winEndNs) {
                        val fn = info.presentationTimeUs / PTS_STEP_US
                        frames++
                        val slot = (fn and (RING - 1).toLong()).toInt()
                        lat.add(now - queuedAt[slot])
                        if (queuedIdr[slot]) idrLat.add(now - queuedAt[slot])
                        if (lastOutNs >= winStartNs) gap.add(now - lastOutNs)
                    }
                    lastOutNs = now
                }
                c.releaseOutputBuffer(idx, output == "image")
            } catch (_: IllegalStateException) {
            }
        }

        override fun onError(c: MediaCodec, e: MediaCodec.CodecException) {
            if (error == null) error = "codec:${e.errorCode}:${e.diagnosticInfo}"
        }

        override fun onOutputFormatChanged(c: MediaCodec, format: MediaFormat) {
            if (!loggedFormat && index == 0) {
                loggedFormat = true
                log("DECPROBE info out_format s$index $output $format")
            }
        }
    }

    companion object {
        private const val RING = 1024
        private const val STREAM_FPS = 120
        private const val PTS_STEP_US = 8333L
        private val TICK = Any()
    }
}
