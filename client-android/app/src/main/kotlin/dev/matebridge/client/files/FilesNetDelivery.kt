package dev.matebridge.client.files

import dev.matebridge.client.protocol.FilesNet
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference

/**
 * Bounded hand-over of the Mac's `FILES_NET` (T-269) from the session thread to the UI thread: one pending slot holding
 * the latest (connection generation, message) and at most one queued run of [deliver]. A burst of repeats (or an OPEN
 * followed by a CLOSE) therefore costs O(1) memory and never queues ahead of input handling; only the newest state is
 * delivered, and an identical one that is already waiting is dropped. [deliver] re-checks the generation itself
 * ([FilesSessionGate.onFilesNet]). Any thread may [offer]; [deliver] runs on whatever [post] posts to.
 */
class FilesNetDelivery(private val post: (Runnable) -> Unit, private val deliver: (Int, FilesNet) -> Unit) {
    private val slot = AtomicReference<Pair<Int, FilesNet>?>(null)
    private val queued = AtomicBoolean(false)

    /** False when an identical message already waits in the slot (nothing to do), true otherwise. */
    fun offer(gen: Int, msg: FilesNet): Boolean {
        val v = gen to msg
        if (slot.get() == v) return false
        slot.set(v)
        if (!queued.compareAndSet(false, true)) return true // the queued run will take the newest value
        try {
            post(Runnable {
                queued.set(false) // before taking: a value set from here on posts again
                slot.getAndSet(null)?.let { deliver(it.first, it.second) }
            })
        } catch (e: RuntimeException) {
            queued.set(false)
            throw e
        }
        return true
    }
}
