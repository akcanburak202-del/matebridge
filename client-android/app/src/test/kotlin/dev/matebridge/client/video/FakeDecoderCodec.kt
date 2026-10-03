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
 * timeout and returns try-again-later), the T-028 no-output case.
 */
class FakeDecoderFactory : DecoderCodec.Factory {
    /** The next n [create] calls throw `IOException` (like `createDecoderByType`). */
    @Volatile var failCreates = 0
    @Volatile var failConfigure = false
    @Volatile var failStart = false
    @Volatile var throwOnDequeueInput = false
    @Volatile var throwOnDequeueOutput = false
    /** While set and closed, `stop()` / `release()` / `dequeueOutputBuffer()` block until the latch opens. */
    @Volatile var stopGate: CountDownLatch? = null
    @Volatile var releaseGate: CountDownLatch? = null
    @Volatile var dequeueOutputGate: CountDownLatch? = null
    /** What [DecoderCodec.lowLatencySupport] answers (null = API < 30). */
    @Volatile var lowLatency: Boolean? = true
    @Volatile var inputCapacity = 64 * 1024

    private val lock = Object()
    private val log = ArrayList<String>()
    private var serials = 0
    private var queued = 0
    private var outputPolls = 0

    val events: List<String> get() = synchronized(lock) { ArrayList(log) }
    val createCalls: Int get() = synchronized(lock) { serials }
    /** Non-empty inputs queued to any codec. */
    val queuedInputs: Int get() = synchronized(lock) { queued }
    /** dequeueOutputBuffer calls that returned try-again-later. */
    val silentOutputPolls: Int get() = synchronized(lock) { outputPolls }

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
        return Codec(serial, mime)
    }

    private fun gate(latch: CountDownLatch?) {
        if (latch == null) return
        try { latch.await() } catch (_: InterruptedException) { Thread.currentThread().interrupt() }
    }

    private class Format(private val values: Map<String, Int>) : DecoderCodec.FormatView {
        override fun containsKey(key: String) = values.containsKey(key)
        override fun getInteger(key: String) = values[key] ?: throw NullPointerException(key)
        override fun getFloat(key: String): Float = throw ClassCastException(key)
    }

    inner class Codec(val serial: Int, val mime: String) : DecoderCodec {
        @Volatile var format: DecoderFormat? = null
        @Volatile var surface: Any? = null
        @Volatile var renderedListener: ((Long, Long) -> Unit)? = null
        private var nextIndex = 0 // input thread only

        override val name = "fake.decoder"
        override fun lowLatencySupport(mime: String) = lowLatency

        override fun configure(format: DecoderFormat, surface: Any) {
            record("configure#$serial")
            if (failConfigure) throw IllegalStateException("fake configure failure")
            this.format = format; this.surface = surface
        }

        override fun start() {
            record("start#$serial")
            if (failStart) throw IllegalStateException("fake start failure")
        }

        override fun dequeueInputBuffer(timeoutUs: Long): Int {
            if (throwOnDequeueInput) throw IllegalStateException("fake dequeueInputBuffer failure")
            return nextIndex.also { nextIndex = (nextIndex + 1) % 8 }
        }

        override fun getInputBuffer(index: Int): ByteBuffer = ByteBuffer.allocate(inputCapacity)

        override fun queueInputBuffer(index: Int, offset: Int, size: Int, presentationTimeUs: Long, flags: Int) {
            synchronized(lock) { if (size > 0) queued++; lock.notifyAll() }
        }

        override fun dequeueOutputBuffer(info: DecoderCodec.OutputInfo, timeoutUs: Long): Int {
            dequeueOutputGate?.let { g ->
                if (g.count > 0) { record("dequeueOutput#$serial>"); gate(g); record("dequeueOutput#$serial<") }
            }
            if (throwOnDequeueOutput) throw IllegalStateException("fake dequeueOutputBuffer failure")
            if (timeoutUs > 0) LockSupport.parkNanos(timeoutUs * 1000) // a real codec blocks up to the timeout
            synchronized(lock) { outputPolls++; lock.notifyAll() }
            return DecoderCodec.INFO_TRY_AGAIN_LATER
        }

        override fun releaseOutputBuffer(index: Int, renderTimestampNs: Long) = record("releaseOutput#$serial")
        override fun releaseOutputBuffer(index: Int, render: Boolean) = record("releaseOutput#$serial")

        override fun setOnFrameRenderedListener(listener: (presentationTimeUs: Long, nanoTime: Long) -> Unit) {
            renderedListener = listener
        }

        override val inputFormat: DecoderCodec.FormatView get() = Format(format?.integers ?: emptyMap())
        override val outputFormat: DecoderCodec.FormatView get() = Format(emptyMap())

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
