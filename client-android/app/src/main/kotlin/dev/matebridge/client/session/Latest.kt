package dev.matebridge.client.session

import dev.matebridge.client.protocol.StreamPrefs
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

/**
 * T-276: the display mode and the cursor wish as ONE pending command (PROTOCOL.md 0x0D: switching to Oyun sends
 * CURSOR_PREFS(0) before STREAM_PREFS). Two separate mailboxes cannot keep that order: the engine may find the cursor slot
 * empty, be preempted while the UI posts the cursor wish and then the display mode, and take the display mode first. Here
 * a post merges into the pending command with a compare-and-set (the newest value of each part wins, a part that is not
 * posted again stays) and [take] removes the whole command at once, so the engine sees either nothing, the cursor part
 * alone (posted first), or both together (cursor handled first, see [SessionMachine.Event.SetMode]).
 */
class ModeSlot {
    private val slot = AtomicReference<SessionMachine.Event.SetMode?>(null)

    fun setPrefs(prefs: StreamPrefs) = merge(null, prefs)

    fun setCursor(enabled: Boolean) = merge(enabled, null)

    /** [beforeCas] is a test hook that runs between reading the pending command and publishing the merge. */
    internal fun merge(cursor: Boolean?, prefs: StreamPrefs?, beforeCas: () -> Unit = {}) {
        while (true) {
            val cur = slot.get()
            val next = SessionMachine.Event.SetMode(cursor ?: cur?.cursor, prefs ?: cur?.prefs)
            beforeCas()
            if (slot.compareAndSet(cur, next)) return
        }
    }

    fun take(): SessionMachine.Event.SetMode? = slot.getAndSet(null)
}

/**
 * The engine's command mailboxes (one [Latest] slot each, [mode] merged) and the one order they are drained in.
 */
class EngineMailboxes {
    val trust = Latest<SessionMachine.Event>() // T-150: confirm / cancel / forget; the latest wins
    val intent = Latest<SessionMachine.Event>() // Start/Stop: the latest desired state wins
    val expect = Latest<SessionMachine.Event>() // T-227: the newest host expectation wins
    val promptVisible = Latest<SessionMachine.Event>() // T-150: the latest prompt visibility wins
    val mode = ModeSlot() // the newest display-mode request and cursor wish, in one ordered command
    val rate = Latest<SessionMachine.Event>() // the newest panel rate wins
    val audio = Latest<SessionMachine.Event>() // the newest audio setting wins
    val forget = Latest<SessionMachine.Event>() // T-269: the newest forgotten open request wins
    val files = Latest<SessionMachine.Event>() // T-135: the newest file server state wins
    val migrate = Latest<SessionMachine.Event>() // T-096: the newest migration request wins
    val videoBackoff = Latest<SessionMachine.Event>() // T-294: "Yeniden dene" resets the video reopen backoff (idempotent)

    /** The next pending command in priority order, or null. */
    fun take(): SessionMachine.Event? =
        trust.take() ?: intent.take() ?: expect.take() ?: promptVisible.take() ?: mode.take() ?:
            rate.take() ?: audio.take() ?: forget.take() ?: files.take() ?: migrate.take() ?:
            videoBackoff.take()
}
