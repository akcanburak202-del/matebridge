package dev.matebridge.client.files

import dev.matebridge.client.protocol.FilesNet
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference

/**
 * Bounded hand-over of the Mac's `FILES_NET` (T-269) from the session thread to the UI thread: one pending slot holding
 * the latest (connection generation, message) and at most one queued run of [deliver]. A burst of repeats (or an OPEN
 * followed by a CLOSE) therefore costs O(1) memory and never queues ahead of input handling; only the newest state is
 * delivered, and an identical one that is already waiting is dropped.
 *
 * Generation barrier: the UI learns a new control connection through its own queued run ([currentGen] is what the UI has
 * seen so far). A message of a newer generation must not be delivered by a run that was queued before that update, or
 * the gate would reject it and a repeat of the same OPEN is suppressed upstream (the open request would be lost). Such a
 * run keeps the message in the slot and queues itself again, behind the UI's pending generation update. Any thread may
 * [offer]; [deliver] and [currentGen] run on whatever [post] posts to.
 *
 * Teardown flag: coalescing must not hide an eject. A CLOSE that is replaced by a following OPEN (the Mac ejected and
 * reopened, even on the same port, before the UI ran) leaves `closeSeen` on the pending state; the run then delivers a
 * CLOSE first (the UI stops the server and publishes STANDBY: a running copy ends, the token dies) and the OPEN after it
 * (a fresh server with a new token). Without it the gate would see its old OPEN unchanged and do nothing.
 */
class FilesNetDelivery(
    private val post: (Runnable) -> Unit,
    private val currentGen: () -> Int,
    private val deliver: (Int, FilesNet) -> Unit,
) {
    /** [closeSeen]: a CLOSE of this generation was coalesced into (or is) this state and has not been delivered. */
    private data class Pending(val gen: Int, val msg: FilesNet, val closeSeen: Boolean)

    private val slot = AtomicReference<Pending?>(null)
    private val queued = AtomicBoolean(false)

    /** False when an identical state already waits in the slot (nothing to do), true otherwise. */
    fun offer(gen: Int, msg: FilesNet): Boolean {
        while (true) {
            val cur = slot.get()
            val closeSeen = !msg.isOpen || (cur != null && cur.gen == gen && cur.closeSeen)
            val next = Pending(gen, msg, closeSeen)
            if (cur == next) return false
            if (slot.compareAndSet(cur, next)) break
        }
        schedule()
        return true
    }

    /** Queues the run unless one is already queued (it will take the newest value). */
    private fun schedule() {
        if (!queued.compareAndSet(false, true)) return
        try {
            post(Runnable { run() })
        } catch (e: RuntimeException) {
            queued.set(false)
            throw e
        }
    }

    private fun run() {
        queued.set(false) // before taking: a value set from here on posts again
        val v = slot.getAndSet(null) ?: return
        if (v.gen > currentGen()) {
            // the UI has not seen this generation yet: wait behind its update (a newer offer meanwhile replaces v)
            slot.compareAndSet(null, v)
            schedule()
            return
        }
        // an eject that was coalesced away still happens: CLOSE first, then the newer OPEN
        if (v.msg.isOpen && v.closeSeen) deliver(v.gen, FilesNet(FilesNet.STATE_CLOSE, 0, 0, 0))
        deliver(v.gen, v.msg)
    }
}
