package dev.matebridge.client.session

import java.util.concurrent.atomic.AtomicReference

/** Single-slot mailbox: the newest posted value wins. Memory use is O(1) however often it is posted. */
class Latest<T : Any> {
    private val slot = AtomicReference<T?>(null)

    fun post(value: T) { slot.set(value) }

    fun take(): T? = slot.getAndSet(null)
}

/**
 * Single-slot mailbox keyed by connection generation: keeps the value with the highest generation.
 * Only the newest connection of a kind matters to the session machine (older generations are ignored),
 * so dropping lower-generation notifications loses nothing.
 */
class LatestGen<T : Any>(private val genOf: (T) -> Int) {
    private val slot = AtomicReference<T?>(null)

    fun post(value: T) {
        while (true) {
            val cur = slot.get()
            if (cur != null && genOf(cur) > genOf(value)) return
            if (slot.compareAndSet(cur, value)) return
        }
    }

    fun take(): T? = slot.getAndSet(null)
}
