package dev.matebridge.client.video

import java.nio.ByteBuffer
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.locks.LockSupport

/**
 * T-158: scriptable [DecoderCodec.Factory] for JVM tests of the real [VideoRenderer] threads. Set the script before
 * attaching; every codec it creates reads it. All calls are recorded in [events] as `<call>#<codec serial>` (serials
 * start at 1; a blocking call records `<call>#n>` on entry and `<call>#n<` on exit), and a waiter can block on them
 * with [awaitEvent] / [await] (monitor waits, no sleeps).
 *
 * Default behaviour is "silent": every input is accepted and no output ever comes (dequeueOutputBuffer waits its
 * timeout and returns try-again-later), the T-028 no-output case. T-159: with [produceOutput] each non-empty,
 * non-config input comes out as one decoded frame (same pts), in order.
 */
class FakeDecoderFactory : DecoderCodec.Factory {
    /** The next n [create] calls throw `IOException` (like `createDecoderByType`). */
    @Volatile var failCreates = 0
    @Volatile var failConfigure = false
    @Volatile var failStart = false
    @Volatile var throwOnDequeueInput = false
    @Volatile var throwOnDequeueOutput = false
    /** T-159: the next n dequeueOutputBuffer calls (any codec) throw, then it works again. */
    @Volatile var dequeueOutputFailures = 0
    /** T-252: when > 0, outputs come at least this far apart (a slow decoder that swallowed its inputs early). */
    @Volatile var outputSpacingMs = 0L
    /** T-159: each non-empty, non-config input yields one output. */
    @Volatile var produceOutput = false
    /** While set and closed, `stop()` / `release()` / `dequeueOutputBuffer()` block until the latch opens. */
    @Volatile var stopGate: CountDownLatch? = null
    @Volatile var releaseGate: CountDownLatch? = null
    @Volatile var dequeueOutputGate: CountDownLatch? = null
    /** T-219: while set and closed, `dequeueInputBuffer()` (any codec) blocks until the latch opens. */
    @Volatile var dequeueInputGate: CountDownLatch? = null
    /** What [DecoderCodec.lowLatencySupport] answers (null = API < 30). */
    @Volatile var lowLatency: Boolean? = true
    @Volatile var inputCapacity = 64 * 1024
    /** T-168: what [DecoderCodec.isHardwareAccelerated] / [DecoderCodec.isSoftwareOnly] answer (null = unknown). */
    @Volatile var hardware: Boolean? = true
    @Volatile var softwareOnly: Boolean? = false
    /** T-217: the next n `start()` calls (any codec) throw, then it works again. */
    @Volatile var failStarts = 0
    /** T-217: configure throws `IllegalArgumentException` when the format has any of these keys. */
    @Volatile var rejectKeys: Set<String> = emptySet()
    /** T-217: what [DecoderCodec.supportedVendorParameters] answers (null = unknown / API < 31). */
    @Volatile var vendorParameters: List<String>? = null
    /** T-231: the next n dequeueOutputBuffer calls (any codec) return `INFO_OUTPUT_FORMAT_CHANGED`. */
    @Volatile var outputFormatChanges = 0
    /** T-231: the integer keys of every codec's output format. */
    @Volatile var outputFormatInts: Map<String, Int> = emptyMap()
    /** T-231: the byte-buffer keys of every codec's output format (e.g. `hdr-static-info`). */
    @Volatile var outputFormatBuffers: Map<String, ByteArray> = emptyMap()
    /** T-217: the integer keys of every configure call (any codec, failed ones included), in order. */
    val configureFormats = java.util.concurrent.CopyOnWriteArrayList<Map<String, Int>>()

    /**
     * T-168 review: a render release (`releaseOutputBuffer(idx, ns)` / `(idx, true)`) calls the frame-rendered listener
     * before it returns, as if the main looper ran the callback while the output thread was descheduled.
     */
    @Volatile var renderCallbackInRelease = false

    /** T-168: every codec created, in order (a test drives a codec's frame-rendered listener through it). */
    val codecs = java.util.concurrent.CopyOnWriteArrayList<Codec>()

    private val lock = Object()
    private val log = ArrayList<String>()
    private var serials = 0
    private var queued = 0
    private var outputPolls = 0
    private var outputs = 0

    val events: List<String> get() = synchronized(lock) { ArrayList(log) }
    val createCalls: Int get() = synchronized(lock) { serials }
    /** Non-empty inputs queued to any codec. */
    val queuedInputs: Int get() = synchronized(lock) { queued }
    /** dequeueOutputBuffer calls that returned try-again-later. */
    val silentOutputPolls: Int get() = synchronized(lock) { outputPolls }
    /** T-159: outputs handed out by dequeueOutputBuffer (any codec). */
    val outputsDequeued: Int get() = synchronized(lock) { outputs }

    fun count(event: String) = events.count { it == event }

    /** Waits until [event] has been recorded. */
    fun awaitEvent(event: String, timeoutMs: Long = 5_000): Boolean = await(timeoutMs) { log.contains(event) }

    /** Waits until [condition] (evaluated under the fake's lock) holds. */
    fun await(timeoutMs: Long = 5_000, condition: FakeDecoderFactory.() -> Boolean): Boolean {
        val deadline = System.nanoTime() + TimeUnit.MILLISECONDS.toNanos(timeoutMs)
        synchronized(lock) {
            while (!condition()) {
                val leftMs = TimeUnit.NANOSECONDS.toMillis(deadline - System.nanoTime())
                if (leftMs <= 0) return false
                lock.wait(leftMs)
            }
            return true
        }
    }

    private fun record(e: String, update: () -> Unit = {}) = synchronized(lock) {
        log.add(e); update(); lock.notifyAll()
    }

    override fun create(mime: String): DecoderCodec {
        var serial = 0
        var fail = false
        synchronized(lock) {
            serial = ++serials
            if (failCreates > 0) { failCreates--; fail = true }
            log.add("create#$serial"); lock.notifyAll()
        }
        if (fail) throw java.io.IOException("fake create failure")
        return Codec(serial, mime).also { codecs.add(it) }
    }

    private fun gate(latch: CountDownLatch?) {
        if (latch == null) return
        try { latch.await() } catch (_: InterruptedException) { Thread.currentThread().interrupt() }
    }

    private class Format(
        private val values: Map<String, Int>,
        private val buffers: Map<String, ByteArray> = emptyMap(),
    ) : DecoderCodec.FormatView {
        override fun containsKey(key: String) = values.containsKey(key) || buffers.containsKey(key)
        override fun getInteger(key: String) = values[key] ?: throw NullPointerException(key)
        override fun getFloat(key: String): Float = throw ClassCastException(key)
        override fun getByteBuffer(key: String): ByteBuffer? = buffers[key]?.let { ByteBuffer.wrap(it).asReadOnlyBuffer() }
    }

    inner class Codec(val serial: Int, val mime: String) : DecoderCodec {
        @Volatile var format: DecoderFormat? = null
        @Volatile var surface: Any? = null
        @Volatile var renderedListener: ((Long, Long) -> Unit)? = null
        private var nextIndex = 0 // input thread only
        private val ready = ArrayDeque<Long>() // under the factory lock
        private var nextOut = 0
        private var nextOutNs = 0L // under the factory lock
        private val outPts = java.util.concurrent.ConcurrentHashMap<Int, Long>() // output index -> pts
        /** T-219: pts of every non-empty input queued to this codec, in order (config inputs included). */
        val inputPts = java.util.concurrent.CopyOnWriteArrayList<Long>()
        /** T-252: pts of the outputs released for rendering / without rendering, in release order. */
        val renderedPts = java.util.concurrent.CopyOnWriteArrayList<Long>()
        val discardedPts = java.util.concurrent.CopyOnWriteArrayList<Long>()

        override val name = "fake.decoder"
        override fun lowLatencySupport(mime: String) = lowLatency
        override val isHardwareAccelerated: Boolean? get() = hardware
        override val isSoftwareOnly: Boolean? get() = softwareOnly
        override val supportedVendorParameters: List<String>? get() = vendorParameters

        override fun configure(format: DecoderFormat, surface: Any) {
            configureFormats.add(LinkedHashMap(format.integers))
            record("configure#$serial")
            if (failConfigure) throw IllegalStateException("fake configure failure")
            if (format.integers.keys.any { it in rejectKeys }) throw IllegalArgumentException("fake unsupported key")
            this.format = format; this.surface = surface
        }

        override fun start() {
            var fail = failStart
            record("start#$serial") { if (failStarts > 0) { failStarts--; fail = true } }
            if (fail) throw IllegalStateException("fake start failure")
        }

        override fun dequeueInputBuffer(timeoutUs: Long): Int {
            dequeueInputGate?.let { g ->
                if (g.count > 0) { record("dequeueInput#$serial>"); gate(g); record("dequeueInput#$serial<") }
            }
            if (throwOnDequeueInput) throw IllegalStateException("fake dequeueInputBuffer failure")
            return nextIndex.also { nextIndex = (nextIndex + 1) % 8 }
        }

        override fun getInputBuffer(index: Int): ByteBuffer = ByteBuffer.allocate(inputCapacity)

        override fun queueInputBuffer(index: Int, offset: Int, size: Int, presentationTimeUs: Long, flags: Int) {
            synchronized(lock) {
                if (size > 0) { queued++; inputPts.add(presentationTimeUs) }
                if (produceOutput && size > 0 && flags and DecoderCodec.BUFFER_FLAG_CODEC_CONFIG == 0) ready.addLast(presentationTimeUs)
                lock.notifyAll()
            }
        }

        override fun dequeueOutputBuffer(info: DecoderCodec.OutputInfo, timeoutUs: Long): Int {
            dequeueOutputGate?.let { g ->
                if (g.count > 0) { record("dequeueOutput#$serial>"); gate(g); record("dequeueOutput#$serial<") }
            }
            if (throwOnDequeueOutput) throw IllegalStateException("fake dequeueOutputBuffer failure")
            synchronized(lock) {
                if (dequeueOutputFailures > 0) {
                    dequeueOutputFailures--
                    log.add("dequeueOutputFailure#$serial"); lock.notifyAll()
                    throw IllegalStateException("fake dequeueOutputBuffer failure")
                }
                if (outputFormatChanges > 0) {
                    outputFormatChanges--
                    log.add("outputFormatChanged#$serial"); lock.notifyAll()
                    return DecoderCodec.INFO_OUTPUT_FORMAT_CHANGED
                }
                val nowNs = System.nanoTime()
                val pts = if (outputSpacingMs > 0 && nowNs < nextOutNs) null else ready.removeFirstOrNull()
                if (pts != null) {
                    nextOutNs = nowNs + outputSpacingMs * 1_000_000L
                    outputs++; lock.notifyAll()
                    info.presentationTimeUs = pts
                    info.flags = 0
                    outPts[nextOut] = pts
                    return nextOut.also { nextOut = (nextOut + 1) % 8 }
                }
            }
            if (timeoutUs > 0) LockSupport.parkNanos(timeoutUs * 1000) // a real codec blocks up to the timeout
            synchronized(lock) { outputPolls++; lock.notifyAll() }
            return DecoderCodec.INFO_TRY_AGAIN_LATER
        }

        override fun releaseOutputBuffer(index: Int, renderTimestampNs: Long) { record("releaseOutput#$serial"); rendered(index) }
        override fun releaseOutputBuffer(index: Int, render: Boolean) {
            record("releaseOutput#$serial")
            if (render) rendered(index) else outPts.remove(index)?.let { discardedPts.add(it) }
        }

        private fun rendered(index: Int) {
            val pts = outPts.remove(index) ?: return
            renderedPts.add(pts)
            if (renderCallbackInRelease) renderedListener?.invoke(pts, System.nanoTime())
        }

        override fun setOnFrameRenderedListener(listener: (presentationTimeUs: Long, nanoTime: Long) -> Unit) {
            renderedListener = listener
        }

        override val inputFormat: DecoderCodec.FormatView get() = Format(format?.integers ?: emptyMap())
        override val outputFormat: DecoderCodec.FormatView get() = Format(outputFormatInts, outputFormatBuffers)

        override fun stop() {
            record("stop#$serial>"); gate(stopGate); record("stop#$serial<")
        }

        override fun release() {
            record("release#$serial>"); gate(releaseGate); record("release#$serial<")
        }
    }
}

/** T-158: JVM [DecoderEnv]: a settable clock and an in-memory log of the full lines. */
class TestDecoderEnv(@Volatile var nowMs: Long = 1_000L) : DecoderEnv {
    private val lines = java.util.concurrent.CopyOnWriteArrayList<String>()

    val log: List<String> get() = lines.toList()

    private val lock = Object()

    /** Lines whose event is [ev] (`ev=<name>` as a whole field). */
    fun lines(ev: String) = lines.filter { " ev=$ev " in "$it " }

    /** Waits (monitor wait, no sleep) until at least [count] lines with event [ev] were logged. */
    fun awaitLines(ev: String, count: Int = 1, timeoutMs: Long = 5_000): Boolean {
        val deadline = System.nanoTime() + TimeUnit.MILLISECONDS.toNanos(timeoutMs)
        synchronized(lock) {
            while (lines(ev).size < count) {
                val leftMs = TimeUnit.NANOSECONDS.toMillis(deadline - System.nanoTime())
                if (leftMs <= 0) return false
                lock.wait(leftMs)
            }
            return true
        }
    }

    override fun elapsedRealtimeMs() = nowMs
    override fun elapsedRealtimeNanos() = System.nanoTime()
    override fun log(level: Char, tag: String, line: String) {
        synchronized(lock) { lines.add("$tag $line"); lock.notifyAll() }
    }
    override fun myTid() = 0
    override fun setDisplayPriority() {}
}
