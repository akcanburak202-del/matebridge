package dev.matebridge.client.camera

/**
 * The bounded send queue between the encoder and the camera connection (PROTOCOL.md section 5, Kamera): at most
 * [CAPACITY] encoded frames wait. When it overflows the waiting non-key frames go (oldest first), and until the next
 * keyframe arrives every non-key frame is dropped ([needKeyframe]; the owner asks the encoder for one). The newest frame
 * is never delayed behind a backlog.
 *
 * `CODEC_CONFIG` is not queued: the queue keeps the latest config and puts it in front of the next keyframe that follows
 * a (re)start, a host keyframe request, a facing change or a new config ([configPending]). Thread-safe; the encoder
 * thread offers, the connection's writer thread takes.
 */
class CamSendQueue(private val capacity: Int = CAPACITY) {
    /** One unit for the writer: an optional config to send first, then the frame. */
    class Out(val config: ByteArray?, val data: ByteArray, val captureTimeUs: Long, val keyframe: Boolean, val configTimeUs: Long)

    private class Item(val data: ByteArray, val ts: Long, val key: Boolean)

    private val lock = Object()
    private val items = ArrayDeque<Item>()
    private var config: ByteArray? = null
    private var configTs = 0L
    private var configPending = true
    private var gate = true
    private var active = false
    private var closed = false

    // counters (guarded by lock)
    private var offered = 0L
    private var dropped = 0L

    /** True while only a keyframe may pass. */
    val needKeyframe: Boolean get() = synchronized(lock) { gate }

    /** The queue holds frames only while a connection is [active]; otherwise offered frames are dropped at once. */
    fun setActive(on: Boolean) {
        synchronized(lock) {
            active = on
            if (on) {
                items.clear()
                gate = true
                configPending = true
            } else {
                dropped += items.size
                items.clear()
            }
            lock.notifyAll()
        }
    }

    /**
     * The encoder produced a (new) config. It is sent before the next keyframe, and only a keyframe may pass until then
     * (the owner asks the encoder for one).
     */
    fun onConfig(data: ByteArray, tsUs: Long) {
        synchronized(lock) {
            config = data
            configTs = tsUs
            configPending = true
            gate = true
            dropped += items.count { !it.key }
            items.removeAll { !it.key }
            lock.notifyAll()
        }
    }

    /** The host asked for a keyframe (or the connection restarted): drop what is behind and wait for the next key (with the config). */
    fun onKeyframeRequested() {
        synchronized(lock) {
            configPending = true
            gate = true
            dropped += items.count { !it.key }
            items.removeAll { !it.key }
            lock.notifyAll()
        }
    }

    /** Result of [offer]. */
    enum class Offer { QUEUED, DROPPED, DROPPED_NEED_KEYFRAME }

    /**
     * An encoded frame. [Offer.DROPPED_NEED_KEYFRAME]: the frame (or an older one) was lost in a way that breaks the
     * reference chain, so the caller must request a keyframe (once per gate: the gate was just closed by this call).
     */
    fun offer(data: ByteArray, tsUs: Long, key: Boolean): Offer {
        synchronized(lock) {
            offered++
            if (!active) { dropped++; return Offer.DROPPED }
            if (gate) {
                if (!key) { dropped++; return Offer.DROPPED }
                gate = false
            }
            var brokeChain = false
            if (items.size >= capacity) {
                // Overflow: every waiting non-key frame goes (a delta behind a missing one cannot be decoded); a key frame
                // that still fills the queue gives way to the newest one only as a last resort.
                val n = items.count { !it.key }
                if (n > 0) { items.removeAll { !it.key }; dropped += n; brokeChain = true }
                while (items.size >= capacity) { items.removeFirst(); dropped++; brokeChain = true }
            }
            if (brokeChain && !key) {
                // A delta behind a gap cannot be decoded: drop it too and wait for a keyframe.
                dropped++
                gate = true
                lock.notifyAll()
                return Offer.DROPPED_NEED_KEYFRAME
            }
            if (brokeChain) items.removeAll { !it.key } // a keyframe restarts the chain: older deltas are useless
            items.addLast(Item(data, tsUs, key))
            lock.notifyAll()
            return Offer.QUEUED
        }
    }

    /**
     * Blocks up to [timeoutMs] for the next unit; null on timeout or after [close]. A keyframe is preceded by the config
     * while [configPending] and a config is known (a keyframe before any config waits for the config).
     */
    fun take(timeoutMs: Long): Out? {
        val deadline = System.nanoTime() + timeoutMs * 1_000_000
        synchronized(lock) {
            while (true) {
                if (closed) return null
                val first = items.firstOrNull()
                if (first != null) {
                    if (first.key && configPending) {
                        val cfg = config
                        if (cfg != null) {
                            items.removeFirst()
                            configPending = false
                            return Out(cfg, first.data, first.ts, true, configTs)
                        }
                        // no config yet: wait for it (the encoder emits it before the first frame)
                    } else {
                        items.removeFirst()
                        return Out(null, first.data, first.ts, first.key, 0)
                    }
                }
                val left = deadline - System.nanoTime()
                if (left <= 0) return null
                lock.wait(left / 1_000_000, (left % 1_000_000).toInt())
            }
        }
    }

    /** Wakes and ends every [take]; the queue is unusable afterwards. */
    fun close() {
        synchronized(lock) {
            closed = true
            items.clear()
            lock.notifyAll()
        }
    }

    /** Frames offered / dropped since creation. */
    fun counters(): Pair<Long, Long> = synchronized(lock) { offered to dropped }

    /** Frames waiting (tests). */
    fun size(): Int = synchronized(lock) { items.size }

    companion object {
        const val CAPACITY = 2
    }
}
