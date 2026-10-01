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

/**
 * T-096: close notifications of control connections, with one slot per role. A migration candidate has a HIGHER
 * generation than the current connection, so in one shared [LatestGen] its close would replace (lose) the current
 * connection's close. Each connection's role is fixed when it is built and changed only by the engine:
 * a candidate becomes [Owner.CURRENT] on promotion, and [Owner.CANCELLED] when it is aborted. A cancelled
 * connection's close is dropped (the machine already forgot it).
 */
class ControlCloseSlots {
    enum class Owner { CURRENT, CANDIDATE, CANCELLED }

    private val current = LatestGen<SessionMachine.Event.ControlClosed> { it.gen }
    private val candidate = LatestGen<SessionMachine.Event.ControlClosed> { it.gen }

    fun post(event: SessionMachine.Event.ControlClosed, owner: Owner) {
        when (owner) {
            Owner.CURRENT -> current.post(event)
            Owner.CANDIDATE -> candidate.post(event)
            Owner.CANCELLED -> Unit
        }
    }

    /** The current connection's close first; the other comes on the next take. */
    fun take(): SessionMachine.Event.ControlClosed? = current.take() ?: candidate.take()
}
