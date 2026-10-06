package dev.matebridge.client.cursor

/**
 * Small least-recently-used map (decision 0036: the tablet keeps at least 64 shapes per session so every id the host
 * believes we hold is still here). "Use" is a [put] or a [touch]; [peek] does not count as use. Thread-safe.
 */
class ShapeCache<V : Any>(val capacity: Int = DEFAULT_CAPACITY) {
    private class Slot<V>(val value: V, var used: Long)

    private val map = HashMap<Long, Slot<V>>()
    private var clock = 0L

    init {
        require(capacity >= 1) { "capacity must be at least 1" }
    }

    @Synchronized fun put(id: Long, value: V) {
        map[id] = Slot(value, ++clock)
        if (map.size > capacity) {
            var oldest: Long? = null
            var oldestUsed = Long.MAX_VALUE
            for ((k, v) in map) if (v.used < oldestUsed) { oldest = k; oldestUsed = v.used }
            oldest?.let { map.remove(it) }
        }
    }

    /** The value for [id], counted as a use; null when unknown. */
    @Synchronized fun touch(id: Long): V? = map[id]?.also { it.used = ++clock }?.value

    /** The value for [id] without counting a use. */
    @Synchronized fun peek(id: Long): V? = map[id]?.value

    @Synchronized fun clear() { map.clear() }

    val size: Int @Synchronized get() = map.size

    companion object {
        const val DEFAULT_CAPACITY = 64
    }
}
