package dev.matebridge.client.video

import dev.matebridge.client.protocol.Capabilities
import dev.matebridge.client.session.KeyValueStore

/**
 * Persisted result of the full-chroma capability self-test (decision 0034, T-259 [FullChromaSelfTest]). The panel
 * (T-260) reads [status]/[available] to grey out "Tam renk" ("Bu cihazda yok"). Pure over [KeyValueStore].
 *
 * Stored per build ([buildKey]: an APK update re-tests): `<build>|pass`, `<build>|fail|<reason>` (definitive), or
 * `<build>|retry|<n>|<reason>` (the test could not run, e.g. the decoder was busy: tried again at the next start, and
 * after [MAX_ATTEMPTS] it becomes a definitive fail). Only a pass enables `chroma = 2` and the HELLO bit11.
 */
class FullChromaCapability(private val store: KeyValueStore, private val buildKey: String) {
    enum class State { UNKNOWN, PASSED, FAILED }

    data class Status(val state: State, val reason: String = "")

    private fun parts(): List<String>? =
        store.getString(KEY)?.split('|')?.takeIf { it.size >= 2 && it[0] == buildKey }

    /** The stored result for this build; [State.UNKNOWN] while untested or while a retry is pending. */
    fun status(): Status {
        val p = parts() ?: return Status(State.UNKNOWN)
        return when (p[1]) {
            "pass" -> Status(State.PASSED)
            "fail" -> Status(State.FAILED, p.getOrElse(2) { "" })
            else -> Status(State.UNKNOWN, p.getOrElse(3) { "" })
        }
    }

    fun available(): Boolean = status().state == State.PASSED

    /** True when the self-test must (still) run: nothing stored for this build, or a retry is pending. */
    fun needsTest(): Boolean = status().state == State.UNKNOWN

    /** `HELLO.capabilities` bit11 ([Capabilities.FULL_CHROMA]) only when the test passed. */
    fun helloBits(): Long = if (available()) Capabilities.FULL_CHROMA.toLong() else 0L

    fun recordPass() = store.putString(KEY, "$buildKey|pass")

    fun recordFail(reason: String) = store.putString(KEY, "$buildKey|fail|${clean(reason)}")

    /** The test could not decide (exception, busy decoder): counts an attempt; the [MAX_ATTEMPTS]th makes it a fail. */
    fun recordInconclusive(reason: String) {
        val p = parts()
        val n = (if (p != null && p[1] == "retry") p.getOrNull(2)?.toIntOrNull() ?: 0 else 0) + 1
        if (n >= MAX_ATTEMPTS) recordFail("inconclusive_${clean(reason)}")
        else store.putString(KEY, "$buildKey|retry|$n|${clean(reason)}")
    }

    private fun clean(s: String) = s.replace('|', '_').replace(Regex("\\s+"), "_").take(60)

    companion object {
        const val KEY = "full_chroma_cap"
        const val MAX_ATTEMPTS = 3
    }
}
