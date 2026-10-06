package dev.matebridge.client.audio

import java.util.concurrent.atomic.AtomicLong

/**
 * T-287: when the writer suspends the output stream. While nothing plays the Mac sends no packets (T-279) but an
 * AAudio MMAP stream still wants a silent burst every 5 ms (~200 wake-ups/s, ~2% of a core, T-282). After
 * [AFTER_FRAMES] of silence (10 s counted in output frames, which the device paces in real time) the writer pauses the
 * stream and blocks until the next packet, then resumes it; [PlayoutCore] sees nothing but a long idle gap.
 *
 * Pure state; writer thread only. [shouldPause] holds only in PRIMING with no packet for [afterFrames] and not right
 * after a resume (the core has not yet seen the packet that woke the writer: its "frames since the last packet" still
 * holds the old, long value until one burst has been rendered, see [onRendered]).
 */
class IdlePause(val mode: Mode, private val afterFrames: Long = AFTER_FRAMES) {
    /** [PAUSE]: requestPause (buffered data kept, counters continuous); [STOP]: requestStop; [OFF]: never (default). */
    enum class Mode(val id: String) { OFF("off"), PAUSE("pause"), STOP("stop") }

    /** Why pausing is switched off for this stream (null = it is not); logs. */
    var disabledReason: String? = null
        private set

    /** Pause cycles done by this stream (logs). */
    var pauses = 0L
        private set

    private var settled = true

    val enabled: Boolean get() = mode != Mode.OFF && disabledReason == null

    /**
     * [newPackets]: packets reached the jitter buffer after the last rendered burst started, so
     * [framesSinceLastPacket] (from that render) is stale and the buffered audio is not yet played: never pause then
     * (a parked writer waits for a packet after its own snapshot and would leave that audio queued).
     */
    fun shouldPause(priming: Boolean, framesSinceLastPacket: Long, canPause: Boolean, newPackets: Boolean = false): Boolean =
        enabled && canPause && settled && priming && !newPackets && framesSinceLastPacket >= afterFrames

    /** The output was paused and the writer parks. */
    fun onPaused() {
        pauses++
    }

    /** The output was started again: no new pause before a burst has been rendered. */
    fun onResumed() {
        settled = false
    }

    /** A burst was rendered (the core has seen the packets that arrived while parked). */
    fun onRendered() {
        settled = true
    }

    /** The output could not be paused or resumed: do not try again for this stream. */
    fun disable(reason: String) {
        if (disabledReason == null) disabledReason = reason
    }

    /** A new output replaced the old one (rebuild): nothing is in flight. */
    fun onNewOutput() {
        settled = true
    }

    /** [raw] resolved: [mode] (default [DEFAULT] when null or unknown) and whether a non-null [raw] was unknown. */
    data class Resolved(val mode: Mode, val unknown: Boolean)

    companion object {
        const val SECONDS = 10
        const val AFTER_FRAMES = SECONDS * 48_000L
        /** Off until the device A/B passes (decision 0026: a new knob defaults to the old behaviour). */
        val DEFAULT = Mode.OFF

        /** `--es audio_idle_pause off|pause|stop` (developer knob); null = the default. */
        fun resolve(raw: String?): Resolved {
            if (raw == null) return Resolved(DEFAULT, false)
            val m = Mode.entries.firstOrNull { it.id == raw.trim().lowercase() }
            return if (m != null) Resolved(m, false) else Resolved(DEFAULT, true)
        }
    }
}

/**
 * T-287: when the `first_sound` line is due: after a successful write made while the output reported itself running.
 * A burst can be accepted while the stream is still STARTING (requestStart is asynchronous), which would leave the
 * rest of the start-up out of the time. The writer asks the output ([AudioSink.started]) only while [pending].
 */
class FirstSoundWait {
    /** Playback started and no line was written for it yet. */
    var pending = false
        private set

    /** Playback (PLAYING) started. */
    fun onPlaybackStart() {
        pending = true
    }

    /** A write succeeded; [started]: the output is running. True (once) when the line is due now. */
    fun onWrite(started: Boolean): Boolean {
        if (!pending || !started) return false
        pending = false
        return true
    }
}

/**
 * T-287: time from the first packet after a gap to the first audible burst, for the `first_sound` log (the A/B of
 * pausing against not pausing). The control reader calls [onPacket] for every accepted packet; the writer takes the
 * stamp with [take] when playback starts. A gap is [GAP_NS] without a packet (the host's silence gate sends nothing
 * after 500 ms of zeros) or the stream's first packet. Thread-safe, allocation-free.
 */
class FirstSoundTimer(private val gapNs: Long = GAP_NS) {
    private val pending = AtomicLong(0)
    private var lastNs = 0L // reader thread only

    /** A packet arrived at [nowNs] (System.nanoTime(), never 0). */
    fun onPacket(nowNs: Long) {
        val last = lastNs
        lastNs = nowNs
        if (last == 0L || nowNs - last >= gapNs) pending.compareAndSet(0, nowNs)
    }

    /** Arrival stamp of the packet that ended the last gap (0 = none), without consuming it. */
    fun peek(): Long = pending.get()

    /** Consumes the stamp (0 = none). */
    fun take(): Long = pending.getAndSet(0)

    companion object {
        const val GAP_NS = 400_000_000L
    }
}
